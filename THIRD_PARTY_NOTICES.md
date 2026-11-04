# Third-party notices

Celeris itself is MIT-licensed (see `LICENSE`). It vendors the following
third-party components under `vendor/`, each under its own license. The full
license text ships next to each component and is included in the Zig package.

| Component | Version | License | Where | License file |
|---|---|---|---|---|
| [HarfBuzz](https://github.com/harfbuzz/harfbuzz) | 14.2.1 | "Old MIT" | `vendor/harfbuzz/` (compiled into the engine) | `vendor/harfbuzz/COPYING` |
| [wgpu-native](https://github.com/gfx-rs/wgpu-native) | v22.1.0.5 | MIT OR Apache-2.0 | `vendor/wgpu-native/` (prebuilt `.dll`/`.lib`/`.so`, headers) | `vendor/wgpu-native/LICENSE.MIT`, `vendor/wgpu-native/LICENSE.APACHE` |
| [stb_truetype](https://github.com/nothings/stb) | 1.26 | Public domain OR MIT | `vendor/stb_truetype.h` | end of the header |
| [stb_image](https://github.com/nothings/stb) | 2.30 | Public domain OR MIT | `vendor/stb_image.h` | end of the header |
| [Codicons](https://github.com/microsoft/vscode-codicons) (font) | 1.15 (font version) | CC BY 4.0 | `vendor/codicons/codicon.ttf` (embedded into the engine) | `vendor/codicons/LICENSE` |

## What this means for apps built with Celeris

- **wgpu-native**: if you ship `wgpu_native.dll` / `libwgpu_native.so` with your
  app (which `addRuntimeDeps` does), include its MIT (or Apache-2.0) notice.
- **HarfBuzz**: compiled into your binary; include its copyright notice and the
  two disclaimer paragraphs from `vendor/harfbuzz/COPYING`.
- **Codicons**: the icon font is embedded in every Celeris binary; CC BY 4.0
  requires attribution, e.g. "Icons: Codicons © Microsoft, CC BY 4.0".
- **stb**: no obligation (public-domain option).

Celeris does not bundle a UI text font: at runtime it loads a system font
(Segoe UI on Windows, DejaVu/Liberation on Linux) unless the app supplies its
own typefaces.
