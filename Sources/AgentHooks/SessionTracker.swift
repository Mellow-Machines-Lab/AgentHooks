import Foundation

/// Every agent session and what it's doing: working, idle or
/// waiting on you ("needs you"), with its running tool calls, from the
/// events `Mapping` makes. The rules are the fiddly part of agent-hooks:
/// Codex's early request and its grace, a `Notification` that repeats a
/// request its own hook makes, subagents asking alongside their parent,
/// hooks that land after their session ended, and the safety net.
///
/// It's a pure state machine with no queue or clock of its own: `handle`
/// takes each event at its time, and `advance` runs the timers, about once
/// a second. Touch it from one queue.
public final class SessionTracker {
    /// A tool call running.
    public struct Call: Equatable, Sendable {
        /// Its key: the `tool_use_id`, or `#N` for one without.
        public let key: String
        public let tool: String
        /// What kind of work it is, from `tool` (`ToolKind`).
        public var kind: ToolKind { ToolKind.of(tool) }
        public let topic: String?
        /// `""` for the main agent, else the subagent's `agent_id`.
        public let by: String
        /// The order calls started in, for a result that names no call.
        public let order: Int
        public let startedAt: Int64
        /// A subagent started while it ran: for an `Agent` or `Task` call,
        /// that subagent's `SubagentStop` is its return, not this call's
        /// end.
        public internal(set) var sawSubagent = false
    }

    /// One session.
    public struct Session: Sendable {
        public let agent: Agent
        public let id: String
        /// Its project and workspace (`Place`): where its events come from,
        /// except while a request waits.
        public internal(set) var project: String
        public internal(set) var workspace: String?
        /// The thread's name as its agent's app shows it, the last an event
        /// brought.
        public internal(set) var name: String?
        /// The app the agent runs in and that app's ID for the session, the
        /// last an event brought: where the thread opens (`ThreadLink`).
        public internal(set) var app: String?
        public internal(set) var appSession: String?
        /// The permission mode the last event that had one said.
        public internal(set) var mode: String?
        /// Working on a turn: not idle, and not waiting on "needs you". A
        /// Codex request in its grace still counts as working.
        public internal(set) var working = false
        public internal(set) var turn = Turn()
        public internal(set) var lastEventAt: Int64
        /// When "needs you" started showing.
        public internal(set) var needsSince: Int64?
        /// The number of the request it shows, in the order requests
        /// started showing, from `firstRequest` on: a new one when another
        /// asker's prompt shows in its place.
        public internal(set) var request = 0
        /// The `ref` of the event that made it show.
        public internal(set) var requestRef: Int?
        /// Codex: when "needs you" arrived, during the grace period.
        public internal(set) var pendingSince: Int64?
        /// Who is asking, while "needs you" waits: `""` for the main agent,
        /// a Claude subagent's id, or `SessionTracker.anyone` for a
        /// `Notification` whose request's own hook hasn't come; each with
        /// the tool it asks for, or `""` for none.
        public internal(set) var askers: [String: String] = [:]
        /// What the request asks for, as its first asker said.
        public internal(set) var asking: AgentEvent.Asking?
        /// The tool calls running this turn, by key.
        public internal(set) var calls: [String: Call] = [:]
        /// The subagents seen starting this turn (`SubagentStart`) that
        /// haven't ended, by `agent_id`.
        public internal(set) var helpers: Set<String> = []
        /// The order sessions were first seen in.
        public let order: Int

        /// When "needs you" last cleared, to drop its late `Notification`.
        var clearedAt: Int64?
        /// A tool call has started since then: a new request follows one.
        var calledSinceClear = false
        /// The `Notification` types the waiting request's askers send, and
        /// those of the request that last cleared: only a late one of those
        /// is a copy.
        var notices: Set<String> = []
        var clearedNotices: Set<String> = []

        init(agent: Agent, id: String, project: String, lastEventAt: Int64, order: Int) {
            self.agent = agent
            self.id = id
            self.project = project
            self.lastEventAt = lastEventAt
            self.order = order
        }

        public var key: String { SessionFold.key(agent, id) }
        /// Claude's plan mode.
        public var planMode: Bool { mode == "plan" }
        /// Where the thread opens.
        public var thread: ThreadRef { ThreadRef(agent: agent.rawValue, session: id, app: app, appSession: appSession) }
    }

