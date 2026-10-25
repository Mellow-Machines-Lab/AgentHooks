import Foundation

/// The program a shell call runs, as a word from a closed list, so an app
/// can say `grep` or `git log` where it would say `Bash`. Only the word
/// leaves this function: never a path, an argument or a script's name
/// unless you listed it (`words.json`).
public enum Program {
    /// The programs whose names may leave, by their names on disk
    /// (`python3.12` is `python`, below).
    static let known: Set<String> = [
        // Reading and searching.
        "cat", "head", "tail", "less", "more", "ls", "tree", "wc", "sed", "awk", "grep", "egrep", "fgrep", "rg", "ag",
        "ack", "find", "fd", "nl", "sort", "uniq", "cut", "diff", "jq", "yq", "file", "stat", "du", "df", "xxd",
        "hexdump", "od", "strings", "which", "cmp", "tr", "xargs", "tee",
        // Files.
        "mkdir", "mv", "cp", "rm", "rmdir", "touch", "chmod", "chown", "ln", "tar", "zip", "unzip", "gzip",
        // Scripts.
        "python", "node", "ruby", "perl", "deno", "bun", "php", "lua", "osascript", "swift",
        // Version control.
        "git", "gh", "hg", "svn",
        // Building and testing.
        "make", "cmake", "ninja", "swiftc", "xcodebuild", "xcrun", "cargo", "go", "rustc", "gcc", "clang", "javac",
        "gradle", "gradlew", "mvn", "tsc", "vite", "next", "webpack", "pio", "platformio", "dotnet", "pytest", "jest",
        "vitest", "mocha", "rspec", "playwright", "emcc",
        // Packages.
        "npm", "pnpm", "yarn", "pip", "uv", "poetry", "brew", "apt", "gem", "bundle", "composer",
        // The network.
        "curl", "wget", "ssh", "scp", "rsync", "nc", "ping", "http",
        // Containers and deploys.
        "docker", "podman", "kubectl", "helm", "terraform", "vercel", "fly", "flyctl", "wrangler", "netlify",
        "firebase", "gcloud", "aws",
        // Processes, the Mac and the rest.
        "sleep", "kill", "pkill", "ps", "lsof", "top", "open", "pbcopy", "pbpaste", "date", "sqlite3", "psql",
        "redis-cli", "ffmpeg", "magick", "convert", "defaults", "launchctl", "codesign", "plutil", "say",
    ]

    /// The programs whose first operand says what they do, and the
    /// operands that may leave with them: `git log`, `npm i`, `gh pr`.
    static let subcommands: [String: Set<String>] = [
        "git": [
            "add", "am", "apply", "bisect", "blame", "branch", "checkout", "cherry-pick", "clean", "clone", "commit",
            "config", "describe", "diff", "fetch", "grep", "init", "log", "ls-files", "merge", "mv", "pull", "push",
            "rebase", "reflog", "remote", "reset", "restore", "revert", "rev-parse", "rm", "show", "stash", "status",
            "submodule", "switch", "tag", "worktree",
        ],
        "gh": ["api", "issue", "pr", "release", "repo", "run", "workflow"],
        "npm": ["add", "build", "ci", "dev", "exec", "i", "install", "publish", "remove", "run", "start", "test"],
        "pnpm": ["add", "build", "dev", "exec", "i", "install", "remove", "run", "start", "test"],
        "yarn": ["add", "build", "dev", "install", "remove", "run", "start", "test"],
        "bun": ["add", "build", "install", "run", "test"],
        "docker": ["build", "compose", "exec", "images", "logs", "ps", "pull", "push", "run"],
        "kubectl": ["apply", "delete", "describe", "exec", "get", "logs"],
        "cargo": ["add", "build", "check", "clippy", "fmt", "run", "test"],
        "go": ["build", "get", "mod", "run", "test", "vet"],
        "swift": ["build", "package", "run", "test"],
        "brew": ["install", "list", "services", "update", "upgrade"],
        "pip": ["install", "list", "uninstall"],
        "uv": ["add", "pip", "run", "sync"],
        "poetry": ["add", "install", "run"],
    ]

