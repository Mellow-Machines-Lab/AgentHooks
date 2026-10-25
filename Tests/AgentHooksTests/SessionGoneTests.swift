import AgentHooks
import Foundation
import Testing

/// A request waits, and a turn works, as long as its agent's process runs.
/// A session ends when it's gone, whether or not its `SessionEnd` comes:
/// its process ended, it was archived in its app, or a newer thread took
/// its process; the Claude app's own threads outlive their process. Every
/// way out has a way back: its next start or prompt.
@Suite final class SessionGoneTests {
    final class World: @unchecked Sendable {
        var alive: Set<Int32> = [7]
        /// Each thread's state in its app, by session ID: open if not said.
        var threads: [String: ThreadArchive.State] = [:]
        var checks = 0
    }

    let world: World
    let tracker: SessionTracker
    var now: Int64 = 1_000_000
    let agent = AgentProcess(pid: 7, started: 1)
    static let appThread = "local_3d70f836-1432-467b-b6b6-06fb9829a5b6"

    init() {
        let world = World()
        self.world = world
        tracker = SessionTracker(firstRequest: 100, place: { Place(project: ($0 as NSString).lastPathComponent) },
                                 isRunning: { world.checks += 1; return world.alive.contains($0.pid) },
                                 archive: { world.threads[$0.session] ?? .open })
    }

    @discardableResult
    func send(_ kind: AgentEvent.Kind, _ phase: AgentEvent.Phase, _ hook: String, agent: Agent = .claude,
              session: String = "s1", process: AgentProcess?? = .none, after ms: Int64 = 100,
              _ configure: (inout AgentEvent) -> Void = { _ in }) -> SessionTracker.Change? {
        now += ms
        var e = AgentEvent(agent: agent, kind: kind, phase: phase, hook: hook, session: session, at: now, cwd: "/w/landing")
        e.process = process ?? self.agent
        configure(&e)
        return tracker.handle(e)
    }

