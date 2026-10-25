import Foundation

/// The one line `agent-hook` sends to the apps listening: only the fields
/// below. Tool input and file contents never get this far; the
/// topic tag is worked out from the tool input in memory, then the input
/// is dropped with the rest of the payload. The only words it can keep are
/// your prompt (`UserPromptSubmit`) and the agent's last message
/// (`Stop`), and only with `--keep-text`.
public struct HookLine: Equatable, Sendable {
    /// `claude` or `codex`, from `agent-hook <agent>`.
    public var agent: String
    /// The agent's hook name, e.g. `PreToolUse`.
    public var hook: String
    public var session: String
    public var cwd: String?
    public var tool: String?
    public var topic: String?
    /// A shell call's program, as a word from a closed list (`Program`):
    /// `grep`, `git log`, `run`. Never its arguments.
    public var program: String?
    /// An edit's file type, its first file's extension (`swift`).
    public var fileType: String?
    /// `StopFailure`'s error as a short class (`TurnError`), e.g.
    /// `rate_limit`; the error's text never leaves `agent-hook`.
    public var error: String?
    /// `Notification`'s type, e.g. `permission_prompt`.
    public var kind: String?
    /// `PostToolUseFailure` because you interrupted the call.
    public var interrupt: Bool
    /// `PostToolUseFailure`'s error as a short class (`ToolError`); the
    /// error's text never leaves `agent-hook`.
    public var toolError: String?
    /// The tool call's ID, to pair its `PreToolUse` with its result.
    public var toolUseID: String?
    /// Claude's `agent_type`: what kind of subagent the hook fired in.
    public var agentType: String?
    /// Claude's `agent_id`: which subagent the hook fired in. Claude gives a
    /// subagent's hooks the parent's session, so this tells siblings apart;
    /// nil for the main agent.
    public var agentID: String?
    /// `Stop`'s `last_assistant_message`: what the agent said as it
    /// finished, up to `maxMessage` characters, with `--keep-text`.
    public var message: String?
    /// `UserPromptSubmit`'s `prompt`: what you asked, up to `maxMessage`
    /// characters, with `--keep-text`. Never a prompt the agent's harness
    /// typed for you (`typedForYou`).
    public var prompt: String?
    /// The thread's name as its agent's app shows it (`ThreadName`), on
    /// every hook that finds one.
    public var name: String?
    /// `SessionStart`'s `source`: `startup`, `resume`, `clear` or `compact`.
    public var source: String?
    /// The agent's `permission_mode` (Claude's `default`, `plan`,
    /// `acceptEdits`…), on every hook that carries one.
    public var mode: String?
    /// The app the agent runs in, by bundle ID (`HostApp`): the Claude or
    /// Codex app, or the terminal: where the thread can be opened.
    public var app: String?
    /// The Claude app's own ID for the session, which its links open:
    /// `local_…`, or by Remote Control the remote session's `session_…`,
    /// only as a session or turn starts (`HostApp.recordHooks`); nil
    /// outside the Claude app.
    public var appSession: String?
    /// Where in a terminal the agent runs (`TerminalTab`), so its tab can be
    /// opened; nil outside a terminal.
    public var terminal: TerminalTab?
    /// An edit tool call's size (`EditSize`), on `PreToolUse` (what it will
    /// change) and `PostToolUse` (what it changed): lines added and
    /// removed. Only the counts; the text stays in `agent-hook`.
    public var linesAdded: Int?
    public var linesRemoved: Int?
    /// The agent's process (`AgentProcess`), on every hook that finds it.
    public var process: AgentProcess?
    /// A task the agent created or updated (`TaskCreate`, `TaskUpdate`),
    /// on its `PostToolUse`: its ID and its new status (`todoStatuses`),
    /// none when an update changed something else.
    public var todoID: String?
    public var todoStatus: String?
    /// The agent's whole to-do list (`TodoWrite`, `update_plan`), on its
    /// `PreToolUse`: how many items are completed, of how many.
    public var todosDone: Int?
    public var todosTotal: Int?
    /// When the hook ran, in milliseconds.
    public var ts: Int64

