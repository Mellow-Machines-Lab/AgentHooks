import AgentHooks
import Foundation
import Testing

/// Each hook becomes a kind and a phase, with the facts that
/// kind has. Only the public API, as an app sees it.
@Suite struct MappingTests {
    func line(_ agent: String, _ hook: String, tool: String? = nil, kind: String? = nil,
              configure: (inout HookLine) -> Void = { _ in }) -> HookLine {
        var l = HookLine(agent: agent, hook: hook, session: "s1", cwd: "/w/landing", tool: tool, kind: kind, ts: 7)
        configure(&l)
        return l
    }

    func shape(_ l: HookLine) -> String? {
        Mapping.event(from: l).map { "\($0.kind.rawValue) \($0.phase.rawValue)" }
    }

    @Test func everyHookHasItsKindAndPhase() {
        for (hook, kind) in Mapping.claude {
            guard let kind else { continue }
            #expect(shape(line("claude", hook)) == (hook.hasPrefix("Subagent") ? nil : "\(kind.kind) \(kind.phase)"),
                    "\(hook): a subagent's hook needs its agent_id")
        }
        for (hook, kind) in Mapping.codex {
            #expect(shape(line("codex", hook)) == "\(kind.kind) \(kind.phase)", "\(hook)")
        }
        #expect(shape(line("claude", "Notification", kind: "permission_prompt")) == "tool wait")
        #expect(shape(line("claude", "Notification", kind: "elicitation_dialog")) == "tool wait")
        #expect(shape(line("claude", "Notification", kind: "idle_prompt")) == "turn end")
        #expect(shape(line("claude", "Notification", kind: "auth_success")) == nil, "a type it doesn't map")
        #expect(shape(line("claude", "PreCompact")) == nil)
        #expect(shape(line("cursor", "Stop")) == nil, "an agent it doesn't know")
        #expect(Mapping.hooks(.claude).count == 14)
        #expect(Mapping.hooks(.codex).count == 8)
    }

    @Test func aTurnSaysHowItEnded() throws {
        let done = try #require(Mapping.event(from: line("claude", "Stop") { $0.message = "Fixed it." }))
        #expect(done.outcome == .done)
        #expect(done.message == "Fixed it.")
        let failed = try #require(Mapping.event(from: line("claude", "StopFailure") { $0.error = "server_error" }))
        #expect(failed.outcome == .failed)
        #expect(failed.error == "api_error")
        let esc = try #require(Mapping.event(from: line("claude", "PostToolUseFailure", tool: "Bash") { $0.interrupt = true }))
        #expect(esc.kind == .turn)
        #expect(esc.outcome == .stopped)
        #expect(esc.tool == "Bash")
        #expect(Mapping.event(from: line("codex", "Interrupt"))?.outcome == .stopped)
        let idle = try #require(Mapping.event(from: line("claude", "Notification", kind: "idle_prompt")))
        #expect(idle.outcome == .stopped)
        #expect(idle.notice == "idle_prompt")
    }

    @Test func aToolCallSaysWhetherItFailedOnlyFromClaude() throws {
        let failed = try #require(Mapping.event(from: line("claude", "PostToolUseFailure", tool: "Bash") {
            $0.toolError = "timeout"
            $0.topic = "tests"
        }))
        #expect(failed.failed == true)
        #expect(failed.error == "timeout")
        #expect(failed.topic == "tests")
        #expect(Mapping.event(from: line("claude", "PostToolUse", tool: "Bash"))?.failed == false)
        #expect(Mapping.event(from: line("codex", "PostToolUse", tool: "shell"))?.failed == nil, "Codex doesn't say")
        #expect(Mapping.event(from: line("claude", "PreToolUse", tool: "Bash"))?.failed == nil)
    }

    @Test func aWaitSaysWhatItAsksFor() {
        #expect(Mapping.event(from: line("claude", "PermissionRequest", tool: "Bash"))?.asking == .permission)
        #expect(Mapping.event(from: line("claude", "Elicitation"))?.asking == .input)
        let notice = Mapping.event(from: line("claude", "Notification", kind: "elicitation_dialog"))
        #expect(notice?.asking == .input)
        #expect(notice?.notice == "elicitation_dialog")
        #expect(Mapping.event(from: line("codex", "PermissionRequest", tool: "shell"))?.asking == .permission)
    }

    @Test func subagentsAndModesAreClaudes() {
        let sub = Mapping.event(from: line("claude", "SubagentStart") {
            $0.agentID = "a1"
            $0.agentType = "Explore"
            $0.mode = "plan"
        })
        #expect(sub?.subagent == "a1")
        #expect(sub?.subagentType == "Explore")
        #expect(sub?.mode == "plan")
        let codex = Mapping.event(from: line("codex", "PreToolUse", tool: "shell") {
            $0.agentID = "x"
            $0.mode = "plan"
        })
        #expect(codex?.subagent == nil)
        #expect(codex?.mode == nil)
    }

    @Test func theEventAsAJSONLine() throws {
        let e = try #require(Mapping.event(from: line("claude", "PreToolUse", tool: "Bash") {
            $0.toolUseID = "toolu_1"
            $0.topic = "build"
            $0.name = "Fix the nav"
        }, receivedAt: 99))
        #expect(e.at == 99)
        #expect(e.key == "claude/s1")
        #expect(e.jsonLine == #"{"agent":"claude","at":99,"cwd":"/w/landing","hook":"PreToolUse","kind":"tool","name":"Fix the nav","phase":"start","session":"s1","tool":"Bash","tool_use_id":"toolu_1","topic":"build"}"#)
        #expect(Mapping.errorClass("Request timeout") == "timeout")
        #expect(Mapping.errorClass("weird") == "other")
    }
}
