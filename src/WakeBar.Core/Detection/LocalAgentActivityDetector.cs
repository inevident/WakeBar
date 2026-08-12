namespace WakeBar.Core.Detection;

public sealed class AgentDetectionOptions
{
    /// <summary>How recently a Codex rollout must have changed to count as live.</summary>
    public TimeSpan CodexRolloutFreshness { get; init; } = TimeSpan.FromMinutes(10);

    /// <summary>Freshness required when no owning process can be found.</summary>
    public TimeSpan OrphanTranscriptFreshness { get; init; } = TimeSpan.FromMinutes(2);

    public TimeSpan ClaudeTranscriptFreshness { get; init; } = TimeSpan.FromMinutes(2);

    public TimeSpan CursorTranscriptFreshness { get; init; } = TimeSpan.FromMinutes(2);

    /// <summary>
    /// A terminal manifest is only trusted when the recorded start time matches
    /// the live process, which rules out a recycled process id.
    /// </summary>
    public TimeSpan TerminalStartTolerance { get; init; } = TimeSpan.FromSeconds(5);
}

/// <summary>
/// Correlates running processes with on-disk session evidence to decide whether
/// local agent work is actually in flight. Ported from LocalAgentActivityDetector
/// in the macOS app; the strategy is the same, the mechanisms are Windows ones.
/// </summary>
public sealed class LocalAgentActivityDetector : IAgentActivityDetector
{
    private readonly IProcessSnapshotProvider _processes;
    private readonly string _homeDirectory;
    private readonly AgentDetectionOptions _options;

    public LocalAgentActivityDetector(
        IProcessSnapshotProvider processes,
        string? homeDirectory = null,
        AgentDetectionOptions? options = null)
    {
        _processes = processes;
        _homeDirectory = homeDirectory
            ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        _options = options ?? new AgentDetectionOptions();
    }

    public async Task<AgentScanSnapshot> ScanAsync(
        DateTimeOffset now,
        CancellationToken cancellationToken = default)
    {
        var snapshot = await _processes.GetSnapshotAsync(cancellationToken).ConfigureAwait(false);
        if (!snapshot.Succeeded || snapshot.Processes.Count == 0)
        {
            return AgentScanSnapshot.Failed(now);
        }

        var processes = snapshot.Processes;
        var byProcessId = processes
            .GroupBy(process => process.ProcessId)
            .ToDictionary(group => group.Key, group => group.First());

        var classified = processes
            .Select(process => (Process: process, Runtime: AgentProcessClassifier.Classify(process)))
            .Where(pair => pair.Runtime is not null
                && !AgentProcessClassifier.IsCodexAppServer(pair.Process))
            .Select(pair => (pair.Process, Runtime: pair.Runtime!.Value))
            .ToList();

        var cursorProcessIds = processes
            .Where(AgentProcessClassifier.IsCursorApplication)
            .Select(process => process.ProcessId)
            .ToHashSet();

        var activities = new List<AgentActivity>();

        var codex = InspectCodex(
            classified.Where(pair => pair.Runtime == AgentRuntime.Codex).Select(pair => pair.Process).ToList(),
            now);
        activities.AddRange(codex.Activities);

        var claude = InspectClaude(
            classified.Where(pair => pair.Runtime == AgentRuntime.ClaudeCode).Select(pair => pair.Process).ToList(),
            now);
        activities.AddRange(claude.Activities);

        var cursor = InspectCursor(byProcessId, cursorProcessIds, now);
        activities.AddRange(cursor.Activities);

        foreach (var (process, runtime) in classified)
        {
            // Codex, Claude, and Cursor need transcript corroboration; the rest are
            // short-lived commands where a live process is the work itself.
            if (runtime is AgentRuntime.Codex or AgentRuntime.ClaudeCode or AgentRuntime.Cursor)
            {
                continue;
            }

            activities.Add(new AgentActivity(
                $"{runtime}:pid:{process.ProcessId}",
                runtime,
                null,
                process.ProcessId,
                AgentActivityEvidence.LiveProcess));
        }

        var antigravityWorker = processes.FirstOrDefault(AgentProcessClassifier.IsAntigravityWorker);
        if (antigravityWorker is not null
            && !activities.Any(activity => activity.Runtime == AgentRuntime.Antigravity))
        {
            activities.Add(new AgentActivity(
                $"antigravity:worker:{antigravityWorker.ProcessId}",
                AgentRuntime.Antigravity,
                null,
                antigravityWorker.ProcessId,
                AgentActivityEvidence.ProcessActivity,
                now));
        }

        var deduplicated = activities
            .OrderBy(activity => activity.Runtime.DisplayName(), StringComparer.Ordinal)
            .ThenByDescending(activity => activity.LastActivityAt ?? DateTimeOffset.MinValue)
            .DistinctBy(activity => activity.Id)
            .ToList();

        return new AgentScanSnapshot(
            deduplicated,
            now,
            true,
            codex.WasConclusive && claude.WasConclusive && cursor.WasConclusive);
    }

