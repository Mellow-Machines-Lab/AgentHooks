import AgentHooks
import Darwin
import Foundation
import Testing
@testable import AgentHooksWire

/// The agent's own process, found above the hook, and whether it still
/// runs: against the tests' own process and its parents.
@Suite struct AgentProcessTests {
    /// The process `pid`, as `find` would name it.
    func process(_ pid: Int32) throws -> AgentProcess {
        let info = try #require(AgentProcess.info(pid))
        return AgentProcess(pid: pid, started: AgentProcess.startTime(info))
    }

    @Test func aRunningProcessRunsAndOneThatStartedAnotherTimeDoesnt() throws {
        let me = try process(getpid())
        #expect(AgentProcess.isRunning(me))
        #expect(!AgentProcess.isRunning(AgentProcess(pid: me.pid, started: me.started + 1)), "its pid, reused")
        #expect(!AgentProcess.isRunning(AgentProcess(pid: 99_999_999, started: me.started)), "no such process")
        #expect(me.started <= Int64(Date().timeIntervalSince1970 * 1000))
        #expect(me.started > 1_700_000_000_000, "milliseconds since 1970")
    }

    /// The first parent that isn't a shell or a launcher, else Claude's
    /// own pid when it's one of the parents.
    @Test func theAgentIsFoundAboveTheHook() throws {
        var expected: AgentProcess?
        var pid = getppid()
        var ancestors: [AgentProcess] = []
        for _ in 0..<8 where pid > 1 {
            let info = try #require(AgentProcess.info(pid))
            let p = try process(pid)
            ancestors.append(p)
            if expected == nil, !AgentProcess.launchers.contains(AgentProcess.name(info)) { expected = p }
            pid = info.kp_eproc.e_ppid
        }
        let found = AgentProcess.find(agent: "codex", env: [:])
        #expect(found == expected)
        if let found { #expect(AgentProcess.isRunning(found)) }
        #expect(AgentProcess.find(agent: "claude", env: ["CLAUDE_PID": "99999999"]) == expected, "not a parent: ignored")
        if let last = ancestors.last {
            #expect(AgentProcess.find(agent: "claude", env: ["CLAUDE_PID": "\(last.pid)"]) == last)
            #expect(AgentProcess.find(agent: "codex", env: ["CLAUDE_PID": "\(last.pid)"]) == expected, "Claude's alone")
        }
        #expect(AgentProcess.find(agent: "codex", env: [:], levels: 0) == nil)
        #expect(AgentProcess.launchers == ["sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh", "env"])
    }

    /// It rides every line, to the event and its session.
    @Test func itRidesTheLineToTheSession() throws {
        let raw = Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"s1"}"#.utf8)
        let agent = AgentProcess(pid: 4242, started: 1_791_707_031_722)
        let line = try #require(HookLine.extract(agent: "claude", payload: raw, ts: 1, process: agent))
        let wire = String(decoding: line.encoded(), as: UTF8.self)
        #expect(wire.contains(#""pid":4242"#) && wire.contains(#""pid_start":1791707031722"#))
        #expect(HookLine.decode(line.encoded()) == line)
        #expect(HookLine.decode(Data(#"{"agent":"claude","hook":"Stop","session":"s1","pid":-3,"pid_start":1}"#.utf8))?.process == nil)
        #expect(HookLine.decode(Data(#"{"agent":"claude","hook":"Stop","session":"s1","pid":3}"#.utf8))?.process == nil)
        let event = try #require(Mapping.event(from: line))
        #expect(event.process == agent)
        #expect(try JSONDecoder().decode(AgentEvent.self, from: Data(event.jsonLine.utf8)) == event)
        let tracker = SessionTracker()
        tracker.handle(event)
        #expect(tracker.sessions["claude/s1"]?.process == agent)
    }
}

/// A request waits, and a turn works, as long as its agent's process runs,
/// and stops when the agent is gone; an idle session's process doesn't
/// matter.
@Suite final class AgentGoneTests {
    final class Processes: @unchecked Sendable {
        var alive: Set<Int32> = [7]
        var checks = 0
    }

