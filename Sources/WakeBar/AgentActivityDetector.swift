import Foundation

enum AgentRuntime: String, CaseIterable, Codable, Sendable {
    case codex
    case claude
    case cursor
    case openCode
    case copilot
    case gemini
    case antigravity
    case aider
    case goose
    case amp
    case kiro
    case factory
    case codebuff
    case qoder
    case cline
    case kilo
    case crush
    case deepSeek
    case minimax
    case groq

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .cursor: return "Cursor"
        case .openCode: return "OpenCode"
        case .copilot: return "GitHub Copilot"
        case .gemini: return "Gemini CLI"
        case .antigravity: return "Antigravity"
        case .aider: return "Aider"
        case .goose: return "Goose"
        case .amp: return "Amp"
        case .kiro: return "Kiro"
        case .factory: return "Factory Droid"
        case .codebuff: return "Codebuff"
        case .qoder: return "Qoder"
        case .cline: return "Cline"
        case .kilo: return "Kilo Code"
        case .crush: return "Crush"
        case .deepSeek: return "DeepSeek Code"
        case .minimax: return "MiniMax Code"
        case .groq: return "Groq Build"
        }
    }
}

enum AgentActivityEvidence: String, Codable, Sendable {
    case lifecycle
    case liveProcess
    case recentTranscript
    case processActivity
}

struct AgentActivity: Identifiable, Equatable, Sendable {
    let id: String
    let runtime: AgentRuntime
    let projectName: String?
    let processID: Int32?
    let evidence: AgentActivityEvidence
    let lastActivityAt: Date?

    var displayName: String {
        if let projectName, !projectName.isEmpty {
            return "\(runtime.displayName) · \(projectName)"
        }
        return runtime.displayName
    }
}

struct AgentActivitySnapshot: Equatable, Sendable {
    let activities: [AgentActivity]
    let scannedAt: Date
    let processScanSucceeded: Bool
    let scanWasConclusive: Bool

    init(
        activities: [AgentActivity],
        scannedAt: Date,
        processScanSucceeded: Bool,
        scanWasConclusive: Bool? = nil
    ) {
        self.activities = activities
        self.scannedAt = scannedAt
        self.processScanSucceeded = processScanSucceeded
        self.scanWasConclusive = scanWasConclusive ?? processScanSucceeded
    }

    static func empty(at date: Date = Date()) -> AgentActivitySnapshot {
        AgentActivitySnapshot(
            activities: [],
            scannedAt: date,
            processScanSucceeded: true
        )
    }
}

protocol AgentActivityDetecting: Sendable {
    func scan(now: Date) async -> AgentActivitySnapshot
}

struct AgentProcessRecord: Equatable, Sendable {
    let pid: Int32
    let parentPID: Int32
    let cpuPercent: Double
    let startedAt: Date?
    let command: String

    var executableBasename: String {
        let lowercased = command.lowercased()
        let token = command.split(whereSeparator: \Character.isWhitespace).first.map(String.init) ?? ""
        let basename = URL(fileURLWithPath: token).lastPathComponent.lowercased()

        if basename == "disclaimer" {
            return basename
        }

        if lowercased.contains("application support/claude/claude-code/claude") {
            return "claude"
        }

        if lowercased.hasPrefix("/applications/chatgpt.app/contents/resources/codex ")
            || lowercased.hasPrefix("/applications/codex.app/contents/resources/codex ") {
            return "codex"
        }

        return basename
    }

    var arguments: [String] {
        command.split(whereSeparator: \Character.isWhitespace).dropFirst().map(String.init)
    }
}

enum AgentProcessParser {
    static func parse(_ output: String) -> [AgentProcessRecord] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"

        return output.split(whereSeparator: \Character.isNewline).compactMap { rawLine in
            let fields = rawLine.split(
                maxSplits: 8,
                omittingEmptySubsequences: true,
                whereSeparator: \Character.isWhitespace
            )

            guard fields.count == 9,
                  let pid = Int32(fields[0]),
                  let parentPID = Int32(fields[1]),
                  let cpuPercent = Double(fields[2]) else {
                return nil
            }

            let dateText = fields[3...7].joined(separator: " ")
            return AgentProcessRecord(
                pid: pid,
                parentPID: parentPID,
                cpuPercent: cpuPercent,
                startedAt: formatter.date(from: dateText),
                command: String(fields[8]).trimmingCharacters(in: .whitespaces)
            )
        }
    }

    static func runtime(for record: AgentProcessRecord) -> AgentRuntime? {
        let basename = record.executableBasename
        let lowercasedCommand = record.command.lowercased()
        let arguments = record.arguments.map { $0.lowercased() }

        if arguments.contains("--help") || arguments.contains("--version") {
            return nil
        }

        if lowercasedCommand.contains(".app/") {
            let knownEmbeddedAgent = lowercasedCommand.contains(
                "application support/claude/claude-code/claude"
            ) || basename == "cursor-agent"
                || lowercasedCommand.hasPrefix(
                    "/applications/chatgpt.app/contents/resources/codex "
                )
                || lowercasedCommand.hasPrefix(
                    "/applications/codex.app/contents/resources/codex "
                )

            guard knownEmbeddedAgent else { return nil }
        }

        switch basename {
        case "codex":
            return .codex
        case "claude":
            guard !lowercasedCommand.contains("claude-code-acp") else { return nil }
            return .claude
        case "disclaimer":
            guard lowercasedCommand.contains("claude") else { return nil }
            return .claude
        case "cursor-agent":
            return .cursor
        case "opencode":
            guard !arguments.contains("serve") && !arguments.contains("web") else { return nil }
            return .openCode
        case "copilot", "github-copilot-cli":
            return .copilot
        case "gemini", "gemini-cli":
            return .gemini
        case "antigravity", "antigravity-cli", "agy":
            return .antigravity
        case "aider", "aider-chat":
            return .aider
        case "goose":
            return .goose
        case "amp":
            return .amp
        case "kiro-cli":
            return .kiro
        case "droid", "factory-cli":
            return .factory
        case "codebuff":
            return .codebuff
        case "qoder", "qoder-cli":
            return .qoder
        case "cline", "cline-cli":
            return .cline
        case "kilo", "kilo-cli", "kilocode":
            return .kilo
        case "crush":
            return .crush
        case "deepseek-code", "deepseek-cli":
            return .deepSeek
        case "minimax-code", "minimax-cli":
            return .minimax
        case "groq-build", "groq-cli":
            return .groq
        default:
            break
        }

        guard basename == "node" || basename == "bun" || basename == "deno" else {
            return nil
        }

        if lowercasedCommand.contains("/node_modules/@anthropic-ai/claude-code/") {
            return .claude
        }
        if lowercasedCommand.contains("/node_modules/@openai/codex/") {
            return .codex
        }
        if lowercasedCommand.contains("/node_modules/opencode-ai/") {
            return .openCode
        }
        if lowercasedCommand.contains("/node_modules/@google/gemini-cli/") {
            return .gemini
        }
        if lowercasedCommand.contains("/node_modules/codebuff/") {
            return .codebuff
        }

        return nil
    }

    static func isCodexAppServer(_ record: AgentProcessRecord) -> Bool {
        guard runtime(for: record) == .codex else { return false }
        return record.arguments.map { $0.lowercased() }.contains("app-server")
    }

    static func isCursorApplication(_ record: AgentProcessRecord) -> Bool {
        let executable = record.command
            .split(whereSeparator: \Character.isWhitespace)
            .first?
            .lowercased()
        return executable == "/applications/cursor.app/contents/macos/cursor"
    }

    static func isAntigravityWorker(_ record: AgentProcessRecord) -> Bool {
        let command = record.command.lowercased()
        return command.contains("antigravity")
            && command.contains("language_server")
            && record.cpuPercent >= 1.0
    }
}

