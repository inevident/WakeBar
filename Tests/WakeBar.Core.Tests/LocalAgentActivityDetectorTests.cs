using WakeBar.Core;
using WakeBar.Core.Detection;

namespace WakeBar.Core.Tests;

public sealed class FakeProcessSnapshotProvider : IProcessSnapshotProvider
{
    private readonly List<AgentProcessRecord> _records = [];

    public bool Succeeded { get; set; } = true;

    public FakeProcessSnapshotProvider Add(
        string executableName,
        string commandLine,
        int pid,
        int parentPid = 1,
        DateTimeOffset? startedAt = null,
        double cpuPercent = 0)
    {
        _records.Add(new AgentProcessRecord(
            pid,
            parentPid,
            executableName,
            commandLine,
            startedAt ?? DateTimeOffset.UtcNow,
            cpuPercent));
        return this;
    }

    public Task<ProcessSnapshot> GetSnapshotAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult(Succeeded && _records.Count > 0
            ? new ProcessSnapshot(_records, true)
            : ProcessSnapshot.Failed);
}

public class LocalAgentActivityDetectorTests : IDisposable
{
    private readonly string _home;

    public LocalAgentActivityDetectorTests()
    {
        _home = Path.Combine(Path.GetTempPath(), "wakebar-tests", Guid.NewGuid().ToString("n"));
        Directory.CreateDirectory(_home);
    }

    public void Dispose()
    {
        try
        {
            Directory.Delete(_home, recursive: true);
        }
        catch (IOException)
        {
            // A leftover temp directory must never fail a test run.
        }
    }

