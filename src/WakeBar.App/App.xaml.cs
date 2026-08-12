using System.ComponentModel;
using System.Windows;
using H.NotifyIcon;
using H.NotifyIcon.Core;
using WakeBar.App.Platform;
using WakeBar.App.Tray;
using WakeBar.Core;
using WakeBar.Core.Detection;
using WakeBar.Platform.Windows;

namespace WakeBar.App;

public partial class App : Application
{
    private WindowsPowerService? _powerService;
    private WindowsLidSensor? _lidSensor;
    private SleepControlModel? _model;
    private TaskbarIcon? _trayIcon;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        var preferences = new RegistryPreferences();
        _powerService = new WindowsPowerService(preferences);
        _lidSensor = new WindowsLidSensor();
        _model = new SleepControlModel(
            _powerService,
            new LocalAgentActivityDetector(new WmiProcessSnapshotProvider()),
            _lidSensor,
            preferences);

        _trayIcon = new TaskbarIcon
        {
            TrayPopup = new PopoverView { DataContext = _model },
            PopupActivation = PopupActivationMode.LeftOrRightClick,
            NoLeftClickDelay = true
        };
        _trayIcon.ForceCreate();

        _model.PropertyChanged += OnModelPropertyChanged;
        UpdateTrayPresentation();

        _trayIcon.ShowNotification(
            "WakeBar is running",
            "Look in the taskbar overflow (^). Click the icon to open OFF / AUTO / ON.",
            NotificationIcon.Info);

        _model.StartMonitoring();
    }

    private void OnModelPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is not (nameof(SleepControlModel.TrayGlyph)
            or nameof(SleepControlModel.TrayText)
            or nameof(SleepControlModel.TrayAccessibilityLabel)
            or nameof(SleepControlModel.ActiveAgentCount)))
        {
            return;
        }

        Dispatcher.Invoke(UpdateTrayPresentation);
    }

    private void UpdateTrayPresentation()
    {
        if (_trayIcon is null || _model is null)
        {
            return;
        }

        var previousIcon = _trayIcon.Icon;
        _trayIcon.Icon = TrayIconRenderer.Render(_model.TrayGlyph, _model.ActiveAgentCount);
        previousIcon?.Dispose();

        _trayIcon.ToolTipText = $"{_model.TrayText} — {_model.TrayAccessibilityLabel}";
    }

    protected override void OnExit(ExitEventArgs e)
    {
        if (_model is not null)
        {
            _model.PropertyChanged -= OnModelPropertyChanged;
            _model.Dispose();
        }

        _trayIcon?.Dispose();

        // Windows releases the power request when the process ends, so quitting
        // always restores normal sleep. Only the lid-close action would persist.
        _powerService?.Dispose();
        _lidSensor?.Dispose();

        base.OnExit(e);
    }
}
