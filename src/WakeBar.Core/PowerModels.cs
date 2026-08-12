namespace WakeBar.Core;

public enum SleepPreventionState
{
    Loading,
    Enabled,
    Disabled,
    Unavailable
}

public enum PowerSource
{
    Unknown,
    PowerAdapter,
    Battery
}

public readonly record struct PowerSnapshot(PowerSource Source, int? BatteryPercentage)
{
    public static readonly PowerSnapshot Unknown = new(PowerSource.Unknown, null);
}

/// <summary>
/// What Windows does when the lid closes on battery. Unlike macOS, blocking idle
/// sleep does not survive a lid close, so this setting is part of the sleep lock.
/// </summary>
public enum LidCloseAction
{
    Unknown,
    DoNothing,
    Sleep,
    Hibernate,
    ShutDown
}

public enum LidPosition
{
    Unknown,
    Open,
    Closed
}

/// <summary>
/// Whether prompt-free control over the lid-close action has been granted. The
/// sleep lock itself needs no elevation on Windows; changing the lid action does.
/// </summary>
public enum InstantControlState
{
    Checking,
    SetupRequired,
    Installing,
    Ready,
    Unsupported
}

public abstract record InlineNotice(string Title, string Message)
{
    public sealed record Cancelled() : InlineNotice("Setup cancelled", "Nothing was changed.");

    public sealed record Failure(string Detail) : InlineNotice("WakeBar needs attention", Detail);

    public bool IsFailure => this is Failure;
}
