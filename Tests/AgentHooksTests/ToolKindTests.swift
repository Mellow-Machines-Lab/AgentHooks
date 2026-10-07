import Foundation
import Testing
@testable import AgentHooks
@testable import AgentHooksWire

/// A tool call's kind, from its name.
@Suite struct ToolKindTests {
    @Test func testEachAgentsToolsHaveTheirKind() {
        let cases: [(String, ToolKind)] = [
            ("Bash", .shell), ("shell", .shell), ("exec_command", .shell), ("local_shell", .shell),
            ("Edit", .edit), ("Write", .edit), ("MultiEdit", .edit), ("NotebookEdit", .edit),
            ("apply_patch", .edit), ("write_file", .edit), ("edit_file", .edit),
            ("Read", .read), ("Grep", .search), ("Glob", .search), ("LS", .search),
            ("WebFetch", .web), ("WebSearch", .web), ("Task", .subagent), ("Agent", .subagent),
            ("TodoWrite", .planning), ("ExitPlanMode", .planning), ("update_plan", .planning),
            ("mcp__github__create_issue", .mcp), ("SomethingNew", .other),
        ]
        for (tool, kind) in cases { #expect(ToolKind.of(tool) == kind, "\(tool)") }
        #expect(ToolKind.of(nil) == .other)
    }

    @Test func testNoToolHasTwoKinds() {
        let all = ToolKind.tools.values.flatMap { $0 }
        #expect(all.count == Set(all).count)
    }

    @Test func testAnEventAndACallSayTheirKind() {
        var e = AgentEvent(agent: .claude, kind: .tool, phase: .start, hook: "PreToolUse", session: "s1", at: 0)
        #expect(e.toolKind == nil)
        e.tool = "Grep"
        #expect(e.toolKind == .search)
    }

    /// An edit's topic comes from the files it touches, whichever agent's
    /// name for an edit it has.
    @Test func testEveryEditToolIsTaggedByItsFiles() {
        for tool in ToolKind.tools[.edit]! {
            #expect(Topic.tag(tool: tool, input: ["file_path": "README.md"]) == "docs", "\(tool)")
        }
    }
}