    /// Flags a program takes before its subcommand that take the next word
    /// as their value: `git -C repo log`.
    static let valueFlags: [String: Set<String>] = [
        "git": ["-C", "-c", "--git-dir", "--work-tree", "--namespace"],
        "docker": ["-H", "--host", "--context", "-c", "--config"],
        "kubectl": ["-n", "--namespace", "--context", "--kubeconfig"],
        "gh": ["-R", "--repo"],
    ]

    /// Names that are one program: `python3.12` and `pip3` are `python`
    /// and `pip`.
    static func normal(_ program: String) -> String {
        for base in ["python", "pip", "node", "ruby", "perl"] where program.hasPrefix(base) {
            let rest = program.dropFirst(base.count)
            if rest.allSatisfy({ $0.isNumber || $0 == "." }) { return base }
        }
        return program
    }

    /// The word for a tool call: its program for a shell call (Claude's
    /// `Bash`, Codex's `shell` or `exec_command`), nil for any other tool.
    /// `own` adds your programs (`words.json`).
    public static func word(tool: String?, input: Any?, own: Set<String> = []) -> String? {
        guard ToolKind.of(tool) == .shell, let commands = Topic.commands(in: input) else { return nil }
        return word(commands, own: own)
    }

    /// The word for a command line: `grep`, `git log`, `loop` for a `for`
    /// or `while` loop, or `run` for a program that's neither known nor
    /// yours. The first command that does something counts, after `cd`,
    /// `echo` and the like (`cd src && rg foo` is `rg`). Nil when nothing
    /// runs.
    public static func word(command: String, own: Set<String> = []) -> String? {
        word(Topic.commands(command), own: own)
    }

    static func word(_ commands: [[String]], own: Set<String>) -> String? {
        var bystander: String?
        for words in commands {
            if ["for", "while", "until"].contains(words.first) { return "loop" }
            guard let (program, args) = Topic.unwrap(words) else { continue }
            if Topic.shells.contains(program), let at = args.firstIndex(where: Topic.isDashC), at + 1 < args.count {
                if let inside = word(Topic.commands(args[at + 1]), own: own) { return inside }
                continue
            }
            let name = normal(program)
            if quiet.contains(name) {
                bystander = bystander ?? name
                continue
            }
            if own.contains(name) { return name }
            guard known.contains(name) else { return "run" }
            return withSubcommand(name, args)
        }
        // A line of only bystanders: `echo done`.
        return bystander
    }

    /// Commands that set up for the one that does something:
    /// `cd`, `echo`, `export X=1`, `source env.sh`.
    static let quiet = Topic.bystanders.union(["export", "set", "unset", "source", ".", "local", "read"])

    static func withSubcommand(_ program: String, _ args: [String]) -> String {
        guard let allowed = subcommands[program] else { return program }
        let valued = valueFlags[program] ?? []
        var i = 0
        while i < args.count, args[i].hasPrefix("-") {
            i += valued.contains(args[i]) ? 2 : 1
        }
        guard i < args.count, allowed.contains(args[i]) else { return program }
        return program + " " + args[i]
    }

    /// Your own programs, from `words.json` in the agent-hooks folder
    /// (`$AGENT_HOOKS_DIR`, else `~/.agent-hooks`): `{"words": ["boopctl",
    /// "just"]}`. Each is a program's name, as it's run (a path's last
    /// part); empty when there's none or it doesn't read.
    public static func ownWords(environment: [String: String] = ProcessInfo.processInfo.environment) -> Set<String> {
        let root = environment["AGENT_HOOKS_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (environment["HOME"] ?? NSHomeDirectory()) + "/.agent-hooks"
        guard let data = FileManager.default.contents(atPath: root + "/words.json"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let words = object["words"] as? [String] else { return [] }
        return Set(words.map { ($0 as NSString).lastPathComponent }.filter { !$0.isEmpty && $0.count <= 24 })
    }

    /// An edit's file type: the extension of the first file it touches,
    /// lowercased (`swift`, `md`), when it's a short plain one. Nil for
    /// any other tool, or a file with none.
    public static func fileType(tool: String?, input: Any?) -> String? {
        guard ToolKind.of(tool) == .edit, let path = Topic.paths(in: input).first else { return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, ext.count <= 8, ext.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return ext
    }
}
