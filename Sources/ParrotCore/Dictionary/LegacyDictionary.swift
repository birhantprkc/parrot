import Foundation

// The old format, `dictionary.json`, kept only so `DictionaryMigration` can
// convert it once to the plain-text table.

extension UserDictionary {
    /// Decodes a `dictionary.json`, or throws a `LegacyDictionaryError` that
    /// names where the problem is and never quotes the file's contents.
    static func parseLegacyJSON(_ data: Data) throws -> UserDictionary {
        // JSONSerialization reports syntax errors with a byte offset, which
        // becomes a line and column; JSONDecoder then reports type errors with
        // a key path.
        do {
            let object = try JSONSerialization.jsonObject(with: data, options: [])
            guard object is [String: Any] else { throw LegacyDictionaryError.notAnObject }
        } catch let error as LegacyDictionaryError {
            throw error
        } catch {
            let offset = (error as NSError).userInfo["NSJSONSerializationErrorIndex"] as? Int
            throw LegacyDictionaryError.syntax(position: offset.map { Position(offset: $0, in: data) })
        }
        do {
            return try JSONDecoder().decode(UserDictionary.self, from: data)
        } catch let error as DecodingError {
            throw LegacyDictionaryError.schema(path: Self.keyPath(error), problem: Self.problem(error))
        }
    }

    /// Line and column (both from 1) of a byte offset.
    struct Position: Equatable {
        var line: Int
        var column: Int

        init(line: Int, column: Int) {
            self.line = line
            self.column = column
        }

        init(offset: Int, in data: Data) {
            var line = 1
            var lineStart = 0
            for (i, byte) in data.prefix(max(0, offset)).enumerated() where byte == UInt8(ascii: "\n") {
                line += 1
                lineStart = i + 1
            }
            // Count characters, not bytes, so a column after "é" is still right.
            let prefix = data[lineStart..<min(max(offset, lineStart), data.count)]
            let column = (String(data: prefix, encoding: .utf8)?.count ?? prefix.count) + 1
            self.init(line: line, column: column)
        }
    }

    private static func keyPath(_ error: DecodingError) -> String {
        let context: DecodingError.Context
        switch error {
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c):
            context = c
        case .keyNotFound(let key, let c):
            return render(c.codingPath + [key])
        @unknown default:
            return "?"
        }
        return render(context.codingPath)
    }

    private static func render(_ path: [CodingKey]) -> String {
        var out = ""
        for key in path {
            if let index = key.intValue {
                out += "[\(index)]"
            } else {
                out += out.isEmpty ? key.stringValue : ".\(key.stringValue)"
            }
        }
        return out.isEmpty ? "top level" : out
    }

    private static func problem(_ error: DecodingError) -> String {
        switch error {
        case .typeMismatch(let type, _): return "expected \(describe(type))"
        case .valueNotFound(let type, _): return "expected \(describe(type)), found null"
        case .keyNotFound: return "missing"
        case .dataCorrupted: return "invalid value"
        @unknown default: return "invalid"
        }
    }

    private static func describe(_ type: Any.Type) -> String {
        switch type {
        case is String.Type: return "a string"
        case is [String].Type, is [Replacement].Type, is [Any].Type: return "an array"
        case is [String: String].Type, is [String: Any].Type: return "an object"
        default: return "\(type)"
        }
    }
}

/// Why `dictionary.json` did not convert. Descriptions give a position or key
/// path and never quote the file.
enum LegacyDictionaryError: Error, Equatable, CustomStringConvertible {
    case syntax(position: UserDictionary.Position?)
    case notAnObject
    case schema(path: String, problem: String)

    var description: String {
        switch self {
        case .syntax(let position?):
            return "invalid JSON at line \(position.line), column \(position.column)"
        case .syntax(nil):
            return "invalid JSON"
        case .notAnObject:
            return "the top level must be an object"
        case .schema(let path, let problem):
            return "\(path): \(problem)"
        }
    }
}
