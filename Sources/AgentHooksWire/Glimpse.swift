import Foundation

/// A glimpse of a tool call: a few short pieces of what it touched, so an
/// app can show more than the program. A file's name (`Core.swift`), a
/// word it searched for (`maxWordBytes`), a folder (`agent-hooks`), a web
/// host (`swift.org`). Only with `--keep-text`.
///
/// Each piece is one word, picked from the call's input by its shape
/// alone, with no list of programs: a path leaves only its last part, a
/// URL only its host, a pattern or a script only its longest name. Only a
/// piece that `keeps` passes leaves: short, of letters, digits and `._+-`,
/// with a letter, and not shaped like a key, a token or a random ID.
/// Output and file contents never get this far.
public enum Glimpse {
    /// The most pieces a call keeps, and the longest a piece may be.
    public static let most = 3
    public static let longest = 24

    /// The pieces of a tool call, in the order the input has them, without
    /// repeats, the words its program already says, or `home`'s last part
    /// (your user name). Empty for a tool with none: an MCP tool, a
    /// helper, the to-do list.
    public static func of(tool: String?, input: Any?, home: String? = nil) -> [String] {
        var pieces: [String] = []
        var said: Set<String> = []
        let object = input as? [String: Any]
        switch ToolKind.of(tool) {
        case .shell:
            let commands = Topic.commands(in: input) ?? []
            for words in commands { pieces += operands(words) }
            said = Set((Program.word(commands, own: [], wide: true) ?? "").split(separator: " ").map(String.init))
        case .edit, .read:
            pieces = Topic.paths(in: input).compactMap(piece)
        case .search:
            pieces = ["pattern", "path", "glob"].compactMap { (object?[$0] as? String).flatMap(piece) }
        case .web:
            if let url = object?["url"] as? String { pieces = [url].compactMap(piece) }
            if let query = object?["query"] as? String {
                pieces = query.split(separator: " ").map(String.init).filter { $0.count >= 4 }.compactMap(piece)
            }
        default:
            return []
        }
        let user = home.map { ($0 as NSString).lastPathComponent.lowercased() }
        var seen: Set<String> = []
        return Array(pieces.filter { piece in
            let lower = piece.lowercased()
            guard !said.contains(piece), lower != user, !seen.contains(lower) else { return false }
            seen.insert(lower)
            return true
        }.prefix(most))
    }

    /// The pieces of one simple command's operands: not its flags,
    /// variables, a heredoc's marker, its subcommand (`status` in
    /// `git status`), what follows a flag that may take a secret
    /// (`secretFlag`), or a command that only sets up (`cd`, `echo`,
    /// `export`); a shell's `-c`, a container's command and `xargs`'s are
    /// read for their own.
    static func operands(_ words: [String]) -> [String] {
        guard let (program, args) = Topic.unwrap(words), !Program.quiet.contains(program),
              !loops.contains(program) else { return [] }
        if Topic.shells.contains(program), let at = args.firstIndex(where: Topic.isDashC), at + 1 < args.count {
            return Topic.commands(args[at + 1]).flatMap(operands)
        }
        if let inside = Topic.containerCommand(program, args) { return operands(inside) }
        if program == "xargs" { return operands(Array(args.drop { $0.hasPrefix("-") })) }
        let word = Program.withSubcommand(Program.normal(program), args, wide: true)
        var subcommand = word.split(separator: " ").dropFirst().first.map(String.init)
        var kept: [String] = []
        for (i, arg) in args.enumerated() {
            if arg == subcommand {
                subcommand = nil
                continue
            }
            if arg.hasPrefix("-") || arg.hasPrefix("<<") || arg.hasPrefix("$") || Topic.isAssignment(arg) { continue }
            if i > 0, secretFlag(args[i - 1]) { continue }
            if let piece = piece(arg) { kept.append(piece) }
        }
        return kept
    }