    public init(agent: String, hook: String, session: String, cwd: String? = nil, tool: String? = nil,
                topic: String? = nil, program: String? = nil, fileType: String? = nil, error: String? = nil, kind: String? = nil, interrupt: Bool = false,
                toolError: String? = nil, toolUseID: String? = nil, agentType: String? = nil,
                agentID: String? = nil, message: String? = nil, prompt: String? = nil, name: String? = nil,
                source: String? = nil, mode: String? = nil, app: String? = nil, appSession: String? = nil,
                terminal: TerminalTab? = nil, linesAdded: Int? = nil, linesRemoved: Int? = nil,
                process: AgentProcess? = nil, todoID: String? = nil, todoStatus: String? = nil, todosDone: Int? = nil,
                todosTotal: Int? = nil, ts: Int64) {
        self.agent = agent
        self.hook = hook
        self.session = session
        self.cwd = cwd
        self.tool = tool
        self.topic = topic
        self.program = program
        self.fileType = fileType
        self.error = error
        self.kind = kind
        self.interrupt = interrupt
        self.toolError = toolError
        self.toolUseID = toolUseID
        self.agentType = agentType
        self.agentID = agentID
        self.message = message
        self.prompt = prompt
        self.name = name
        self.source = source
        self.mode = mode
        self.app = app
        self.appSession = appSession
        self.terminal = terminal
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.process = process
        self.todoID = todoID
        self.todoStatus = todoStatus
        self.todosDone = todosDone
        self.todosTotal = todosTotal
        self.ts = ts
    }

    /// Longest value kept for any field, so a strange payload can't make the
    /// line large.
    static let maxField = 200
    /// Longest prompt or last assistant message kept.
    public static let maxMessage = 2000

    /// Whether a `UserPromptSubmit`'s prompt is a notice the agent's
    /// harness typed for you, not something you asked: Claude Code hands
    /// a background task's end to the agent as a prompt that opens with
    /// `<task-notification>`, naming the command. It's dropped, as a
    /// command would be, and the turn starts as one with no prompt.
    public static func typedForYou(_ prompt: String) -> Bool {
        prompt.drop { $0.isWhitespace }.hasPrefix("<task-notification>")
    }

    /// The hooks that come with every tool call. They look for the thread's
    /// name only near the end of its transcript, where it almost always is,
    /// so a thread that has none doesn't cost a wide read on every call.
    static let perCall: Set<String> = ["PreToolUse", "PostToolUse", "PostToolUseFailure"]

    /// Picks the kept fields out of a raw hook payload. Returns nil when the
    /// payload has no hook name or session. With `codexHome`, the line also
    /// gets the thread's name (`ThreadName`); without it, neither agent's
    /// is looked up. `env` is the hook's environment, which says what app
    /// the agent runs in (`HostApp`, with `home`, where Claude Code keeps
    /// its config folder unless `env` says, and the Claude app its records)
    /// and where in a terminal (`TerminalTab`, with `tty`, the agent's
    /// controlling terminal).
    /// `process` is the agent's (`AgentProcess.find`). `keepText` keeps
    /// your prompt and the agent's last message; `topics`
    /// adds command patterns to the topic tags (`Topic.extraPatterns`),
    /// and `words` programs to the ones a call may name
    /// (`Program.ownWords`).
    public static func extract(agent: String, payload: Data, ts: Int64, codexHome: String? = nil,
                               env: [String: String] = [:], tty: String? = nil, process: AgentProcess? = nil,
                               home: String = NSHomeDirectory(), keepText: Bool = false,
                               topics: [String: [[String]]] = [:], words: Set<String> = []) -> HookLine? {
        let json = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        guard var line = json.flatMap({ extract(agent: agent, json: $0, ts: ts, keepText: keepText, topics: topics,
                                                words: words) })
            ?? salvage(agent: agent, payload: payload, ts: ts) else { return nil }
        if let codexHome, let json {
            line.name = ThreadName.find(agent: agent, json: json, session: line.session, codexHome: codexHome,
                                        env: env, pid: process?.pid, home: home, wide: !perCall.contains(line.hook))
        }
        line.app = HostApp.bundleID(agent: agent, env: env)
        line.appSession = HostApp.session(agent: agent, env: env, hook: line.hook, pid: process?.pid, home: home)
        line.terminal = TerminalTab.from(env: env, tty: tty)
        line.process = process
        return line
    }

