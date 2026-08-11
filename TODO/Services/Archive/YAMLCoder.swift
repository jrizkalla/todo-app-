import Foundation

/// Writes the YAML subset the archive uses.
///
/// Deliberately a subset, not a general YAML emitter: block mappings, block
/// sequences, and scalars. That is everything the records need, and it keeps the
/// output the kind of thing a person can read and edit in a text editor — which
/// is much of the point of exporting YAML rather than a binary or JSON dump.
enum YAMLWriter {

    /// Render a record as a YAML document.
    ///
    /// Keys are emitted in the order given rather than sorted, so related fields
    /// stay together for a reader.
    static func document(_ pairs: [(String, YAMLValue)]) -> String {
        var output = ""
        for (key, value) in pairs {
            append(key: key, value: value, indent: 0, to: &output)
        }
        return output
    }

    private static func append(
        key: String,
        value: YAMLValue,
        indent: Int,
        to output: inout String
    ) {
        let padding = String(repeating: " ", count: indent)

        switch value {
        case .null:
            output += "\(padding)\(key):\n"

        case .scalar(let text):
            output += "\(padding)\(key): \(scalar(text))\n"

        case .list(let items):
            if items.isEmpty {
                output += "\(padding)\(key): []\n"
                return
            }
            output += "\(padding)\(key):\n"
            for item in items {
                switch item {
                case .mapping(let pairs):
                    // A mapping inside a sequence puts its first key on the
                    // dash line, which is the conventional YAML shape.
                    var isFirst = true
                    for (childKey, childValue) in pairs.sorted(by: { $0.key < $1.key }) {
                        var rendered = ""
                        append(key: childKey, value: childValue, indent: indent + 4, to: &rendered)
                        if isFirst {
                            let trimmed = rendered.drop { $0 == " " }
                            output += "\(padding)  - \(trimmed)"
                            isFirst = false
                        } else {
                            output += rendered
                        }
                    }
                default:
                    output += "\(padding)  - \(scalar(item.stringValue ?? ""))\n"
                }
            }

        case .mapping(let pairs):
            output += "\(padding)\(key):\n"
            for (childKey, childValue) in pairs.sorted(by: { $0.key < $1.key }) {
                append(key: childKey, value: childValue, indent: indent + 2, to: &output)
            }
        }
    }

    /// Quote a scalar when leaving it bare would change how it parses.
    ///
    /// Multi-line text uses a literal block (`|-`), which is what keeps exported
    /// notes readable instead of collapsing into one escaped line.
    private static func scalar(_ text: String) -> String {
        if text.isEmpty { return "\"\"" }

        if text.contains("\n") {
            // Rendered by the caller's indentation; see `blockScalar`.
            return blockScalar(text)
        }

        let needsQuoting =
            text != text.trimmingCharacters(in: .whitespaces)
            || text.first.map { ":#-?&*!|>'\"%@`[]{},".contains($0) } == true
            || text.contains(": ")
            || text.hasSuffix(":")
            || ["true", "false", "yes", "no", "on", "off", "null", "~", "y", "n"]
                .contains(text.lowercased())
            || Double(text) != nil

        guard needsQuoting else { return text }

        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// A literal block scalar, indented four spaces under its key.
    ///
    /// `|-` strips the trailing newline so a value round-trips to exactly what
    /// was exported.
    private static func blockScalar(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let body = lines.map { "    \($0)" }.joined(separator: "\n")
        return "|-\n\(body)"
    }
}

/// Parses the YAML subset the exporter writes — and tries hard to make sense of
/// anything close to it.
///
/// Forgiveness here is structural, complementing the type-level leniency in
/// `YAMLValue`: a malformed line is skipped instead of aborting the document, so
/// one bad line costs one field rather than the whole record. That is what lets
/// an import survive a file that has been hand-edited, truncated, or written by
/// a different version of the app.
enum YAMLParser {

    /// Parse a document into a mapping. Never throws — a file that makes no
    /// sense at all parses to an empty mapping, which the importer reports as a
    /// skipped record.
    static func parse(_ text: String) -> YAMLValue {
        let lines = Self.physicalLines(of: text)
        var index = 0
        let mapping = parseMapping(lines, index: &index, indent: 0)
        return .mapping(mapping)
    }

    private struct Line {
        var indent: Int
        var content: String
        /// Blank, a comment, or a document marker.
        ///
        /// Structural parsing skips these, but a block scalar keeps them: a
        /// blank line inside exported notes is content, and so is a markdown
        /// `# Heading`, which is indistinguishable from a comment out of
        /// context. Filtering them away up front is what silently corrupted
        /// every multi-line note.
        var isStructuralNoise: Bool
    }

