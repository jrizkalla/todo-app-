import Testing
import Foundation
@testable import TODO

/// The zip container and the YAML codec, tested apart from the database so a
/// failure points at the format layer rather than the import logic.
struct ArchiveFormatTests {

    // MARK: Zip

    @Test func zipRoundTripsEntries() throws {
        let entries = [
            Zip.Entry(path: "manifest.yaml", data: Data("formatVersion: 1".utf8)),
            Zip.Entry(path: "todos/a.yaml", data: Data("title: Buy milk".utf8)),
        ]

        let archive = try ZipWriter.build(entries)
        let read = try ZipReader.entries(in: archive)

        #expect(read.count == 2)
        #expect(read.first { $0.path == "todos/a.yaml" }?.data == Data("title: Buy milk".utf8))
    }

    /// Compressible content must survive the deflate path specifically — the
    /// short entries above are stored uncompressed.
    @Test func zipRoundTripsCompressibleContent() throws {
        let body = String(repeating: "notes: the same line over and over\n", count: 500)
        let archive = try ZipWriter.build([
            Zip.Entry(path: "todos/big.yaml", data: Data(body.utf8))
        ])

        // Worth asserting: a round trip would pass even if compression silently
        // fell back to stored for everything.
        #expect(archive.count < body.utf8.count / 2)

        let read = try ZipReader.entries(in: archive)
        #expect(String(data: read[0].data, encoding: .utf8) == body)
    }

    @Test func zipRejectsNonArchiveData() {
        let notAZip = Data(repeating: 0x41, count: 512)
        #expect(throws: (any Error).self) { try ZipReader.entries(in: notAZip) }
    }

    /// Real archives carry a CRC per entry; readers that check it reject a zero.
    @Test func crc32MatchesKnownValue() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func zipHandlesEmptyAndBinaryEntries() throws {
        let binary = Data((0..<256).map { UInt8($0 % 256) })
        let archive = try ZipWriter.build([
            Zip.Entry(path: "empty.yaml", data: Data()),
            Zip.Entry(path: "blob.bin", data: binary),
        ])

        let read = try ZipReader.entries(in: archive)
        #expect(read.first { $0.path == "empty.yaml" }?.data.isEmpty == true)
        #expect(read.first { $0.path == "blob.bin" }?.data == binary)
    }

    // MARK: YAML writing and parsing

    @Test func yamlRoundTripsScalars() {
        let document = YAMLWriter.document([
            ("title", .scalar("Buy milk")),
            ("sortIndex", .scalar("3")),
            ("isProject", .scalar("false")),
        ])
        let parsed = YAMLParser.parse(document)

        #expect(parsed.value(forKey: "title")?.stringValue == "Buy milk")
        #expect(parsed.value(forKey: "sortIndex")?.intValue == 3)
        #expect(parsed.value(forKey: "isProject")?.boolValue == false)
    }

    /// Notes are markdown and routinely multi-line; a block scalar has to come
    /// back byte-identical or exported notes degrade on every round trip.
    @Test func yamlRoundTripsMultilineText() {
        let notes = "# Heading\n\nA line.\n\n```swift\nlet x = 1\n```"
        let document = YAMLWriter.document([("notes", .scalar(notes))])
        let parsed = YAMLParser.parse(document)

        #expect(parsed.value(forKey: "notes")?.stringValue == notes)
    }

