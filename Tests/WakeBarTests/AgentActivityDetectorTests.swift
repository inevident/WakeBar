import Foundation
import XCTest
@testable import WakeBar

@MainActor
final class AgentActivityDetectorTests: XCTestCase {
    func testProcessParserReadsPSColumnsAndFullCommand() throws {
        let output = "  123   7  2.5 Fri Jul 10 09:04:00 2026 /opt/homebrew/bin/codex exec --full-auto\n"

        let record = try XCTUnwrap(AgentProcessParser.parse(output).first)

        XCTAssertEqual(record.pid, 123)
        XCTAssertEqual(record.parentPID, 7)
        XCTAssertEqual(record.cpuPercent, 2.5)
        XCTAssertNotNil(record.startedAt)
        XCTAssertEqual(record.command, "/opt/homebrew/bin/codex exec --full-auto")
        XCTAssertEqual(record.executableBasename, "codex")
    }

    func testProcessParserTrimsLeadingWhitespaceBeforeCursorCommand() throws {
        let output = "801 1 0.0 Mon Jul 13 12:00:00 2026     /Applications/Cursor.app/Contents/MacOS/Cursor\n"

        let record = try XCTUnwrap(AgentProcessParser.parse(output).first)

        XCTAssertEqual(record.command, "/Applications/Cursor.app/Contents/MacOS/Cursor")
        XCTAssertTrue(AgentProcessParser.isCursorApplication(record))
    }

    func testExactCLIProcessMatchersCoverSupportedRuntimes() {
        let fixtures: [(String, AgentRuntime)] = [
            ("/opt/homebrew/bin/codex exec", .codex),
            ("/usr/local/bin/claude -p hello", .claude),
            ("/usr/local/bin/cursor-agent run", .cursor),
            ("/opt/homebrew/bin/opencode run", .openCode),
            ("/usr/local/bin/copilot suggest", .copilot),
            ("/opt/homebrew/bin/gemini -p hello", .gemini),
            ("/usr/local/bin/antigravity-cli run", .antigravity),
            ("/opt/homebrew/bin/aider --yes", .aider),
            ("/usr/local/bin/goose run", .goose),
            ("/usr/local/bin/amp run", .amp),
            ("/usr/local/bin/kiro-cli chat", .kiro),
            ("/usr/local/bin/droid exec", .factory),
            ("/usr/local/bin/codebuff run", .codebuff),
            ("/usr/local/bin/qoder-cli run", .qoder),
            ("/usr/local/bin/cline-cli run", .cline),
            ("/usr/local/bin/kilo-cli run", .kilo),
            ("/usr/local/bin/crush run", .crush),
            ("/usr/local/bin/deepseek-code run", .deepSeek),
            ("/usr/local/bin/minimax-code run", .minimax),
            ("/usr/local/bin/groq-build run", .groq)
        ]

        for (command, expectedRuntime) in fixtures {
            XCTAssertEqual(
                AgentProcessParser.runtime(for: process(command: command)),
                expectedRuntime,
                command
            )
        }
    }

    func testNodePackageMatchersArePathAnchored() {
        let fixtures: [(String, AgentRuntime)] = [
            ("/opt/homebrew/bin/node /tmp/node_modules/@anthropic-ai/claude-code/cli.js", .claude),
            ("/opt/homebrew/bin/node /tmp/node_modules/@openai/codex/bin/codex.js", .codex),
            ("/opt/homebrew/bin/bun /tmp/node_modules/opencode-ai/bin.js", .openCode),
            ("/opt/homebrew/bin/node /tmp/node_modules/@google/gemini-cli/index.js", .gemini),
            ("/opt/homebrew/bin/node /tmp/node_modules/codebuff/bin.js", .codebuff)
        ]

        for (command, expectedRuntime) in fixtures {
            XCTAssertEqual(
                AgentProcessParser.runtime(for: process(command: command)),
                expectedRuntime,
                command
            )
        }

        XCTAssertNil(AgentProcessParser.runtime(
            for: process(command: "/opt/homebrew/bin/node /tmp/not-codex-helper.js")
        ))
    }

    func testPersistentGUIAppsAndHelpersAreNotAgents() {
        let commands = [
            "/Applications/Claude.app/Contents/MacOS/Claude",
            "/Applications/Copilot.app/Contents/MacOS/Copilot",
            "/Applications/Antigravity.app/Contents/MacOS/Antigravity",
            "/Applications/Qoder.app/Contents/MacOS/Qoder",
            "/Applications/Goose.app/Contents/MacOS/Goose",
            "/Applications/Amp.app/Contents/MacOS/Amp",
            "/Applications/Codex.app/Contents/MacOS/Codex",
            "/tmp/disclaimer --accept",
            "/usr/local/bin/claude-code-acp --stdio",
            "/opt/homebrew/bin/codex --help",
            "/opt/homebrew/bin/opencode --version"
        ]

        for command in commands {
            XCTAssertNil(
                AgentProcessParser.runtime(for: process(command: command)),
                command
            )
        }
    }

    func testCodexAppServerIsIdentifiedButNotAWorkSession() async {
        let psOutput = psLine(
            pid: 77,
            command: "/Applications/Codex.app/Contents/Resources/codex app-server"
        )
        let runner = DetectorCommandRunner(
            processOutput: psOutput,
            lsofResult: CommandResult(
                standardOutput: "p77\nccodex\nfcwd\nn/tmp\n",
                standardError: "",
                terminationStatus: 0
            )
        )
        let detector = LocalAgentActivityDetector(
            commandRunner: runner,
            homeDirectory: temporaryDirectory(),
            environment: [:]
        )

        let snapshot = await detector.scan(now: Date())

        XCTAssertEqual(snapshot.activities, [])
        XCTAssertTrue(snapshot.scanWasConclusive)
    }

