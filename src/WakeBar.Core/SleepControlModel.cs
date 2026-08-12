using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace WakeBar.Core;

public enum TrayGlyph
{
    Mismatch,
    UnprotectedAgents,
    Sleeping,
    Locked,
    Degraded,
    Working,
    Grace,
    Watching
}

public sealed class SleepControlOptions
{
    public TimeSpan ReleaseGracePeriod { get; init; } = TimeSpan.FromSeconds(90);

    public TimeSpan MonitorInterval { get; init; } = TimeSpan.FromSeconds(5);

    public TimeSpan LidMonitorInterval { get; init; } = TimeSpan.FromMilliseconds(250);

    public TimeSpan SystemVerificationInterval { get; init; } = TimeSpan.FromSeconds(20);
}

/// <summary>
/// The OFF / AUTO / ON state machine. Ported from SleepControlModel.swift; all
/// platform behavior stays behind <see cref="IPowerService"/>,
/// <see cref="IAgentActivityDetector"/>, and <see cref="ILidSensor"/> so this type
/// is exercisable without touching the host machine.
/// </summary>
public sealed class SleepControlModel : ObservableObject, IDisposable
{
    public const string PolicyPreferenceKey = "wakebar.policy-mode";
    public const string LifetimeWakeSessionPreferenceKey = "wakebar.lifetime-protected-lid-closure-count";

    private readonly IPowerService _powerService;
    private readonly IAgentActivityDetector _agentDetector;
    private readonly ILidSensor _lidSensor;
    private readonly IPreferences _preferences;
    private readonly SleepControlOptions _options;
    private readonly LidClosureDetector _lidClosureDetector = new();

    private CancellationTokenSource? _monitorCancellation;
    private CancellationTokenSource? _lidMonitorCancellation;
    private Task? _monitorTask;
    private Task? _lidMonitorTask;
    private DateTimeOffset? _lastActiveAt;
    private DateTimeOffset? _lastSystemVerificationAt;
    private ulong _operationRevision;
    private bool _disposed;

    private SleepPreventionState _state = SleepPreventionState.Loading;
    private WakePolicyMode _policyMode;
    private int _lifetimeWakeSessionCount;
    private bool _isLidClosed;
    private InstantControlState _lidControlState = InstantControlState.Checking;
    private PowerSnapshot _powerSnapshot = PowerSnapshot.Unknown;
    private IReadOnlyList<AgentActivity> _agentActivities = Array.Empty<AgentActivity>();
    private bool _isHoldingAutoGrace;
    private bool _agentDetectorAvailable = true;
    private bool _agentScanConclusive = true;
    private DateTimeOffset? _lastAgentScanAt;
    private bool _isChanging;
    private InlineNotice? _notice;

    public SleepControlModel(
        IPowerService powerService,
        IAgentActivityDetector? agentDetector = null,
        ILidSensor? lidSensor = null,
        IPreferences? preferences = null,
        SleepControlOptions? options = null)
    {
        _powerService = powerService;
        _agentDetector = agentDetector ?? new NullAgentActivityDetector();
        _lidSensor = lidSensor ?? new UnsupportedLidSensor();
        _preferences = preferences ?? new InMemoryPreferences();
        _options = options ?? new SleepControlOptions();

        _lifetimeWakeSessionCount = Math.Max(0, _preferences.GetInt(LifetimeWakeSessionPreferenceKey));
        if (_preferences.GetInt(LifetimeWakeSessionPreferenceKey) < 0)
        {
            _preferences.SetInt(LifetimeWakeSessionPreferenceKey, 0);
        }

        _policyMode = WakePolicyModeExtensions
            .FromPreferenceValue(_preferences.GetString(PolicyPreferenceKey))
            ?? WakePolicyMode.Automatic;

        SelectModeCommand = new AsyncRelayCommand<WakePolicyMode>(RequestPolicyModeAsync);
        RetryCommand = new AsyncRelayCommand(RetryAsync);
        SetUpLidControlCommand = new AsyncRelayCommand(RequestLidControlSetupAsync);
        RemoveLidControlCommand = new AsyncRelayCommand(RequestLidControlRemovalAsync);
        DismissNoticeCommand = new RelayCommand(DismissNotice);
    }

