//! Celeris — the package root (`@import("celeris")`).
//!
//!   * `framework` — the API for building apps in Zig: components, widgets,
//!     signals, theming, windows (`fw.runApp`). Start here; see docs/FRAMEWORK_API.md.
//!   * `c_api` — the C-ABI functions declared in include/celeris.h, callable from
//!     Zig too (headless engines, host-style integrations, tests).
//!   * `internal` — the engine's own modules (node registry, property store, layout
//!     solver, renderer, text). Exposed for tooling and advanced use; NOT covered by
//!     any stability promise and may change in any release.

const std = @import("std");

pub const framework = @import("framework.zig");
pub const c_api = @import("c_api.zig");

pub const internal = struct {
    pub const registry = @import("core/registry.zig");
    pub const properties = @import("core/properties.zig");
    pub const path = @import("core/path.zig");
    pub const signals = @import("core/signals.zig");
    pub const accessibility = @import("core/accessibility.zig");
    pub const events = @import("core/events.zig");
    pub const layout = @import("layout/flexbox.zig");
    pub const renderer = @import("render/renderer.zig");
    pub const text = @import("render/text.zig");
    pub const linebreak = @import("render/linebreak.zig");
};

// Force every `export fn` in c_api into the shared library's export table. Zig
// only emits exports from the root file automatically; functions in an imported
// file (c_api.zig) need an explicit reference here, or the .dll/.so ships with
// no C-ABI symbols (the examples link the engine statically and never noticed).
comptime {
    @setEvalBranchQuota(20000);
    for (@typeInfo(c_api).@"struct".decls) |decl| {
        if (@typeInfo(@TypeOf(@field(c_api, decl.name))) == .@"fn") {
            _ = &@field(c_api, decl.name);
        }
    }
}

test {
    _ = internal.registry;
    _ = internal.properties;
    _ = internal.path;
    _ = @import("core/prop_parse.zig");
    _ = internal.signals;
    _ = internal.accessibility;
    _ = @import("framework/component.zig");
    _ = @import("framework/events.zig");
    _ = internal.layout;
    _ = internal.renderer;
    _ = internal.text;
    _ = internal.linebreak;
    _ = framework;
    _ = @import("framework/verification_test.zig");
    _ = @import("framework/testkit_test.zig");
    _ = @import("platform/xdg_portal.zig");
    _ = @import("platform/keysym.zig");
    if (@import("builtin").os.tag == .windows) _ = @import("platform/uia_test.zig");
    _ = @import("c_api.zig");
}
