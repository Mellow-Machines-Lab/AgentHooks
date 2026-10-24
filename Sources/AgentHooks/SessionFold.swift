import Foundation

/// The bookkeeping about agent sessions: what an agent's
/// event means, which sessions ended, so that a hook of theirs landing
/// later is let go, and how long a silent session still counts.
/// `SessionTracker` keeps one and adds who asks and "needs you". An app
/// reads what an event means (`step`) and the timings here; the rest is
/// the tracker's.
public struct SessionFold: Sendable {
    /// What an agent's event means to the rules.
    public enum Step: Equatable, Sendable {
        case sessionStart, turnStart, activity, needsYou, turnEnd, turnFailed, turnStopped, subagentStart, subagentEnd,
             sessionEnd
    }

    public static func step(_ e: AgentEvent) -> Step {
        switch (e.kind, e.phase) {
        case (.session, .start): .sessionStart
        case (.session, _): .sessionEnd
        case (.turn, .start): .turnStart
        case (.turn, _):
            switch e.outcome {
            case .failed?: .turnFailed
            case .stopped?: .turnStopped
            default: .turnEnd
            }
        case (.tool, .wait): .needsYou
        case (.tool, _): .activity
        case (.subagent, .start): .subagentStart
        case (.subagent, _): .subagentEnd
        }
    }

    /// The steps that start or end a turn or a session: from inside a
    /// subagent, only that subagent's.
    public static let turnLevel: Set<Step> = [.sessionStart, .turnStart, .turnEnd, .turnFailed, .sessionEnd]

    /// A subagent's start or end, or its own turn-level hook: the
    /// subagent's alone, so it doesn't move the session's turn or clock.
    public static func subagentsOwn(_ e: AgentEvent, _ step: Step) -> Bool {
        step == .subagentStart || step == .subagentEnd || (e.subagent != nil && turnLevel.contains(step))
    }

    /// A working session with no events for this long counts as idle,
    /// even while its agent's process runs. A turn sends a hook at every
    /// tool call, and no call runs anywhere near this long in silence
    /// (Claude's commands time out at 10 minutes), so only a `Stop` that
    /// never arrived, or an interrupt that sent none, leaves a session
    /// working this long: a working look and its check-ins end, though
    /// the agent sits at its prompt. Only waiting lasts as long as the
    /// agent does.
    public static let staleWorkMs: Int64 = 60 * 60 * 1000
    /// A session with no events for this long is forgotten, whatever it
    /// does, a request waiting included: so the table is what the last
    /// day of events rebuilds, as an app that reads a day back at launch
    /// does.
    public static let forgetMs: Int64 = 24 * 60 * 60 * 1000
    /// "Needs you" clears anyway after this long with no events, and the
    /// session goes idle, when it has no process to check.
    public static let safetyNetMs: Int64 = 10 * 60 * 1000
    /// Claude's idle notice comes after a minute at its prompt, so one
    /// sooner than this after you sent a prompt is from before it.
    public static let idleNoticeMinMs: Int64 = 30_000

    /// A session's key: `claude/s1`.
    public static func key(_ agent: Agent, _ id: String) -> String { agent.rawValue + "/" + id }

    /// When each session that ended (`session_end`) did, until it starts
    /// again or a day passes: a hook of its that lands later landed late,
    /// and doesn't bring it back.
    var ended: [String: Int64] = [:]
    /// The last session's place in the order they were first seen.
    var lastOrder = 0

    init() {}

    /// The next session's place in the order.
    mutating func takeOrder() -> Int {
        lastOrder += 1
        return lastOrder
    }

    /// Whether `e` counts for the session `key`, which is `known` or not
    /// yet: a session that ended is back only when it starts again, resumed
    /// or with a new prompt. Anything else of its came from before the end
    /// (a Notification as you quit at the prompt, a background subagent's
    /// result, the command Codex's Interrupt aborted).
    mutating func admits(_ e: AgentEvent, _ step: Step, key: String, known: Bool) -> Bool {
        guard !known, ended[key] != nil else { return true }
        guard e.subagent == nil, step == .sessionStart || step == .turnStart else { return false }
        ended[key] = nil
        return true
    }