    /// The kept fields of a parsed payload, without the thread's name or
    /// anything from the hook's environment.
    public static func extract(agent: String, json: [String: Any], ts: Int64, keepText: Bool = false,
                               topics: [String: [[String]]] = [:], words: Set<String> = []) -> HookLine? {
        guard let hook = string(json["hook_event_name"]) ?? string(json["hookEventName"]),
              let session = string(json["session_id"]) ?? string(json["thread_id"]) ?? string(json["conversation_id"])
        else { return nil }
        var line = HookLine(agent: agent, hook: hook, session: session, cwd: string(json["cwd"]),
                            agentType: string(json["agent_type"]), agentID: string(json["agent_id"]),
                            mode: string(json["permission_mode"]), ts: ts)
        switch hook {
        case "SessionStart":
            line.source = string(json["source"])
        case "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest":
            line.tool = string(json["tool_name"])
            line.toolUseID = string(json["tool_use_id"])
            if hook != "PermissionRequest" {
                line.topic = Topic.tag(tool: line.tool, input: json["tool_input"], extra: topics)
                line.program = Program.word(tool: line.tool, input: json["tool_input"], own: words)
                line.fileType = Program.fileType(tool: line.tool, input: json["tool_input"])
            }
            if hook == "PreToolUse" || hook == "PostToolUse",
               let size = EditSize.of(tool: line.tool, input: json["tool_input"],
                                      response: hook == "PostToolUse" ? json["tool_response"] : nil) {
                line.linesAdded = size.added
                line.linesRemoved = size.removed
            }
            if hook == "PreToolUse" || hook == "PostToolUse" {
                line.readTodos(hook: hook, input: json["tool_input"], response: json["tool_response"])
            }
            line.interrupt = hook == "PostToolUseFailure" && json["is_interrupt"] as? Bool == true
            if hook == "PostToolUseFailure" && !line.interrupt {
                line.toolError = ToolError.classify(json["error"] as? String)
            }
        case "UserPromptSubmit":
            if keepText { line.prompt = string(json["prompt"], max: maxMessage).flatMap { typedForYou($0) ? nil : $0 } }
        case "Stop":
            if keepText { line.message = string(json["last_assistant_message"], max: maxMessage) }
        case "StopFailure":
            line.error = (string(json["error"]) ?? string(json["error_type"])).map(TurnError.classify)
        case "Notification":
            line.kind = string(json["notification_type"])
        default:
            break
        }
        return line
    }

