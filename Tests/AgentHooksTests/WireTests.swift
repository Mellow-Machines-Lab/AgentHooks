import Foundation
import Testing
@testable import AgentHooksWire

@Suite struct WireTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    func payload(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    @Test func testKeepsOnlyTheMappedFields() throws {
        let raw = payload([
            "hook_event_name": "PreToolUse", "session_id": "s1", "cwd": "/w/landing", "tool_name": "Bash",
            "tool_input": ["command": "npm test -- SECRET_ARG"], "transcript_path": "/secret/t.jsonl",
        ])
        let line = try #require(HookLine.extract(agent: "claude", payload: raw, ts: 42))
        #expect(line == (HookLine(agent: "claude", hook: "PreToolUse", session: "s1", cwd: "/w/landing",
                                      tool: "Bash", topic: "tests", ts: 42)))
        let wire = String(decoding: line.encoded(), as: UTF8.self)
        #expect(!wire.contains("SECRET"))
        #expect(!wire.contains("transcript"))
        #expect(wire.hasSuffix("\n"))
        #expect(HookLine.decode(line.encoded()) == line)
    }

    /// The app the agent runs in, from the hook's
    /// environment: a launched app's bundle ID, which its children keep;
    /// the Codex app's server marks itself instead; and the Claude app's
    /// own ID for the session. Nothing else of the environment leaves.
    @Test func testTheHookSaysWhatAppTheAgentRunsIn() throws {
        let raw = payload(["hook_event_name": "Stop", "session_id": "s1"])
        func line(_ agent: String, _ env: [String: String]) throws -> HookLine {
            try #require(HookLine.extract(agent: agent, payload: raw, ts: 1, env: env))
        }
        let claude = try line("claude", ["__CFBundleIdentifier": "com.anthropic.claudefordesktop",
                                         "CLAUDE_CODE_HOST_SESSION_ID": "local_7db5", "HOME": "/Users/secret"])
        #expect(claude.app == HostApp.claude)
        #expect(claude.appSession == "local_7db5")
        let wire = String(decoding: claude.encoded(), as: UTF8.self)
        #expect(wire.contains(#""app_session":"local_7db5""#))
        #expect(!wire.contains("secret"))
        #expect(HookLine.decode(claude.encoded()) == claude)

        let terminal = try line("claude", ["__CFBundleIdentifier": "com.mitchellh.ghostty"])
        #expect(terminal.app == "com.mitchellh.ghostty")
        #expect(terminal.appSession == nil)
        try #expect((line("claude", ["CLAUDE_CODE_HOST_SESSION_ID": "cse_1"]).appSession) == nil, "only the app's local IDs")
        try #expect((line("codex", ["CODEX_INTERNAL_ORIGINATOR_OVERRIDE": "Codex"]).app) == HostApp.codex)
        try #expect((line("codex", ["__CFBundleIdentifier": "com.googlecode.iterm2",
                                          "CODEX_INTERNAL_ORIGINATOR_OVERRIDE": "Codex"]).app) == "com.googlecode.iterm2")
        try #expect((line("codex", ["CLAUDE_CODE_HOST_SESSION_ID": "local_1"]).appSession) == nil, "Claude's alone")
        try #expect((line("claude", [:]).app) == nil, "no environment, no app")
        // A payload too big to parse keeps them too.
        let cut = Data(#"{"hook_event_name":"Stop","session_id":"s1","x":"#.utf8)
        #expect((HookLine.extract(agent: "claude", payload: cut, ts: 1, env: ["__CFBundleIdentifier": "a.b"])?.app) == "a.b")
    }

    /// Every hook gets the thread's name: Claude's last
    /// title in the transcript, yours over its own, and Codex's from its
    /// session index. Nothing else of either file leaves.
    @Test func testEveryHookGetsTheThreadsName() throws {
        let dir = tempDir("threadname")
        defer { try? FileManager.default.removeItem(at: dir) }
        func jsonl(_ rows: [[String: Any]]) -> Data {
            Data(rows.map { String(decoding: payload($0), as: UTF8.self) + "\n" }.joined().utf8)
        }
        let transcript = dir.appendingPathComponent("t.jsonl")
        try jsonl([
            ["type": "custom-title", "customTitle": "Old name", "sessionId": "s"],
            ["type": "user", "message": ["content": "SECRET prompt"]],
            ["type": "custom-title", "customTitle": "Thread name on \"needs you\" screen", "sessionId": "s"],
            ["type": "ai-title", "aiTitle": "Made-up name", "sessionId": "s"],
            ["type": "assistant", "message": ["content": "SECRET reply"]],
        ]).write(to: transcript)
        let codexHome = dir.path
        func ask(_ agent: String, _ hook: String, session: String = "s", _ extra: [String: Any] = [:]) -> HookLine? {
            var object: [String: Any] = ["hook_event_name": hook, "session_id": session,
                                         "transcript_path": transcript.path, "tool_name": "Bash"]
            object.merge(extra) { $1 }
            return HookLine.extract(agent: agent, payload: payload(object), ts: 1, codexHome: codexHome)
        }
        let line = try #require(ask("claude", "PermissionRequest"))
        #expect(line.name == ("Thread name on \"needs you\" screen"))
        let wire = String(decoding: line.encoded(), as: UTF8.self)
        #expect(!wire.contains("SECRET"))
        #expect(HookLine.decode(line.encoded()) == line)
        #expect((ask("claude", "Notification", ["notification_type": "permission_prompt"])?.name) == ("Thread name on \"needs you\" screen"))
        for hook in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"] {
            #expect((ask("claude", hook)?.name) == ("Thread name on \"needs you\" screen"), "\(hook)")
        }
        #expect((HookLine.extract(agent: "claude", payload: payload(["hook_event_name": "PermissionRequest",
                                                                         "session_id": "s", "transcript_path": transcript.path]),
                                      ts: 1)?.name) == nil, "nor without a Codex home")

        // With no title of yours, Claude's own; with none at all, no name.
        try jsonl([["type": "ai-title", "aiTitle": "Made-up name"], ["type": "user"]]).write(to: transcript)
        #expect((ask("claude", "PermissionRequest")?.name) == ("Made-up name"))
        try jsonl([["type": "user"]]).write(to: transcript)
        #expect((ask("claude", "PermissionRequest")?.name) == nil)
        #expect((ask("claude", "PermissionRequest", ["transcript_path": "/nowhere/t.jsonl"])?.name) == nil)

        // A title far back in a long transcript is still found.
        var long = jsonl([["type": "custom-title", "customTitle": "Far back"]])
        let filler = jsonl([["type": "assistant", "text": String(repeating: "x", count: 1000)]])
        for _ in 0..<400 { long.append(filler) }
        try long.write(to: transcript)
        #expect((ask("claude", "PermissionRequest")?.name) == ("Far back"))
        #expect((ask("claude", "Stop")?.name) == ("Far back"))
        #expect((ask("claude", "PreToolUse")?.name) == nil, "a tool call's hook reads only the last 256 KB")

        try jsonl([
            ["id": "t1", "thread_name": "Old codex name"], ["id": "t2", "thread_name": "Another thread"],
            ["id": "t1", "thread_name": "Codex thread"],
        ]).write(to: dir.appendingPathComponent("session_index.jsonl"))
        #expect((ask("codex", "PermissionRequest", session: "t1")?.name) == ("Codex thread"))
        #expect((ask("codex", "PreToolUse", session: "t1")?.name) == ("Codex thread"))
        #expect((ask("codex", "PermissionRequest", session: "t3")?.name) == nil)
    }

    /// A title on the first complete line of a bounded tail
    /// remains readable; only a line cut by the window is discarded.
    @Test func testThreadNameTailPreservesALineAtTheWindowBoundary() throws {
        let dir = tempDir("threadname-boundary")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("t.jsonl")
        let title = #"{"type":"custom-title","customTitle":"Boundary name"}"# + "\n"
        let after = #"{"type":"assistant"}"# + "\n"
        let tail = title + after
        try ("older\n" + tail).write(to: file, atomically: true, encoding: .utf8)
        let aligned = try #require(ThreadName.tail(of: file.path, bytes: tail.utf8.count))
        #expect(String(decoding: aligned.data, as: UTF8.self) == tail)
        #expect(!aligned.whole)
        let cut = try #require(ThreadName.tail(of: file.path, bytes: tail.utf8.count - 1))
        #expect(String(decoding: cut.data, as: UTF8.self) == after)
        let whole = try #require(ThreadName.tail(of: file.path, bytes: 1024))
        #expect(String(decoding: whole.data, as: UTF8.self) == "older\n" + tail)
        #expect(whole.whole)
    }

    @Test func testStopFailureKeepsTheErrorClassAndNotificationItsType() throws {
        let failure = try #require(HookLine.extract(agent: "claude", payload: payload([
            "hook_event_name": "StopFailure", "session_id": "s", "error": "rate_limit",
            "last_assistant_message": "PRIVATE",
        ]), ts: 0))
        #expect(failure.error == "rate_limit")
        #expect(!(String(decoding: failure.encoded(), as: UTF8.self).contains("PRIVATE")))
        let note = try #require(HookLine.extract(agent: "claude", payload: payload([
            "hook_event_name": "Notification", "session_id": "s", "notification_type": "permission_prompt",
            "message": "Claude needs your permission to use Bash",
        ]), ts: 0))
        #expect(note.kind == "permission_prompt")
        #expect(!(String(decoding: note.encoded(), as: UTF8.self).contains("Bash")))
    }

    /// A failed call's error text never gets this far, only
    /// its class and whether you interrupted it.
    @Test func testPostToolUseFailureKeepsOnlyWhetherYouInterruptedIt() throws {
        let failure = try #require(HookLine.extract(agent: "claude", payload: payload([
            "hook_event_name": "PostToolUseFailure", "session_id": "s", "tool_name": "Bash",
            "tool_input": ["command": "npm test"], "error": "PRIVATE Command exited with non-zero status code 1",
            "is_interrupt": false,
        ]), ts: 0))
        #expect(failure == (HookLine(agent: "claude", hook: "PostToolUseFailure", session: "s", tool: "Bash", topic: "tests",
                                         toolError: "exit_code", ts: 0)))
        let wire = String(decoding: failure.encoded(), as: UTF8.self)
        #expect(!(wire.contains("PRIVATE") || wire.contains("interrupt")), "\(wire)")
        let interrupted = try #require(HookLine.extract(agent: "claude", payload: payload([
            "hook_event_name": "PostToolUseFailure", "session_id": "s", "tool_name": "Bash",
            "tool_input": ["command": "npm test"], "is_interrupt": true,
        ]), ts: 0))
        #expect(interrupted.interrupt)
        #expect(HookLine.decode(interrupted.encoded()) == interrupted)
        let succeeded = try #require(HookLine.extract(agent: "claude", payload: payload([
            "hook_event_name": "PostToolUse", "session_id": "s", "tool_name": "Bash", "is_interrupt": true,
        ]), ts: 0))
        #expect(!succeeded.interrupt, "only a failure can be an interrupt")
    }

    /// From every recorded payload, the only words that can
    /// reach the line are your prompt and the agent's last message, and
    /// only with `--keep-text`: no tool input or output, error text or
    /// transcript.
    @Test func testOnlyThePromptAndLastMessageFromAnyRecordedFixtureReachTheLine() throws {
        let files = FileManager.default.enumerator(at: WireTests.fixtures, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { ["json", "jsonl"].contains($0.pathExtension) }
        #expect(files.count > 3)
        var lines = 0, words = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let payloads = file.pathExtension == "json" ? [text] : text.split(separator: "\n").map(String.init)
            for raw in payloads where !raw.isEmpty {
                let plain = HookLine.extract(agent: "claude", payload: Data(raw.utf8), ts: 0)
                #expect(plain?.prompt == nil && plain?.message == nil, "no words without --keep-text")
                guard var line = HookLine.extract(agent: "claude", payload: Data(raw.utf8), ts: 0, keepText: true)
                else { continue }
                lines += 1
                if line.prompt != nil || line.message != nil { words += 1 }
                line.prompt = nil
                line.message = nil
                #expect(!(String(decoding: line.encoded(), as: UTF8.self).contains("PRIVATE")), "\(file.lastPathComponent)")
            }
        }
        #expect(lines > 40)
        #expect(words > 5, "prompts and last messages do get through")
    }

    /// With `--keep-text`, `UserPromptSubmit` keeps what you
    /// asked and `Stop` what the agent said last, each cut to 2,000
    /// characters.
    @Test func testThePromptAndLastMessageAreKeptWhenAsked() throws {
        let asked = payload(["hook_event_name": "UserPromptSubmit", "session_id": "s", "prompt": "fix the nav"])
        #expect(HookLine.extract(agent: "claude", payload: asked, ts: 0)?.prompt == nil, "not by default")
        let prompt = try #require(HookLine.extract(agent: "claude", payload: asked, ts: 0, keepText: true))
        #expect(prompt.prompt == ("fix the nav"))
        #expect(HookLine.decode(prompt.encoded()) == prompt)
        let long = String(repeating: "y", count: 3000)
        let stop = try #require(HookLine.extract(agent: "codex", payload: payload([
            "hook_event_name": "Stop", "session_id": "s", "last_assistant_message": long,
        ]), ts: 0, keepText: true))
        #expect(stop.message?.count == HookLine.maxMessage)
        #expect(HookLine.decode(stop.encoded()) == stop)
    }

    /// A subagent's hooks carry the parent's session plus
    /// its `agent_id` and `agent_type`, which the line keeps, the id even
    /// from a payload cut off at the cap.
    @Test func testASubagentsIDIsKept() throws {
        let raw = payload([
            "hook_event_name": "PreToolUse", "session_id": "s1", "agent_id": "a1b2", "agent_type": "general-purpose",
            "tool_name": "Read", "tool_input": ["file_path": "/w/x.swift"],
        ])
        let line = try #require(HookLine.extract(agent: "claude", payload: raw, ts: 0))
        #expect(line.agentID == "a1b2")
        #expect(HookLine.decode(line.encoded()) == line)
        #expect(line.agentType == ("general-purpose"))
        let main = try #require(HookLine.extract(agent: "claude", payload: payload(["hook_event_name": "Stop", "session_id": "s1"]), ts: 0))
        #expect(main.agentID == nil)
        #expect(!(String(decoding: main.encoded(), as: UTF8.self).contains("agent_id")))
        let big = String(repeating: "x", count: 300_000)
        let cut = Data(#"{"session_id": "s1", "agent_id": "a1b2", "hook_event_name": "PostToolUse", "tool_name": "Read", "tool_response": "\#(big)"}"#.utf8).prefix(256 * 1024)
        #expect((HookLine.extract(agent: "claude", payload: Data(cut), ts: 0)?.agentID) == "a1b2")
    }

    /// `SubagentStop` keeps which subagent ended, never its
    /// last message or transcript, and a payload cut off at the cap by a
    /// long last message still says which subagent.
    @Test func testSubagentStopKeepsOnlyWhichSubagentEnded() throws {
        let raw = payload([
            "hook_event_name": "SubagentStop", "session_id": "s1", "cwd": "/w/landing", "stop_hook_active": false,
            "agent_id": "a1", "agent_type": "Explore", "agent_transcript_path": "/PRIVATE/agent-a1.jsonl",
            "last_assistant_message": "PRIVATE found 3 issues",
        ])
        let line = try #require(HookLine.extract(agent: "claude", payload: raw, ts: 3))
        #expect(line == (HookLine(agent: "claude", hook: "SubagentStop", session: "s1", cwd: "/w/landing",
                                      agentType: "Explore", agentID: "a1", ts: 3)))
        #expect(!(String(decoding: line.encoded(), as: UTF8.self).contains("PRIVATE")))
        let big = String(repeating: "x", count: 300_000)
        let cut = Data(#"{"session_id": "s1", "hook_event_name": "SubagentStop", "agent_id": "a1", "last_assistant_message": "\#(big)"}"#.utf8).prefix(256 * 1024)
        let salvaged = try #require(HookLine.extract(agent: "claude", payload: Data(cut), ts: 0))
        #expect(salvaged.hook == "SubagentStop")
        #expect(salvaged.agentID == "a1")
    }

    /// `SessionStart` keeps its `source`, and every hook
    /// its `permission_mode`, even from a payload cut off at the cap.
    @Test func testSessionStartsSourceAndThePermissionModeAreKept() throws {
        for agent in ["claude-code", "codex"] {
            let raw = try Data(contentsOf: Self.fixtures.appendingPathComponent("\(agent)/2026-09-08/SessionStart-1.json"))
            let line = try #require(HookLine.extract(agent: agent == "codex" ? "codex" : "claude", payload: raw, ts: 1))
            #expect(line.source == "startup", "\(agent)")
            #expect(HookLine.decode(line.encoded()) == line)
        }
        let raw = payload(["hook_event_name": "PreToolUse", "session_id": "s1", "permission_mode": "plan", "tool_name": "Read",
                           "tool_input": ["file_path": "/w/x.swift"], "source": "not a start"])
        let line = try #require(HookLine.extract(agent: "claude", payload: raw, ts: 1))
        #expect(line.mode == "plan")
        #expect(line.source == nil, "only a start has a source")
        #expect(String(decoding: line.encoded(), as: UTF8.self).contains(#""mode":"plan""#))
        #expect(HookLine.decode(line.encoded()) == line)
        let big = String(repeating: "x", count: 300_000)
        let cut = Data(#"{"session_id": "s1", "permission_mode": "plan", "hook_event_name": "PostToolUse", "tool_name": "Read", "tool_response": "\#(big)"}"#.utf8).prefix(256 * 1024)
        #expect((HookLine.extract(agent: "claude", payload: Data(cut), ts: 0)?.mode) == "plan")
    }

    /// A shell command that only looks at files is
    /// `inspect`, so an app can show it as only looking: every command in it
    /// reads (`rg`, `grep`, `cat`, `sed -n`, `find`, `ls`, `head`, `tail`,
    /// `wc`, `nl`, `sort`, `uniq`, `cut`) or neither reads nor changes
    /// anything (`cd`, `echo`), and none writes a file. A check comes first.
    @Test func testShellReadsAreInspect() {
        let reads = [
            "rg -n 'func tick' app/", "grep -rn TODO .", "cat Package.swift", "sed -n '1,80p' app/Core.swift",
            "find . -name '*.swift'", "ls -la", "head -50 README.md", "tail -n 20 log.txt", "wc -l *.swift",
            "nl -ba app/Core.swift | sed -n '120,200p'", "cd app && rg -l Core", "cat a.md; echo ---; cat b.md",
            "rg foo 2>/dev/null | sort | uniq -c", "grep -n 'make test' Makefile", "ls node_modules/.bin/jest",
            "bash -lc 'rg -n foo src'", "sed -ne 's/a/b/p' x",
        ]
        for command in reads {
            #expect(Topic.inspects(command: command), "\(command)")
            #expect((Topic.tag(tool: "Bash", input: ["command": command])) == "inspect", "\(command)")
        }
        let others = [
            "sed -i 's/a/b/' x", "sed 's/a/b/' x", "sed -n -i 's/a/b/p' x", "find . -name '*.o' -delete",
            "find . -exec rm {} \\;", "cat > /tmp/x.py <<'EOF'\nprint(1)\nEOF", "echo hi > notes.txt",
            "rg foo > out.txt", "cat a >> b", "ls && git status", "cd app", "echo hello", "git log | head",
            "cat x | python3 -c 'import sys'", "tee out.txt", "",
        ]
        for command in others { #expect(!(Topic.inspects(command: command)), "\(command)") }
        #expect((Topic.tag(tool: "Bash", input: ["command": "swift test 2>&1 | tail -20"])) == "tests", "a check first")
        #expect((Topic.tag(tool: "Bash", input: ["command": "make 2>&1 | grep -i error"])) == "build")
        #expect((Topic.tag(tool: "shell", input: ["command": ["bash", "-lc", "nl -ba x | sed -n '1,40p'"]])) == "inspect", "Codex's argv")
        #expect((Topic.tag(tool: "exec_command", input: ["cmd": "rg -n foo"])) == "inspect")
        #expect((Topic.tag(tool: "Read", input: ["file_path": "/w/x.swift"])) == nil, "a tool without a command")
        #expect((Topic.tag(tool: "Edit", input: ["file_path": "/w/x.swift", "command": "cat x"])) == nil, "an edit is an edit")
    }

    @Test func testPayloadWithoutHookNameOrSessionIsDropped() {
        #expect((HookLine.extract(agent: "claude", payload: payload(["session_id": "s"]), ts: 0)) == nil)
        #expect((HookLine.extract(agent: "claude", payload: payload(["hook_event_name": "Stop"]), ts: 0)) == nil)
        #expect((HookLine.extract(agent: "claude", payload: Data("not json".utf8), ts: 0)) == nil)
    }

    @Test func testAPayloadCutOffAtTheCapStillGivesTheEvent() throws {
        let big = String(repeating: "x", count: 300_000)
        // Agents send the small fields first, as the recorded fixtures show.
        let raw = Data(#"{"session_id": "s9", "cwd": "/w/jetpack", "hook_event_name": "PostToolUse", "tool_name": "Read", "tool_response": "\#(big)"}"#.utf8)
        let cut = raw.prefix(256 * 1024)
        let line = try #require(HookLine.extract(agent: "codex", payload: Data(cut), ts: 1))
        #expect(line.hook == "PostToolUse")
        #expect(line.session == "s9")
        #expect(line.topic == nil)
    }

    /// A cut that lands inside a multibyte character still
    /// gives the event (a Write of 300 KB of accented text).
    @Test func testACutInsideACharacterStillGivesTheEvent() throws {
        let big = String(repeating: "é", count: 200_000)
        let raw = Data(#"{"session_id": "s9", "hook_event_name": "PostToolUse", "tool_name": "Write", "tool_input": {"content": "\#(big)"}}"#.utf8)
        for cut in [256 * 1024, 256 * 1024 - 1] {
            let line = try #require(HookLine.extract(agent: "claude", payload: Data(raw.prefix(cut)), ts: 1), "\(cut)")
            #expect(line.hook == "PostToolUse")
            #expect(line.tool == "Write")
        }
    }

    @Test func testCodexShellArgvAndPatchesGetTopics() {
        #expect((Topic.tag(tool: "shell", input: ["command": ["bash", "-lc", "cargo test -q"]])) == "tests")
        #expect((Topic.tag(tool: "exec_command", input: ["cmd": "pnpm run build"])) == "build")
        // An argv is one command already: its words are never split again.
        #expect((Topic.tag(tool: "container.exec", input: ["command": ["make", "test"]])) == "tests")
        #expect((Topic.tag(tool: "shell", input: ["command": ["echo", "make test && vercel"]])) == nil)
        #expect((Topic.tag(tool: "shell", input: ["command": ["sh", "-c", "cd app && make test"]])) == "tests")
        #expect((Topic.tag(tool: "shell", input: [:])) == nil)
        #expect((Topic.tag(tool: "apply_patch", input: ["input": "*** Begin Patch\n*** Update File: docs/intro.md\n@@"])) == "docs")
        #expect((Topic.tag(tool: "apply_patch", input: ["input": "*** Begin Patch\n*** Update File: src/a.swift\n@@"])) == nil)
    }

    @Test func testTopicTable() {
        let cases: [(String, String?)] = [
            ("pytest -x tests/", "tests"), ("npm test", "tests"), ("npx jest --watch=false", "tests"),
            ("vitest run", "tests"), ("go test ./...", "tests"), ("cargo test", "tests"),
            ("swift test --filter Foo", "tests"), ("cd app && make test", "tests"), ("./gradlew test", "tests"),
            ("make", "build"), ("make -j8 all", "build"), ("npm run build", "build"), ("cargo build --release", "build"),
            ("swift build", "build"), ("xcodebuild -scheme App", "build"), ("tsc -p .", "build"),
            ("vercel --prod", "deploy"), ("fly deploy", "deploy"), ("kubectl apply -f k8s/", "deploy"),
            ("terraform apply -auto-approve", "deploy"),
            ("ls -la", nil), ("cat Makefile", nil), ("git status", nil), ("echo testing", nil), ("", nil),
        ]
        for (command, topic) in cases {
            #expect((Topic.tag(command: command)) == topic, "\(command)")
        }
    }

    /// The topic comes from what the command runs, after
    /// `VAR=value`, `cd … &&` and wrappers, never from a word in its
    /// arguments, quoted text or a heredoc. A failing grep for "make test"
    /// must not fail a turn, and a commit message about pytest must not
    /// hide one. Real commands, as agents write them.
    @Test func testTopicComesFromWhatTheCommandRuns() {
        let cases: [(String, String?)] = [
            // What runs.
            ("cd app && swift test", "tests"), ("FOO=1 npm test", "tests"), ("CI=true npx vitest run", "tests"),
            ("uv run pytest -q tests/test_api.py", "tests"), ("python3 -m pytest -x", "tests"),
            ("bundle exec rspec spec/models", "tests"), ("make -C firmware test", "tests"),
            ("swift test 2>&1 | tail -20", "tests"), ("timeout 600 make fw-test", "tests"),
            ("env -i PATH=/usr/bin make test", "tests"), ("(cd app && cargo test --release)", "tests"),
            ("xcodebuild -scheme App -destination 'platform=macOS' test", "tests"),
            ("bash -lc 'cd app && go test ./...'", "tests"), ("make build && make test", "tests"),
            ("bash --norc -c \"pytest -x\"", "tests"), ("zsh --no-rcs -c 'npm test'", "tests"),
            ("bash --rcfile x -c 'go test ./...'", "tests"), ("bash -o pipefail -c 'make test'", "tests"),
            ("cd /Users/me/src/landing && npm run build 2>&1 | tail -40", "build"),
            ("make 2>&1 | grep -i error", "build"), ("sudo make install", "build"),
            ("git push heroku main", "deploy"), ("npx vercel --prod", "deploy"),
            ("gcloud app deploy --quiet", "deploy"), ("make test && vercel --prod", "deploy"),
            // Inside shell syntax, behind a wrapper's flag value, or run by
            // a package manager or a container.
            ("for i in 1 2 3; do make test || break; done", "tests"), ("if [ -f Makefile ]; then make test; fi", "tests"),
            ("{ make test; } 2>&1 | tee out.log", "tests"), ("! make test", "tests"),
            ("while ! make fw-test; do sleep 5; done", "tests"), ("timeout -s KILL 600 make test", "tests"),
            ("sudo -u ci make test", "tests"), ("env -u DEBUG cargo test", "tests"), ("yarn jest --ci", "tests"),
            ("pnpm vitest run", "tests"), ("bun x vitest", "tests"), ("yarn test --watch=false", "tests"),
            ("bun test", "tests"), ("bun run build", "build"), ("yarn tsc --noEmit", "build"),
            ("docker compose run --rm web pytest", "tests"), ("docker exec -it api make test", "tests"),
            ("docker compose -f compose.test.yml run -e CI=1 web bundle exec rspec", "tests"),
            ("docker build -t app .", "build"),
            // Only mentioned.
            ("grep -rn \"make webcam-test\" README.md documentation/", nil), ("grep -n 'make test' Makefile", nil),
            ("git commit -m \"run pytest in CI\"", nil), ("python3 -c \"import pytest\"", nil),
            ("which tsc", nil), ("ls node_modules/.bin/jest", nil), ("rg -l 'cargo test' docs", nil),
            ("echo \"now run: make test\"", nil), ("go run ./cmd/test", nil),
            ("git log --oneline | grep -i vercel", nil), ("cat package.json | jq .scripts.test", nil),
            ("git commit -F - <<'EOF'\nmake test passes again\n\nCo-Authored-By: x\nEOF", nil),
            ("git commit -m \"$(cat <<'EOF'\nFix: pytest runs in CI\nEOF\n)\"", nil),
            ("cat > /tmp/run.sh <<EOF\nnpm test\nEOF\nchmod +x /tmp/run.sh", nil),
            ("command -v pytest", nil), ("command -v make >/dev/null || brew install make", nil), ("type jest", nil),
            ("hash tsc", nil), ("for f in *.test.js; do echo $f; done", nil), ("docker compose up -d", nil),
            ("if grep -q 'make test' Makefile; then echo yes; fi", nil),
        ]
        for (command, topic) in cases {
            #expect((Topic.tag(command: command)) == topic, "\(command)")
        }
        #expect((Topic.tag(tool: "shell", input: ["command": ["grep", "-rn", "make test", "docs"]])) == "inspect", "a search, not tests")
        #expect((Topic.tag(tool: "shell", input: ["command": ["zsh", "-c", "npm run build"]])) == "build")
        #expect((Topic.tag(tool: "shell", input: ["command": ["bash", "--noprofile", "--norc", "-c", "cargo test"]])) == "tests")
    }

    @Test func testEditsToMarkdownOrTextAreDocs() {
        #expect((Topic.tag(tool: "Edit", input: ["file_path": "/w/README.md"])) == "docs")
        #expect((Topic.tag(tool: "Write", input: ["file_path": "/w/notes.txt"])) == "docs")
        #expect((Topic.tag(tool: "Edit", input: ["file_path": "/w/main.swift"])) == nil)
        #expect((Topic.tag(tool: "Read", input: ["file_path": "/w/README.md"])) == nil)
        #expect((Topic.tag(tool: nil, input: nil)) == nil)
    }

    /// `topics.json` adds command patterns to the check topics,
    /// which keep their order, so a project's own test script is tests.
    @Test func testExtraTopicPatterns() throws {
        let extra = ["tests": [["just", "check"], ["./scripts/ci.sh"]], "build": [["just"]], "chores": [["git", "gc"]]]
        let input: (String) -> [String: Any] = { ["command": $0] }
        #expect(Topic.tag(tool: "Bash", input: input("just check")) == nil, "not without them")
        #expect(Topic.tag(tool: "Bash", input: input("just check"), extra: extra) == "tests", "tests beat build")
        #expect(Topic.tag(tool: "Bash", input: input("just"), extra: extra) == "build")
        #expect(Topic.tag(tool: "Bash", input: input("cd x && ./scripts/ci.sh --fast"), extra: extra) == "tests")
        #expect(Topic.tag(tool: "Bash", input: input("git gc"), extra: extra) == nil, "only the check topics")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ah-topics-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"tests": [["just", "check"]], "bad": 3}"#.utf8).write(to: root.appendingPathComponent("topics.json"))
        #expect(Topic.extraPatterns(environment: ["AGENT_HOOKS_DIR": root.path]) == ["tests": [["just", "check"]]])
        #expect(Topic.extraPatterns(environment: ["AGENT_HOOKS_DIR": "/nowhere"]) == [:])
    }

    @Test func testSendingToAMissingSocketGivesUpAtOnce() {
        let start = Date()
        #expect(!(HookSocket.send(Data("x\n".utf8), to: "/tmp/ah-missing-\(getpid()).sock")))
        #expect(Date().timeIntervalSince(start) < 0.05)
    }

    /// The hook gives up if the app
    /// is slow to accept, and connecting and writing share one 50 ms budget,
    /// so the write never starts a fresh one.
    @Test func testConnectingAndWritingShareOneDeadline() throws {
        // An app that listens but never reads: a big line fills the socket
        // buffer, so the write has to wait for room.
        let path = "/tmp/ah-slow-\(getpid()).sock"
        unlink(path)
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(server >= 0)
        defer {
            close(server)
            unlink(path)
        }
        var address = try #require(HookSocket.unixAddress(path))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(bound == 0)
        #expect((listen(server, 8)) == 0)
        let big = Data(count: 1 << 20)

        // A budget already spent (on connecting) leaves the write none.
        var start = Date()
        #expect(!(HookSocket.send(big, to: path, deadline: DispatchTime.now().uptimeNanoseconds)))
        #expect(Date().timeIntervalSince(start) < 0.045, "no fresh 50 ms for the write")

        // The whole send gives up within its budget, give or take scheduling.
        start = Date()
        #expect(!(HookSocket.send(big, to: path, timeoutMs: 50)))
        #expect(Date().timeIntervalSince(start) < 0.5)

        // A line that fits goes straight through, with time to spare.
        #expect(HookSocket.send(Data("x\n".utf8), to: path))
    }

    /// Apps listen in one folder, and the client sends to every
    /// socket there, or to `AGENT_HOOKS_SOCKET` alone.
    @Test func testTheSocketFolderAndItsDestinations() throws {
        #expect(HookSocket.directory(environment: ["HOME": "/Users/x"]) == "/Users/x/.agent-hooks/sockets")
        #expect(HookSocket.directory(environment: ["HOME": "/Users/x", "AGENT_HOOKS_DIR": "/tmp/ah"]) == "/tmp/ah/sockets")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ah-\(getpid())-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: root) }
        let env = ["AGENT_HOOKS_DIR": root.path]
        #expect(HookSocket.destinations(environment: env) == [], "no folder, nobody listening")
        let app = root.appendingPathComponent("app.sock").path
        try HookSocket.register(app, as: "one", environment: env)
        try HookSocket.register(app, as: "one", environment: env)  // twice is once
        let dir = HookSocket.directory(environment: env)
        try Data().write(to: URL(fileURLWithPath: dir + "/notes.txt"))
        FileManager.default.createFile(atPath: dir + "/two.sock", contents: nil)
        #expect(HookSocket.destinations(environment: env) == [dir + "/one.sock", dir + "/two.sock"])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: dir + "/one.sock") == app)
        #expect(HookSocket.destinations(environment: env.merging(["AGENT_HOOKS_SOCKET": "/tmp/t.sock"]) { $1 }) == ["/tmp/t.sock"])
    }

    /// The socket folder is this user's alone (0700). The
    /// client sends nowhere while others can write to it, and registering
    /// tightens a folder an older version left open.
    @Test func testTheSocketFolderIsPrivate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ah-\(getpid())-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: root) }
        let env = ["AGENT_HOOKS_DIR": root.path]
        let dir = HookSocket.directory(environment: env)
        try HookSocket.register(root.appendingPathComponent("app.sock").path, as: "one", environment: env)
        func mode() throws -> Int {
            try (FileManager.default.attributesOfItem(atPath: dir)[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }
        #expect(try mode() == 0o700)
        #expect(HookSocket.isPrivate(dir))
        #expect(HookSocket.destinations(environment: env) == [dir + "/one.sock"])

        chmod(dir, 0o777)
        #expect(!HookSocket.isPrivate(dir))
        #expect(HookSocket.destinations(environment: env) == [], "others can add a link: send nowhere")
        chmod(dir, 0o755)
        #expect(HookSocket.isPrivate(dir), "readable by others is an older folder, still safe to send to")
        try HookSocket.register(root.appendingPathComponent("app.sock").path, as: "one", environment: env)
        #expect(try mode() == 0o700, "registering tightens it")

        let link = root.appendingPathComponent("elsewhere").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: dir)
        #expect(!HookSocket.isPrivate(link), "a link to a folder isn't the folder")
    }

    /// A tool error's text becomes one of four classes.
    /// A failed command's text is Claude's "Exit code N"
    /// then the command's own output, which may say denied, rejected or
    /// permission; it's still a command that failed.
    @Test func testToolErrorClasses() {
        #expect((ToolError.classify("Command exited with non-zero status code 1")) == "exit_code")
        #expect((ToolError.classify("Command timed out after 2m")) == "timeout")
        #expect((ToolError.classify("Permission to use Bash has been denied.")) == "denied")
        #expect((ToolError.classify("Exit code 128\n ! [rejected] main -> main (fetch first)")) == "exit_code")
        #expect((ToolError.classify("Exit code 255\ngit@github.com: Permission denied (publickey).")) == "exit_code")
        #expect((ToolError.classify("Exit code 1\nFAILED tests/test_permissions.py::test_admin_can_edit")) == "exit_code")
        #expect((ToolError.classify("something odd")) == "other")
        #expect(ToolError.classify(nil) == "other")
    }

    /// The tool call's ID and a subagent's type are kept; they carry no content.
    @Test func testKeepsTheToolUseIDAndAgentType() throws {
        let line = try #require(HookLine.extract(agent: "claude", payload: payload([
            "hook_event_name": "PreToolUse", "session_id": "s", "tool_name": "Read", "tool_use_id": "toolu_9",
            "agent_id": "a1", "agent_type": "Explore", "tool_input": ["file_path": "/PRIVATE"],
        ]), ts: 0))
        #expect(line.toolUseID == "toolu_9")
        #expect(line.agentType == "Explore")
        #expect(HookLine.decode(line.encoded()) == line)
        #expect(!(String(decoding: line.encoded(), as: UTF8.self).contains("PRIVATE")))
    }
}
