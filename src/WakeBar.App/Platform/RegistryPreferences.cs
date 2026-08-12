using System.Globalization;
using Microsoft.Win32;
using WakeBar.Core;

namespace WakeBar.App.Platform;

/// <summary>
/// Per-user storage under HKCU, the Windows counterpart of the macOS version's
/// UserDefaults. Only the selected mode and the lifetime wake-session count are kept.
/// </summary>
public sealed class RegistryPreferences : IPreferences
{
    private const string SubKey = @"Software\WakeBar";

    public string? GetString(string key)
    {
        using var registryKey = Registry.CurrentUser.OpenSubKey(SubKey);
        return registryKey?.GetValue(key) as string;
    }

    public void SetString(string key, string value)
    {
        using var registryKey = Registry.CurrentUser.CreateSubKey(SubKey);
        registryKey.SetValue(key, value, RegistryValueKind.String);
    }

    public int GetInt(string key)
    {
        using var registryKey = Registry.CurrentUser.OpenSubKey(SubKey);
        return registryKey?.GetValue(key) switch
        {
            int value => value,
            string text when int.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed) => parsed,
            _ => 0
        };
    }

    public void SetInt(string key, int value)
    {
        using var registryKey = Registry.CurrentUser.CreateSubKey(SubKey);
        registryKey.SetValue(key, value, RegistryValueKind.DWord);
    }
}