    /// Text that looks like other YAML constructs must not be reinterpreted.
    @Test func yamlQuotesAmbiguousScalars() {
        let cases = ["true", "123", "- not a list", "value: with colon", "#hashtag", ""]

        for text in cases {
            let document = YAMLWriter.document([("title", .scalar(text))])
            let parsed = YAMLParser.parse(document)
            #expect(
                parsed.value(forKey: "title")?.stringValue == text,
                "‘\(text)’ did not survive the round trip"
            )
        }
    }

    @Test func yamlRoundTripsLists() {
        let document = YAMLWriter.document([
            ("detailedSummary", .list([.scalar("First"), .scalar("Second")]))
        ])
        let parsed = YAMLParser.parse(document)

        #expect(parsed.value(forKey: "detailedSummary")?.stringList == ["First", "Second"])
    }

    @Test func yamlRoundTripsNestedMappings() {
        let document = YAMLWriter.document([
            ("fingerprint", .mapping([
                "instructions": .scalar("Be brief"),
                "todos": .list([.scalar("One")]),
            ]))
        ])
        let parsed = YAMLParser.parse(document)
        let fingerprint = parsed.value(forKey: "fingerprint")

        #expect(fingerprint?.value(forKey: "instructions")?.stringValue == "Be brief")
        #expect(fingerprint?.value(forKey: "todos")?.stringList == ["One"])
    }

    // MARK: Parser leniency

    /// A malformed line costs its own field and nothing else.
    @Test func parserSkipsGarbageLinesAndKeepsTheRest() {
        let text = """
        title: Kept
        this line has no colon at all
        !!! nonsense
        sortIndex: 7
        """
        let parsed = YAMLParser.parse(text)

        #expect(parsed.value(forKey: "title")?.stringValue == "Kept")
        #expect(parsed.value(forKey: "sortIndex")?.intValue == 7)
    }

    @Test func parserIgnoresCommentsAndDocumentMarkers() {
        let parsed = YAMLParser.parse("""
        ---
        # a comment
        title: Visible
        ...
        """)

        #expect(parsed.value(forKey: "title")?.stringValue == "Visible")
    }

    @Test func parserAcceptsFlowCollections() {
        let parsed = YAMLParser.parse("tags: [one, two, three]")
        #expect(parsed.value(forKey: "tags")?.stringList == ["one", "two", "three"])
    }

    /// Nothing the parser is handed should be able to throw or trap.
    @Test func parserSurvivesNonsense() {
        let inputs = ["", "::::", "[[[[", "\n\n\n", "- - - -", String(repeating: "a: ", count: 200)]
        for input in inputs {
            _ = YAMLParser.parse(input)
        }
    }

    // MARK: Value coercion

    @Test func valuesCoerceAcrossTypes() {
        #expect(YAMLValue.scalar("3.0").intValue == 3)
        #expect(YAMLValue.scalar("42").doubleValue == 42)
        #expect(YAMLValue.scalar("yes").boolValue == true)
        #expect(YAMLValue.scalar("OFF").boolValue == false)
        #expect(YAMLValue.scalar("1").boolValue == true)
    }

    /// A field that was a scalar in an older export and a list in a newer one
    /// reads either way.
    @Test func valuesCoerceBetweenScalarAndList() {
        #expect(YAMLValue.scalar("only").stringList == ["only"])
        #expect(YAMLValue.list([.scalar("a"), .scalar("b")]).stringValue == "a\nb")
    }

    @Test func uuidsParseWithoutHyphens() {
        let uuid = UUID()
        let bare = uuid.uuidString.replacingOccurrences(of: "-", with: "")

        #expect(YAMLValue.scalar(bare).uuidValue == uuid)
        #expect(YAMLValue.scalar(uuid.uuidString).uuidValue == uuid)
        #expect(YAMLValue.scalar("not-a-uuid").uuidValue == nil)
    }

    @Test func datesParseInSeveralFormats() {
        let inputs = [
            "2026-08-11T14:30:00.000Z",
            "2026-08-11T14:30:00Z",
            "2026-08-11 14:30:00",
            "2026-08-11",
            "1786article", // nonsense, must not crash
        ]
        // Only the last is expected to fail; the rest must all produce a date.
        for input in inputs.dropLast() {
            #expect(YAMLValue.scalar(input).dateValue != nil, "‘\(input)’ did not parse")
        }
        #expect(YAMLValue.scalar(inputs.last!).dateValue == nil)
    }

    /// Renamed fields resolve through case- and separator-insensitive lookup.
    @Test func keyLookupIgnoresCaseAndSeparators() {
        let parsed = YAMLParser.parse("due_date: 2026-08-11")

        #expect(parsed.value(forKey: "dueDate")?.dateValue != nil)
        #expect(parsed.value(forKey: "DUEDATE")?.dateValue != nil)
    }

    @Test func anyKeyPrefersTheFirstPresentSpelling() {
        let parsed = YAMLParser.parse("name: From name field")

        #expect(
            parsed.value(forAnyKey: ["title", "name", "text"])?.stringValue == "From name field"
        )
    }
}
