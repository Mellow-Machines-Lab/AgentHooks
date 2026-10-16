import Foundation

// An error leaves `agent-hook` only as a short, fixed class: the client
// reads the error's text in memory and keeps only the class.

/// A failed tool call's error class (`PostToolUseFailure`). A failed
/// command's text is "Exit code N" then its own output, so the exit code
/// counts before the words a command's output often has.
public enum ToolError {
    /// A command that exited with an error.
    public static let exitCode = "exit_code"
    /// A call that ran out of time.
    public static let timeout = "timeout"
    /// A request you denied.
    public static let denied = "denied"
    public static let other = "other"

    public static func classify(_ text: String?) -> String {
        guard let text = text?.lowercased(), !text.isEmpty else { return other }
        if text.contains("timed out") || text.contains("timeout") { return timeout }
        if ["exit code", "exited", "non-zero", "status code"].contains(where: text.contains) { return exitCode }
        if ["denied", "not allowed", "rejected", "permission"].contains(where: text.contains) { return denied }
        return other
    }
}

/// A failed turn's error class (`StopFailure`): `rate_limit`,
/// `overloaded`, `api_error`, `auth`, `timeout`, `network`,
/// `context_limit`, `billing` or `other`. A class classes as itself.
public enum TurnError {
    static let classes = ["rate_limit", "overloaded", "api_error", "auth", "timeout", "network", "context_limit", "billing"]

    /// Claude's errors that don't name their class.
    static let claude = [
        "server_error": "api_error", "invalid_request": "api_error", "model_not_found": "api_error",
        "max_output_tokens": "context_limit",
        "account_on_hold": "auth", "verification_required": "auth", "cloud_credential_error": "auth",
    ]

    public static func classify(_ text: String) -> String {
        let lowered = text.lowercased()
        if let known = claude[lowered] { return known }
        return classes.first { lowered.contains($0) } ?? "other"
    }
}