    /// What an event did to its session, for an app that reacts to it.
    public enum Change: Equatable, Sendable {
        /// A session started, from its `source`: `startup`, `resume`…
        case sessionStarted(source: String?)
        case turnStarted
        case callStarted(Call)
        /// A call's result: the call it ended, if one was running, and
        /// whether it landed late, after its turn ended or stopped.
        case callEnded(Call?, late: Bool)
        /// A turn's end, and whether it ended one that was open.
        case turnEnded(AgentEvent.Outcome, endedTurn: Bool)
        /// A request: it started, joined the one waiting, or was a late copy.
        case asked
        case subagentStarted
        /// A subagent ended; `returned` when it's a helper seen starting,
        /// back while its turn goes on.
        case subagentEnded(returned: Bool)
        case sessionEnded
        /// Anything else that counted: a question answered, or a
        /// subagent's own turn-level hook.
        case other
    }

    /// The asker of a request that came as a `Notification` alone, which
    /// doesn't say who asked: any event from the session answers it.
    public static let anyone = "*"
    /// How far apart a request's own hook and its `Notification` may land,
    /// either way round.
    public static let noticeLagMs: Int64 = 5000
    /// Codex's grace period before "needs you" shows.
    public static let codexGraceMs: Int64 = 2000
    /// In its first second, a request from "anyone" isn't answered by a
    /// call: its own hook may still be coming, and nobody answers a prompt
    /// that fast.
    public static let noticeFirstMs: Int64 = 1000
    /// The largest request number, so it fits in 32 bits.
    public static let maxRequest = Int(Int32.max)

    public private(set) var sessions: [String: Session] = [:]
    /// Why each request that cleared unanswered did (`nothing for 10
    /// minutes`, `forgotten`), by session key, until the app takes it.
    public var clearedWhy: [String: String] = [:]
    var fold = SessionFold()
    public private(set) var lastRequest: Int
    var callOrder = 0
    let place: (String) -> Place

    /// `firstRequest` is where request numbers start: the first request
    /// shown gets the one after it. `place` names a working directory's
    /// project (`Places` caches it).
    public init(firstRequest: Int = 0, place: @escaping (String) -> Place = { Place.at(cwd: $0) }) {
        lastRequest = firstRequest
        self.place = place
    }

    // MARK: - Inputs

    /// An agent's event at its time, the timers due by then run first:
    /// what it did, or nil when it didn't count (a hook that landed after
    /// its session ended, a stale idle notice). `ref` is the caller's own
    /// for it, such as a log's sequence number: a request keeps it.
    @discardableResult
    public func handle(_ event: AgentEvent, ref: Int? = nil) -> Change? {
        let now = event.at
        let key = event.key
        // The event's own session is left until after the event: a Codex
        // request past its grace that the event answers was never shown.
        advance(to: now, sparing: key)
        let change = apply(event, SessionFold.step(event), key, now, ref)
        if var s = sessions[key] {
            promote(&s, now)
            sessions[key] = s
        }
        return change
    }

    /// Runs every timer due by `now`: a Codex request past its grace shows,
    /// a session silent 10 minutes stops waiting and working, and one
    /// silent a day is forgotten. `sparing`'s Codex request isn't shown:
    /// its event comes first.
    public func advance(to now: Int64, sparing: String? = nil) {
        for (key, var s) in sessions where s.pendingSince != nil || now - s.lastEventAt >= SessionFold.safetyNetMs {
            let silent = now - s.lastEventAt >= SessionFold.safetyNetMs
            if !silent && key != sparing { promote(&s, now) }
            if silent && (s.needsSince != nil || s.pendingSince != nil) {
                // Ten silent minutes, even for a Codex request no tick saw
                // through its grace (the Mac slept): the agent is still
                // waiting on its prompt, or gone. Either way it isn't
                // working. Its turn, if it goes on, still counts from its
                // start.
                clearRequest(&s, now, why: "nothing for 10 minutes")
                s.working = false
            }
            if SessionFold.forgotten(s.lastEventAt, at: now) {
                if s.needsSince != nil { clearedWhy[key] = "forgotten" }
                sessions[key] = nil
            } else {
                sessions[key] = s
            }
        }
        fold.forgetEnds(at: now)
    }