struct AgentLsofSnapshot: Equatable, Sendable {
    struct CodexRollout: Equatable, Sendable {
        let pid: Int32
        let path: String
    }

    var currentWorkingDirectories: [Int32: String] = [:]
    var writableCodexRollouts: [CodexRollout] = []
}

enum AgentLsofParser {
    static func parse(
        _ output: String,
        codexProcessIDs: Set<Int32> = [],
        codexSessionsRoots: [URL] = []
    ) -> AgentLsofSnapshot {
        var snapshot = AgentLsofSnapshot()
        var currentPID: Int32?
        var currentCommand: String?
        var currentFileDescriptor: String?
        var currentAccess: String?

        for line in output.split(whereSeparator: \Character.isNewline).map(String.init) {
            guard let prefix = line.first else { continue }
            let value = String(line.dropFirst())

            switch prefix {
            case "p":
                currentPID = Int32(value)
                currentCommand = nil
                currentFileDescriptor = nil
                currentAccess = nil
            case "c":
                currentCommand = value
            case "f":
                currentFileDescriptor = value
                currentAccess = nil
            case "a":
                currentAccess = value
            case "n":
                guard let currentPID else { continue }

                if currentFileDescriptor == "cwd" {
                    snapshot.currentWorkingDirectories[currentPID] = value
                }

                let isCodexProcess = codexProcessIDs.isEmpty
                    ? currentCommand?.lowercased() == "codex"
                    : codexProcessIDs.contains(currentPID)

                if isCodexProcess,
                   currentAccess == "w" || currentAccess == "u",
                   CodexLifecycleReader.isRolloutPath(
                       value,
                       under: codexSessionsRoots
                   ) {
                    snapshot.writableCodexRollouts.append(
                        AgentLsofSnapshot.CodexRollout(pid: currentPID, path: value)
                    )
                }
            default:
                continue
            }
        }

        return snapshot
    }
}

enum ThreadLifecycle: Equatable, Sendable {
    case active
    case terminal
    case unknown
}

enum CodexLifecycleReader {
    private struct Envelope: Decodable {
        let type: String?
        let payload: Payload?

        struct Payload: Decodable {
            let type: String?
        }
    }

    private struct MetadataEnvelope: Decodable {
        let type: String?
        let payload: Payload?

        struct Payload: Decodable {
            let id: String?
            let sessionID: String?
            let cwd: String?

            enum CodingKeys: String, CodingKey {
                case id
                case sessionID = "session_id"
                case cwd
            }
        }
    }

    struct Metadata: Equatable, Sendable {
        let id: String?
        let projectName: String?
    }

    static func isRolloutPath(
        _ path: String,
        under sessionsRoots: [URL] = []
    ) -> Bool {
        let url = URL(fileURLWithPath: path)
        let hasValidName = url.lastPathComponent.hasPrefix("rollout-")
            && url.pathExtension == "jsonl"

        guard hasValidName else { return false }
        guard !sessionsRoots.isEmpty else { return path.contains("/sessions/") }

        let standardizedPath = url.standardizedFileURL.path
        return sessionsRoots.contains { root in
            standardizedPath.hasPrefix(root.standardizedFileURL.path + "/")
        }
    }

    static func latestLifecycle(in text: String) -> ThreadLifecycle {
        for line in text.split(whereSeparator: \Character.isNewline).reversed() {
            guard line.contains("task_started")
                    || line.contains("turn_started")
                    || line.contains("task_complete")
                    || line.contains("turn_complete")
                    || line.contains("turn_aborted"),
                  let data = String(line).data(using: .utf8),
                  let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
                  envelope.type == "event_msg",
                  let eventType = envelope.payload?.type else {
                continue
            }

            switch eventType {
            case "task_started", "turn_started":
                return .active
            case "task_complete", "turn_complete", "turn_aborted":
                return .terminal
            default:
                continue
            }
        }

        return .unknown
    }

    static func latestLifecycle(at url: URL, maximumBytes: Int = 1_048_576) -> ThreadLifecycle {
        guard let text = tailText(at: url, maximumBytes: maximumBytes) else { return .unknown }
        return latestLifecycle(in: text)
    }

    static func metadata(at url: URL) -> Metadata {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return Metadata(id: nil, projectName: nil)
        }
        defer { try? handle.close() }

        guard let data = try? handle.read(upToCount: 65_536),
              let newline = data.firstIndex(of: 0x0A),
              let envelope = try? JSONDecoder().decode(
                  MetadataEnvelope.self,
                  from: data.prefix(upTo: newline)
              ),
              envelope.type == "session_meta" else {
            return Metadata(id: nil, projectName: nil)
        }

