using System.Diagnostics;
using System.Globalization;
using System.Management;
using WakeBar.Core.Detection;

namespace WakeBar.Platform.Windows;

/// <summary>
/// The Windows counterpart of the macOS <c>ps -axo pid,ppid,%cpu,lstart,command</c>
/// call. Win32_Process is the only unelevated source of full command lines, which
/// the classifier needs to tell an agent CLI apart from a bare node process.
/// </summary>
public sealed class WmiProcessSnapshotProvider : IProcessSnapshotProvider
{
    private const string Query =
        "SELECT ProcessId, ParentProcessId, Name, CommandLine, CreationDate, KernelModeTime, UserModeTime FROM Win32_Process";

    private readonly Dictionary<int, CpuSample> _previousCpuSamples = new();

    public Task<ProcessSnapshot> GetSnapshotAsync(CancellationToken cancellationToken = default) =>
        Task.Run(() => Collect(cancellationToken), cancellationToken);

    private ProcessSnapshot Collect(CancellationToken cancellationToken)
    {
        var records = new List<AgentProcessRecord>();
        var sampledAt = Stopwatch.GetTimestamp();
        var currentSamples = new Dictionary<int, CpuSample>();

        try
        {
            using var searcher = new ManagementObjectSearcher(Query);
            using var results = searcher.Get();

            foreach (var item in results)
            {
                cancellationToken.ThrowIfCancellationRequested();

                using var process = (ManagementObject)item;

                var processId = ReadInt(process, "ProcessId");
                if (processId is null)
                {
                    continue;
                }

                var name = process["Name"] as string ?? string.Empty;
                var commandLine = process["CommandLine"] as string ?? name;
                var startedAt = ReadDate(process, "CreationDate");
                var processorTicks = ReadUInt64(process, "KernelModeTime") + ReadUInt64(process, "UserModeTime");

                currentSamples[processId.Value] = new CpuSample(processorTicks, sampledAt);

                records.Add(new AgentProcessRecord(
                    processId.Value,
                    ReadInt(process, "ParentProcessId") ?? 0,
                    name,
                    commandLine,
                    startedAt,
                    CpuPercent(processId.Value, processorTicks, sampledAt)));
            }
        }
        catch (ManagementException)
        {
            return ProcessSnapshot.Failed;
        }
        catch (UnauthorizedAccessException)
        {
            return ProcessSnapshot.Failed;
        }

        _previousCpuSamples.Clear();
        foreach (var (processId, sample) in currentSamples)
        {
            _previousCpuSamples[processId] = sample;
        }

        return records.Count > 0
            ? new ProcessSnapshot(records, true)
            : ProcessSnapshot.Failed;
    }

    /// <summary>
    /// Win32_Process reports cumulative processor time, so a usable percentage
    /// only exists once two scans have been taken.
    /// </summary>
    private double CpuPercent(int processId, ulong processorTicks, long sampledAt)
    {
        if (!_previousCpuSamples.TryGetValue(processId, out var previous)
            || processorTicks < previous.ProcessorTicks)
        {
            return 0;
        }

        var elapsed = Stopwatch.GetElapsedTime(previous.SampledAt, sampledAt);
        if (elapsed <= TimeSpan.Zero)
        {
            return 0;
        }

        // Both kernel and user time are reported in 100-nanosecond units.
        var busy = TimeSpan.FromTicks((long)(processorTicks - previous.ProcessorTicks));
        var percent = busy.TotalMilliseconds / elapsed.TotalMilliseconds * 100.0;

        return double.IsFinite(percent) ? Math.Max(0, percent) : 0;
    }

    private static int? ReadInt(ManagementObject process, string property) =>
        process[property] switch
        {
            uint value => (int)value,
            int value => value,
            _ => null
        };

    private static ulong ReadUInt64(ManagementObject process, string property) =>
        process[property] switch
        {
            ulong value => value,
            long value and >= 0 => (ulong)value,
            string text when ulong.TryParse(text, out var parsed) => parsed,
            _ => 0
        };

    private static DateTimeOffset? ReadDate(ManagementObject process, string property)
    {
        if (process[property] is not string value || value.Length < 21)
        {
            return null;
        }

        try
        {
            return new DateTimeOffset(ManagementDateTimeConverter.ToDateTime(value));
        }
        catch (ArgumentException)
        {
            return null;
        }
        catch (FormatException)
        {
            return null;
        }
    }

    private readonly record struct CpuSample(ulong ProcessorTicks, long SampledAt);
}