    // MARK: - Reading

    /// Whether the session works at `now`: working, and heard from within
    /// the hour.
    public func isWorking(_ s: Session, at now: Int64) -> Bool {
        s.working && now - s.lastEventAt < SessionFold.staleWorkMs
    }

    /// Whether any session needs you.
    public var needsYou: Bool { sessions.values.contains { $0.needsSince != nil } }

    /// The sessions in the order to list them: those that need you (oldest
    /// first), then working, then idle, each in the order first seen.
    public func grouped(at now: Int64) -> (waiting: [Session], working: [Session], idle: [Session]) {
        let waiting = sessions.values.filter { $0.needsSince != nil }
            .sorted { ($0.needsSince!, $0.request) < ($1.needsSince!, $1.request) }
        let working = sessions.values.filter { $0.needsSince == nil && isWorking($0, at: now) }.sorted { $0.order < $1.order }
        let idle = sessions.values.filter { $0.needsSince == nil && !isWorking($0, at: now) }.sorted { $0.order < $1.order }
        return (waiting, working, idle)
    }

    /// The number after `request`, back to 1 past `maxRequest`: never 0,
    /// which means none.
    public static func nextRequest(after request: Int) -> Int { request >= maxRequest ? 1 : request + 1 }

    /// A random place for request numbers to start, so they don't repeat
    /// from one launch to the next.
    public static func randomFirstRequest() -> Int { Int.random(in: 0..<maxRequest) }

    // MARK: - Rules