    public IAsyncRelayCommand<WakePolicyMode> SelectModeCommand { get; }

    public IAsyncRelayCommand RetryCommand { get; }

    public IAsyncRelayCommand SetUpLidControlCommand { get; }

    public IAsyncRelayCommand RemoveLidControlCommand { get; }

    public IRelayCommand DismissNoticeCommand { get; }

    public SleepPreventionState State
    {
        get => _state;
        private set
        {
            if (SetProperty(ref _state, value))
            {
                RaiseDerivedChanged();
            }
        }
    }

    public WakePolicyMode PolicyMode
    {
        get => _policyMode;
        private set
        {
            if (SetProperty(ref _policyMode, value))
            {
                RaiseDerivedChanged();
            }
        }
    }

    public int LifetimeWakeSessionCount
    {
        get => _lifetimeWakeSessionCount;
        private set => SetProperty(ref _lifetimeWakeSessionCount, value);
    }

    public bool IsLidClosed
    {
        get => _isLidClosed;
        private set => SetProperty(ref _isLidClosed, value);
    }

    public InstantControlState LidControlState
    {
        get => _lidControlState;
        private set => SetProperty(ref _lidControlState, value);
    }

    public PowerSnapshot PowerSnapshot
    {
        get => _powerSnapshot;
        private set => SetProperty(ref _powerSnapshot, value);
    }

    public IReadOnlyList<AgentActivity> AgentActivities
    {
        get => _agentActivities;
        private set
        {
            if (SetProperty(ref _agentActivities, value))
            {
                RaiseDerivedChanged();
            }
        }
    }

    public bool IsHoldingAutoGrace
    {
        get => _isHoldingAutoGrace;
        private set
        {
            if (SetProperty(ref _isHoldingAutoGrace, value))
            {
                RaiseDerivedChanged();
            }
        }
    }

    public bool AgentDetectorAvailable
    {
        get => _agentDetectorAvailable;
        private set
        {
            if (SetProperty(ref _agentDetectorAvailable, value))
            {
                RaiseDerivedChanged();
            }
        }
    }

    public bool AgentScanConclusive
    {
        get => _agentScanConclusive;
        private set
        {
            if (SetProperty(ref _agentScanConclusive, value))
            {
                RaiseDerivedChanged();
            }
        }
    }

    public DateTimeOffset? LastAgentScanAt
    {
        get => _lastAgentScanAt;
        private set => SetProperty(ref _lastAgentScanAt, value);
    }

    public bool IsChanging
    {
        get => _isChanging;
        private set
        {
            if (SetProperty(ref _isChanging, value))
            {
                OnPropertyChanged(nameof(CanSelectMode));
            }
        }
    }

    public InlineNotice? Notice
    {
        get => _notice;
        private set => SetProperty(ref _notice, value);
    }

    public bool IsEnabled => State == SleepPreventionState.Enabled;

    public bool CanSelectMode => !IsChanging && State != SleepPreventionState.Loading;

    public bool EffectiveAgentActivity => AgentActivities.Count > 0 || IsHoldingAutoGrace;

    public int ActiveAgentCount => AgentActivities.Count;

    public bool HasAgentsWhileOff => PolicyMode == WakePolicyMode.Off && ActiveAgentCount > 0;

    public bool DesiredSleepPrevention => PolicyMode switch
    {
        WakePolicyMode.Off => false,
        WakePolicyMode.Automatic => EffectiveAgentActivity,
        WakePolicyMode.On => true,
        _ => false
    };

    public bool PolicyMatchesSystemState => State switch
    {
        SleepPreventionState.Enabled or SleepPreventionState.Disabled => DesiredSleepPrevention == IsEnabled,
        _ => false
    };

