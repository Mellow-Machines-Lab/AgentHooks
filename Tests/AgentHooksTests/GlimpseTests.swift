import Foundation
import Testing
@testable import AgentHooksWire

/// A tool call's glimpse: short pieces of what it touched, by their shape,
/// and never anything shaped like a secret.
@Suite struct GlimpseTests {
    func shell(_ command: String, home: String? = nil) -> [String] {
        Glimpse.of(tool: "Bash", input: ["command": command], home: home)
    }

    @Test func testAShellCallsPiecesAreItsOperands() {
        let cases: [(String, [String])] = [
            ("sed -n '1,80p' app/BoopKit/Core/WorkStream.swift", ["WorkStream.swift"]),
            ("grep -rn 'maxWordBytes' app/BoopKit --include=*.swift", ["maxWordBytes", "BoopKit"]),
            ("git -C agent-hooks log --oneline HEAD..main", ["agent-hooks", "HEAD..main"]),
            ("make -C internal test 2>&1 | tail -5", ["internal"]),
            ("cd /Users/me/src/acme && rg -n 'foo\\|barBaz' src/", ["barBaz", "src"]),
            ("curl -s https://www.swift.org/install/ | head", ["swift.org"]),
            ("python3 - <<'EOF'\nimport os\nprint(os.environ['TOKEN'])\nEOF", []),
            ("cat x.swift > /dev/null", ["x.swift"]),
            ("for f in *.md; do wc -l $f; done", []),
            ("bash -lc 'pytest tests/test_core.py::test_it -q'", ["test_core.py"]),
            ("git show 5bd61bd5 --stat", ["5bd61bd5"]),
            ("git diff --stat a1b2c3d | tail -3; git status --short | grep -v Done", ["a1b2c3d", "Done"]),
            ("find . -name '*.h' | xargs grep -l kGesture", ["kGesture"]),
            ("swiftc a.swift b.swift c.swift d.swift", ["a.swift", "b.swift", "c.swift"]),
            ("ls Sources/x.swift:120", ["x.swift"]),
        ]
        for (command, pieces) in cases { #expect(shell(command) == pieces, "\(command) -> \(shell(command))") }
    }

    @Test func testYourUserNameAndTheProgramsOwnWordsStayOut() {
        #expect(shell("ls /Users/me", home: "/Users/me") == [])
        #expect(shell("git show HEAD") == ["HEAD"])
        #expect(shell("make test") == [])
    }

    @Test func testOtherToolsPieces() {
        #expect(Glimpse.of(tool: "Edit", input: ["file_path": "/w/app/Core.swift"]) == ["Core.swift"])
        #expect(Glimpse.of(tool: "Read", input: ["file_path": "/w/README.md"]) == ["README.md"])
        #expect(Glimpse.of(tool: "Grep", input: ["pattern": "func (\\w+)Stream", "path": "/w/app"]) == ["Stream", "app"])
        #expect(Glimpse.of(tool: "WebFetch", input: ["url": "https://docs.swift.org/x?y=1"]) == ["docs.swift.org"])
        #expect(Glimpse.of(tool: "WebSearch", input: ["query": "swift testing macros flake"]) == ["swift", "testing", "macros"])
        #expect(Glimpse.of(tool: "apply_patch", input: "*** Update File: docs/README.md\n@@") == ["README.md"])
        #expect(Glimpse.of(tool: "mcp__linear__create_issue", input: ["title": "x"]) == [])
        #expect(Glimpse.of(tool: "Agent", input: ["prompt": "do it"]) == [])
    }

    /// Keys, tokens and random IDs never leave, whatever their shape.
    @Test func testNothingShapedLikeASecretLeaves() {
        for secret in ["sk-ant-abc123", "ghp_abcdefghijklmnop", "AKIAIOSFODNN7EXAMPLE", "eyJhbGciOiJIUzI1NiJ9",
                       "0123456789abcdef0123", "bridge-cse_0199Vhkox2KLpq", "a8F3kd92LmQ0xZ7pTe1"] {
            #expect(!Glimpse.keeps(secret), "\(secret)")
        }
        #expect(shell("curl -H 'Authorization: Bearer ghp_abcdefghijklmnop1234' https://api.github.com/user")
            == ["api.github.com"])
        #expect(shell("curl -u me:hunter https://x.dev --api-key abcd1234secretvalue") == ["x.dev"])
        #expect(shell("python3 -c 'k = \"abcd1234secretvalue\"; send(k)'") == ["send"])
        #expect(shell("export TOKEN=sk-ant-abc123; ./run.sh") == [])
        for kept in ["Core.swift", "fw-test", "HEAD..main", "linkkit-bridge", "5bd61bd5", "x86_64"] {
            #expect(Glimpse.keeps(kept), "\(kept)")
        }
        #expect(!Glimpse.keeps("x") && !Glimpse.keeps("1234") && !Glimpse.keeps("null")
                && !Glimpse.keeps(String(repeating: "a", count: 25)) && !Glimpse.keeps("na me"))
    }
}
