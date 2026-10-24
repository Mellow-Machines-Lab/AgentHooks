import AgentHooks
import Foundation
import Testing

/// A Claude Code session the Claude app drives by Remote Control runs in a
/// terminal, but opens in the Claude app, by the remote session's ID from
/// Claude Code's record of the agent's process.
@Suite struct RemoteControlTests {
    static let remote = "session_01AbCdEfGhIjKlMnOpQrSt12"
    let pid: Int32 = 4242

    /// The hook's environment by Remote Control, from a terminal.
    func env(_ config: URL) -> [String: String] {
        ["__CFBundleIdentifier": "com.mitchellh.ghostty", "TERM_PROGRAM": "ghostty", "TMUX_PANE": "%3",
         "CLAUDE_CODE_ENVIRONMENT_KIND": "bridge", "CLAUDE_PID": "\(pid)", "CLAUDE_CONFIG_DIR": config.path]
    }

    /// A config folder with `record` as the process's record, removed after `body`.
    func withConfig(_ record: String?, _ body: (URL) throws -> Void) throws {
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("rc-\(UUID().uuidString)")
        let sessions = config.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: config) }
        if let record { try Data(record.utf8).write(to: sessions.appendingPathComponent("\(pid).json")) }
        try body(config)
    }

    func record(pid: Int32 = 4242, bridge: String = remote) -> String {
        #"{"pid":\#(pid),"sessionId":"PRIVATE_SESSION_9101","cwd":"/Users/PRIVATE_HOME_9102/src","startedAt":1791707031722,"#
            + #""kind":"interactive","entrypoint":"cli","name":"PRIVATE_NAME_9103","bridgeSessionId":"\#(bridge)"}"#
    }

    func line(_ env: [String: String], process: AgentProcess? = nil, hook: String = "UserPromptSubmit") throws
        -> HookLine {
        let raw = Data(#"{"hook_event_name":"\#(hook)","session_id":"s1","cwd":"/w/landing"}"#.utf8)
        return try #require(HookLine.extract(agent: "claude", payload: raw, ts: 1, env: env, process: process,
                                             home: "/nonexistent"))
    }

    func target(_ line: HookLine) throws -> ThreadLink.Target? {
        let tracker = SessionTracker()
        tracker.handle(try #require(Mapping.event(from: line)))
        return ThreadLink.target(try #require(tracker.sessions["claude/s1"]?.thread))
    }

    @Test func itOpensInTheClaudeAppByTheRemoteSession() throws {
        try withConfig(record()) { config in
            for process in [AgentProcess(pid: pid, started: 1), nil] {
                let line = try line(env(config), process: process)
                #expect(line.app == HostApp.claude, "not the terminal's")
                #expect(line.appSession == Self.remote)
                let wire = String(decoding: line.encoded(), as: UTF8.self)
                #expect(!wire.contains("PRIVATE"), "nothing else of the record leaves")
                #expect(HookLine.decode(line.encoded()) == line)
                #expect(try target(line) == .url("claude://code/\(Self.remote)"))
            }
        }
    }

    /// The record is read only on hooks that start a session or a turn,
    /// so a tool call reads no file; the tracker keeps the ID it was sent,
    /// and the app the hook's environment says comes on every hook.
    @Test func itsRecordIsReadOnlyAsASessionOrTurnStarts() throws {
        #expect(HostApp.recordHooks == ["SessionStart", "UserPromptSubmit"])
        try withConfig(record()) { config in
            for hook in ["SessionStart", "UserPromptSubmit"] {
                #expect(try line(env(config), hook: hook).appSession == Self.remote, "\(hook)")
            }
            let tracker = SessionTracker()
            tracker.handle(try #require(Mapping.event(from: try line(env(config)))))
            for hook in ["PreToolUse", "PostToolUse", "Notification", "Stop"] {
                let call = try line(env(config), hook: hook)
                #expect(call.appSession == nil, "\(hook)")
                #expect(call.app == HostApp.claude, "\(hook)")
                if let event = Mapping.event(from: call) { tracker.handle(event) }
            }
            #expect(tracker.sessions["claude/s1"]?.appSession == Self.remote)
        }
    }

    /// Without the remote session's ID, the Claude app is still where it
    /// opens, not the terminal's tab.
    @Test func withoutItsRecordItOpensTheClaudeApp() throws {
        let bad = [record(bridge: "session_01x&y=1"), record(bridge: "local_1"), record(pid: 99), "{not json",
                   record() + String(repeating: " ", count: 64 * 1024)]
        for record in bad + [nil] {
            try withConfig(record) { config in
                let line = try line(env(config))
                #expect(line.app == HostApp.claude)
                #expect(line.appSession == nil, "\(record?.prefix(60) ?? "no record")")
                #expect(try target(line) == .app(HostApp.claude))
            }
        }
        try withConfig(record(bridge: "cse_011dymZfyfjWLQ46emnXxTYQ")) { config in
            let line = try line(env(config))
            #expect(line.appSession == "cse_011dymZfyfjWLQ46emnXxTYQ")
        }
    }

    /// Only by Remote Control: the same record with an ordinary terminal
    /// session, or Codex, is never read.
    @Test func otherSessionsAreAsBefore() throws {
        try withConfig(record()) { config in
            var plain = env(config)
            plain["CLAUDE_CODE_ENVIRONMENT_KIND"] = nil
            let terminal = try line(plain)
            #expect(terminal.app == "com.mitchellh.ghostty")
            #expect(terminal.appSession == nil)
            #expect(try target(terminal) == .terminal(app: "com.mitchellh.ghostty", tab: try #require(terminal.terminal)))
            #expect(HostApp.session(agent: "codex", env: env(config), hook: "SessionStart", pid: pid) == nil)
            #expect(HostApp.bundleID(agent: "codex", env: env(config)) == "com.mitchellh.ghostty")
        }
    }
}
