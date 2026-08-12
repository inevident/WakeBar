namespace WakeBar.Core.Detection;

/// <summary>
/// Bounded reads of append-only transcript files. Reading the tail keeps a scan
/// cheap even when a session has run for hours.
/// </summary>
public static class FileTail
{
    public static string? Read(string path, int maximumBytes)
    {
        try
        {
            using var stream = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete);

            var startOffset = stream.Length > maximumBytes ? stream.Length - maximumBytes : 0;
            stream.Seek(startOffset, SeekOrigin.Begin);

            using var reader = new StreamReader(stream);
            var text = reader.ReadToEnd();

            // A tail almost always starts mid-line; drop the partial record.
            if (startOffset > 0)
            {
                var firstNewline = text.IndexOf('\n');
                text = firstNewline >= 0 ? text[(firstNewline + 1)..] : string.Empty;
            }

            return text;
        }
        catch (IOException)
        {
            return null;
        }
        catch (UnauthorizedAccessException)
        {
            return null;
        }
    }

    public static string? ReadHead(string path, int maximumBytes)
    {
        try
        {
            using var stream = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete);

            var length = (int)Math.Min(maximumBytes, stream.Length);
            var buffer = new byte[length];
            var read = stream.ReadAtLeast(buffer, length, throwOnEndOfStream: false);

            return System.Text.Encoding.UTF8.GetString(buffer, 0, read);
        }
        catch (IOException)
        {
            return null;
        }
        catch (UnauthorizedAccessException)
        {
            return null;
        }
    }

    public static IEnumerable<string> NonEmptyLines(string text)
    {
        foreach (var line in text.Split('\n'))
        {
            var trimmed = line.Trim('\r', ' ', '\t');
            if (trimmed.Length > 0)
            {
                yield return trimmed;
            }
        }
    }
}
