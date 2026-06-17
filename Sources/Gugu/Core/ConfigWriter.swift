import Foundation

/// Surgically edits the `config.yaml` text by dotted key, preserving comments,
/// blank lines, key ordering, and any keys the settings UI doesn't manage.
/// Counterpart to `MiniYAML` (which only reads). Same YAML subset: flat
/// `key: value` plus one level of two-space `section:` nesting.
///
/// A value of `nil` deletes the key (used when a tier override is cleared so it
/// falls back to the base model id). Keys not present in the file are inserted
/// under their section (the section is created at the end if it doesn't exist).
enum ConfigWriter {

    /// Apply `changes` (dotted key -> value, or nil to delete) to the file at
    /// `url`, writing atomically. Order of `changes` decides insertion order for
    /// brand-new keys within a section.
    static func update(_ url: URL, changes: [(key: String, value: String?)]) throws {
        let original = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let updated = apply(to: original, changes: changes)
        try updated.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Pure text transform — exposed for testing without touching disk.
    static func apply(to text: String, changes: [(key: String, value: String?)]) -> String {
        // Preserve the document's original line ending where detectable.
        var lines = text.components(separatedBy: "\n")

        var pending = changes               // not yet written
        func take(_ dotted: String) -> (value: String?, present: Bool) {
            if let idx = pending.firstIndex(where: { $0.key == dotted }) {
                let v = pending.remove(at: idx).value
                return (v, true)
            }
            return (nil, false)
        }

        // --- Phase A: rewrite or delete existing keys in place ---
        var section: String? = nil
        var out: [String] = []
        out.reserveCapacity(lines.count)
        for line in lines {
            guard let parsed = parseKeyLine(line) else {
                out.append(line)            // comment / blank / unparseable: keep verbatim
                continue
            }
            // Track section context exactly like MiniYAML does.
            if !parsed.indented {
                section = parsed.value.isEmpty ? parsed.key : nil
            }
            let dotted = parsed.indented ? "\(section ?? "").\(parsed.key)" : parsed.key
            let (newValue, present) = take(dotted)
            guard present else { out.append(line); continue }
            guard let newValue else { continue }   // delete: drop the line
            out.append(rewriteValue(line, parsed: parsed, newValue: newValue))
        }
        lines = out

        // --- Phase B: insert keys that weren't found ---
        // Group remaining inserts by section (top-level keys use section "").
        for change in pending {
            guard let value = change.value else { continue }   // delete of absent key: no-op
            let (sect, leaf) = splitDotted(change.key)
            insert(&lines, section: sect, key: leaf, value: value)
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Line parsing

    private struct KeyLine {
        var indent: String      // leading whitespace, preserved on rewrite
        var key: String
        var value: String       // raw value, comment stripped
        var comment: String     // trailing comment incl. leading spaces and '#', or ""
        var indented: Bool { !indent.isEmpty }
    }

    /// Parse `  key: value   # comment` into parts. Returns nil for blank lines,
    /// pure comments, or lines without a colon.
    private static func parseKeyLine(_ line: String) -> KeyLine? {
        let trimmedLeading = line.drop(while: { $0 == " " || $0 == "\t" })
        let indent = String(line[line.startIndex..<trimmedLeading.startIndex])
        let body = String(trimmedLeading)
        if body.isEmpty || body.hasPrefix("#") { return nil }
        guard let colon = body.firstIndex(of: ":") else { return nil }
        let key = String(body[..<colon]).trimmingCharacters(in: .whitespaces)
        if key.isEmpty { return nil }
        let afterColon = String(body[body.index(after: colon)...])
        let (value, comment) = splitComment(afterColon)
        return KeyLine(indent: indent,
                       key: key,
                       value: value.trimmingCharacters(in: .whitespaces),
                       comment: comment)
    }

    /// Split a value region into (value, trailingComment). The comment retains
    /// its original leading spacing and '#'. Quotes are respected.
    private static func splitComment(_ s: String) -> (String, String) {
        var inQuote: Character? = nil
        let chars = Array(s)
        for i in chars.indices {
            let ch = chars[i]
            if let q = inQuote {
                if ch == q { inQuote = nil }
            } else if ch == "\"" || ch == "'" {
                inQuote = ch
            } else if ch == "#" {
                return (String(chars[..<i]), String(chars[i...]))
            }
        }
        return (s, "")
    }

    private static func rewriteValue(_ original: String, parsed: KeyLine, newValue: String) -> String {
        // Keep a single space after the colon and re-attach any trailing comment,
        // preserving the gap the comment originally had.
        let commentSuffix: String
        if parsed.comment.isEmpty {
            commentSuffix = ""
        } else {
            commentSuffix = "  " + parsed.comment.trimmingCharacters(in: .whitespaces)
        }
        return "\(parsed.indent)\(parsed.key): \(newValue)\(commentSuffix)"
    }

    // MARK: - Insertion

    private static func splitDotted(_ dotted: String) -> (section: String, leaf: String) {
        guard let dot = dotted.firstIndex(of: ".") else { return ("", dotted) }
        return (String(dotted[..<dot]), String(dotted[dotted.index(after: dot)...]))
    }

    /// Insert `key: value` into `lines`. For a sectioned key, place it just after
    /// the last line belonging to that section; create the section at EOF if
    /// absent. For a top-level key (section ""), append at EOF.
    private static func insert(_ lines: inout [String], section: String, key: String, value: String) {
        if section.isEmpty {
            lines.append("\(key): \(value)")
            return
        }
        // Find the section header line index.
        var headerIdx: Int? = nil
        for (i, line) in lines.enumerated() {
            guard let parsed = parseKeyLine(line), !parsed.indented else { continue }
            if parsed.key == section && parsed.value.isEmpty { headerIdx = i; break }
        }
        let newLine = "  \(key): \(value)"
        guard let header = headerIdx else {
            // No such section: create it at EOF (with a separating blank line).
            if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("")
            }
            lines.append("\(section):")
            lines.append(newLine)
            return
        }
        // Walk to the end of the section (next top-level key or EOF), then insert
        // after the last non-blank line within it.
        var insertAt = header + 1
        var lastContent = header
        var i = header + 1
        while i < lines.count {
            let line = lines[i]
            if let parsed = parseKeyLine(line) {
                if !parsed.indented { break }       // next section starts
                lastContent = i
            }
            // blank/comment lines inside the section are skipped over but not counted
            i += 1
        }
        insertAt = lastContent + 1
        lines.insert(newLine, at: insertAt)
    }
}
