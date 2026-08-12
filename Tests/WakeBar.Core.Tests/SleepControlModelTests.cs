using WakeBar.Core;

namespace WakeBar.Core.Tests;

public class SleepControlModelTests
{
    private static readonly DateTimeOffset Origin = new(2026, 8, 12, 9, 0, 0, TimeSpan.Zero);

    private static SleepControlModel CreateModel(
        FakePowerService power,
        FakeAgentDetector detector,
        WakePolicyMode mode = WakePolicyMode.Automatic,
        IPreferences? preferences = null)
    {
        preferences ??= new InMemoryPreferences();
        preferences.SetString(SleepControlModel.PolicyPreferenceKey, mode.PreferenceValue());
        return new SleepControlModel(power, detector, new UnsupportedLidSensor(), preferences);
    }

    [Fact]
    public async Task Automatic_blocks_sleep_when_an_agent_becomes_active()
    {
        var power = new FakePowerService();
        var detector = new FakeAgentDetector();
        using var model = CreateModel(power, detector);

        detector.ReportActive(Origin, TestAgents.Codex());
        await model.PollAgentActivityAsync(Origin);

        Assert.True(power.SleepPreventionEnabled);
        Assert.Equal(SleepPreventionState.Enabled, model.State);
        Assert.Equal(1, model.ActiveAgentCount);
    }

    [Fact]
    public async Task Automatic_holds_the_lock_through_the_grace_window()
    {
        var power = new FakePowerService();
        var detector = new FakeAgentDetector();
        using var model = CreateModel(power, detector);

        detector.ReportActive(Origin, TestAgents.Codex());
        await model.PollAgentActivityAsync(Origin);

        detector.ReportIdle(Origin);
        await model.PollAgentActivityAsync(Origin.AddSeconds(30));

        Assert.True(model.IsHoldingAutoGrace);
        Assert.True(power.SleepPreventionEnabled);
        Assert.Equal(0, model.ActiveAgentCount);
    }

    [Fact]
    public async Task Automatic_restores_sleep_after_the_grace_window_expires()
    {
        var power = new FakePowerService();
        var detector = new FakeAgentDetector();
        using var model = CreateModel(power, detector);

        detector.ReportActive(Origin, TestAgents.Codex());
        await model.PollAgentActivityAsync(Origin);

        detector.ReportIdle(Origin);
        await model.PollAgentActivityAsync(Origin.AddSeconds(91));

        Assert.False(model.IsHoldingAutoGrace);
        Assert.False(power.SleepPreventionEnabled);
        Assert.Equal(SleepPreventionState.Disabled, model.State);
    }

    [Fact]
    public async Task A_failed_scan_never_releases_an_active_lock()
    {
        var power = new FakePowerService();
        var detector = new FakeAgentDetector();
        using var model = CreateModel(power, detector);

        detector.ReportActive(Origin, TestAgents.Codex());
        await model.PollAgentActivityAsync(Origin);

        detector.ReportScanFailure(Origin);
        await model.PollAgentActivityAsync(Origin.AddSeconds(200));

        Assert.True(power.SleepPreventionEnabled);
        Assert.False(model.AgentDetectorAvailable);
        Assert.Equal(1, model.ActiveAgentCount);
    }

    [Fact]
    public async Task An_inconclusive_empty_scan_never_releases_an_active_lock()
    {
        var power = new FakePowerService();
        var detector = new FakeAgentDetector();
        using var model = CreateModel(power, detector);

        detector.ReportActive(Origin, TestAgents.Codex());
        await model.PollAgentActivityAsync(Origin);

        detector.ReportInconclusive(Origin);
        await model.PollAgentActivityAsync(Origin.AddSeconds(200));

        Assert.True(power.SleepPreventionEnabled);
        Assert.False(model.AgentScanConclusive);
    }