    /// <summary>
    /// Windows tray icons carry no text label, so this is rendered into the icon
    /// bitmap rather than displayed beside it the way macOS does.
    /// </summary>
    public string TrayText => PolicyMode switch
    {
        WakePolicyMode.Off => ActiveAgentCount > 0 ? $"OFF · {ActiveAgentCount}" : "OFF",
        WakePolicyMode.On => "ON",
        _ => ActiveAgentCount > 0 ? $"AUTO · {ActiveAgentCount}" : "AUTO"
    };

    public TrayGlyph TrayGlyph
    {
        get
        {
            if (State is not SleepPreventionState.Loading
                and not SleepPreventionState.Unavailable
                && !PolicyMatchesSystemState)
            {
                return TrayGlyph.Mismatch;
            }

            return PolicyMode switch
            {
                WakePolicyMode.Off when HasAgentsWhileOff => TrayGlyph.UnprotectedAgents,
                WakePolicyMode.Off => TrayGlyph.Sleeping,
                WakePolicyMode.On => TrayGlyph.Locked,
                WakePolicyMode.Automatic when !AgentDetectorAvailable || !AgentScanConclusive => TrayGlyph.Degraded,
                WakePolicyMode.Automatic when ActiveAgentCount > 0 => TrayGlyph.Working,
                WakePolicyMode.Automatic when IsHoldingAutoGrace => TrayGlyph.Grace,
                _ => TrayGlyph.Watching
            };
        }
    }

    public string TrayAccessibilityLabel
    {
        get
        {
            if (State is not SleepPreventionState.Loading
                and not SleepPreventionState.Unavailable
                && !PolicyMatchesSystemState)
            {
                return $"WakeBar {PolicyMode.Title().ToLowerInvariant()} selected, but the system sleep lock has not been applied";
            }

            return PolicyMode switch
            {
                WakePolicyMode.Off when ActiveAgentCount == 1 =>
                    "WakeBar off, 1 active agent is unprotected and Windows may sleep",
                WakePolicyMode.Off when ActiveAgentCount > 1 =>
                    $"WakeBar off, {ActiveAgentCount} active agents are unprotected and Windows may sleep",
                WakePolicyMode.Off =>
                    "WakeBar off, automatic system sleep enabled",
                WakePolicyMode.On =>
                    "WakeBar on, system sleep blocked",
                WakePolicyMode.Automatic when !AgentDetectorAvailable || !AgentScanConclusive =>
                    "WakeBar automatic, activity scan interrupted, preserving the last safe state",
                WakePolicyMode.Automatic when ActiveAgentCount > 0 =>
                    $"WakeBar automatic, {ActiveAgentCount} active agents, system sleep blocked",
                WakePolicyMode.Automatic when IsHoldingAutoGrace =>
                    "WakeBar automatic, finishing a safety window before restoring system sleep",
                _ => "WakeBar automatic, watching for active agents"
            };
        }
    }

    public void StartMonitoring()
    {
        if (_monitorTask is not null)
        {
            return;
        }

        StartLidMonitoringIfNeeded();

        _monitorCancellation = new CancellationTokenSource();
        var token = _monitorCancellation.Token;
        _monitorTask = Task.Run(async () =>
        {
            await RefreshAsync().ConfigureAwait(false);
            await PollAgentActivityAsync(DateTimeOffset.Now).ConfigureAwait(false);

            while (!token.IsCancellationRequested)
            {
                try
                {
                    await Task.Delay(_options.MonitorInterval, token).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    break;
                }

                if (token.IsCancellationRequested)
                {
                    break;
                }

                await PollAgentActivityAsync(DateTimeOffset.Now).ConfigureAwait(false);
            }
        }, token);
    }

