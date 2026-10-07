import Foundation

/// The agents agent-hooks listens to, by the name `agent-hook` is called
/// with.
public enum Agent: String, CaseIterable, Codable, Sendable {
    case claude, codex

    /// `Claude Code`, `Codex`.
    public var displayName: String { self == .claude ? "Claude Code" : "Codex" }
}

/// One thing an agent did, whichever agent it was: a hook
/// mapped to a kind of thing (`session`, `turn`, `tool`, `subagent`) and
/// where in its life it is (`start`, `wait`, `end`), with the few facts
/// that hook carries. Everything agent-specific stays in `Mapping`.
public struct AgentEvent: Equatable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case session, turn, tool, subagent }
    /// Only a `tool` waits: on you, for permission or an answer.
    public enum Phase: String, Codable, Sendable { case start, wait, end }
    /// How a turn ended.
    public enum Outcome: String, Codable, Sendable { case done, failed, stopped }
    /// What a waiting tool call asks you for.
    public enum Asking: String, Codable, Sendable { case permission, input }

    public var agent: Agent
    public var kind: Kind
    public var phase: Phase
    /// The agent's own name for the hook: `PreToolUse`, `Interrupt`.
    public var hook: String
    /// The agent's session: `session_id`, or Codex's thread.
    public var session: String
    /// When it happened, in unix milliseconds.
    public var at: Int64
    /// The Claude subagent it came from (`agent_id`); nil for the main agent.
    public var subagent: String?
    /// What kind of Claude subagent (`agent_type`): `Explore`, `Plan`.
    public var subagentType: String?
    public var cwd: String?

    // On any hook that has them.
    /// The thread's name as its agent's app shows it (`ThreadName`).
    public var name: String?
    /// The app the agent runs in, by bundle ID (`HostApp`).
    public var app: String?
    /// The Claude app's own ID for the session (`local_…`).
    public var appSession: String?
    /// The agent's permission mode: Claude's `default`, `plan`, `acceptEdits`…
    public var mode: String?

    // By kind and phase.
    /// A session start's source: `startup`, `resume`, `clear` or `compact`.
    public var source: String?
    /// A turn start's prompt, with `--keep-text`.
    public var prompt: String?
    public var tool: String?
    /// What kind of work the tool call is, from `tool` (`ToolKind`).
    public var toolKind: ToolKind? { tool.map(ToolKind.of) }
    public var toolUseID: String?
    /// What a tool call is about: `tests`, `build`, `deploy`, `docs` or
    /// `inspect` (`Topic`).
    public var topic: String?
    /// Whether a tool call failed. Only Claude says; nil from Codex.
    public var failed: Bool?
    /// A failed call's or turn's error, as a short class.
    public var error: String?
    /// A wait's request: permission or input.
    public var asking: Asking?
    /// The Claude `Notification` type a wait or a stop came as, which
    /// repeats a request its own hook makes.
    public var notice: String?
    /// A turn end's outcome.
    public var outcome: Outcome?
    /// A done turn's last message, with `--keep-text`.
    public var message: String?

    public init(agent: Agent, kind: Kind, phase: Phase, hook: String, session: String, at: Int64,
                subagent: String? = nil, subagentType: String? = nil, cwd: String? = nil, name: String? = nil,
                app: String? = nil, appSession: String? = nil, mode: String? = nil, source: String? = nil,
                prompt: String? = nil, tool: String? = nil, toolUseID: String? = nil, topic: String? = nil,
                failed: Bool? = nil, error: String? = nil, asking: Asking? = nil, notice: String? = nil,
                outcome: Outcome? = nil, message: String? = nil) {
        self.agent = agent
        self.kind = kind
        self.phase = phase
        self.hook = hook
        self.session = session
        self.at = at
        self.subagent = subagent
        self.subagentType = subagentType
        self.cwd = cwd
        self.name = name
        self.app = app
        self.appSession = appSession
        self.mode = mode
        self.source = source
        self.prompt = prompt
        self.tool = tool
        self.toolUseID = toolUseID
        self.topic = topic
        self.failed = failed
        self.error = error
        self.asking = asking
        self.notice = notice
        self.outcome = outcome
        self.message = message
    }

    /// The session's key across agents: `claude/s1`.
    public var key: String { SessionFold.key(agent, session) }

    /// The event as one JSON line, keys sorted, for `agent-hooks tail`.
    public var jsonLine: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return String(decoding: (try? encoder.encode(self)) ?? Data(), as: UTF8.self)
    }
}