        let cwd = envelope.payload?.cwd
        return Metadata(
            id: envelope.payload?.id ?? envelope.payload?.sessionID,
            projectName: cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
        )
    }

    private static func tailText(at url: URL, maximumBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let endOffset = try? handle.seekToEnd() else { return nil }
        let startOffset = endOffset > UInt64(maximumBytes)
            ? endOffset - UInt64(maximumBytes)
            : 0
        try? handle.seek(toOffset: startOffset)

        guard let data = try? handle.readToEnd() else { return nil }
        var text = String(decoding: data, as: UTF8.self)

        if startOffset > 0, let firstNewline = text.firstIndex(of: "\n") {
            text.removeSubrange(text.startIndex...firstNewline)
        }

        return text
    }
}

enum CursorLifecycleReader {
    private struct Envelope: Decodable {
        let type: String?
        let role: String?
    }

    private struct ToolEnvelope: Decodable {
        let message: Message?

        struct Message: Decodable {
            let content: [Content]?
        }

        struct Content: Decodable {
            let type: String?
            let name: String?
            let input: Input?
        }

        struct Input: Decodable {
            let shellID: String?

            enum CodingKeys: String, CodingKey {
                case shellID = "shell_id"
            }
        }
    }

    struct Inspection: Equatable, Sendable {
        let lifecycle: ThreadLifecycle
        let awaitedShellIDs: Set<String>
    }

    static func inspection(in text: String) -> Inspection {
        var lifecycle: ThreadLifecycle = .unknown
        var awaitedShellIDs = Set<String>()

        for line in text.split(whereSeparator: \Character.isNewline) {
            guard let data = String(line).data(using: .utf8) else { continue }

            if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
                if envelope.type == "turn_ended" {
                    lifecycle = .terminal
                } else if envelope.role == "user" {
                    if lifecycle == .terminal {
                        awaitedShellIDs.removeAll()
                    }
                    lifecycle = .active
                } else if envelope.role == "assistant" {
                    if lifecycle == .terminal {
                        awaitedShellIDs.removeAll()
                    }
                    lifecycle = .active
                }
            }

            guard let toolEnvelope = try? JSONDecoder().decode(
                      ToolEnvelope.self,
                      from: data
                  ) else {
                continue
            }
            for content in toolEnvelope.message?.content ?? []
                where content.type == "tool_use" && content.name == "AwaitShell" {
                if let shellID = content.input?.shellID, !shellID.isEmpty {
                    awaitedShellIDs.insert(shellID)
                }
            }
        }

        return Inspection(
            lifecycle: lifecycle,
            awaitedShellIDs: awaitedShellIDs
        )
    }

    static func latestLifecycle(in text: String) -> ThreadLifecycle {
        inspection(in: text).lifecycle
    }

    static func inspection(at url: URL, maximumBytes: Int = 524_288) -> Inspection {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return Inspection(lifecycle: .unknown, awaitedShellIDs: [])
        }
        defer { try? handle.close() }

        guard let endOffset = try? handle.seekToEnd() else {
            return Inspection(lifecycle: .unknown, awaitedShellIDs: [])
        }
        let startOffset = endOffset > UInt64(maximumBytes)
            ? endOffset - UInt64(maximumBytes)
            : 0
        try? handle.seek(toOffset: startOffset)
        guard let data = try? handle.readToEnd() else {
            return Inspection(lifecycle: .unknown, awaitedShellIDs: [])
        }

        var text = String(decoding: data, as: UTF8.self)
        if startOffset > 0, let firstNewline = text.firstIndex(of: "\n") {
            text.removeSubrange(text.startIndex...firstNewline)
        }
        return inspection(in: text)
    }

    static func latestLifecycle(at url: URL, maximumBytes: Int = 524_288) -> ThreadLifecycle {
        inspection(at: url, maximumBytes: maximumBytes).lifecycle
    }
}

enum CursorPowerAssertionParser {
    static func activeProcessIDs(
        in output: String,
        cursorProcessIDs: Set<Int32>
    ) -> Set<Int32> {
        var activeProcessIDs = Set<Int32>()

        for line in output.split(whereSeparator: \Character.isNewline).map(String.init) {
            guard line.contains("NoIdleSleepAssertion"),
                  line.contains("named: \"Electron\""),
                  let pidMarker = line.range(of: "pid ") else {
                continue
            }

            let suffix = line[pidMarker.upperBound...]
            let digits = suffix.prefix(while: \Character.isNumber)
            guard let processID = Int32(digits),
                  cursorProcessIDs.contains(processID) else {
                continue
            }

            activeProcessIDs.insert(processID)
        }

        return activeProcessIDs
    }
}

enum CursorTerminalManifestReader {
    struct Metadata: Equatable, Sendable {
        let processID: Int32
        let workingDirectory: String
        let startedAt: Date
        let runningForMilliseconds: UInt64
        let hasCompletionFooter: Bool
    }

    static func read(
        at url: URL,
        maximumHeaderBytes: Int = 32_768,
        maximumFooterBytes: Int = 8_192
    ) -> Metadata? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let headerData = try? handle.read(upToCount: maximumHeaderBytes) else {
            return nil
        }
        let headerText = String(decoding: headerData, as: UTF8.self)
        let header = parseHeader(headerText)

        guard let processID = header.processID,
              let workingDirectory = header.workingDirectory,
              let startedAt = header.startedAt,
              let runningForMilliseconds = header.runningForMilliseconds,
              header.hasCommand else {
            return nil
        }

        let footerText: String
        if let endOffset = try? handle.seekToEnd() {
            let startOffset = endOffset > UInt64(maximumFooterBytes)
                ? endOffset - UInt64(maximumFooterBytes)
                : 0
            try? handle.seek(toOffset: startOffset)
            let footerData = (try? handle.readToEnd()) ?? Data()
            footerText = String(decoding: footerData, as: UTF8.self)
        } else {
            footerText = ""
        }

