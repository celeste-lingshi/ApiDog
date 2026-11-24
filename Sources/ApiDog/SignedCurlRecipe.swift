import Foundation

enum SignedCurlRecipe {
    private static let identifier = #"[A-Za-z_][A-Za-z0-9_]*"#
    private static let braced = #"\$\{("# + identifier + #")\}"#

    private static let signing = try! NSRegularExpression(pattern:
        #"(?:\A|\n)[ \t]*("# + identifier + #")=\$\(\s*printf\s+'%s'\s+""#
        + braced + "_" + braced + "_" + braced + "_" + braced
        + #""\s*\|\s*openssl\s+dgst\s+-sha256\s+-hmac\s+"\$(?:\{("#
        + identifier + #")\}|("# + identifier
        + #"))"\s+-binary\s*\|\s*openssl\s+base64\s+-A\s*\|\s*tr\s+'/\+'\s+'_-'\s*\|\s*tr\s+-d\s+'='\s*\)\s*\z"#
    )

    static func parse(_ text: String) throws -> RequestDraft {
        guard let start = text.range(of: #"(?m)^[ \t]*curl[ \t]+"#, options: .regularExpression) else {
            throw RecipeError.unsupported
        }
        let prefix = String(text[..<start.lowerBound]).replacingOccurrences(
            of: #"\\\r?\n"#, with: "", options: .regularExpression
        )
        let source = prefix as NSString
        guard let match = signing.firstMatch(in: prefix, range: NSRange(location: 0, length: source.length)) else {
            throw RecipeError.unsupported
        }
        func capture(_ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : source.substring(with: range)
        }
        guard let signName = capture(1), let keyName = capture(2), let secretName = capture(3),
              let pathName = capture(4), let timeName = capture(5),
              (capture(6) ?? capture(7)) == secretName,
              Set([signName, keyName, secretName, pathName, timeName]).count == 5 else {
            throw RecipeError.unsupported
        }

        var literals: [String: String] = [:]
        var declared = Set<String>()
        var hasTime = false
        let assignments = source.substring(to: match.range.location)
        for line in assignments.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].range(of: #"\A"# + identifier + #"\z"#,
                                                 options: .regularExpression) != nil else {
                throw RecipeError.unsupported
            }
            let name = String(parts[0])
            guard declared.insert(name).inserted, name != signName else { throw RecipeError.unsupported }
            let value = String(parts[1])
            if name == timeName {
                guard value.range(of: #"\A\$\(\s*date\s+\+%s\s*\)\z"#, options: .regularExpression) != nil else {
                    throw RecipeError.unsupported
                }
                hasTime = true
                continue
            }
            let (words, _) = try CurlCommand.tokenize(value)
            guard words.count <= 1 else { throw RecipeError.unsupported }
            literals[name] = words.first ?? ""
        }
        guard hasTime, let signedURI = literals[pathName], !signedURI.isEmpty else { throw RecipeError.unsupported }
        let key = literals.removeValue(forKey: keyName)
        let secret = literals.removeValue(forKey: secretName)
        let templateVariables = literals
        let marker = UUID().uuidString
        let keyMarker = marker + "-key"
        let timeMarker = marker + "-time"
        let signMarker = marker + "-sign"
        literals[keyName] = keyMarker
        literals[timeName] = timeMarker
        literals[signName] = signMarker

        var draft = try CurlCommand.parseCommand(String(text[start.lowerBound...]), substitutions: literals,
                                                templateVariables: templateVariables)
        guard draft.auth.mode == .none,
              let keyField = draft.query.first(where: { $0.value == keyMarker })?.name,
              !keyField.isEmpty, !["timestamp", "sign"].contains(keyField),
              draft.query.filter({ $0.name == keyField }).count == 1,
              draft.query.filter({ $0.name == "timestamp" }).map(\.value) == [timeMarker],
              draft.query.filter({ $0.name == "sign" }).map(\.value) == [signMarker] else {
            throw RecipeError.authFields
        }
        draft.query.removeAll { [keyField, "timestamp", "sign"].contains($0.name) }
        let leftovers = [draft.url, draft.body ?? "", draft.route?.resolve ?? "", draft.route?.noProxy ?? "", draft.projection ?? ""]
            + (draft.query + draft.headers).flatMap { [$0.name, $0.value ?? ""] }
        guard !leftovers.contains(where: { $0.contains(marker) }) else { throw RecipeError.authFields }

        draft.auth = RequestAuthentication(
            mode: .hmac, name: key ?? "", secret: secret,
            signingURI: "{{\(pathName)}}",
            signingKeyField: keyField, signingKeyInput: keyName, signingSecretInput: secretName
        )
        let referenced = Set(draft.variableNames)
        draft.variables = templateVariables.filter { referenced.contains($0.key) }
        return draft
    }
}

private enum RecipeError: LocalizedError {
    case unsupported, authFields

    var errorDescription: String? {
        switch self {
        case .unsupported: return "无法识别签名命令。请使用普通变量赋值、date +%s 和 OpenSSL HMAC-SHA256 写法。"
        case .authFields: return "签名命令需要在查询中引用 Key、timestamp 和 sign，且每项只出现一次。"
        }
    }
}
