import AgentHooks
import Foundation
import Testing

/// Sessions and "needs you", through the public API only, as an
/// app sees them. The app that grew these rules pins every case in its own
/// tests too; these are the ones an app most relies on.
@Suite final class SessionTrackerTests {
    let tracker = SessionTracker(firstRequest: 100, place: { Place(project: ($0 as NSString).lastPathComponent) })
    var now: Int64 = 1_000_000

    @discardableResult
    func send(_ kind: AgentEvent.Kind, _ phase: AgentEvent.Phase, _ hook: String, agent: Agent = .claude,
              session: String = "s1", after ms: Int64 = 100,
              _ configure: (inout AgentEvent) -> Void = { _ in }) -> SessionTracker.Change? {
        now += ms
        var e = AgentEvent(agent: agent, kind: kind, phase: phase, hook: hook, session: session, at: now, cwd: "/w/landing")
        configure(&e)
        return tracker.handle(e)
    }

    func state(_ key: String = "claude/s1") -> String {
        let (waiting, working, _) = tracker.grouped(at: now)
        if waiting.contains(where: { $0.key == key }) { return "needs_you" }
        if working.contains(where: { $0.key == key }) { return "working" }
        return tracker.sessions[key] == nil ? "gone" : "idle"
    }

    @Test func aTurnWorksThenGoesIdle() {
        #expect(send(.session, .start, "SessionStart") { $0.source = "resume" } == .sessionStarted(source: "resume"))
        #expect(state() == "idle")
        #expect(send(.turn, .start, "UserPromptSubmit") == .turnStarted)
        #expect(state() == "working")
        #expect(tracker.sessions["claude/s1"]?.project == "landing")
        guard case .callStarted(let call)? = send(.tool, .start, "PreToolUse", { $0.tool = "Bash"; $0.toolUseID = "t1"; $0.topic = "tests" })
        else { Issue.record("no call started"); return }
        #expect(call.topic == "tests")
        #expect(tracker.sessions["claude/s1"]?.calls.count == 1)
        #expect(send(.tool, .end, "PostToolUse", { $0.tool = "Bash"; $0.toolUseID = "t1" }) == .callEnded(call, late: false))
        #expect(send(.turn, .end, "Stop") { $0.outcome = .done } == .turnEnded(.done, endedTurn: true))
        #expect(state() == "idle")
        #expect(send(.session, .end, "SessionEnd") == .sessionEnded)
        #expect(state() == "gone")
    }

    @Test func claudesRequestShowsAtOnceAndItsCallAnswersIt() {
        send(.turn, .start, "UserPromptSubmit")
        send(.tool, .wait, "PermissionRequest") { $0.tool = "Bash"; $0.asking = .permission }
        #expect(state() == "needs_you")
        #expect(tracker.needsYou)
        #expect(tracker.sessions["claude/s1"]?.request == 101, "numbers count on from firstRequest")
        #expect(tracker.sessions["claude/s1"]?.asking == .permission)
        send(.tool, .start, "PreToolUse") { $0.tool = "Bash" }
        #expect(state() == "working", "the call ran: you approved")
    }

    @Test func codexsRequestWaitsForItsGrace() {
        send(.turn, .start, "UserPromptSubmit", agent: .codex)
        send(.tool, .wait, "PermissionRequest", agent: .codex) { $0.tool = "shell" }
        let asked = now
        #expect(state("codex/s1") == "working", "its reviewer may still approve it")
        now += SessionTracker.codexGraceMs
        tracker.advance(to: now)
        #expect(state("codex/s1") == "needs_you")
        #expect(tracker.sessions["codex/s1"]?.needsSince == asked + 2000)

        send(.tool, .wait, "PermissionRequest", agent: .codex, session: "s2") { $0.tool = "shell" }
        send(.tool, .start, "PreToolUse", agent: .codex, session: "s2", after: 500) { $0.tool = "shell" }
        now += 5000
        tracker.advance(to: now)
        #expect(state("codex/s2") == "working", "answered inside the grace: never shown")
        #expect(SessionTracker.codexGraceMs == 2000)
    }

