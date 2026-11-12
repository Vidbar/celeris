const std = @import("std");

/// Applies the include paths, native libraries, and C/C++ sources every Celeris
/// artifact needs, onto a module. Single source of truth for the dependency set.
fn linkNativeDeps(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    mod.addIncludePath(b.path("vendor"));
    mod.addIncludePath(b.path("vendor/wgpu-native/include/webgpu"));
    mod.addIncludePath(b.path("vendor/wgpu-native/include/wgpu"));

    switch (target.result.os.tag) {
        .windows => {
            mod.addLibraryPath(b.path("vendor/wgpu-native/lib"));
            mod.linkSystemLibrary("wgpu_native", .{});
            mod.linkSystemLibrary("user32", .{});
            mod.linkSystemLibrary("gdi32", .{});
            mod.linkSystemLibrary("kernel32", .{});
            mod.linkSystemLibrary("comdlg32", .{}); // GetOpenFileNameW / GetSaveFileNameW
            mod.linkSystemLibrary("ole32", .{}); // IFileOpenDialog (folder picker) + CoTaskMemFree
            mod.linkSystemLibrary("imm32", .{}); // IME composition (WM_IME_*)
            mod.linkSystemLibrary("dwmapi", .{}); // window corner preference (Win11)
        },
        .linux => {
            const libdir = b.path("vendor/wgpu-native/linux-x86_64/lib");
            mod.addLibraryPath(libdir);
            mod.addRPath(libdir);
            mod.linkSystemLibrary("wgpu_native", .{});
            // Wayland windowing backend (platform/linux.zig).
            mod.addIncludePath(.{ .cwd_relative = "/usr/include/libdecor-0" });
            mod.linkSystemLibrary("wayland-client", .{});
            mod.linkSystemLibrary("wayland-cursor", .{});
            mod.linkSystemLibrary("xkbcommon", .{});
            mod.linkSystemLibrary("decor-0", .{});
            // IME: generate the zwp_text_input_v3 client glue with wayland-scanner
            // (the protocol isn't in wayland-client core).
            const ti_xml = "/usr/share/wayland-protocols/unstable/text-input/text-input-unstable-v3.xml";
            const ti_code = b.addSystemCommand(&.{ "wayland-scanner", "private-code", ti_xml });
            const ti_c = ti_code.addOutputFileArg("text-input-unstable-v3-protocol.c");
            const ti_header = b.addSystemCommand(&.{ "wayland-scanner", "client-header", ti_xml });
            const ti_h = ti_header.addOutputFileArg("text-input-unstable-v3-client-protocol.h");
            mod.addCSourceFile(.{ .file = ti_c, .flags = &.{} });
            mod.addIncludePath(ti_h.dirname());
        },
        else => {},
    }

    mod.addCSourceFile(.{ .file = b.path("vendor/stb_truetype_impl.c"), .flags = &.{} });
    mod.addCSourceFile(.{ .file = b.path("vendor/stb_image_impl.c"), .flags = &.{} });

    // HarfBuzz (text shaping) — vendored amalgamation, C++.
    mod.addIncludePath(b.path("vendor/harfbuzz/src"));
    mod.addCSourceFile(.{ .file = b.path("vendor/harfbuzz/src/harfbuzz.cc"), .flags = &.{"-std=c++17"} });
}

