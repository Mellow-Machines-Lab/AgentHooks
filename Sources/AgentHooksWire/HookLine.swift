import Foundation

/// The one line `agent-hook` sends to the apps listening: only the fields
/// below. Tool input and file contents never get this far; the
/// topic tag is worked out from the tool input in memory, then the input
/// is dropped with the rest of the payload. The only words it can keep are
/// your prompt (`UserPromptSubmit`) and the agent's last message (`Stop`),
/// and only with `--keep-text`.
public struct HookLine: Equatable, Sendable {
    /// `claude` or `codex`, from `agent-hook <agent>`.
    public var agent: String
    /// The agent's hook name, e.g. `PreToolUse`.
    public var hook: String
    public var session: String
    public var cwd: String?
    public var tool: String?
    public var topic: String?
    /// `StopFailure`'s error class, e.g. `rate_limit`.
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
    /// characters, with `--keep-text`.
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
    /// The Claude app's own ID for the session (`local_…`), which its links
    /// open; nil outside the Claude app.
    public var appSession: String?
    /// When the hook ran, in milliseconds.
    public var ts: Int64

    public init(agent: String, hook: String, session: String, cwd: String? = nil, tool: String? = nil,
                topic: String? = nil, error: String? = nil, kind: String? = nil, interrupt: Bool = false,
                toolError: String? = nil, toolUseID: String? = nil, agentType: String? = nil,
                agentID: String? = nil, message: String? = nil, prompt: String? = nil, name: String? = nil,
                source: String? = nil, mode: String? = nil, app: String? = nil, appSession: String? = nil,
                ts: Int64) {
        self.agent = agent
        self.hook = hook
        self.session = session
        self.cwd = cwd
        self.tool = tool
        self.topic = topic
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
        self.ts = ts
    }

    /// Longest value kept for any field, so a strange payload can't make the
    /// line large.
    static let maxField = 200
    /// Longest prompt or last assistant message kept.
    public static let maxMessage = 2000

    /// The hooks that come with every tool call. They look for the thread's
    /// name only near the end of its transcript, where it almost always is,
    /// so a thread that has none doesn't cost a wide read on every call.
    static let perCall: Set<String> = ["PreToolUse", "PostToolUse", "PostToolUseFailure"]

    /// Picks the kept fields out of a raw hook payload. Returns nil when the
    /// payload has no hook name or session. With `codexHome`, the line also
    /// gets the thread's name (`ThreadName`); without it, neither agent's
    /// is looked up. `env` is the hook's environment, which says what app
    /// the agent runs in (`HostApp`). `keepText` keeps your prompt and the
    /// agent's last message; `topics` adds command patterns to the topic
    /// tags (`Topic.extraPatterns`).
    public static func extract(agent: String, payload: Data, ts: Int64, codexHome: String? = nil,
                               env: [String: String] = [:], keepText: Bool = false,
                               topics: [String: [[String]]] = [:]) -> HookLine? {
        var line = (try? JSONSerialization.jsonObject(with: payload) as? [String: Any])
            .flatMap { extract(agent: agent, json: $0, ts: ts, codexHome: codexHome, keepText: keepText, topics: topics) }
            ?? salvage(agent: agent, payload: payload, ts: ts)
        line?.app = HostApp.bundleID(agent: agent, env: env)
        line?.appSession = HostApp.session(agent: agent, env: env)
        return line
    }

    public static func extract(agent: String, json: [String: Any], ts: Int64, codexHome: String? = nil,
                               keepText: Bool = false, topics: [String: [[String]]] = [:]) -> HookLine? {
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
            }
            line.interrupt = hook == "PostToolUseFailure" && json["is_interrupt"] as? Bool == true
            if hook == "PostToolUseFailure" && !line.interrupt {
                line.toolError = ToolError.classify(json["error"] as? String)
            }
        case "UserPromptSubmit":
            if keepText { line.prompt = string(json["prompt"], max: maxMessage) }
        case "Stop":
            if keepText { line.message = string(json["last_assistant_message"], max: maxMessage) }
        case "StopFailure":
            line.error = string(json["error"]) ?? string(json["error_type"])
        case "Notification":
            line.kind = string(json["notification_type"])
        default:
            break
        }
        if let codexHome {
            line.name = ThreadName.find(agent: agent, json: json, session: session, codexHome: codexHome,
                                        wide: !perCall.contains(hook))
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
        ("cwd", \.cwd), ("tool", \.tool), ("topic", \.topic), ("error", \.error), ("kind", \.kind),
        ("tool_error", \.toolError), ("tool_use_id", \.toolUseID), ("agent_type", \.agentType),
        ("agent_id", \.agentID), ("message", \.message), ("prompt", \.prompt), ("name", \.name),
        ("source", \.source), ("mode", \.mode), ("app", \.app), ("app_session", \.appSession),
    ]

    public func encoded() -> Data {
        var object: [String: Any] = ["agent": agent, "hook": hook, "session": session, "ts": ts]
        if interrupt { object["interrupt"] = true }
        for (key, field) in Self.wire { if let value = self[keyPath: field] { object[key] = value } }
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
        return line
    }
}
