import Foundation

enum MeowConfigValidator {
    static func validate(_ yaml: String) throws {
        let rc = yaml.withCString { ptr -> Int32 in
            meow_engine_validate_config(ptr, Int32(yaml.utf8.count))
        }
        if rc != 0 {
            let msg = meow_core_last_error().map { String(cString: $0) } ?? "invalid config"
            throw MeowConfigError.invalid(msg)
        }
    }

    static func parseErrorLines(_ message: String) -> Set<Int> {
        var lines: Set<Int> = []
        let rawPatterns = [
            #"at line (\d+)"#,
            #"line (\d+) column \d+"#,
            #"\[(\d+)\]"#,
        ]
        let nsMsg = message as NSString
        let range = NSRange(location: 0, length: nsMsg.length)
        for raw in rawPatterns {
            guard let regex = try? NSRegularExpression(pattern: raw) else { continue }
            for match in regex.matches(in: message, range: range)
                where match.numberOfRanges >= 2
            {
                if let n = Int(nsMsg.substring(with: match.range(at: 1))), n > 0 {
                    lines.insert(n)
                }
            }
        }
        return lines
    }
}

enum MeowConfigError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        let fallback = String(
            localized: "yamlEditor.error.invalid",
            comment: "Fallback message when config validation fails without engine detail",
        )
        if case let .invalid(msg) = self {
            return msg.isEmpty ? fallback : msg
        }
        return fallback
    }
}
