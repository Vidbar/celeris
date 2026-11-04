pub const builder = @import("framework/builder.zig");
pub const application = @import("framework/application.zig");
pub const runApp = application.runApp;
/// Native OS file dialogs (open / save / pick-folder), window-scoped.
pub const dialogs = application.dialogs;
/// Window controls: the `runApp`-owned window (the escape hatch for apps that set
/// `hide_app_bar` and mount their own title bar), plus `window.open` for a second
/// window with its own component tree.
pub const window = application.window;
pub const WindowOptions = application.WindowOptions;
pub const WindowHandle = application.WindowHandle;
pub const Placement = application.Placement;
/// Window geometry in logical px, as returned by `window.bounds()` / `workArea()`.
pub const Rect = @import("platform/platform.zig").Rect;
pub const CornerPreference = @import("platform/platform.zig").CornerPreference;
pub const ThemeSource = application.ThemeSource;
/// A secondary window bound to a signal — the declarative form of `window.open`.
pub const overlay_window = @import("framework/overlay_window.zig");
pub const OverlayWindow = overlay_window.OverlayWindow;
pub const signals = @import("core/signals.zig");
/// Vertex type for `NodeType.path` nodes (`b.path(...)`). See `core/path.zig`.
pub const PathVertex = @import("core/path.zig").PathVertex;
pub const component = @import("framework/component.zig");
pub const events = @import("framework/events.zig");
pub const scroll_view = @import("framework/scroll_view.zig");
pub const virtual_list = @import("framework/virtual_list.zig");
pub const virtual_grid = @import("framework/virtual_grid.zig");
pub const VirtualGrid = virtual_grid.VirtualGrid;
pub const CellCoord = virtual_grid.CellCoord;
pub const CellRange = virtual_grid.CellRange;
pub const progress = @import("framework/progress.zig");
pub const tooltip = @import("framework/tooltip.zig");
pub const toast = @import("framework/toast.zig");
pub const tree_list = @import("framework/tree_list.zig");
pub const text_input = @import("framework/text_input.zig");
pub const theme = @import("framework/theme.zig");
pub const color = @import("core/color.zig");
pub const tonal_palette = @import("core/tonal_palette.zig");
pub const color_scheme = @import("framework/color_scheme.zig");
pub const tree_view = @import("framework/tree_view.zig");
pub const split_pane = @import("framework/split_pane.zig");
pub const tabs = @import("framework/tabs.zig");
pub const stack = @import("framework/stack.zig");
pub const grid = @import("framework/grid.zig");
pub const text_area = @import("framework/text_area.zig");
pub const button = @import("framework/button.zig");
pub const icon_button = @import("framework/icon_button.zig");
/// Helpers for testing YOUR widgets and apps headlessly: find nodes by role or
/// name, click, type, and assert on the same accessibility tree screen readers see.
pub const testkit = @import("framework/testkit.zig");
pub const icons = @import("framework/icons.zig");
pub const checkbox = @import("framework/checkbox.zig");
pub const radio = @import("framework/radio.zig");
pub const radio_group = @import("framework/radio_group.zig");
pub const slider = @import("framework/slider.zig");
pub const dropdown = @import("framework/dropdown.zig");
pub const dialog = @import("framework/dialog.zig");
/// Turns the engine's routine stderr diagnostics on or off (off by default;
/// `CELERIS_LOG` also enables them). Warnings are always printed.
pub const setVerboseLogging = @import("core/log.zig").setVerbose;
pub const menu = @import("framework/menu.zig");
pub const app_bar = @import("framework/app_bar.zig");
pub const window_chrome = @import("framework/window_chrome.zig");
pub const bottom_bar = @import("framework/bottom_bar.zig");
pub const status_bar = @import("framework/status_bar.zig");

test {
    // Force analysis of every framework module so their unit tests are
    // discovered by the test runner.
    @import("std").testing.refAllDecls(@This());
}

/// A property value (color, dimension, keyword, …) — what `signals.bindStyle` /
/// `bindLayout` signals carry.
pub const PropValue = @import("core/properties.zig").PropValue;
pub const Window = @import("framework/window.zig").Window;
