/// What kind of work a tool call is, from its name: the one
/// place that knows Claude Code's and Codex's tool names, so an app maps a
/// kind to its own words and never keeps a list of tools itself.
public enum ToolKind: String, Codable, Sendable, CaseIterable {
    /// Runs a command: Claude's `Bash`, Codex's `shell`, `exec_command`
    /// or `local_shell`. What the command does is the call's topic.
    case shell
    /// Changes files.
    case edit
    /// Reads one file.
    case read
    /// Looks through files.
    case search
    /// Looks something up on the web.
    case web
    /// Hands work to a subagent.
    case subagent
    /// Writes or leaves a plan.
    case planning
    /// A tool from an MCP server (`mcp__…`).
    case mcp
    /// Anything else, or no tool name.
    case other

    /// The kind for a tool's name, exactly as its hook reports it.
    public static func of(_ tool: String?) -> ToolKind {
        guard let tool else { return .other }
        if tool.hasPrefix("mcp__") { return .mcp }
        return names[tool] ?? .other
    }

    /// Every tool name this knows, by kind.
    public static let tools: [ToolKind: Set<String>] = [
        .shell: ["Bash", "shell", "exec_command", "local_shell"],
        .edit: ["Edit", "Write", "MultiEdit", "NotebookEdit", "apply_patch", "edit", "write", "write_file", "edit_file"],
        .read: ["Read"],
        .search: ["Grep", "Glob", "LS"],
        .web: ["WebFetch", "WebSearch"],
        .subagent: ["Task", "Agent"],
        .planning: ["TodoWrite", "ExitPlanMode", "update_plan"],
    ]

    static let names: [String: ToolKind] = {
        var out: [String: ToolKind] = [:]
        for (kind, tools) in tools {
            for tool in tools { out[tool] = kind }
        }
        return out
    }()
}
