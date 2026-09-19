//
//  ShellJSONTests.swift
//  Created by Claude on 9/18/26, at Vince's request.
//
//  `export --format mongo-shell-syntax` writes documents with `shellJSON(indent:)`. Its output has to be valid
//  mongo shell input, so these pin the exact text for each type.
//

import Foundation
import MongoKitten
import Testing

@Suite("Mongo shell syntax rendering")
struct ShellJSONTests {

    struct ScalarCase: CustomTestStringConvertible, Sendable {
        let description: String
        let render: @Sendable () -> String
        let expected: String

        var testDescription: String { description }
    }

    static let scalarCases: [ScalarCase] = [
        ScalarCase(description: "Int32 → NumberInt", render: { Int32(7).shellJSON() }, expected: "NumberInt(7)"),
        ScalarCase(description: "Int → NumberLong", render: { 42.shellJSON() }, expected: "NumberLong(42)"),
        ScalarCase(description: "negative Int", render: { (-3).shellJSON() }, expected: "NumberLong(-3)"),
        ScalarCase(description: "Double", render: { 1.25.shellJSON() }, expected: "1.25"),
        ScalarCase(description: "true", render: { true.shellJSON() }, expected: "true"),
        ScalarCase(description: "false", render: { false.shellJSON() }, expected: "false"),
        ScalarCase(description: "null", render: { Null().shellJSON() }, expected: "null"),
        ScalarCase(
            description: "ObjectId",
            render: { ObjectId("5f5b3c1e2a9d4b0012345678")!.shellJSON() },
            expected: #"ObjectId("5f5b3c1e2a9d4b0012345678")"#
        ),
        ScalarCase(
            description: "Date → ISODate in UTC with milliseconds",
            render: { Date(timeIntervalSince1970: 1_600_000_000.5).shellJSON() },
            expected: #"ISODate("2020-09-13T12:26:40.500+0000")"#
        )
    ]

    /// Catches: a type being written in a form the mongo shell reads back as a different type.
    @Test("Scalars render as their mongo shell constructors", arguments: scalarCases)
    func rendersScalars(_ scalarCase: ScalarCase) {
        #expect(scalarCase.render() == scalarCase.expected)
    }

    struct EscapeCase: CustomTestStringConvertible, Sendable {
        let input: String
        let expected: String

        var testDescription: String { input.debugDescription }
    }

    static let escapeCases: [EscapeCase] = [
        EscapeCase(input: "plain", expected: #""plain""#),
        EscapeCase(input: #"say "hi""#, expected: #""say \"hi\"""#),
        EscapeCase(input: #"C:\path"#, expected: #""C:\\path""#),
        EscapeCase(input: "line\nbreak", expected: #""line\nbreak""#),
        EscapeCase(input: "tab\there", expected: #""tab\there""#),
        EscapeCase(input: "carriage\rreturn", expected: #""carriage\rreturn""#),
        EscapeCase(input: "bell\u{07}", expected: #""bell\u0007""#),
        EscapeCase(input: "emoji 🚀 and ünïcödé", expected: #""emoji 🚀 and ünïcödé""#)
    ]

    /// Catches: an unescaped quote or control character producing a file the shell can't parse.
    @Test("Strings are quoted and escaped", arguments: escapeCases)
    func escapesStrings(_ escapeCase: EscapeCase) {
        #expect(escapeCase.input.shellJSON() == escapeCase.expected)
    }

    /// Catches: indentation or separators drifting inside nested documents and arrays.
    @Test("Nested documents and arrays are indented four spaces per level")
    func rendersNestedStructure() {
        let document: Document = [
            "_id": Int32(1),
            "tags": ["a", "b"] as Document,
            "address": ["city": "Denver", "zip": Int32(80202)] as Document
        ]

        #expect(document.shellJSON() == """
        {
            "_id" : NumberInt(1),
            "tags" : [
                "a",
                "b"
            ],
            "address" : {
                "city" : "Denver",
                "zip" : NumberInt(80202)
            }
        }
        """)
    }

    /// Catches: empty documents and arrays rendering as `{\n\n}` or similar invalid output.
    @Test("Empty documents and arrays render on one line")
    func rendersEmptyContainers() {
        #expect(Document().shellJSON() == "{ }")
        #expect(([] as Document).shellJSON() == "[ ]")
    }
}
