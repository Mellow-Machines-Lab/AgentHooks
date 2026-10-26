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

    /// When the hook keeps text, any program says its name, and its
    /// subcommand or target when the first operand is shaped like one.
    @Test func testAWideWordNamesAnyProgramAndItsSubcommand() {
        let cases: [(String, String?)] = [
            ("make -C internal test", "make test"),
            ("FOO=1 make -j8 VERBOSE=1 fw-test", "make fw-test"),
            ("make", "make"),
            ("./internal/tools/boopctl sim --json", "boopctl sim"),
            ("firmware/tools/pio.sh test -e native", "pio.sh test"),
            (".build/debug/BoopTests", "BoopTests"),
            ("git frobnicate", "git frobnicate"),
            ("git -C agent-hooks log --oneline", "git log"),
            ("terraform plan -out x", "terraform plan"),
            ("grep -rn foo src", "grep"),
            ("cat README.md", "cat"),
            ("python3 tools/x.py build", "python"),
            ("./scripts/Run.sh Main.c", "Run.sh"),
            ("./a8F3kd92LmQ0xZ7pTe1 go", "run"),
        ]
        for (command, word) in cases { #expect(Program.word(command: command, wide: true) == word, "\(command)") }
        #expect(Program.isSubcommand("db:migrate") && !Program.isSubcommand("main.c") && !Program.isSubcommand("Test"))
    }

    /// Every program on the lists is there once: a repeat in a set literal
    /// stops the hook at launch.
    @Test func testTheListsHaveNoRepeats() {
        #expect(!Program.known.isEmpty && !Program.verbs.isEmpty && Program.known.count > 400)
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

    /// With `--keep-text` a call carries its glimpse and its wide word.
    @Test func testTheLineCarriesAGlimpseWhenItKeepsText() throws {
        let payload: [String: Any] = [
            "hook_event_name": "PostToolUse", "session_id": "s1", "tool_name": "Bash",
            "tool_input": ["command": "./tools/boopctl sim /Users/me/work/Core.swift"],
        ]
        let line = try #require(HookLine.extract(agent: "claude", json: payload, ts: 1, keepText: true, home: "/Users/me"))
        #expect(line.program == "boopctl sim" && line.glimpse == "Core.swift")
        #expect(HookLine.decode(line.encoded())?.glimpse == "Core.swift")
        let bare = try #require(HookLine.extract(agent: "claude", json: payload, ts: 1))
        #expect(bare.program == "run" && bare.glimpse == nil)
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
