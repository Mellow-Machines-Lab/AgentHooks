import Foundation

/// A failed tool call's error as a short class:
/// `agent-hook` reads the error's text in memory and keeps only this. A
/// failed command's text is "Exit code N" then its own output, so the exit
/// code counts before the words a command's output often has.
public enum ToolError {
    public static func classify(_ text: String?) -> String {
        guard let text = text?.lowercased(), !text.isEmpty else { return "other" }
        if text.contains("timed out") || text.contains("timeout") { return "timeout" }
        if ["exit code", "exited", "non-zero", "status code"].contains(where: text.contains) { return "exit_code" }
        if ["denied", "not allowed", "rejected", "permission"].contains(where: text.contains) { return "denied" }
        return "other"
    }
}
