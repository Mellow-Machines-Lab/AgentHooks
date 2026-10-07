import AgentHooks
import Darwin
import Foundation

// `agent-hooks`: install the hooks, and see what your agents are doing.

let usage = """
    agent-hooks install [claude|codex] [--keep-text] [--hook PATH] [--home DIR]
        Adds agent-hook to the agents' hooks (every agent found, or the one named). --keep-text keeps
        your prompt and the agent's last message; --hook is the client to run (default: the agent-hook
        next to this command); --home is the home folder whose ~/.claude and ~/.codex change (default:
        $HOME).
    agent-hooks remove [claude|codex] [--home DIR]
        Takes agent-hook's entries out of ~/.claude/settings.json and ~/.codex/hooks.json. Leaves
        codex_hooks = true in ~/.codex/config.toml, since other hooks may need it.
    agent-hooks status [--hook PATH] [--home DIR]
        Each agent's hooks, and the apps listening.
    agent-hooks tail [--sessions] [--name NAME]
        Listens as NAME (default tail-PID) and prints every event as a JSON line; with --sessions, also
        each session's state as it changes (working, idle, needs_you, gone). Ctrl-C stops it.
    agent-hooks doctor [--hook PATH] [--home DIR]
        Status, then a made-up hook through the client to a socket of its own.
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("agent-hooks: \(message)\n".utf8))
    exit(1)
}

/// Options by name, the flags given, and the rest in order.
struct Arguments {
    var options: [String: String] = [:]
    var flags: Set<String> = []
    var words: [String] = []

    init(_ raw: ArraySlice<String>, options known: Set<String>, flags knownFlags: Set<String>) {
        var rest = raw
        while let word = rest.popFirst() {
            if known.contains(word) {
                guard let value = rest.popFirst() else { fail("\(word) needs a value") }
                options[word] = value
            } else if knownFlags.contains(word) {
                flags.insert(word)
            } else if word.hasPrefix("--") {
                fail("unknown option \(word)\n\n\(usage)")
            } else {
                words.append(word)
            }
        }
    }
}

let args = CommandLine.arguments
guard args.count > 1, !["-h", "--help", "help"].contains(args[1]) else {
    print(usage)
    exit(args.count > 1 ? 0 : 1)
}
let command = args[1]
let given = Arguments(args.dropFirst(2), options: ["--hook", "--home", "--name"], flags: ["--keep-text", "--sessions"])

/// The `agent-hook` built next to this command: next to the executable
/// itself, since run from `PATH` its `argv[0]` is only its name.
func builtClient() -> String {
    let me = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
    return me.deletingLastPathComponent().appendingPathComponent(HookInstaller.client).path
}

/// The home folder whose `~/.claude` and `~/.codex` change: `--home`, else
/// `$HOME`, as for the socket folder. Not `NSHomeDirectory()` alone, which
/// ignores `$HOME`, so a run with a throwaway `HOME` would change the real
/// hooks.
func home() -> URL {
    let env = ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : $0 }
    return URL(fileURLWithPath: given.options["--home"] ?? env ?? NSHomeDirectory())
}

func installer(keepText: Bool = given.flags.contains("--keep-text")) -> HookInstaller {
    let home = home()
    return HookInstaller(home: home, hookPath: given.options["--hook"] ?? builtClient(),
                         arguments: keepText ? ["--keep-text"] : [])
}

/// The agent named, or every one whose folder is there.
func agents(_ installer: HookInstaller) -> [Agent] {
    if let name = given.words.first {
        guard let agent = Agent(rawValue: name) else { fail("the agent is claude or codex, not \(name)") }
        return [agent]
    }
    return Agent.allCases.filter(installer.detected)
}

func describe(_ health: HookInstaller.Health) -> String {
    switch health {
    case .installed: "installed"
    case .notInstalled: "not installed"
    case .outdated: "outdated: run agent-hooks install"
    case .unreadable(let why): "unreadable: \(why)"
    case .clientMissing: "no agent-hook at the path given"
    case .hooksOff(let file): "installed, but hooks are turned off in \(file)"
    }
}

/// An agent's health, whether its entries keep text or not.
func health(_ agent: Agent) -> String {
    let plain = installer(keepText: false), keeping = installer(keepText: true)
    switch (plain.health(agent), keeping.health(agent)) {
    case (.installed, _): return "installed"
    case (_, .installed): return "installed, keeping text"
    case (let other, _): return describe(other)
    }
}

func status() {
    let i = installer()
    for agent in Agent.allCases {
        print("\(agent.displayName): \(i.detected(agent) ? health(agent) : "not found")")
    }
    let folder = HookSocket.directory()
    if FileManager.default.fileExists(atPath: folder), !HookSocket.isPrivate(folder) {
        print("Listening in \(folder): nobody, since others can write to it (chmod 700 it)")
        return
    }
    let listening = HookSocket.destinations()
    print("Listening in \(folder): " + (listening.isEmpty ? "nobody" : ""))
    for path in listening { print("  \((path as NSString).lastPathComponent)") }
}

switch command {
case "install", "remove":
    let i = installer()
    let chosen = agents(i)
    if chosen.isEmpty { fail("found neither ~/.claude nor ~/.codex; name the agent") }
    for agent in chosen {
        do {
            if command == "install" { try i.install(agent) } else { try i.remove(agent) }
            print("\(agent.displayName): \(health(agent))")
        } catch {
            fail("\(agent.displayName): \(error.localizedDescription)")
        }
    }
    print("Restart open agent sessions: they read their hooks when they start.")

case "status":
    status()

case "tail":
    let name = given.options["--name"] ?? "tail-\(getpid())"
    Tail(path: HookSocket.directory() + "/" + name + ".sock", sessions: given.flags.contains("--sessions")).run()

case "doctor":
    status()
    let client = given.options["--hook"] ?? builtClient()
    guard FileManager.default.isExecutableFile(atPath: client) else { fail("no agent-hook at \(client)") }
    let path = NSTemporaryDirectory() + "agent-hooks-doctor-\(getpid()).sock"
    let got = DispatchSemaphore(value: 0)
    let server = HookServer(path: path) { line in if line.session == "doctor" { got.signal() } }
    do { try server.start() } catch { fail("can't listen at \(path): \(error)") }
    defer { server.stop() }
    let run = Process()
    run.executableURL = URL(fileURLWithPath: client)
    run.arguments = ["claude"]
    run.environment = ProcessInfo.processInfo.environment.merging(["AGENT_HOOKS_SOCKET": path]) { $1 }
    let input = Pipe()
    run.standardInput = input
    do { try run.run() } catch { fail("can't run \(client): \(error)") }
    input.fileHandleForWriting.write(Data(#"{"hook_event_name":"Stop","session_id":"doctor","cwd":"/tmp"}"#.utf8))
    try? input.fileHandleForWriting.close()
    run.waitUntilExit()
    guard run.terminationStatus == 0 else { fail("agent-hook exited \(run.terminationStatus); it should always exit 0") }
    guard got.wait(timeout: .now() + 2) == .success else { fail("agent-hook ran, but its line never arrived") }
    print("A made-up hook went through agent-hook and arrived: the client works.")

default:
    fail("unknown command \(command)\n\n\(usage)")
}

/// `agent-hooks tail`: a listener that prints what it hears. Everything
/// but the server's thread runs on `queue`.
final class Tail: @unchecked Sendable {
    let path: String
    let sessions: Bool
    let queue = DispatchQueue(label: "agent-hooks.tail")
    let places = Places()
    lazy var tracker = SessionTracker(place: { [places] in places.place(cwd: $0) })
    /// Each session's state as last printed.
    var shown: [String: String] = [:]
    var keep: [Any] = []

    init(path: String, sessions: Bool) {
        self.path = path
        self.sessions = sessions
    }

    func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    func run() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        let server = HookServer(path: path) { [self] line in queue.async { self.take(line) } }
        do { try server.start() } catch { fail("can't listen at \(path): \(error)") }
        FileHandle.standardError.write(Data("agent-hooks: listening at \(path)\n".utf8))
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [self] in
            guard sessions else { return }
            tracker.advance(to: now())
            report(at: now())
        }
        timer.resume()
        keep.append(timer)
        for stop in [SIGINT, SIGTERM] {
            signal(stop, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: stop, queue: queue)
            source.setEventHandler {
                server.stop()
                exit(0)
            }
            source.resume()
            keep.append(source)
        }
        dispatchMain()
    }

    func take(_ line: HookLine) {
        guard let event = Mapping.event(from: line, receivedAt: now()) else { return }
        print(event.jsonLine)
        guard sessions else { return }
        tracker.handle(event)
        report(at: event.at)
    }

    /// Prints each session whose state changed since last time.
    func report(at time: Int64) {
        var states: [String: String] = [:]
        let (waiting, working, idle) = tracker.grouped(at: time)
        for s in waiting { states[s.key] = "needs_you" }
        for s in working { states[s.key] = "working" }
        for s in idle { states[s.key] = "idle" }
        for (key, state) in states.sorted(by: { $0.key < $1.key }) where shown[key] != state {
            let s = tracker.sessions[key]!
            var line: [String: Any] = ["session": key, "state": state, "project": s.project, "at": time]
            line["workspace"] = s.workspace
            line["name"] = s.name
            if state == "needs_you" { line["asking"] = (s.asking ?? .permission).rawValue }
            let data = try! JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes])
            print(String(decoding: data, as: UTF8.self))
        }
        for key in shown.keys.sorted() where states[key] == nil {
            print(#"{"at":\#(time),"session":"\#(key)","state":"gone"}"#)
        }
        shown = states
    }
}
