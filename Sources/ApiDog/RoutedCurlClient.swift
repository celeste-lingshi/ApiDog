import Darwin
import Foundation

enum RoutedCurlClient {
    static func send(_ request: URLRequest, route: RequestRoute, followsRedirects: Bool) async throws -> ResponseDetails {
        guard let url = request.url else { throw RequestError.invalidURL }
        try route.validate(for: url)
        let transfer = Transfer()
        return try await withTaskCancellationHandler {
            try await Task.detached {
                try transfer.run(request, route: route, followsRedirects: followsRedirects)
            }.value
        } onCancel: {
            transfer.cancel()
        }
    }

    private final class Transfer: @unchecked Sendable {
        private let lock = NSLock()
        private let process = Process()
        private var cancelled = false
        private var started = false

        func cancel() {
            lock.lock()
            defer { lock.unlock() }
            cancelled = true
            if started { stop() }
        }

        private func stop() {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }

        private func start() throws {
            lock.lock()
            defer { lock.unlock() }
            if cancelled { throw CancellationError() }
            try process.run()
            started = true
        }

        func run(_ request: URLRequest, route: RequestRoute, followsRedirects: Bool) throws -> ResponseDetails {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: folder) }

            let headerFile = folder.appendingPathComponent("headers")
            let input = Pipe()
            let output = Pipe()
            let isHead = request.httpMethod == HTTPMethod.head.rawValue
            var options = [
                ["--silent"], ["--proto", "=http,https"], ["--proto-redir", "=http,https"],
                ["--max-time", "30"], ["--max-redirs", "20"], ["--dump-header", headerFile.path]
            ]
            options += CurlCommand.requestOptions(request, followsRedirects: followsRedirects, route: route)
            let config = options.map { option in
                let name = option[0].dropFirst(2)
                return option.count == 1 ? String(name) : name + " = " + Self.configValue(option[1])
            }.joined(separator: "\n") + "\n"

            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            // 参数通过标准输入传递，避免签名和凭证出现在进程参数里。
            process.arguments = ["--disable", "--config", "-"]
            let proxyKeys = ["http_proxy", "https_proxy", "all_proxy", "no_proxy", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"]
            process.environment = ProcessInfo.processInfo.environment.filter { proxyKeys.contains($0.key) }
            process.standardInput = input
            if isHead {
                process.standardOutput = FileHandle.nullDevice
            } else {
                process.standardOutput = output
            }
            process.standardError = FileHandle.nullDevice
            try start()
            defer {
                stop()
                process.waitUntilExit()
            }
            do {
                // 管道提前关闭时，让写入失败以错误返回。
                _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                try input.fileHandleForWriting.write(contentsOf: Data(config.utf8))
                try input.fileHandleForWriting.close()
            } catch {
                try? input.fileHandleForWriting.close()
                if wasCancelled { throw CancellationError() }
                throw error
            }

            var data = Data()
            let limit = HTTPClient.responseLimit
            if !isHead {
                while data.count <= limit,
                      let chunk = try output.fileHandleForReading.read(upToCount: min(16 * 1024, limit + 1 - data.count)),
                      !chunk.isEmpty {
                    data.append(chunk)
                }
            }
            let truncated = data.count > limit
            if truncated { stop() }
            process.waitUntilExit()
            if wasCancelled { throw CancellationError() }
            if !truncated, process.terminationStatus != 0 {
                throw RouteError.curlFailure(process.terminationStatus)
            }
            guard let handle = try? FileHandle(forReadingFrom: headerFile) else { throw RequestError.nonHTTPResponse }
            defer { try? handle.close() }
            let raw = (try handle.read(upToCount: 512 * 1024)) ?? Data()
            let blocks = String(decoding: raw, as: UTF8.self)
                .replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
            guard let final = blocks.last(where: { $0.hasPrefix("HTTP/") }) else { throw RequestError.nonHTTPResponse }
            let lines = final.split(separator: "\n")
            guard let line = lines.first, let status = line.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else {
                throw RequestError.nonHTTPResponse
            }
            let headers = lines.dropFirst()
            let mime = headers.lazy.compactMap { RequestField.header(String($0)) }.first {
                $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame
            }?.value?.split(separator: ";").first.map(String.init)
            let body = Data(data.prefix(limit))
            return ResponseDetails(status: status, headers: headers.joined(separator: "\n"),
                                   body: HTTPClient.displayBody(body, mimeType: mime, truncated: truncated),
                                   byteCount: body.count, truncated: truncated)
        }

        private var wasCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        private static func configValue(_ value: String) -> String {
            let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\t", with: "\\t")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\u{000B}", with: "\\v")
            return "\"" + escaped + "\""
        }
    }
}
