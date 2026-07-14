import AppKit
import Foundation
import XCTest
@testable import WakeBar

final class PMSetServiceTests: XCTestCase {
    func testEnabledToggleUsesOnlyExactNoninteractiveCommand() async throws {
        let runner = RecordingCommandRunner(results: [.success])
        let service = PMSetService(
            commandRunner: runner,
            instantControlManager: StubInstantControlManager()
        )

        try await service.setSleepPrevention(enabled: true)

        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].executable.path, "/usr/bin/sudo")
        XCTAssertEqual(
            calls[0].arguments,
            [
                "-n", "-k", "-u", "root", "--",
                "/usr/bin/pmset", "-a", "disablesleep", "1"
            ]
        )
    }

    func testDisabledToggleUsesOnlyExactNoninteractiveCommand() async throws {
        let runner = RecordingCommandRunner(results: [.success])
        let service = PMSetService(
            commandRunner: runner,
            instantControlManager: StubInstantControlManager()
        )

        try await service.setSleepPrevention(enabled: false)

        let calls = await runner.recordedCalls()
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(
            call.arguments,
            [
                "-n", "-k", "-u", "root", "--",
                "/usr/bin/pmset", "-a", "disablesleep", "0"
            ]
        )
    }

    func testPasswordDenialBecomesSetupRequired() async {
        let runner = RecordingCommandRunner(
            results: [
                CommandResult(
                    standardOutput: "",
                    standardError: "sudo: a password is required",
                    terminationStatus: 1
                )
            ]
        )
        let service = PMSetService(
            commandRunner: runner,
            instantControlManager: StubInstantControlManager()
        )

        do {
            try await service.setSleepPrevention(enabled: true)
            XCTFail("Expected authorization to be required")
        } catch {
            XCTAssertEqual(error as? PMSetError, .instantAuthorizationRequired)
        }
    }

    func testAuthorizationRuleContainsOnlyTwoFixedCommands() {
        let rule = WakeBarAuthorizationRule.contents(userID: 501)
        let lines = rule.split(whereSeparator: \Character.isNewline)

        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(rule.contains("#501 ALL=(root) NOPASSWD: NOSETENV:"))
        XCTAssertTrue(rule.contains("/usr/bin/pmset -a disablesleep 0"))
        XCTAssertTrue(rule.contains("/usr/bin/pmset -a disablesleep 1"))
        XCTAssertFalse(rule.contains("*"))
        XCTAssertFalse(rule.contains("/bin/sh"))
        XCTAssertFalse(rule.contains("Cmnd_Alias"))
    }

    func testAuthorizationFilenameWillBeLoadedBySudoers() {
        let path = WakeBarAuthorizationRule.path(userID: 501)
        let filename = URL(fileURLWithPath: path).lastPathComponent

        XCTAssertEqual(filename, "zzzz_wakebar_501")
        XCTAssertFalse(filename.contains("."))
    }

    func testInstallerUsesAtomicValidatedRootOwnedReceipt() throws {
        let script = WakeBarAuthorizationRule.installationScript(userID: 501)

        XCTAssertTrue(script.contains("mktemp \"$directory/.wakebar_501.XXXXXX\""))
        XCTAssertTrue(script.contains("/usr/sbin/chown root:wheel"))
        XCTAssertTrue(script.contains("/bin/chmod 0440"))
        XCTAssertTrue(script.contains("/usr/sbin/visudo -cf \"$temporary\""))
        XCTAssertTrue(script.contains("/bin/mv \"$temporary\" \"$target\""))
        XCTAssertFalse(script.contains("/usr/bin/sudo "))

        try assertValidShellSyntax(script)
    }

    func testRemovalTurnsOffAgentModeAndMatchesExactReceipt() throws {
        let script = WakeBarAuthorizationRule.removalScript(userID: 501)

        XCTAssertTrue(script.contains("/usr/bin/pmset -a disablesleep 0"))
        XCTAssertTrue(script.contains("/usr/bin/cmp -s \"$temporary\" \"$target\""))
        XCTAssertFalse(script.contains("rm -rf"))

        try assertValidShellSyntax(script)
    }

    func testRuleParsesWithVisudo() throws {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wakebar-rule-\(UUID().uuidString)")
        try WakeBarAuthorizationRule.contents(userID: 501)
            .write(to: temporaryURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/visudo")
        process.arguments = ["-cf", temporaryURL.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
    }

    @MainActor
    func testAdministratorAppleScriptCompilesWithoutExecuting() {
        let source = AppleScriptAdministratorCommandRunner.appleScriptSource(
            for: WakeBarAuthorizationRule.installationScript(userID: 501)
        )
        let script = NSAppleScript(source: source)
        var errorInfo: NSDictionary?

        XCTAssertTrue(script?.compileAndReturnError(&errorInfo) == true)
        XCTAssertNil(errorInfo)
    }

    private func assertValidShellSyntax(
        _ shellScript: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", "-c", shellScript]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0, file: file, line: line)
    }
}

private struct RecordedCommand: Equatable, Sendable {
    let executable: URL
    let arguments: [String]
}

private actor RecordingCommandRunner: CommandRunning {
    private var results: [CommandResult]
    private var calls: [RecordedCommand] = []

    init(results: [CommandResult]) {
        self.results = results
    }

    func run(executable: URL, arguments: [String]) async throws -> CommandResult {
        calls.append(RecordedCommand(executable: executable, arguments: arguments))
        return results.removeFirst()
    }

    func recordedCalls() -> [RecordedCommand] {
        calls
    }
}

private actor StubInstantControlManager: InstantControlManaging {
    func receiptLooksValid() async -> Bool { true }
    func install() async throws {}
    func remove() async throws {}
}

private extension CommandResult {
    static let success = CommandResult(
        standardOutput: "",
        standardError: "",
        terminationStatus: 0
    )
}
