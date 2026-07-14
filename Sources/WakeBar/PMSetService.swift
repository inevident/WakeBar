import AppKit
import Darwin
import Foundation

enum PMSetError: LocalizedError, Equatable, Sendable {
    case couldNotLaunch(String)
    case commandFailed(status: Int32, message: String)
    case unexpectedOutput
    case instantAuthorizationRequired
    case instantAuthorizationUnavailable
    case authorizationCancelled
    case authorizationFailed(String)
    case unsafeAuthorizationReceipt
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .couldNotLaunch:
            return "WakeBar couldn’t start the macOS power settings tool."
        case let .commandFailed(_, message):
            return message.isEmpty
                ? "macOS couldn’t update the sleep setting."
                : message
        case .unexpectedOutput:
            return "macOS returned an unrecognized sleep setting."
        case .instantAuthorizationRequired:
            return "Agent Mode needs its one-time administrator setup."
        case .instantAuthorizationUnavailable:
            return "WakeBar couldn’t verify its prompt-free power permission."
        case .authorizationCancelled:
            return "Nothing was changed."
        case let .authorizationFailed(message):
            return message.isEmpty
                ? "The one-time administrator setup could not be completed."
                : message
        case .unsafeAuthorizationReceipt:
            return "WakeBar found an unexpected authorization file and left it untouched."
        case .verificationFailed:
            return "macOS did not apply the requested sleep setting."
        }
    }
}

struct CommandResult: Equatable, Sendable {
    let standardOutput: String
    let standardError: String
    let terminationStatus: Int32
}

protocol CommandRunning: Sendable {
    func run(executable: URL, arguments: [String]) async throws -> CommandResult
}

struct ProcessCommandRunner: CommandRunning {
    func run(executable: URL, arguments: [String]) async throws -> CommandResult {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let standardOutput = Pipe()
            let standardError = Pipe()

            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = standardOutput
            process.standardError = standardError

            do {
                try process.run()
            } catch {
                throw PMSetError.couldNotLaunch(error.localizedDescription)
            }

            let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
            let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            return CommandResult(
                standardOutput: String(decoding: outputData, as: UTF8.self),
                standardError: String(decoding: errorData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                terminationStatus: process.terminationStatus
            )
        }.value
    }
}

protocol AdministratorCommandRunning: Sendable {
    func runAsAdministrator(shellScript: String) async throws
}

struct AppleScriptAdministratorCommandRunner: AdministratorCommandRunning {
    func runAsAdministrator(shellScript: String) async throws {
        try await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)

            let source = Self.appleScriptSource(for: shellScript)
            guard let script = NSAppleScript(source: source) else {
                throw PMSetError.authorizationFailed("")
            }

            var errorInfo: NSDictionary?
            script.executeAndReturnError(&errorInfo)

            guard let errorInfo else { return }

            let number = (errorInfo["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue
            let message = errorInfo["NSAppleScriptErrorMessage"] as? String ?? ""

            if number == -128 {
                throw PMSetError.authorizationCancelled
            }

            throw PMSetError.authorizationFailed(message)
        }
    }

    static func appleScriptSource(for shellScript: String) -> String {
        let escaped = shellScript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }
}

enum WakeBarAuthorizationRule {
    static let directory = "/private/etc/sudoers.d"

    static func path(userID: uid_t) -> String {
        "\(directory)/zzzz_wakebar_\(userID)"
    }

    static func contents(userID: uid_t) -> String {
        """
        #\(userID) ALL=(root) NOPASSWD: NOSETENV: /usr/bin/pmset -a disablesleep 0
        #\(userID) ALL=(root) NOPASSWD: NOSETENV: /usr/bin/pmset -a disablesleep 1

        """
    }