    let processes: Processes
    let tracker: SessionTracker
    var now: Int64 = 1_000_000
    let agent = AgentProcess(pid: 7, started: 1)

    init() {
        let processes = Processes()
        self.processes = processes
        tracker = SessionTracker(firstRequest: 100, place: { Place(project: ($0 as NSString).lastPathComponent) },
                                 isRunning: { processes.checks += 1; return processes.alive.contains($0.pid) })
    }

    @discardableResult
    func send(_ kind: AgentEvent.Kind, _ phase: AgentEvent.Phase, _ hook: String, agent: Agent = .claude,
              process: AgentProcess?? = .none, after ms: Int64 = 100,
              _ configure: (inout AgentEvent) -> Void = { _ in }) -> SessionTracker.Change? {
        now += ms
        var e = AgentEvent(agent: agent, kind: kind, phase: phase, hook: hook, session: "s1", at: now, cwd: "/w/landing")
        e.process = process ?? self.agent
        configure(&e)
        return tracker.handle(e)
    }

    func state(_ key: String = "claude/s1") -> String {
        let (waiting, working, _) = tracker.grouped(at: now)
        if waiting.contains(where: { $0.key == key }) { return "needs_you" }
        if working.contains(where: { $0.key == key }) { return "working" }
        return tracker.sessions[key] == nil ? "gone" : "idle"
    }

    /// Ticks once a second for `ms`, gathering what the timers did.
    func tick(for ms: Int64, every step: Int64 = 1000) -> [(at: Int64, changes: [String: SessionTracker.Change])] {
        var out: [(at: Int64, changes: [String: SessionTracker.Change])] = []
        let end = now + ms
        while now < end {
            now += step
            let changes = tracker.advance(to: now)
            if !changes.isEmpty { out.append((now, changes)) }
        }
        return out
    }

    @Test func aRequestWaitsAsLongAsItsAgentRuns() {
        send(.turn, .start, "UserPromptSubmit")
        send(.tool, .wait, "PermissionRequest") { $0.tool = "Bash" }
        let request = tracker.sessions["claude/s1"]?.request
        #expect(tick(for: 2 * 60 * 60 * 1000, every: 5000).isEmpty, "two hours at lunch")
        #expect(state() == "needs_you")
        #expect(tracker.sessions["claude/s1"]?.request == request, "the same request")
        #expect(processes.checks > 0)
        now += SessionFold.forgetMs
        tracker.advance(to: now)
        #expect(state() == "needs_you", "a day, and its agent still waits")
    }