    func testClaudeDesktopWrapperAndBusyChildSessionProduceOneActivity() async throws {
        let now = Date(timeIntervalSince1970: 1_784_000_120)
        let wrapperStartedAt = now.addingTimeInterval(-60)
        let childStartedAt = now.addingTimeInterval(-59)
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try writeClaudeSession(
            under: base,
            processID: 102,
            sessionID: "desktop-thread",
            workingDirectory: "/Users/test/project",
            processStartedAt: childStartedAt,
            status: .busy,
            statusUpdatedAt: now
        )
        let psOutput = [
            psLine(
                pid: 101,
                parentPID: 1,
                startedAt: wrapperStartedAt,
                command: "/Applications/Claude.app/Contents/Resources/disclaimer /Users/test/Library/Application Support/Claude/claude-code/claude --dangerously-skip-permissions"
            ),
            psLine(
                pid: 102,
                parentPID: 101,
                startedAt: childStartedAt,
                command: "/Users/test/Library/Application Support/Claude/claude-code/claude --dangerously-skip-permissions"
            )
        ].joined(separator: "\n")
        let lsof = "p101\ncdisclaime\nfcwd\nn/Users/test/project\np102\ncclaude\nfcwd\nn/Users/test/project\n"
        let runner = DetectorCommandRunner(
            processOutput: psOutput,
            lsofResult: CommandResult(
                standardOutput: lsof,
                standardError: "",
                terminationStatus: 0
            )
        )
        let detector = LocalAgentActivityDetector(
            commandRunner: runner,
            homeDirectory: base,
            environment: [:]
        )

        let snapshot = await detector.scan(now: now)

        XCTAssertEqual(snapshot.activities.count, 1)
        XCTAssertEqual(snapshot.activities.first?.id, "claude:desktop-thread")
        XCTAssertEqual(snapshot.activities.first?.runtime, .claude)
        XCTAssertEqual(snapshot.activities.first?.processID, 102)
        XCTAssertEqual(snapshot.activities.first?.evidence, .processActivity)
        XCTAssertTrue(snapshot.scanWasConclusive)
    }

    func testLsofParserCorrelatesWritableRolloutByKnownCodexPID() {
        let root = URL(fileURLWithPath: "/custom/codex/sessions", isDirectory: true)
        let rollout = "/custom/codex/sessions/2026/07/10/rollout-one.jsonl"
        let outside = "/tmp/sessions/2026/07/10/rollout-other.jsonl"
        let output = """
        p123
        cnode
        fcwd
        n/Users/test/project
        f18
        au
        n\(rollout)
        p124
        ccodex
        f19
        aw
        n\(outside)
        """

        let snapshot = AgentLsofParser.parse(
            output,
            codexProcessIDs: [123],
            codexSessionsRoots: [root]
        )

        XCTAssertEqual(snapshot.currentWorkingDirectories[123], "/Users/test/project")
        XCTAssertEqual(
            snapshot.writableCodexRollouts,
            [AgentLsofSnapshot.CodexRollout(pid: 123, path: rollout)]
        )
    }

    func testCodexLifecycleUsesNewestOuterEventOnly() {
        let active = """
        {"type":"event_msg","payload":{"type":"task_started"}}
        {"type":"response_item","payload":{"message":"turn_complete"}}
        {"type":"event_msg","payload":{"type":"turn_started"}}
        {"type":"event_msg","payload":{"type":"not_a_terminal_event","note":"task_complete"}}
        """
        XCTAssertEqual(CodexLifecycleReader.latestLifecycle(in: active), .active)

        let complete = active + "\n{\"type\":\"event_msg\",\"payload\":{\"type\":\"turn_complete\"}}\n"
        XCTAssertEqual(CodexLifecycleReader.latestLifecycle(in: complete), .terminal)

        let aborted = active + "\n{\"type\":\"event_msg\",\"payload\":{\"type\":\"turn_aborted\"}}\n"
        XCTAssertEqual(CodexLifecycleReader.latestLifecycle(in: aborted), .terminal)

        let partial = active + "\n{\"type\":\"event_msg\",\"payload\":{\"type\":\"turn_complete\""
        XCTAssertEqual(CodexLifecycleReader.latestLifecycle(in: partial), .active)
    }

    func testCodexMetadataPrefersUniqueThreadID() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let file = directory.appendingPathComponent("rollout-meta.jsonl")
        let text = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"child-thread\",\"session_id\":\"shared-parent\",\"cwd\":\"/Users/test/WakeBar\"}}\n"
        try text.write(to: file, atomically: true, encoding: .utf8)

        let metadata = CodexLifecycleReader.metadata(at: file)

