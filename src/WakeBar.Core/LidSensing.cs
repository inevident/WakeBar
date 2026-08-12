namespace WakeBar.Core;

public interface ILidSensor
{
    bool IsSupported { get; }

    Task<LidPosition> ReadPositionAsync(CancellationToken cancellationToken = default);

    Task StopAsync();
}

public sealed class UnsupportedLidSensor : ILidSensor
{
    public bool IsSupported => false;

    public Task<LidPosition> ReadPositionAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult(LidPosition.Unknown);

    public Task StopAsync() => Task.CompletedTask;
}

/// <summary>
/// Debounces lid readings and reports the open-to-closed transition exactly once.
/// macOS reads a continuous hinge angle; Windows reports a binary switch state, so
/// the angle thresholds collapse into consecutive-sample confirmation.
/// </summary>
public sealed class LidClosureDetector
{
    public const int RequiredClosedSamples = 2;
    public const int InvalidSamplesBeforeReset = 8;

    private LidPosition _position = LidPosition.Unknown;
    private int _consecutiveClosedSamples;
    private int _consecutiveInvalidSamples;

    public bool IsClosed => _position == LidPosition.Closed;

    /// <returns>True only on a confirmed transition from open to closed.</returns>
    public bool Observe(LidPosition reading)
    {
        if (reading == LidPosition.Unknown)
        {
            _consecutiveClosedSamples = 0;
            _consecutiveInvalidSamples++;
            if (_consecutiveInvalidSamples >= InvalidSamplesBeforeReset)
            {
                Reset();
            }

            return false;
        }

        _consecutiveInvalidSamples = 0;

        if (reading == LidPosition.Closed)
        {
            _consecutiveClosedSamples++;
            if (_consecutiveClosedSamples < RequiredClosedSamples)
            {
                return false;
            }

            var wasOpen = _position == LidPosition.Open;
            _position = LidPosition.Closed;
            return wasOpen;
        }

        _consecutiveClosedSamples = 0;
        _position = LidPosition.Open;
        return false;
    }

    public void Reset()
    {
        _position = LidPosition.Unknown;
        _consecutiveClosedSamples = 0;
        _consecutiveInvalidSamples = 0;
    }
}