    @Test func aNotificationAndItsOwnHookCountOnce() {
        send(.turn, .start, "UserPromptSubmit")
        send(.tool, .wait, "Notification") { $0.notice = "permission_prompt" }
        let first = tracker.sessions["claude/s1"]?.request
        send(.tool, .wait, "PermissionRequest", after: 50) { $0.tool = "Bash" }
        #expect(tracker.sessions["claude/s1"]?.request == first, "the same request")
        #expect(tracker.sessions["claude/s1"]?.askers == ["": "Bash"], "its own hook takes it over")
        send(.tool, .end, "PostToolUse") { $0.tool = "Bash" }
        #expect(state() == "working")
        send(.tool, .wait, "Notification", after: 200) { $0.notice = "permission_prompt" }
        #expect(state() == "working", "a late copy of the request that just cleared")
    }

    @Test func aSubagentAskingBesideItsParentIsAnotherRequest() {
        send(.turn, .start, "UserPromptSubmit")
        send(.tool, .wait, "PermissionRequest") { $0.tool = "Bash" }
        let first = tracker.sessions["claude/s1"]!.request
        send(.tool, .wait, "PermissionRequest") { $0.tool = "Edit"; $0.subagent = "a1" }
        #expect(tracker.sessions["claude/s1"]?.askers == ["": "Bash", "a1": "Edit"])
        send(.tool, .start, "PreToolUse") { $0.tool = "Bash" }
        #expect(state() == "needs_you", "the subagent still asks")
        #expect(tracker.sessions["claude/s1"]!.request > first, "a new request, so an app alerts again")
    }

    @Test func theSafetyNetClearsASilentRequest() {
        send(.turn, .start, "UserPromptSubmit")
        send(.tool, .wait, "PermissionRequest") { $0.tool = "Bash" }
        now += SessionFold.safetyNetMs
        tracker.advance(to: now)
        #expect(state() == "idle")
        #expect(tracker.clearedWhy["claude/s1"] == "nothing for 10 minutes")
        #expect(SessionFold.safetyNetMs == 600_000)
    }

    @Test func aHookAfterItsSessionEndedIsLetGo() {
        send(.turn, .start, "UserPromptSubmit")
        send(.session, .end, "SessionEnd")
        #expect(send(.tool, .wait, "Notification") { $0.notice = "permission_prompt" } == nil)
        #expect(state() == "gone")
        #expect(send(.turn, .start, "UserPromptSubmit") == .turnStarted, "a new prompt brings it back")
    }

    @Test func anIdleNoticeFromBeforeThePromptIsStale() {
        send(.turn, .start, "UserPromptSubmit")
        #expect(send(.turn, .end, "Notification", after: 5000) { $0.outcome = .stopped; $0.notice = "idle_prompt" } == nil)
        #expect(state() == "working")
        #expect(send(.turn, .end, "Notification", after: SessionFold.idleNoticeMinMs) {
            $0.outcome = .stopped
            $0.notice = "idle_prompt"
        } == .turnEnded(.stopped, endedTurn: true))
    }

    @Test func aSilentSessionIsForgotten() {
        send(.turn, .start, "UserPromptSubmit")
        now += SessionFold.staleWorkMs
        #expect(state() == "idle", "an hour silent isn't working")
        now += SessionFold.forgetMs
        tracker.advance(to: now)
        #expect(state() == "gone")
    }

    @Test func aHelperReturnsWhileItsTurnGoesOn() {
        send(.turn, .start, "UserPromptSubmit")
        #expect(send(.subagent, .start, "SubagentStart") { $0.subagent = "a1" } == .subagentStarted)
        #expect(tracker.sessions["claude/s1"]?.helpers == ["a1"])
        #expect(send(.subagent, .end, "SubagentStop") { $0.subagent = "a1" } == .subagentEnded(returned: true))
    }

    @Test func requestNumbersWrapPastTheirLimit() {
        #expect(SessionTracker.nextRequest(after: SessionTracker.maxRequest) == 1)
        #expect(SessionTracker.nextRequest(after: 7) == 8)
    }
}
