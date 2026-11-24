import Darwin
import Foundation
import JavaScriptCore

struct AuthScript: Codable {
    static let workerArgument = "--apidog-auth-worker"
    static let example = """
    if (!inputs.token) throw new Error("请填写 token");
    return { headers: { Authorization: "Bearer " + inputs.token } };
    """
    private static let maxInput = 512 * 1024
    private static let maxOutput = 64 * 1024

    struct QueryItem: Codable {
        var name: String
        var value: String?
    }

    struct Context: Codable {
        var method: String
        var url: String
        var uri: String
        var query: [QueryItem]
        var headers: [String: String]
        var body: String

        var javascript: [String: Any] {
            ["method": method, "url": url, "uri": uri,
             "query": query.map { ["name": $0.name, "value": $0.value as Any? ?? NSNull()] },
             "headers": headers, "body": body]
        }
    }

    var source: String
    var inputs: [String: String]
    var request: Context
    var timestamp: String

    private struct WorkerResult: Codable {
        var fields: Data?
        var error: String?
    }

    func run() throws -> GeneratedAuthFields {
        guard let executable = Bundle.main.executableURL else { throw RequestError.authWorkerUnavailable }
        let bytes = try JSONEncoder().encode(self)
        guard bytes.count <= Self.maxInput else { throw RequestError.authScriptSize }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = [Self.workerArgument]
        process.environment = [:]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw RequestError.authWorkerUnavailable
        }

        let watchdog = DispatchWorkItem {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: watchdog)
        defer { watchdog.cancel() }

        do {
            try input.fileHandleForWriting.write(contentsOf: bytes)
            try input.fileHandleForWriting.close()
        } catch {
            try? input.fileHandleForWriting.close()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw RequestError.authWorkerUnavailable
        }

        let reply = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit else { throw RequestError.authScriptInterrupted }
        guard process.terminationStatus == 0,
              let result = try? JSONDecoder().decode(WorkerResult.self, from: reply) else {
            throw RequestError.authWorkerUnavailable
        }
        if let error = result.error { throw RequestError.authScript(error) }
        guard let fields = result.fields else { throw RequestError.invalidAuthOutput }
        return try GeneratedAuthFields(fields)
    }

    static func runWorkerIfRequested() -> Bool {
        guard CommandLine.arguments.dropFirst().elementsEqual([workerArgument]) else { return false }
        let result: WorkerResult
        do {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard data.count <= maxInput else { throw RequestError.authScriptSize }
            let input = try JSONDecoder().decode(Self.self, from: data)
            result = WorkerResult(fields: try input.evaluate())
        } catch RequestError.authScript(let reason) {
            result = WorkerResult(error: reason)
        } catch {
            result = WorkerResult(error: error.localizedDescription)
        }
        if let reply = try? JSONEncoder().encode(result) { FileHandle.standardOutput.write(reply) }
        return true
    }

    private func evaluate() throws -> Data {
        guard let js = JSContext() else { throw RequestError.authWorkerUnavailable }

        let hmacURL: @convention(block) (String, String) -> String = { secret, message in
            AuthCrypto.hmacBase64URL(secret, message)
        }
        let hmacHex: @convention(block) (String, String) -> String = { secret, message in
            AuthCrypto.hex(AuthCrypto.hmac(secret, message))
        }
        let sha256: @convention(block) (String) -> String = { AuthCrypto.sha256Hex($0) }
        let base64: @convention(block) (String) -> String = { Data($0.utf8).base64EncodedString() }
        let crypto = JSValue(newObjectIn: js)
        crypto?.setObject(hmacURL, forKeyedSubscript: "hmacSHA256Base64URL")
        crypto?.setObject(hmacHex, forKeyedSubscript: "hmacSHA256Hex")
        crypto?.setObject(sha256, forKeyedSubscript: "sha256Hex")
        crypto?.setObject(base64, forKeyedSubscript: "base64")
        var exception: String?
        js.exceptionHandler = { _, error in exception = String((error?.toString() ?? "脚本错误").prefix(240)) }

        guard let function = js.objectForKeyedSubscript("Function")?.construct(
            withArguments: ["inputs", "request", "timestamp", "crypto", "\"use strict\";\n" + source]
        ), exception == nil else {
            throw RequestError.authScript(exception ?? "脚本语法错误。")
        }
        guard let crypto else { throw RequestError.authWorkerUnavailable }
        let result = function.call(withArguments: [inputs, request.javascript, timestamp, crypto])
        if let exception { throw RequestError.authScript(exception) }
        guard let result, result.isObject,
              let serialized = js.objectForKeyedSubscript("JSON")?.invokeMethod("stringify", withArguments: [result]),
              serialized.isString, let json = serialized.toString(), exception == nil else {
            throw RequestError.invalidAuthOutput
        }
        let fields = Data(json.utf8)
        guard fields.count <= Self.maxOutput else { throw RequestError.authScriptSize }
        return fields
    }
}
