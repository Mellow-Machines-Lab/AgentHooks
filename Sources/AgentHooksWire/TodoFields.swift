import Foundation

/// The agent's to-do list, as counts: Claude Code's tasks one at a time
/// (`TaskCreate`, `TaskUpdate`), or a whole list each call (Claude's older
/// `TodoWrite`, Codex's `update_plan`). Nothing of an item but its status
/// leaves.
extension HookLine {
    /// The statuses a task can be given.
    public static let todoStatuses: Set<String> = ["pending", "in_progress", "completed", "deleted"]
    /// A task's ID: Claude numbers them.
    static let todoIDShape = TerminalTab.Shape(prefix: "", extra: "_-", max: 16)

    /// Picks the to-do fields out of a tool call's hook. A task is read
    /// from its `PostToolUse`, once it happened: a call you deny never
    /// changes the list. A whole list is read from its `PreToolUse`, which
    /// already has it all.
    mutating func readTodos(hook: String, input: Any?, response: Any?) {
        let input = input as? [String: Any] ?? [:]
        switch (tool, hook) {
        case ("TaskCreate", "PostToolUse"):
            let task = (response as? [String: Any])?["task"] as? [String: Any]
            guard let id = Self.todoID(task?["id"]) else { return }
            todoID = id
            todoStatus = "pending"
        case ("TaskUpdate", "PostToolUse"):
            guard (response as? [String: Any])?["success"] as? Bool != false, let id = Self.todoID(input["taskId"])
            else { return }
            todoID = id
            todoStatus = Self.string(input["status"]).flatMap { Self.todoStatuses.contains($0) ? $0 : nil }
        case ("TodoWrite", "PreToolUse"), ("update_plan", "PreToolUse"):
            guard let items = (input["todos"] ?? input["plan"]) as? [[String: Any]] else { return }
            todosTotal = items.count
            todosDone = items.filter { $0["status"] as? String == "completed" }.count
        default:
            break
        }
    }

    /// A task's ID, as text, when it has its shape.
    static func todoID(_ value: Any?) -> String? {
        let id = (value as? String) ?? count(value).map(String.init)
        return todoIDShape.matches(id) ? id : nil
    }
}
