import AgentHooksWire
import Foundation

/// Turns a hook line from `agent-hook` into an `AgentEvent`:
/// its kind and phase, the hook's own name, and the facts that kind has.
/// Everything agent-specific lives here.
public enum Mapping {
    /// A hook's kind and phase.
    public typealias Kind = (kind: AgentEvent.Kind, phase: AgentEvent.Phase)

    /// Claude Code's hooks, in the order the installer adds them,
    /// and what each becomes. `Notification` (nil here) and
    /// an interrupted `PostToolUseFailure` depend on what they carry
    /// (`kind(of:)`).
    public static let claude: [(hook: String, kind: Kind?)] = [
        ("SessionStart", (.session, .start)),
        ("UserPromptSubmit", (.turn, .start)),
        ("PreToolUse", (.tool, .start)),
        ("PostToolUse", (.tool, .end)),
        ("PostToolUseFailure", (.tool, .end)),
        ("PermissionRequest", (.tool, .wait)),
        ("Notification", nil),
        ("Elicitation", (.tool, .wait)),
        ("ElicitationResult", (.tool, .end)),
        ("Stop", (.turn, .end)),
        ("StopFailure", (.turn, .end)),
        ("SubagentStart", (.subagent, .start)),
        ("SubagentStop", (.subagent, .end)),
        ("SessionEnd", (.session, .end)),
    ]

    /// Claude's `Notification` types that mean a person is being asked.
    static let askingNotifications = ["permission_prompt", "elicitation_dialog"]
    /// Claude's `Notification` type for sitting at its prompt for a minute:
    /// whatever turn there was is over, even one that ended without `Stop`.
    static let idleNotification = "idle_prompt"
    /// Every `Notification` type mapped, in the order the installer's
    /// matcher lists them: Claude runs the hook for no other.
    /// A new order would make every install look outdated.
    static let notificationTypes = askingNotifications + [idleNotification]

    /// Codex's hooks, in the order the installer adds them. Codex has no
    /// failure hook; `Interrupt` is you pressing Esc. `PostCompact` is its
    /// context compacted, which Claude says with a `SessionStart` whose
    /// `source` is `compact`: both become that.
    public static let codex: [(hook: String, kind: Kind)] = [
        ("SessionStart", (.session, .start)),
        ("UserPromptSubmit", (.turn, .start)),
        ("PreToolUse", (.tool, .start)),
        ("PostToolUse", (.tool, .end)),
        ("PermissionRequest", (.tool, .wait)),
        ("Stop", (.turn, .end)),
        ("Interrupt", (.turn, .end)),
        ("PostCompact", (.session, .start)),
        ("SessionEnd", (.session, .end)),
    ]

    /// A session start's `source` once its context was compacted.
    public static let compacted = "compact"

    static let claudeByHook = Dictionary(uniqueKeysWithValues: claude.map { ($0.hook, $0.kind) })
    static let codexByHook = Dictionary(uniqueKeysWithValues: codex.map { ($0.hook, $0.kind) })

    /// Every hook of `agent`'s that's mapped, in the installer's order.
    public static func hooks(_ agent: Agent) -> [String] {
        switch agent {
        case .claude: claude.map(\.hook)
        case .codex: codex.map(\.hook)
        }
    }

    /// What a hook line becomes, or nil for one that's ignored.
    public static func kind(of line: HookLine) -> Kind? {
        guard let agent = Agent(rawValue: line.agent) else { return nil }
        switch agent {
        case .claude:
            if line.hook == "Notification" {
                if line.kind.map(askingNotifications.contains) == true { return (.tool, .wait) }
                return line.kind == idleNotification ? (.turn, .end) : nil
            }
            // Esc: Claude sends no `Stop` for a turn you interrupt.
            if line.interrupt { return (.turn, .end) }
            return claudeByHook[line.hook] ?? nil
        case .codex:
            return codexByHook[line.hook]
        }
    }

    /// The event for a hook line, or nil for hooks that are ignored. `at`
    /// is when it was received, or the line's own time.
    public static func event(from line: HookLine, receivedAt: Int64? = nil) -> AgentEvent? {
        guard let agent = Agent(rawValue: line.agent), let (kind, phase) = kind(of: line) else { return nil }
        // A subagent's start or end says which subagent by its `agent_id`;
        // one without it can't answer anyone's request or end a helper, and
        // mustn't pass for the main agent.
        if kind == .subagent && line.agentID == nil { return nil }
        let claude = agent == .claude
        var e = AgentEvent(agent: agent, kind: kind, phase: phase, hook: line.hook, session: line.session,
                           at: receivedAt ?? line.ts, subagent: claude ? line.agentID : nil, cwd: line.cwd)
        if claude {
            e.subagentType = line.agentType
            e.mode = line.mode
        }
        switch (kind, phase) {
        case (.session, .start):
            e.source = line.hook == "PostCompact" ? compacted : line.source
        case (.turn, .start):
            e.prompt = line.prompt
        case (.tool, .start):
            e.tool = line.tool
            e.toolUseID = line.toolUseID
            e.topic = line.topic
        case (.tool, .wait):
            e.tool = line.tool
            e.toolUseID = line.toolUseID
            let notice = line.hook == "Notification" ? line.kind : nil
            e.notice = notice
            let forInput = line.hook == "Elicitation" || notice == "elicitation_dialog"
            e.asking = forInput ? .input : .permission
        case (.tool, .end):
            e.tool = line.tool
            e.toolUseID = line.toolUseID
            e.topic = line.topic
            if claude && line.tool != nil {
                // Claude says whether a call failed; Codex doesn't.
                let failed = line.hook == "PostToolUseFailure"
                e.failed = failed
                if failed { e.error = line.toolError ?? "other" }
            }
        case (.turn, .end):
            if line.hook == "StopFailure" {
                e.outcome = .failed
                // The client sends only the class; classing it again is a
                // no-op, and still classes a line from an older client.
                e.error = line.error.map(TurnError.classify)
            } else if line.hook == "Stop" {
                e.outcome = .done
                e.message = line.message
            } else {
                // Esc, Codex's `Interrupt` or Claude's idle notice: over
                // without finishing.
                e.outcome = .stopped
                e.tool = line.tool  // an interrupted call; the idle notice has none
                e.notice = line.hook == "Notification" ? line.kind : nil
            }
        default:
            break
        }
        e.name = line.name
        e.app = line.app
        e.appSession = line.appSession
        return e
    }
}
