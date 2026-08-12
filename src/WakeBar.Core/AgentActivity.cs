namespace WakeBar.Core;

public enum AgentRuntime
{
    Codex,
    ClaudeCode,
    Cursor,
    OpenCode,
    Copilot,
    Gemini,
    Antigravity,
    Aider,
    Goose,
    Amp,
    Kiro,
    Factory,
    Codebuff,
    Qoder,
    Cline,
    Kilo,
    Crush,
    DeepSeek,
    MiniMax,
    Groq
}

public static class AgentRuntimeExtensions
{
    public static string DisplayName(this AgentRuntime runtime) => runtime switch
    {
        AgentRuntime.Codex => "Codex",
        AgentRuntime.ClaudeCode => "Claude Code",
        AgentRuntime.Cursor => "Cursor",
        AgentRuntime.OpenCode => "OpenCode",
        AgentRuntime.Copilot => "GitHub Copilot",
        AgentRuntime.Gemini => "Gemini CLI",
        AgentRuntime.Antigravity => "Antigravity",
        AgentRuntime.Aider => "Aider",
        AgentRuntime.Goose => "Goose",
        AgentRuntime.Amp => "Amp",
        AgentRuntime.Kiro => "Kiro",
        AgentRuntime.Factory => "Factory Droid",
        AgentRuntime.Codebuff => "Codebuff",
        AgentRuntime.Qoder => "Qoder",
        AgentRuntime.Cline => "Cline",
        AgentRuntime.Kilo => "Kilo Code",
        AgentRuntime.Crush => "Crush",
        AgentRuntime.DeepSeek => "DeepSeek Code",
        AgentRuntime.MiniMax => "MiniMax Code",
        AgentRuntime.Groq => "Groq Build",
        _ => "Agent"
    };
}

public enum AgentActivityEvidence
{
    Lifecycle,
    LiveProcess,
    RecentTranscript,
    ProcessActivity
}

/// <summary>
/// Transient display metadata for one detected agent. Deliberately carries no
/// prompt or response content.
/// </summary>
public sealed record AgentActivity(
    string Id,
    AgentRuntime Runtime,
    string? ProjectName = null,
    int? ProcessId = null,
    AgentActivityEvidence Evidence = AgentActivityEvidence.LiveProcess,
    DateTimeOffset? LastActivityAt = null)
{
    public string DisplayName => string.IsNullOrEmpty(ProjectName)
        ? Runtime.DisplayName()
        : $"{Runtime.DisplayName()} · {ProjectName}";
}

public sealed record AgentScanSnapshot(
    IReadOnlyList<AgentActivity> Activities,
    DateTimeOffset ScannedAt,
    bool ProcessScanSucceeded,
    bool ScanWasConclusive)
{
    public static AgentScanSnapshot Empty(DateTimeOffset scannedAt) =>
        new(Array.Empty<AgentActivity>(), scannedAt, true, true);

    public static AgentScanSnapshot Failed(DateTimeOffset scannedAt) =>
        new(Array.Empty<AgentActivity>(), scannedAt, false, false);
}

public interface IAgentActivityDetector
{
    Task<AgentScanSnapshot> ScanAsync(DateTimeOffset now, CancellationToken cancellationToken = default);
}

/// <summary>
/// Stands in until the real detector lands so the state machine and UI can be
/// exercised end to end. Always reports a successful, conclusive, empty scan.
/// </summary>
public sealed class NullAgentActivityDetector : IAgentActivityDetector
{
    public Task<AgentScanSnapshot> ScanAsync(DateTimeOffset now, CancellationToken cancellationToken = default) =>
        Task.FromResult(AgentScanSnapshot.Empty(now));
}
