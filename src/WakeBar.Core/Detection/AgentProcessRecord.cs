namespace WakeBar.Core.Detection;

public enum ThreadLifecycle
{
    Unknown,
    Active,
    Terminal
}

public sealed record AgentProcessRecord(
    int ProcessId,
    int ParentProcessId,
    string ExecutableName,
    string CommandLine,
    DateTimeOffset? StartedAt,
    double CpuPercent)
{
    /// <summary>Lower-cased executable name without the .exe suffix.</summary>
    public string NormalizedName
    {
        get
        {
            var name = ExecutableName.ToLowerInvariant();
            return name.EndsWith(".exe", StringComparison.Ordinal)
                ? name[..^4]
                : name;
        }
    }

    public IReadOnlyList<string> Arguments => CommandLineArguments.Split(CommandLine);
}

public sealed record ProcessSnapshot(IReadOnlyList<AgentProcessRecord> Processes, bool Succeeded)
{
    public static readonly ProcessSnapshot Failed = new(Array.Empty<AgentProcessRecord>(), false);
}

public interface IProcessSnapshotProvider
{
    Task<ProcessSnapshot> GetSnapshotAsync(CancellationToken cancellationToken = default);
}

/// <summary>
/// Splits a Windows command line into arguments, honouring double-quoted spans.
/// Only the argument boundaries matter here, so escape handling stays minimal.
/// </summary>
public static class CommandLineArguments
{
    public static IReadOnlyList<string> Split(string commandLine)
    {
        var arguments = new List<string>();
        var current = new System.Text.StringBuilder();
        var inQuotes = false;

        foreach (var character in commandLine)
        {
            if (character == '"')
            {
                inQuotes = !inQuotes;
                continue;
            }

            if (!inQuotes && char.IsWhiteSpace(character))
            {
                if (current.Length > 0)
                {
                    arguments.Add(current.ToString());
                    current.Clear();
                }

                continue;
            }

            current.Append(character);
        }

        if (current.Length > 0)
        {
            arguments.Add(current.ToString());
        }

        return arguments.Count > 0 ? arguments[1..] : Array.Empty<string>();
    }
}