    /// Whether a flag may take a secret as its value: a header (`-H`), a
    /// user and password (`-u`, `-p`), or any long flag that names a token,
    /// a key, a password or the like.
    static func secretFlag(_ flag: String) -> Bool {
        guard flag.hasPrefix("-"), !flag.contains("=") else { return false }
        if ["-H", "-u", "-p", "-P"].contains(flag) { return true }
        let name = flag.lowercased()
        return ["token", "key", "secret", "pass", "auth", "cred", "header", "cookie", "user"].contains(where: name.contains)
    }

    static let loops: Set<String> = ["for", "while", "until", "case", "select", "function"]

    /// The piece one word of input stands for, or nil: a URL's host, a
    /// path's last part, a plain word itself, and anything else, a pattern,
    /// quoted text or a script, its longest name of letters alone (a name
    /// with digits in text could be a key).
    static func piece(_ word: String) -> String? {
        var text = word.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("://") {
            guard let host = URLComponents(string: text)?.host else { return nil }
            text = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            return keeps(text) ? text : nil
        }
        // A redirection's target: `>out.txt`, `2>/dev/null`.
        if let arrow = text.range(of: "^[0-9]*[<>&]+", options: .regularExpression) {
            text.removeSubrange(arrow)
        }
        // A place in a file: `Core.swift:120`, `x.swift:3:9`, pytest's
        // `test_x.py::test_it`.
        if let place = text.range(of: "::") {
            text = String(text[..<place.lowerBound])
        } else if let colon = text.firstIndex(of: ":"),
                  text[text.index(after: colon)...].allSatisfy({ $0.isNumber || $0 == ":" }) {
            text = String(text[..<colon])
        }
        if isPath(text), let last = text.split(separator: "/").last {
            text = String(last)
        }
        if text.allSatisfy(allowed) { return keeps(text) ? text : nil }
        let names = text.split { !($0.isLetter || $0.isNumber || $0 == "_") || !$0.isASCII }
            .filter { $0.count >= 3 && !$0.contains(where: \.isNumber) }
        guard let longest = names.max(by: { $0.count < $1.count }) else { return nil }
        return keeps(String(longest)) ? String(longest) : nil
    }

    /// Whether a word is a path: parts of plain characters between
    /// slashes, with a slash, so `s/a/b/g` is too short to be one and a
    /// pattern isn't.
    static func isPath(_ text: String) -> Bool {
        guard text.contains("/") else { return false }
        let parts = text.split(separator: "/", omittingEmptySubsequences: true)
        return !parts.isEmpty && parts.allSatisfy { $0.allSatisfy(allowed) || $0 == "~" }
            && parts.contains { $0.count > 1 }
    }

    static func allowed(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || "._+-".contains(c))
    }

    /// Words that say nothing about the work.
    static let noise: Set<String> = ["null", "dev", "tmp", "stdin", "stdout", "stderr", "true", "false", "eof"]
    /// How keys and tokens start.
    static let secretPrefixes = [
        "sk-", "sk_", "pk_", "rk_", "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat", "xox", "AKIA", "ASIA", "AIza",
        "eyJ", "glpat-", "npm_", "hf_", "shpat_",
    ]

    /// Whether a piece may leave: 2 to `longest` characters of letters,
    /// digits and `._+-`, with a letter, not a word that says nothing, and
    /// not shaped like a secret: a key's prefix, 16 or more hex digits, or
    /// 16 or more characters with upper and lower case and 3 digits, as
    /// random IDs are.
    public static func keeps(_ piece: String) -> Bool {
        guard (2...longest).contains(piece.count), piece.allSatisfy(allowed), piece.contains(where: \.isLetter),
              !noise.contains(piece.lowercased()), !secretPrefixes.contains(where: piece.hasPrefix) else { return false }
        if piece.count >= 16 {
            if piece.allSatisfy(\.isHexDigit) { return false }
            let digits = piece.filter(\.isNumber).count
            if digits >= 3, piece.contains(where: \.isUppercase), piece.contains(where: \.isLowercase) { return false }
        }
        return true
    }
}
