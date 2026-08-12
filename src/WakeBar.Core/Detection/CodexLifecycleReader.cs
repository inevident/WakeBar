using System.Text.Json;

namespace WakeBar.Core.Detection;

public sealed record CodexSessionMetadata(string? Id, string? ProjectName);

/// <summary>
/// Reads Codex rollout transcripts. A task_started or turn_started with no later
/// completion means the thread is still working.
/// </summary>
public static class CodexLifecycleReader
{
    public const int DefaultTailBytes = 1_048_576;

    public static bool IsRolloutPath(string path)
    {
        var fileName = Path.GetFileName(path);
        return fileName.StartsWith("rollout-", StringComparison.OrdinalIgnoreCase)
            && fileName.EndsWith(".jsonl", StringComparison.OrdinalIgnoreCase);
    }

    public static ThreadLifecycle LatestLifecycle(string text)
    {
        foreach (var line in FileTail.NonEmptyLines(text).Reverse())
        {
            if (!line.Contains("task_started", StringComparison.Ordinal)
                && !line.Contains("turn_started", StringComparison.Ordinal)
                && !line.Contains("task_complete", StringComparison.Ordinal)
                && !line.Contains("turn_complete", StringComparison.Ordinal)
                && !line.Contains("turn_aborted", StringComparison.Ordinal))
            {
                continue;
            }

            if (!JsonLine.TryParse(line, out var root))
            {
                continue;
            }

            if (JsonLine.GetString(root, "type") != "event_msg"
                || !root.TryGetProperty("payload", out var payload))
            {
                continue;
            }

            switch (JsonLine.GetString(payload, "type"))
            {
                case "task_started":
                case "turn_started":
                    return ThreadLifecycle.Active;
                case "task_complete":
                case "turn_complete":
                case "turn_aborted":
                    return ThreadLifecycle.Terminal;
            }
        }

        return ThreadLifecycle.Unknown;
    }

    public static ThreadLifecycle LatestLifecycleAt(string path, int maximumBytes = DefaultTailBytes)
    {
        var text = FileTail.Read(path, maximumBytes);
        return text is null ? ThreadLifecycle.Unknown : LatestLifecycle(text);
    }

    public static CodexSessionMetadata ReadMetadata(string path)
    {
        var head = FileTail.ReadHead(path, 65_536);
        if (head is null)
        {
            return new CodexSessionMetadata(null, null);
        }

        var firstLine = FileTail.NonEmptyLines(head).FirstOrDefault();
        if (firstLine is null
            || !JsonLine.TryParse(firstLine, out var root)
            || JsonLine.GetString(root, "type") != "session_meta"
            || !root.TryGetProperty("payload", out var payload))
        {
            return new CodexSessionMetadata(null, null);
        }

        var id = JsonLine.GetString(payload, "id") ?? JsonLine.GetString(payload, "session_id");
        var cwd = JsonLine.GetString(payload, "cwd");

        return new CodexSessionMetadata(id, ProjectNameFrom(cwd));
    }

    public static string? ProjectNameFrom(string? directory)
    {
        if (string.IsNullOrWhiteSpace(directory))
        {
            return null;
        }

        var trimmed = directory.TrimEnd('/', '\\');
        var separator = trimmed.LastIndexOfAny(['/', '\\']);
        return separator >= 0 && separator < trimmed.Length - 1
            ? trimmed[(separator + 1)..]
            : trimmed;
    }
}

internal static class JsonLine
{
    public static bool TryParse(string line, out JsonElement root)
    {
        try
        {
            using var document = JsonDocument.Parse(line);
            root = document.RootElement.Clone();
            return root.ValueKind == JsonValueKind.Object;
        }
        catch (JsonException)
        {
            root = default;
            return false;
        }
    }

    public static string? GetString(JsonElement element, string propertyName) =>
        element.ValueKind == JsonValueKind.Object
            && element.TryGetProperty(propertyName, out var value)
            && value.ValueKind == JsonValueKind.String
                ? value.GetString()
                : null;

    public static bool? GetBoolean(JsonElement element, string propertyName)
    {
        if (element.ValueKind != JsonValueKind.Object
            || !element.TryGetProperty(propertyName, out var value))
        {
            return null;
        }

        return value.ValueKind switch
        {
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            _ => null
        };
    }
}
