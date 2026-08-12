using System.Runtime.InteropServices;

namespace WakeBar.App.Platform;

internal enum PowerRequestType
{
    DisplayRequired = 0,
    SystemRequired = 1,
    AwayModeRequired = 2,
    ExecutionRequired = 3
}

[StructLayout(LayoutKind.Sequential)]
internal struct ReasonContext
{
    public uint Version;
    public uint Flags;
    public IntPtr SimpleReasonString;
}

[StructLayout(LayoutKind.Sequential)]
internal struct PowerBroadcastSetting
{
    public Guid PowerSetting;
    public uint DataLength;
    public byte Data;
}

[StructLayout(LayoutKind.Sequential)]
internal struct SystemPowerStatus
{
    public byte AcLineStatus;
    public byte BatteryFlag;
    public byte BatteryLifePercent;
    public byte SystemStatusFlag;
    public uint BatteryLifeTime;
    public uint BatteryFullLifeTime;
}

internal static class NativeMethods
{
    public const uint PowerRequestContextVersion = 0;
    public const uint PowerRequestContextSimpleString = 0x1;

    public const int ErrorSuccess = 0;
    public const int ErrorAccessDenied = 5;
    public const int ErrorFileNotFound = 2;

    /// <summary>Subgroup "Power buttons and lid".</summary>
    public static readonly Guid ButtonsSubgroup = new("4f971e89-eebd-4455-a8de-9e59040e7347");

    /// <summary>Setting "Lid close action".</summary>
    public static readonly Guid LidCloseActionSetting = new("5ca83367-6e45-459f-a27b-476b1d01c936");

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr PowerCreateRequest(ref ReasonContext context);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool PowerSetRequest(IntPtr powerRequest, PowerRequestType requestType);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool PowerClearRequest(IntPtr powerRequest, PowerRequestType requestType);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetSystemPowerStatus(out SystemPowerStatus status);

    [DllImport("powrprof.dll")]
    public static extern uint PowerGetActiveScheme(IntPtr userRootPowerKey, out IntPtr activePolicyGuid);

    [DllImport("powrprof.dll")]
    public static extern uint PowerReadDCValueIndex(
        IntPtr rootPowerKey,
        ref Guid schemeGuid,
        ref Guid subGroupOfPowerSettingsGuid,
        ref Guid powerSettingGuid,
        out uint value);

    [DllImport("powrprof.dll")]
    public static extern uint PowerReadACValueIndex(
        IntPtr rootPowerKey,
        ref Guid schemeGuid,
        ref Guid subGroupOfPowerSettingsGuid,
        ref Guid powerSettingGuid,
        out uint value);

    [DllImport("powrprof.dll")]
    public static extern uint PowerWriteDCValueIndex(
        IntPtr rootPowerKey,
        ref Guid schemeGuid,
        ref Guid subGroupOfPowerSettingsGuid,
        ref Guid powerSettingGuid,
        uint value);

    [DllImport("powrprof.dll")]
    public static extern uint PowerWriteACValueIndex(
        IntPtr rootPowerKey,
        ref Guid schemeGuid,
        ref Guid subGroupOfPowerSettingsGuid,
        ref Guid powerSettingGuid,
        uint value);

    [DllImport("powrprof.dll")]
    public static extern uint PowerSetActiveScheme(IntPtr userRootPowerKey, ref Guid schemeGuid);

    [DllImport("kernel32.dll")]
    public static extern IntPtr LocalFree(IntPtr handle);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool DestroyIcon(IntPtr icon);

    public const int WmPowerBroadcast = 0x0218;
    public const int PbtPowerSettingChange = 0x8013;
    public const int DeviceNotifyWindowHandle = 0x0;

    public static readonly Guid LidSwitchStateChange = new("ba3e0f4d-b817-4094-a2d1-d56379e6a0f3");

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr RegisterPowerSettingNotification(
        IntPtr recipient,
        ref Guid powerSettingGuid,
        int flags);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool UnregisterPowerSettingNotification(IntPtr handle);
}