        return Metadata(
            processID: processID,
            workingDirectory: workingDirectory,
            startedAt: startedAt,
            runningForMilliseconds: runningForMilliseconds,
            hasCompletionFooter: hasCompletionFooter(in: footerText)
        )
    }

    private static func parseHeader(_ text: String) -> (
        processID: Int32?,
        workingDirectory: String?,
        startedAt: Date?,
        runningForMilliseconds: UInt64?,
        hasCommand: Bool
    ) {
        let lines = text.split(whereSeparator: \Character.isNewline).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return (nil, nil, nil, nil, false)
        }

        var processID: Int32?
        var workingDirectory: String?
        var startedAt: Date?
        var runningForMilliseconds: UInt64?
        var hasCommand = false

        for line in lines.dropFirst() {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine == "---" { break }

            if let value = value(after: "pid:", in: trimmedLine) {
                processID = Int32(value)
            } else if let value = value(after: "cwd:", in: trimmedLine) {
                workingDirectory = decodedString(value)
            } else if value(after: "command:", in: trimmedLine) != nil {
                hasCommand = true
            } else if let value = value(after: "started_at:", in: trimmedLine) {
                startedAt = iso8601Date(value)
            } else if let value = value(after: "running_for_ms:", in: trimmedLine) {
                runningForMilliseconds = UInt64(value)
            }
        }

        return (
            processID,
            workingDirectory,
            startedAt,
            runningForMilliseconds,
            hasCommand
        )
    }

    private static func value(after prefix: String, in line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespaces)
    }

    private static func decodedString(_ value: String) -> String {
        guard value.first == "\"",
              let data = value.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(String.self, from: data) else {
            return value
        }
        return decoded
    }

    private static func iso8601Date(_ value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func hasCompletionFooter(in text: String) -> Bool {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        return normalized.contains("\nexit_code:")
            && normalized.contains("\nended_at:")
    }
}

enum ClaudeSessionStatus: String, Equatable, Sendable {
    case busy
    case shell
    case idle
    case waiting
    case unknown

    var isActiveWork: Bool {
        self == .busy || self == .shell
    }

    var isSettled: Bool {
        self == .idle || self == .waiting
    }
}

enum ClaudeSessionKind: String, Equatable, Sendable {
    case interactive
    case background = "bg"
    case daemon
    case daemonWorker = "daemon-worker"
    case unknown

    var canOwnWork: Bool {
        switch self {
        case .interactive, .background, .daemonWorker:
            return true
        case .daemon, .unknown:
            return false
        }
    }
}

enum ClaudeSessionReader {
    private struct Envelope: Decodable {
        let pid: Int32?
        let sessionID: String?
        let cwd: String?
        let processStart: String?
        let kind: String?
        let status: String?
        let statusUpdatedAt: Double?

        enum CodingKeys: String, CodingKey {
            case pid
            case sessionID = "sessionId"
            case cwd
            case processStart = "procStart"
            case kind
            case status
            case statusUpdatedAt
        }
    }

    struct Metadata: Equatable, Sendable {
        let processID: Int32
        let sessionID: String?
        let workingDirectory: String?
        let processStartedAt: Date
        let kind: ClaudeSessionKind
        let status: ClaudeSessionStatus
        let statusUpdatedAt: Date?
    }

    static func read(at url: URL, maximumBytes: Int = 65_536) -> Metadata? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let data = try? handle.read(upToCount: maximumBytes),
              !data.isEmpty,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let processID = envelope.pid,
              let processStartedAt = processStartDate(envelope.processStart) else {
            return nil
        }

        return Metadata(
            processID: processID,
            sessionID: envelope.sessionID,
            workingDirectory: envelope.cwd,
            processStartedAt: processStartedAt,
            kind: envelope.kind.flatMap(ClaudeSessionKind.init(rawValue:)) ?? .unknown,
            status: envelope.status.flatMap(ClaudeSessionStatus.init(rawValue:)) ?? .unknown,
            statusUpdatedAt: envelope.statusUpdatedAt.map {
                Date(timeIntervalSince1970: $0 / 1_000)
            }
        )
    }

    private static func processStartDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.date(from: value)
    }
}

enum ClaudeLifecycleReader {
    private struct BaseEnvelope: Decodable {
        let type: String?
        let subtype: String?
        let isMeta: Bool?
        let isSidechain: Bool?

        enum CodingKeys: String, CodingKey {
            case type
            case subtype
            case isMeta = "is_meta"
            case isSidechain = "is_sidechain"
        }
    }

    private struct AssistantEnvelope: Decodable {
        let message: Message?

        struct Message: Decodable {
            let role: String?
            let stopReason: String?
            let content: [Content]?

            enum CodingKeys: String, CodingKey {
                case role
                case stopReason = "stop_reason"
                case content
            }
        }

        struct Content: Decodable {
            let type: String?
        }
    }

    static func latestLifecycle(in text: String) -> ThreadLifecycle {
        for line in text.split(whereSeparator: \Character.isNewline).reversed() {
            guard let data = String(line).data(using: .utf8),
                  let envelope = try? JSONDecoder().decode(BaseEnvelope.self, from: data) else {
                continue
            }

            if envelope.type == "last-prompt"
                || (envelope.type == "system"
                    && (envelope.subtype == "local_command"
                        || envelope.subtype == "turn_duration")) {
                return .terminal
            }

            if envelope.type == "user" {
                if envelope.isMeta == true || envelope.isSidechain == true {
                    continue
                }
                return .active
            }

            guard envelope.type == "assistant",
                  let assistant = try? JSONDecoder().decode(
                      AssistantEnvelope.self,
                      from: data
                  ),
                  assistant.message?.role == "assistant" else {
                continue
            }

            switch assistant.message?.stopReason {
            case "end_turn", "stop_sequence":
                return .terminal
            case "tool_use":
                return .active
            case .none:
                if assistant.message?.content?.contains(where: { $0.type == "tool_use" }) == true {
                    return .active
                }
                return .unknown
            default:
                if assistant.message?.content?.contains(where: { $0.type == "tool_use" }) == true {
                    return .active
                }
                return .unknown
            }
        }

        return .unknown
    }

    static func latestLifecycle(at url: URL, maximumBytes: Int = 524_288) -> ThreadLifecycle {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? handle.close() }

        guard let endOffset = try? handle.seekToEnd() else { return .unknown }
        let startOffset = endOffset > UInt64(maximumBytes)
            ? endOffset - UInt64(maximumBytes)
            : 0
        try? handle.seek(toOffset: startOffset)
        guard let data = try? handle.readToEnd() else { return .unknown }

