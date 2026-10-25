import Foundation

/// The app an agent runs in, from its hook's environment,
/// so an app can open the thread there. Only a few variables are read,
/// and for a Claude Code session the Claude app drives by Remote Control,
/// one small file of Claude Code's.
public enum HostApp {
    public static let claude = "com.anthropic.claudefordesktop"
    public static let codex = "com.openai.codex"

    /// The app's bundle ID: macOS gives a process an app launched the app's
    /// `__CFBundleIdentifier`, and its children keep it, so an agent in a
    /// terminal has the terminal's and one in the Claude app has Claude's.
    /// The Codex app's agent server has none, but its own marker. A Claude
    /// Code session the Claude app drives by Remote Control
    /// (`CLAUDE_CODE_ENVIRONMENT_KIND` is `bridge`) runs in a terminal, but
    /// opens in the Claude app, so it's Claude's.
    public static func bundleID(agent: String, env: [String: String]) -> String? {
        if isBridge(agent: agent, env: env) { return claude }
        if let id = HookLine.string(env["__CFBundleIdentifier"]) { return id }
        if agent == "codex", env["CODEX_INTERNAL_ORIGINATOR_OVERRIDE"] != nil { return codex }
        return nil
    }

    /// The Claude app's ID for the session: the ID its links take. Claude
    /// Code's own `session_id` is another. In the Claude app it's
    /// `CLAUDE_CODE_HOST_SESSION_ID`, `local_…`. By Remote Control it's
    /// the remote session's, `session_…`, which Claude Code keeps as
    /// `bridgeSessionId` in its record of the agent's process (`record`).
    /// Only that one value of it is kept, when it has its shape, and only on
    /// `recordHooks`.
    public static func session(agent: String, env: [String: String], hook: String, pid: Int32? = nil,
                               home: String = NSHomeDirectory()) -> String? {
        guard agent == "claude" else { return nil }
        if let id = HookLine.string(env["CLAUDE_CODE_HOST_SESSION_ID"]), id.hasPrefix("local_") { return id }
        guard isBridge(agent: agent, env: env), recordHooks.contains(hook),
              let id = record(env: env, pid: pid, home: home)?["bridgeSessionId"] as? String,
              remoteShapes.contains(where: { $0.matches(id) }) else { return nil }
        return id
    }

    /// Claude Code's record of the agent's process, `sessions/<pid>.json`
    /// in its config folder (`CLAUDE_CONFIG_DIR`, else `~/.claude` in
    /// `home`), when the record is that process's. `pid` is the agent's
    /// (`AgentProcess`), else `CLAUDE_PID`. Only its first 64 KB are read.
    static func record(env: [String: String], pid: Int32?, home: String) -> [String: Any]? {
        guard let pid = pid ?? env["CLAUDE_PID"].flatMap({ Int32($0) }), pid > 0 else { return nil }
        let folder = HookLine.string(env["CLAUDE_CONFIG_DIR"], max: 1024) ?? home + "/.claude"
        guard let record = readObject(folder + "/sessions/\(pid).json", max: maxRecord),
              (record["pid"] as? NSNumber).map({ $0.int32Value == pid }) != false else { return nil }
        return record
    }

    /// The JSON object in the file at `path`, when it's no larger than `max`.
    static func readObject(_ path: String, max: Int) -> [String: Any]? {
        guard let file = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? file.close() }
        let data = file.readData(ofLength: max + 1)
        guard data.count <= max else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The hooks a Remote Control session's ID is sent on: those that
    /// start a session or a turn. The remote session's ID doesn't change
    /// in between, and an app keeps the last `app_session` it was sent.
    public static let recordHooks: Set<String> = ["SessionStart", "UserPromptSubmit"]
    /// The largest record read.
    static let maxRecord = 64 * 1024
    /// A remote session's ID: `session_` or `cse_`, then letters and digits.
    public static let remoteShapes = [TerminalTab.Shape(prefix: "session_", extra: "", max: 64),
                                      TerminalTab.Shape(prefix: "cse_", extra: "", max: 64)]

    /// A Claude Code session the Claude app drives by Remote Control.
    static func isBridge(agent: String, env: [String: String]) -> Bool {
        agent == "claude" && env["CLAUDE_CODE_ENVIRONMENT_KIND"] == "bridge"
    }
}
