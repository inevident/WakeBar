using WakeBar.Core;

namespace WakeBar.Core.Tests;

public class LidClosureDetectorTests
{
    [Fact]
    public void A_single_closed_reading_is_not_enough()
    {
        var detector = new LidClosureDetector();

        detector.Observe(LidPosition.Open);

        Assert.False(detector.Observe(LidPosition.Closed));
        Assert.False(detector.IsClosed);
    }

    [Fact]
    public void Two_consecutive_closed_readings_confirm_a_closure()
    {
        var detector = new LidClosureDetector();

        detector.Observe(LidPosition.Open);
        detector.Observe(LidPosition.Closed);

        Assert.True(detector.Observe(LidPosition.Closed));
        Assert.True(detector.IsClosed);
    }

    [Fact]
    public void Staying_closed_only_counts_once()
    {
        var detector = new LidClosureDetector();

        detector.Observe(LidPosition.Open);
        detector.Observe(LidPosition.Closed);
        Assert.True(detector.Observe(LidPosition.Closed));

        Assert.False(detector.Observe(LidPosition.Closed));
        Assert.False(detector.Observe(LidPosition.Closed));
    }

    [Fact]
    public void Starting_already_closed_does_not_count()
    {
        var detector = new LidClosureDetector();

        detector.Observe(LidPosition.Closed);

        Assert.False(detector.Observe(LidPosition.Closed));
        Assert.True(detector.IsClosed);
    }

    [Fact]
    public void Reopening_allows_the_next_closure_to_count()
    {
        var detector = new LidClosureDetector();

        detector.Observe(LidPosition.Open);
        detector.Observe(LidPosition.Closed);
        Assert.True(detector.Observe(LidPosition.Closed));

        detector.Observe(LidPosition.Open);
        detector.Observe(LidPosition.Closed);

        Assert.True(detector.Observe(LidPosition.Closed));
    }

    [Fact]
    public void Unknown_readings_interrupt_confirmation()
    {
        var detector = new LidClosureDetector();

        detector.Observe(LidPosition.Open);
        detector.Observe(LidPosition.Closed);
        detector.Observe(LidPosition.Unknown);

        Assert.False(detector.Observe(LidPosition.Closed));
    }

    [Fact]
    public void Sustained_unknown_readings_reset_the_detector()
    {
        var detector = new LidClosureDetector();

        detector.Observe(LidPosition.Open);
        detector.Observe(LidPosition.Closed);
        detector.Observe(LidPosition.Closed);
        Assert.True(detector.IsClosed);

        for (var index = 0; index < LidClosureDetector.InvalidSamplesBeforeReset; index++)
        {
            detector.Observe(LidPosition.Unknown);
        }

        Assert.False(detector.IsClosed);
    }
}
