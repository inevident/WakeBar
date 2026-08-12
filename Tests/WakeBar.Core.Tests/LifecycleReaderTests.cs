using WakeBar.Core.Detection;

namespace WakeBar.Core.Tests;

public class CodexLifecycleReaderTests
{
    [Fact]
    public void A_started_task_with_no_completion_is_active()
    {
        var text = """
            {"type":"session_meta","payload":{"id":"abc","cwd":"C:/work/wakebar"}}
            {"type":"event_msg","payload":{"type":"task_started"}}
            """;

        Assert.Equal(ThreadLifecycle.Active, CodexLifecycleReader.LatestLifecycle(text));
    }

    [Fact]
    public void The_last_lifecycle_event_wins()
    {
        var text = """
            {"type":"event_msg","payload":{"type":"task_started"}}
            {"type":"event_msg","payload":{"type":"task_complete"}}
            """;

        Assert.Equal(ThreadLifecycle.Terminal, CodexLifecycleReader.LatestLifecycle(text));
    }

    [Fact]
    public void An_aborted_turn_is_terminal()
    {
        var text = """
            {"type":"event_msg","payload":{"type":"turn_started"}}
            {"type":"event_msg","payload":{"type":"turn_aborted"}}
            """;

        Assert.Equal(ThreadLifecycle.Terminal, CodexLifecycleReader.LatestLifecycle(text));
    }

    [Fact]
    public void A_transcript_with_no_lifecycle_events_is_unknown()
    {
        var text = """
            {"type":"session_meta","payload":{"id":"abc"}}
            {"type":"response_item","payload":{"type":"message"}}
            """;

        Assert.Equal(ThreadLifecycle.Unknown, CodexLifecycleReader.LatestLifecycle(text));
    }

    [Fact]
    public void Malformed_lines_are_skipped_rather_than_throwing()
    {
        var text = """
            not json at all
            {"type":"event_msg","payload":{"type":"task_started"}}
            """;

        Assert.Equal(ThreadLifecycle.Active, CodexLifecycleReader.LatestLifecycle(text));
    }

    [Theory]
    [InlineData("rollout-2026-08-12T09-00-00.jsonl", true)]
    [InlineData("notes.jsonl", false)]
    [InlineData("rollout-2026.json", false)]
    public void Only_rollout_transcripts_are_considered(string fileName, bool expected)
    {
        Assert.Equal(expected, CodexLifecycleReader.IsRolloutPath(fileName));
    }

