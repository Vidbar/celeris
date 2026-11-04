using System.Runtime.InteropServices;

namespace Celeris.Interop;

/// <summary>Raised when a native Celeris call reports failure (-1).</summary>
public sealed class CelerisException(string message) : Exception(message);

internal static class Native
{
    /// <summary>The engine's reason for the most recent failure, or "" if none.</summary>
    public static string LastError() => Marshal.PtrToStringUTF8(CelerisInterop.celeris_last_error()) ?? "";

    /// <summary>Throws a <see cref="CelerisException"/> when <paramref name="rc"/> is negative,
    /// naming the call and the engine's own reason, so a typo'd key or a bad value fails
    /// loudly instead of silently leaving the node unstyled.</summary>
    public static int Check(int rc, string call)
    {
        if (rc >= 0) return rc;
        var reason = LastError();
        throw new CelerisException(reason.Length > 0 ? $"{call} failed: {reason}" : $"{call} failed");
    }
}
