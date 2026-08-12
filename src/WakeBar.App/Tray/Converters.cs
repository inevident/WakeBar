using System.Globalization;
using System.Windows;
using System.Windows.Data;
using WakeBar.Core;

namespace WakeBar.App.Tray;

public sealed class EnumMatchToBooleanConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is not null && value.Equals(parameter);

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        Binding.DoNothing;
}

public sealed class BooleanToVisibilityConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        var flag = value is true;
        if (parameter as string == "invert")
        {
            flag = !flag;
        }

        return flag ? Visibility.Visible : Visibility.Collapsed;
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        Binding.DoNothing;
}

public sealed class NotNullToVisibilityConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is null ? Visibility.Collapsed : Visibility.Visible;

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        Binding.DoNothing;
}

public sealed class CountToVisibilityConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        var count = value switch
        {
            int number => number,
            System.Collections.ICollection collection => collection.Count,
            _ => 0
        };

        var visibleWhenEmpty = parameter as string == "empty";
        return (count > 0) != visibleWhenEmpty ? Visibility.Visible : Visibility.Collapsed;
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        Binding.DoNothing;
}

/// <summary>
/// Renders the one-line summary under the mode selector, mirroring the phrasing
/// the macOS popover uses for each state.
/// </summary>
public sealed class StatusSummaryConverter : IMultiValueConverter
{
    public object Convert(object?[] values, Type targetType, object? parameter, CultureInfo culture)
    {
        if (values.Length < 2 || values[0] is not SleepControlModel model)
        {
            return string.Empty;
        }

        return model.State switch
        {
            SleepPreventionState.Loading => "Checking the current sleep setting…",
            SleepPreventionState.Unavailable => "WakeBar can't read the sleep setting right now.",
            _ => model.PolicyMode switch
            {
                WakePolicyMode.On => "Holding the sleep lock until you choose OFF or AUTO.",
                WakePolicyMode.Off when model.ActiveAgentCount > 0 =>
                    $"{model.ActiveAgentCount} active {(model.ActiveAgentCount == 1 ? "agent is" : "agents are")} unprotected.",
                WakePolicyMode.Off => "Normal Windows sleep is available.",
                _ when !model.AgentDetectorAvailable || !model.AgentScanConclusive =>
                    "Activity scan interrupted. Holding the last safe state.",
                _ when model.ActiveAgentCount > 0 =>
                    $"Protecting {model.ActiveAgentCount} active {(model.ActiveAgentCount == 1 ? "agent" : "agents")}.",
                _ when model.IsHoldingAutoGrace => "Finishing a 90-second safety window.",
                _ => "Watching for local agent activity."
            }
        };
    }

    public object[] ConvertBack(object? value, Type[] targetTypes, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}
