namespace WakeBar.Core.Detection;

/// <summary>
/// Decides which runtime, if any, a running process represents. Ported from
/// AgentProcessParser.runtime(for:), with Windows executable names and the
/// node_modules paths matched against both slash styles.
/// </summary>
public static class AgentProcessClassifier
{
    public const string CursorApplicationName = "cursor";

    public static AgentRuntime? Classify(AgentProcessRecord record)
    {
        var arguments = record.Arguments
            .Select(argument => argument.ToLowerInvariant())
            .ToArray();

        // A help or version invocation exits immediately and is never real work.
        if (arguments.Contains("--help") || arguments.Contains("--version"))
        {
            return null;
        }

        var runtime = ClassifyByName(record.NormalizedName, arguments);
        if (runtime is not null)
        {
            return runtime;
        }

        return ClassifyScriptHost(record);
    }

    private static AgentRuntime? ClassifyByName(string name, IReadOnlyList<string> arguments) => name switch
    {
        "codex" => AgentRuntime.Codex,
        "claude" => AgentRuntime.ClaudeCode,
        "cursor-agent" => AgentRuntime.Cursor,
        "opencode" when !arguments.Contains("serve") && !arguments.Contains("web") => AgentRuntime.OpenCode,
        "copilot" or "github-copilot-cli" => AgentRuntime.Copilot,
        "gemini" or "gemini-cli" => AgentRuntime.Gemini,
        "antigravity" or "antigravity-cli" or "agy" => AgentRuntime.Antigravity,
        "aider" or "aider-chat" => AgentRuntime.Aider,
        "goose" => AgentRuntime.Goose,
        "amp" => AgentRuntime.Amp,
        "kiro-cli" => AgentRuntime.Kiro,
        "droid" or "factory-cli" => AgentRuntime.Factory,
        "codebuff" => AgentRuntime.Codebuff,
        "qoder" or "qoder-cli" => AgentRuntime.Qoder,
        "cline" or "cline-cli" => AgentRuntime.Cline,
        "kilo" or "kilo-cli" or "kilocode" => AgentRuntime.Kilo,
        "crush" => AgentRuntime.Crush,
        "deepseek-code" or "deepseek-cli" => AgentRuntime.DeepSeek,
        "minimax-code" or "minimax-cli" => AgentRuntime.MiniMax,
        "groq-build" or "groq-cli" => AgentRuntime.Groq,
        _ => null
    };

    /// <summary>
    /// Most agent CLIs install on Windows as scripts run by node, so the package
    /// path in the command line is the only reliable identity.
    /// </summary>
    private static AgentRuntime? ClassifyScriptHost(AgentProcessRecord record)
    {
        if (record.NormalizedName is not ("node" or "bun" or "deno"))
        {
            return null;
        }

        var command = NormalizeSeparators(record.CommandLine);

        if (command.Contains("/node_modules/@anthropic-ai/claude-code/", StringComparison.Ordinal))
        {
            return AgentRuntime.ClaudeCode;
        }

        if (command.Contains("/node_modules/@openai/codex/", StringComparison.Ordinal))
        {
            return AgentRuntime.Codex;
        }

        if (command.Contains("/node_modules/opencode-ai/", StringComparison.Ordinal))
        {
            return AgentRuntime.OpenCode;
        }

        if (command.Contains("/node_modules/@google/gemini-cli/", StringComparison.Ordinal))
        {
            return AgentRuntime.Gemini;
        }

        if (command.Contains("/node_modules/codebuff/", StringComparison.Ordinal))
        {
            return AgentRuntime.Codebuff;
        }

        return null;
    }

    /// <summary>
    /// A persistent Codex app-server is infrastructure, not a running task.
    /// </summary>
    public static bool IsCodexAppServer(AgentProcessRecord record) =>
        Classify(record) == AgentRuntime.Codex
        && record.Arguments.Any(argument =>
            string.Equals(argument, "app-server", StringComparison.OrdinalIgnoreCase));

    public static bool IsCursorApplication(AgentProcessRecord record) =>
        string.Equals(record.NormalizedName, CursorApplicationName, StringComparison.Ordinal);

    public static bool IsAntigravityWorker(AgentProcessRecord record)
    {
        var command = record.CommandLine.ToLowerInvariant();
        return command.Contains("antigravity", StringComparison.Ordinal)
            && command.Contains("language_server", StringComparison.Ordinal)
            && record.CpuPercent >= 1.0;
    }

    public static string NormalizeSeparators(string path) =>
        path.Replace('\\', '/').ToLowerInvariant();
}