    public async Task RefreshAsync()
    {
        if (IsChanging)
        {
            return;
        }

        var revision = _operationRevision;

        var lidAvailability = await SafeGetLidAvailabilityAsync().ConfigureAwait(false);
        if (IsChanging || _operationRevision != revision)
        {
            return;
        }

        LidControlState = lidAvailability switch
        {
            LidControlAvailability.Ready => InstantControlState.Ready,
            LidControlAvailability.SetupRequired => InstantControlState.SetupRequired,
            _ => InstantControlState.Unsupported
        };

        PowerSnapshot refreshedPower;
        try
        {
            refreshedPower = await _powerService.GetPowerSnapshotAsync().ConfigureAwait(false);
        }
        catch
        {
            refreshedPower = PowerSnapshot.Unknown;
        }

        if (IsChanging || _operationRevision != revision)
        {
            return;
        }

        PowerSnapshot = refreshedPower;
        await LoadStateAsync(State == SleepPreventionState.Unavailable, revision).ConfigureAwait(false);

        if (IsChanging || _operationRevision != revision)
        {
            return;
        }

        if (PolicyMode != WakePolicyMode.Automatic)
        {
            await ReconcilePolicyWithoutPromptAsync().ConfigureAwait(false);
        }
    }

    public async Task PollAgentActivityAsync(DateTimeOffset now)
    {
        if (IsChanging)
        {
            return;
        }

        AgentScanSnapshot snapshot;
        try
        {
            snapshot = await _agentDetector.ScanAsync(now).ConfigureAwait(false);
        }
        catch
        {
            snapshot = AgentScanSnapshot.Failed(now);
        }

        await VerifyPhysicalStateIfNeededAsync(now).ConfigureAwait(false);

        if (IsChanging)
        {
            return;
        }

        LastAgentScanAt = snapshot.ScannedAt;
        AgentDetectorAvailable = snapshot.ProcessScanSucceeded;
        AgentScanConclusive = snapshot.ScanWasConclusive;

        // A failed or inconclusive empty scan must never release an active lock.
        if (!snapshot.ProcessScanSucceeded
            || (!snapshot.ScanWasConclusive && snapshot.Activities.Count == 0))
        {
            if (PolicyMode != WakePolicyMode.Automatic || DesiredSleepPrevention)
            {
                await ReconcilePolicyWithoutPromptAsync().ConfigureAwait(false);
            }

            return;
        }

        if (snapshot.Activities.Count > 0)
        {
            AgentActivities = snapshot.Activities;
            _lastActiveAt = now;
            IsHoldingAutoGrace = false;
        }
        else if (_lastActiveAt is { } lastActiveAt && now - lastActiveAt < _options.ReleaseGracePeriod)
        {
            AgentActivities = Array.Empty<AgentActivity>();
            IsHoldingAutoGrace = true;
        }
        else
        {
            AgentActivities = Array.Empty<AgentActivity>();
            IsHoldingAutoGrace = false;
            _lastActiveAt = null;
        }

        await ReconcilePolicyWithoutPromptAsync().ConfigureAwait(false);
    }

    public async Task PollLidAsync()
    {
        var position = await SafeReadLidAsync().ConfigureAwait(false);
        await ObserveLidAsync(position).ConfigureAwait(false);
    }

    public Task RequestPolicyModeAsync(WakePolicyMode mode)
    {
        if (IsChanging)
        {
            return Task.CompletedTask;
        }

        if (mode == PolicyMode)
        {
            var physicalStateMatches = State != SleepPreventionState.Loading
                && State != SleepPreventionState.Unavailable
                && DesiredSleepPrevention == IsEnabled;
            var automaticSetupMissing = mode == WakePolicyMode.Automatic
                && LidControlState == InstantControlState.SetupRequired;

            if (physicalStateMatches && !automaticSetupMissing)
            {
                return Task.CompletedTask;
            }
        }

        PolicyMode = mode;
        _preferences.SetString(PolicyPreferenceKey, mode.PreferenceValue());
        UpdateLidMonitoringForPolicy();

        return RunOperationAsync(() => PerformApplyPolicyModeAsync(mode));
    }

    public Task RequestLidControlSetupAsync()
    {
        if (IsChanging || LidControlState == InstantControlState.Unsupported)
        {
            return Task.CompletedTask;
        }

        return RunOperationAsync(PerformConfigureLidControlAsync);
    }

    public Task RequestLidControlRemovalAsync()
    {
        if (IsChanging || LidControlState == InstantControlState.Unsupported)
        {
            return Task.CompletedTask;
        }

        PolicyMode = WakePolicyMode.Off;
        _preferences.SetString(PolicyPreferenceKey, WakePolicyMode.Off.PreferenceValue());
        UpdateLidMonitoringForPolicy();

        return RunOperationAsync(PerformRemoveLidControlAsync);
    }