    private Inspection InspectCodex(IReadOnlyList<AgentProcessRecord> codexProcesses, DateTimeOffset now)
    {
        var sessionsRoot = Path.Combine(_homeDirectory, ".codex", "sessions");
        if (!Directory.Exists(sessionsRoot))
        {
            return Inspection.Empty;
        }

        if (!TryEnumerateFiles(sessionsRoot, "*.jsonl", out var files))
        {
            return codexProcesses.Count > 0 ? Inspection.Inconclusive : Inspection.Empty;
        }

        var hasLiveProcess = codexProcesses.Count > 0;
        var freshness = hasLiveProcess
            ? _options.CodexRolloutFreshness
            : _options.OrphanTranscriptFreshness;

        var activities = new List<AgentActivity>();
        var conclusive = true;

        foreach (var path in files.Where(CodexLifecycleReader.IsRolloutPath))
        {
            var modifiedAt = LastWriteTime(path);
            if (modifiedAt is null || now - modifiedAt.Value > freshness)
            {
                continue;
            }

            var lifecycle = CodexLifecycleReader.LatestLifecycleAt(path);

            // A rollout still being written is positive evidence even when its
            // start marker has fallen outside the bounded tail.
            var recentlyModified = now - modifiedAt.Value <= _options.OrphanTranscriptFreshness;

            if (lifecycle == ThreadLifecycle.Unknown && !recentlyModified)
            {
                conclusive = false;
                continue;
            }

            if (lifecycle != ThreadLifecycle.Active
                && !(lifecycle == ThreadLifecycle.Unknown && recentlyModified && hasLiveProcess))
            {
                continue;
            }

            var metadata = CodexLifecycleReader.ReadMetadata(path);
            activities.Add(new AgentActivity(
                $"codex:{metadata.Id ?? Path.GetFileNameWithoutExtension(path)}",
                AgentRuntime.Codex,
                metadata.ProjectName,
                codexProcesses.Count == 1 ? codexProcesses[0].ProcessId : null,
                lifecycle == ThreadLifecycle.Active
                    ? AgentActivityEvidence.Lifecycle
                    : AgentActivityEvidence.RecentTranscript,
                modifiedAt));
        }

        return new Inspection(activities, conclusive);
    }

