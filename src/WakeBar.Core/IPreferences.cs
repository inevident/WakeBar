namespace WakeBar.Core;

public interface IPreferences
{
    string? GetString(string key);

    void SetString(string key, string value);

    int GetInt(string key);

    void SetInt(string key, int value);
}

public sealed class InMemoryPreferences : IPreferences
{
    private readonly Dictionary<string, string> _values = new(StringComparer.Ordinal);

    public string? GetString(string key) => _values.GetValueOrDefault(key);

    public void SetString(string key, string value) => _values[key] = value;

    public int GetInt(string key) =>
        _values.TryGetValue(key, out var raw) && int.TryParse(raw, out var value) ? value : 0;

    public void SetInt(string key, int value) =>
        _values[key] = value.ToString(System.Globalization.CultureInfo.InvariantCulture);
}
