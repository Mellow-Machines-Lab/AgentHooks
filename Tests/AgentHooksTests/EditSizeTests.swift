import AgentHooks
import Foundation
import Testing
@testable import AgentHooksWire

/// An edit's size: lines added and removed, and never its text.
@Suite struct EditSizeTests {
    func size(_ tool: String, _ input: Any?, _ response: Any? = nil) -> [Int]? {
        EditSize.of(tool: tool, input: input, response: response).map { [$0.added, $0.removed] }
    }

    @Test func testAnEditCountsTheLinesItReplacesLessTheLinesBothShare() {
        #expect(size("Edit", ["old_string": "a", "new_string": "b"]) == [1, 1])
        #expect(size("Edit", ["old_string": "a\nb\nc", "new_string": "a\nc"]) == [0, 1], "shared ends don't count")
        #expect(size("Edit", ["old_string": "a\n", "new_string": "a\nb\n"]) == [1, 0], "a final newline ends a line")
        #expect(size("Edit", ["old_string": "a\nb", "new_string": ""]) == [0, 2])
        #expect(size("Edit", ["old_string": "x"]) == nil, "no new_string, no size")
        #expect(size("MultiEdit", ["edits": [["old_string": "a", "new_string": "b\nc"],
                                             ["old_string": "d\ne", "new_string": ""]]]) == [2, 3])
        #expect(size("Write", ["content": "a\nb\nc\n"]) == [3, 0])
        #expect(size("Write", ["content": ""]) == [0, 0])
    }

    /// Claude's result has the patch it applied, which counts
    /// `replace_all` and a `Write` over a file exactly.
    @Test func testClaudesStructuredPatchWins() {
        let response: [String: Any] = ["structuredPatch": [["lines": [" a", "-b", "-c", "+d"]], ["lines": ["+e"]]]]
        #expect(size("Edit", ["old_string": "b", "new_string": "d"], response) == [2, 2])
        #expect(size("Write", ["content": "a\nd\ne"], response) == [2, 2])
    }

    @Test func testAPatchCountsItsPlusAndMinusLines() {
        let patch = "*** Begin Patch\n*** Update File: a.ts\n@@\n same\n-old\n--- old dashes\n+new\n*** Add File: b.ts\n+one\n+two\n*** Delete File: c.ts\n*** End Patch"
        #expect(size("apply_patch", ["input": patch]) == [3, 2])
        #expect(size("apply_patch", patch) == [3, 2], "a bare string")
        #expect(size("apply_patch", ["command": ["apply_patch", patch]]) == [3, 2], "an argv")
        #expect(size("apply_patch", ["other": 1]) == nil)
    }

    @Test func testOtherToolsHaveNoSize() {
        #expect(size("Bash", ["command": "rm -rf x"]) == nil)
        #expect(size("NotebookEdit", ["new_source": "x"]) == nil)
        #expect(EditSize.of(tool: nil, input: nil) == nil)
    }

    /// From the fixtures to events: a start says what the call will
    /// change, an end what it changed, a failure nothing; only the counts
    /// leave, which the line carries both ways.
    @Test func testTheFixturesEditsReachTheirEvents() throws {
        func events(_ agent: String, _ file: String) throws -> [AgentEvent] {
            let url = WireTests.fixtures.appendingPathComponent(file)
            return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap { raw in
                let line = try #require(HookLine.extract(agent: agent, payload: Data(raw.utf8), ts: 1))
                let wire = String(decoding: line.encoded(), as: UTF8.self)
                #expect(!wire.contains("PRIVATE"))
                #expect(HookLine.decode(line.encoded()) == line)
                return Mapping.event(from: line)
            }
        }
        let claude = try events("claude", "claude-code/synthetic/edits.jsonl")
        #expect(claude.map { $0.linesAdded.map { [$0] } ?? [] } == [[1], [1], [2], [2], [3], [2], []])
        #expect(claude.map { $0.linesRemoved.map { [$0] } ?? [] } == [[2], [2], [3], [3], [0], [1], []])
        let codex = try events("codex", "codex/synthetic/edits.jsonl")
        #expect(codex.map(\.linesAdded) == [4, 4])
        #expect(codex.map(\.linesRemoved) == [1, 1])

        let event = try #require(claude.first)
        #expect(event.jsonLine.contains(#""lines_added":1"#) && event.jsonLine.contains(#""lines_removed":2"#))
        #expect(try JSONDecoder().decode(AgentEvent.self, from: Data(event.jsonLine.utf8)) == event)
    }

    @Test func testAWireCountMustBeAWholeNumber() {
        func decoded(_ value: String) -> Int? {
            HookLine.decode(Data(#"{"agent":"claude","hook":"PostToolUse","session":"s","ts":1,"lines_added":\#(value)}"#.utf8))?.linesAdded
        }
        #expect(decoded("12") == 12)
        #expect(decoded("-1") == nil)
        #expect(decoded("true") == nil)
        #expect(decoded(#""12""#) == nil)
    }
}