        var text = String(decoding: data, as: UTF8.self)
        if startOffset > 0, let firstNewline = text.firstIndex(of: "\n") {
            text.removeSubrange(text.startIndex...firstNewline)
        }
        return latestLifecycle(in: text)
    }
}

struct LocalAgentActivityDetector: AgentActivityDetecting {
    private struct LsofInspection: Sendable {
        let snapshot: AgentLsofSnapshot
        let succeeded: Bool
    }

    private struct CodexInspection: Sendable {
        let activities: [AgentActivity]
        let lifecycleWasConclusive: Bool
    }

    private struct ClaudeInspection: Sendable {
        let activity: AgentActivity?
        let signalsWereConclusive: Bool
    }

    private struct CursorAssertionInspection: Sendable {
        let activeProcessIDs: Set<Int32>
        let succeeded: Bool
    }

    private struct CursorInspection: Sendable {
        let activities: [AgentActivity]
        let signalsWereConclusive: Bool
    }

    private struct CursorTranscriptInspection: Sendable {
        let records: [CursorTranscriptRecord]
        let succeeded: Bool
    }

    private struct CursorTranscriptRecord: Sendable {
        let id: String
        let projectName: String?
        let lifecycle: ThreadLifecycle
        let modifiedAt: Date
        let awaitedShellIDs: Set<String>
    }

    private struct CursorTerminalCandidate: Sendable {
        let shellID: String
        let projectName: String?
        let processID: Int32
        let modifiedAt: Date?
    }

    private struct CursorTerminalInspection: Sendable {
        let candidates: [CursorTerminalCandidate]
        let succeeded: Bool
    }

    private let commandRunner: any CommandRunning
    private let homeDirectory: URL
    private let environment: [String: String]

