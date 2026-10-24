import AgentHooks
import Foundation
import Testing

/// The agent's to-do list, from the fixtures through the line, the event
/// and the tracker: counts only, never an item's words, even with
/// `--keep-text`.
@Suite struct TodoTests {
    typealias Todos = SessionTracker.Todos

    /// Each change to the session's list, replaying `file` as `agent`.
    func replay(_ agent: String, _ file: String) throws -> [Todos?] {
        let url = WireTests.fixtures.appendingPathComponent(file)
        let tracker = SessionTracker()
        var seen: [Todos?] = [nil]
        var at: Int64 = 1_000_000
        for raw in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            at += 100
            let line = try #require(HookLine.extract(agent: agent, payload: Data(raw.utf8), ts: at, keepText: true))
            #expect(HookLine.decode(line.encoded()) == line)
            var words = line
            words.prompt = nil
            words.message = nil
            #expect(!String(decoding: words.encoded(), as: UTF8.self).contains("PRIVATE"), "no item's words")
            guard let event = Mapping.event(from: line) else { continue }
            #expect(try JSONDecoder().decode(AgentEvent.self, from: Data(event.jsonLine.utf8)) == event)
            tracker.handle(event)
            let todos = tracker.sessions.values.first?.todos
            if todos != seen.last! { seen.append(todos) }
        }
        return seen
    }

    /// Claude Code's tasks, one at a time, from each call's result: a
    /// denied update changes nothing, a deleted task is gone, the list
    /// lasts from turn to turn, and a task created once every one is
    /// completed starts a new list.
    @Test func claudesTasksAreCountedOneAtATime() throws {
        #expect(try replay("claude", "claude-code/synthetic/tasks.jsonl") == [
            nil, Todos(done: 0, total: 1), Todos(done: 0, total: 2), Todos(done: 0, total: 3), Todos(done: 1, total: 3),
            Todos(done: 1, total: 2), Todos(done: 2, total: 2), Todos(done: 0, total: 1),
        ])
    }

    /// Claude's older `TodoWrite` sends the whole list each time, which
    /// replaces it; a subagent's list is its own.
    @Test func claudesWholeListReplacesIt() throws {
        #expect(try replay("claude", "claude-code/synthetic/todowrite.jsonl") == [
            nil, Todos(done: 1, total: 3), Todos(done: 3, total: 3),
        ])
    }

    /// Codex's `update_plan` is a whole list too.
    @Test func codexsPlanIsAWholeList() throws {
        #expect(try replay("codex", "codex/synthetic/plan.jsonl") == [
            nil, Todos(done: 1, total: 3), Todos(done: 2, total: 3),
        ])
    }

    /// Only a task's ID with its shape, and only the four statuses, reach
    /// the line; a failed update changes nothing.
    @Test func onlyATasksIDAndStatusWithTheirShapeAreKept() throws {
        func line(_ tool: String, _ input: [String: Any], _ response: Any) throws -> HookLine {
            let raw = try JSONSerialization.data(withJSONObject: [
                "hook_event_name": "PostToolUse", "session_id": "s1", "tool_name": tool, "tool_input": input,
                "tool_response": response,
            ])
            return try #require(HookLine.extract(agent: "claude", payload: raw, ts: 1))
        }
        #expect(try line("TaskCreate", ["subject": "x"], ["task": ["id": "1\"; rm"]]).todoID == nil)
        #expect(try line("TaskCreate", ["subject": "x"], ["task": ["id": String(repeating: "1", count: 17)]]).todoID == nil)
        #expect(try line("TaskCreate", ["subject": "x"], ["task": ["id": 7]]).todoID == "7", "a number")
        #expect(try line("TaskCreate", ["subject": "x"], ["task": ["id": true]]).todoID == nil, "not a boolean")
        #expect(try line("TaskCreate", ["subject": "x"], ["task": ["id": -7]]).todoID == nil, "not a negative")
        let odd = try line("TaskUpdate", ["taskId": "1", "status": "PRIVATE_STATUS"], ["success": true])
        #expect(odd.todoID == "1" && odd.todoStatus == nil)
        #expect(try line("TaskUpdate", ["taskId": "1", "status": "completed"], ["success": false]).todoID == nil)
        #expect(HookLine.todoStatuses == ["pending", "in_progress", "completed", "deleted"])
        #expect(ToolKind.of("TaskCreate") == .planning && ToolKind.of("TaskUpdate") == .planning)
    }

    /// A prompt drops a list that's all done, so a later turn doesn't show
    /// it; one with work left lasts.
    @Test func aPromptDropsAListAllDone() {
        let tracker = SessionTracker()
        var at: Int64 = 0
        func list(_ done: Int, of total: Int) {
            at += 1
            var e = AgentEvent(agent: .claude, kind: .tool, phase: .start, hook: "PreToolUse", session: "s1", at: at)
            e.tool = "TodoWrite"
            e.todosDone = done
            e.todosTotal = total
            tracker.handle(e)
        }
        func prompt() {
            at += 1
            tracker.handle(AgentEvent(agent: .claude, kind: .turn, phase: .start, hook: "UserPromptSubmit", session: "s1", at: at))
        }
        list(2, of: 5)
        prompt()
        #expect(tracker.sessions["claude/s1"]?.todos == Todos(done: 2, total: 5), "work left")
        list(5, of: 5)
        #expect(tracker.sessions["claude/s1"]?.todos == Todos(done: 5, total: 5), "done, till the turn's over")
        prompt()
        #expect(tracker.sessions["claude/s1"]?.todos == nil, "the next turn has none")
    }

    /// Claude's tasks all done are dropped too, and the next task starts a
    /// list of its own.
    @Test func aPromptDropsTasksAllDone() {
        let tracker = SessionTracker()
        var at: Int64 = 0
        func task(_ tool: String, _ id: String, _ status: String?) {
            at += 1
            var e = AgentEvent(agent: .claude, kind: .tool, phase: .end, hook: "PostToolUse", session: "s1", at: at)
            e.tool = tool
            e.todoID = id
            e.todoStatus = status
            tracker.handle(e)
        }
        task("TaskCreate", "1", nil)
        task("TaskUpdate", "1", "completed")
        #expect(tracker.sessions["claude/s1"]?.todos == Todos(done: 1, total: 1))
        at += 1
        tracker.handle(AgentEvent(agent: .claude, kind: .turn, phase: .start, hook: "UserPromptSubmit", session: "s1", at: at))
        #expect(tracker.sessions["claude/s1"]?.todos == nil)
        task("TaskUpdate", "2", "in_progress")
        #expect(tracker.sessions["claude/s1"]?.todos == Todos(done: 0, total: 1), "not the old task")
    }

    /// The list goes with its session.
    @Test func theListEndsWithItsSession() {
        let tracker = SessionTracker()
        var e = AgentEvent(agent: .claude, kind: .tool, phase: .start, hook: "PreToolUse", session: "s1", at: 1)
        e.tool = "TodoWrite"
        e.todosDone = 0
        e.todosTotal = 2
        tracker.handle(e)
        #expect(tracker.sessions["claude/s1"]?.todos == Todos(done: 0, total: 2))
        tracker.handle(AgentEvent(agent: .claude, kind: .session, phase: .end, hook: "SessionEnd", session: "s1", at: 2))
        tracker.handle(AgentEvent(agent: .claude, kind: .session, phase: .start, hook: "SessionStart", session: "s1", at: 3))
        #expect(tracker.sessions["claude/s1"]?.todos == nil)
    }
}