    /// Split into lines, tagging the ones structural parsing ignores.
    private static func physicalLines(of text: String) -> [Line] {
        text.components(separatedBy: .newlines).map { raw in
            // Tabs are illegal for YAML indentation but appear in hand-edited
            // files; treating them as two spaces is friendlier than failing.
            let indent = raw.prefix { $0 == " " || $0 == "\t" }
                .reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
            let content = raw.trimmingCharacters(in: .whitespaces)

            let isNoise = content.isEmpty
                || content == "---"
                || content == "..."
                || content.hasPrefix("#")

            return Line(indent: indent, content: content, isStructuralNoise: isNoise)
        }
    }

    /// Advance past lines that carry no structure.
    private static func skipNoise(_ lines: [Line], index: inout Int) {
        while index < lines.count, lines[index].isStructuralNoise {
            index += 1
        }
    }

    private static func parseMapping(
        _ lines: [Line],
        index: inout Int,
        indent: Int
    ) -> [String: YAMLValue] {
        var result: [String: YAMLValue] = [:]

        while true {
            skipNoise(lines, index: &index)
            guard index < lines.count else { break }

            let line = lines[index]
            if line.indent < indent { break }

            // A sequence item at this level does not belong to a mapping;
            // hand it back to the caller.
            if line.content.hasPrefix("- ") || line.content == "-" { break }

            guard let separator = keySeparatorIndex(in: line.content) else {
                // Not a `key: value` line at all. Skip it — a stray line should
                // not cost the reader the rest of the record.
                index += 1
                continue
            }

            let key = line.content[..<separator]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let inlineValue = line.content[line.content.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)

            index += 1

            if !inlineValue.isEmpty {
                if inlineValue.hasPrefix("|") || inlineValue.hasPrefix(">") {
                    result[key] = .scalar(
                        parseBlockScalar(lines, index: &index, parentIndent: line.indent,
                                         folded: inlineValue.hasPrefix(">"),
                                         chomp: inlineValue.contains("-"))
                    )
                } else {
                    result[key] = parseInlineScalar(inlineValue)
                }
                continue
            }

            // No inline value: a nested block, or an explicit empty.
            var lookahead = index
            skipNoise(lines, index: &lookahead)
            guard lookahead < lines.count, lines[lookahead].indent > line.indent else {
                result[key] = .null
                continue
            }
            index = lookahead

            let childIndent = lines[index].indent
            if lines[index].content.hasPrefix("- ") || lines[index].content == "-" {
                result[key] = .list(parseSequence(lines, index: &index, indent: childIndent))
            } else {
                result[key] = .mapping(parseMapping(lines, index: &index, indent: childIndent))
            }
        }

        return result
    }

