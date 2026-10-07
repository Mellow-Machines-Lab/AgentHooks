import Foundation

/// Installs, repairs and removes agent-hooks' entries:
/// Claude's in `~/.claude/settings.json`, Codex's in `~/.codex/hooks.json`.
///
/// Every entry it adds calls `agent-hook`, and that's how it recognises its
/// own, along with any older client an app names (`formerClients`), whose
/// entries it replaces. It never touches anyone else's hooks. Nothing is
/// written when nothing would change, so installing twice is the same as
/// once. One installed client serves every app listening (`HookSocket`).
public struct HookInstaller {
    /// Why a change was refused, in words for the person.
    public struct Refusal: LocalizedError, Equatable, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
        public var errorDescription: String? { description }
    }

    public enum Health: Equatable, Sendable {
        case notInstalled
        case installed
        /// Some of its entries are missing, old or point elsewhere.
        case outdated
        /// The file can't be read or isn't a JSON object, or Codex's
        /// `config.toml` can't be read; it's left alone.
        case unreadable(String)
        /// The `agent-hook` the entries call isn't there, so they'd drop every
        /// event. Nothing is installed or repaired until it is.
        case clientMissing
        /// Its entries are there, but the person turned the agent's hooks off
        /// in this file, so none run. It never turns them back on: repair
        /// skips them and installing Codex refuses.
        case hooksOff(String)
    }

    /// The hooks each agent gets, `Mapping`'s in its order,
    /// with a matcher where one is needed. Claude matches `Notification` on
    /// its type, so the matcher lists every type `Mapping` maps. A new
    /// order would make every install look outdated.
    static let events: [Agent: [(event: String, matcher: String?)]] = Dictionary(
        uniqueKeysWithValues: Agent.allCases.map { agent in (agent, Mapping.hooks(agent).map { ($0, matchers[agent]?[$0]) }) })
    /// Each agent's matchers, by hook.
    static let matchers: [Agent: [String: String]] = [
        .claude: ["Notification": Mapping.notificationTypes.joined(separator: "|")],
        .codex: ["SessionStart": "startup|resume|clear"],
    ]
    /// Seconds. `agent-hook` finishes in milliseconds and gives up after one.
    static let timeout = 5

    /// The client's name, which every entry runs.
    public static let client = "agent-hook"

    public let home: URL
    /// The `agent-hook` binary the entries call.
    public let hookPath: String
    /// What each entry passes after the agent's name: `--keep-text` keeps
    /// your prompt and the agent's last message.
    public let arguments: [String]
    /// Commands an app's older hook client ran, as a program's name or a
    /// path's ending (`old-hook`, `/old-hook.sh`): entries that run them
    /// are its own too, and installing replaces them.
    public let formerClients: [String]

    public init(home: URL, hookPath: String, arguments: [String] = [], formerClients: [String] = []) {
        self.home = home
        self.hookPath = hookPath
        self.arguments = arguments
        self.formerClients = formerClients
    }

    public func configURL(_ agent: Agent) -> URL {
        switch agent {
        case .claude: home.appendingPathComponent(".claude/settings.json")
        case .codex: home.appendingPathComponent(".codex/hooks.json")
        }
    }

    /// Whether the agent looks installed on this Mac.
    public func detected(_ agent: Agent) -> Bool {
        FileManager.default.fileExists(atPath: configURL(agent).deletingLastPathComponent().path)
    }

    /// Whether the `agent-hook` the entries call is in place.
    public var clientInPlace: Bool { FileManager.default.isExecutableFile(atPath: hookPath) }

    public func command(_ agent: Agent) -> String {
        (["\"\(hookPath)\"", agent.rawValue] + arguments).joined(separator: " ")
    }

    /// Whether an entry's command is one of ours: it runs `agent-hook`, or
    /// one of `formerClients`.
    public func isOurs(_ command: String) -> Bool {
        if formerClients.contains(where: { $0.hasPrefix("/") && command.contains($0) }) { return true }
        return ([Self.client] + formerClients.filter { !$0.hasPrefix("/") }).contains { name in
            let program = NSRegularExpression.escapedPattern(for: name)
            return command.range(of: #"(^|/)"# + program + #""?(\s|$)"#, options: .regularExpression) != nil
        }
    }

    // MARK: Reading

    public func health(_ agent: Agent) -> Health {
        let root: [String: Any]
        switch read(agent) {
        case .failure(let why): return .unreadable(why.description)
        case .success(let r): root = r
        }
        if agent == .codex, case .failure(let why) = codexConfig { return .unreadable(why.description) }
        guard clientInPlace else { return .clientMissing }
        let ours = ourGroups(in: root["hooks"] as? [String: Any] ?? [:])
        if ours.isEmpty { return .notInstalled }
        switch agent {
        case .claude where root["disableAllHooks"] as? Bool == true: return .hooksOff(configURL(agent).path)
        case .codex where Self.codexHooksOff(in: (try? codexConfig.get()) ?? ""): return .hooksOff(codexConfigURL.path)
        default: break
        }
        let fresh = installing(agent, into: [:])["hooks"] as? [String: Any] ?? [:]
        return NSDictionary(dictionary: ours).isEqual(to: fresh) ? .installed : .outdated
    }

    /// What installing adds, one line per hook, for an app to show before
    /// it installs, with the config file's path above it. For Codex it ends with the
    /// switch installing turns on in `config.toml`, unless it's already on,
    /// or with why nothing is added when that file can't be read or turns
    /// the hooks off.
    public func preview(_ agent: Agent) -> String {
        var text = Self.events[agent]!.map { "\($0.event)\($0.matcher.map { " (\($0))" } ?? "") → \(command(agent))" }
            .joined(separator: "\n")
        if agent == .codex {
            let config = codexConfig
            if case .failure(let why) = config { return text + "\n\nNothing is added: \(why)" }
            switch Result(catching: { try Self.enablingCodexHooks(in: config.get()) }) {
            case .success(nil): break
            case .success: text += "\n\nIn \(codexConfigURL.path), under [features]:\ncodex_hooks = true"
            case .failure(let why) where why as? Refusal == Self.codexHooksTurnedOff: text += "\n\nNothing is added: \(why)"
            case .failure(let why):
                let place = why as? Refusal == Self.inlineFeatures ? "inside features = { … }" : "under [features] (\(why))"
                text += "\n\nNothing is added until you put this in \(codexConfigURL.path), \(place):\ncodex_hooks = true"
            }
        }
        return text
    }

    // MARK: Changing

    /// Adds its entries, replacing any older ones. For Codex it also turns
    /// hooks on in `config.toml`, and writes nothing at all when it won't edit
    /// that file or the person turned the hooks off there. Refuses while
    /// `agent-hook` isn't in place.
    public func install(_ agent: Agent) throws {
        guard clientInPlace else { throw Refusal("there's no \(Self.client) at \(hookPath)") }
        let root = try read(agent).get()
        let config = agent == .codex ? try Self.enablingCodexHooks(in: codexConfig.get()) : nil
        try write(installing(agent, into: root), agent)
        if let config { try config.write(to: codexConfigURL.resolvingSymlinksInPath(), atomically: true, encoding: .utf8) }
    }

    /// Removes its entries, current and old, and nothing else.
    public func remove(_ agent: Agent) throws {
        let root = try read(agent).get()
        try write(removing(from: root), agent)
    }

    /// Brings back missing or outdated entries for agents that already have
    /// some of its own, as an app does at launch. Returns the agents it
    /// repaired; none while `agent-hook` isn't in place.
    @discardableResult
    public func repair() -> [Agent] {
        Agent.allCases.filter { agent in
            guard health(agent) == .outdated else { return false }
            return (try? install(agent)) != nil
        }
    }

    func installing(_ agent: Agent, into root: [String: Any]) -> [String: Any] {
        var root = removing(from: root)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let entry: [String: Any] = ["type": "command", "command": command(agent), "timeout": Self.timeout]
        for (event, matcher) in Self.events[agent]! {
            var groups = hooks[event] as? [[String: Any]] ?? []
            var group: [String: Any] = ["hooks": [entry]]
            if let matcher { group["matcher"] = matcher }
            groups.append(group)
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return root
    }

    func removing(from root: [String: Any]) -> [String: Any] {
        guard var hooks = root["hooks"] as? [String: Any] else { return root }
        var removedAny = false
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            var kept: [[String: Any]] = []
            var changed = false
            for var group in groups {
                guard let entries = group["hooks"] as? [[String: Any]] else {
                    kept.append(group)
                    continue
                }
                let others = entries.filter { !isOurs($0["command"] as? String ?? "") }
                if others.count == entries.count {
                    kept.append(group)
                    continue
                }
                changed = true
                if !others.isEmpty {
                    group["hooks"] = others
                    kept.append(group)
                }
            }
            guard changed else { continue }
            removedAny = true
            hooks[event] = kept.isEmpty ? nil : kept
        }
        guard removedAny else { return root }
        var root = root
        root["hooks"] = hooks.isEmpty ? nil : hooks
        return root
    }

    /// Its entries by hook, each in a group of its own with its group's
    /// matcher, as a fresh install writes them. Where a group sits, and
    /// what else is in it, doesn't matter: the agent runs every hook.
    func ourGroups(in hooks: [String: Any]) -> [String: [[String: Any]]] {
        var ours: [String: [[String: Any]]] = [:]
        for (event, value) in hooks {
            for group in value as? [[String: Any]] ?? [] {
                for entry in group["hooks"] as? [[String: Any]] ?? [] where isOurs(entry["command"] as? String ?? "") {
                    var alone: [String: Any] = ["hooks": [entry]]
                    alone["matcher"] = group["matcher"]
                    ours[event, default: []].append(alone)
                }
            }
        }
        return ours
    }

    // MARK: Files

    /// Only a file that isn't there reads as empty. One that's there but
    /// can't be read is refused, so it's never replaced with our hooks.
    func read(_ agent: Agent) -> Result<[String: Any], Refusal> {
        let url = configURL(agent)
        let data: Data
        do { data = try Data(contentsOf: url) } catch CocoaError.fileReadNoSuchFile { return .success([:]) } catch {
            return .failure(Refusal(error.localizedDescription))
        }
        if data.allSatisfy({ [0x20, 0x0A, 0x0D, 0x09].contains($0) }) { return .success([:]) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(Refusal("\(url.lastPathComponent) isn't a JSON object"))
        }
        return .success(object)
    }

    /// Writes through a symlink (a dotfiles setup) rather than replacing it.
    func write(_ root: [String: Any], _ agent: Agent) throws {
        let url = configURL(agent).resolvingSymlinksInPath()
        if case .success(let old) = read(agent), NSDictionary(dictionary: old).isEqual(to: root),
           FileManager.default.fileExists(atPath: url.path) || root.isEmpty { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }

    var codexConfigURL: URL { home.appendingPathComponent(".codex/config.toml") }

    /// `config.toml` as it is now; empty if it isn't there, and refused, as
    /// `read` does, if it's there but can't be read.
    var codexConfig: Result<String, Refusal> {
        do { return .success(try String(contentsOf: codexConfigURL, encoding: .utf8)) }
        catch CocoaError.fileReadNoSuchFile { return .success("") }
        catch { return .failure(Refusal(error.localizedDescription)) }
    }

    /// Codex runs hooks only with `codex_hooks = true` under `[features]`.
    /// Installing adds the line if it's missing and never removes it: other
    /// hooks may rely on it.
    ///
    /// `toml` with `codex_hooks = true` in `features`, or nil if it's
    /// already there. It finds the table however it's written (`[features]`,
    /// `[ features ] # note`, or top-level `features.x = …` keys) and never
    /// declares it twice, which Codex refuses to load. It throws while the
    /// person has the hooks turned off there, which is never undone, and
    /// for a shape it won't edit (an inline `features = {…}` without the
    /// key), so the line is added by hand.
    static func enablingCodexHooks(in toml: String) throws -> String? {
        if codexHooksOff(in: toml) { throw codexHooksTurnedOff }
        var lines = toml.components(separatedBy: "\n")
        var section: String?  // nil at the top level
        var featuresAt: Int?
        var lastDotted: Int?
        for (i, raw) in lines.enumerated() {
            let line = uncommented(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                section = line.filter { !$0.isWhitespace }
                if section == "[features]" { featuresAt = i }
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].filter { !$0.isWhitespace }
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch (section, key) {
            case ("[features]", "codex_hooks"), (nil, "features.codex_hooks"):
                if value == "true" { return nil }
                lines[i] = section == nil ? "features.codex_hooks = true" : "codex_hooks = true"
                return lines.joined(separator: "\n")
            case (nil, "features"):
                if value.range(of: #"[{,]\s*codex_hooks\s*=\s*true\s*[,}]"#, options: .regularExpression) != nil {
                    return nil
                }
                throw inlineFeatures
            case (nil, _) where key.hasPrefix("features."):
                lastDotted = i
            default:
                break
            }
        }
        switch (featuresAt, lastDotted) {
        case (.some, .some):
            throw Refusal("features is declared twice already")
        case (.some(let at), nil):
            lines.insert("codex_hooks = true", at: at + 1)
            return lines.joined(separator: "\n")
        case (nil, .some(let at)):
            lines.insert("features.codex_hooks = true", at: at + 1)
            return lines.joined(separator: "\n")
        case (nil, nil):
            var out = toml
            if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
            if !out.isEmpty { out += "\n" }
            return out + "[features]\ncodex_hooks = true\n"
        }
    }

    static let inlineFeatures = Refusal("features is an inline table")
    static let codexHooksTurnedOff = Refusal("Codex's hooks are turned off in config.toml")

    /// Whether `toml` turns Codex's hooks off: `hooks`, or its old name
    /// `codex_hooks`, set to false in `features`, however that's written.
    /// A file without either leaves them on.
    static func codexHooksOff(in toml: String) -> Bool {
        var section: String?  // nil at the top level
        for raw in toml.components(separatedBy: "\n") {
            let line = uncommented(raw).filter { !$0.isWhitespace }
            if line.hasPrefix("[") {
                section = line
            } else if section == "[features]", line == "hooks=false" || line == "codex_hooks=false" {
                return true
            } else if section == nil, line == "features.hooks=false" || line == "features.codex_hooks=false"
                        || line.range(of: #"^features=\{(.*,)?(codex_)?hooks=false[,}]"#, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    /// A TOML line without its `# comment`, leaving a `#` inside quotes.
    static func uncommented(_ line: String) -> Substring {
        var quote: Character?
        for i in line.indices {
            let ch = line[i]
            if let q = quote {
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "#" {
                return line[..<i]
            }
        }
        return line[...]
    }
}