/// Wires the wgpu runtime library into a consumer's build so apps run without
/// manual DLL copying. Call from the consumer's build.zig after creating the
/// exe and its run step:
///
///     const celeris = b.dependency("celeris", .{ .target = target, .optimize = optimize });
///     exe.root_module.addImport("celeris", celeris.module("celeris"));
///     @import("celeris").addRuntimeDeps(b, celeris, exe, run);
///
/// Windows: installs wgpu_native.dll next to the exe (zig-out/bin) and puts it
/// on the run step's PATH. Linux: the vendored .so + rpath already handle it,
/// but the .so is installed too so zig-out/bin stays self-contained.
/// `run` is optional — pass null if you only install.
pub fn addRuntimeDeps(
    b: *std.Build,
    dep: *std.Build.Dependency,
    exe: *std.Build.Step.Compile,
    run: ?*std.Build.Step.Run,
) void {
    switch (exe.rootModuleTarget().os.tag) {
        .windows => {
            const dll = dep.path("vendor/wgpu-native/lib/wgpu_native.dll");
            b.getInstallStep().dependOn(&b.addInstallBinFile(dll, "wgpu_native.dll").step);
            if (run) |r| r.addPathDir(dep.path("vendor/wgpu-native/lib").getPath(b));
        },
        .linux => {
            const so = dep.path("vendor/wgpu-native/linux-x86_64/lib/libwgpu_native.so");
            b.getInstallStep().dependOn(&b.addInstallBinFile(so, "libwgpu_native.so").step);
        },
        else => {},
    }
}

const ExampleApp = struct {
    name: []const u8,
    root: []const u8,
    step: []const u8,
    desc: []const u8,
};