    public async Task RetryAsync()
    {
        if (Notice is not InlineNotice.Failure)
        {
            return;
        }

        if (State != SleepPreventionState.Unavailable
            && LidControlState == InstantControlState.SetupRequired)
        {
            await RequestLidControlSetupAsync().ConfigureAwait(false);
            return;
        }

        await RefreshAsync().ConfigureAwait(false);
        await PollAgentActivityAsync(DateTimeOffset.Now).ConfigureAwait(false);
    }

    public void DismissNotice() => Notice = null;

    public async Task ApplyPolicyModeAsync(WakePolicyMode mode)
    {
        if (IsChanging)
        {
            return;
        }

        unchecked
        {
            _operationRevision++;
        }

        IsChanging = true;
        try
        {
            await PerformApplyPolicyModeAsync(mode).ConfigureAwait(false);
        }
        finally
        {
            IsChanging = false;
        }
    }

    private async Task PerformApplyPolicyModeAsync(WakePolicyMode mode)
    {
        PolicyMode = mode;
        _preferences.SetString(PolicyPreferenceKey, mode.PreferenceValue());
        UpdateLidMonitoringForPolicy();
        Notice = null;

        try
        {
            if (mode == WakePolicyMode.Automatic && LidControlState == InstantControlState.SetupRequired)
            {
                LidControlState = InstantControlState.Installing;
                await _powerService.InstallLidControlAsync().ConfigureAwait(false);
                LidControlState = InstantControlState.Ready;
            }

            await ApplySystemStateIfNeededAsync(DesiredSleepPrevention).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            await RecoverStateAsync(error).ConfigureAwait(false);
        }
    }

    private async Task ReconcilePolicyWithoutPromptAsync()
    {
        if (IsChanging)
        {
            return;
        }

        var desired = DesiredSleepPrevention;

        if (State == SleepPreventionState.Enabled && desired)
        {
            return;
        }

        if (State == SleepPreventionState.Disabled && !desired)
        {
            return;
        }

        unchecked
        {
            _operationRevision++;
        }

        IsChanging = true;
        try
        {
            await ApplySystemStateIfNeededAsync(desired).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            await RecoverStateAsync(error).ConfigureAwait(false);
        }
        finally
        {
            IsChanging = false;
        }
    }

    private async Task ApplySystemStateIfNeededAsync(bool enabled)
    {
        // Read immediately before deciding to write so an external change cannot be
        // mistaken for a new WakeBar protection session.
        var currentValue = await _powerService.GetSleepPreventionStateAsync().ConfigureAwait(false);
        State = currentValue ? SleepPreventionState.Enabled : SleepPreventionState.Disabled;

        if (enabled == currentValue)
        {
            return;
        }

        await _powerService.SetSleepPreventionAsync(enabled).ConfigureAwait(false);

        var verifiedValue = await _powerService.GetSleepPreventionStateAsync().ConfigureAwait(false);
        if (verifiedValue != enabled)
        {
            throw new PowerServiceException(PowerServiceFault.VerificationFailed);
        }

        State = enabled ? SleepPreventionState.Enabled : SleepPreventionState.Disabled;

        try
        {
            PowerSnapshot = await _powerService.GetPowerSnapshotAsync().ConfigureAwait(false);
        }
        catch
        {
            // Keep the previous snapshot; it is display metadata only.
        }

        Notice = null;
    }

    private async Task PerformConfigureLidControlAsync()
    {
        LidControlState = InstantControlState.Installing;
        Notice = null;

        try
        {
            await _powerService.InstallLidControlAsync().ConfigureAwait(false);
            LidControlState = InstantControlState.Ready;
            await ApplySystemStateIfNeededAsync(DesiredSleepPrevention).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            LidControlState = InstantControlState.SetupRequired;
            SetNotice(error);
        }
    }