    private Inspection InspectClaude(IReadOnlyList<AgentProcessRecord> claudeProcesses, DateTimeOffset now)
    {
        if (claudeProcesses.Count == 0)
        {
            return Inspection.Empty;
        }

        var projectsRoot = Path.Combine(_homeDirectory, ".claude", "projects");
        if (!Directory.Exists(projectsRoot))
        {
            // A live Claude process with no readable session store is exactly the
            // case where releasing the lock would be unsafe.
            return Inspection.Inconclusive;
        }

        if (!TryEnumerateFiles(projectsRoot, "*.jsonl", out var files))
        {
            return Inspection.Inconclusive;
        }

        var activities = new List<AgentActivity>();

        foreach (var path in files)
        {
            var modifiedAt = LastWriteTime(path);
            if (modifiedAt is null || now - modifiedAt.Value > _options.ClaudeTranscriptFreshness)
            {
                continue;
            }

            if (ClaudeLifecycleReader.LatestLifecycleAt(path) != ThreadLifecycle.Active)
            {
                continue;
            }

            activities.Add(new AgentActivity(
                $"claude:{Path.GetFileNameWithoutExtension(path)}",
                AgentRuntime.ClaudeCode,
                ProjectNameFromSlug(Path.GetFileName(Path.GetDirectoryName(path))),
                claudeProcesses.Count == 1 ? claudeProcesses[0].ProcessId : null,
                AgentActivityEvidence.Lifecycle,
                modifiedAt));
        }

        return new Inspection(activities, true);
    }

    private Inspection InspectCursor(
        IReadOnlyDictionary<int, AgentProcessRecord> byProcessId,
        IReadOnlySet<int> cursorProcessIds,
        DateTimeOffset now)
    {
        if (cursorProcessIds.Count == 0)
        {
            return Inspection.Empty;
        }

        var projectsRoot = Path.Combine(_homeDirectory, ".cursor", "projects");
        if (!Directory.Exists(projectsRoot))
        {
            return Inspection.Empty;
        }

        string[] projectDirectories;
        try
        {
            projectDirectories = Directory.GetDirectories(projectsRoot);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return Inspection.Inconclusive;
        }

        var terminalsByShellId = new Dictionary<string, TerminalCandidate>(StringComparer.Ordinal);
        var activities = new List<AgentActivity>();
        var conclusive = true;

        foreach (var projectDirectory in projectDirectories)
        {
            CollectTerminals(projectDirectory, byProcessId, cursorProcessIds, terminalsByShellId, ref conclusive);
        }

        foreach (var projectDirectory in projectDirectories)
        {
            var transcriptDirectory = Path.Combine(projectDirectory, "agent-transcripts");
            if (!Directory.Exists(transcriptDirectory))
            {
                continue;
            }

            if (!TryEnumerateFiles(transcriptDirectory, "*.jsonl", out var transcripts))
            {
                conclusive = false;
                continue;
            }

            foreach (var path in transcripts)
            {
                var modifiedAt = LastWriteTime(path);
                if (modifiedAt is null)
                {
                    continue;
                }

                var isFresh = now - modifiedAt.Value <= _options.CursorTranscriptFreshness;
                var inspection = CursorLifecycleReader.InspectAt(path);

                if (inspection.Lifecycle == ThreadLifecycle.Unknown && isFresh)
                {
                    conclusive = false;
                    continue;
                }

                if (inspection.Lifecycle != ThreadLifecycle.Active)
                {
                    continue;
                }

                var linkedTerminals = inspection.AwaitedShellIds
                    .Select(shellId => terminalsByShellId.GetValueOrDefault(shellId))
                    .Where(candidate => candidate is not null)
                    .Select(candidate => candidate!)
                    .ToList();

                // Without a running shell to point at, only a transcript that is
                // still being written counts as work in flight.
                if (!isFresh && linkedTerminals.Count == 0)
                {
                    continue;
                }

                var linkedTerminal = linkedTerminals
                    .OrderByDescending(candidate => candidate.ModifiedAt ?? DateTimeOffset.MinValue)
                    .FirstOrDefault();

                activities.Add(new AgentActivity(
                    $"cursor:{Path.GetFileNameWithoutExtension(path)}",
                    AgentRuntime.Cursor,
                    linkedTerminal?.ProjectName ?? ProjectNameFromSlug(Path.GetFileName(projectDirectory)),
                    linkedTerminal?.ProcessId,
                    isFresh ? AgentActivityEvidence.Lifecycle : AgentActivityEvidence.ProcessActivity,
                    Max(modifiedAt.Value, linkedTerminal?.ModifiedAt)));
            }
        }

        return new Inspection(activities, conclusive);
    }

