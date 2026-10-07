import AgentHooksWire
import Darwin
import Foundation

// The hook client: `agent-hook claude|codex [--keep-text]`.
// Reads the hook's JSON, keeps a few fields, writes one line to every app
// listening (`HookSocket.destinations`) and exits 0. It never prints, so it
// never answers for the agent, and it gives up quickly when nobody's there.

let inputCap = 256 * 1024

// Whatever happens, finish within a second and report success.
signal(SIGALRM) { _ in _exit(0) }
signal(SIGPIPE, SIG_IGN)
alarm(1)

let started = Int64(Date().timeIntervalSince1970 * 1000)
let arguments = CommandLine.arguments.dropFirst()
let agent = arguments.first ?? "claude"
let keepText = arguments.contains("--keep-text")

var payload = Data()
var chunk = [UInt8](repeating: 0, count: 65536)
while true {
    let n = read(STDIN_FILENO, &chunk, chunk.count)
    if n <= 0 { break }
    // Past the cap the rest is drained and ignored.
    let room = inputCap - payload.count
    if room > 0 { payload.append(contentsOf: chunk[0..<min(n, room)]) }
}

let environment = ProcessInfo.processInfo.environment
if ["claude", "codex"].contains(agent),
   let line = HookLine.extract(agent: agent, payload: payload, ts: started, codexHome: ThreadName.codexHome,
                               env: environment, keepText: keepText, topics: Topic.extraPatterns(environment: environment)) {
    let data = line.encoded()
    for destination in HookSocket.destinations(environment: environment) {
        HookSocket.send(data, to: destination)
    }
}
exit(0)