    /// A thread the Claude app runs itself.
    static func inApp(_ e: inout AgentEvent) {
        e.app = HostApp.claude
        e.appSession = appThread
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

    /// Up to a silent day, when any session is forgotten: the table is
    /// what a day of events rebuilds.
    @Test func aRequestWaitsAsLongAsItsAgentRunsUpToADay() {
        send(.turn, .start, "UserPromptSubmit")
        send(.tool, .wait, "PermissionRequest") { $0.tool = "Bash" }
        let asked = now
        let request = tracker.sessions["claude/s1"]?.request
        #expect(tick(for: 2 * 60 * 60 * 1000, every: 5000).isEmpty, "two hours at lunch")
        #expect(state() == "needs_you")
        #expect(tracker.sessions["claude/s1"]?.request == request, "the same request")
        #expect(world.checks > 0)
        now = asked + SessionFold.forgetMs - 1
        tracker.advance(to: now)
        #expect(state() == "needs_you", "a day less a moment, and its agent still waits")
        now += 1
        #expect(tracker.advance(to: now).isEmpty)
        #expect(state() == "gone", "a silent day: forgotten, as a launch that reads a day back would have it")
    }

    /// The agent gone while a request waits: the session ends, once,
    /// within 5 s and a tick, as if its `SessionEnd` had come. Its late
    /// hooks don't bring it back; its start does.
    @Test func aSessionEndsWhenItsAgentIsGone() {
        send(.turn, .start, "UserPromptSubmit")
        send(.tool, .start, "PreToolUse") { $0.tool = "Bash"; $0.toolUseID = "t1" }
        send(.tool, .wait, "PermissionRequest") { $0.tool = "Bash" }
        #expect(tick(for: 3000).isEmpty)
        world.alive = []
        let died = now
        let changes = tick(for: 20_000)
        #expect(changes.count == 1)
        #expect(changes.first?.changes == ["claude/s1": .sessionGone(.process)])
        #expect(changes.first.map { $0.at <= died + SessionTracker.liveCheckMs + 1000 } == true, "within 5 s and a tick")
        #expect(state() == "gone")
        #expect(send(.tool, .end, "PostToolUse") { $0.tool = "Bash"; $0.toolUseID = "t1" } == nil, "a late result")
        #expect(state() == "gone")
        world.alive = [8]
        let fresh = AgentProcess(pid: 8, started: 2)
        #expect(send(.session, .start, "SessionStart", process: fresh) { $0.source = "resume" } == .sessionStarted(source: "resume"))
        #expect(tracker.sessions["claude/s1"]?.process == fresh, "resumed")
        #expect(SessionTracker.liveCheckMs == 5000)
    }

    /// An idle session whose agent is gone ends too: a terminal closed at
    /// the prompt, or a Remote Control session archived on claude.ai,
    /// which ends its process and may send no `SessionEnd`.
    @Test func anIdleSessionEndsWhenItsAgentIsGone() {
        send(.turn, .start, "UserPromptSubmit") { $0.app = HostApp.claude; $0.appSession = "session_01GGTiWRKfXz7LCA" }
        send(.turn, .end, "Stop") { $0.outcome = .done }
        #expect(tick(for: 60_000).isEmpty, "idle, its agent running")
        world.alive = []
        #expect(tick(for: 10_000).map(\.changes) == [["claude/s1": .sessionGone(.process)]])
        #expect(tick(for: 60_000).isEmpty, "once")
        #expect(send(.turn, .start, "UserPromptSubmit") == .turnStarted, "a prompt brings it back")
        #expect(state() == "working")
    }

    /// The Claude app keeps a thread whose process ended, and starts it
    /// again when you open it: the request clears and the turn stops, and
    /// the thread stays, idle, until its app archives or deletes it.
    @Test func aClaudeAppThreadOutlivesItsProcess() {
        send(.turn, .start, "UserPromptSubmit", Self.inApp)
        #expect(tracker.sessions["claude/s1"]?.lifetime == Lifetime(endsWithProcess: false, oneThreadPerProcess: false))
        world.alive = []
        #expect(tick(for: 10_000).map(\.changes) == [["claude/s1": .agentGone]])
        #expect(state() == "idle")
        #expect(tick(for: 60_000).isEmpty, "kept in the app")
        world.threads["s1"] = .archived
        #expect(tick(for: 10_000).map(\.changes) == [["claude/s1": .sessionGone(.archived)]])
        #expect(state() == "gone")
    }

    /// A Claude app thread ends when its app archives it, whatever its
    /// process, or deletes it once its process is gone too.
    @Test func aClaudeAppThreadEndsWhenItsAppArchivesOrDeletesIt() {
        send(.turn, .start, "UserPromptSubmit", Self.inApp)
        send(.turn, .end, "Stop", { Self.inApp(&$0); $0.outcome = .done })
        world.threads["s1"] = .archived
        #expect(tick(for: 10_000).map(\.changes) == [["claude/s1": .sessionGone(.archived)]], "its process running")

        send(.turn, .start, "UserPromptSubmit", Self.inApp)
        world.threads["s1"] = .missing
        send(.turn, .end, "Stop", { Self.inApp(&$0); $0.outcome = .done })
        #expect(tick(for: 60_000).isEmpty, "no record, but its process runs: the app may not have written it")
        world.alive = []
        #expect(tick(for: 10_000).map(\.changes) == [["claude/s1": .sessionGone(.process)]], "deleted")
    }

    /// A thread that waits or works is running, whatever its app says: it
    /// ends once it's idle.
    @Test func aThreadThatWorksOutlastsItsArchive() {
        send(.turn, .start, "UserPromptSubmit", Self.inApp)
        world.threads["s1"] = .archived
        #expect(tick(for: 60_000).isEmpty)
        #expect(state() == "working")
        send(.tool, .wait, "PermissionRequest", { Self.inApp(&$0); $0.tool = "Bash" })
        #expect(tick(for: 60_000).isEmpty)
        #expect(state() == "needs_you")
        send(.turn, .end, "Stop", { Self.inApp(&$0); $0.outcome = .done })
        #expect(tick(for: 10_000).map(\.changes) == [["claude/s1": .sessionGone(.archived)]])
    }

    /// Codex archives a thread in its app, whose one server runs on, or
    /// from the CLI: the thread ends once it's idle.
    @Test func aCodexThreadEndsWhenArchived() {
        for app in [HostApp.codex, "com.mitchellh.ghostty"] {
            send(.turn, .start, "UserPromptSubmit", agent: .codex) { $0.app = app }
            send(.turn, .end, "Stop", agent: .codex) { $0.app = app; $0.outcome = .done }
            #expect(tick(for: 60_000).isEmpty)
            world.threads["s1"] = .archived
            #expect(tick(for: 10_000).map(\.changes) == [["codex/s1": .sessionGone(.archived)]], "\(app)")
            world.threads = [:]
        }
    }

    /// A process that runs one thread at a time runs the one that started
    /// last: an idle thread a newer one replaced in it, with no
    /// `SessionEnd` (`/clear`, `/resume`), ends. One that waits doesn't, nor
    /// one whose process runs every thread (the Codex app's server), nor a
    /// Claude app thread.
    @Test func aNewerThreadInItsProcessEndsAnIdleOne() {
        send(.turn, .start, "UserPromptSubmit")
        send(.turn, .end, "Stop") { $0.outcome = .done }
        send(.session, .start, "SessionStart", session: "s2") { $0.source = "clear" }
        #expect(tick(for: 10_000).map(\.changes) == [["claude/s1": .sessionGone(.replaced)]])
        #expect(state("claude/s2") == "idle", "the newer stays")

        send(.turn, .start, "UserPromptSubmit", session: "s3")
        send(.tool, .wait, "PermissionRequest", session: "s3") { $0.tool = "Bash" }
        send(.turn, .start, "UserPromptSubmit", session: "s4")
        #expect(tick(for: 10_000).map(\.changes) == [["claude/s2": .sessionGone(.replaced)]], "not s3, which waits")
        #expect(state("claude/s3") == "needs_you")

        for (agent, app): (Agent, (inout AgentEvent) -> Void) in [(.codex, { $0.app = HostApp.codex }), (.claude, Self.inApp)] {
            send(.turn, .start, "UserPromptSubmit", agent: agent, session: "a", process: AgentProcess(pid: 7, started: 9), app)
            send(.turn, .end, "Stop", agent: agent, session: "a", process: AgentProcess(pid: 7, started: 9)) {
                app(&$0)
                $0.outcome = .done
            }
            send(.turn, .start, "UserPromptSubmit", agent: agent, session: "b", process: AgentProcess(pid: 7, started: 9), app)
            #expect(tick(for: 60_000).isEmpty, "\(agent)")
            #expect(state("\(agent.rawValue)/a") == "idle")
        }
    }

    /// A turn silent an hour isn't working, even while its agent's
    /// process runs: its `Stop` was lost, or an interrupt sent none. It
    /// stays, idle, and its next event works again.
    @Test func aTurnSilentAnHourIsIdleWhateverItsProcess() {
        send(.turn, .start, "UserPromptSubmit")
        let started = now
        #expect(tick(for: SessionFold.staleWorkMs - 5000, every: 5000).isEmpty)
        #expect(state() == "working", "its agent runs")
        now = started + SessionFold.staleWorkMs
        #expect(tracker.advance(to: now).isEmpty)
        #expect(state() == "idle", "an hour silent")
        #expect(tick(for: 60_000).isEmpty)
        send(.tool, .start, "PreToolUse") { $0.tool = "Bash" }
        #expect(state() == "working")
        #expect(SessionFold.staleWorkMs == 3_600_000)
    }

    /// An idle session whose agent runs, and a Claude app thread kept in
    /// its app, are forgotten after a silent day.
    @Test func anIdleSessionIsForgottenAfterADay() {
        for (alive, inApp) in [(true, false), (false, true)] {
            world.alive = alive ? [7] : []
            let tracker = SessionTracker(place: { _ in Place(project: "landing") }, isRunning: { [world] in world.alive.contains($0.pid) },
                                         archive: { _ in .open })
            var at: Int64 = 1_000_000
            for (kind, phase, hook) in [(AgentEvent.Kind.turn, AgentEvent.Phase.start, "UserPromptSubmit"),
                                        (.turn, .end, "Stop")] {
                at += 100
                var e = AgentEvent(agent: .claude, kind: kind, phase: phase, hook: hook, session: "s1", at: at, cwd: "/w")
                e.process = agent
                if inApp { Self.inApp(&e) }
                tracker.handle(e)
            }
            for t in stride(from: at + 5000, to: at + SessionFold.forgetMs, by: 60_000) {
                #expect(tracker.advance(to: t).isEmpty)
            }
            #expect(tracker.sessions["claude/s1"] != nil, "a day less a minute, idle")
            tracker.advance(to: at + SessionFold.forgetMs)
            #expect(tracker.sessions["claude/s1"] == nil, "forgotten, \(inApp ? "kept in its app" : "its process running")")
        }
        #expect(SessionFold.forgetMs == 86_400_000)
    }

    /// From an older hook client, with no process, the safety net still
    /// clears a request after 10 silent minutes, and the session stays.
    @Test func withNoProcessTheSafetyNetStillApplies() {
        send(.turn, .start, "UserPromptSubmit", process: .some(nil))
        send(.tool, .wait, "PermissionRequest", process: .some(nil)) { $0.tool = "Bash" }
        now += SessionFold.safetyNetMs
        #expect(tracker.advance(to: now) == ["claude/s1": .requestExpired])
        #expect(state() == "idle")
        #expect(world.checks == 0)
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

    /// The sessions are checked at most every 5 s, and only those silent
    /// that long.
    @Test func checksAreThrottled() {
        send(.turn, .start, "UserPromptSubmit")
        let t = now
        tracker.advance(to: t + 4999)
        #expect(world.checks == 0, "not yet")
        tracker.advance(to: t + 5000)
        #expect(world.checks == 1)
        for ms in stride(from: Int64(6000), to: 10_000, by: 1000) { tracker.advance(to: t + ms) }
        #expect(world.checks == 1, "not again within 5 s")
        tracker.advance(to: t + 10_000)
        #expect(world.checks == 2)
        now = t + 12_000
        send(.tool, .start, "PreToolUse", after: 0) { $0.tool = "Bash" }
        tracker.advance(to: t + 15_000)
        #expect(world.checks == 2, "heard from within 5 s")
    }

    /// When nothing can tell a session is gone, an app can end it by hand,
    /// as its `SessionEnd` would; its next prompt brings it back.
    @Test func anAppCanEndASessionByHand() {
        send(.turn, .start, "UserPromptSubmit")
        send(.turn, .end, "Stop") { $0.outcome = .done }
        #expect(tracker.end("claude/s1", at: now))
        #expect(state() == "gone")
        #expect(!tracker.end("claude/s1", at: now), "none left to end")
        #expect(send(.tool, .start, "PreToolUse") { $0.tool = "Bash" } == nil, "a stray hook doesn't bring it back")
        #expect(send(.turn, .start, "UserPromptSubmit") == .turnStarted)
        #expect(state() == "working")
    }
}

/// Where a thread stands in its app, from the app's own records, and how
/// long a session lasts by where it runs. A record that can't be read says
/// the thread is open.
@Suite struct ThreadArchiveTests {
    static let id = "local_3d70f836-1432-467b-b6b6-06fb9829a5b6"

    @Test func theClaudeAppsRecordSaysWhetherItsThreadIsArchived() throws {
        let home = tempDir("archive-claude")
        defer { try? FileManager.default.removeItem(at: home) }
        let thread = ThreadRef(agent: "claude", session: "s1", app: HostApp.claude, appSession: Self.id)
        func state() -> ThreadArchive.State { ThreadArchive.state(thread, home: home.path, codexHome: home.path) }
        #expect(state() == .open, "no folder of records: nothing to say")

        let root = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        let org = root.appendingPathComponent("a1/o1")
        try FileManager.default.createDirectory(at: org, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent(".DS_Store"))
        #expect(state() == .missing, "no record in any account: deleted")

        let record = org.appendingPathComponent("\(Self.id).json")
        func write(_ object: Any) throws { try JSONSerialization.data(withJSONObject: object).write(to: record) }
        try write(["sessionId": Self.id, "isArchived": true])
        #expect(state() == .archived)
        try write(["sessionId": Self.id, "isArchived": false])
        #expect(state() == .open)
        try write(["sessionId": Self.id])
        #expect(state() == .open)
        try write(["sessionId": "local_other", "isArchived": true])
        #expect(state() == .open, "another's record")
        try Data("{not json".utf8).write(to: record)
        #expect(state() == .open, "a record that lost its shape")

        for other in [ThreadRef(agent: "claude", session: "s1"),
                      ThreadRef(agent: "claude", session: "s1", app: HostApp.claude, appSession: "session_01GGTiWRKfXz7LCA"),
                      ThreadRef(agent: "claude", session: "s1", appSession: "local_../x")] {
            #expect(ThreadArchive.state(other, home: home.path, codexHome: home.path) == .open, "\(other)")
        }
    }

    @Test func codexsFolderOfArchivedThreadsSaysWhetherItsThreadIsArchived() throws {
        let home = tempDir("archive-codex")
        defer { try? FileManager.default.removeItem(at: home) }
        let thread = "019f298b-8331-78f1-8a0d-92c1ead9f22d"
        func state(_ session: String = thread) -> ThreadArchive.State {
            ThreadArchive.state(ThreadRef(agent: "codex", session: session), home: home.path, codexHome: home.path)
        }
        #expect(state() == .open, "no folder")
        let archived = home.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        #expect(state() == .open)
        try Data().write(to: archived.appendingPathComponent("rollout-2026-07-03T12-53-56-\(thread).jsonl.zst"))
        #expect(state() == .archived)
        try Data().write(to: archived.appendingPathComponent("rollout-2026-07-03T12-57-49-019f298f.jsonl"))
        #expect(state("019f298f") == .archived, "uncompressed")
        #expect(state("8f") == .open, "only the whole ID")
        #expect(state("") == .open)
        #expect(state("../\(thread)") == .open)
    }

    @Test func aSessionLastsByWhereItRuns() {
        func life(_ agent: String, app: String? = nil, appSession: String? = nil, terminal: TerminalTab? = nil) -> [Bool] {
            let l = Lifetime.of(ThreadRef(agent: agent, session: "s1", app: app, appSession: appSession, terminal: terminal))
            return [l.endsWithProcess, l.oneThreadPerProcess]
        }
        let tab = TerminalTab(program: "ghostty")
        #expect(life("claude", app: "com.mitchellh.ghostty", terminal: tab) == [true, true], "Claude Code in a terminal")
        #expect(life("claude", app: HostApp.claude, appSession: "session_01GGTiWRKfXz7LCA") == [true, true], "by Remote Control")
        #expect(life("claude", app: HostApp.claude, appSession: Self.id) == [false, false], "the Claude app's own")
        #expect(life("codex", app: "com.mitchellh.ghostty", terminal: tab) == [true, true], "the Codex CLI")
        #expect(life("codex", app: HostApp.codex) == [true, false], "the Codex app's one server")
        #expect(life("codex") == [true, false], "no app or terminal named: the app's")
    }
}
