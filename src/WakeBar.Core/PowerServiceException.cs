namespace WakeBar.Core;

public enum PowerServiceFault
{
    RequestRejected,
    CommandFailed,
    UnexpectedOutput,
    InstantAuthorizationRequired,
    InstantAuthorizationUnavailable,
    AuthorizationCancelled,
    AuthorizationFailed,
    VerificationFailed,
    Unsupported
}

public sealed class PowerServiceException : Exception
{
    public PowerServiceException(PowerServiceFault fault, string? detail = null)
        : base(detail is { Length: > 0 } ? detail : DefaultMessage(fault))
    {
        Fault = fault;
    }

    public PowerServiceFault Fault { get; }

    private static string DefaultMessage(PowerServiceFault fault) => fault switch
    {
        PowerServiceFault.RequestRejected =>
            "Windows refused WakeBar's request to stay awake.",
        PowerServiceFault.CommandFailed =>
            "Windows couldn't update the sleep setting.",
        PowerServiceFault.UnexpectedOutput =>
            "Windows returned an unrecognized power setting.",
        PowerServiceFault.InstantAuthorizationRequired =>
            "Closed-lid protection needs its one-time administrator setup.",
        PowerServiceFault.InstantAuthorizationUnavailable =>
            "WakeBar couldn't verify its lid-close permission.",
        PowerServiceFault.AuthorizationCancelled =>
            "Nothing was changed.",
        PowerServiceFault.AuthorizationFailed =>
            "The one-time administrator setup could not be completed.",
        PowerServiceFault.VerificationFailed =>
            "Windows did not apply the requested sleep setting.",
        PowerServiceFault.Unsupported =>
            "This device does not support that power feature.",
        _ => "WakeBar couldn't read the system sleep setting."
    };
}
