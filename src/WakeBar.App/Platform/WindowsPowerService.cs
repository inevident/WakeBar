using System.Runtime.InteropServices;
using WakeBar.Core;

namespace WakeBar.App.Platform;

/// <summary>
/// Windows implementation of the sleep lock.
/// </summary>
/// <remarks>
/// Unlike macOS, blocking sleep here needs no elevation: a power request is owned
/// by this process, so nothing outside WakeBar can clear it and the handle itself
/// is the authoritative state. The lid-close action is the part that is system-wide
/// and may require an administrator, because a closing lid overrides a power request.
/// </remarks>
public sealed class WindowsPowerService : IPowerService, IDisposable
{
    private const string ReasonString = "WakeBar is protecting active local agent work.";
    private const string PreviousAcLidActionKey = "wakebar.previous-lid-action.ac";
    private const string PreviousDcLidActionKey = "wakebar.previous-lid-action.dc";
    private const uint LidActionDoNothing = 0;

    private readonly IPreferences _preferences;
    private readonly object _gate = new();

    private IntPtr _requestHandle = IntPtr.Zero;
    private bool _isHeld;
    private bool _disposed;

    public WindowsPowerService(IPreferences preferences)
    {
        _preferences = preferences;
    }

    public Task<bool> GetSleepPreventionStateAsync(CancellationToken cancellationToken = default)
    {
        lock (_gate)
        {
            return Task.FromResult(_isHeld && _requestHandle != IntPtr.Zero);
        }
    }

    public Task SetSleepPreventionAsync(bool enabled, CancellationToken cancellationToken = default)
    {
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);

