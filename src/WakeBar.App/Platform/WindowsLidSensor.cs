using System.Runtime.InteropServices;
using System.Windows.Interop;
using WakeBar.Core;

namespace WakeBar.App.Platform;

/// <summary>
/// Tracks the lid switch through power setting notifications.
/// </summary>
/// <remarks>
/// macOS exposes a continuous hinge angle that can be polled at any time; Windows
/// only broadcasts a binary open/closed message when the state changes. There is no
/// API to read the current position, so the state stays unknown until the first
/// transition. That matches how the macOS app treats a Mac started with the lid
/// already closed: it does not count.
/// </remarks>
public sealed class WindowsLidSensor : ILidSensor, IDisposable
{
    private readonly HwndSource? _messageWindow;
    private readonly IntPtr _notificationHandle;
    private volatile int _position = (int)LidPosition.Unknown;
    private bool _disposed;

    public WindowsLidSensor()
    {
        IsSupported = DeviceHasLid();
        if (!IsSupported)
        {
            return;
        }

        _messageWindow = new HwndSource(new HwndSourceParameters("WakeBarLidListener")
        {
            Width = 0,
            Height = 0,
            WindowStyle = 0
        });
        _messageWindow.AddHook(OnWindowMessage);

        var setting = NativeMethods.LidSwitchStateChange;
        _notificationHandle = NativeMethods.RegisterPowerSettingNotification(
            _messageWindow.Handle,
            ref setting,
            NativeMethods.DeviceNotifyWindowHandle);
    }

    public bool IsSupported { get; }

    public Task<LidPosition> ReadPositionAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult((LidPosition)_position);

    public Task StopAsync() => Task.CompletedTask;

    private IntPtr OnWindowMessage(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message != NativeMethods.WmPowerBroadcast
            || wParam.ToInt32() != NativeMethods.PbtPowerSettingChange
            || lParam == IntPtr.Zero)
        {
            return IntPtr.Zero;
        }

        var setting = Marshal.PtrToStructure<PowerBroadcastSetting>(lParam);
        if (setting.PowerSetting != NativeMethods.LidSwitchStateChange)
        {
            return IntPtr.Zero;
        }

        _position = (int)(setting.Data == 0 ? LidPosition.Closed : LidPosition.Open);
        return IntPtr.Zero;
    }

    /// <summary>
    /// The lid-close action only exists in the power scheme on machines with a lid.
    /// </summary>
    private static bool DeviceHasLid()
    {
        if (NativeMethods.PowerGetActiveScheme(IntPtr.Zero, out var pointer) != NativeMethods.ErrorSuccess
            || pointer == IntPtr.Zero)
        {
            return false;
        }

        try
        {
            var scheme = Marshal.PtrToStructure<Guid>(pointer);
            var subgroup = NativeMethods.ButtonsSubgroup;
            var setting = NativeMethods.LidCloseActionSetting;

            return NativeMethods.PowerReadDCValueIndex(
                IntPtr.Zero,
                ref scheme,
                ref subgroup,
                ref setting,
                out _) == NativeMethods.ErrorSuccess;
        }
        finally
        {
            NativeMethods.LocalFree(pointer);
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;

        if (_notificationHandle != IntPtr.Zero)
        {
            NativeMethods.UnregisterPowerSettingNotification(_notificationHandle);
        }

        if (_messageWindow is not null)
        {
            _messageWindow.RemoveHook(OnWindowMessage);
            _messageWindow.Dispose();
        }
    }
}
