import CryptoKit
import Foundation

struct GeneratedAuthFields {
    var headers: [String: String] = [:]
    var query: [String: String] = [:]
    var body: [String: Any] = [:]

    init() {}

    init(_ data: Data) throws {
        guard let values = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(values.keys).isSubset(of: ["headers", "query", "body"]) else {
            throw RequestError.invalidAuthOutput
        }
        if let value = values["headers"] {
            guard let fields = value as? [String: String] else { throw RequestError.invalidAuthOutput }
            headers = fields
        }
        if let value = values["query"] {
            guard let fields = value as? [String: String] else { throw RequestError.invalidAuthOutput }
            query = fields
        }
        if let value = values["body"] {
            guard let fields = value as? [String: Any] else { throw RequestError.invalidAuthOutput }
            body = fields
        }
    }

    mutating func place(_ value: String, as name: String, at location: RequestAuthentication.Location) {
        switch location {
        case .header: headers[name] = value
        case .query: query[name] = value
        case .body: body[name] = value
        }
    }
}

enum AuthCrypto {
    static func hmac(_ secret: String, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(secret.utf8))))
    }

    static func hmacBase64URL(_ secret: String, _ message: String) -> String {
        hmac(secret, message).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func sha256Hex(_ message: String) -> String {
        hex(SHA256.hash(data: Data(message.utf8)))
    }

    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