    private async Task PerformRemoveLidControlAsync()
    {
        LidControlState = InstantControlState.Installing;
        Notice = null;

        try
        {
            await _powerService.RemoveLidControlAsync().ConfigureAwait(false);
            LidControlState = InstantControlState.SetupRequired;

            var verifiedValue = await _powerService.GetSleepPreventionStateAsync().ConfigureAwait(false);
            if (verifiedValue)
            {
                throw new PowerServiceException(PowerServiceFault.VerificationFailed);
            }

            State = SleepPreventionState.Disabled;
        }
        catch (Exception error)
        {
            var availability = await SafeGetLidAvailabilityAsync().ConfigureAwait(false);
            LidControlState = availability switch
            {
                LidControlAvailability.Ready => InstantControlState.Ready,
                LidControlAvailability.SetupRequired => InstantControlState.SetupRequired,
                _ => InstantControlState.Unsupported
            };

            await RecoverStateAsync(error).ConfigureAwait(false);
        }
    }

    private async Task RunOperationAsync(Func<Task> operation)
    {
        if (IsChanging)
        {
            return;
        }

        unchecked
        {
            _operationRevision++;
        }

        IsChanging = true;
        try
        {
            await operation().ConfigureAwait(false);
        }
        finally
        {
            IsChanging = false;
        }
    }

    private async Task LoadStateAsync(bool showLoading, ulong expectedOperationRevision)
    {
        if (showLoading)
        {
            State = SleepPreventionState.Loading;
        }

        try
        {
            var enabled = await _powerService.GetSleepPreventionStateAsync().ConfigureAwait(false);
            if (IsChanging || _operationRevision != expectedOperationRevision)
            {
                return;
            }

            State = enabled ? SleepPreventionState.Enabled : SleepPreventionState.Disabled;
        }
        catch (Exception error)
        {
            if (IsChanging || _operationRevision != expectedOperationRevision)
            {
                return;
            }

            State = SleepPreventionState.Unavailable;
            Notice = new InlineNotice.Failure(UserFacingMessage(error));
        }
    }

    private async Task VerifyPhysicalStateIfNeededAsync(DateTimeOffset now)
    {
        if (_lastSystemVerificationAt is { } lastVerification)
        {
            var elapsed = now - lastVerification;
            if (elapsed >= TimeSpan.Zero && elapsed < _options.SystemVerificationInterval)
            {
                return;
            }
        }

        var revision = _operationRevision;
        try
        {
            var enabled = await _powerService.GetSleepPreventionStateAsync().ConfigureAwait(false);
            if (IsChanging || _operationRevision != revision)
            {
                return;
            }

            State = enabled ? SleepPreventionState.Enabled : SleepPreventionState.Disabled;
            _lastSystemVerificationAt = now;
        }
        catch (Exception error)
        {
            if (IsChanging || _operationRevision != revision)
            {
                return;
            }

            State = SleepPreventionState.Unavailable;
            _lastSystemVerificationAt = now;
            Notice = new InlineNotice.Failure(UserFacingMessage(error));
        }
    }

    private async Task RecoverStateAsync(Exception error)
    {
        try
        {
            var currentValue = await _powerService.GetSleepPreventionStateAsync().ConfigureAwait(false);
            State = currentValue ? SleepPreventionState.Enabled : SleepPreventionState.Disabled;
        }
        catch
        {
            State = SleepPreventionState.Unavailable;
        }

        if (error is PowerServiceException { Fault: PowerServiceFault.InstantAuthorizationRequired
            or PowerServiceFault.InstantAuthorizationUnavailable
            or PowerServiceFault.AuthorizationCancelled
            or PowerServiceFault.AuthorizationFailed })
        {
            LidControlState = InstantControlState.SetupRequired;
        }

        SetNotice(error);
    }

    private void UpdateLidMonitoringForPolicy()
    {
        if (PolicyMode == WakePolicyMode.Automatic)
        {
            StartLidMonitoringIfNeeded();
        }
        else
        {
            StopLidMonitoring();
        }
    }

