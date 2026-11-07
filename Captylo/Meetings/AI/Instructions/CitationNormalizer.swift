import Foundation

/// Puts the citations a small model writes in its own way back into the forms the parsers read
/// (`MeetingCitations`, `LibraryCitation`): a list in one bracket becomes one bracket per
/// source ("[26:23, 27:40]" -> "[26:23] [27:40]", "[S1 12:34, 15:00]" -> "[S1 12:34] [S1 15:00]")
/// and a time span keeps its start ("[0:00-1:45]" -> "[0:00]"). Any other bracket (a Markdown
/// link, a checkbox, plain text) stays as it is. Applied to every answer of the meeting AI.
enum CitationNormalizer {
    private static let time = #"(?:\d+:)?\d{1,2}:\d{2}"#
    /// A bracket on one line, short enough to be a citation list.
    private static let bracket = try! NSRegularExpression(pattern: #"\[([^\[\]\n]{1,120})\]"#)
    private static let bareTime = try! NSRegularExpression(pattern: "^\(time)$")
    /// "S1 12:34" or "S1, 12:34": the source and the time.
    private static let sourceTime = try! NSRegularExpression(pattern: #"^(S\d{1,2}),?\s+("# + time + ")$")
    private static let sourceOnly = try! NSRegularExpression(pattern: #"^(?:S|N)\d{1,2}$"#)
    /// "<anything>12:34-13:00" (hyphen or en dash between): the part up to the first time.
    private static let span = try! NSRegularExpression(pattern: "^(.*?\(time))\\s*[-\\u2013]\\s*\(time)$")

    static func normalize(_ text: String) -> String {
        let ns = text as NSString
        let matches = bracket.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        let result = NSMutableString(string: text)
        for match in matches.reversed() {
            let content = ns.substring(with: match.range(at: 1))
            if let fixed = rewrite(content) {
                result.replaceCharacters(in: match.range, with: fixed)
            }
        }
        return result as String
    }

    /// The brackets for `content`, or nil when it is not a citation list or span to fix.
    private static func rewrite(_ content: String) -> String? {
        let items = content
            .components(separatedBy: CharacterSet(charactersIn: ",;"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // "S1, 12:34" is one source with its time, not a list.
        if items.count == 2, matches(sourceTime, "\(items[0]) \(items[1])"), matches(sourceOnly, items[0]), matches(bareTime, items[1]) {
            return nil
        }
        var changed = items.count > 1
        let reduced = items.map { item -> String in
            guard let start = first(span, item) else { return item }
            changed = true
            return start
        }
        var source: String?
        var out: [String] = []
        for (index, item) in reduced.enumerated() {
            if matches(bareTime, item) {
                out.append(source.map { "\($0) \(item)" } ?? item)
            } else if let (name, _) = sourceAndTime(item) {
                source = name
                out.append(item)
            } else if matches(sourceOnly, item) {
                source = item.hasPrefix("S") ? item : nil
                // "S1" followed by its times names the meeting of those times only.
                let next = index + 1 < reduced.count ? reduced[index + 1] : ""
                if source == nil || !matches(bareTime, next) {
                    out.append(item)
                }
            } else {
                return nil
            }
        }
        guard changed, !out.isEmpty else { return nil }
        return out.map { "[\($0)]" }.joined(separator: " ")
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// Group 1 of the first match.
    private static func first(_ regex: NSRegularExpression, _ text: String) -> String? {
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    private static func sourceAndTime(_ text: String) -> (String, String)? {
        let ns = text as NSString
        guard let match = sourceTime.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (ns.substring(with: match.range(at: 1)), ns.substring(with: match.range(at: 2)))
    }
}