    /// A payload over the 256 KB cap is cut off and won't parse. The fields we
    /// need come early, so pick them out of the prefix; the topic is lost.
    /// The cut can land inside a character, so bad bytes are replaced
    /// rather than losing the line.
    static func salvage(agent: String, payload: Data, ts: Int64) -> HookLine? {
        let text = String(decoding: payload, as: UTF8.self)
        func field(_ name: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: "\"\(name)\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.){0,400})\"")
            else { return nil }
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  let value = Range(match.range(at: 1), in: text) else { return nil }
            return string(String(text[value]))
        }
        guard let hook = field("hook_event_name"), let session = field("session_id") else { return nil }
        var line = HookLine(agent: agent, hook: hook, session: session, cwd: field("cwd"),
                            agentID: field("agent_id"), mode: field("permission_mode"), ts: ts)
        if ["PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest"].contains(hook) {
            line.tool = field("tool_name")
            line.toolUseID = field("tool_use_id")
        }
        return line
    }

    static func string(_ value: Any?, max: Int = maxField) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return s.count > max ? String(s.prefix(max)) : s
    }

    // MARK: Wire form

    /// The optional text fields, by their names on the wire.
    static let wire: [(key: String, field: WritableKeyPath<HookLine, String?> & Sendable)] = [
        ("cwd", \.cwd), ("tool", \.tool), ("topic", \.topic), ("program", \.program), ("file_type", \.fileType),
        ("error", \.error), ("kind", \.kind),
        ("tool_error", \.toolError), ("tool_use_id", \.toolUseID), ("agent_type", \.agentType),
        ("agent_id", \.agentID), ("message", \.message), ("prompt", \.prompt), ("name", \.name),
        ("source", \.source), ("mode", \.mode), ("app", \.app), ("app_session", \.appSession),
        ("todo_id", \.todoID), ("todo_status", \.todoStatus),
    ]

    /// The terminal's fields, by their names on the wire, which are its
    /// `Codable` keys.
    static let terminalWire: [(key: String, field: WritableKeyPath<TerminalTab, String?> & Sendable)] = [
        ("program", \.program), ("iterm_session", \.itermSession), ("term_session", \.termSession), ("tty", \.tty),
        ("tmux_pane", \.tmuxPane), ("tmux_socket", \.tmuxSocket),
    ]

    /// A non-negative whole number, or nil.
    static func count(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let n = number.intValue
        return n >= 0 ? n : nil
    }

    public func encoded() -> Data {
        var object: [String: Any] = ["agent": agent, "hook": hook, "session": session, "ts": ts]
        if interrupt { object["interrupt"] = true }
        for (key, field) in Self.wire { if let value = self[keyPath: field] { object[key] = value } }
        if let linesAdded { object["lines_added"] = linesAdded }
        if let linesRemoved { object["lines_removed"] = linesRemoved }
        if let todosDone { object["todos_done"] = todosDone }
        if let todosTotal { object["todos_total"] = todosTotal }
        if let process {
            object["pid"] = process.pid
            object["pid_start"] = process.started
        }
        if let terminal {
            var tab: [String: Any] = [:]
            for (key, field) in Self.terminalWire { if let value = terminal[keyPath: field] { tab[key] = value } }
            object["terminal"] = tab
        }
        // No `.sortedKeys`: nothing reads the order, and sorting loads
        // locale-aware comparison, about half of a hook's few milliseconds.
        var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        data.append(0x0A)
        return data
    }

    public static func decode(_ data: Data) -> HookLine? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let agent = string(object["agent"]), let hook = string(object["hook"]),
              let session = string(object["session"]) else { return nil }
        var line = HookLine(agent: agent, hook: hook, session: session, interrupt: object["interrupt"] as? Bool == true,
                            ts: (object["ts"] as? NSNumber)?.int64Value ?? 0)
        for (key, field) in wire {
            line[keyPath: field] = string(object[key], max: key == "message" || key == "prompt" ? maxMessage : maxField)
        }
        line.linesAdded = count(object["lines_added"])
        line.linesRemoved = count(object["lines_removed"])
        line.todosDone = count(object["todos_done"])
        line.todosTotal = count(object["todos_total"])
        if let pid = count(object["pid"]), pid > 1, pid <= Int(Int32.max), let started = count(object["pid_start"]) {
            line.process = AgentProcess(pid: Int32(pid), started: Int64(started))
        }
        if let tab = object["terminal"] as? [String: Any] {
            var terminal = TerminalTab()
            for (key, field) in terminalWire { terminal[keyPath: field] = string(tab[key]) }
            line.terminal = terminal == TerminalTab() ? nil : terminal
        }
        return line
    }
}