        XCTAssertEqual(metadata.id, "child-thread")
        XCTAssertEqual(metadata.projectName, "WakeBar")
    }

    func testCursorLifecycleRecognizesActiveAndTurnEnded() {
        let active = """
        {"role":"user","message":"work"}
        {"role":"assistant","message":"working"}
        """
        XCTAssertEqual(CursorLifecycleReader.latestLifecycle(in: active), .active)

        let terminal = active + "\n{\"type\":\"turn_ended\"}\n"
        XCTAssertEqual(CursorLifecycleReader.latestLifecycle(in: terminal), .terminal)
    }

    func testCursorLifecycleInspectionCollectsAwaitedShellIDs() {
        let transcript = """
        {"role":"assistant","message":{"content":[{"type":"tool_use","name":"AwaitShell","input":{"shell_id":"602284"}},{"type":"tool_use","name":"OtherTool","input":{"shell_id":"ignored"}}]}}
        {"role":"assistant","message":{"content":[{"type":"tool_use","name":"AwaitShell","input":{"shell_id":"602284"}},{"type":"tool_use","name":"AwaitShell","input":{"shell_id":"81316"}},{"type":"tool_use","name":"AwaitShell","input":{"shell_id":""}}]}}
        """

        let inspection = CursorLifecycleReader.inspection(in: transcript)

        XCTAssertEqual(inspection.lifecycle, .active)
        XCTAssertEqual(inspection.awaitedShellIDs, ["602284", "81316"])
    }

    func testCursorPowerAssertionParserRequiresExactCursorPIDTypeAndName() {
        let output = """
        Assertion status system-wide:
           NoIdleSleepAssertion          1
        Listed by owning process:
           pid 801(Cursor): [0x0000000000000001] 00:00:07 NoIdleSleepAssertion named: "Electron"
           pid 802(Cursor): [0x0000000000000002] 00:00:07 NoIdleSleepAssertion named: "Chromium"
           pid 803(Electron): [0x0000000000000003] 00:00:07 NoIdleSleepAssertion named: "Electron"
           pid 804(Cursor): [0x0000000000000004] 00:00:07 PreventUserIdleSystemSleep named: "Electron"
        """

        let processIDs = CursorPowerAssertionParser.activeProcessIDs(
            in: output,
            cursorProcessIDs: [801, 802, 804]
        )

        XCTAssertEqual(processIDs, [801])
    }

    func testCursorTerminalManifestReaderParsesLiveMetadata() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let startedAt = Date(timeIntervalSince1970: 1_784_000_000.125)
        let manifest = try writeCursorTerminalManifest(
            under: base,
            fileName: "live.txt",
            processID: 901,
            workingDirectory: "/Users/test/My Project",
            startedAt: startedAt
        )

        let metadata = try XCTUnwrap(CursorTerminalManifestReader.read(at: manifest))

        XCTAssertEqual(metadata.processID, 901)
        XCTAssertEqual(metadata.workingDirectory, "/Users/test/My Project")
        XCTAssertEqual(
            metadata.startedAt.timeIntervalSince1970,
            startedAt.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertEqual(metadata.runningForMilliseconds, 1_200)
        XCTAssertFalse(metadata.hasCompletionFooter)
    }

    func testCursorTerminalManifestReaderRecognizesCompletionFooter() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let manifest = try writeCursorTerminalManifest(
            under: base,
            fileName: "complete.txt",
            processID: 902,
            workingDirectory: "/Users/test/project",
            startedAt: Date(timeIntervalSince1970: 1_784_000_000),
            completed: true
        )

        let metadata = try XCTUnwrap(CursorTerminalManifestReader.read(at: manifest))

        XCTAssertTrue(metadata.hasCompletionFooter)
    }

    func testClaudeSessionReaderParsesStatusAndWorkSemantics() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let processStartedAt = Date(timeIntervalSince1970: 1_784_000_000)
        let statusUpdatedAt = Date(timeIntervalSince1970: 1_784_000_100.125)
        let fixtures: [(ClaudeSessionStatus, Bool, Bool)] = [
            (.busy, true, false),
            (.shell, true, false),
            (.idle, false, true),
            (.waiting, false, true)
        ]

        for (index, fixture) in fixtures.enumerated() {
            let (status, isActiveWork, isSettled) = fixture
            let processID = Int32(500 + index)
            let url = try writeClaudeSession(
                under: base,
                processID: processID,
                sessionID: "thread-\(status.rawValue)",
                workingDirectory: "/Users/test/project",
                processStartedAt: processStartedAt,
                status: status,
                statusUpdatedAt: statusUpdatedAt
            )

            let metadata = try XCTUnwrap(ClaudeSessionReader.read(at: url))

            XCTAssertEqual(metadata.processID, processID)
            XCTAssertEqual(metadata.sessionID, "thread-\(status.rawValue)")
            XCTAssertEqual(metadata.workingDirectory, "/Users/test/project")
            XCTAssertEqual(metadata.processStartedAt, processStartedAt)
            XCTAssertEqual(metadata.status, status)
            XCTAssertEqual(metadata.status.isActiveWork, isActiveWork, status.rawValue)
            XCTAssertEqual(metadata.status.isSettled, isSettled, status.rawValue)
            XCTAssertEqual(
                try XCTUnwrap(metadata.statusUpdatedAt).timeIntervalSince1970,
                statusUpdatedAt.timeIntervalSince1970,
                accuracy: 0.001
            )
        }
    }

    func testClaudeLifecycleDistinguishesWorkFromIdlePrompt() {
        let working = """
        {"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use"}]}}
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result"}]}}
        """
        XCTAssertEqual(ClaudeLifecycleReader.latestLifecycle(in: working), .active)

        let idle = working
            + "\n{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"stop_reason\":\"end_turn\",\"content\":[{\"type\":\"text\"}]}}\n"
            + "{\"type\":\"last-prompt\"}\n"
        XCTAssertEqual(ClaudeLifecycleReader.latestLifecycle(in: idle), .terminal)
    }

    func testClaudeLifecycleTreatsLocalCommandAsSettledFallback() {
        let transcript = """
        {"type":"user","message":{"role":"user"}}
        {"type":"system","subtype":"local_command"}
        """

        XCTAssertEqual(ClaudeLifecycleReader.latestLifecycle(in: transcript), .terminal)
    }

    func testClaudeTranscriptPreventsIdleCLIFromCountingAsActive() async throws {
        let now = Date()
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let projectDirectory = base
            .appendingPathComponent(".claude/projects/-Users-test-project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: true
        )
        let transcript = projectDirectory.appendingPathComponent("thread-one.jsonl")
        let active = "{\"type\":\"user\",\"message\":{\"role\":\"user\"}}\n"
        try active.write(to: transcript, atomically: true, encoding: .utf8)

        let runner = DetectorCommandRunner(
            processOutput: psLine(
                pid: 450,
                startedAt: now.addingTimeInterval(-60),
                command: "/usr/local/bin/claude"
            ),
            lsofResult: CommandResult(
                standardOutput: "p450\ncclaude\nfcwd\nn/Users/test/project\n",
                standardError: "",
                terminationStatus: 0
            )
        )
        let detector = LocalAgentActivityDetector(
            commandRunner: runner,
            homeDirectory: base,
            environment: [:]
        )

        let activeSnapshot = await detector.scan(now: now)
        XCTAssertEqual(activeSnapshot.activities.first?.runtime, .claude)
        XCTAssertEqual(activeSnapshot.activities.first?.evidence, .lifecycle)

        let idle = active
            + "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"stop_reason\":\"end_turn\",\"content\":[{\"type\":\"text\"}]}}\n"
        try idle.write(to: transcript, atomically: true, encoding: .utf8)

        let idleSnapshot = await detector.scan(now: now)
        XCTAssertEqual(idleSnapshot.activities, [])
    }

    func testClaudeIdlePromptSessionOverridesLocalCommandTranscript() async throws {
        let now = Date(timeIntervalSince1970: 1_784_000_120)
        let processStartedAt = now.addingTimeInterval(-600)
        let statusUpdatedAt = now.addingTimeInterval(-60)
        let sessionID = "11111111-2222-4333-8444-555555555555"
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try writeClaudeSession(
            under: base,
            processID: 45_001,
            sessionID: sessionID,
            workingDirectory: "/Users/test/project",
            processStartedAt: processStartedAt,
            status: .idle,
            statusUpdatedAt: statusUpdatedAt
        )
        let transcript = """
        {"type":"mode","sessionId":"\(sessionID)"}
        {"type":"permission-mode","sessionId":"\(sessionID)"}
        {"type":"file-history-snapshot"}
        {"type":"user","isMeta":true,"sessionId":"\(sessionID)","message":{"role":"user"}}
        {"type":"user","sessionId":"\(sessionID)","message":{"role":"user"}}
        {"type":"user","sessionId":"\(sessionID)","message":{"role":"user"}}
        {"type":"system","subtype":"local_command","sessionId":"\(sessionID)"}
        {"type":"system","subtype":"local_command","sessionId":"\(sessionID)"}

        """
        _ = try writeClaudeTranscript(
            under: base,
            workingDirectory: "/Users/test/project",
            sessionID: sessionID,
            contents: transcript,
            modifiedAt: statusUpdatedAt
        )
        let runner = DetectorCommandRunner(
            processOutput: psLine(
                pid: 45_001,
                startedAt: processStartedAt,
                command: "/Users/test/.local/bin/claude"
            ),
            lsofResult: successfulResult("p45001\nc2.1.207\nfcwd\nn/Users/test/project\n")
        )
        let detector = LocalAgentActivityDetector(
            commandRunner: runner,
            homeDirectory: base,
            environment: [:]
        )

        let snapshot = await detector.scan(now: now)

        XCTAssertEqual(snapshot.activities, [])
        XCTAssertTrue(snapshot.scanWasConclusive)
    }

    func testClaudeBusyAndShellSessionsProduceActivity() async throws {
        let now = Date(timeIntervalSince1970: 1_784_000_120)
        let processStartedAt = now.addingTimeInterval(-600)

        for (index, status) in [ClaudeSessionStatus.busy, .shell].enumerated() {
            let processID = Int32(460 + index)
            let base = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            _ = try writeClaudeSession(
                under: base,
                processID: processID,
                sessionID: "thread-\(status.rawValue)",
                workingDirectory: "/Users/test/project",
                processStartedAt: processStartedAt,
                status: status,
                statusUpdatedAt: now
            )
            let runner = DetectorCommandRunner(
                processOutput: psLine(
                    pid: processID,
                    startedAt: processStartedAt,
                    command: "/usr/local/bin/claude"
                ),
                lsofResult: successfulResult(
                    "p\(processID)\ncclaude\nfcwd\nn/Users/test/project\n"
                )
            )
            let detector = LocalAgentActivityDetector(
                commandRunner: runner,
                homeDirectory: base,
                environment: [:]
            )

            let snapshot = await detector.scan(now: now)

            XCTAssertEqual(
                snapshot.activities.map(\.id),
                ["claude:thread-\(status.rawValue)"],
                status.rawValue
            )
            XCTAssertEqual(snapshot.activities.first?.processID, processID, status.rawValue)
            XCTAssertEqual(
                snapshot.activities.first?.evidence,
                .processActivity,
                status.rawValue
            )
            XCTAssertTrue(snapshot.scanWasConclusive, status.rawValue)
        }
    }

    func testClaudeWaitingSessionIsSettled() async throws {
        let now = Date(timeIntervalSince1970: 1_784_000_120)
        let processStartedAt = now.addingTimeInterval(-600)
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try writeClaudeSession(
            under: base,
            processID: 470,
            sessionID: "thread-waiting",
            workingDirectory: "/Users/test/project",
            processStartedAt: processStartedAt,
            status: .waiting,
            statusUpdatedAt: now
        )
        let runner = DetectorCommandRunner(
            processOutput: psLine(
                pid: 470,
                startedAt: processStartedAt,
                command: "/usr/local/bin/claude"
            ),
            lsofResult: successfulResult("p470\ncclaude\nfcwd\nn/Users/test/project\n")
        )
        let detector = LocalAgentActivityDetector(
            commandRunner: runner,
            homeDirectory: base,
            environment: [:]
        )

        let snapshot = await detector.scan(now: now)

        XCTAssertEqual(snapshot.activities, [])
        XCTAssertTrue(snapshot.scanWasConclusive)
    }

    func testClaudeStaleOrReusedPIDSessionFallsBackToTranscript() async throws {
        let now = Date(timeIntervalSince1970: 1_784_000_120)
        let processStartedAt = now.addingTimeInterval(-600)
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try writeClaudeTranscript(
            under: base,
            workingDirectory: "/Users/test/project",
            sessionID: "live-transcript",
            contents: "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"stop_reason\":\"tool_use\",\"content\":[{\"type\":\"tool_use\"}]}}\n",
            modifiedAt: now
        )
        _ = try writeClaudeSession(
            under: base,
            fileProcessID: 480,
            processID: 481,
            sessionID: "stale-session",
            workingDirectory: "/Users/test/project",
            processStartedAt: processStartedAt,
            status: .idle,
            statusUpdatedAt: now
        )
        let runner = DetectorCommandRunner(
            processOutput: psLine(
                pid: 480,
                startedAt: processStartedAt,
                command: "/usr/local/bin/claude"
            ),
            lsofResult: successfulResult("p480\ncclaude\nfcwd\nn/Users/test/project\n")
        )
        let detector = LocalAgentActivityDetector(
            commandRunner: runner,
            homeDirectory: base,
            environment: [:]
        )

        let mismatchedPIDSnapshot = await detector.scan(now: now)

        XCTAssertEqual(mismatchedPIDSnapshot.activities.map(\.id), ["claude:live-transcript"])
        XCTAssertEqual(mismatchedPIDSnapshot.activities.first?.evidence, .lifecycle)

        _ = try writeClaudeSession(
            under: base,
            fileProcessID: 480,
            processID: 480,
            sessionID: "reused-pid-session",
            workingDirectory: "/Users/test/project",
            processStartedAt: processStartedAt.addingTimeInterval(10),
            status: .idle,
            statusUpdatedAt: now
        )

        let mismatchedStartSnapshot = await detector.scan(now: now)

        XCTAssertEqual(mismatchedStartSnapshot.activities.map(\.id), ["claude:live-transcript"])
        XCTAssertEqual(mismatchedStartSnapshot.activities.first?.evidence, .lifecycle)
        XCTAssertTrue(mismatchedStartSnapshot.scanWasConclusive)
    }

    func testDetectorUsesCustomCodexHomeNodePIDAndLifecycle() async throws {
        let now = Date()
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let codexHome = base.appendingPathComponent("custom-codex", isDirectory: true)
        let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
        let day = dayPath(for: now)
        let directory = sessions.appendingPathComponent(day, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rollout = directory.appendingPathComponent("rollout-one.jsonl")
        try activeCodexRollout(id: "thread-one").write(
            to: rollout,
            atomically: true,
            encoding: .utf8
        )

        let psOutput = psLine(
            pid: 501,
            startedAt: now.addingTimeInterval(-120),
            command: "/opt/homebrew/bin/node /tmp/node_modules/@openai/codex/bin/codex.js exec"
        )
        let lsofOutput = "p501\ncnode\nfcwd\nn/Users/test/project\nf22\nau\nn\(rollout.path)\n"
        let runner = DetectorCommandRunner(
            processOutput: psOutput,
            lsofResult: CommandResult(
                standardOutput: lsofOutput,
                standardError: "",
                terminationStatus: 0
            )
        )
        let detector = LocalAgentActivityDetector(
            commandRunner: runner,
            homeDirectory: base,
            environment: ["CODEX_HOME": codexHome.path]
        )

        let activeSnapshot = await detector.scan(now: now)
        XCTAssertEqual(activeSnapshot.activities.map(\.id), ["codex:thread-one"])
        XCTAssertEqual(activeSnapshot.activities.first?.evidence, .lifecycle)
        XCTAssertTrue(activeSnapshot.scanWasConclusive)

        let completed = activeCodexRollout(id: "thread-one")
            + "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}\n"
        try completed.write(to: rollout, atomically: true, encoding: .utf8)

        let terminalSnapshot = await detector.scan(now: now)
        XCTAssertEqual(terminalSnapshot.activities, [])
        XCTAssertTrue(terminalSnapshot.scanWasConclusive)

        let unknown = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"thread-one\",\"cwd\":\"/Users/test/project\"}}\n"
            + "{\"type\":\"new_protocol_event\",\"payload\":{}}\n"
        try unknown.write(to: rollout, atomically: true, encoding: .utf8)

        let unknownSnapshot = await detector.scan(now: now)
        XCTAssertEqual(unknownSnapshot.activities.first?.evidence, .recentTranscript)
        XCTAssertTrue(unknownSnapshot.scanWasConclusive)

        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-11 * 60)],
            ofItemAtPath: rollout.path
        )

        let staleUnknownSnapshot = await detector.scan(now: now)
        XCTAssertEqual(staleUnknownSnapshot.activities, [])
        XCTAssertFalse(staleUnknownSnapshot.scanWasConclusive)
    }

    func testCodexProcessWithFailedLsofDoesNotBecomeGenericActivity() async {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let runner = DetectorCommandRunner(
            processOutput: psLine(pid: 700, command: "/opt/homebrew/bin/codex exec"),
            lsofResult: nil
        )
        let detector = LocalAgentActivityDetector(
            commandRunner: runner,
            homeDirectory: base,
            environment: [:]
        )

        let snapshot = await detector.scan(now: Date())

        XCTAssertEqual(snapshot.activities, [])
        XCTAssertTrue(snapshot.processScanSucceeded)
        XCTAssertFalse(snapshot.scanWasConclusive)
    }

    func testPmsetFailureUsesFreshCursorTranscriptAndHonorsTerminalState() async throws {
        let now = Date()
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let transcriptDirectory = base
            .appendingPathComponent(".cursor/projects/wakebar/agent-transcripts/thread-one", isDirectory: true)
        try FileManager.default.createDirectory(
            at: transcriptDirectory,
            withIntermediateDirectories: true
        )
        let transcript = transcriptDirectory.appendingPathComponent("thread-one.jsonl")
        try activeCursorTranscript(awaitingShellID: "orphaned").write(
            to: transcript,
            atomically: true,
            encoding: .utf8
        )

        let runner = DetectorCommandRunner(
            processOutput: psLine(
                pid: 801,
                startedAt: now.addingTimeInterval(-60),
                command: "/Applications/Cursor.app/Contents/MacOS/Cursor"
            ),
            lsofResult: nil
        )
        let detector = LocalAgentActivityDetector(
            commandRunner: runner,
            homeDirectory: base,
            environment: [:]
        )

        let activeSnapshot = await detector.scan(now: now)
        XCTAssertEqual(activeSnapshot.activities.map(\.id), ["cursor:thread-one"])
        XCTAssertEqual(activeSnapshot.activities.first?.runtime, .cursor)
        XCTAssertEqual(activeSnapshot.activities.first?.evidence, .lifecycle)
        XCTAssertTrue(activeSnapshot.scanWasConclusive)

        try "{\"role\":\"assistant\"}\n{\"type\":\"turn_ended\"}\n".write(
            to: transcript,
            atomically: true,
            encoding: .utf8
        )
        let terminalSnapshot = await detector.scan(now: now)
        XCTAssertEqual(terminalSnapshot.activities, [])
        XCTAssertTrue(terminalSnapshot.scanWasConclusive)

        try "{\"role\":\"assistant\"}\n".write(
            to: transcript,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-120)],
            ofItemAtPath: transcript.path
        )
        let staleSnapshot = await detector.scan(now: now)
        XCTAssertEqual(staleSnapshot.activities, [])
        XCTAssertTrue(staleSnapshot.scanWasConclusive)
    }

    func testMatchingCursorPowerAssertionNeverCreatesStandaloneActivity() async {
        let now = Date()
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let runner = DetectorCommandRunner(
            processOutput: psLine(
                pid: 801,
                startedAt: now.addingTimeInterval(-60),
                command: "/Applications/Cursor.app/Contents/MacOS/Cursor"
            ),
            lsofResult: nil,
            pmsetAssertionsResult: CommandResult(
                standardOutput: "   pid 801(Cursor): [0x0000000000000001] 00:00:07 NoIdleSleepAssertion named: \"Electron\"\n",
                standardError: "",
                terminationStatus: 0
            )
        )
        let detector = LocalAgentActivityDetector(
            commandRunner: runner,
            homeDirectory: base,
            environment: [:]
        )

        let snapshot = await detector.scan(now: now)

        XCTAssertEqual(snapshot.activities, [])
        XCTAssertTrue(snapshot.scanWasConclusive)
    }

    func testMatchingCursorPowerAssertionCorroboratesStaleActiveTranscript() async throws {
        let now = Date(timeIntervalSince1970: 1_784_000_120)
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try writeCursorTranscript(
            under: base,
            contents: "{\"role\":\"assistant\",\"message\":{\"content\":[]}}\n",
            modifiedAt: now.addingTimeInterval(-600)
        )
        let runner = DetectorCommandRunner(
            processOutput: psLine(
                pid: 801,
                startedAt: now.addingTimeInterval(-3_600),
                command: "/Applications/Cursor.app/Contents/MacOS/Cursor"
            ),
            lsofResult: nil,
            pmsetAssertionsResult: successfulResult(
                "   pid 801(Cursor): [0x1] 00:10:00 NoIdleSleepAssertion named: \"Electron\"\n"
            )
        )
        let detector = LocalAgentActivityDetector(
            commandRunner: runner,
            homeDirectory: base,
            environment: [:]
        )

        let snapshot = await detector.scan(now: now)

        XCTAssertEqual(snapshot.activities.map(\.id), ["cursor:thread-one"])
        XCTAssertEqual(snapshot.activities.first?.evidence, .processActivity)
        XCTAssertTrue(snapshot.scanWasConclusive)
    }

    func testSuccessfulEmptyCursorAssertionOverridesStaleLocalSignals() async throws {
        let now = Date(timeIntervalSince1970: 1_784_000_120)
        let toolStartedAt = now.addingTimeInterval(-30)
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        let transcriptDirectory = base
            .appendingPathComponent(
                ".cursor/projects/wakebar/agent-transcripts/thread-one",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: transcriptDirectory,
            withIntermediateDirectories: true
        )
        let transcript = transcriptDirectory.appendingPathComponent("thread-one.jsonl")
        try "{\"role\":\"assistant\"}\n".write(
            to: transcript,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now],
            ofItemAtPath: transcript.path
        )

        _ = try writeCursorTerminalManifest(
            under: base,
            fileName: "orphaned.txt",
            processID: 913,
            workingDirectory: "/Users/test/WakeBar",
            startedAt: toolStartedAt
        )

        let processOutput = [
            psLine(
                pid: 801,
                startedAt: now.addingTimeInterval(-60),
                command: "/Applications/Cursor.app/Contents/MacOS/Cursor"
            ),
            psLine(
                pid: 913,
                parentPID: 801,
                startedAt: toolStartedAt,
                command: "/bin/zsh -l"
            )
        ].joined(separator: "\n")
        let runner = DetectorCommandRunner(
            processOutput: processOutput,
            lsofResult: nil,
            pmsetAssertionsResult: successfulResult()
        )
        let detector = LocalAgentActivityDetector(
            commandRunner: runner,
            homeDirectory: base,
            environment: [:]
        )

        let snapshot = await detector.scan(now: now)

        XCTAssertEqual(snapshot.activities, [])
        XCTAssertTrue(snapshot.scanWasConclusive)
    }

    func testStoppedCursorTaskWithErrorSuppressesStillLiveAwaitedShell() async throws {
        let now = Date(timeIntervalSince1970: 1_784_000_120)
        let shellStartedAt = now.addingTimeInterval(-900)
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let stoppedTranscript = """
        {"role":"user","message":{"content":[]}}
        {"role":"assistant","message":{"content":[{"type":"tool_use","name":"AwaitShell","input":{"shell_id":"602284"}}]}}
        {"role":"assistant","message":{"content":[]}}
        {"type":"turn_ended","status":"error","error":{}}

        """
        _ = try writeCursorTranscript(
            under: base,
            threadID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            contents: stoppedTranscript,
            modifiedAt: now
        )
        _ = try writeCursorTerminalManifest(
            under: base,
            fileName: "602284.txt",
            processID: 81_316,
            workingDirectory: "/Users/test/project",
            startedAt: shellStartedAt
        )
        let processOutput = [
            psLine(
                pid: 90_359,
                startedAt: now.addingTimeInterval(-3_600),
                command: "/Applications/Cursor.app/Contents/MacOS/Cursor"
            ),
            psLine(
                pid: 12_233,
                parentPID: 90_359,
                startedAt: now.addingTimeInterval(-3_000),
                command: "Cursor Helper (Plugin): extension-host menubarpmset"
            ),
            psLine(
                pid: 81_316,
                parentPID: 12_233,
                startedAt: shellStartedAt,
                command: "/bin/zsh -l"
            )
        ].joined(separator: "\n")
        let runner = DetectorCommandRunner(
            processOutput: processOutput,
            lsofResult: nil,
            pmsetAssertionsResult: successfulResult(
                "   pid 90359(Cursor): [0x1] 00:15:00 NoIdleSleepAssertion named: \"Electron\"\n"
            )
        )
        let detector = LocalAgentActivityDetector(
            commandRunner: runner,
            homeDirectory: base,
            environment: [:]
        )

        let snapshot = await detector.scan(now: now)

        XCTAssertEqual(snapshot.activities, [])
        XCTAssertTrue(snapshot.scanWasConclusive)
    }

    func testCursorTerminalManifestRequiresLiveProcess() async throws {
        let now = Date(timeIntervalSince1970: 1_784_000_120)
        let processStartedAt = Date(timeIntervalSince1970: 1_784_000_000)
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try writeCursorTranscript(
            under: base,
            contents: activeCursorTranscript(awaitingShellID: "dead"),
            modifiedAt: now.addingTimeInterval(-600)
        )
        _ = try writeCursorTerminalManifest(
            under: base,
            fileName: "dead.txt",
            processID: 911,
            workingDirectory: "/Users/test/project",
            startedAt: processStartedAt
        )
        let runner = DetectorCommandRunner(
            processOutput: psLine(
                pid: 801,
                startedAt: now.addingTimeInterval(-3_600),
                command: "/Applications/Cursor.app/Contents/MacOS/Cursor"
            ),
            lsofResult: nil
        )
        let detector = LocalAgentActivityDetector(
            commandRunner: runner,
            homeDirectory: base,
            environment: [:]
        )

        let snapshot = await detector.scan(now: now)

        XCTAssertEqual(snapshot.activities, [])
        XCTAssertTrue(snapshot.scanWasConclusive)
    }

    func testCursorTerminalManifestRejectsReusedPIDWithStartMismatch() async throws {
        let now = Date(timeIntervalSince1970: 1_784_000_120)
        let recordedStart = Date(timeIntervalSince1970: 1_784_000_000)
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try writeCursorTranscript(
            under: base,
            contents: activeCursorTranscript(awaitingShellID: "reused"),
            modifiedAt: now.addingTimeInterval(-600)
        )
        _ = try writeCursorTerminalManifest(
            under: base,
            fileName: "reused.txt",
            processID: 912,
            workingDirectory: "/Users/test/project",
            startedAt: recordedStart
        )
        let processOutput = [
            psLine(
                pid: 801,
                startedAt: now.addingTimeInterval(-3_600),
                command: "/Applications/Cursor.app/Contents/MacOS/Cursor"
            ),
            psLine(
                pid: 912,
                parentPID: 801,
                startedAt: recordedStart.addingTimeInterval(10),
                command: "/bin/zsh -l"
            )
        ].joined(separator: "\n")
        let runner = DetectorCommandRunner(
            processOutput: processOutput,
            lsofResult: nil
        )
        let detector = LocalAgentActivityDetector(
            commandRunner: runner,
            homeDirectory: base,
            environment: [:]
        )

        let snapshot = await detector.scan(now: now)

        XCTAssertEqual(snapshot.activities, [])
        XCTAssertTrue(snapshot.scanWasConclusive)
    }

    func testCursorTerminalManifestNeverCreatesStandaloneActivity() async throws {
        let now = Date(timeIntervalSince1970: 1_784_000_120)
        let processStartedAt = Date(timeIntervalSince1970: 1_784_000_000)
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try writeCursorTerminalManifest(
            under: base,
            fileName: "standalone.txt",
            processID: 913,
            workingDirectory: "/Users/test/WakeBar",
            startedAt: processStartedAt
        )
        let processOutput = [
            psLine(
                pid: 801,
                startedAt: now.addingTimeInterval(-3_600),
                command: "/Applications/Cursor.app/Contents/MacOS/Cursor"
            ),
            psLine(
                pid: 913,
                parentPID: 801,
                startedAt: processStartedAt,
                command: "/bin/zsh -l"
            )
        ].joined(separator: "\n")
        let runner = DetectorCommandRunner(
            processOutput: processOutput,
            lsofResult: nil
        )
        let detector = LocalAgentActivityDetector(
            commandRunner: runner,
            homeDirectory: base,
            environment: [:]
        )

        let snapshot = await detector.scan(now: now)

        XCTAssertEqual(snapshot.activities, [])
        XCTAssertTrue(snapshot.scanWasConclusive)
    }

    func testPmsetFailureExtendsOldActiveTranscriptWithLinkedLiveTerminal() async throws {
        let now = Date(timeIntervalSince1970: 1_784_000_120)
        let processStartedAt = Date(timeIntervalSince1970: 1_784_000_000)
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try writeCursorTranscript(
            under: base,
            contents: activeCursorTranscript(awaitingShellID: "linked"),
            modifiedAt: now.addingTimeInterval(-600)
        )
        _ = try writeCursorTerminalManifest(
            under: base,
            fileName: "linked.txt",
            processID: 913,
            workingDirectory: "/Users/test/WakeBar",
            startedAt: processStartedAt
        )
        _ = try writeCursorTerminalManifest(
            under: base,
            fileName: "unlinked.txt",
            processID: 914,
            workingDirectory: "/Users/test/WakeBar",
            startedAt: processStartedAt
        )
        let processOutput = [
            psLine(
                pid: 801,
                startedAt: now.addingTimeInterval(-3_600),
                command: "/Applications/Cursor.app/Contents/MacOS/Cursor"
            ),
            psLine(
                pid: 913,
                parentPID: 801,
                startedAt: processStartedAt,
                command: "/bin/zsh -l"
            ),
            psLine(
                pid: 914,
                parentPID: 801,
                startedAt: processStartedAt,
                command: "/bin/zsh -l"
            )
        ].joined(separator: "\n")
        let runner = DetectorCommandRunner(
            processOutput: processOutput,
            lsofResult: nil
        )
        let detector = LocalAgentActivityDetector(
            commandRunner: runner,
            homeDirectory: base,
            environment: [:]
        )

        let snapshot = await detector.scan(now: now)

        XCTAssertEqual(snapshot.activities.map(\.id), ["cursor:thread-one"])
        XCTAssertEqual(snapshot.activities.first?.processID, 913)
        XCTAssertEqual(snapshot.activities.first?.evidence, .processActivity)
        XCTAssertTrue(snapshot.scanWasConclusive)
    }

    private func process(
        pid: Int32 = 42,
        parentPID: Int32 = 1,
        command: String
    ) -> AgentProcessRecord {
        AgentProcessRecord(
            pid: pid,
            parentPID: parentPID,
            cpuPercent: 0,
            startedAt: nil,
            command: command
        )
    }

    private func psLine(
        pid: Int32,
        parentPID: Int32 = 1,
        cpuPercent: Double = 0,
        startedAt: Date = Date().addingTimeInterval(-60),
        command: String
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return "\(pid) \(parentPID) \(cpuPercent) \(formatter.string(from: startedAt)) \(command)"
    }

    private func dayPath(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter.string(from: date)
    }

    private func activeCodexRollout(id: String) -> String {
        """
        {"type":"session_meta","payload":{"id":"\(id)","session_id":"parent","cwd":"/Users/test/project"}}
        {"type":"event_msg","payload":{"type":"task_started"}}

        """
    }

    private func writeClaudeSession(
        under homeDirectory: URL,
        fileProcessID: Int32? = nil,
        processID: Int32,
        sessionID: String,
        workingDirectory: String,
        processStartedAt: Date,
        status: ClaudeSessionStatus,
        statusUpdatedAt: Date
    ) throws -> URL {
        let directory = homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let processStartFormatter = DateFormatter()
        processStartFormatter.locale = Locale(identifier: "en_US_POSIX")
        processStartFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        processStartFormatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let object: [String: Any] = [
            "pid": Int(processID),
            "sessionId": sessionID,
            "cwd": workingDirectory,
            "startedAt": processStartedAt.timeIntervalSince1970 * 1_000,
            "procStart": processStartFormatter.string(from: processStartedAt),
            "status": status.rawValue,
            "statusUpdatedAt": statusUpdatedAt.timeIntervalSince1970 * 1_000,
            "updatedAt": statusUpdatedAt.timeIntervalSince1970 * 1_000,
            "kind": "interactive",
            "entrypoint": "cli",
            "version": "2.1.207"
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let url = directory.appendingPathComponent("\(fileProcessID ?? processID).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func writeClaudeTranscript(
        under homeDirectory: URL,
        workingDirectory: String,
        sessionID: String,
        contents: String,
        modifiedAt: Date
    ) throws -> URL {
        let escapedWorkingDirectory = String(workingDirectory.unicodeScalars.map { scalar in
            let value = scalar.value
            let isASCIIAlphanumeric = (48...57).contains(value)
                || (65...90).contains(value)
                || (97...122).contains(value)
            return isASCIIAlphanumeric ? Character(scalar) : "-"
        })
        let directory = homeDirectory
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(escapedWorkingDirectory, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let url = directory.appendingPathComponent("\(sessionID).jsonl")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: modifiedAt],
            ofItemAtPath: url.path
        )
        return url
    }

    private func activeCursorTranscript(awaitingShellID shellID: String) -> String {
        """
        {"role":"assistant","message":{"content":[{"type":"tool_use","name":"AwaitShell","input":{"shell_id":"\(shellID)"}}]}}

        """
    }

    private func writeCursorTranscript(
        under homeDirectory: URL,
        threadID: String = "thread-one",
        contents: String,
        modifiedAt: Date
    ) throws -> URL {
        let directory = homeDirectory.appendingPathComponent(
            ".cursor/projects/wakebar/agent-transcripts/\(threadID)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let url = directory.appendingPathComponent("\(threadID).jsonl")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: modifiedAt],
            ofItemAtPath: url.path
        )
        return url
    }

    private func writeCursorTerminalManifest(
        under homeDirectory: URL,
        fileName: String,
        processID: Int32,
        workingDirectory: String,
        startedAt: Date,
        completed: Bool = false
    ) throws -> URL {
        let directory = homeDirectory
            .appendingPathComponent(".cursor/projects/wakebar/terminals", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var contents = """
        ---
        pid: \(processID)
        cwd: "\(workingDirectory)"
        command: "npm test"
        started_at: \(formatter.string(from: startedAt))
        running_for_ms: 1200
        ---
        still running

        """
        if completed {
            contents += "exit_code: 0\nended_at: \(formatter.string(from: startedAt.addingTimeInterval(1.2)))\n"
        }

        let url = directory.appendingPathComponent(fileName)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func successfulResult(_ output: String = "") -> CommandResult {
        CommandResult(
            standardOutput: output,
            standardError: "",
            terminationStatus: 0
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WakeBarTests-\(UUID().uuidString)", isDirectory: true)
    }
}

private enum DetectorRunnerError: Error {
    case unavailable
}

private actor DetectorCommandRunner: CommandRunning {
    private let processOutput: String
    private let lsofResult: CommandResult?
    private let pmsetAssertionsResult: CommandResult?

    init(
        processOutput: String,
        lsofResult: CommandResult?,
        pmsetAssertionsResult: CommandResult? = nil
    ) {
        self.processOutput = processOutput
        self.lsofResult = lsofResult
        self.pmsetAssertionsResult = pmsetAssertionsResult
    }

    func run(executable: URL, arguments: [String]) async throws -> CommandResult {
        if executable.path == "/bin/ps" {
            return CommandResult(
                standardOutput: processOutput,
                standardError: "",
                terminationStatus: 0
            )
        }

        if executable.path == "/usr/bin/pmset" {
            guard let pmsetAssertionsResult else {
                throw DetectorRunnerError.unavailable
            }
            return pmsetAssertionsResult
        }

        guard let lsofResult else {
            throw DetectorRunnerError.unavailable
        }
        return lsofResult
    }
}