    init(
        commandRunner: any CommandRunning = ProcessCommandRunner(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.commandRunner = commandRunner
        self.homeDirectory = homeDirectory
        self.environment = environment
    }

    func scan(now: Date) async -> AgentActivitySnapshot {
        let processResult: CommandResult

        do {
            processResult = try await commandRunner.run(
                executable: URL(fileURLWithPath: "/bin/ps"),
                arguments: ["-axo", "pid=,ppid=,%cpu=,lstart=,command="]
            )
        } catch {
            return AgentActivitySnapshot(
                activities: [],
                scannedAt: now,
                processScanSucceeded: false,
                scanWasConclusive: false
            )
        }

        guard processResult.terminationStatus == 0 else {
            return AgentActivitySnapshot(
                activities: [],
                scannedAt: now,
                processScanSucceeded: false,
                scanWasConclusive: false
            )
        }

        let processes = AgentProcessParser.parse(processResult.standardOutput)
        guard !processes.isEmpty else {
            return AgentActivitySnapshot(
                activities: [],
                scannedAt: now,
                processScanSucceeded: false,
                scanWasConclusive: false
            )
        }
        let candidateProcesses = processCandidates(from: processes)
        let codexProcesses = processes.filter { AgentProcessParser.runtime(for: $0) == .codex }
        let cursorProcesses = processes.filter(AgentProcessParser.isCursorApplication)
        let pidsToInspect = Set(candidateProcesses.map(\.pid) + codexProcesses.map(\.pid))
        let lsofInspection = await lsofSnapshot(
            for: Array(pidsToInspect),
            codexProcessIDs: Set(codexProcesses.map(\.pid)),
            codexSessionsRoots: [codexSessionsRoot]
        )
        let cursorAssertionInspection = await cursorPowerAssertions(
            cursorProcessIDs: Set(cursorProcesses.map(\.pid))
        )
        let lsofSnapshot = lsofInspection.snapshot

        let codexInspection = codexActivities(
            processes: codexProcesses,
            lsofSnapshot: lsofSnapshot,
            now: now
        )
        var activities = codexInspection.activities
        var claudeSignalsWereConclusive = true

        for process in candidateProcesses {
            guard let runtime = AgentProcessParser.runtime(for: process) else { continue }
            if runtime == .codex {
                continue
            }

            let cwd = lsofSnapshot.currentWorkingDirectories[process.pid]
            if runtime == .claude {
                let inspection = inspectClaudeActivity(
                    process: process,
                    cwd: cwd,
                    now: now
                )
                claudeSignalsWereConclusive = claudeSignalsWereConclusive
                    && inspection.signalsWereConclusive
                if let activity = inspection.activity {
                    activities.append(activity)
                }
                continue
            }

            activities.append(
                AgentActivity(
                    id: "\(runtime.rawValue):pid:\(process.pid)",
                    runtime: runtime,
                    projectName: cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
                    processID: process.pid,
                    evidence: .liveProcess,
                    lastActivityAt: nil
                )
            )
        }

        let cursorInspection = inspectCursorActivity(
            processes: processes,
            cursorProcesses: cursorProcesses,
            assertionInspection: cursorAssertionInspection,
            now: now
        )
        activities.append(contentsOf: cursorInspection.activities)

        if let worker = processes.first(where: AgentProcessParser.isAntigravityWorker),
           !activities.contains(where: { $0.runtime == .antigravity }) {
            activities.append(
                AgentActivity(
                    id: "antigravity:worker:\(worker.pid)",
                    runtime: .antigravity,
                    projectName: nil,
                    processID: worker.pid,
                    evidence: .processActivity,
                    lastActivityAt: now
                )
            )
        }

        var seen = Set<String>()
        let deduplicated = activities
            .sorted { lhs, rhs in
                if lhs.runtime != rhs.runtime {
                    return lhs.runtime.displayName < rhs.runtime.displayName
                }
                return (lhs.lastActivityAt ?? .distantPast) > (rhs.lastActivityAt ?? .distantPast)
            }
            .filter { seen.insert($0.id).inserted }

        return AgentActivitySnapshot(
            activities: deduplicated,
            scannedAt: now,
            processScanSucceeded: true,
            scanWasConclusive: (lsofInspection.succeeded || codexProcesses.isEmpty)
                && codexInspection.lifecycleWasConclusive
                && claudeSignalsWereConclusive
                && cursorInspection.signalsWereConclusive
        )
    }

    private func processCandidates(from processes: [AgentProcessRecord]) -> [AgentProcessRecord] {
        let candidates = processes.filter { process in
            guard let runtime = AgentProcessParser.runtime(for: process) else { return false }
            if runtime == .codex, AgentProcessParser.isCodexAppServer(process) {
                return false
            }
            return true
        }

        return candidates.filter { process in
            guard process.executableBasename == "disclaimer" else { return true }
            return !candidates.contains { child in
                child.parentPID == process.pid && AgentProcessParser.runtime(for: child) == .claude
            }
        }
    }

    private func lsofSnapshot(
        for pids: [Int32],
        codexProcessIDs: Set<Int32>,
        codexSessionsRoots: [URL]
    ) async -> LsofInspection {
        guard !pids.isEmpty else {
            return LsofInspection(snapshot: AgentLsofSnapshot(), succeeded: true)
        }
        let lsofPath = ["/usr/sbin/lsof", "/usr/bin/lsof"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        guard let lsofPath else {
            return LsofInspection(snapshot: AgentLsofSnapshot(), succeeded: false)
        }

        let joinedPIDs = pids.map(String.init).joined(separator: ",")
        guard let result = try? await commandRunner.run(
            executable: URL(fileURLWithPath: lsofPath),
            arguments: ["-nP", "-a", "-p", joinedPIDs, "-Fpcfna"]
        ) else {
            return LsofInspection(snapshot: AgentLsofSnapshot(), succeeded: false)
        }

        let snapshot = AgentLsofParser.parse(
            result.standardOutput,
            codexProcessIDs: codexProcessIDs,
            codexSessionsRoots: codexSessionsRoots
        )
        return LsofInspection(
            snapshot: snapshot,
            succeeded: result.terminationStatus == 0 || !result.standardOutput.isEmpty
        )
    }

    private func codexActivities(
        processes: [AgentProcessRecord],
        lsofSnapshot: AgentLsofSnapshot,
        now: Date
    ) -> CodexInspection {
        guard !processes.isEmpty else {
            return CodexInspection(activities: [], lifecycleWasConclusive: true)
        }

        var activities: [AgentActivity] = []
        var inspectedPaths = Set<String>()
        var lifecycleWasConclusive = true

        for rollout in lsofSnapshot.writableCodexRollouts
            where inspectedPaths.insert(rollout.path).inserted {
            let url = URL(fileURLWithPath: rollout.path)
            let lifecycle = CodexLifecycleReader.latestLifecycle(at: url)
            let modifiedAt = try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            let recentlyModified = modifiedAt.map {
                Self.isRecent($0, relativeTo: now, within: 10 * 60)
            } ?? false

            // A writable rollout that is still changing is positive activity
            // evidence even when its start marker has fallen outside the
            // bounded JSONL tail. Keep the scan degraded only when that open
            // rollout is also stale and we cannot safely decide either way.
            if lifecycle == .unknown && !recentlyModified {
                lifecycleWasConclusive = false
            }

            guard lifecycle == .active || (lifecycle == .unknown && recentlyModified) else {
                continue
            }

            let metadata = CodexLifecycleReader.metadata(at: url)
            activities.append(
                AgentActivity(
                    id: "codex:\(metadata.id ?? url.deletingPathExtension().lastPathComponent)",
                    runtime: .codex,
                    projectName: metadata.projectName,
                    processID: rollout.pid,
                    evidence: lifecycle == .active ? .lifecycle : .recentTranscript,
                    lastActivityAt: modifiedAt
                )
            )
        }

        if lsofSnapshot.writableCodexRollouts.isEmpty {
            activities.append(contentsOf: recentCodexFallbackActivities(now: now))
        }

        return CodexInspection(
            activities: activities,
            lifecycleWasConclusive: lifecycleWasConclusive
        )
    }

    private func recentCodexFallbackActivities(now: Date) -> [AgentActivity] {
        let sessionsRoot = codexSessionsRoot
        let calendar = Calendar(identifier: .gregorian)
        let dates = [now, calendar.date(byAdding: .day, value: -1, to: now)].compactMap(\.self)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd"

        return dates.flatMap { date -> [AgentActivity] in
            let directory = sessionsRoot.appendingPathComponent(
                formatter.string(from: date),
                isDirectory: true
            )
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }

            return files.compactMap { url in
                guard CodexLifecycleReader.isRolloutPath(
                          url.path,
                          under: [sessionsRoot]
                      ),
                      let modifiedAt = try? url.resourceValues(
                          forKeys: [.contentModificationDateKey]
                      ).contentModificationDate,
                      Self.isRecent(modifiedAt, relativeTo: now, within: 120),
                      CodexLifecycleReader.latestLifecycle(at: url) == .active else {
                    return nil
                }

                let metadata = CodexLifecycleReader.metadata(at: url)
                return AgentActivity(
                    id: "codex:\(metadata.id ?? url.deletingPathExtension().lastPathComponent)",
                    runtime: .codex,
                    projectName: metadata.projectName,
                    processID: nil,
                    evidence: .recentTranscript,
                    lastActivityAt: modifiedAt
                )
            }
        }
    }

    private func cursorPowerAssertions(
        cursorProcessIDs: Set<Int32>
    ) async -> CursorAssertionInspection {
        guard !cursorProcessIDs.isEmpty else {
            return CursorAssertionInspection(activeProcessIDs: [], succeeded: true)
        }

        guard let result = try? await commandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/pmset"),
            arguments: ["-g", "assertions"]
        ), result.terminationStatus == 0 else {
            return CursorAssertionInspection(activeProcessIDs: [], succeeded: false)
        }

        return CursorAssertionInspection(
            activeProcessIDs: CursorPowerAssertionParser.activeProcessIDs(
                in: result.standardOutput,
                cursorProcessIDs: cursorProcessIDs
            ),
            succeeded: true
        )
    }