            if (enabled)
            {
                EnsureRequestHandle();
                if (!NativeMethods.PowerSetRequest(_requestHandle, PowerRequestType.SystemRequired))
                {
                    throw new PowerServiceException(
                        PowerServiceFault.RequestRejected,
                        DescribeLastError("Windows refused WakeBar's request to stay awake"));
                }

                _isHeld = true;
            }
            else
            {
                if (_requestHandle != IntPtr.Zero
                    && _isHeld
                    && !NativeMethods.PowerClearRequest(_requestHandle, PowerRequestType.SystemRequired))
                {
                    throw new PowerServiceException(
                        PowerServiceFault.CommandFailed,
                        DescribeLastError("Windows couldn't release the sleep lock"));
                }

                _isHeld = false;
            }
        }

        return Task.CompletedTask;
    }

    public Task<PowerSnapshot> GetPowerSnapshotAsync(CancellationToken cancellationToken = default)
    {
        if (!NativeMethods.GetSystemPowerStatus(out var status))
        {
            return Task.FromResult(PowerSnapshot.Unknown);
        }

        var source = status.AcLineStatus switch
        {
            0 => PowerSource.Battery,
            1 => PowerSource.PowerAdapter,
            _ => PowerSource.Unknown
        };

        int? percentage = status.BatteryLifePercent <= 100 ? status.BatteryLifePercent : null;

        return Task.FromResult(new PowerSnapshot(source, percentage));
    }

    public Task<LidControlAvailability> GetLidControlAvailabilityAsync(CancellationToken cancellationToken = default)
    {
        if (!TryReadLidAction(useAcLine: false, out var currentValue))
        {
            // The setting is absent on machines without a lid.
            return Task.FromResult(LidControlAvailability.Unsupported);
        }

        // Writing the value back unchanged is a harmless way to learn whether this
        // user can change the active power scheme without elevation.
        var writeStatus = WriteLidAction(useAcLine: false, currentValue);
        return Task.FromResult(writeStatus == NativeMethods.ErrorSuccess
            ? LidControlAvailability.Ready
            : LidControlAvailability.SetupRequired);
    }

    public Task InstallLidControlAsync(CancellationToken cancellationToken = default)
    {
        if (!TryReadLidAction(useAcLine: false, out var currentDc))
        {
            throw new PowerServiceException(PowerServiceFault.Unsupported);
        }

        TryReadLidAction(useAcLine: true, out var currentAc);

        _preferences.SetInt(PreviousDcLidActionKey, (int)currentDc);
        _preferences.SetInt(PreviousAcLidActionKey, (int)currentAc);

        ApplyLidAction(LidActionDoNothing, LidActionDoNothing);

        if (!TryReadLidAction(useAcLine: false, out var verified) || verified != LidActionDoNothing)
        {
            throw new PowerServiceException(PowerServiceFault.InstantAuthorizationUnavailable);
        }

        return Task.CompletedTask;
    }

    public Task RemoveLidControlAsync(CancellationToken cancellationToken = default)
    {
        if (!TryReadLidAction(useAcLine: false, out _))
        {
            throw new PowerServiceException(PowerServiceFault.Unsupported);
        }

        var previousDc = (uint)Math.Max(0, _preferences.GetInt(PreviousDcLidActionKey));
        var previousAc = (uint)Math.Max(0, _preferences.GetInt(PreviousAcLidActionKey));

        ApplyLidAction(previousAc, previousDc);

        return Task.CompletedTask;
    }

    private void ApplyLidAction(uint acValue, uint dcValue)
    {
        var dcStatus = WriteLidAction(useAcLine: false, dcValue);
        var acStatus = WriteLidAction(useAcLine: true, acValue);

        if (dcStatus == NativeMethods.ErrorAccessDenied || acStatus == NativeMethods.ErrorAccessDenied)
        {
            throw new PowerServiceException(PowerServiceFault.InstantAuthorizationRequired);
        }

        if (dcStatus != NativeMethods.ErrorSuccess || acStatus != NativeMethods.ErrorSuccess)
        {
            throw new PowerServiceException(
                PowerServiceFault.AuthorizationFailed,
                $"Windows rejected the lid-close change (error {Math.Max(dcStatus, acStatus)}).");
        }
    }

    private static bool TryReadLidAction(bool useAcLine, out uint value)
    {
        value = 0;
        if (!TryGetActiveScheme(out var scheme))
        {
            return false;
        }

        var subgroup = NativeMethods.ButtonsSubgroup;
        var setting = NativeMethods.LidCloseActionSetting;

        var status = useAcLine
            ? NativeMethods.PowerReadACValueIndex(IntPtr.Zero, ref scheme, ref subgroup, ref setting, out value)
            : NativeMethods.PowerReadDCValueIndex(IntPtr.Zero, ref scheme, ref subgroup, ref setting, out value);

        return status == NativeMethods.ErrorSuccess;
    }

    private static uint WriteLidAction(bool useAcLine, uint value)
    {
        if (!TryGetActiveScheme(out var scheme))
        {
            return NativeMethods.ErrorFileNotFound;
        }

        var subgroup = NativeMethods.ButtonsSubgroup;
        var setting = NativeMethods.LidCloseActionSetting;

        var status = useAcLine
            ? NativeMethods.PowerWriteACValueIndex(IntPtr.Zero, ref scheme, ref subgroup, ref setting, value)
            : NativeMethods.PowerWriteDCValueIndex(IntPtr.Zero, ref scheme, ref subgroup, ref setting, value);

        if (status != NativeMethods.ErrorSuccess)
        {
            return status;
        }

        // A write only takes effect once the scheme is reactivated.
        return NativeMethods.PowerSetActiveScheme(IntPtr.Zero, ref scheme);
    }

    private static bool TryGetActiveScheme(out Guid scheme)
    {
        scheme = Guid.Empty;
        if (NativeMethods.PowerGetActiveScheme(IntPtr.Zero, out var pointer) != NativeMethods.ErrorSuccess
            || pointer == IntPtr.Zero)
        {
            return false;
        }

        try
        {
            scheme = Marshal.PtrToStructure<Guid>(pointer);
            return true;
        }
        finally
        {
            NativeMethods.LocalFree(pointer);
        }
    }

    private void EnsureRequestHandle()
    {
        if (_requestHandle != IntPtr.Zero)
        {
            return;
        }

        var reasonPointer = Marshal.StringToHGlobalUni(ReasonString);
        try
        {
            var context = new ReasonContext
            {
                Version = NativeMethods.PowerRequestContextVersion,
                Flags = NativeMethods.PowerRequestContextSimpleString,
                SimpleReasonString = reasonPointer
            };

            var handle = NativeMethods.PowerCreateRequest(ref context);
            if (handle == IntPtr.Zero || handle == new IntPtr(-1))
            {
                throw new PowerServiceException(
                    PowerServiceFault.RequestRejected,
                    DescribeLastError("Windows would not create a power request"));
            }

            _requestHandle = handle;
        }
        finally
        {
            Marshal.FreeHGlobal(reasonPointer);
        }
    }

    private static string DescribeLastError(string prefix)
    {
        var error = Marshal.GetLastWin32Error();
        return error == 0 ? $"{prefix}." : $"{prefix} (error {error}).";
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;

            if (_requestHandle == IntPtr.Zero)
            {
                return;
            }

            if (_isHeld)
            {
                NativeMethods.PowerClearRequest(_requestHandle, PowerRequestType.SystemRequired);
                _isHeld = false;
            }

            NativeMethods.CloseHandle(_requestHandle);
            _requestHandle = IntPtr.Zero;
        }
    }
}