    static func installationScript(userID: uid_t) -> String {
        let target = path(userID: userID)

        return """
        set -eu
        directory='\(directory)'
        target='\(target)'
        [ "$(/usr/bin/id -u)" -eq 0 ]
        [ -d "$directory" ]
        [ ! -L "$directory" ]
        [ "$(/usr/bin/stat -f '%u:%g:%Lp' "$directory")" = '0:0:755' ]
        /usr/sbin/visudo -c >/dev/null
        umask 077
        temporary=$(/usr/bin/mktemp "$directory/.wakebar_\(userID).XXXXXX")
        cleanup() { /bin/rm -f "$temporary"; }
        trap cleanup EXIT HUP INT TERM
        /usr/bin/printf '%s\n' \
          '#\(userID) ALL=(root) NOPASSWD: NOSETENV: /usr/bin/pmset -a disablesleep 0' \
          '#\(userID) ALL=(root) NOPASSWD: NOSETENV: /usr/bin/pmset -a disablesleep 1' > "$temporary"
        /usr/sbin/chown root:wheel "$temporary"
        /bin/chmod 0440 "$temporary"
        /usr/sbin/visudo -cf "$temporary" >/dev/null
        installed_new=0
        if [ -e "$target" ] || [ -L "$target" ]; then
          [ -f "$target" ]
          [ ! -L "$target" ]
          /usr/bin/cmp -s "$temporary" "$target"
          /bin/rm -f "$temporary"
          /usr/sbin/chown root:wheel "$target"
          /bin/chmod 0440 "$target"
        else
          /bin/mv "$temporary" "$target"
          installed_new=1
        fi
        trap - EXIT HUP INT TERM
        if ! /usr/sbin/visudo -c >/dev/null; then
          if [ "$installed_new" -eq 1 ]; then /bin/rm -f "$target"; fi
          exit 1
        fi
        """
    }

    static func removalScript(userID: uid_t) -> String {
        let target = path(userID: userID)

        return """
        set -eu
        directory='\(directory)'
        target='\(target)'
        [ "$(/usr/bin/id -u)" -eq 0 ]
        [ -d "$directory" ]
        [ ! -L "$directory" ]
        /usr/bin/pmset -a disablesleep 0
        if [ ! -e "$target" ] && [ ! -L "$target" ]; then exit 0; fi
        [ -f "$target" ]
        [ ! -L "$target" ]
        [ "$(/usr/bin/stat -f '%u:%g:%Lp' "$target")" = '0:0:440' ]
        umask 077
        temporary=$(/usr/bin/mktemp "$directory/.wakebar_remove_\(userID).XXXXXX")
        cleanup() { /bin/rm -f "$temporary"; }
        trap cleanup EXIT HUP INT TERM
        /usr/bin/printf '%s\n' \
          '#\(userID) ALL=(root) NOPASSWD: NOSETENV: /usr/bin/pmset -a disablesleep 0' \
          '#\(userID) ALL=(root) NOPASSWD: NOSETENV: /usr/bin/pmset -a disablesleep 1' > "$temporary"
        /usr/bin/cmp -s "$temporary" "$target"
        /bin/rm -f "$target" "$temporary"
        trap - EXIT HUP INT TERM
        /usr/sbin/visudo -c >/dev/null
        """
    }
}

protocol InstantControlManaging: Sendable {
    func receiptLooksValid() async -> Bool
    func install() async throws
    func remove() async throws
}

struct SudoersInstantControlManager: InstantControlManaging {
    private let administratorRunner: any AdministratorCommandRunning
    private let userID: uid_t

    init(
        administratorRunner: any AdministratorCommandRunning = AppleScriptAdministratorCommandRunner(),
        userID: uid_t = getuid()
    ) {
        self.administratorRunner = administratorRunner
        self.userID = userID
    }

    func receiptLooksValid() async -> Bool {
        guard userID > 0 else { return false }

        var fileStatus = stat()
        let result = WakeBarAuthorizationRule.path(userID: userID).withCString {
            lstat($0, &fileStatus)
        }

        guard result == 0 else { return false }

        let isRegularFile = (fileStatus.st_mode & S_IFMT) == S_IFREG
        let permissions = fileStatus.st_mode & 0o777

        return isRegularFile
            && fileStatus.st_uid == 0
            && fileStatus.st_gid == 0
            && permissions == 0o440
    }

    func install() async throws {
        guard userID > 0 else {
            throw PMSetError.unsafeAuthorizationReceipt
        }

        try await administratorRunner.runAsAdministrator(
            shellScript: WakeBarAuthorizationRule.installationScript(userID: userID)
        )

        guard await receiptLooksValid() else {
            throw PMSetError.instantAuthorizationUnavailable
        }
    }