    private func inspectCursorActivity(
        processes: [AgentProcessRecord],
        cursorProcesses: [AgentProcessRecord],
        assertionInspection: CursorAssertionInspection,
        now: Date
    ) -> CursorInspection {
        guard !cursorProcesses.isEmpty else {
            return CursorInspection(activities: [], signalsWereConclusive: true)
        }

        let latestStart = cursorProcesses.compactMap(\.startedAt).max()
        let transcriptInspection = cursorTranscriptInspection(
            now: now,
            applicationStartedAt: latestStart
        )
        let terminalInspection = cursorTerminalActivities(
            processes: processes,
            cursorProcessIDs: Set(cursorProcesses.map(\.pid))
        )

        var terminalsByShellID: [String: CursorTerminalCandidate] = [:]
        for candidate in terminalInspection.candidates {
            let previous = terminalsByShellID[candidate.shellID]
            if (previous?.modifiedAt ?? .distantPast)
                < (candidate.modifiedAt ?? .distantPast) {
                terminalsByShellID[candidate.shellID] = candidate
            }
        }

        let assertionIsActive = !assertionInspection.activeProcessIDs.isEmpty
        var activities: [AgentActivity] = []
        var needsUnavailableTerminalEvidence = false

        // A transcript owns only the terminal manifests it references through
        // AwaitShell.shell_id. turn_ended records never reach this loop, so a
        // detached shell cannot keep its completed agent thread alive. The
        // app-level assertion corroborates an active transcript but never
        // creates an activity on its own.
        for record in transcriptInspection.records where record.lifecycle == .active {
            let linkedTerminals = record.awaitedShellIDs.compactMap {
                terminalsByShellID[$0]
            }
            let isFresh = Self.isRecent(
                record.modifiedAt,
                relativeTo: now,
                within: 120
            )
            let hasLiveLinkedTerminal = !linkedTerminals.isEmpty

            if assertionInspection.succeeded {
                guard assertionIsActive else { continue }
            } else {
                guard isFresh || hasLiveLinkedTerminal else {
                    if !record.awaitedShellIDs.isEmpty && !terminalInspection.succeeded {
                        needsUnavailableTerminalEvidence = true
                    }
                    continue
                }
            }

            let linkedTerminal = linkedTerminals.max {
                ($0.modifiedAt ?? .distantPast) < ($1.modifiedAt ?? .distantPast)
            }
            activities.append(
                AgentActivity(
                    id: "cursor:\(record.id)",
                    runtime: .cursor,
                    projectName: record.projectName ?? linkedTerminal?.projectName,
                    processID: linkedTerminal?.processID,
                    evidence: isFresh ? .lifecycle : .processActivity,
                    lastActivityAt: max(
                        record.modifiedAt,
                        linkedTerminal?.modifiedAt ?? .distantPast
                    )
                )
            )
        }

        let hasRecentUnknownLifecycle = transcriptInspection.records.contains { record in
            record.lifecycle == .unknown
                && Self.isRecent(record.modifiedAt, relativeTo: now, within: 120)
        }
        let aggregateIdleWasConclusive = assertionInspection.succeeded
            && !assertionIsActive

        return CursorInspection(
            activities: activities,
            signalsWereConclusive: aggregateIdleWasConclusive
                || (transcriptInspection.succeeded
                    && !needsUnavailableTerminalEvidence
                    && !hasRecentUnknownLifecycle)
        )
    }

    private func cursorTerminalActivities(
        processes: [AgentProcessRecord],
        cursorProcessIDs: Set<Int32>
    ) -> CursorTerminalInspection {
        let root = homeDirectory
            .appendingPathComponent(".cursor", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else {
            return CursorTerminalInspection(candidates: [], succeeded: true)
        }
        guard let projectDirectories = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return CursorTerminalInspection(candidates: [], succeeded: false)
        }

        let processesByID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        var candidates: [CursorTerminalCandidate] = []
        var succeeded = true

        for projectDirectory in projectDirectories {
            guard (try? projectDirectory.resourceValues(
                forKeys: [.isDirectoryKey]
            ).isDirectory) == true else {
                continue
            }
            let terminalDirectory = projectDirectory.appendingPathComponent(
                "terminals",
                isDirectory: true
            )
            guard FileManager.default.fileExists(atPath: terminalDirectory.path) else {
                continue
            }
            guard let manifests = try? FileManager.default.contentsOfDirectory(
                at: terminalDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                succeeded = false
                continue
            }

            for url in manifests {
                guard url.pathExtension == "txt",
                  let values = try? url.resourceValues(
                      forKeys: [.contentModificationDateKey, .isRegularFileKey]
                  ),
                  values.isRegularFile == true,
                  let metadata = CursorTerminalManifestReader.read(at: url),
                  !metadata.hasCompletionFooter,
                  let process = processesByID[metadata.processID],
                  let processStartedAt = process.startedAt,
                  abs(processStartedAt.timeIntervalSince(metadata.startedAt)) <= 5,
                  Self.hasCursorAncestor(
                      processID: metadata.processID,
                      processesByID: processesByID,
                      cursorProcessIDs: cursorProcessIDs
                  ) else {
                    continue
                }

                candidates.append(
                    CursorTerminalCandidate(
                        shellID: url.deletingPathExtension().lastPathComponent,
                        projectName: URL(
                            fileURLWithPath: metadata.workingDirectory
                        ).lastPathComponent,
                        processID: metadata.processID,
                        modifiedAt: values.contentModificationDate
                    )
                )
            }
        }

        return CursorTerminalInspection(candidates: candidates, succeeded: succeeded)
    }

    private static func hasCursorAncestor(
        processID: Int32,
        processesByID: [Int32: AgentProcessRecord],
        cursorProcessIDs: Set<Int32>
    ) -> Bool {
        var currentProcessID = processID
        var visited = Set<Int32>()

        for _ in 0..<32 {
            if cursorProcessIDs.contains(currentProcessID) {
                return true
            }
            guard visited.insert(currentProcessID).inserted,
                  let process = processesByID[currentProcessID],
                  process.parentPID > 0 else {
                return false
            }
            currentProcessID = process.parentPID
        }

        return false
    }

