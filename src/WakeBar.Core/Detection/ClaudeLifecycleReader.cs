using System.Text.Json;

namespace WakeBar.Core.Detection;

/// <summary>
/// Reads Claude Code transcripts. A prompt or a tool call in flight counts as
/// work; a finished turn or a session waiting for input does not.
/// </summary>
public static class ClaudeLifecycleReader
{
    public const int DefaultTailBytes = 524_288;

    public static ThreadLifecycle LatestLifecycle(string text)
    {
        foreach (var line in FileTail.NonEmptyLines(text).Reverse())
        {
            if (!JsonLine.TryParse(line, out var root))
            {
                continue;
            }

            var type = JsonLine.GetString(root, "type");
            var subtype = JsonLine.GetString(root, "subtype");

            if (type == "last-prompt"
                || (type == "system" && subtype is "local_command" or "turn_duration"))
            {
                return ThreadLifecycle.Terminal;
            }

            if (type == "user")
            {
                // Meta and sidechain records are bookkeeping, not a new turn.
                if (JsonLine.GetBoolean(root, "is_meta") == true
                    || JsonLine.GetBoolean(root, "is_sidechain") == true)
                {
                    continue;
                }

                return ThreadLifecycle.Active;
            }

            if (type != "assistant"
                || !root.TryGetProperty("message", out var message)
                || JsonLine.GetString(message, "role") != "assistant")
            {
                continue;
            }

            var stopReason = JsonLine.GetString(message, "stop_reason");
            if (stopReason is "end_turn" or "stop_sequence")
            {
                return ThreadLifecycle.Terminal;
            }

            if (stopReason == "tool_use" || HasToolUse(message))
            {
                return ThreadLifecycle.Active;
            }

            return ThreadLifecycle.Unknown;
        }

        return ThreadLifecycle.Unknown;
    }

    public static ThreadLifecycle LatestLifecycleAt(string path, int maximumBytes = DefaultTailBytes)
    {
        var text = FileTail.Read(path, maximumBytes);
        return text is null ? ThreadLifecycle.Unknown : LatestLifecycle(text);
    }

    private static bool HasToolUse(JsonElement message)
    {
        if (!message.TryGetProperty("content", out var content)
            || content.ValueKind != JsonValueKind.Array)
        {
            return false;
        }

        foreach (var item in content.EnumerateArray())
        {
            if (JsonLine.GetString(item, "type") == "tool_use")
            {
                return true;
            }
        }

        return false;
    }
}