    private static func parseSequence(
        _ lines: [Line],
        index: inout Int,
        indent: Int
    ) -> [YAMLValue] {
        var items: [YAMLValue] = []

        while true {
            skipNoise(lines, index: &index)
            guard index < lines.count else { break }

            let line = lines[index]
            guard line.indent >= indent else { break }
            guard line.content.hasPrefix("- ") || line.content == "-" else { break }

            let rest = line.content == "-"
                ? ""
                : String(line.content.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            index += 1

            if rest.isEmpty {
                // The item's content is on the following lines.
                var lookahead = index
                skipNoise(lines, index: &lookahead)
                if lookahead < lines.count, lines[lookahead].indent > line.indent {
                    index = lookahead
                    let childIndent = lines[index].indent
                    items.append(.mapping(parseMapping(lines, index: &index, indent: childIndent)))
                } else {
                    items.append(.null)
                }
                continue
            }

            if let separator = keySeparatorIndex(in: rest) {
                // `- key: value` starts a mapping whose remaining keys are
                // indented to where this key began.
                let key = String(rest[..<separator]).trimmingCharacters(in: .whitespaces)
                let inline = rest[rest.index(after: separator)...]
                    .trimmingCharacters(in: .whitespaces)

                var pairs: [String: YAMLValue] = [:]
                pairs[key] = inline.isEmpty ? .null : parseInlineScalar(inline)

                let continuationIndent = line.indent + 2
                var lookahead = index
                skipNoise(lines, index: &lookahead)
                if lookahead < lines.count, lines[lookahead].indent >= continuationIndent {
                    index = lookahead
                    let nested = parseMapping(
                        lines, index: &index, indent: lines[index].indent
                    )
                    pairs.merge(nested) { current, _ in current }
                }
                items.append(.mapping(pairs))
            } else {
                items.append(parseInlineScalar(rest))
            }
        }

        return items
    }

    /// Collect an indented literal (`|`) or folded (`>`) block.
    ///
    /// Everything indented past the key belongs to the block verbatim —
    /// including `#` lines, which are markdown headings here and not comments,
    /// and including blank lines, which are paragraph breaks in exported notes.
    ///
    /// A blank line carries no indentation to compare, so it cannot end the
    /// block; only the next line that is indented no deeper than the key does.
    /// Trailing blanks are then dropped, since they are an artifact of the
    /// separation between this key and the next rather than part of the value.
    private static func parseBlockScalar(
        _ lines: [Line],
        index: inout Int,
        parentIndent: Int,
        folded: Bool,
        chomp: Bool
    ) -> String {
        var collected: [String] = []
        var blockIndent: Int?

        while index < lines.count {
            let line = lines[index]

            if line.content.isEmpty {
                collected.append("")
                index += 1
                continue
            }

            guard line.indent > parentIndent else { break }

            // The first non-blank line fixes the block's own indentation; any
            // deeper indentation is content, such as a nested list or a code
            // fence inside a note.
            let base = blockIndent ?? line.indent
            blockIndent = base
            let extra = max(0, line.indent - base)
            collected.append(String(repeating: " ", count: extra) + line.content)
            index += 1
        }

        // Trailing blanks are an artifact of the gap before the next key, not
        // part of the value. A plain `|` keeps one of them as the trailing
        // newline YAML specifies; `|-`, which is what the exporter writes,
        // keeps none.
        while collected.last?.isEmpty == true {
            collected.removeLast()
        }
        if !chomp && !collected.isEmpty {
            collected.append("")
        }

        return collected.joined(separator: folded ? " " : "\n")
    }

    /// Interpret a scalar written on one line, including flow collections.
    private static func parseInlineScalar(_ text: String) -> YAMLValue {
        if text == "[]" { return .list([]) }
        if text == "{}" { return .mapping([:]) }
        if text == "~" || text.lowercased() == "null" { return .null }

        if text.hasPrefix("[") && text.hasSuffix("]") {
            let inner = String(text.dropFirst().dropLast())
            let items = splitFlow(inner).map { parseInlineScalar($0) }
            return .list(items)
        }

        if text.hasPrefix("{") && text.hasSuffix("}") {
            let inner = String(text.dropFirst().dropLast())
            var pairs: [String: YAMLValue] = [:]
            for element in splitFlow(inner) {
                guard let separator = keySeparatorIndex(in: element) else { continue }
                let key = String(element[..<separator]).trimmingCharacters(in: .whitespaces)
                let value = element[element.index(after: separator)...]
                    .trimmingCharacters(in: .whitespaces)
                pairs[unquote(key)] = parseInlineScalar(value)
            }
            return .mapping(pairs)
        }

        return .scalar(unquote(text))
    }

    /// Split a flow collection on commas that are not inside quotes or nesting.
    private static func splitFlow(_ text: String) -> [String] {
        var elements: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?

        for character in text {
            if let active = quote {
                current.append(character)
                if character == active { quote = nil }
                continue
            }
            switch character {
            case "\"", "'":
                quote = character
                current.append(character)
            case "[", "{":
                depth += 1
                current.append(character)
            case "]", "}":
                depth -= 1
                current.append(character)
            case "," where depth == 0:
                elements.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            default:
                current.append(character)
            }
        }

        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { elements.append(last) }
        return elements.filter { !$0.isEmpty }
    }

    private static func unquote(_ text: String) -> String {
        guard text.count >= 2 else { return text }

        if text.hasPrefix("\"") && text.hasSuffix("\"") {
            return String(text.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        if text.hasPrefix("'") && text.hasSuffix("'") {
            return String(text.dropFirst().dropLast())
                .replacingOccurrences(of: "''", with: "'")
        }
        return text
    }

    /// Index of the `:` separating a key from its value, ignoring colons inside
    /// quotes and any that are part of the value (`12:30`).
    ///
    /// YAML requires the separator to be a colon followed by a space or the end
    /// of the line, which is what distinguishes `time: 12:30` from a key.
    private static func keySeparatorIndex(in text: String) -> String.Index? {
        var quote: Character?
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]

            if let active = quote {
                if character == active { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ":" {
                let next = text.index(after: index)
                if next == text.endIndex || text[next] == " " { return index }
            }

            index = text.index(after: index)
        }
        return nil
    }
}