    /// The agent gone while a request waits: the request clears and the
    /// turn stops, once, within 5 s and a tick. The session stays, idle,
    /// and its later events count.
    @Test func aRequestClearsWhenItsAgentIsGone() {
        send(.turn, .start, "UserPromptSubmit")
        send(.tool, .start, "PreToolUse") { $0.tool = "Bash"; $0.toolUseID = "t1" }
        send(.tool, .wait, "PermissionRequest") { $0.tool = "Bash" }
        #expect(tick(for: 3000).isEmpty)
        processes.alive = []
        let died = now
        let changes = tick(for: 20_000)
        #expect(changes.count == 1)
        #expect(changes.first?.changes == ["claude/s1": .agentGone])
        #expect(changes.first.map { $0.at <= died + SessionTracker.liveCheckMs + 1000 } == true, "within 5 s and a tick")
        #expect(state() == "idle", "the session stays")
        let s = tracker.sessions["claude/s1"]
        #expect(s?.calls.isEmpty == true && s?.turn.startedAt == nil, "its turn is over")
        #expect(send(.tool, .end, "PostToolUse") { $0.tool = "Bash"; $0.toolUseID = "t1" } == .callEnded(nil, late: true),
                "a late result leaves it over")
        #expect(state() == "idle")
        processes.alive = [8]
        let fresh = AgentProcess(pid: 8, started: 2)
        #expect(send(.session, .start, "SessionStart", process: fresh) { $0.source = "resume" } == .sessionStarted(source: "resume"))
        #expect(tracker.sessions["claude/s1"]?.process == fresh)
        #expect(SessionTracker.liveCheckMs == 5000)
    }

    /// The agent gone mid-turn: the session stops working, and stays.
    @Test func aTurnStopsWhenItsAgentIsGone() {
        send(.turn, .start, "UserPromptSubmit")
        processes.alive = []
        #expect(tick(for: 10_000).map(\.changes) == [["claude/s1": .agentGone]])
        #expect(state() == "idle")
        #expect(tick(for: 60_000).isEmpty, "once")
    }

    /// A running process keeps a turn working past the hour that makes a
    /// silent one stale.
    @Test func aTurnWorksAsLongAsItsAgentRuns() {
        send(.turn, .start, "UserPromptSubmit")
        #expect(tick(for: 2 * SessionFold.staleWorkMs, every: 5000).isEmpty)
        #expect(state() == "working")
        #expect(SessionFold.staleWorkMs == 3_600_000)
    }

    /// An idle session's process isn't checked: one process outlives many
    /// sessions (the Codex app's one server, a new thread in a running
    /// CLI), and one may end with each turn. Running or not, the session
    /// stays, idle, and is forgotten after a day.
    @Test func anIdleSessionIsForgottenAfterADayWhateverItsProcess() {
        for alive in [true, false] {
            let tracker = SessionTracker(place: { _ in Place(project: "landing") }, isRunning: { _ in alive })
            var at: Int64 = 1_000_000
            for (kind, phase, hook) in [(AgentEvent.Kind.turn, AgentEvent.Phase.start, "UserPromptSubmit"),
                                        (.turn, .end, "Stop")] {
                at += 100
                var e = AgentEvent(agent: .codex, kind: kind, phase: phase, hook: hook, session: "s1", at: at, cwd: "/w")
                e.process = agent
                tracker.handle(e)
            }
            for t in stride(from: at + 5000, to: at + SessionFold.forgetMs, by: 60_000) {
                #expect(tracker.advance(to: t).isEmpty)
            }
            #expect(tracker.sessions["codex/s1"] != nil, "a day less a minute, idle")
            tracker.advance(to: at + SessionFold.forgetMs)
            #expect(tracker.sessions["codex/s1"] == nil, "forgotten, its process \(alive ? "running" : "gone")")
        }
        #expect(SessionFold.forgetMs == 86_400_000)
    }

    /// From an older hook client, with no process, the safety net still
    /// clears a request after 10 silent minutes.
    @Test func withNoProcessTheSafetyNetStillApplies() {
        send(.turn, .start, "UserPromptSubmit", process: .some(nil))
        send(.tool, .wait, "PermissionRequest", process: .some(nil)) { $0.tool = "Bash" }
        now += SessionFold.safetyNetMs
        #expect(tracker.advance(to: now) == ["claude/s1": .requestExpired])
        #expect(state() == "idle")
        #expect(processes.checks == 0)
    }

    /// A Codex request whose agent runs shows after its grace however
    /// long nobody ticked (the Mac slept).
    @Test func aCodexRequestWithItsAgentRunningShowsAfterASleep() {
        send(.turn, .start, "UserPromptSubmit", agent: .codex)
        send(.tool, .wait, "PermissionRequest", agent: .codex) { $0.tool = "shell" }
        now += SessionFold.safetyNetMs
        #expect(tracker.advance(to: now).isEmpty)
        #expect(state("codex/s1") == "needs_you")
    }

    /// The processes are checked at most every 5 s, and only those of
    /// sessions silent that long.
    @Test func checksAreThrottled() {
        send(.turn, .start, "UserPromptSubmit")
        let t = now
        tracker.advance(to: t + 4999)
        #expect(processes.checks == 0, "not yet")
        tracker.advance(to: t + 5000)
        #expect(processes.checks == 1)
        for ms in stride(from: Int64(6000), to: 10_000, by: 1000) { tracker.advance(to: t + ms) }
        #expect(processes.checks == 1, "not again within 5 s")
        tracker.advance(to: t + 10_000)
        #expect(processes.checks == 2)
        now = t + 12_000
        send(.tool, .start, "PreToolUse", after: 0) { $0.tool = "Bash" }
        tracker.advance(to: t + 15_000)
        #expect(processes.checks == 2, "heard from within 5 s")
    }
}
