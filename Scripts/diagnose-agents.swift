import Foundation

@main
struct WakeBarAgentDiagnostics {
    static func main() async {
        if let processResult = try? await ProcessCommandRunner().run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axo", "pid=,ppid=,%cpu=,lstart=,command="]
        ) {
            let records = AgentProcessParser.parse(processResult.standardOutput)
            let cursorProcesses = records.filter(AgentProcessParser.isCursorApplication)
            print("parsed-processes: \(records.count)")
            print("cursor-app-processes: \(cursorProcesses.count)")
            for process in cursorProcesses {
                let started = process.startedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"
                print("  pid \(process.pid), started \(started)")
            }
        }

        printCursorTranscripts()

        let snapshot = await LocalAgentActivityDetector().scan(now: Date())

        print("process-scan: \(snapshot.processScanSucceeded ? "ok" : "failed")")
        print("conclusive: \(snapshot.scanWasConclusive ? "yes" : "no")")
        print("active-agents: \(snapshot.activities.count)")

        for activity in snapshot.activities {
            let project = activity.projectName.map { " · \($0)" } ?? ""
            print("- \(activity.runtime.displayName)\(project) [\(activity.evidence.rawValue)]")
        }
    }

    private static func printCursorTranscripts() {
        let cursorRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor/projects", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: cursorRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let url as URL in enumerator
            where url.pathExtension == "jsonl" && url.path.contains("/agent-transcripts/") {
            let modifiedAt = try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            let age = modifiedAt.map { Int(Date().timeIntervalSince($0)) } ?? -1
            guard age >= -300, age <= 6 * 60 * 60 else { continue }
            print("cursor-transcript: \(url.deletingLastPathComponent().lastPathComponent), age \(age)s, lifecycle \(CursorLifecycleReader.latestLifecycle(at: url))")
        }
    }
}