    /// The session `key` ended at `now`.
    mutating func end(_ key: String, at now: Int64) { ended[key] = now }

    /// Lets go of sessions that ended a day or more before `now`.
    mutating func forgetEnds(at now: Int64) {
        ended = ended.filter { now - $0.value < Self.forgetMs }
    }

    /// A session whose last event was at `lastEventAt` has had none for
    /// `forgetMs` before `now`.
    public static func forgotten(_ lastEventAt: Int64, at now: Int64) -> Bool { now - lastEventAt >= forgetMs }
}

/// A tool call's start, for its result: when, and its topic.
typealias ToolStart = (at: Int64, topic: String?)

/// A session's turn and its tool calls' starts, as `SessionTracker`
/// keeps them.
public struct Turn: Sendable {
    /// When the turn now open started, and when the last one ended: a
    /// call's result from before the end landed late.
    public internal(set) var startedAt: Int64?
    public internal(set) var lastEndedAt: Int64?
    /// When you last sent a prompt (a `turn` start), for a stale idle
    /// notice: a turn a call started (Claude carrying on after another
    /// hook blocked its `Stop`) had no prompt to race.
    public internal(set) var promptedAt: Int64?
    /// The number of the last turn you prompted, counting the prompts
    /// since the tracker first saw the session: 0 before any. A turn a call
    /// opens with no prompt keeps the number before it.
    public internal(set) var number = 0
    /// Each running tool call's start, by `tool_use_id`, and the last
    /// one's, for a result that carries no ID or topic.
    var toolStarts: [String: ToolStart] = [:]
    var lastToolStart: ToolStart?

    init() {}

    /// Claude's idle notice means it has sat at its prompt for a minute,
    /// so one within 30 s of your last prompt is from before it: a new
    /// prompt typed just as the minute ran out.
    func isStaleNotice(_ e: AgentEvent, _ step: SessionFold.Step) -> Bool {
        step == .turnStopped && e.notice != nil
            && promptedAt.map { e.at - $0 < SessionFold.idleNoticeMinMs } == true
    }

    /// You sent a prompt at `now`: a turn starts.
    mutating func prompted(at now: Int64) {
        startedAt = now
        promptedAt = now
        number += 1
    }

    /// A tool call starting, with its topic, kept for its result.
    mutating func callStarted(_ e: AgentEvent) {
        let start = (at: e.at, topic: e.topic)
        if let id = e.toolUseID { toolStarts[id] = start }
        lastToolStart = start
    }

    /// The start of the call that the result `e` ends, before the tracker
    /// handles it: by `tool_use_id`, or else the last call's. When it
    /// started, and its topic, for a result that came without one (a hook
    /// line cut short loses it).
    public func callStart(for e: AgentEvent) -> (at: Int64, topic: String?)? {
        e.toolUseID.flatMap { toolStarts[$0] } ?? lastToolStart
    }

    /// A call's result: its call's start (`callStart`), and whether it
    /// landed late: the call started before the turn ended or stopped, and
    /// none is open (Esc as it finished, or a subagent's racing the
    /// interrupt), so the turn stays over.
    mutating func callEnded(_ e: AgentEvent) -> (started: ToolStart?, late: Bool) {
        let started = e.toolUseID.flatMap { toolStarts.removeValue(forKey: $0) } ?? lastToolStart
        let late = startedAt == nil && started.map { s in lastEndedAt.map { s.at <= $0 } == true } == true
        return (started, late)
    }

    /// The main agent's call `e` with no turn open opens one, with no
    /// prompt (Claude carrying on after another hook blocked its `Stop`).
    /// A subagent's opens none: a background helper that works on after
    /// the main agent's `Stop` is no turn. Whether it did.
    @discardableResult
    mutating func openTurn(_ e: AgentEvent) -> Bool {
        guard startedAt == nil, e.subagent == nil else { return false }
        startedAt = e.at
        return true
    }

    /// The turn open ends at `now`: when it started, or nil with none open.
    mutating func endTurn(at now: Int64) -> Int64? {
        guard let started = startedAt else { return nil }
        startedAt = nil
        lastEndedAt = now
        return started
    }
}
