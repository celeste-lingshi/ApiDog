import Darwin
import Foundation

struct RequestRoute: Codable, Equatable {
    var resolve: String?
    var noProxy: String?

    var isConfigured: Bool { resolve != nil || noProxy != nil }

    func validate(for url: URL) throws {
        if let noProxy, noProxy.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            throw RouteError.invalidProxy
        }
        guard let resolve else { return }
        let parts = resolve.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let port = Int(parts[1]), (1...65_535).contains(port) else {
            throw RouteError.invalidResolve
        }
        let address = String(parts[2])
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        let valid: Bool
        if address.hasPrefix("["), address.hasSuffix("]") {
            valid = inet_pton(AF_INET6, String(address.dropFirst().dropLast()), &ipv6) == 1
        } else {
            valid = inet_pton(AF_INET, address, &ipv4) == 1
        }
        guard valid else { throw RouteError.invalidResolve }
        let expectedPort = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        guard url.host?.caseInsensitiveCompare(String(parts[0])) == .orderedSame, port == expectedPort else {
            throw RouteError.mismatchedResolve
        }
    }
}

enum RouteError: LocalizedError {
    case invalidResolve, mismatchedResolve, invalidProxy, curlFailure(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidResolve: return "指定解析需要填写「域名:端口:IP」，IPv6 地址用方括号括起。"
        case .mismatchedResolve: return "指定解析的域名和端口须与请求 URL 一致。"
        case .invalidProxy: return "直连主机列表不能包含控制字符。"
        case .curlFailure(let code): return "系统 cURL 发送失败，退出码 \(code)。"
        }
    }
}
