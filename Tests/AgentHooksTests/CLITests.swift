import Darwin
import Foundation
import Testing

/// The `agent-hooks` command line, run as built, next to the tests.
@Suite struct CLITests {
    /// A program the build made: it sits beside the tests' own bundle.
    static func built(_ program: String) -> URL? {
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0, let image = info.dli_fname else { return nil }
        var folder = URL(fileURLWithPath: String(cString: image))
        while folder.path != "/", folder.pathExtension != "xctest" { folder.deleteLastPathComponent() }
        guard folder.pathExtension == "xctest" else { return nil }
        return folder.deletingLastPathComponent().appendingPathComponent(program)
    }

    /// Runs `agent-hooks` with `arguments`; returns its exit status and what it printed.
    func run(_ arguments: [String]) throws -> (status: Int32, out: String, err: String) {
        let program = try #require(Self.built("agent-hooks"))
        try #require(FileManager.default.isExecutableFile(atPath: program.path), "no agent-hooks at \(program.path)")
        let process = Process()
        process.executableURL = program
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let printed = out.fileHandleForReading.readDataToEndOfFile()
        let complained = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: printed, as: UTF8.self),
                String(decoding: complained, as: UTF8.self))
    }

    /// `--help` or `-h`, alone or after any command, prints the usage and
    /// exits 0, and changes nothing.
    @Test(arguments: [["--help"], ["-h"], ["help"], ["install", "--help"], ["remove", "-h"],
                      ["status", "--help"], ["tail", "--help"], ["doctor", "-h"],
                      ["install", "claude", "--keep-text", "--help"]])
    func testHelpAfterAnyCommandPrintsTheUsage(_ arguments: [String]) throws {
        let result = try run(arguments)
        #expect(result.status == 0)
        #expect(result.out.contains("agent-hooks install [claude|codex]"))
        #expect(result.err.isEmpty)
    }

    /// An option it doesn't know is still an error.
    @Test func testAnUnknownOptionFails() throws {
        let result = try run(["status", "--nope"])
        #expect(result.status == 1)
        #expect(result.err.contains("unknown option --nope"))
    }
}
