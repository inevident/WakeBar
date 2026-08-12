using WakeBar.Core;

namespace WakeBar.Core.Tests;

public sealed class FakePowerService : IPowerService
{
    public bool SleepPreventionEnabled { get; set; }

    public int SetCallCount { get; private set; }

    public PowerSnapshot Snapshot { get; set; } = new(PowerSource.PowerAdapter, 100);

    public LidControlAvailability LidAvailability { get; set; } = LidControlAvailability.Unsupported;

    public Exception? ThrowOnRead { get; set; }

    public Exception? ThrowOnWrite { get; set; }

    /// <summary>When set, a write records the call but leaves the state unchanged.</summary>
    public bool IgnoreWrites { get; set; }

    public Task<bool> GetSleepPreventionStateAsync(CancellationToken cancellationToken = default)
    {
        if (ThrowOnRead is not null)
        {
            throw ThrowOnRead;
        }

        return Task.FromResult(SleepPreventionEnabled);
    }

    public Task SetSleepPreventionAsync(bool enabled, CancellationToken cancellationToken = default)
    {
        SetCallCount++;

        if (ThrowOnWrite is not null)
        {
            throw ThrowOnWrite;
        }

        if (!IgnoreWrites)
        {
            SleepPreventionEnabled = enabled;
        }

        return Task.CompletedTask;
    }

    public Task<PowerSnapshot> GetPowerSnapshotAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult(Snapshot);

    public Task<LidControlAvailability> GetLidControlAvailabilityAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult(LidAvailability);

    public Task InstallLidControlAsync(CancellationToken cancellationToken = default)
    {
        LidAvailability = LidControlAvailability.Ready;
        return Task.CompletedTask;
    }

    public Task RemoveLidControlAsync(CancellationToken cancellationToken = default)
    {
        LidAvailability = LidControlAvailability.SetupRequired;
        SleepPreventionEnabled = false;
        return Task.CompletedTask;
    }
}

public sealed class FakeAgentDetector : IAgentActivityDetector
{
    public AgentScanSnapshot? NextSnapshot { get; set; }

    public int ScanCount { get; private set; }

    public Task<AgentScanSnapshot> ScanAsync(DateTimeOffset now, CancellationToken cancellationToken = default)
    {
        ScanCount++;
        return Task.FromResult(NextSnapshot ?? AgentScanSnapshot.Empty(now));
    }

    public void ReportActive(DateTimeOffset now, params AgentActivity[] activities) =>
        NextSnapshot = new AgentScanSnapshot(activities, now, true, true);

    public void ReportIdle(DateTimeOffset now) => NextSnapshot = AgentScanSnapshot.Empty(now);

    public void ReportScanFailure(DateTimeOffset now) => NextSnapshot = AgentScanSnapshot.Failed(now);

    public void ReportInconclusive(DateTimeOffset now) =>
        NextSnapshot = new AgentScanSnapshot(Array.Empty<AgentActivity>(), now, true, false);
}

public static class TestAgents
{
    public static AgentActivity Codex(int pid = 4242) =>
        new($"codex:pid:{pid}", AgentRuntime.Codex, "wakebar-windows", pid, AgentActivityEvidence.Lifecycle);

    public static AgentActivity Claude(int pid = 5150) =>
        new($"claude:pid:{pid}", AgentRuntime.ClaudeCode, "wakebar-windows", pid, AgentActivityEvidence.Lifecycle);
}
