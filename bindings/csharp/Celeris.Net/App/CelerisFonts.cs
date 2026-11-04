using System;
using System.Runtime.InteropServices;
using Celeris.Interop;

namespace Celeris.App;

/// <summary>
/// The app's typefaces. Without this the primary face is whatever the host's font
/// scan turns up first, so the same app has a different typographic voice on every
/// machine. Set it once, before the first <see cref="CelerisApp"/> is constructed:
/// the font atlas is built when the engine starts and is not re-based afterwards.
/// </summary>
/// <remarks>
/// Only <c>primary</c> is required — it is the face the whole UI is set in. The role
/// faces are optional and follow Material's reading of a type system (one family
/// carrying every role): supplying the primary alone is a complete answer, and
/// bold/mono text then degrades to it rather than mixing in an unrelated host face.
/// </remarks>
public static class CelerisFonts
{
    /// <summary>Registers the faces used by every window opened afterwards. The
    /// native side copies the bytes, so the arrays may be collected on return.</summary>
    /// <exception cref="InvalidOperationException">The native copy failed (OOM);
    /// the previously registered set is kept.</exception>
    public static void Set(byte[] primary, byte[]? bold = null, byte[]? mono = null, byte[]? monoBold = null)
    {
        ArgumentNullException.ThrowIfNull(primary);

        var handles = new GCHandle[4];
        var faces = new CelerisFontFace[4];
        var arrays = new[] { primary, bold, mono, monoBold };
        try
        {
            for (int i = 0; i < arrays.Length; i++)
            {
                var bytes = arrays[i];
                if (bytes is null || bytes.Length == 0) continue;
                handles[i] = GCHandle.Alloc(bytes, GCHandleType.Pinned);
                faces[i] = new CelerisFontFace
                {
                    Data = handles[i].AddrOfPinnedObject(),
                    Len = (nuint)bytes.Length,
                };
            }

            var config = new CelerisFontConfig
            {
                Primary = faces[0],
                Bold = faces[1],
                Mono = faces[2],
                MonoBold = faces[3],
            };
            if (CelerisInterop.celeris_set_app_fonts(ref config) != 0)
                throw new InvalidOperationException("celeris_set_app_fonts failed (out of memory).");
        }
        finally
        {
            foreach (var h in handles)
                if (h.IsAllocated) h.Free();
        }
    }

    /// <summary>Clears back to the engine's OS font discovery.</summary>
    public static void Clear()
    {
        var config = default(CelerisFontConfig);
        CelerisInterop.celeris_set_app_fonts(ref config);
    }
}