    private string WriteFile(string relativePath, string contents)
    {
        var path = Path.Combine(_home, relativePath);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, contents);
        return path;
    }

    private LocalAgentActivityDetector CreateDetector(IProcessSnapshotProvider processes) =>
        new(processes, _home);

    [Fact]
    public async Task A_failed_process_scan_is_reported_as_such()
    {
        var processes = new FakeProcessSnapshotProvider { Succeeded = false };
        var detector = CreateDetector(processes);

        var snapshot = await detector.ScanAsync(DateTimeOffset.UtcNow);

        Assert.False(snapshot.ProcessScanSucceeded);
        Assert.False(snapshot.ScanWasConclusive);
        Assert.Empty(snapshot.Activities);
    }

    [Fact]
    public async Task An_idle_machine_reports_no_agents()
    {
        var processes = new FakeProcessSnapshotProvider()
            .Add("explorer.exe", @"C:\Windows\explorer.exe", 10)
            .Add("node.exe", @"C:\Program Files\nodejs\node.exe server.js", 11);
        var detector = CreateDetector(processes);

        var snapshot = await detector.ScanAsync(DateTimeOffset.UtcNow);

        Assert.True(snapshot.ProcessScanSucceeded);
        Assert.True(snapshot.ScanWasConclusive);
        Assert.Empty(snapshot.Activities);
    }

    [Fact]
    public async Task A_running_codex_task_is_detected()
    {
        WriteFile(
            @".codex\sessions\2026\08\12\rollout-2026-08-12T09-00-00.jsonl",
            """
            {"type":"session_meta","payload":{"id":"session-1","cwd":"C:/work/wakebar"}}
            {"type":"event_msg","payload":{"type":"task_started"}}
            """);

        var processes = new FakeProcessSnapshotProvider()
            .Add("codex.exe", @"C:\tools\codex.exe", 4242);
        var detector = CreateDetector(processes);

        var snapshot = await detector.ScanAsync(DateTimeOffset.UtcNow);

        var activity = Assert.Single(snapshot.Activities);
        Assert.Equal(AgentRuntime.Codex, activity.Runtime);
        Assert.Equal("wakebar", activity.ProjectName);
        Assert.Equal("codex:session-1", activity.Id);
        Assert.True(snapshot.ScanWasConclusive);
    }

    [Fact]
    public async Task A_finished_codex_task_is_not_reported()
    {
        WriteFile(
            @".codex\sessions\2026\08\12\rollout-2026-08-12T09-00-00.jsonl",
            """
            {"type":"session_meta","payload":{"id":"session-1","cwd":"C:/work/wakebar"}}
            {"type":"event_msg","payload":{"type":"task_started"}}
            {"type":"event_msg","payload":{"type":"task_complete"}}
            """);

        var processes = new FakeProcessSnapshotProvider()
            .Add("codex.exe", @"C:\tools\codex.exe", 4242);
        var detector = CreateDetector(processes);

        var snapshot = await detector.ScanAsync(DateTimeOffset.UtcNow);

        Assert.Empty(snapshot.Activities);
        Assert.True(snapshot.ScanWasConclusive);
    }

    [Fact]
    public async Task A_live_claude_process_with_no_session_store_keeps_the_scan_inconclusive()
    {
        var processes = new FakeProcessSnapshotProvider()
            .Add("claude.exe", @"C:\tools\claude.exe", 5150);
        var detector = CreateDetector(processes);

        var snapshot = await detector.ScanAsync(DateTimeOffset.UtcNow);

        Assert.Empty(snapshot.Activities);
        Assert.True(snapshot.ProcessScanSucceeded);
        Assert.False(snapshot.ScanWasConclusive);
    }

    [Fact]
    public async Task A_claude_session_waiting_for_input_is_not_work()
    {
        WriteFile(
            @".claude\projects\C--work-wakebar\session.jsonl",
            """
            {"type":"user","message":{"role":"user"}}
            {"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn"}}
            """);

        var processes = new FakeProcessSnapshotProvider()
            .Add("claude.exe", @"C:\tools\claude.exe", 5150);
        var detector = CreateDetector(processes);

        var snapshot = await detector.ScanAsync(DateTimeOffset.UtcNow);

        Assert.Empty(snapshot.Activities);
        Assert.True(snapshot.ScanWasConclusive);
    }

    [Fact]
    public async Task A_claude_tool_call_in_flight_is_work()
    {
        WriteFile(
            @".claude\projects\C--work-wakebar\session.jsonl",
            """
            {"type":"user","message":{"role":"user"}}
            {"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use"}}
            """);

        var processes = new FakeProcessSnapshotProvider()
            .Add("claude.exe", @"C:\tools\claude.exe", 5150);
        var detector = CreateDetector(processes);

        var snapshot = await detector.ScanAsync(DateTimeOffset.UtcNow);

        var activity = Assert.Single(snapshot.Activities);
        Assert.Equal(AgentRuntime.ClaudeCode, activity.Runtime);
        Assert.Equal("wakebar", activity.ProjectName);
    }

    [Fact]
    public async Task A_named_cli_counts_as_work_while_it_runs()
    {
        var processes = new FakeProcessSnapshotProvider()
            .Add("aider.exe", @"C:\tools\aider.exe", 777);
        var detector = CreateDetector(processes);

        var snapshot = await detector.ScanAsync(DateTimeOffset.UtcNow);

        var activity = Assert.Single(snapshot.Activities);
        Assert.Equal(AgentRuntime.Aider, activity.Runtime);
        Assert.Equal(777, activity.ProcessId);
    }

    [Fact]
    public async Task An_open_cursor_window_alone_is_not_work()
    {
        var processes = new FakeProcessSnapshotProvider()
            .Add("Cursor.exe", @"C:\cursor\Cursor.exe", 900);
        var detector = CreateDetector(processes);

        var snapshot = await detector.ScanAsync(DateTimeOffset.UtcNow);

        Assert.Empty(snapshot.Activities);
    }

    [Fact]
    public async Task An_active_cursor_transcript_with_a_running_shell_is_work()
    {
        var startedAt = DateTimeOffset.UtcNow.AddMinutes(-1);
        var slug = "c-work-wakebar";

        WriteFile(
            Path.Combine(".cursor", "projects", slug, "terminals", "251055.txt"),
            $"""
            ---
            pid: 6344
            cwd: "C:\\work\\wakebar"
            command: "dotnet build"
            status: running
            started_at: {startedAt:yyyy-MM-ddTHH:mm:ss.fffZ}
            running_for_ms: 60000
            ---
            building...
            """);

        WriteFile(
            Path.Combine(".cursor", "projects", slug, "agent-transcripts", "thread.jsonl"),
            """
            {"role":"user"}
            {"role":"assistant","message":{"content":[{"type":"tool_use","name":"AwaitShell","input":{"shell_id":"251055"}}]}}
            """);

        var processes = new FakeProcessSnapshotProvider()
            .Add("Cursor.exe", @"C:\cursor\Cursor.exe", 900)
            .Add("powershell.exe", @"C:\Windows\powershell.exe", 6344, parentPid: 900, startedAt: startedAt);
        var detector = CreateDetector(processes);

        var snapshot = await detector.ScanAsync(DateTimeOffset.UtcNow);

        var activity = Assert.Single(snapshot.Activities);
        Assert.Equal(AgentRuntime.Cursor, activity.Runtime);
        Assert.Equal("wakebar", activity.ProjectName);
        Assert.Equal(6344, activity.ProcessId);
    }

    [Fact]
    public async Task A_terminal_owned_by_an_unrelated_process_tree_is_ignored()
    {
        var startedAt = DateTimeOffset.UtcNow.AddMinutes(-1);
        var slug = "c-work-wakebar";

        WriteFile(
            Path.Combine(".cursor", "projects", slug, "terminals", "251055.txt"),
            $"""
            ---
            pid: 6344
            cwd: "C:\\work\\wakebar"
            command: "dotnet build"
            status: running
            started_at: {startedAt:yyyy-MM-ddTHH:mm:ss.fffZ}
            running_for_ms: 60000
            ---
            """);

        WriteFile(
            Path.Combine(".cursor", "projects", slug, "agent-transcripts", "thread.jsonl"),
            """
            {"type":"turn_ended"}
            """);

        var processes = new FakeProcessSnapshotProvider()
            .Add("Cursor.exe", @"C:\cursor\Cursor.exe", 900)
            .Add("powershell.exe", @"C:\Windows\powershell.exe", 6344, parentPid: 5, startedAt: startedAt);
        var detector = CreateDetector(processes);

        var snapshot = await detector.ScanAsync(DateTimeOffset.UtcNow);

        Assert.Empty(snapshot.Activities);
    }

    [Fact]
    public async Task A_finished_shell_does_not_keep_a_thread_alive()
    {
        var startedAt = DateTimeOffset.UtcNow.AddMinutes(-30);
        var slug = "c-work-wakebar";

        WriteFile(
            Path.Combine(".cursor", "projects", slug, "terminals", "251055.txt"),
            $"""
            ---
            pid: 6344
            cwd: "C:\\work\\wakebar"
            command: "dotnet build"
            started_at: {startedAt:yyyy-MM-ddTHH:mm:ss.fffZ}
            running_for_ms: 60000
            ---
            output
            exit_code: 0
            ended_at: 2026-08-12T17:03:00Z
            """);

        var transcript = WriteFile(
            Path.Combine(".cursor", "projects", slug, "agent-transcripts", "thread.jsonl"),
            """
            {"role":"assistant","message":{"content":[{"type":"tool_use","name":"AwaitShell","input":{"shell_id":"251055"}}]}}
            """);

        // Age the transcript past the freshness window so only the shell could vouch for it.
        File.SetLastWriteTimeUtc(transcript, DateTime.UtcNow.AddMinutes(-30));

        var processes = new FakeProcessSnapshotProvider()
            .Add("Cursor.exe", @"C:\cursor\Cursor.exe", 900)
            .Add("powershell.exe", @"C:\Windows\powershell.exe", 6344, parentPid: 900, startedAt: startedAt);
        var detector = CreateDetector(processes);

        var snapshot = await detector.ScanAsync(DateTimeOffset.UtcNow);

        Assert.Empty(snapshot.Activities);
    }

    [Fact]
    public async Task A_busy_antigravity_worker_is_reported_once()
    {
        var processes = new FakeProcessSnapshotProvider()
            .Add("language_server.exe", @"C:\antigravity\language_server.exe --mode agent", 321, cpuPercent: 22);
        var detector = CreateDetector(processes);

        var snapshot = await detector.ScanAsync(DateTimeOffset.UtcNow);

        var activity = Assert.Single(snapshot.Activities);
        Assert.Equal(AgentRuntime.Antigravity, activity.Runtime);
    }
}
