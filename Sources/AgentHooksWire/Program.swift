import Foundation

/// The program a shell call runs, as a word from a closed list, so an app
/// can say `grep` or `git log` where it would say `Bash`. Only the word
/// leaves this function: never a path or an argument, and a script's name
/// only if you listed it (`words.json`) or the hook keeps text (`wide`).
public enum Program {
    /// The programs whose names may leave, by their names on disk
    /// (`python3.12` is `python`, below).
    static let known: Set<String> = [
        // Reading and searching.
        "cat", "head", "tail", "less", "more", "ls", "tree", "wc", "sed", "awk", "grep", "egrep", "fgrep", "rg", "ag",
        "ack", "find", "fd", "nl", "sort", "uniq", "cut", "diff", "jq", "yq", "file", "stat", "du", "df", "xxd",
        "hexdump", "od", "strings", "which", "cmp", "tr", "xargs", "tee", "bat", "eza", "exa", "fzf", "sd", "delta",
        "difft", "patch", "column", "paste", "join", "comm", "rev", "shuf", "split", "base64", "shasum", "sha256sum",
        "md5", "md5sum", "realpath", "dirname", "basename", "readlink", "mdfind", "mdls", "plistbuddy",
        // Files.
        "mkdir", "mv", "cp", "rm", "rmdir", "touch", "chmod", "chown", "ln", "tar", "zip", "unzip", "gzip", "gunzip",
        "xz", "zstd", "7z", "ditto", "xattr", "trash",
        // Editors.
        "vim", "nvim", "vi", "nano", "emacs", "code", "cursor", "subl", "zed",
        // Scripts.
        "python", "node", "ruby", "perl", "deno", "bun", "php", "lua", "osascript", "swift", "java", "kotlin", "scala",
        "elixir", "erl", "iex", "ghc", "ghci", "runghc", "julia", "Rscript", "R", "dart", "zig", "nim", "ocaml", "racket",
        "guile", "clojure", "tclsh", "jshell", "irb", "ts-node", "tsx",
        // Version control.
        "git", "gh", "hg", "svn",
        // Building and testing.
        "make", "cmake", "ninja", "swiftc", "xcodebuild", "xcrun", "cargo", "go", "rustc", "gcc", "clang", "javac",
        "gradle", "gradlew", "mvn", "tsc", "vite", "next", "webpack", "pio", "platformio", "dotnet", "pytest", "jest",
        "vitest", "mocha", "rspec", "playwright", "emcc", "bazel", "bazelisk", "buck2", "meson", "scons", "rake", "mix",
        "sbt", "lein", "stack", "cabal", "dune", "just", "task", "turbo", "nx", "lerna", "esbuild", "rollup", "parcel",
        "babel", "swc", "flutter", "cypress", "phpunit", "tox", "nox", "ctest", "ld", "ar", "nm", "otool", "objdump",
        "lipo", "strip", "install_name_tool", "pkg-config", "autoconf", "automake", "configure",
        // Linters and formatters.
        "ruff", "black", "isort", "flake8", "mypy", "pyright", "pylint", "eslint", "prettier", "biome", "oxlint",
        "stylelint", "rubocop", "golangci-lint", "gofmt", "rustfmt", "clippy-driver", "shellcheck", "shfmt", "swiftlint",
        "swiftformat", "clang-format", "clang-tidy", "ktlint", "markdownlint", "yamllint", "hadolint", "actionlint",
        // Debugging and profiling.
        "lldb", "gdb", "valgrind", "strace", "dtruss", "dtrace", "perf", "instruments", "hyperfine", "leaks", "heap",
        "vmmap", "sample", "spindump", "log",
        // Packages.
        "npm", "pnpm", "yarn", "pip", "uv", "poetry", "brew", "apt", "gem", "bundle", "composer", "pipx", "conda",
        "mamba", "pyenv", "rbenv", "nvm", "volta", "fnm", "asdf", "mise", "rustup", "nix", "nix-shell", "port",
        "apt-get", "dnf", "yum", "pacman", "apk", "luarocks", "opam", "hex",
        // The network.
        "curl", "wget", "ssh", "scp", "rsync", "nc", "ping", "http", "https", "httpie", "xh", "dig", "nslookup", "host",
        "traceroute", "netstat", "ifconfig", "ipconfig", "networksetup", "openssl", "telnet", "websocat", "grpcurl",
        "ngrok", "cloudflared", "tailscale",
        // Containers and deploys.
        "docker", "podman", "kubectl", "helm", "terraform", "vercel", "fly", "flyctl", "wrangler", "netlify",
        "firebase", "gcloud", "aws", "az", "doctl", "heroku", "railway", "supabase", "render", "pulumi", "cdk", "sam",
        "serverless", "sls", "ansible", "ansible-playbook", "packer", "vagrant", "minikube", "kind", "k9s", "skaffold",
        "tilt", "docker-compose", "colima", "lima", "orb", "prisma", "drizzle-kit", "sqlx", "alembic", "flyway",
        // Processes, the Mac and the rest.
        "sleep", "kill", "pkill", "ps", "lsof", "top", "open", "pbcopy", "pbpaste", "date", "sqlite3", "psql",
        "redis-cli", "ffmpeg", "magick", "convert", "defaults", "launchctl", "codesign", "plutil", "say", "mysql",
        "mongosh", "duckdb", "clickhouse", "ffprobe", "sox", "afplay", "sips", "screencapture", "pandoc", "latexmk",
        "pdflatex", "xelatex", "dot", "mmdc", "gs", "qpdf", "tmux", "screen", "watch", "entr", "nodemon", "htop", "btop",
        "uptime", "whoami", "uname", "hostname", "printenv", "man", "tldr", "diskutil", "hdiutil", "tmutil", "pmset",
        "spctl", "xcode-select", "simctl", "systemctl", "journalctl", "service", "crontab", "gpg", "ssh-keygen",
        "ssh-add", "pkgbuild", "productbuild", "notarytool", "stapler", "claude", "codex", "ollama", "llm", "aider",
        "gemini",
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

    /// Programs whose first operand is a name of the program's own, and
    /// isn't on the list above: a make target (`make test`), a task, a
    /// command (`terraform plan`). They and every program not on the list
    /// say it when the hook keeps text (`wide`), if it's shaped like one
    /// (`isSubcommand`).
    static let verbs: Set<String> = [
        "make", "just", "task", "rake", "mix", "bazel", "bazelisk", "buck2", "nx", "turbo", "lerna", "deno", "dotnet",
        "gradle", "gradlew", "mvn", "sbt", "lein", "stack", "cabal", "dune", "opam", "zig", "flutter", "dart", "pio",
        "platformio", "terraform", "pulumi", "helm", "fly", "flyctl", "vercel", "wrangler", "netlify", "firebase",
        "gcloud", "aws", "az", "doctl", "heroku", "railway", "supabase", "prisma", "nix", "conda", "mamba", "pipx",
        "rustup", "mise", "asdf", "volta", "tmux", "launchctl", "defaults", "diskutil", "hdiutil", "tmutil", "xcrun",
        "simctl", "systemctl", "podman", "minikube", "kind", "skaffold", "tilt", "colima", "ollama", "tailscale",
        "ngrok", "claude", "codex", "gemini", "llm", "ruff", "biome", "port", "apt", "apt-get", "dnf", "yum",
        "pacman", "apk", "gem", "composer", "hex", "notarytool", "alembic", "sqlx", "drizzle-kit", "flyway", "sam",
        "cdk", "serverless", "sls", "ansible-galaxy", "vagrant", "docker-compose",
    ]

    /// Flags a program takes before its subcommand that take the next word
    /// as their value: `git -C repo log`.
    static let valueFlags: [String: Set<String>] = [
        "make": ["-C", "-f", "-I", "-o", "-W", "--directory", "--file", "--include-dir", "--makefile"],
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
    /// `own` adds your programs (`words.json`); `wide` names any program
    /// and its subcommand (`isSubcommand`), when the hook keeps text.
    public static func word(tool: String?, input: Any?, own: Set<String> = [], wide: Bool = false) -> String? {
        guard ToolKind.of(tool) == .shell, let commands = Topic.commands(in: input) else { return nil }
        return word(commands, own: own, wide: wide)
    }

    /// The word for a command line: `grep`, `git log`, `loop` for a `for`
    /// or `while` loop, or `run` for a program that's neither known nor
    /// yours, unless `wide`. The first command that does something counts,
    /// after `cd`, `echo` and the like (`cd src && rg foo` is `rg`). Nil
    /// when nothing runs.
    public static func word(command: String, own: Set<String> = [], wide: Bool = false) -> String? {
        word(Topic.commands(command), own: own, wide: wide)
    }

    static func word(_ commands: [[String]], own: Set<String>, wide: Bool = false) -> String? {
        var bystander: String?
        for words in commands {
            if ["for", "while", "until"].contains(words.first) { return "loop" }
            guard let (program, args) = Topic.unwrap(words) else { continue }
            if Topic.shells.contains(program), let at = args.firstIndex(where: Topic.isDashC), at + 1 < args.count {
                if let inside = word(Topic.commands(args[at + 1]), own: own, wide: wide) { return inside }
                continue
            }
            let name = normal(program)
            if quiet.contains(name) {
                bystander = bystander ?? name
                continue
            }
            if own.contains(name) { return wide ? withSubcommand(name, args, wide: true) : name }
            guard known.contains(name) else {
                return wide && Glimpse.keeps(name) ? withSubcommand(name, args, wide: true) : "run"
            }
            return withSubcommand(name, args, wide: wide)
        }
        // A line of only bystanders: `echo done`.
        return bystander
    }

    /// Commands that set up for the one that does something:
    /// `cd`, `echo`, `export X=1`, `source env.sh`.
    static let quiet = Topic.bystanders.union(["export", "set", "unset", "source", ".", "local", "read"])

    /// The program and its subcommand: one from its list, or with `wide`
    /// any first operand shaped like one (`isSubcommand`), of a program
    /// with a list, one of `verbs` or one not on the list at all.
    static func withSubcommand(_ program: String, _ args: [String], wide: Bool = false) -> String {
        let allowed = subcommands[program]
        let open = wide && (allowed != nil || verbs.contains(program) || !known.contains(program))
        guard allowed != nil || open else { return program }
        let valued = valueFlags[program] ?? []
        var i = 0
        while i < args.count, args[i].hasPrefix("-") || Topic.isAssignment(args[i]) {
            i += valued.contains(args[i]) ? 2 : 1
        }
        guard i < args.count, allowed?.contains(args[i]) == true || open && isSubcommand(args[i]) else { return program }
        return program + " " + args[i]
    }

    /// Whether an operand is shaped like a subcommand or a target: a
    /// lowercase word of 2 to 14 letters, digits, `-`, `_` or `:`, starting
    /// with a letter (`test`, `fw-test`, `db:migrate`), and not a file
    /// (`main.c`) or a path.
    static func isSubcommand(_ word: String) -> Bool {
        guard (2...14).contains(word.count), let first = word.first, first.isLowercase, first.isASCII else { return false }
        return word.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || "-_:".contains($0)) }
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
