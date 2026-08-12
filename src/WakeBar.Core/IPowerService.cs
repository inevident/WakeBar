namespace WakeBar.Core;

/// <summary>
/// The seam between the state machine and Windows power management. Mirrors the
/// macOS PMSetServicing protocol so the two versions stay recognizable to each other.
/// </summary>
public interface IPowerService
{
    Task<bool> GetSleepPreventionStateAsync(CancellationToken cancellationToken = default);

    Task SetSleepPreventionAsync(bool enabled, CancellationToken cancellationToken = default);

    Task<PowerSnapshot> GetPowerSnapshotAsync(CancellationToken cancellationToken = default);

    /// <summary>
    /// True when WakeBar can change the lid-close action without prompting. On a
    /// device with no lid this reports <see cref="LidControlAvailability.Unsupported"/>.
    /// </summary>
    Task<LidControlAvailability> GetLidControlAvailabilityAsync(CancellationToken cancellationToken = default);

    Task InstallLidControlAsync(CancellationToken cancellationToken = default);

    Task RemoveLidControlAsync(CancellationToken cancellationToken = default);
}

public enum LidControlAvailability
{
    Unsupported,
    SetupRequired,
    Ready
}
