import Foundation

/// The user's custom dictionary, stored as `Paths.dictionaryFile` (#33).
///
/// Three kinds of entry, all optional:
/// - `terms`: canonical spellings. A term heard in any casing is rewritten to
///   this one ("posthog" becomes "PostHog").
/// - `replacements`: what the model writes instead of a word, mapped to the
///   word ("post hog" becomes "PostHog").
/// - `examples`: one natural sentence per language, keyed by language code,
///   that the engine may condition on. Whisper reads it as speech that came
///   just before the dictation, so it biases spelling without being a list.
///
/// This is the only user-authored text Parrot stores. It never holds
/// transcript text.
struct UserDictionary: Codable, Equatable, Sendable {
    struct Replacement: Codable, Equatable, Sendable {
        /// What the model writes. Matched as whole words, ignoring case.
        var from: [String]
        /// What to write instead, inserted exactly as given.
        var to: String
    }

    var terms: [String]
    var replacements: [Replacement]
    /// One sentence per language code (`en`, `pt-BR`).
    var examples: [String: String]

    init(terms: [String] = [], replacements: [Replacement] = [], examples: [String: String] = [:]) {
        self.terms = terms
        self.replacements = replacements
        self.examples = examples
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        terms = try c.decodeIfPresent([String].self, forKey: .terms) ?? []
        replacements = try c.decodeIfPresent([Replacement].self, forKey: .replacements) ?? []
        examples = try c.decodeIfPresent([String: String].self, forKey: .examples) ?? [:]
    }

    static let empty = UserDictionary()

    /// The example sentence for `language`, or nil when there is none.
    ///
    /// Matches the exact code first, then its primary subtag, ignoring case:
    /// `pt-BR` and `pt` share a section. There is no fallback to another
    /// language: a prompt in the wrong language pulls the decoder into that
    /// language, which is worse than no prompt (#23).
    func example(for language: String?) -> String? {
        guard let language, !language.isEmpty else { return nil }
        // Sorted so the choice among several matching sections is stable.
        let sections = examples
            .map { (code: $0.key.lowercased(), text: $0.value.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.text.isEmpty }
            .sorted { $0.code < $1.code }
        let code = language.lowercased()
        let primary = Self.primarySubtag(code)
        if let exact = sections.first(where: { $0.code == code }) { return exact.text }
        if let base = sections.first(where: { $0.code == primary }) { return base.text }
        // `en` spoken, only `en-US` written: still the same language.
        return sections.first { Self.primarySubtag($0.code) == primary }?.text
    }

    /// Canonical spellings for engines that accept a vocabulary list, such as
    /// contextual strings: every term and every replacement target.
    var vocabulary: [String] {
        var seen = Set<String>()
        return (terms + replacements.map(\.to))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func primarySubtag(_ code: String) -> String {
        String(code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? Substring(code))
    }
}

// MARK: - Parsing

extension UserDictionary {
    /// Decodes `data`, or throws a `DictionaryParseError` that names where the
    /// problem is and never quotes the file's contents.
    static func parse(_ data: Data) throws -> UserDictionary {
        // JSONSerialization reports syntax errors with a byte offset, which
        // becomes a line and column; JSONDecoder then reports type errors with
        // a key path.
        do {
            let object = try JSONSerialization.jsonObject(with: data, options: [])
            guard object is [String: Any] else { throw DictionaryParseError.notAnObject }
        } catch let error as DictionaryParseError {
            throw error
        } catch {
            let offset = (error as NSError).userInfo["NSJSONSerializationErrorIndex"] as? Int
            throw DictionaryParseError.syntax(position: offset.map { Position(offset: $0, in: data) })
        }
        do {
            return try JSONDecoder().decode(UserDictionary.self, from: data)
        } catch let error as DecodingError {
            throw DictionaryParseError.schema(path: Self.keyPath(error), problem: Self.problem(error))
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

/// Why `dictionary.json` did not load. Descriptions give a position or key
/// path and never quote the file.
enum DictionaryParseError: Error, Equatable, CustomStringConvertible {
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

// MARK: - First-run template

extension UserDictionary {
    /// Written on first run so the file starts with one working example of
    /// each entry type. JSON has no comments; the README documents the format.
    static let template = """
        {
          "terms": ["PostHog", "WhisperKit"],
          "replacements": [
            { "from": ["post hog", "posthoc"], "to": "PostHog" }
          ],
          "examples": {
            "en": "I pushed the WhisperKit fix and checked the PostHog dashboard before the review."
          }
        }

        """
}