    private void CollectTerminals(
        string projectDirectory,
        IReadOnlyDictionary<int, AgentProcessRecord> byProcessId,
        IReadOnlySet<int> cursorProcessIds,
        Dictionary<string, TerminalCandidate> terminalsByShellId,
        ref bool conclusive)
    {
        var terminalDirectory = Path.Combine(projectDirectory, "terminals");
        if (!Directory.Exists(terminalDirectory))
        {
            return;
        }

        if (!TryEnumerateFiles(terminalDirectory, "*.txt", out var manifests))
        {
            conclusive = false;
            return;
        }

        foreach (var path in manifests)
        {
            var manifest = CursorTerminalManifestReader.Read(path);
            if (manifest is null || manifest.HasCompletionFooter)
            {
                continue;
            }

            if (!byProcessId.TryGetValue(manifest.ProcessId, out var process)
                || process.StartedAt is null)
            {
                continue;
            }

            var drift = (process.StartedAt.Value - manifest.StartedAt).Duration();
            if (drift > _options.TerminalStartTolerance
                || !HasCursorAncestor(manifest.ProcessId, byProcessId, cursorProcessIds))
            {
                continue;
            }

            var shellId = Path.GetFileNameWithoutExtension(path);
            var candidate = new TerminalCandidate(
                shellId,
                CodexLifecycleReader.ProjectNameFrom(manifest.WorkingDirectory),
                manifest.ProcessId,
                LastWriteTime(path));

            var existing = terminalsByShellId.GetValueOrDefault(shellId);
            if (existing is null
                || (existing.ModifiedAt ?? DateTimeOffset.MinValue)
                    < (candidate.ModifiedAt ?? DateTimeOffset.MinValue))
            {
                terminalsByShellId[shellId] = candidate;
            }
        }
    }

    private static bool HasCursorAncestor(
        int processId,
        IReadOnlyDictionary<int, AgentProcessRecord> byProcessId,
        IReadOnlySet<int> cursorProcessIds)
    {
        var current = processId;
        var visited = new HashSet<int>();

        for (var depth = 0; depth < 32; depth++)
        {
            if (cursorProcessIds.Contains(current))
            {
                return true;
            }

            if (!visited.Add(current)
                || !byProcessId.TryGetValue(current, out var process)
                || process.ParentProcessId <= 0)
            {
                return false;
            }

            current = process.ParentProcessId;
        }

        return false;
    }

    private static bool TryEnumerateFiles(string root, string pattern, out IReadOnlyList<string> files)
    {
        try
        {
            files = Directory.GetFiles(root, pattern, SearchOption.AllDirectories);
            return true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            files = Array.Empty<string>();
            return false;
        }
    }

    private static DateTimeOffset? LastWriteTime(string path)
    {
        try
        {
            return new DateTimeOffset(File.GetLastWriteTimeUtc(path), TimeSpan.Zero);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private static DateTimeOffset Max(DateTimeOffset left, DateTimeOffset? right) =>
        right is null || left > right.Value ? left : right.Value;

    /// <summary>
    /// Cursor names each project directory after its full path with separators
    /// flattened to dashes, so the trailing segment is the folder name.
    /// </summary>
    internal static string? ProjectNameFromSlug(string? slug)
    {
        if (string.IsNullOrWhiteSpace(slug))
        {
            return null;
        }

        var lastDash = slug.LastIndexOf('-');
        return lastDash >= 0 && lastDash < slug.Length - 1 ? slug[(lastDash + 1)..] : slug;
    }

    private sealed record TerminalCandidate(
        string ShellId,
        string? ProjectName,
        int ProcessId,
        DateTimeOffset? ModifiedAt);

    private sealed record Inspection(IReadOnlyList<AgentActivity> Activities, bool WasConclusive)
    {
        public static readonly Inspection Empty = new(Array.Empty<AgentActivity>(), true);

        public static readonly Inspection Inconclusive = new(Array.Empty<AgentActivity>(), false);
    }
}
