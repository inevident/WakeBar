using WakeBar.Core;
using WakeBar.Core.Detection;
using WakeBar.Platform.Windows;

var watch = args.Contains("--watch", StringComparer.OrdinalIgnoreCase);
var interval = TimeSpan.FromSeconds(5);

var provider = new WmiProcessSnapshotProvider();
var detector = new LocalAgentActivityDetector(provider);

Console.WriteLine("WakeBar agent scan");
Console.WriteLine(watch
    ? $"Watching every {interval.TotalSeconds:0} seconds. Press Ctrl+C to stop."
    : "Single scan.");
Console.WriteLine();

// The first pass only seeds the processor-time baseline, so the numbers it
// reports for CPU-gated runtimes are not meaningful yet.
await detector.ScanAsync(DateTimeOffset.UtcNow);
await Task.Delay(TimeSpan.FromSeconds(1));

do
{
    var snapshot = await detector.ScanAsync(DateTimeOffset.UtcNow);
    Report(snapshot);

    if (watch)
    {
        await Task.Delay(interval);
    }
}
while (watch);

static void Report(AgentScanSnapshot snapshot)
{
    Console.WriteLine($"[{snapshot.ScannedAt.ToLocalTime():HH:mm:ss}] "
        + $"process scan: {(snapshot.ProcessScanSucceeded ? "ok" : "FAILED")}, "
        + $"evidence: {(snapshot.ScanWasConclusive ? "conclusive" : "INCONCLUSIVE")}, "
        + $"agents: {snapshot.Activities.Count}");

    foreach (var activity in snapshot.Activities)
    {
        var pid = activity.ProcessId is { } processId ? $"pid {processId}" : "no pid";
        var age = activity.LastActivityAt is { } lastActivity
            ? $", last activity {(snapshot.ScannedAt - lastActivity).TotalSeconds:0}s ago"
            : string.Empty;

        Console.WriteLine($"    - {activity.DisplayName} ({pid}, {activity.Evidence}{age})");
    }

    if (!snapshot.ScanWasConclusive)
    {
        Console.WriteLine("      Evidence was incomplete, so WakeBar would hold the wake lock.");
    }

    Console.WriteLine();
}
