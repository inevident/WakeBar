namespace WakeBar.Core;

public enum WakePolicyMode
{
    Off,
    Automatic,
    On
}

public static class WakePolicyModeExtensions
{
    public static string Title(this WakePolicyMode mode) => mode switch
    {
        WakePolicyMode.Off => "OFF",
        WakePolicyMode.Automatic => "AUTO",
        WakePolicyMode.On => "ON",
        _ => "OFF"
    };

    public static string PreferenceValue(this WakePolicyMode mode) => mode switch
    {
        WakePolicyMode.Off => "off",
        WakePolicyMode.Automatic => "automatic",
        WakePolicyMode.On => "on",
        _ => "off"
    };

    public static WakePolicyMode? FromPreferenceValue(string? value) => value switch
    {
        "off" => WakePolicyMode.Off,
        "automatic" => WakePolicyMode.Automatic,
        "on" => WakePolicyMode.On,
        _ => null
    };
}