    func remove() async throws {
        guard userID > 0 else {
            throw PMSetError.unsafeAuthorizationReceipt
        }

        try await administratorRunner.runAsAdministrator(
            shellScript: WakeBarAuthorizationRule.removalScript(userID: userID)
        )

        guard !(await receiptLooksValid()) else {
            throw PMSetError.instantAuthorizationUnavailable
        }
    }
}

enum PowerSource: Equatable, Sendable {
    case powerAdapter
    case battery
    case unknown
}

struct PowerSnapshot: Equatable, Sendable {
    let source: PowerSource
    let batteryPercentage: Int?

    static let unknown = PowerSnapshot(source: .unknown, batteryPercentage: nil)
}

protocol PMSetServicing: Sendable {
    func currentSleepPreventionState() async throws -> Bool
    func currentPowerSnapshot() async throws -> PowerSnapshot
    func instantControlConfigured() async -> Bool
    func installInstantControl() async throws
    func removeInstantControl() async throws
    func setSleepPrevention(enabled: Bool) async throws
}

struct PMSetService: PMSetServicing {
    private let commandRunner: any CommandRunning
    private let instantControlManager: any InstantControlManaging

    init(
        commandRunner: any CommandRunning = ProcessCommandRunner(),
        instantControlManager: (any InstantControlManaging)? = nil
    ) {
        self.commandRunner = commandRunner
        self.instantControlManager = instantControlManager
            ?? SudoersInstantControlManager()
    }

    func currentSleepPreventionState() async throws -> Bool {
        let result = try await commandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/pmset"),
            arguments: ["-g"]
        )

        guard result.terminationStatus == 0 else {
            throw PMSetError.commandFailed(
                status: result.terminationStatus,
                message: result.standardError
            )
        }

        guard let value = PMSetOutputParser.sleepPreventionEnabled(in: result.standardOutput) else {
            throw PMSetError.unexpectedOutput
        }

        return value
    }

    func currentPowerSnapshot() async throws -> PowerSnapshot {
        let result = try await commandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/pmset"),
            arguments: ["-g", "batt"]
        )

        guard result.terminationStatus == 0 else {
            throw PMSetError.commandFailed(
                status: result.terminationStatus,
                message: result.standardError
            )
        }

        return PMSetOutputParser.powerSnapshot(in: result.standardOutput)
    }

    func instantControlConfigured() async -> Bool {
        await instantControlManager.receiptLooksValid()
    }

    func installInstantControl() async throws {
        try await instantControlManager.install()
    }

    func removeInstantControl() async throws {
        try await instantControlManager.remove()
    }

    func setSleepPrevention(enabled: Bool) async throws {
        let result = try await commandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/sudo"),
            arguments: [
                "-n", "-k", "-u", "root", "--",
                "/usr/bin/pmset", "-a", "disablesleep", enabled ? "1" : "0"
            ]
        )

        guard result.terminationStatus == 0 else {
            let normalizedError = result.standardError.lowercased()
            if normalizedError.contains("password")
                || normalizedError.contains("not allowed")
                || normalizedError.contains("not permitted")
                || normalizedError.contains("a terminal is required") {
                throw PMSetError.instantAuthorizationRequired
            }

            throw PMSetError.commandFailed(
                status: result.terminationStatus,
                message: result.standardError
            )
        }
    }
}

enum PMSetOutputParser {
    static func sleepPreventionEnabled(in output: String) -> Bool? {
        for line in output.split(whereSeparator: \Character.isNewline) {
            let fields = line.split(whereSeparator: \Character.isWhitespace)
            guard fields.count >= 2,
                  fields[0].lowercased() == "sleepdisabled" else {
                continue
            }

            switch fields[1] {
            case "1":
                return true
            case "0":
                return false
            default:
                return nil
            }
        }

        return nil
    }

    static func powerSnapshot(in output: String) -> PowerSnapshot {
        let lowercased = output.lowercased()
        let source: PowerSource

        if lowercased.contains("'ac power'") {
            source = .powerAdapter
        } else if lowercased.contains("'battery power'") {
            source = .battery
        } else {
            source = .unknown
        }

        let percentage = output
            .split(whereSeparator: \Character.isWhitespace)
            .first { $0.contains("%") }
            .flatMap { token -> Int? in
                let digits = token.prefix(while: \Character.isNumber)
                return Int(digits)
            }

        return PowerSnapshot(source: source, batteryPercentage: percentage)
    }
}