    private func cursorTranscriptInspection(
        now: Date,
        applicationStartedAt: Date?
    ) -> CursorTranscriptInspection {
        let root = homeDirectory
            .appendingPathComponent(".cursor", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else {
            return CursorTranscriptInspection(records: [], succeeded: true)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return CursorTranscriptInspection(records: [], succeeded: false)
        }

        var candidates: [(URL, Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  url.path.contains("/agent-transcripts/"),
                  let values = try? url.resourceValues(
                      forKeys: [.contentModificationDateKey, .isRegularFileKey]
                  ),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt <= now.addingTimeInterval(5 * 60),
                  applicationStartedAt.map({ modifiedAt >= $0.addingTimeInterval(-5) }) ?? true else {
                continue
            }
            candidates.append((url, modifiedAt))
        }

        let records = candidates
            .sorted { $0.1 > $1.1 }
            .prefix(200)
            .map { url, modifiedAt in
                let lifecycleInspection = CursorLifecycleReader.inspection(at: url)

                let components = url.pathComponents
                let projectName: String? = components.firstIndex(of: "projects").flatMap { index in
                    let projectIndex = components.index(after: index)
                    guard projectIndex < components.endIndex else { return nil }
                    return components[projectIndex].split(separator: "-").last.map(String.init)
                }

                return CursorTranscriptRecord(
                    id: url.deletingPathExtension().lastPathComponent,
                    projectName: projectName,
                    lifecycle: lifecycleInspection.lifecycle,
                    modifiedAt: modifiedAt,
                    awaitedShellIDs: lifecycleInspection.awaitedShellIDs
                )
            }

        return CursorTranscriptInspection(records: records, succeeded: true)
    }

    private func inspectClaudeActivity(
        process: AgentProcessRecord,
        cwd: String?,
        now: Date
    ) -> ClaudeInspection {
        let sessionURL = claudeConfigRoot
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("\(process.pid).json")
        let sessionMetadata: ClaudeSessionReader.Metadata? = ClaudeSessionReader
            .read(at: sessionURL).flatMap { metadata in
            guard metadata.processID == process.pid,
                  let processStartedAt = process.startedAt,
                  abs(processStartedAt.timeIntervalSince(metadata.processStartedAt)) <= 5 else {
                return nil
            }
            return metadata
        }

        if let sessionMetadata {
            if sessionMetadata.status.isSettled {
                return ClaudeInspection(activity: nil, signalsWereConclusive: true)
            }
            if sessionMetadata.status.isActiveWork, sessionMetadata.kind == .daemon {
                return ClaudeInspection(activity: nil, signalsWereConclusive: true)
            }
            if sessionMetadata.status.isActiveWork, sessionMetadata.kind.canOwnWork {
                let workingDirectory = sessionMetadata.workingDirectory ?? cwd
                return ClaudeInspection(
                    activity: AgentActivity(
                        id: "claude:\(sessionMetadata.sessionID ?? "pid:\(process.pid)")",
                        runtime: .claude,
                        projectName: workingDirectory.map {
                            URL(fileURLWithPath: $0).lastPathComponent
                        },
                        processID: process.pid,
                        evidence: .processActivity,
                        lastActivityAt: sessionMetadata.statusUpdatedAt
                    ),
                    signalsWereConclusive: true
                )
            }
        }

        let workingDirectory = sessionMetadata?.workingDirectory ?? cwd
        if let workingDirectory,
           let transcript = newestClaudeTranscript(
                  cwd: workingDirectory,
                  processStartedAt: process.startedAt,
                  preferredSessionID: sessionMetadata?.sessionID
              ) {
            switch ClaudeLifecycleReader.latestLifecycle(at: transcript.url) {
            case .terminal:
                return ClaudeInspection(activity: nil, signalsWereConclusive: true)
            case .active where Self.isRecent(
                transcript.modifiedAt,
                relativeTo: now,
                within: 120
            ):
                return ClaudeInspection(
                    activity: AgentActivity(
                        id: "claude:\(transcript.url.deletingPathExtension().lastPathComponent)",
                        runtime: .claude,
                        projectName: URL(fileURLWithPath: workingDirectory).lastPathComponent,
                        processID: process.pid,
                        evidence: .lifecycle,
                        lastActivityAt: transcript.modifiedAt
                    ),
                    signalsWereConclusive: true
                )
            case .active, .unknown:
                break
            }
        }

        let arguments = process.arguments.map { $0.lowercased() }
        if arguments.contains("-p") || arguments.contains("--print") {
            return ClaudeInspection(
                activity: AgentActivity(
                    id: "claude:pid:\(process.pid)",
                    runtime: .claude,
                    projectName: cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
                    processID: process.pid,
                    evidence: .liveProcess,
                    lastActivityAt: nil
                ),
                signalsWereConclusive: true
            )
        }

        return ClaudeInspection(activity: nil, signalsWereConclusive: false)
    }

    private func newestClaudeTranscript(
        cwd: String,
        processStartedAt: Date?,
        preferredSessionID: String? = nil
    ) -> (url: URL, modifiedAt: Date)? {
        let escapedCWD = String(cwd.unicodeScalars.map { scalar in
            let value = scalar.value
            let isASCIIAlphanumeric = (48...57).contains(value)
                || (65...90).contains(value)
                || (97...122).contains(value)
            return isASCIIAlphanumeric ? Character(scalar) : "-"
        })
        let directory = claudeConfigRoot
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(escapedCWD, isDirectory: true)

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let candidates = files.compactMap { url -> (URL, Date)? in
            guard url.pathExtension == "jsonl",
                  let modifiedAt = try? url.resourceValues(
                      forKeys: [.contentModificationDateKey]
                  ).contentModificationDate,
                  processStartedAt.map({ modifiedAt >= $0.addingTimeInterval(-5) }) ?? true else {
                return nil
            }
            return (url, modifiedAt)
        }

        if let preferredSessionID,
           let exact = candidates.first(where: {
               $0.0.deletingPathExtension().lastPathComponent == preferredSessionID
           }) {
            return exact
        }
        return candidates.max { $0.1 < $1.1 }
    }

    private var codexSessionsRoot: URL {
        let codexHome = environment["CODEX_HOME"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        return codexHome.appendingPathComponent("sessions", isDirectory: true)
    }

    private var claudeConfigRoot: URL {
        environment["CLAUDE_CONFIG_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? homeDirectory.appendingPathComponent(".claude", isDirectory: true)
    }

    private static func isRecent(
        _ date: Date,
        relativeTo now: Date,
        within interval: TimeInterval
    ) -> Bool {
        let age = now.timeIntervalSince(date)
        return age >= -5 * 60 && age <= interval
    }
}