    [Fact]
    public async Task Off_releases_the_lock_and_still_reports_active_agents()
    {
        var power = new FakePowerService { SleepPreventionEnabled = true };
        var detector = new FakeAgentDetector();
        using var model = CreateModel(power, detector);

        detector.ReportActive(Origin, TestAgents.Codex(), TestAgents.Claude());
        await model.PollAgentActivityAsync(Origin);

        await model.ApplyPolicyModeAsync(WakePolicyMode.Off);

        Assert.False(power.SleepPreventionEnabled);
        Assert.True(model.HasAgentsWhileOff);
        Assert.Equal(2, model.ActiveAgentCount);
        Assert.Equal(TrayGlyph.UnprotectedAgents, model.TrayGlyph);
    }

    [Fact]
    public async Task On_blocks_sleep_with_no_agents_present()
    {
        var power = new FakePowerService();
        var detector = new FakeAgentDetector();
        using var model = CreateModel(power, detector, WakePolicyMode.Off);

        await model.ApplyPolicyModeAsync(WakePolicyMode.On);

        Assert.True(power.SleepPreventionEnabled);
        Assert.Equal(TrayGlyph.Locked, model.TrayGlyph);
    }

    [Fact]
    public async Task A_write_that_does_not_take_effect_surfaces_a_failure()
    {
        var power = new FakePowerService { IgnoreWrites = true };
        var detector = new FakeAgentDetector();
        using var model = CreateModel(power, detector, WakePolicyMode.Off);

        await model.ApplyPolicyModeAsync(WakePolicyMode.On);

        Assert.IsType<InlineNotice.Failure>(model.Notice);
        Assert.Equal(SleepPreventionState.Disabled, model.State);
    }

    [Fact]
    public async Task An_unreadable_power_state_marks_the_service_unavailable()
    {
        var power = new FakePowerService
        {
            ThrowOnRead = new PowerServiceException(PowerServiceFault.UnexpectedOutput)
        };
        var detector = new FakeAgentDetector();
        using var model = CreateModel(power, detector);

        await model.RefreshAsync();

        Assert.Equal(SleepPreventionState.Unavailable, model.State);
        Assert.IsType<InlineNotice.Failure>(model.Notice);
    }

    [Fact]
    public async Task The_selected_mode_persists_across_instances()
    {
        var preferences = new InMemoryPreferences();
        var power = new FakePowerService();
        var detector = new FakeAgentDetector();

        using (var model = CreateModel(power, detector, WakePolicyMode.Automatic, preferences))
        {
            await model.ApplyPolicyModeAsync(WakePolicyMode.On);
        }

        using var reloaded = new SleepControlModel(
            new FakePowerService(),
            new FakeAgentDetector(),
            new UnsupportedLidSensor(),
            preferences);

        Assert.Equal(WakePolicyMode.On, reloaded.PolicyMode);
    }

    [Theory]
    [InlineData(WakePolicyMode.Off, 0, "OFF")]
    [InlineData(WakePolicyMode.Off, 2, "OFF · 2")]
    [InlineData(WakePolicyMode.Automatic, 0, "AUTO")]
    [InlineData(WakePolicyMode.Automatic, 3, "AUTO · 3")]
    [InlineData(WakePolicyMode.On, 1, "ON")]
    public async Task Tray_text_matches_the_macOS_menu_bar_wording(
        WakePolicyMode mode,
        int agentCount,
        string expected)
    {
        var power = new FakePowerService();
        var detector = new FakeAgentDetector();
        using var model = CreateModel(power, detector, mode);

        var agents = Enumerable.Range(0, agentCount)
            .Select(index => TestAgents.Codex(1000 + index))
            .ToArray();
        detector.ReportActive(Origin, agents);
        await model.PollAgentActivityAsync(Origin);

        Assert.Equal(expected, model.TrayText);
    }

    [Fact]
    public async Task A_mismatch_between_policy_and_system_state_is_surfaced()
    {
        var power = new FakePowerService();
        var detector = new FakeAgentDetector();
        using var model = CreateModel(power, detector, WakePolicyMode.On);

        await model.ApplyPolicyModeAsync(WakePolicyMode.On);
        Assert.True(model.PolicyMatchesSystemState);

        // Something outside WakeBar clears the lock.
        power.SleepPreventionEnabled = false;
        detector.ReportIdle(Origin);
        await model.PollAgentActivityAsync(Origin);

        Assert.True(power.SleepPreventionEnabled);
    }
}
