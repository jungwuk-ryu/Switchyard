import Foundation

/// Parses the simple `KEY=value` files bundled with Switchyard.
///
/// Blank lines, comments, malformed assignments, and assignments containing
/// control characters are ignored. When a key is assigned more than
/// once, the last valid assignment wins, matching a shell sourcing the file.
public enum SourceEnvironmentFile {
    public static func parse(_ contents: String) -> [String: String] {
        var values: [String: String] = [:]

        for rawLine in contents.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine[...]
            let content = line.drop(while: { $0 == " " })
            guard !content.isEmpty,
                  !content.hasPrefix("#"),
                  let separator = content.firstIndex(of: "=") else {
                continue
            }

            let key = content[..<separator]
            let value = content[content.index(after: separator)...]
            guard isValidKey(key),
                  !containsControl(key),
                  !containsControl(value) else {
                continue
            }

            values[String(key)] = String(value)
        }

        return values
    }

    private static func isValidKey(_ key: Substring) -> Bool {
        guard let first = key.first,
              first == "_" || first.isASCII && first.isLetter else {
            return false
        }

        return key.dropFirst().allSatisfy {
            $0 == "_" || $0.isASCII && ($0.isLetter || $0.isNumber)
        }
    }

    private static func containsControl(_ text: Substring) -> Bool {
        text.unicodeScalars.contains {
            $0.properties.generalCategory == .control
        }
    }
}
