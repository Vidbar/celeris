// Excludes the GIF decoder (stbi__gif_load_next / stbi__load_gif_main) from
// the compiled build. Two unpatched CVEs (heap overflow / UAF-double-free,
// both in GIF-specific code, vendor unresponsive to disclosure) affect every
// released version of stb_image up to and including this vendored 2.30 — the
// latest available; there is no newer release to update to. Celeris only
// ever calls stbi_load() for a single static texture per node (getOrLoadTexture
// in wgpu_backend.zig); nothing in the codebase or assets/ loads a .gif. This
// removes the vulnerable code paths from the binary entirely rather than
// leaving them compiled in and unreachable-by-convention — the strongest
// mitigation available while no upstream fix exists.
#define STBI_NO_GIF
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