    /// The event's changes to its session.
    func apply(_ event: AgentEvent, _ step: SessionFold.Step, _ key: String, _ now: Int64, _ ref: Int?) -> Change? {
        let tool = event.tool
        let notice = event.notice
        // A finished call: a result with a tool (an `ElicitationResult` has none).
        let done = event.kind == .tool && event.phase == .end && tool != nil
        guard fold.admits(event, step, key: key, known: sessions[key] != nil) else { return nil }
        let place = event.cwd.map(self.place)
        var s = sessions[key] ?? Session(agent: event.agent, id: event.session, project: place?.project ?? "unknown",
                                         lastEventAt: now, order: fold.takeOrder())
        let waiting = s.needsSince != nil || s.pendingSince != nil
        if s.turn.isStaleNotice(event, step) { return nil }
        // A session is where its events come from, except while a request
        // waits: it's named where that was made, whatever folder a sibling
        // subagent works in meanwhile.
        if let place, place.project != "unknown", !waiting {
            s.project = place.project
            s.workspace = place.workspace
        }
        if let name = event.name { s.name = name }
        if let app = event.app { s.app = app }
        if let appSession = event.appSession { s.appSession = appSession }
        if let mode = event.mode { s.mode = mode }

        if step == .needsYou {
            // A request's own hook (`PermissionRequest`, `Elicitation`) says
            // which agent asks; its `Notification` doesn't, so it's from
            // "anyone" until the hook comes. While a request waits, a
            // Notification is the same request, and a hook joins it: a
            // sibling subagent asking too, or, within 5 s of a Notification
            // that came alone, that request's own hook. With nothing
            // waiting, a Notification of the kind the request that last
            // cleared sends is its late copy if it comes within 5 s of the
            // clear, or before any tool call has started since.
            let asker = notice == nil ? event.subagent ?? "" : Self.anyone
            let kind = notice ?? (tool == nil ? "elicitation_dialog" : "permission_prompt")
            let lateCopy = notice.map(s.clearedNotices.contains) == true
                && s.clearedAt.map { now - $0 < Self.noticeLagMs || !s.calledSinceClear } == true
            if !lateCopy { s.notices.insert(kind) }
            if waiting {
                if notice == nil {
                    if Array(s.askers.keys) == [Self.anyone], s.needsSince.map({ now - $0 < Self.noticeLagMs }) == true {
                        s.askers = [:]
                    }
                    s.askers[asker] = tool ?? ""
                }
            } else if !lateCopy {
                s.askers = [asker: tool ?? ""]
                s.asking = event.asking
                s.requestRef = ref
                if event.agent == .codex {
                    s.pendingSince = now
                    s.working = true
                } else {
                    s.needsSince = now
                    s.request = takeRequest()
                    s.working = false
                }
            }
            s.lastEventAt = now
            sessions[key] = s
            return .asked
        }

        if step == .subagentStart {
            // A helper starting: the main agent delegates until it ends. Like
            // its end, it isn't activity, and answers no request.
            if let id = event.subagent { helperStarted(&s, id) }
            sessions[key] = s
            return .subagentStarted
        }

        if SessionFold.subagentsOwn(event, step) {
            // A subagent that has finished can't be waiting on a prompt, so
            // its end answers its own request: denied, it carried on and
            // ended without another tool call. It answers nobody else, not
            // even "anyone". It isn't activity either: the session doesn't
            // start working and its clock doesn't move, so it can't make an
            // idle or stale session look busy. Once no asker is left, the
            // session works again only if its turn is still going.
            // A turn-level hook from inside a subagent
            // (its `agent_id` on a `StopFailure`, say) is that subagent's
            // alone too, not the session's turn, but only its end ends it:
            // a helper that worked on with no turn open (in the
            // background, after the main agent's `Stop`) is done once none
            // of its calls runs.
            if step == .subagentEnd, let id = event.subagent {
                s.calls = s.calls.filter { $0.value.by != id }
                if s.turn.startedAt == nil, s.calls.isEmpty, s.pendingSince == nil { s.working = false }
            }
            if waiting, let id = event.subagent, s.askers.removeValue(forKey: id) != nil {
                if s.askers.isEmpty {
                    clearRequest(&s, now)
                    s.working = s.turn.startedAt != nil
                } else {
                    anotherRequest(&s)
                }
            }
            // A helper seen starting returns, while its turn goes on.
            let returned = step == .subagentEnd && event.subagent.map { s.helpers.remove($0) != nil } == true
            sessions[key] = s
            return step == .subagentEnd ? .subagentEnded(returned: returned && s.turn.startedAt != nil) : .other
        }

        // The asker's next event means it moved on, and so does any
        // turn-level event. A sibling subagent's tool calls don't answer
        // another agent's request. Claude's idle notice (a stopped `turn` end
        // with no tool) is turn-level too: Claude sits at its own prompt
        // with the turn over, which it never does while a prompt is up, a
        // subagent's included, so you pressed Esc on it, which sends no hook.
        // An asker's result for another tool is a call it made alongside
        // the one that asks (Claude runs read-only calls in parallel, and
        // the main agent's Agent call runs on), so it isn't the answer. An
        // `Elicitation` (no tool) isn't a call: its answer is its
        // `ElicitationResult` or the agent's next call, never a result. A
        // request from "anyone" is answered by any event, but by a call only
        // after its first second: a sibling's can land between a
        // `Notification` and its request's own hook.
        if waiting {
            let asker = event.subagent ?? ""
            let before = s.askers
            defer { denied(&s, before: before, event) }
            let alongside = done && s.askers[asker].map { asked in
                asked.isEmpty || tool.map { $0 != asked } == true
            } == true
            let anyoneAnswered = s.askers[Self.anyone] != nil
                && s.needsSince.map { now - $0 >= Self.noticeFirstMs } != false
            if step != .activity || anyoneAnswered {
                s.askers.removeAll()
            } else if !alongside, s.askers.removeValue(forKey: asker) != nil, !s.askers.isEmpty {
                anotherRequest(&s)
            }
            if s.askers.isEmpty {
                clearRequest(&s, now)
                s.working = true
            }
        }
        s.lastEventAt = now
        // The table has the answer before the event applies.
        sessions[key] = s

        var change: Change = .other
        switch step {
        case .sessionStart:
            change = .sessionStarted(source: event.source)
        case .turnStart:
            s.working = true
            s.turn.prompted(at: now)
            clearWork(&s)
            change = .turnStarted
        case .activity:
            // A result that landed late leaves the turn over.
            var late = false
            if done {
                late = s.turn.callEnded(event).late
                change = .callEnded(endCall(&s, event), late: late)
            } else if let tool {
                s.turn.callStarted(event)
                s.calledSinceClear = true
                change = .callStarted(startCall(&s, event, tool: tool, now))
            }
            if !late {
                s.working = true
                s.turn.openTurn(event)
            }
        case .turnEnd, .turnFailed, .turnStopped:
            // Over, done, failed or stopped: a working session goes idle.
            // A stop ends a turn even once the safety net has made the
            // session idle: its turn went on (you approved, which sends no
            // hook), so a call's result after the stop is a late one.
            s.working = false
            let ended = s.turn.endTurn(at: now) != nil
            clearWork(&s)
            change = .turnEnded(event.outcome ?? .done, endedTurn: ended)
        case .sessionEnd:
            sessions[key] = nil
            fold.end(key, at: now)
            return .sessionEnded
        case .needsYou, .subagentStart, .subagentEnd:
            break
        }
        sessions[key] = s
        return change
    }

