using System.Globalization;
using System.Text.Json;

namespace WakeBar.Core.Detection;

public sealed record CursorTranscriptInspection(
    ThreadLifecycle Lifecycle,
    IReadOnlySet<string> AwaitedShellIds);

/// <summary>
/// Reads Cursor agent transcripts. Alongside the turn lifecycle this collects the
/// shell identifiers the agent is waiting on, which is what links a transcript to
/// a specific terminal manifest.
/// </summary>
public static class CursorLifecycleReader
{
    public const int DefaultTailBytes = 524_288;

    public static CursorTranscriptInspection Inspect(string text)
    {
        var lifecycle = ThreadLifecycle.Unknown;
        var awaitedShellIds = new HashSet<string>(StringComparer.Ordinal);

        foreach (var line in FileTail.NonEmptyLines(text))
        {
            if (!JsonLine.TryParse(line, out var root))
            {
                continue;
            }

            var type = JsonLine.GetString(root, "type");
            var role = JsonLine.GetString(root, "role");

            if (type == "turn_ended")
            {
                lifecycle = ThreadLifecycle.Terminal;
            }
            else if (role is "user" or "assistant")
            {
                // A new turn invalidates the shells the previous turn awaited.
                if (lifecycle == ThreadLifecycle.Terminal)
                {
                    awaitedShellIds.Clear();
                }

                lifecycle = ThreadLifecycle.Active;
            }

            CollectAwaitedShells(root, awaitedShellIds);
        }

        return new CursorTranscriptInspection(lifecycle, awaitedShellIds);
    }

    public static CursorTranscriptInspection InspectAt(string path, int maximumBytes = DefaultTailBytes)
    {
        var text = FileTail.Read(path, maximumBytes);
        return text is null
            ? new CursorTranscriptInspection(ThreadLifecycle.Unknown, new HashSet<string>())
            : Inspect(text);
    }

    private static void CollectAwaitedShells(JsonElement root, HashSet<string> awaitedShellIds)
    {
        if (!root.TryGetProperty("message", out var message)
            || !message.TryGetProperty("content", out var content)
            || content.ValueKind != JsonValueKind.Array)
        {
            return;
        }

        foreach (var item in content.EnumerateArray())
        {
            if (JsonLine.GetString(item, "type") != "tool_use"
                || JsonLine.GetString(item, "name") != "AwaitShell"
                || !item.TryGetProperty("input", out var input))
            {
                continue;
            }

            var shellId = JsonLine.GetString(input, "shell_id");
            if (!string.IsNullOrEmpty(shellId))
            {
                awaitedShellIds.Add(shellId);
            }
        }
    }
}

public sealed record CursorTerminalManifest(
    int ProcessId,
    string WorkingDirectory,
    DateTimeOffset StartedAt,
    ulong RunningForMilliseconds,
    bool HasCompletionFooter);

/// <summary>
/// Parses the YAML-ish header Cursor writes at the top of each terminal file. The
/// footer carries exit_code and ended_at once the command finishes, which is how
/// a still-running shell is told apart from a finished one.
/// </summary>
public static class CursorTerminalManifestReader
{
    public static CursorTerminalManifest? Read(
        string path,
        int maximumHeaderBytes = 32_768,
        int maximumFooterBytes = 8_192)
    {
        var head = FileTail.ReadHead(path, maximumHeaderBytes);
        if (head is null)
        {
            return null;
        }

        var header = ParseHeader(head);
        if (header is null)
        {
            return null;
        }

        var tail = FileTail.Read(path, maximumFooterBytes) ?? string.Empty;

        return header with { HasCompletionFooter = HasCompletionFooter(tail) };
    }

    public static CursorTerminalManifest? ParseHeader(string text)
    {
        var lines = text.Split('\n');
        if (lines.Length == 0 || lines[0].Trim() != "---")
        {
            return null;
        }

        int? processId = null;
        string? workingDirectory = null;
        DateTimeOffset? startedAt = null;
        ulong? runningForMilliseconds = null;
        var hasCommand = false;

        foreach (var raw in lines.Skip(1))
        {
            var line = raw.Trim();
            if (line == "---")
            {
                break;
            }

            if (ValueAfter(line, "pid:") is { } pidText && int.TryParse(pidText, out var parsedPid))
            {
                processId = parsedPid;
            }
            else if (ValueAfter(line, "cwd:") is { } cwdText)
            {
                workingDirectory = Unquote(cwdText);
            }
            else if (ValueAfter(line, "command:") is not null)
            {
                hasCommand = true;
            }
            else if (ValueAfter(line, "started_at:") is { } startedText
                && DateTimeOffset.TryParse(
                    Unquote(startedText),
                    CultureInfo.InvariantCulture,
                    DateTimeStyles.RoundtripKind,
                    out var parsedStart))
            {
                startedAt = parsedStart;
            }
            else if (ValueAfter(line, "running_for_ms:") is { } runningText
                && ulong.TryParse(runningText, out var parsedRunning))
            {
                runningForMilliseconds = parsedRunning;
            }
        }

        if (processId is null
            || workingDirectory is null
            || startedAt is null
            || runningForMilliseconds is null
            || !hasCommand)
        {
            return null;
        }

        return new CursorTerminalManifest(
            processId.Value,
            workingDirectory,
            startedAt.Value,
            runningForMilliseconds.Value,
            false);
    }

    public static bool HasCompletionFooter(string text)
    {
        var normalized = text.Replace("\r\n", "\n");
        return normalized.Contains("\nexit_code:", StringComparison.Ordinal)
            && normalized.Contains("\nended_at:", StringComparison.Ordinal);
    }

    private static string? ValueAfter(string line, string prefix) =>
        line.StartsWith(prefix, StringComparison.Ordinal)
            ? line[prefix.Length..].Trim()
            : null;

    private static string Unquote(string value)
    {
        if (value.Length < 2 || value[0] != '"')
        {
            return value;
        }

        try
        {
            return JsonSerializer.Deserialize<string>(value) ?? value;
        }
        catch (JsonException)
        {
            return value;
        }
    }
}