const example_apps = [_]ExampleApp{
    .{ .name = "headless_test", .root = "examples/headless_test.zig", .step = "headless", .desc = "Run the headless C-API smoke test (no GPU window)" },
    .{ .name = "dashboard", .root = "examples/dashboard.zig", .step = "dashboard", .desc = "Run the dashboard example (every widget, reactive component model)" },
    .{ .name = "counter", .root = "examples/counter.zig", .step = "counter", .desc = "Run the canonical counter example (new component/signal model) — pinned verbatim in docs/FRAMEWORK_API.md" },
    .{ .name = "devtools", .root = "src/devtools/inspector.zig", .step = "devtools", .desc = "Run the DevTools inspector (inspects a second engine live)" },
    .{ .name = "thread_test", .root = "examples/thread_test.zig", .step = "thread_test", .desc = "Test background threads and celeris_post_task" },
    .{ .name = "tree_bench", .root = "examples/tree_bench.zig", .step = "tree_bench", .desc = "Large virtualized TreeView for re-measuring bake/render cost" },
    .{ .name = "titlebar_proto", .root = "examples/titlebar_proto.zig", .step = "titlebar_proto", .desc = "App-composed custom window caption via the app_bar slot" },
    .{ .name = "restyle_inspector", .root = "examples/restyle_inspector.zig", .step = "restyle_inspector", .desc = "Live editable style inspector" },
    .{ .name = "property_panel", .root = "examples/property_panel.zig", .step = "property_panel", .desc = "Key/value property panel recipe (DevTools inspector pane) — referenced in docs/FRAMEWORK_API.md" },
    .{ .name = "replay_evidence", .root = "examples/replay_evidence.zig", .step = "replay_evidence", .desc = "Session replay with per-frame evidence + repo link, plus a steppable execution trace with breakpoints" },
    .{ .name = "overlay_bar", .root = "examples/overlay_bar.zig", .step = "overlay_bar", .desc = "Always-on-top secondary window with its own component tree" },
    .{ .name = "fuzz_api", .root = "examples/fuzz_api.zig", .step = "fuzz_api", .desc = "Adversarial C-API smoke test (invalid handles, bad UTF-8, NaN, cycles)" },
    .{ .name = "perf_bench", .root = "examples/perf_bench.zig", .step = "perf_bench", .desc = "Headless build+layout throughput bench (no window; unattended)" },
    .{ .name = "uia_showcase", .root = "examples/uia_showcase.zig", .step = "uia_showcase", .desc = "Widgets exercising UIA action patterns (Invoke/Toggle/Value/Expand/Selection) for Inspect.exe/NVDA validation" },
    .{ .name = "path_demo", .root = "examples/path_demo.zig", .step = "path_demo", .desc = "NodeType.path visual check: diagonal / cubic / elbow / connection / closed triangle at 3 scales" },
    .{ .name = "resize_list", .root = "examples/resize_list.zig", .step = "resize_list", .desc = "on_resize: full-window VirtualList(fill) that tracks the window height" },
    .{ .name = "window_edge", .root = "examples/window_edge.zig", .step = "window_edge", .desc = "Manual check: .round + window_outline shows one continuous edge, no white strip" },
    .{ .name = "virtual_grid", .root = "examples/virtual_grid.zig", .step = "virtual_grid", .desc = "VirtualGrid: 100k x 40 windowed grid over a pull source, frozen header, keyboard cell nav" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Opt-in zone profiler (src/core/profiler.zig). Off by default so release
    // builds carry zero instrumentation; `zig build -Dprofiling ...` turns it on.
    // At runtime it still does nothing until the host sets CELERIS_TRACE.
    const profiling = b.option(bool, "profiling", "Compile in the zone profiler (Chrome Trace export)") orelse false;
    const build_opts = b.addOptions();
    build_opts.addOption(bool, "profiling", profiling);

    // ─── Engine module shared by all executables ──────────────────────────────
    const m_engine = b.addModule("celeris", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    m_engine.addOptions("build_options", build_opts);
    // Codicons icon font (CC BY 4.0), embedded into the binary — icons are PUA
    // glyphs rendered through the normal text stack, no runtime asset needed.
    m_engine.addAnonymousImport("codicon_ttf", .{ .root_source_file = b.path("vendor/codicons/codicon.ttf") });
    linkNativeDeps(b, m_engine, target);

    // ─── Shared library (celeris.dll) ─────────────────────────────────────────
    const lib = b.addLibrary(.{
        .name = "celeris",
        .root_module = m_engine,
        .linkage = .dynamic,
    });
    b.installArtifact(lib);

    // Ship the C-ABI header next to the library so host bindings have the contract.
    b.installFile("include/celeris.h", "include/celeris.h");

    // Ship the wgpu_native runtime DLL next to the installed binaries so the
    // Windows loader finds it via the executable's directory. (Windows only —
    // Linux links libwgpu_native.so via rpath from the vendored .so.)
    if (target.result.os.tag == .windows) {
        b.installBinFile("vendor/wgpu-native/lib/wgpu_native.dll", "wgpu_native.dll");
    }

    // For a distributable bundle the runtime .so sits next to the executable.
    if (target.result.os.tag == .linux) m_engine.addRPath(.{ .cwd_relative = "$ORIGIN" });

    // ─── Distribution bundle ───────────────────────────────────────────────────
    // `zig build dist` produces a self-contained, runnable zig-out/bin: the
    // example executables + the wgpu runtime lib, co-located. Zip zig-out/bin and ship it.
    const dist_step = b.step("dist", "Build a self-contained runnable bundle in zig-out/bin");
    switch (target.result.os.tag) {
        .windows => dist_step.dependOn(&b.addInstallBinFile(b.path("vendor/wgpu-native/lib/wgpu_native.dll"), "wgpu_native.dll").step),
        .linux => dist_step.dependOn(&b.addInstallBinFile(b.path("vendor/wgpu-native/linux-x86_64/lib/libwgpu_native.so"), "libwgpu_native.so").step),
        else => {},
    }

    // ─── Example / tool executables ───────────────────────────────────────────
    const examples_step = b.step("examples", "Compile all example executables without running them");
    for (example_apps) |app| {
        const exe_mod = b.createModule(.{
            .root_source_file = b.path(app.root),
            .target = target,
            .optimize = optimize,
        });
        exe_mod.addImport("celeris", m_engine);
        const exe = b.addExecutable(.{ .name = app.name, .root_module = exe_mod });
        examples_step.dependOn(&exe.step);
        dist_step.dependOn(&b.addInstallArtifact(exe, .{}).step);

        const run = b.addRunArtifact(exe);
        run.step.dependOn(b.getInstallStep());
        // The child process needs wgpu_native.dll on its search path.
        run.addPathDir("vendor/wgpu-native/lib");
        b.step(app.step, app.desc).dependOn(&run.step);
    }

    // ─── fuzz_api as a test gate, always in Debug ──────────────────────────────
    // `zig build test` should catch what fuzz_api catches (three real defects —
    // a crash and two leaks — came out of one manual run of it) without anyone
    // remembering to run it separately. Leak detection specifically needs
    // Debug: `EngineGpa` in c_api.zig picks a DebugAllocator vs. release's
    // `std.heap.c_allocator` off the *module's own* comptime `optimize`, so a
    // fuzz binary built through the top-level `-Doptimize` flag would silently
    // stop catching leaks the moment someone ran `zig build test -Doptimize=
    // ReleaseFast`. A second engine module pinned to `.Debug` keeps the gate
    // meaningful regardless of what flag the rest of the build used.
    const m_engine_debug = b.createModule(.{ // build-internal; not offered to dependents
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
        .link_libcpp = true,
    });
    m_engine_debug.addOptions("build_options", build_opts);
    m_engine_debug.addAnonymousImport("codicon_ttf", .{ .root_source_file = b.path("vendor/codicons/codicon.ttf") });
    linkNativeDeps(b, m_engine_debug, target);

    const fuzz_api_gate_mod = b.createModule(.{
        .root_source_file = b.path("examples/fuzz_api.zig"),
        .target = target,
        .optimize = .Debug,
    });
    fuzz_api_gate_mod.addImport("celeris", m_engine_debug);
    const fuzz_api_gate_exe = b.addExecutable(.{ .name = "fuzz_api_ci", .root_module = fuzz_api_gate_mod });
    const run_fuzz_api_gate = b.addRunArtifact(fuzz_api_gate_exe);
    run_fuzz_api_gate.step.dependOn(b.getInstallStep());
    run_fuzz_api_gate.addPathDir("vendor/wgpu-native/lib");

    // ─── Unit tests ───────────────────────────────────────────────────────────
    const tf = b.option([]const u8, "tf", "test filter") orelse "";
    const main_tests = b.addTest(.{ .root_module = m_engine, .filters = if (tf.len > 0) &.{tf} else &.{} });
    const run_main_tests = b.addRunArtifact(main_tests);
    run_main_tests.addPathDir("vendor/wgpu-native/lib");

    const fmt_step = b.addFmt(.{
        .paths = &.{ "src", "examples", "build.zig" },
    });
    const check_fmt = b.addFmt(.{
        .paths = &.{ "src", "examples", "build.zig" },
        .check = true,
    });
    b.step("fmt", "Format all source files").dependOn(&fmt_step.step);

    // ─── C host smoke test ─────────────────────────────────────────────────────
    // A plain C program built against include/celeris.h and linked to the shared
    // library: fails the build if the header stops compiling, declares a symbol
    // the library doesn't export, or the string-keyed property surface regresses.
    const c_smoke_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    c_smoke_mod.addCSourceFile(.{ .file = b.path("examples/c_smoke.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    c_smoke_mod.addIncludePath(b.path("include"));
    c_smoke_mod.linkLibrary(lib);
    const c_smoke_exe = b.addExecutable(.{ .name = "c_smoke", .root_module = c_smoke_mod });
    const run_c_smoke = b.addRunArtifact(c_smoke_exe);
    run_c_smoke.addPathDir("vendor/wgpu-native/lib");
    run_c_smoke.expectExitCode(0);

    // ─── Docs guard: the Quick Start snippet must match examples/counter.zig ─────
    const doc_check_exe = b.addExecutable(.{ .name = "doc_snippet_check", .root_module = b.createModule(.{
        .root_source_file = b.path("examples/doc_snippet_check.zig"),
        .target = b.graph.host,
    }) });
    const run_doc_check = b.addRunArtifact(doc_check_exe);
    run_doc_check.addFileArg(b.path("docs/FRAMEWORK_API.md"));
    run_doc_check.addFileArg(b.path("examples/counter.zig"));
    run_doc_check.expectExitCode(0);

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_doc_check.step);
    test_step.dependOn(&run_main_tests.step);
    test_step.dependOn(&run_c_smoke.step);
    test_step.dependOn(&run_fuzz_api_gate.step);
    test_step.dependOn(&check_fmt.step);
}