    /// A Codex request whose grace is over, and nothing answered, shows,
    /// dated 2 s after it arrived.
    func promote(_ s: inout Session, _ now: Int64) {
        guard let pending = s.pendingSince, now - pending >= Self.codexGraceMs else { return }
        s.pendingSince = nil
        s.needsSince = pending + Self.codexGraceMs
        s.request = takeRequest()
        s.working = false
    }

    /// A request's number, in the order requests start showing.
    func takeRequest() -> Int {
        lastRequest = Self.nextRequest(after: lastRequest)
        return lastRequest
    }

    /// One of several askers in a session was answered, so Claude shows
    /// another's prompt now: a different request, with its own number.
    func anotherRequest(_ s: inout Session) {
        if s.needsSince != nil { s.request = takeRequest() }
    }

    /// Nobody is waiting on the session any more; `why` it cleared if
    /// nobody answered.
    func clearRequest(_ s: inout Session, _ now: Int64, why: String? = nil) {
        if s.needsSince != nil, let why { clearedWhy[s.key] = why }
        s.needsSince = nil
        s.pendingSince = nil
        s.askers.removeAll()
        s.asking = nil
        s.clearedAt = now
        s.calledSinceClear = false
        s.clearedNotices = s.notices
        s.notices = []
    }

    /// A call starting, from the main agent or a subagent.
    func startCall(_ s: inout Session, _ event: AgentEvent, tool: String, _ now: Int64) -> Call {
        callOrder += 1
        let call = Call(key: event.toolUseID ?? "#\(callOrder)", tool: tool, topic: event.topic, by: event.subagent ?? "",
                        order: callOrder, startedAt: now)
        s.calls[call.key] = call
        return call
    }

    /// A call's result: the call it ends, by `tool_use_id`, else the last
    /// one started without one, of the same tool by the same agent if
    /// there's one.
    func endCall(_ s: inout Session, _ event: AgentEvent) -> Call? {
        let key: String?
        if let id = event.toolUseID {
            key = s.calls[id] != nil ? id : nil
        } else {
            let by = event.subagent ?? "", tool = event.tool
            let unnamed = s.calls.filter { $0.key.hasPrefix("#") }
            let same = unnamed.filter { $0.value.by == by && $0.value.tool == tool }
            key = (same.isEmpty ? unnamed : same).max { $0.value.order < $1.value.order }?.key
        }
        guard let key else { return nil }
        return s.calls.removeValue(forKey: key)
    }

    /// Requests answered by something other than their call's result: the
    /// agent moved on, so you denied the call, which sends no hook.
    /// Each asker's latest call of the tool it asked for
    /// never runs, so it isn't running any more. `before` is who asked, and
    /// for which tool, before `event`.
    func denied(_ s: inout Session, before: [String: String], _ event: AgentEvent) {
        for (asker, tool) in before where !tool.isEmpty && s.askers[asker] == nil {
            let result = event.kind == .tool && event.phase == .end && (event.subagent ?? "") == asker
                && event.tool == tool
            guard !result else { continue }
            let latest = s.calls.filter { $0.value.by == asker && $0.value.tool == tool }
                .max { $0.value.order < $1.value.order }
            if let key = latest?.key { s.calls[key] = nil }
        }
    }

    /// A helper starting (`SubagentStart`): the calls running are waiting
    /// on it, so an `Agent` or `Task` call's end isn't its return.
    func helperStarted(_ s: inout Session, _ id: String) {
        s.helpers.insert(id)
        for key in s.calls.keys { s.calls[key]?.sawSubagent = true }
    }

    /// A turn starting or ending: its calls and helpers are over.
    func clearWork(_ s: inout Session) {
        s.calls.removeAll()
        s.helpers.removeAll()
    }
}
