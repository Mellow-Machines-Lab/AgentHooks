import Foundation
import Testing
@testable import AgentHooks
@testable import AgentHooksWire

/// A shell call's program, as a word from a closed list, and an edit's
/// file type.
@Suite struct ProgramTests {
    @Test func testTheFirstCommandThatDoesSomethingNamesTheCall() {
        let cases: [(String, String?)] = [
            ("grep -rn foo src", "grep"),
            ("cd app && rg -n 'x y' | head -5", "rg"),
            ("sed -n '1,80p' Sources/x.swift", "sed"),
            ("git -C agent-hooks log --oneline -3", "git log"),
            ("git --no-pager diff --stat", "git diff"),
            ("git frobnicate", "git"),
            ("npm i", "npm i"),
            ("gh pr create --fill", "gh pr"),
            ("python3 - <<'EOF'\nprint(1)\nEOF", "python"),
            ("python3.12 x.py", "python"),
            ("for f in *.md; do wc -l $f; done", "loop"),
            ("FOO=1 make -C internal test", "make"),
            ("export X=1; ./scripts/secret-deploy.sh --prod", "run"),
            ("bash -lc 'cargo test -q'", "cargo test"),
            ("sudo -u me brew upgrade", "brew upgrade"),
            ("echo done", "echo"),
            ("cd /tmp", "cd"),
            ("", nil),
        ]
        for (command, word) in cases { #expect(Program.word(command: command) == word, "\(command)") }
    }

    /// A program that isn't on the list says only `run`, unless it's
    /// yours: a script's name could say what the project is.
    @Test func testOnlyListedProgramsAreNamed() {
        #expect(Program.word(command: "./internal/tools/boopctl ping") == "run")
        #expect(Program.word(command: "./internal/tools/boopctl ping", own: ["boopctl"]) == "boopctl")
        #expect(Program.word(command: "acme-billing-export --all") == "run")
    }

    @Test func testOnlyShellCallsHaveAProgram() {
        #expect(Program.word(tool: "Bash", input: ["command": "git status"]) == "git status")
        #expect(Program.word(tool: "exec_command", input: ["cmd": ["rg", "-n", "x"]]) == "rg")
        #expect(Program.word(tool: "shell", input: ["command": ["bash", "-lc", "pytest -q"]]) == "pytest")
        #expect(Program.word(tool: "Read", input: ["file_path": "/x.swift"]) == nil)
        #expect(Program.word(tool: "Bash", input: nil) == nil)
    }

    @Test func testAnEditsFileType() {
        #expect(Program.fileType(tool: "Edit", input: ["file_path": "/w/Main.Swift"]) == "swift")
        #expect(Program.fileType(tool: "apply_patch", input: "*** Update File: docs/README.md\n@@") == "md")
        #expect(Program.fileType(tool: "Write", input: ["file_path": "/w/Makefile"]) == nil)
        #expect(Program.fileType(tool: "Write", input: ["file_path": "/w/x.reallylongext"]) == nil)
        #expect(Program.fileType(tool: "Bash", input: ["command": "vim x.swift"]) == nil)
    }

    /// `words.json` names your own programs.
    @Test func testYourOwnWords() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ah-words-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"words": ["boopctl", "./bin/just", ""]}"#.utf8).write(to: root.appendingPathComponent("words.json"))
        #expect(Program.ownWords(environment: ["AGENT_HOOKS_DIR": root.path]) == ["boopctl", "just"])
        #expect(Program.ownWords(environment: ["AGENT_HOOKS_DIR": "/nowhere"]) == [])
    }

    /// The hook line carries the word and the file type from the payload,
    /// and never the command.
    @Test func testTheLineCarriesTheWordAndNotTheCommand() throws {
        let payload: [String: Any] = [
            "hook_event_name": "PreToolUse", "session_id": "s1", "tool_name": "Bash",
            "tool_input": ["command": "git -C /Users/me/acme log --grep secret"],
        ]
        let line = try #require(HookLine.extract(agent: "claude", json: payload, ts: 1))
        #expect(line.program == "git log")
        let wire = String(decoding: line.encoded(), as: UTF8.self)
        #expect(wire.contains(#""program":"git log""#))
        #expect(!wire.contains("acme") && !wire.contains("secret"))
        let back = try #require(HookLine.decode(line.encoded()))
        #expect(back.program == "git log")

        let edit = try #require(HookLine.extract(agent: "claude", json: [
            "hook_event_name": "PostToolUse", "session_id": "s1", "tool_name": "Edit",
            "tool_input": ["file_path": "/w/a.swift", "old_string": "a", "new_string": "b"],
        ], ts: 1))
        #expect(edit.fileType == "swift" && edit.program == nil)
        #expect(HookLine.decode(edit.encoded())?.fileType == "swift")
    }
}
