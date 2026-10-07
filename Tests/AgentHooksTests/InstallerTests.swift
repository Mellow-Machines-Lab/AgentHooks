import Foundation
import Testing
@testable import AgentHooks

/// Every test runs on a temporary HOME; your own `~/.claude` and
/// `~/.codex` are never touched.
@Suite final class InstallerTests {
    var home: URL!
    var installer: HookInstaller!
    var hook = ""

    init() throws {
        home = tempDir("agent-hooks-home")
        try! FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        hook = placeClient("Library/Application Support/SomeApp/bin/agent-hook")
        installer = HookInstaller(home: home, hookPath: hook, formerClients: ["/.old/old-hook.sh"])
    }

    /// An executable stand-in for `agent-hook` under HOME; returns its path.
    func placeClient(_ path: String) -> String {
        let url = home.appendingPathComponent(path)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data("#!/bin/sh\n".utf8).write(to: url)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    deinit {
        try? FileManager.default.removeItem(at: home)
    }

    func write(_ agent: Agent, _ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        try! data.write(to: installer.configURL(agent))
    }

    func read(_ agent: Agent) -> [String: Any] {
        let data = try! Data(contentsOf: installer.configURL(agent))
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func commands(_ agent: Agent, _ event: String) -> [String] {
        let groups = (read(agent)["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
        return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    /// A user's own hooks, plus an older client's entries (`formerClients`).
    let existing: [String: Any] = [
        "model": "opus",
        "hooks": [
            "PreToolUse": [
                ["matcher": "Bash", "hooks": [["type": "command", "command": "/usr/local/bin/audit.sh"]]],
                ["hooks": [["type": "command", "command": "/Users/x/.old/old-hook.sh claude-code", "timeout": 310]]],
            ],
            "Stop": [
                ["hooks": [
                    ["type": "command", "command": "say done"],
                    ["type": "command", "command": "/Users/x/.old/old-hook.sh claude-code"],
                ]],
            ],
            "UserPromptSubmit": [["hooks": [["type": "command", "command": "/Users/x/.old/old-hook.sh claude-code"]]]],
        ],
    ]

    @Test func testInstallsEveryClaudeHookAndKeepsOthers() throws {
        write(.claude, existing)
        #expect(installer.health(.claude) == .outdated)  // old-generation entries
        try installer.install(.claude)
        #expect(installer.health(.claude) == .installed)
        let root = read(.claude)
        #expect((root["model"] as? String) == "opus")
        let ours = "\"\(hook)\" claude"
        for event in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
                      "PermissionRequest", "Notification", "Elicitation", "ElicitationResult", "Stop", "StopFailure",
                      "SubagentStart", "SubagentStop", "SessionEnd"] {
            #expect((commands(.claude, event).filter(installer.isOurs)) == [ours], "\(event)")
        }
        #expect((commands(.claude, "PreToolUse")) == (["/usr/local/bin/audit.sh", ours]))
        #expect((commands(.claude, "Stop")) == (["say done", ours]))
        #expect(!(String(decoding: try Data(contentsOf: installer.configURL(.claude)), as: UTF8.self).contains("old-hook.sh")))
        let notification = (root["hooks"] as! [String: Any])["Notification"] as! [[String: Any]]
        #expect((notification.first?["matcher"] as? String) == ("permission_prompt|elicitation_dialog|idle_prompt"))
    }

    /// The hooks come from the adapter's tables, in the
    /// order installs already have, so none reads as outdated.
    @Test func testTheHooksKeepTheirOrder() {
        #expect((HookInstaller.events[.claude]!.map { $0.event + ($0.matcher.map { " " + $0 } ?? "") }) == ([
            "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest",
            "Notification permission_prompt|elicitation_dialog|idle_prompt", "Elicitation", "ElicitationResult", "Stop",
            "StopFailure", "SubagentStart", "SubagentStop", "SessionEnd",
        ]))
        #expect((HookInstaller.events[.codex]!.map { $0.event + ($0.matcher.map { " " + $0 } ?? "") }) == ([
            "SessionStart startup|resume|clear", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
            "Stop", "Interrupt", "SessionEnd",
        ]))
    }

    /// Claude runs a `Notification` hook only for the types
    /// its matcher lists, so the matcher lists every type the adapter maps,
    /// `idle_prompt` included, and an install with the old matcher is
    /// repaired at the next launch.
    @Test func testTheNotificationMatcherListsEveryTypeTheAdapterMaps() throws {
        let matcher = HookInstaller.events[.claude]!.first { $0.event == "Notification" }!.matcher!
        #expect(matcher == ("permission_prompt|elicitation_dialog|idle_prompt"), "the order installs already have")
        for type in matcher.split(separator: "|").map(String.init) {
            let line = HookLine(agent: "claude", hook: "Notification", session: "s", kind: type, ts: 1)
            #expect((Mapping.event(from: line)) != nil, "\(type)")
        }

        try installer.install(.claude)
        var root = read(.claude)
        var hooks = root["hooks"] as! [String: Any]
        hooks["Notification"] = [["matcher": "permission_prompt|elicitation_dialog",
                                  "hooks": [["type": "command", "command": installer.command(.claude), "timeout": 5]]]]
        root["hooks"] = hooks
        write(.claude, root)
        #expect(installer.health(.claude) == .outdated)
        #expect(installer.repair() == [.claude])
        let notification = (read(.claude)["hooks"] as! [String: Any])["Notification"] as! [[String: Any]]
        #expect((notification.map { $0["matcher"] as? String }) == [matcher])
    }

    /// Claude gets 14 hooks. An install from before
    /// `SubagentStop` was hooked is outdated, so the app's launch repair
    /// adds it, beside a `SubagentStop` hook of the person's own, and
    /// changes nothing else.
    @Test func testAnInstallWithoutSubagentStopIsRepaired() throws {
        #expect(HookInstaller.events[.claude]!.count == 14)
        let entry: [String: Any] = ["type": "command", "command": installer.command(.claude), "timeout": 5]
        var hooks: [String: Any] = [:]
        for event in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
                      "PermissionRequest", "Elicitation", "ElicitationResult", "Stop", "StopFailure", "SubagentStart",
                      "SessionEnd"] {
            hooks[event] = [["hooks": [entry]]]
        }
        hooks["Notification"] = [["matcher": "permission_prompt|elicitation_dialog|idle_prompt", "hooks": [entry]]]
        hooks["SubagentStop"] = [["matcher": "Explore", "hooks": [["type": "command", "command": "say explored"]]]]
        write(.claude, ["model": "opus", "hooks": hooks])
        #expect(installer.health(.claude) == .outdated)
        #expect(installer.repair() == [.claude])
        #expect(installer.health(.claude) == .installed)
        #expect((commands(.claude, "SubagentStop")) == (["say explored", installer.command(.claude)]))
        let groups = (read(.claude)["hooks"] as! [String: Any])["SubagentStop"] as! [[String: Any]]
        #expect((groups.map { $0["matcher"] as? String }) == (["Explore", nil]), "ours runs for every subagent")
        #expect((read(.claude)["model"] as? String) == "opus")
        #expect(installer.repair() == [])
        #expect(installer.preview(.claude).contains("\nSubagentStop → \(installer.command(.claude))\n"))
    }

    /// An install from before `SubagentStart` was hooked
    /// (13 hooks) is outdated, so the launch repair adds it and changes
    /// nothing else: apps need it to see helpers start.
    @Test func testAnInstallWithoutSubagentStartIsRepaired() throws {
        try installer.install(.claude)
        var root = read(.claude)
        var hooks = root["hooks"] as! [String: Any]
        hooks["SubagentStart"] = nil
        root["hooks"] = hooks
        write(.claude, root)
        #expect(installer.health(.claude) == .outdated)
        #expect(installer.repair() == [.claude])
        #expect(installer.health(.claude) == .installed)
        #expect((commands(.claude, "SubagentStart")) == [installer.command(.claude)])
        let groups = (read(.claude)["hooks"] as! [String: Any])["SubagentStart"] as! [[String: Any]]
        #expect((groups.map { $0["matcher"] as? String }) == [nil], "every subagent")
        #expect(installer.preview(.claude).contains("\nSubagentStart → \(installer.command(.claude))\n"))
        #expect(!(HookInstaller.events[.codex]!.contains { $0.event == "SubagentStart" }), "Codex has none")
    }

    /// Health looks at its own entries only. A hook of the
    /// person's added after ours (Claude's /hooks appends), or inside our
    /// group, leaves it installed, so the launch repair doesn't rewrite the
    /// file and ask for a restart. Our entry twice, or
    /// under a matcher of the person's, is still outdated.
    @Test func testOthersHooksBesideOursLeaveItInstalled() throws {
        try installer.install(.claude)
        var root = read(.claude)
        var hooks = root["hooks"] as! [String: Any]
        let other: [String: Any] = ["type": "command", "command": "~/bin/other-tool.sh"]
        hooks["PreToolUse"] = hooks["PreToolUse"] as! [[String: Any]] + [["matcher": "Edit", "hooks": [other]]]
        var stop = hooks["Stop"] as! [[String: Any]]
        stop[0]["hooks"] = stop[0]["hooks"] as! [[String: Any]] + [other]
        hooks["Stop"] = stop
        root["hooks"] = hooks
        write(.claude, root)
        let url = installer.configURL(.claude)
        let before = try Data(contentsOf: url)
        #expect(installer.health(.claude) == .installed)
        #expect(installer.repair() == [])
        #expect((try Data(contentsOf: url)) == before)

        let entry: [String: Any] = ["type": "command", "command": installer.command(.claude), "timeout": 5]
        var twice = hooks
        twice["PostToolUse"] = twice["PostToolUse"] as! [[String: Any]] + [["hooks": [entry]]]
        write(.claude, ["hooks": twice])
        #expect(installer.health(.claude) == .outdated)
        var matched = hooks
        stop[0]["matcher"] = "Explore"
        matched["Stop"] = stop
        write(.claude, ["hooks": matched])
        #expect(installer.health(.claude) == .outdated)
    }

    @Test func testInstallIsIdempotent() throws {
        write(.claude, existing)
        try installer.install(.claude)
        let url = installer.configURL(.claude)
        let first = try Data(contentsOf: url)
        let stamp = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as! Date
        Thread.sleep(forTimeInterval: 0.02)
        try installer.install(.claude)
        #expect((try Data(contentsOf: url)) == first)
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) == stamp)
        #expect(installer.repair() == [])
    }

    @Test func testRemoveTakesOnlyOurEntries() throws {
        write(.claude, existing)
        try installer.install(.claude)
        try installer.remove(.claude)
        #expect(installer.health(.claude) == .notInstalled)
        #expect((commands(.claude, "PreToolUse")) == (["/usr/local/bin/audit.sh"]))
        #expect((commands(.claude, "Stop")) == (["say done"]))
        #expect(((read(.claude)["hooks"] as! [String: Any])["UserPromptSubmit"]) == nil)
        #expect((read(.claude)["model"] as? String) == "opus")
    }

    @Test func testRemovingTheOnlyHooksLeavesTheRestOfTheFile() throws {
        write(.claude, ["model": "opus"])
        try installer.install(.claude)
        try installer.remove(.claude)
        let root = read(.claude)
        #expect((root["model"] as? String) == "opus")
        #expect(root["hooks"] == nil)
    }

    @Test func testCodexGetsItsHooksAndTheFeatureFlag() throws {
        try "model = \"gpt-5\"\n\n[features]\nweb_search = true\n".write(
            to: home.appendingPathComponent(".codex/config.toml"), atomically: true, encoding: .utf8)
        try installer.install(.codex)
        #expect(installer.health(.codex) == .installed)
        for event in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "SessionEnd"] {
            #expect((commands(.codex, event)) == (["\"\(hook)\" codex"]), "\(event)")
        }
        let toml = try String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
        #expect(toml == ("model = \"gpt-5\"\n\n[features]\ncodex_hooks = true\nweb_search = true\n"))
        try installer.install(.codex)
        #expect((try String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8)) == toml)
    }

    /// Setup's preview lists each hook's command and, for Codex, the switch
    /// in `config.toml` until it's on.
    @Test func testTheCodexPreviewShowsTheConfigChange() throws {
        let toml = home.appendingPathComponent(".codex/config.toml")
        let preview = installer.preview(.codex)
        #expect(preview.hasPrefix("SessionStart (startup|resume|clear) → \"\(hook)\" codex\n"), "\(preview)")
        #expect(preview.hasSuffix("SessionEnd → \"\(hook)\" codex\n\nIn \(toml.path), under [features]:\ncodex_hooks = true"), "\(preview)")
        #expect(!installer.preview(.claude).contains("codex_hooks"))
        try installer.install(.codex)
        #expect(try String(contentsOf: toml, encoding: .utf8).contains("codex_hooks = true"))
        #expect(!installer.preview(.codex).contains("codex_hooks"), "already on, so nothing to add")
    }

    @Test func testFeatureFlagEdits() throws {
        func enabling(_ toml: String) throws -> String? { try HookInstaller.enablingCodexHooks(in: toml) }
        #expect((try enabling("")) == ("[features]\ncodex_hooks = true\n"))
        #expect((try enabling("a = 1")) == ("a = 1\n\n[features]\ncodex_hooks = true\n"))
        #expect((try enabling("[features]\ncodex_hooks = true\n")) == nil)
        // Hooks the person turned off stay off.
        #expect(throws: (any Error).self) { try enabling("[features]\ncodex_hooks = false\n") }
        #expect(throws: (any Error).self) { try enabling("[features]\nhooks = false\n") }
        // A key of the same name in another table isn't ours.
        #expect((try enabling("[other]\ncodex_hooks = true\n")) == ("[other]\ncodex_hooks = true\n\n[features]\ncodex_hooks = true\n"))
    }

    /// However `features` is written, enabling hooks never
    /// declares it a second time, which Codex refuses to load.
    @Test func testFeatureFlagEditsNeverDeclareFeaturesTwice() throws {
        func enabling(_ toml: String) throws -> String? { try HookInstaller.enablingCodexHooks(in: toml) }
        #expect((try enabling("[features] # experimental\nweb_search = true\n")) == ("[features] # experimental\ncodex_hooks = true\nweb_search = true\n"))
        #expect((try enabling("[features] # experimental\ncodex_hooks = true # for my tools\n")) == nil, "already on")
        #expect((try enabling("[ features ]\n")) == ("[ features ]\ncodex_hooks = true\n"))
        #expect((try enabling("model = \"o3\"\nfeatures.web_search = true\n\n[tui]\nx = 1\n")) == ("model = \"o3\"\nfeatures.web_search = true\nfeatures.codex_hooks = true\n\n[tui]\nx = 1\n"))
        #expect((try enabling("features.codex_hooks = true\n")) == nil)
        #expect((try enabling("[tui]\nnote = \"see #features\"\n")) == ("[tui]\nnote = \"see #features\"\n\n[features]\ncodex_hooks = true\n"))
        #expect(throws: (any Error).self) { try enabling("features = { web_search = true }\n") }
        #expect((try enabling("features = { web_search = true, codex_hooks = true }\n")) == nil, "already on")
        #expect((try enabling("features = {codex_hooks=true}\n")) == nil, "already on")
        #expect(throws: (any Error).self) { try enabling("features = { not_codex_hooks = true }\n") }
        // Install refuses rather than break the file, writes nothing at all,
        // and the preview says to add the line by hand.
        let url = home.appendingPathComponent(".codex/config.toml")
        let inline = "features = { web_search = true }\n"
        try inline.write(to: url, atomically: true, encoding: .utf8)
        #expect(installer.preview(.codex).hasSuffix(
            "Nothing is added until you put this in \(url.path), inside features = { … }:\ncodex_hooks = true"))
        #expect(throws: (any Error).self) { try installer.install(.codex) }
        #expect((try String(contentsOf: url, encoding: .utf8)) == inline)
        #expect(!(FileManager.default.fileExists(atPath: installer.configURL(.codex).path)), "no hooks.json either")
        #expect(installer.health(.codex) == .notInstalled)
        // Once the person adds the key, install leaves config.toml alone.
        let enabled = "features = { web_search = true, codex_hooks = true }\n"
        try enabled.write(to: url, atomically: true, encoding: .utf8)
        #expect(!(installer.preview(.codex).contains("Nothing is added")))
        try installer.install(.codex)
        #expect(installer.health(.codex) == .installed)
        #expect((try String(contentsOf: url, encoding: .utf8)) == enabled)
    }

    /// A config that's a symlink (a dotfiles setup) is written through, not
    /// replaced with a plain file.
    @Test func testSymlinkedConfigsStaySymlinks() throws {
        let real = home.appendingPathComponent("dotfiles/settings.json")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: installer.configURL(.claude), withDestinationURL: real)
        try installer.install(.claude)
        let attributes = try FileManager.default.attributesOfItem(atPath: installer.configURL(.claude).path)
        #expect((attributes[.type] as? FileAttributeType) == .typeSymbolicLink)
        #expect(installer.health(.claude) == .installed)
        #expect(try String(contentsOf: real, encoding: .utf8).contains("agent-hook"))
    }

    @Test func testRepairRestoresMissingEntriesOnlyWhereTheyWereInstalled() throws {
        try installer.install(.claude)
        var root = read(.claude)
        var hooks = root["hooks"] as! [String: Any]
        hooks["Stop"] = nil
        root["hooks"] = hooks
        write(.claude, root)
        #expect(installer.health(.claude) == .outdated)
        #expect(installer.health(.codex) == .notInstalled)
        #expect(installer.repair() == [.claude])
        #expect(installer.health(.claude) == .installed)
        #expect(!(FileManager.default.fileExists(atPath: installer.configURL(.codex).path)))
    }

    @Test func testMovedHookBinaryIsOutdated() throws {
        try installer.install(.claude)
        let moved = HookInstaller(home: home, hookPath: placeClient("Applications/SomeApp.app/Contents/MacOS/agent-hook"))
        #expect(moved.health(.claude) == .outdated)
        try moved.install(.claude)
        #expect((commands(.claude, "Stop")) == (["\"\(moved.hookPath)\" claude"]))
    }

    /// An app once built without its client, and its launch repair replaced
    /// working entries with ones calling a file that wasn't there.
    @Test func testMissingClientInstallsAndRepairsNothing() throws {
        write(.claude, existing)
        let before = try Data(contentsOf: installer.configURL(.claude))
        let unbuilt = HookInstaller(home: home, hookPath: home.appendingPathComponent("bin/agent-hook").path,
                                    formerClients: installer.formerClients)
        #expect(!unbuilt.clientInPlace)
        #expect(unbuilt.health(.claude) == .clientMissing)
        #expect(unbuilt.health(.codex) == .clientMissing)
        #expect(unbuilt.repair() == [])
        #expect(throws: (any Error).self) { try unbuilt.install(.claude) }
        #expect(throws: (any Error).self) { try unbuilt.install(.codex) }
        #expect((try Data(contentsOf: installer.configURL(.claude))) == before)
        #expect(!(FileManager.default.fileExists(atPath: installer.configURL(.codex).path)))
        #expect(!(FileManager.default.fileExists(atPath: installer.codexConfigURL.path)))
        // Removing still works: it only takes its own entries out.
        try unbuilt.remove(.claude)
        #expect((commands(.claude, "Stop")) == (["say done"]))
    }

    @Test func testUnreadableFileIsLeftAlone() throws {
        let url = installer.configURL(.claude)
        try "{ not json".write(to: url, atomically: true, encoding: .utf8)
        guard case .unreadable = installer.health(.claude) else {
            Issue.record("expected unreadable")
            return
        }
        #expect(throws: (any Error).self) { try installer.install(.claude) }
        #expect((try String(contentsOf: url, encoding: .utf8)) == ("{ not json"))
    }

    /// A settings file that's there but
    /// can't be read (a root-owned one a `sudo` run left) is never taken for
    /// an empty one and replaced with our hooks. Settings says why.
    @Test func testAFileThatCantBeReadIsNeverReplaced() throws {
        write(.claude, existing)
        let url = installer.configURL(.claude)
        let before = try Data(contentsOf: url)
        try unreadable(url) {
            guard case .unreadable(let why) = installer.health(.claude) else {
                Issue.record("expected unreadable, got \(installer.health(.claude))")
                return
            }
            #expect(why.contains("settings.json"), "\(why)")
            #expect(throws: (any Error).self) { try installer.install(.claude) }
            #expect(throws: (any Error).self) { try installer.remove(.claude) }
            #expect(installer.repair() == [])
        }
        #expect((try Data(contentsOf: url)) == before)
    }

    /// The same for Codex's `config.toml`: install refuses before writing
    /// either file, and an outdated install isn't repaired over it. The
    /// setup preview says why nothing is added, not which line to add.
    @Test func testACodexConfigThatCantBeReadIsNeverReplaced() throws {
        let toml = installer.codexConfigURL
        let config = "model = \"gpt-6\"\n\n[mcp_servers.docs]\ncommand = \"docs\"\n"
        try config.write(to: toml, atomically: true, encoding: .utf8)
        try unreadable(toml) {
            guard case .failure(let why) = installer.codexConfig else { Issue.record("expected a refusal"); return }
            let preview = installer.preview(.codex)
            #expect(preview.hasSuffix("SessionEnd → \"\(hook)\" codex\n\nNothing is added: \(why)"), "\(preview)")
            #expect(!preview.contains("codex_hooks"), "\(preview)")
            #expect(throws: (any Error).self) { try installer.install(.codex) }
            #expect(!(FileManager.default.fileExists(atPath: installer.configURL(.codex).path)), "no hooks.json either")
        }
        #expect((try String(contentsOf: toml, encoding: .utf8)) == config)

        try installer.install(.codex)
        var root = read(.codex)
        var hooks = root["hooks"] as! [String: Any]
        hooks["Stop"] = nil
        root["hooks"] = hooks
        write(.codex, root)
        let enabled = try String(contentsOf: toml, encoding: .utf8)
        try unreadable(toml) {
            guard case .unreadable(let why) = installer.health(.codex) else {
                Issue.record("expected unreadable, got \(installer.health(.codex))")
                return
            }
            #expect(why.contains("config.toml"), "\(why)")
            #expect(installer.repair() == [])
        }
        #expect((try String(contentsOf: toml, encoding: .utf8)) == enabled)
        #expect(installer.health(.codex) == .outdated)
    }

    /// Hooks the person turned off (Claude's
    /// `disableAllHooks`, Codex's `hooks` or `codex_hooks` set to false in
    /// `features`) aren't Connected, and nothing turns them back on: repair
    /// skips them, installing Codex refuses before writing either file, and
    /// Settings says where, offering only Remove, which works. A
    /// config.toml without either key leaves Codex's hooks on.
    @Test func testHooksTurnedOffAreNotConnected() throws {
        try installer.install(.claude)
        var root = read(.claude)
        root["disableAllHooks"] = true
        write(.claude, root)
        #expect(installer.health(.claude) == .hooksOff(installer.configURL(.claude).path))
        root["disableAllHooks"] = false
        write(.claude, root)
        #expect(installer.health(.claude) == .installed)

        try installer.install(.codex)
        let toml = installer.codexConfigURL
        for off in ["[features]\nhooks = false\n", "[ features ] # mine too\ncodex_hooks=false\n", "features.hooks = false\n",
                    "features = { web_search = true, hooks = false }\n"] {
            try off.write(to: toml, atomically: true, encoding: .utf8)
            #expect(installer.health(.codex) == .hooksOff(toml.path), "\(off)")
            #expect(installer.repair() == [], "\(off)")
            #expect((try String(contentsOf: toml, encoding: .utf8)) == off)
        }
        let installed = try Data(contentsOf: installer.configURL(.codex))
        try installer.remove(.codex)
        #expect(installer.health(.codex) == .notInstalled)
        for off in ["[features]\nhooks = false\n", "[features]\ncodex_hooks = false\n", "features.codex_hooks = false\n"] {
            try off.write(to: toml, atomically: true, encoding: .utf8)
            let removed = try Data(contentsOf: installer.configURL(.codex))
            let error = #expect(throws: (any Error).self, "\(off)") { try installer.install(.codex) }
            #expect(error?.localizedDescription == "Codex's hooks are turned off in config.toml", "\(off)")
            #expect(installer.preview(.codex).hasSuffix("SessionEnd → \"\(hook)\" codex\n\n"
                                                              + "Nothing is added: Codex's hooks are turned off in config.toml"), "\(off)")
            #expect((try String(contentsOf: toml, encoding: .utf8)) == off)
            #expect((try Data(contentsOf: installer.configURL(.codex))) == removed, "\(off)")
        }
        try installed.write(to: installer.configURL(.codex))
        for on in ["", "[features]\nhooks = true\n", "[tui]\nhooks = false\n", "features = { not_hooks = false }\n",
                   "# [features]\n# hooks = false\n"] {
            try on.write(to: toml, atomically: true, encoding: .utf8)
            #expect(installer.health(.codex) == .installed, "\(on)")
        }
    }

    /// Settings shows why a change failed as the error's
    /// `localizedDescription`: a refusal's own words, or Foundation's one
    /// sentence, never an NSError dump with its domain and user info.
    @Test func testAFailedChangeSaysWhyInOneSentence() throws {
        let unbuilt = HookInstaller(home: home, hookPath: home.appendingPathComponent("bin/agent-hook").path)
        let refused = #expect(throws: (any Error).self) { try unbuilt.install(.claude) }
        #expect(refused?.localizedDescription == "there's no agent-hook at \(unbuilt.hookPath)")
        let folder = home.appendingPathComponent(".claude")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let failed = #expect(throws: (any Error).self) { try installer.install(.claude) }
        let why = failed?.localizedDescription ?? ""
        #expect(!why.contains("Domain"), "\(why)")
        #expect(why.contains("settings.json"), "\(why)")
    }

    /// Runs `body` while nobody can read `url`.
    func unreadable(_ url: URL, _ body: () throws -> Void) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        try body()
    }

    @Test func testRecognisesItsOwnCommands() {
        #expect(installer.isOurs("\"/a b/agent-hook\" claude"))
        #expect(installer.isOurs("/usr/local/bin/agent-hook codex --keep-text"))
        #expect(installer.isOurs("agent-hook claude"))
        #expect(installer.isOurs("/Users/x/.old/old-hook.sh claude-code"), "a former client's")
        #expect(!installer.isOurs("/usr/local/bin/not-agent-hook claude"))
        #expect(!installer.isOurs("echo agent-hooked"))
        #expect(!installer.isOurs("say done"))
        let named = HookInstaller(home: home, hookPath: hook, formerClients: ["old-hook"])
        #expect(named.isOurs("\"/Apps/X/old-hook\" codex"), "a former client by its program's name")
        #expect(!named.isOurs("/Users/x/.old/old-hook.sh claude-code"))
    }

    /// `arguments` ride on every entry, and an install without
    /// them is outdated, so an app's repair adds them.
    @Test func testArgumentsRideOnEveryEntry() throws {
        let keeping = HookInstaller(home: home, hookPath: hook, arguments: ["--keep-text"])
        #expect(keeping.command(.claude) == "\"\(hook)\" claude --keep-text")
        try installer.install(.claude)
        #expect(keeping.health(.claude) == .outdated)
        #expect(keeping.repair() == [.claude])
        #expect(commands(.claude, "Stop") == ["\"\(hook)\" claude --keep-text"])
        #expect(installer.health(.claude) == .outdated, "and back")
    }
}

/// A fresh temporary folder.
func tempDir(_ name: String) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
