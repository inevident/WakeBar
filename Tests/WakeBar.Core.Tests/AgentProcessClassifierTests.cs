using WakeBar.Core;
using WakeBar.Core.Detection;

namespace WakeBar.Core.Tests;

public class AgentProcessClassifierTests
{
    private static AgentProcessRecord Process(
        string executableName,
        string commandLine,
        double cpuPercent = 0,
        int pid = 100,
        int parentPid = 1) =>
        new(pid, parentPid, executableName, commandLine, DateTimeOffset.UtcNow, cpuPercent);

    [Theory]
    [InlineData("codex.exe", @"C:\tools\codex.exe", AgentRuntime.Codex)]
    [InlineData("claude.exe", @"C:\tools\claude.exe", AgentRuntime.ClaudeCode)]
    [InlineData("cursor-agent.exe", @"C:\tools\cursor-agent.exe", AgentRuntime.Cursor)]
    [InlineData("aider.exe", @"C:\tools\aider.exe", AgentRuntime.Aider)]
    [InlineData("droid.exe", @"C:\tools\droid.exe", AgentRuntime.Factory)]
    [InlineData("goose.exe", @"C:\tools\goose.exe", AgentRuntime.Goose)]
    public void Named_executables_map_to_their_runtime(
        string executableName,
        string commandLine,
        AgentRuntime expected)
    {
        Assert.Equal(expected, AgentProcessClassifier.Classify(Process(executableName, commandLine)));
    }

    [Fact]
    public void A_version_check_is_not_agent_work()
    {
        var record = Process("codex.exe", @"C:\tools\codex.exe --version");

        Assert.Null(AgentProcessClassifier.Classify(record));
    }

    [Fact]
    public void A_help_invocation_is_not_agent_work()
    {
        var record = Process("claude.exe", @"C:\tools\claude.exe --help");

        Assert.Null(AgentProcessClassifier.Classify(record));
    }

    [Fact]
    public void An_opencode_server_is_infrastructure_rather_than_work()
    {
        var serving = Process("opencode.exe", @"C:\tools\opencode.exe serve");
        var working = Process("opencode.exe", @"C:\tools\opencode.exe run");

        Assert.Null(AgentProcessClassifier.Classify(serving));
        Assert.Equal(AgentRuntime.OpenCode, AgentProcessClassifier.Classify(working));
    }

    [Fact]
    public void Node_hosted_clis_are_identified_by_their_package_path()
    {
        var claude = Process(
            "node.exe",
            @"""C:\Program Files\nodejs\node.exe"" C:\Users\me\AppData\Roaming\npm\node_modules\@anthropic-ai\claude-code\cli.js");

        Assert.Equal(AgentRuntime.ClaudeCode, AgentProcessClassifier.Classify(claude));
    }

    [Fact]
    public void A_bare_node_process_is_not_an_agent()
    {
        var record = Process("node.exe", @"C:\Program Files\nodejs\node.exe server.js");

        Assert.Null(AgentProcessClassifier.Classify(record));
    }

    [Fact]
    public void A_codex_app_server_does_not_count_as_a_running_task()
    {
        var record = Process("codex.exe", @"C:\tools\codex.exe app-server");

        Assert.True(AgentProcessClassifier.IsCodexAppServer(record));
    }

    [Fact]
    public void The_cursor_application_is_recognized_separately_from_its_agent_cli()
    {
        var application = Process("Cursor.exe", @"C:\Users\me\AppData\Local\Programs\cursor\Cursor.exe");

        Assert.True(AgentProcessClassifier.IsCursorApplication(application));
        Assert.Null(AgentProcessClassifier.Classify(application));
    }

    [Fact]
    public void An_idle_antigravity_language_server_is_not_work()
    {
        var idle = Process("language_server.exe", @"C:\antigravity\language_server.exe", cpuPercent: 0.2);
        var busy = Process("language_server.exe", @"C:\antigravity\language_server.exe", cpuPercent: 14.0);

        Assert.False(AgentProcessClassifier.IsAntigravityWorker(idle));
        Assert.True(AgentProcessClassifier.IsAntigravityWorker(busy));
    }
}