    private void StartLidMonitoringIfNeeded()
    {
        if (!_lidSensor.IsSupported
            || PolicyMode != WakePolicyMode.Automatic
            || _lidMonitorTask is not null)
        {
            return;
        }

        _lidMonitorCancellation = new CancellationTokenSource();
        var token = _lidMonitorCancellation.Token;
        _lidMonitorTask = Task.Run(async () =>
        {
            while (!token.IsCancellationRequested)
            {
                var position = await SafeReadLidAsync(token).ConfigureAwait(false);
                if (token.IsCancellationRequested)
                {
                    break;
                }

                await ObserveLidAsync(position).ConfigureAwait(false);

                try
                {
                    await Task.Delay(_options.LidMonitorInterval, token).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    break;
                }
            }

            await _lidSensor.StopAsync().ConfigureAwait(false);
        }, token);
    }

    private void StopLidMonitoring()
    {
        _lidMonitorCancellation?.Cancel();
        _lidMonitorCancellation?.Dispose();
        _lidMonitorCancellation = null;
        _lidMonitorTask = null;
        _lidClosureDetector.Reset();
        IsLidClosed = false;
    }

    private async Task ObserveLidAsync(LidPosition position)
    {
        if (PolicyMode != WakePolicyMode.Automatic)
        {
            IsLidClosed = false;
            return;
        }

        var didClose = _lidClosureDetector.Observe(position);
        IsLidClosed = _lidClosureDetector.IsClosed;

        if (!didClose
            || ActiveAgentCount == 0
            || IsChanging
            || LifetimeWakeSessionCount == int.MaxValue)
        {
            return;
        }

        var revision = _operationRevision;
        bool physicallyEnabled;
        try
        {
            physicallyEnabled = await _powerService.GetSleepPreventionStateAsync().ConfigureAwait(false);
        }
        catch
        {
            return;
        }

        if (IsChanging || _operationRevision != revision)
        {
            return;
        }

        State = physicallyEnabled ? SleepPreventionState.Enabled : SleepPreventionState.Disabled;

        if (!physicallyEnabled
            || PolicyMode != WakePolicyMode.Automatic
            || ActiveAgentCount == 0
            || !PolicyMatchesSystemState
            || LifetimeWakeSessionCount == int.MaxValue)
        {
            return;
        }

        LifetimeWakeSessionCount++;
        _preferences.SetInt(LifetimeWakeSessionPreferenceKey, LifetimeWakeSessionCount);
    }

    private async Task<LidPosition> SafeReadLidAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            return await _lidSensor.ReadPositionAsync(cancellationToken).ConfigureAwait(false);
        }
        catch
        {
            return LidPosition.Unknown;
        }
    }

    private async Task<LidControlAvailability> SafeGetLidAvailabilityAsync()
    {
        try
        {
            return await _powerService.GetLidControlAvailabilityAsync().ConfigureAwait(false);
        }
        catch
        {
            return LidControlAvailability.Unsupported;
        }
    }

    private void SetNotice(Exception error)
    {
        Notice = error is PowerServiceException { Fault: PowerServiceFault.AuthorizationCancelled }
            ? new InlineNotice.Cancelled()
            : new InlineNotice.Failure(UserFacingMessage(error));
    }

    private static string UserFacingMessage(Exception error) =>
        error is PowerServiceException ? error.Message : "WakeBar couldn't read the system sleep setting.";

    private void RaiseDerivedChanged()
    {
        OnPropertyChanged(nameof(IsEnabled));
        OnPropertyChanged(nameof(CanSelectMode));
        OnPropertyChanged(nameof(EffectiveAgentActivity));
        OnPropertyChanged(nameof(ActiveAgentCount));
        OnPropertyChanged(nameof(HasAgentsWhileOff));
        OnPropertyChanged(nameof(DesiredSleepPrevention));
        OnPropertyChanged(nameof(PolicyMatchesSystemState));
        OnPropertyChanged(nameof(TrayText));
        OnPropertyChanged(nameof(TrayGlyph));
        OnPropertyChanged(nameof(TrayAccessibilityLabel));
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _monitorCancellation?.Cancel();
        _monitorCancellation?.Dispose();
        _monitorCancellation = null;
        _monitorTask = null;
        StopLidMonitoring();
    }
}