    [Theory]
    [InlineData("C:/work/wakebar", "wakebar")]
    [InlineData(@"C:\work\wakebar\", "wakebar")]
    [InlineData("", null)]
    public void The_project_name_is_the_final_path_segment(string? directory, string? expected)
    {
        Assert.Equal(expected, CodexLifecycleReader.ProjectNameFrom(directory));
    }
}

public class ClaudeLifecycleReaderTests
{
    [Fact]
    public void A_user_prompt_starts_a_turn()
    {
        var text = """{"type":"user","message":{"role":"user"}}""";

        Assert.Equal(ThreadLifecycle.Active, ClaudeLifecycleReader.LatestLifecycle(text));
    }

    [Fact]
    public void A_finished_assistant_turn_is_terminal()
    {
        var text = """{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn"}}""";

        Assert.Equal(ThreadLifecycle.Terminal, ClaudeLifecycleReader.LatestLifecycle(text));
    }

    [Fact]
    public void A_tool_call_in_flight_is_active()
    {
        var text = """{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use"}}""";

        Assert.Equal(ThreadLifecycle.Active, ClaudeLifecycleReader.LatestLifecycle(text));
    }

    [Fact]
    public void Tool_use_content_counts_even_without_a_stop_reason()
    {
        var text = """{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use"}]}}""";

        Assert.Equal(ThreadLifecycle.Active, ClaudeLifecycleReader.LatestLifecycle(text));
    }

    [Fact]
    public void Meta_records_do_not_start_a_turn()
    {
        var text = """
            {"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn"}}
            {"type":"user","is_meta":true,"message":{"role":"user"}}
            """;

        Assert.Equal(ThreadLifecycle.Terminal, ClaudeLifecycleReader.LatestLifecycle(text));
    }

    [Fact]
    public void A_session_waiting_for_input_is_terminal()
    {
        var text = """
            {"type":"user","message":{"role":"user"}}
            {"type":"last-prompt"}
            """;

        Assert.Equal(ThreadLifecycle.Terminal, ClaudeLifecycleReader.LatestLifecycle(text));
    }
}

public class CursorLifecycleReaderTests
{
    [Fact]
    public void An_ended_turn_is_terminal()
    {
        var text = """
            {"role":"user"}
            {"type":"turn_ended"}
            """;

        Assert.Equal(ThreadLifecycle.Terminal, CursorLifecycleReader.Inspect(text).Lifecycle);
    }

    [Fact]
    public void A_new_message_after_a_turn_ends_reopens_the_thread()
    {
        var text = """
            {"type":"turn_ended"}
            {"role":"user"}
            """;

        Assert.Equal(ThreadLifecycle.Active, CursorLifecycleReader.Inspect(text).Lifecycle);
    }

    [Fact]
    public void Awaited_shell_identifiers_are_collected()
    {
        var text = """
            {"role":"assistant","message":{"content":[{"type":"tool_use","name":"AwaitShell","input":{"shell_id":"251055"}}]}}
            """;

        var inspection = CursorLifecycleReader.Inspect(text);

        Assert.Equal(ThreadLifecycle.Active, inspection.Lifecycle);
        Assert.Contains("251055", inspection.AwaitedShellIds);
    }

    [Fact]
    public void A_completed_turn_releases_the_shells_it_was_waiting_on()
    {
        var text = """
            {"role":"assistant","message":{"content":[{"type":"tool_use","name":"AwaitShell","input":{"shell_id":"1"}}]}}
            {"type":"turn_ended"}
            {"role":"user"}
            """;

        var inspection = CursorLifecycleReader.Inspect(text);

        Assert.Equal(ThreadLifecycle.Active, inspection.Lifecycle);
        Assert.Empty(inspection.AwaitedShellIds);
    }
}

public class CursorTerminalManifestReaderTests
{
    private const string RunningManifest = """
        ---
        pid: 6344
        cwd: "C:\\Users\\me\\project"
        command: "dotnet build"
        title: "Build"
        status: running
        started_at: 2026-08-12T17:01:35.010Z
        running_for_ms: 95172
        ---
        """;

    [Fact]
    public void A_running_manifest_header_is_parsed()
    {
        var manifest = CursorTerminalManifestReader.ParseHeader(RunningManifest);

        Assert.NotNull(manifest);
        Assert.Equal(6344, manifest!.ProcessId);
        Assert.Equal(@"C:\Users\me\project", manifest.WorkingDirectory);
        Assert.Equal(95172UL, manifest.RunningForMilliseconds);
    }

    [Fact]
    public void A_file_without_the_header_fence_is_rejected()
    {
        Assert.Null(CursorTerminalManifestReader.ParseHeader("pid: 1\ncwd: \"C:\\\\x\"\n"));
    }

    [Fact]
    public void A_header_missing_a_command_is_rejected()
    {
        var text = """
            ---
            pid: 6344
            cwd: "C:\\Users\\me\\project"
            started_at: 2026-08-12T17:01:35.010Z
            running_for_ms: 100
            ---
            """;

        Assert.Null(CursorTerminalManifestReader.ParseHeader(text));
    }

    [Fact]
    public void A_completion_footer_marks_the_shell_as_finished()
    {
        Assert.True(CursorTerminalManifestReader.HasCompletionFooter("\nexit_code: 0\nended_at: 2026-08-12T17:03:00Z\n"));
        Assert.False(CursorTerminalManifestReader.HasCompletionFooter("\nstill running\n"));
    }
}
