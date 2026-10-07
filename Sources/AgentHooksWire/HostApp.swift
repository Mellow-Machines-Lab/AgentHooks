import Foundation

/// The app an agent runs in, from its hook's environment,
/// so an app can open the thread there. Only these few variables are read.
public enum HostApp {
    public static let claude = "com.anthropic.claudefordesktop"
    public static let codex = "com.openai.codex"

    /// The app's bundle ID: macOS gives a process an app launched the app's
    /// `__CFBundleIdentifier`, and its children keep it, so an agent in a
    /// terminal has the terminal's and one in the Claude app has Claude's.
    /// The Codex app's agent server has none, but its own marker.
    public static func bundleID(agent: String, env: [String: String]) -> String? {
        if let id = HookLine.string(env["__CFBundleIdentifier"]) { return id }
        if agent == "codex", env["CODEX_INTERNAL_ORIGINATOR_OVERRIDE"] != nil { return codex }
        return nil
    }

    /// The Claude app's ID for the session, `local_…`: the ID its links
    /// take. Claude Code's own `session_id` is another.
    public static func session(agent: String, env: [String: String]) -> String? {
        guard agent == "claude", let id = HookLine.string(env["CLAUDE_CODE_HOST_SESSION_ID"]),
              id.hasPrefix("local_") else { return nil }
        return id
    }
}
