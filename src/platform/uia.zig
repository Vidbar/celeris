const std = @import("std");
const windows = std.os.windows;
const HWND = windows.HWND;
pub const HRESULT = i32;
pub const S_OK: HRESULT = 0;
pub const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
pub const E_INVALIDARG: HRESULT = @bitCast(@as(u32, 0x80070057));
const WINAPI = std.builtin.CallingConvention.winapi;
const BSTR = ?*u16; // String type for COM

const reg = @import("../core/registry.zig");
const props = @import("../core/properties.zig");
const a11y = @import("../core/accessibility.zig");

// --- COM Basics ---
pub const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,
    pub fn eql(self: *const GUID, other: *const GUID) bool {
        return std.mem.eql(u8, std.mem.asBytes(self), std.mem.asBytes(other));
    }
};

const IID_IUnknown = GUID{ .Data1 = 0x00000000, .Data2 = 0x0000, .Data3 = 0x0000, .Data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 } };
const IID_IRawElementProviderSimple = GUID{ .Data1 = 0xd6dd68d1, .Data2 = 0x86fd, .Data3 = 0x4332, .Data4 = .{ 0x86, 0x66, 0x9a, 0xbe, 0xde, 0xa2, 0xd2, 0x4c } };
const IID_IRawElementProviderFragment = GUID{ .Data1 = 0xf7063da8, .Data2 = 0x8359, .Data3 = 0x439c, .Data4 = .{ 0x92, 0x97, 0xbb, 0xc5, 0x29, 0x9a, 0x7d, 0x87 } };
const IID_IRawElementProviderFragmentRoot = GUID{ .Data1 = 0x620ce2a5, .Data2 = 0xab8f, .Data3 = 0x40a9, .Data4 = .{ 0x86, 0xcb, 0xde, 0x3c, 0x75, 0x59, 0x9b, 0x58 } };
const IID_IInvokeProvider = GUID{ .Data1 = 0x54fcb24b, .Data2 = 0xe18e, .Data3 = 0x47a2, .Data4 = .{ 0xb4, 0xd3, 0xec, 0xcb, 0xe7, 0x75, 0x99, 0xa2 } };
const IID_IToggleProvider = GUID{ .Data1 = 0x56d00bd0, .Data2 = 0xc4f4, .Data3 = 0x433c, .Data4 = .{ 0xa8, 0x36, 0x1a, 0x52, 0xa5, 0x7e, 0x08, 0x92 } };
const IID_IValueProvider = GUID{ .Data1 = 0xc7935180, .Data2 = 0x6fb3, .Data3 = 0x4201, .Data4 = .{ 0xb1, 0x74, 0x7d, 0xf7, 0x3a, 0xdb, 0xf6, 0x4a } };
const IID_IExpandCollapseProvider = GUID{ .Data1 = 0xd847d3a5, .Data2 = 0xcab0, .Data3 = 0x4a98, .Data4 = .{ 0x8c, 0x32, 0xec, 0xb4, 0x5c, 0x59, 0xad, 0x24 } };
const IID_ISelectionItemProvider = GUID{ .Data1 = 0x2acad808, .Data2 = 0xb2d4, .Data3 = 0x452d, .Data4 = .{ 0xa4, 0x07, 0x91, 0xff, 0x1a, 0xd1, 0x67, 0xb2 } };

pub const IUnknown = extern struct {
    vtbl: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const fn (self: *IUnknown, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
        AddRef: *const fn (self: *IUnknown) callconv(WINAPI) u32,
        Release: *const fn (self: *IUnknown) callconv(WINAPI) u32,
    };
};

// --- UIA Enums ---
pub const ProviderOptions = enum(i32) {
    ClientSideProvider = 0x0001,
    ServerSideProvider = 0x0002,
    NonClientAreaProvider = 0x0004,
    OverrideProvider = 0x0008,
    ProviderOwnsSetFocus = 0x0010,
    UseComThreading = 0x0020,
};

pub const NavigateDirection = enum(i32) {
    Parent = 0,
    NextSibling = 1,
    PreviousSibling = 2,
    FirstChild = 3,
    LastChild = 4,
};

// --- SysAllocString ---
extern "oleaut32" fn SysAllocString(str: [*:0]const u16) callconv(WINAPI) BSTR;
pub extern "oleaut32" fn SysFreeString(bstr: BSTR) callconv(WINAPI) void;
extern "oleaut32" fn SysStringLen(bstr: BSTR) callconv(WINAPI) u32;

// --- VARIANT ---
pub const VARTYPE = u16;
pub const VT_EMPTY: VARTYPE = 0;
pub const VT_I4: VARTYPE = 3;
pub const VT_BSTR: VARTYPE = 8;
pub const VT_BOOL: VARTYPE = 11;
pub const VT_UNKNOWN: VARTYPE = 13;

pub const VARIANT = extern struct {
    vt: VARTYPE,
    wReserved1: u16 = 0,
    wReserved2: u16 = 0,
    wReserved3: u16 = 0,
    u: extern union {
        lVal: i32,
        bVal: u8,
        iVal: i16,
        fltVal: f32,
        dblVal: f64,
        boolVal: i16,
        bstrVal: BSTR,
        punkVal: ?*IUnknown,
        padding: [8]u8,
    },
};

extern "oleaut32" fn VariantInit(pvarg: *VARIANT) callconv(WINAPI) void;
extern "oleaut32" fn VariantClear(pvarg: *VARIANT) callconv(WINAPI) HRESULT;

/// A VT_I4 VARIANT (ToggleState / ExpandCollapseState travel as their enum int).
pub fn variantI4(v: i32) VARIANT {
    return .{ .vt = VT_I4, .u = .{ .lVal = v } };
}
/// A VT_BOOL VARIANT (VARIANT_TRUE is -1, not 1 — the Win32 convention).
pub fn variantBool(v: bool) VARIANT {
    return .{ .vt = VT_BOOL, .u = .{ .boolVal = if (v) -1 else 0 } };
}
/// A VT_BSTR VARIANT owning a fresh BSTR copy of `text`. The caller (or the raise
/// helper it is handed to) must free it with `SysFreeString`. Returns VT_EMPTY if
/// the UTF-16 conversion fails, so a bad string degrades to "no value" not a crash.
pub fn variantBStr(text: []const u8) VARIANT {
    var buf: [1024]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], text) catch return .{ .vt = VT_EMPTY, .u = .{ .padding = [_]u8{0} ** 8 } };
    buf[n] = 0;
    return .{ .vt = VT_BSTR, .u = .{ .bstrVal = SysAllocString(@ptrCast(&buf)) } };
}

// --- UIA Interfaces ---
pub const IRawElementProviderSimple = extern struct {
    vtbl: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const fn (self: *IRawElementProviderSimple, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
        AddRef: *const fn (self: *IRawElementProviderSimple) callconv(WINAPI) u32,
        Release: *const fn (self: *IRawElementProviderSimple) callconv(WINAPI) u32,
        get_ProviderOptions: *const fn (self: *IRawElementProviderSimple, pRetVal: *ProviderOptions) callconv(WINAPI) HRESULT,
        GetPatternProvider: *const fn (self: *IRawElementProviderSimple, patternId: i32, pRetVal: *?*IUnknown) callconv(WINAPI) HRESULT,
        GetPropertyValue: *const fn (self: *IRawElementProviderSimple, propertyId: i32, pRetVal: *VARIANT) callconv(WINAPI) HRESULT,
        get_HostRawElementProvider: *const fn (self: *IRawElementProviderSimple, pRetVal: *?*IRawElementProviderSimple) callconv(WINAPI) HRESULT,
    };
};

pub const IRawElementProviderFragment = extern struct {
    vtbl: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const fn (self: *IRawElementProviderFragment, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
        AddRef: *const fn (self: *IRawElementProviderFragment) callconv(WINAPI) u32,
        Release: *const fn (self: *IRawElementProviderFragment) callconv(WINAPI) u32,
        Navigate: *const fn (self: *IRawElementProviderFragment, direction: NavigateDirection, pRetVal: *?*IRawElementProviderFragment) callconv(WINAPI) HRESULT,
        GetRuntimeId: *const fn (self: *IRawElementProviderFragment, pRetVal: *?*anyopaque) callconv(WINAPI) HRESULT,
        get_BoundingRectangle: *const fn (self: *IRawElementProviderFragment, pRetVal: *[4]f64) callconv(WINAPI) HRESULT,
        GetEmbeddedFragmentRoots: *const fn (self: *IRawElementProviderFragment, pRetVal: *?*anyopaque) callconv(WINAPI) HRESULT,
        SetFocus: *const fn (self: *IRawElementProviderFragment) callconv(WINAPI) HRESULT,
        get_FragmentRoot: *const fn (self: *IRawElementProviderFragment, pRetVal: *?*IRawElementProviderFragmentRoot) callconv(WINAPI) HRESULT,
    };
};

pub const IRawElementProviderFragmentRoot = extern struct {
    vtbl: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const fn (self: *IRawElementProviderFragmentRoot, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
        AddRef: *const fn (self: *IRawElementProviderFragmentRoot) callconv(WINAPI) u32,
        Release: *const fn (self: *IRawElementProviderFragmentRoot) callconv(WINAPI) u32,
        ElementProviderFromPoint: *const fn (self: *IRawElementProviderFragmentRoot, x: f64, y: f64, pRetVal: *?*IRawElementProviderFragment) callconv(WINAPI) HRESULT,
        GetFocus: *const fn (self: *IRawElementProviderFragmentRoot, pRetVal: *?*IRawElementProviderFragment) callconv(WINAPI) HRESULT,
    };
};

pub const IInvokeProvider = extern struct {
    vtbl: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const fn (self: *IInvokeProvider, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
        AddRef: *const fn (self: *IInvokeProvider) callconv(WINAPI) u32,
        Release: *const fn (self: *IInvokeProvider) callconv(WINAPI) u32,
        Invoke: *const fn (self: *IInvokeProvider) callconv(WINAPI) HRESULT,
    };
};

pub const IToggleProvider = extern struct {
    vtbl: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const fn (self: *IToggleProvider, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
        AddRef: *const fn (self: *IToggleProvider) callconv(WINAPI) u32,
        Release: *const fn (self: *IToggleProvider) callconv(WINAPI) u32,
        Toggle: *const fn (self: *IToggleProvider) callconv(WINAPI) HRESULT,
        get_ToggleState: *const fn (self: *IToggleProvider, pRetVal: *ToggleState) callconv(WINAPI) HRESULT,
    };
};

pub const IValueProvider = extern struct {
    vtbl: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const fn (self: *IValueProvider, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
        AddRef: *const fn (self: *IValueProvider) callconv(WINAPI) u32,
        Release: *const fn (self: *IValueProvider) callconv(WINAPI) u32,
        SetValue: *const fn (self: *IValueProvider, val: BSTR) callconv(WINAPI) HRESULT,
        get_Value: *const fn (self: *IValueProvider, pRetVal: *BSTR) callconv(WINAPI) HRESULT,
        get_IsReadOnly: *const fn (self: *IValueProvider, pRetVal: *windows.BOOL) callconv(WINAPI) HRESULT,
    };
};

pub const IExpandCollapseProvider = extern struct {
    vtbl: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const fn (self: *IExpandCollapseProvider, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
        AddRef: *const fn (self: *IExpandCollapseProvider) callconv(WINAPI) u32,
        Release: *const fn (self: *IExpandCollapseProvider) callconv(WINAPI) u32,
        Expand: *const fn (self: *IExpandCollapseProvider) callconv(WINAPI) HRESULT,
        Collapse: *const fn (self: *IExpandCollapseProvider) callconv(WINAPI) HRESULT,
        get_ExpandCollapseState: *const fn (self: *IExpandCollapseProvider, pRetVal: *ExpandCollapseState) callconv(WINAPI) HRESULT,
    };
};

pub const ISelectionItemProvider = extern struct {
    vtbl: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const fn (self: *ISelectionItemProvider, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
        AddRef: *const fn (self: *ISelectionItemProvider) callconv(WINAPI) u32,
        Release: *const fn (self: *ISelectionItemProvider) callconv(WINAPI) u32,
        Select: *const fn (self: *ISelectionItemProvider) callconv(WINAPI) HRESULT,
        AddToSelection: *const fn (self: *ISelectionItemProvider) callconv(WINAPI) HRESULT,
        RemoveFromSelection: *const fn (self: *ISelectionItemProvider) callconv(WINAPI) HRESULT,
        get_IsSelected: *const fn (self: *ISelectionItemProvider, pRetVal: *windows.BOOL) callconv(WINAPI) HRESULT,
        get_SelectionContainer: *const fn (self: *ISelectionItemProvider, pRetVal: *?*IRawElementProviderSimple) callconv(WINAPI) HRESULT,
    };
};

// --- Win32 point mapping ---
const POINT = extern struct { x: i32, y: i32 };
extern "user32" fn ClientToScreen(hwnd: HWND, lpPoint: *POINT) callconv(WINAPI) windows.BOOL;

// --- SAFEARRAY (RuntimeId) ---
const SAFEARRAY = opaque {};
extern "oleaut32" fn SafeArrayCreateVector(vt: VARTYPE, lLbound: i32, cElements: u32) callconv(WINAPI) ?*SAFEARRAY;
extern "oleaut32" fn SafeArrayPutElement(psa: *SAFEARRAY, rgIndices: [*]const i32, pv: *const anyopaque) callconv(WINAPI) HRESULT;
extern "oleaut32" fn SafeArrayDestroy(psa: *SAFEARRAY) callconv(WINAPI) HRESULT;

/// Returns the UIA host provider for an HWND. The fragment root must hand this
/// back from get_HostRawElementProvider so UIA can splice our fragment into the
/// window's own (non-client area) element.
extern "uiautomationcore" fn UiaHostProviderFromHwnd(hwnd: HWND, ppProvider: *?*IRawElementProviderSimple) callconv(WINAPI) HRESULT;

/// True when at least one UIA client (screen reader, inspector) is attached, so we
/// can skip building throwaway providers and VARIANTs when nobody is listening.
extern "uiautomationcore" fn UiaClientsAreListening() callconv(WINAPI) windows.BOOL;
/// Raises a plain automation event (`id`) on `pProvider`'s element. Focus moves go
/// out this way with UIA_AutomationFocusChangedEventId — there is no dedicated
/// UiaRaiseFocusChangedEvent export; screen readers speak the newly focused control
/// off this event rather than re-polling GetFocus.
extern "uiautomationcore" fn UiaRaiseAutomationEvent(pProvider: *IRawElementProviderSimple, id: i32) callconv(WINAPI) HRESULT;
/// Announces that a pattern property (`id`) of `pProvider`'s element changed. We
/// pass VT_EMPTY as the old value (we don't retain history); clients read the new.
extern "uiautomationcore" fn UiaRaiseAutomationPropertyChangedEvent(pProvider: *IRawElementProviderSimple, id: i32, oldValue: VARIANT, newValue: VARIANT) callconv(WINAPI) HRESULT;
/// Forces every UIA client-side proxy in this process to drop the references it
/// cached from tree navigation / focus events (`fragment_Navigate`, `raiseFocusChanged`,
/// `raisePropertyChanged`), even if the client itself never got around to calling
/// `Release` — a screen reader or inspector polling across a fast focus-churn window
/// can leave fragments referenced well past their useful life. Call once, on the UI
/// thread, right before dropping the app's own root-provider reference on shutdown;
/// otherwise those orphaned references keep the provider chain alive past window
/// teardown and show up as a leak at process exit.
extern "uiautomationcore" fn UiaDisconnectAllProviders() callconv(WINAPI) HRESULT;

/// Wraps `UiaDisconnectAllProviders` for callers outside this file (window shutdown).
pub fn disconnectAllProviders() void {
    _ = UiaDisconnectAllProviders();
}

/// Frees a SAFEARRAY handed out by GetRuntimeId. UIA does this itself in
/// production; tests call it to avoid leaking.
pub fn destroyRuntimeId(psa: ?*anyopaque) void {
    if (psa) |p| _ = SafeArrayDestroy(@ptrCast(@alignCast(p)));
}

/// Sentinel that must lead a provider-supplied RuntimeId: UIA prefixes the rest
/// with the host window's own id, keeping ids unique across processes.
pub const UiaAppendRuntimeId: i32 = 3;

pub const UIA_NamePropertyId: i32 = 30005;
pub const UIA_ControlTypePropertyId: i32 = 30003;
pub const UIA_IsKeyboardFocusablePropertyId: i32 = 30009;
pub const UIA_IsEnabledPropertyId: i32 = 30010;
pub const UIA_AutomationIdPropertyId: i32 = 30011;
pub const UIA_IsControlElementPropertyId: i32 = 30016;
pub const UIA_IsContentElementPropertyId: i32 = 30017;

// UIA ControlType IDs (UIAutomationClient.h). Kept in sync with the ARIA roles
// that a11y.accessibleRole emits, so a widget maps to its real UIA type instead
// of collapsing to Group.
pub const UIA_ButtonControlTypeId: i32 = 50000;
pub const UIA_CheckBoxControlTypeId: i32 = 50002;
pub const UIA_ComboBoxControlTypeId: i32 = 50003;
pub const UIA_EditControlTypeId: i32 = 50004;
pub const UIA_HyperlinkControlTypeId: i32 = 50005;
pub const UIA_ImageControlTypeId: i32 = 50006;
pub const UIA_ListItemControlTypeId: i32 = 50007;
pub const UIA_ListControlTypeId: i32 = 50008;
pub const UIA_MenuItemControlTypeId: i32 = 50011;
pub const UIA_RadioButtonControlTypeId: i32 = 50013;
pub const UIA_SliderControlTypeId: i32 = 50015;
pub const UIA_ScrollBarControlTypeId: i32 = 50014;
pub const UIA_TabControlTypeId: i32 = 50018;
pub const UIA_TabItemControlTypeId: i32 = 50019;
pub const UIA_TextControlTypeId: i32 = 50020;
pub const UIA_ToolBarControlTypeId: i32 = 50021;
pub const UIA_TreeControlTypeId: i32 = 50023;
pub const UIA_TreeItemControlTypeId: i32 = 50024;
pub const UIA_GroupControlTypeId: i32 = 50026;
pub const UIA_WindowControlTypeId: i32 = 50032;
pub const UIA_SeparatorControlTypeId: i32 = 50038;

// UIA pattern ids (UIAutomationClient.h). Returned from GetPatternProvider.
pub const UIA_InvokePatternId: i32 = 10000;
pub const UIA_ValuePatternId: i32 = 10002;
pub const UIA_ExpandCollapsePatternId: i32 = 10005;
pub const UIA_SelectionItemPatternId: i32 = 10010;
pub const UIA_TogglePatternId: i32 = 10015;

// UIA property ids raised on state change (UIAutomationClient.h), so assistive
// tech re-reads the specific pattern value without walking the whole element.
pub const UIA_ValueValuePropertyId: i32 = 30045;
pub const UIA_ExpandCollapseExpandCollapseStatePropertyId: i32 = 30070;
pub const UIA_SelectionItemIsSelectedPropertyId: i32 = 30079;
pub const UIA_ToggleToggleStatePropertyId: i32 = 30086;

// UIA event id raised when keyboard focus moves (UIAutomationClient.h).
pub const UIA_AutomationFocusChangedEventId: i32 = 20005;

pub const ToggleState = enum(i32) {
    Off = 0,
    On = 1,
    Indeterminate = 2,
};

pub const ExpandCollapseState = enum(i32) {
    Collapsed = 0,
    Expanded = 1,
    PartiallyExpanded = 2,
    LeafNode = 3,
};

/// The engine-side action channel a pattern object drives. `uia.zig` is a
/// low-level platform module and must not import `c_api` (that would be a cycle),
/// so the C-API injects these function pointers when it creates the root
/// provider. Both run the *real* input path on the UI thread — the impl marshals
/// via the task queue; the pattern method itself just calls and returns S_OK.
/// Why a pattern is firing a click, so the UI-thread handler can decide — against
/// *fresh* state — whether the click should actually happen. Evaluating the gate
/// on the UI thread (not in the COM-thread pattern method) removes both the
/// unsynchronized store read and the time-of-check/time-of-use gap where the
/// state could change between the check and the click.
pub const InvokeIntent = enum(i32) {
    /// Invoke/Toggle — always click (the handler flips whatever state applies).
    activate = 0,
    /// Expand — click only if currently collapsed.
    expand = 1,
    /// Collapse — click only if currently expanded.
    collapse = 2,
    /// Select — click only if currently unselected.
    select = 3,
};

/// Whether a click should fire for `intent` given the node's fresh state. Pure so
/// the UI-thread handler and tests share one rule. `expanded`/`checked` are read
/// on the UI thread by the caller.
pub fn shouldActuate(intent: InvokeIntent, expanded: bool, checked: bool) bool {
    return switch (intent) {
        .activate => true,
        .expand => !expanded,
        .collapse => expanded,
        .select => !checked,
    };
}

pub const ActionChannel = struct {
    /// Fires the same click a real pointer/keyboard activation would on `node_id`,
    /// subject to `intent` re-checked on the UI thread. Used by Invoke, Toggle,
    /// Expand/Collapse and Select — all are a click; the intent gates it.
    invoke: *const fn (engine_id: i32, node_id: reg.NodeId, intent: InvokeIntent) callconv(.c) void,
    /// Replaces the editable content of `node_id` with `text[0..len]` through the
    /// real edit path (focus → select-all → commit). Used by ValuePattern.SetValue.
    set_text: *const fn (engine_id: i32, node_id: reg.NodeId, text: [*]const u8, len: usize) callconv(.c) void,
    /// Moves engine keyboard focus to `node_id` (if focusable). Used by
    /// IRawElementProviderFragment::SetFocus so a UIA client / screen reader can
    /// focus a control, and so "focus a field, then type" works.
    set_focus: *const fn (engine_id: i32, node_id: reg.NodeId) callconv(.c) void,
};

/// Signature for the "is anyone listening" policy consulted by raiseFocusChanged
/// / raisePropertyChanged. See `CelerisUiaProvider.clients_listening`.
pub const ClientsListeningFn = *const fn () bool;

fn defaultClientsListening() bool {
    return UiaClientsAreListening() != .FALSE;
}

/// Whether a semantic role exposes InvokePattern (button-like activation).
/// Selection items (tab/treeitem/option) and toggles are deliberately excluded:
/// per UIA they are selected/toggled, not invoked, and exposing both confuses
/// clients about the element's primary action.
fn roleSupportsInvoke(role: []const u8) bool {
    const roles = [_][]const u8{ "button", "link", "menuitem" };
    for (roles) |r| if (std.mem.eql(u8, role, r)) return true;
    return false;
}

/// Whether a semantic role exposes TogglePattern (on/off state via activation).
/// A radio is a SelectionItem, not a Toggle (UIA forbids exposing both), so it
/// is not listed here.
pub fn roleSupportsToggle(role: []const u8) bool {
    const roles = [_][]const u8{ "checkbox", "switch" };
    for (roles) |r| if (std.mem.eql(u8, role, r)) return true;
    return false;
}

/// Whether a semantic role exposes ValuePattern (editable text value). A
/// non-editable combobox exposes ExpandCollapse, not Value — an editable one is
/// a textbox (I-beam cursor) and matches here through that role instead.
pub fn roleSupportsValue(role: []const u8) bool {
    return std.mem.eql(u8, role, "textbox");
}

/// Whether a semantic role exposes ExpandCollapsePattern (open/close).
pub fn roleSupportsExpandCollapse(role: []const u8) bool {
    const roles = [_][]const u8{ "combobox", "treeitem", "menuitem" };
    for (roles) |r| if (std.mem.eql(u8, role, r)) return true;
    return false;
}

/// Whether a semantic role exposes SelectionItemPattern (selectable child).
pub fn roleSupportsSelectionItem(role: []const u8) bool {
    const roles = [_][]const u8{ "radio", "option", "tab", "tabitem", "treeitem", "cell" };
    for (roles) |r| if (std.mem.eql(u8, role, r)) return true;
    return false;
}

/// Maps an ARIA role name (as produced by a11y.accessibleRole) to its UIA
/// ControlType id. Unknown roles fall back to Group, matching prior behaviour.
pub fn ariaRoleToControlType(role: []const u8) i32 {
    const Pair = struct { role: []const u8, ct: i32 };
    const table = [_]Pair{
        .{ .role = "button", .ct = UIA_ButtonControlTypeId },
        .{ .role = "checkbox", .ct = UIA_CheckBoxControlTypeId },
        .{ .role = "switch", .ct = UIA_CheckBoxControlTypeId },
        .{ .role = "radio", .ct = UIA_RadioButtonControlTypeId },
        .{ .role = "combobox", .ct = UIA_ComboBoxControlTypeId },
        .{ .role = "textbox", .ct = UIA_EditControlTypeId },
        .{ .role = "link", .ct = UIA_HyperlinkControlTypeId },
        .{ .role = "img", .ct = UIA_ImageControlTypeId },
        .{ .role = "text", .ct = UIA_TextControlTypeId },
        .{ .role = "slider", .ct = UIA_SliderControlTypeId },
        .{ .role = "scrollbar", .ct = UIA_ScrollBarControlTypeId },
        .{ .role = "menuitem", .ct = UIA_MenuItemControlTypeId },
        .{ .role = "tab", .ct = UIA_TabControlTypeId },
        .{ .role = "tabitem", .ct = UIA_TabItemControlTypeId },
        .{ .role = "toolbar", .ct = UIA_ToolBarControlTypeId },
        .{ .role = "separator", .ct = UIA_SeparatorControlTypeId },
        .{ .role = "list", .ct = UIA_ListControlTypeId },
        .{ .role = "option", .ct = UIA_ListItemControlTypeId },
        .{ .role = "listitem", .ct = UIA_ListItemControlTypeId },
        .{ .role = "cell", .ct = UIA_ListItemControlTypeId },
        .{ .role = "tree", .ct = UIA_TreeControlTypeId },
        .{ .role = "treeitem", .ct = UIA_TreeItemControlTypeId },
    };
    for (table) |p| {
        if (std.mem.eql(u8, role, p.role)) return p.ct;
    }
    return UIA_GroupControlTypeId; // Default
}

// --- Implementation ---
pub const CelerisUiaProvider = struct {
    simple: IRawElementProviderSimple,
    fragment: IRawElementProviderFragment,
    fragment_root: IRawElementProviderFragmentRoot,
    invoke: IInvokeProvider,
    toggle: IToggleProvider,
    value: IValueProvider,
    expand: IExpandCollapseProvider,
    select: ISelectionItemProvider,

    ref_count: u32,
    allocator: std.mem.Allocator,
    node_id: reg.NodeId,
    registry: *reg.UIRegistry,
    store: *props.PropertyStore,
    hwnd: HWND,
    is_root: bool,
    scale: f32,
    /// Borrowed pointer to the engine's current focus slot, so GetFocus can
    /// answer without the provider owning focus state. Null when the host
    /// doesn't track focus (tests), in which case GetFocus reports nothing.
    focused: ?*const ?reg.NodeId = null,
    /// Engine id + action channel injected by the C-API, so action patterns
    /// (Invoke/Toggle) can drive the real input path. Null in tests / when no
    /// engine is wired, in which case Invoke/Toggle are inert (still return S_OK).
    engine_id: i32 = -1,
    actions: ?*const ActionChannel = null,
    /// Policy for whether a UIA client is listening, consulted by the raise*
    /// APIs before doing any work. Defaults to the real `UiaClientsAreListening`
    /// extern; tests inject a stub so the create/release path can be exercised
    /// without an actual screen reader attached (see uia_test.zig).
    clients_listening: ClientsListeningFn = defaultClientsListening,

    const invoke_vtbl = IInvokeProvider.VTable{
        .QueryInterface = invoke_QueryInterface,
        .AddRef = invoke_AddRef,
        .Release = invoke_Release,
        .Invoke = invoke_Invoke,
    };

    const toggle_vtbl = IToggleProvider.VTable{
        .QueryInterface = toggle_QueryInterface,
        .AddRef = toggle_AddRef,
        .Release = toggle_Release,
        .Toggle = toggle_Toggle,
        .get_ToggleState = toggle_get_ToggleState,
    };

    const value_vtbl = IValueProvider.VTable{
        .QueryInterface = value_QueryInterface,
        .AddRef = value_AddRef,
        .Release = value_Release,
        .SetValue = value_SetValue,
        .get_Value = value_get_Value,
        .get_IsReadOnly = value_get_IsReadOnly,
    };

    const expand_vtbl = IExpandCollapseProvider.VTable{
        .QueryInterface = expand_QueryInterface,
        .AddRef = expand_AddRef,
        .Release = expand_Release,
        .Expand = expand_Expand,
        .Collapse = expand_Collapse,
        .get_ExpandCollapseState = expand_get_State,
    };

    const select_vtbl = ISelectionItemProvider.VTable{
        .QueryInterface = select_QueryInterface,
        .AddRef = select_AddRef,
        .Release = select_Release,
        .Select = select_Select,
        .AddToSelection = select_Select,
        .RemoveFromSelection = select_RemoveFromSelection,
        .get_IsSelected = select_get_IsSelected,
        .get_SelectionContainer = select_get_SelectionContainer,
    };

    const simple_vtbl = IRawElementProviderSimple.VTable{
        .QueryInterface = simple_QueryInterface,
        .AddRef = simple_AddRef,
        .Release = simple_Release,
        .get_ProviderOptions = simple_get_ProviderOptions,
        .GetPatternProvider = simple_GetPatternProvider,
        .GetPropertyValue = simple_GetPropertyValue,
        .get_HostRawElementProvider = simple_get_HostRawElementProvider,
    };

    const fragment_vtbl = IRawElementProviderFragment.VTable{
        .QueryInterface = fragment_QueryInterface,
        .AddRef = fragment_AddRef,
        .Release = fragment_Release,
        .Navigate = fragment_Navigate,
        .GetRuntimeId = fragment_GetRuntimeId,
        .get_BoundingRectangle = fragment_get_BoundingRectangle,
        .GetEmbeddedFragmentRoots = fragment_GetEmbeddedFragmentRoots,
        .SetFocus = fragment_SetFocus,
        .get_FragmentRoot = fragment_get_FragmentRoot,
    };

    const fragment_root_vtbl = IRawElementProviderFragmentRoot.VTable{
        .QueryInterface = root_QueryInterface,
        .AddRef = root_AddRef,
        .Release = root_Release,
        .ElementProviderFromPoint = root_ElementProviderFromPoint,
        .GetFocus = root_GetFocus,
    };

    pub fn create(
        allocator: std.mem.Allocator,
        node_id: reg.NodeId,
        registry: *reg.UIRegistry,
        store: *props.PropertyStore,
        hwnd: HWND,
        is_root: bool,
        scale: f32,
    ) !*CelerisUiaProvider {
        const self = try allocator.create(CelerisUiaProvider);
        self.* = .{
            .simple = .{ .vtbl = &simple_vtbl },
            .fragment = .{ .vtbl = &fragment_vtbl },
            .fragment_root = .{ .vtbl = &fragment_root_vtbl },
            .invoke = .{ .vtbl = &invoke_vtbl },
            .toggle = .{ .vtbl = &toggle_vtbl },
            .value = .{ .vtbl = &value_vtbl },
            .expand = .{ .vtbl = &expand_vtbl },
            .select = .{ .vtbl = &select_vtbl },
            .ref_count = 1,
            .allocator = allocator,
            .node_id = node_id,
            .registry = registry,
            .store = store,
            .hwnd = hwnd,
            .is_root = is_root,
            .scale = scale,
            .focused = null,
        };
        return self;
    }

    fn addRef(self: *CelerisUiaProvider) u32 {
        self.ref_count += 1;
        return self.ref_count;
    }

    /// Drops the reference `create` handed to the engine. UIA may still hold its
    /// own references, so this frees the provider only once the last one goes.
    pub fn releaseRef(self: *CelerisUiaProvider) void {
        _ = self.release();
    }

    fn release(self: *CelerisUiaProvider) u32 {
        self.ref_count -= 1;
        if (self.ref_count == 0) {
            self.allocator.destroy(self);
            return 0;
        }
        return self.ref_count;
    }

    fn queryInterface(self: *CelerisUiaProvider, riid: *const GUID, ppvObject: *?*anyopaque) HRESULT {
        if (riid.eql(&IID_IUnknown) or riid.eql(&IID_IRawElementProviderSimple)) {
            ppvObject.* = &self.simple;
            _ = self.addRef();
            return S_OK;
        } else if (riid.eql(&IID_IRawElementProviderFragment)) {
            ppvObject.* = &self.fragment;
            _ = self.addRef();
            return S_OK;
        } else if (self.is_root and riid.eql(&IID_IRawElementProviderFragmentRoot)) {
            ppvObject.* = &self.fragment_root;
            _ = self.addRef();
            return S_OK;
        } else if (riid.eql(&IID_IInvokeProvider)) {
            ppvObject.* = &self.invoke;
            _ = self.addRef();
            return S_OK;
        } else if (riid.eql(&IID_IToggleProvider)) {
            ppvObject.* = &self.toggle;
            _ = self.addRef();
            return S_OK;
        } else if (riid.eql(&IID_IValueProvider)) {
            ppvObject.* = &self.value;
            _ = self.addRef();
            return S_OK;
        } else if (riid.eql(&IID_IExpandCollapseProvider)) {
            ppvObject.* = &self.expand;
            _ = self.addRef();
            return S_OK;
        } else if (riid.eql(&IID_ISelectionItemProvider)) {
            ppvObject.* = &self.select;
            _ = self.addRef();
            return S_OK;
        }

        ppvObject.* = null;
        return E_NOINTERFACE;
    }

    /// The semantic role of this provider's node (or "window" for the root),
    /// used to decide which action patterns to expose.
    fn nodeRole(self: *CelerisUiaProvider) []const u8 {
        if (self.is_root) return "window";
        const node = self.registry.getNode(self.node_id) orelse return "";
        return a11y.accessibleRole(self.store, self.node_id, node.node_type);
    }

    /// Fires the node's real click through the injected action channel. No-op
    /// when no engine/action channel is wired (tests). Runs from the UIA (COM)
    /// thread — the channel marshals onto the UI thread.
    fn fireInvoke(self: *CelerisUiaProvider, intent: InvokeIntent) void {
        if (self.actions) |ch| ch.invoke(self.engine_id, self.node_id, intent);
    }

    /// Replaces the node's editable text through the injected action channel
    /// (focus → select-all → commit on the UI thread). No-op without a channel.
    fn fireSetText(self: *CelerisUiaProvider, text: []const u8) void {
        if (self.actions) |ch| ch.set_text(self.engine_id, self.node_id, text.ptr, text.len);
    }

    // --- IRawElementProviderSimple delegates ---
    fn simple_QueryInterface(simple: *IRawElementProviderSimple, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT {
        const self: *CelerisUiaProvider = @fieldParentPtr("simple", simple);
        return self.queryInterface(riid, ppvObject);
    }
    fn simple_AddRef(simple: *IRawElementProviderSimple) callconv(WINAPI) u32 {
        const self: *CelerisUiaProvider = @fieldParentPtr("simple", simple);
        return self.addRef();
    }
    fn simple_Release(simple: *IRawElementProviderSimple) callconv(WINAPI) u32 {
        const self: *CelerisUiaProvider = @fieldParentPtr("simple", simple);
        return self.release();
    }
    fn simple_get_ProviderOptions(_: *IRawElementProviderSimple, pRetVal: *ProviderOptions) callconv(WINAPI) HRESULT {
        pRetVal.* = .ServerSideProvider;
        return S_OK;
    }
    fn simple_GetPatternProvider(simple: *IRawElementProviderSimple, patternId: i32, pRetVal: *?*IUnknown) callconv(WINAPI) HRESULT {
        const self: *CelerisUiaProvider = @fieldParentPtr("simple", simple);
        pRetVal.* = null;
        const role = self.nodeRole();
        if (patternId == UIA_InvokePatternId and roleSupportsInvoke(role)) {
            _ = self.addRef();
            pRetVal.* = @ptrCast(&self.invoke);
        } else if (patternId == UIA_TogglePatternId and roleSupportsToggle(role)) {
            _ = self.addRef();
            pRetVal.* = @ptrCast(&self.toggle);
        } else if (patternId == UIA_ValuePatternId and roleSupportsValue(role)) {
            _ = self.addRef();
            pRetVal.* = @ptrCast(&self.value);
        } else if (patternId == UIA_ExpandCollapsePatternId and roleSupportsExpandCollapse(role)) {
            _ = self.addRef();
            pRetVal.* = @ptrCast(&self.expand);
        } else if (patternId == UIA_SelectionItemPatternId and roleSupportsSelectionItem(role)) {
            _ = self.addRef();
            pRetVal.* = @ptrCast(&self.select);
        }
        return S_OK;
    }
    fn simple_GetPropertyValue(simple: *IRawElementProviderSimple, propertyId: i32, pRetVal: *VARIANT) callconv(WINAPI) HRESULT {
        const self: *CelerisUiaProvider = @fieldParentPtr("simple", simple);
        VariantInit(pRetVal);

        if (propertyId == UIA_NamePropertyId) {
            const name = a11y.accessibleName(self.registry, self.store, self.node_id);
            if (name.len > 0) {
                var utf16_buf: [256]u16 = undefined;
                if (std.unicode.utf8ToUtf16Le(utf16_buf[0 .. utf16_buf.len - 1], name)) |n| {
                    utf16_buf[n] = 0;
                    const bstr = SysAllocString(@ptrCast(&utf16_buf));
                    if (bstr != null) {
                        pRetVal.vt = VT_BSTR;
                        pRetVal.u.bstrVal = bstr;
                    }
                } else |_| {}
            }
        } else if (propertyId == UIA_AutomationIdPropertyId) {
            var buf: [32]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{d}", .{self.node_id}) catch "0";
            var utf16_buf: [32]u16 = undefined;
            if (std.unicode.utf8ToUtf16Le(utf16_buf[0 .. utf16_buf.len - 1], text)) |n| {
                utf16_buf[n] = 0;
                const bstr = SysAllocString(@ptrCast(&utf16_buf));
                if (bstr != null) {
                    pRetVal.vt = VT_BSTR;
                    pRetVal.u.bstrVal = bstr;
                }
            } else |_| {}
        } else if (propertyId == UIA_ControlTypePropertyId) {
            const node = self.registry.getNode(self.node_id);
            if (node) |n| {
                const role = if (self.is_root) "window" else a11y.accessibleRole(self.store, self.node_id, n.node_type);
                const control_type = if (self.is_root) UIA_WindowControlTypeId else ariaRoleToControlType(role);
                pRetVal.vt = VT_I4;
                pRetVal.u.lVal = control_type;
            }
        } else if (propertyId == UIA_IsEnabledPropertyId) {
            // Must be answered explicitly: leaving the VARIANT empty makes
            // clients read the element as disabled, and UIA automation refuses
            // to invoke a disabled element, so nothing in the window is
            // clickable. Enabled is the default; only the `disabled` modifier
            // turns it off.
            pRetVal.vt = VT_BOOL;
            pRetVal.u.boolVal = if (a11y.stateFlag(self.store, self.node_id, .disabled)) 0 else -1;
        } else if (propertyId == UIA_IsKeyboardFocusablePropertyId) {
            const focusable = a11y.stateFlag(self.store, self.node_id, .focusable);
            pRetVal.vt = VT_BOOL;
            pRetVal.u.boolVal = if (focusable) -1 else 0;
        } else if (propertyId == UIA_IsControlElementPropertyId or propertyId == UIA_IsContentElementPropertyId) {
            // A label absorbed into its control's name (a button's text, an
            // Edit's placeholder) must not present as its own control, or a
            // client searching by that name gets two hits. UIA's own control-
            // view/content-view walkers honor this without us pruning the
            // fragment tree.
            const is_control = a11y.isControlElement(self.registry, self.store, self.node_id);
            pRetVal.vt = VT_BOOL;
            pRetVal.u.boolVal = if (is_control) -1 else 0;
        }
        return S_OK;
    }
    fn simple_get_HostRawElementProvider(simple: *IRawElementProviderSimple, pRetVal: *?*IRawElementProviderSimple) callconv(WINAPI) HRESULT {
        const self: *CelerisUiaProvider = @fieldParentPtr("simple", simple);
        pRetVal.* = null;
        // Only the fragment root is hosted in the HWND; inner fragments must
        // report null or UIA will treat each one as a separate window.
        if (!self.is_root) return S_OK;
        return UiaHostProviderFromHwnd(self.hwnd, pRetVal);
    }

    // --- IInvokeProvider delegates ---
    fn invoke_QueryInterface(iface: *IInvokeProvider, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT {
        const self: *CelerisUiaProvider = @fieldParentPtr("invoke", iface);
        return self.queryInterface(riid, ppvObject);
    }
    fn invoke_AddRef(iface: *IInvokeProvider) callconv(WINAPI) u32 {
        const self: *CelerisUiaProvider = @fieldParentPtr("invoke", iface);
        return self.addRef();
    }
    fn invoke_Release(iface: *IInvokeProvider) callconv(WINAPI) u32 {
        const self: *CelerisUiaProvider = @fieldParentPtr("invoke", iface);
        return self.release();
    }
    fn invoke_Invoke(iface: *IInvokeProvider) callconv(WINAPI) HRESULT {
        const self: *CelerisUiaProvider = @fieldParentPtr("invoke", iface);
        self.fireInvoke(.activate);
        return S_OK;
    }

    // --- IToggleProvider delegates ---
    fn toggle_QueryInterface(iface: *IToggleProvider, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT {
        const self: *CelerisUiaProvider = @fieldParentPtr("toggle", iface);
        return self.queryInterface(riid, ppvObject);
    }
    fn toggle_AddRef(iface: *IToggleProvider) callconv(WINAPI) u32 {
        const self: *CelerisUiaProvider = @fieldParentPtr("toggle", iface);
        return self.addRef();
    }
    fn toggle_Release(iface: *IToggleProvider) callconv(WINAPI) u32 {
        const self: *CelerisUiaProvider = @fieldParentPtr("toggle", iface);
        return self.release();
    }
    fn toggle_Toggle(iface: *IToggleProvider) callconv(WINAPI) HRESULT {
        const self: *CelerisUiaProvider = @fieldParentPtr("toggle", iface);
        // Toggling a checkbox/switch is the same click a user makes; the handler
        // flips the state. UIA reads the new state back via get_ToggleState.
        self.fireInvoke(.activate);
        return S_OK;
    }
    fn toggle_get_ToggleState(iface: *IToggleProvider, pRetVal: *ToggleState) callconv(WINAPI) HRESULT {
        const self: *CelerisUiaProvider = @fieldParentPtr("toggle", iface);
        pRetVal.* = if (a11y.stateFlag(self.store, self.node_id, .checked)) .On else .Off;
        return S_OK;
    }

    // --- IValueProvider delegates ---
    fn value_QueryInterface(iface: *IValueProvider, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT {
        const self: *CelerisUiaProvider = @fieldParentPtr("value", iface);
        return self.queryInterface(riid, ppvObject);
    }
    fn value_AddRef(iface: *IValueProvider) callconv(WINAPI) u32 {
        const self: *CelerisUiaProvider = @fieldParentPtr("value", iface);
        return self.addRef();
    }
    fn value_Release(iface: *IValueProvider) callconv(WINAPI) u32 {
        const self: *CelerisUiaProvider = @fieldParentPtr("value", iface);
        return self.release();
    }
    fn value_SetValue(iface: *IValueProvider, val: BSTR) callconv(WINAPI) HRESULT {
        const self: *CelerisUiaProvider = @fieldParentPtr("value", iface);
        // The read-only guard runs on the UI thread in setNodeTextViaInput against
        // fresh state, not here on the COM thread.
        if (val) |p| {
            const len16 = SysStringLen(val);
            const chars: [*]const u16 = @ptrCast(p);
            var u8buf: [1024]u8 = undefined;
            if (std.unicode.utf16LeToUtf8(&u8buf, chars[0..len16])) |n| {
                self.fireSetText(u8buf[0..n]);
            } else |_| {}
        } else {
            self.fireSetText(""); // null BSTR clears the field
        }
        return S_OK;
    }
    fn value_get_Value(iface: *IValueProvider, pRetVal: *BSTR) callconv(WINAPI) HRESULT {
        const self: *CelerisUiaProvider = @fieldParentPtr("value", iface);
        pRetVal.* = null;
        const text = a11y.editableValue(self.registry, self.store, self.node_id);
        if (text.len == 0) return S_OK;
        var utf16_buf: [1024]u16 = undefined;
        if (std.unicode.utf8ToUtf16Le(utf16_buf[0 .. utf16_buf.len - 1], text)) |n| {
            utf16_buf[n] = 0;
            pRetVal.* = SysAllocString(@ptrCast(&utf16_buf));
        } else |_| {}
        return S_OK;
    }
    fn value_get_IsReadOnly(iface: *IValueProvider, pRetVal: *windows.BOOL) callconv(WINAPI) HRESULT {
        const self: *CelerisUiaProvider = @fieldParentPtr("value", iface);
        pRetVal.* = if (a11y.stateFlag(self.store, self.node_id, .readonly)) .TRUE else .FALSE;
        return S_OK;
    }

    // --- IExpandCollapseProvider delegates ---
    fn expand_QueryInterface(iface: *IExpandCollapseProvider, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT {
        const self: *CelerisUiaProvider = @fieldParentPtr("expand", iface);
        return self.queryInterface(riid, ppvObject);
    }
    fn expand_AddRef(iface: *IExpandCollapseProvider) callconv(WINAPI) u32 {
        const self: *CelerisUiaProvider = @fieldParentPtr("expand", iface);
        return self.addRef();
    }
    fn expand_Release(iface: *IExpandCollapseProvider) callconv(WINAPI) u32 {
        const self: *CelerisUiaProvider = @fieldParentPtr("expand", iface);
        return self.release();
    }
    fn expand_Expand(iface: *IExpandCollapseProvider) callconv(WINAPI) HRESULT {
        const self: *CelerisUiaProvider = @fieldParentPtr("expand", iface);
        // The "only click when collapsed" gate is applied on the UI thread against
        // fresh state (see uia.shouldActuate), not here on the COM thread.
        self.fireInvoke(.expand);
        return S_OK;
    }
    fn expand_Collapse(iface: *IExpandCollapseProvider) callconv(WINAPI) HRESULT {
        const self: *CelerisUiaProvider = @fieldParentPtr("expand", iface);
        self.fireInvoke(.collapse);
        return S_OK;
    }
    fn expand_get_State(iface: *IExpandCollapseProvider, pRetVal: *ExpandCollapseState) callconv(WINAPI) HRESULT {
        const self: *CelerisUiaProvider = @fieldParentPtr("expand", iface);
        pRetVal.* = if (a11y.stateFlag(self.store, self.node_id, .expanded)) .Expanded else .Collapsed;
        return S_OK;
    }

    // --- ISelectionItemProvider delegates ---
    fn select_QueryInterface(iface: *ISelectionItemProvider, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT {
        const self: *CelerisUiaProvider = @fieldParentPtr("select", iface);
        return self.queryInterface(riid, ppvObject);
    }
    fn select_AddRef(iface: *ISelectionItemProvider) callconv(WINAPI) u32 {
        const self: *CelerisUiaProvider = @fieldParentPtr("select", iface);
        return self.addRef();
    }
    fn select_Release(iface: *ISelectionItemProvider) callconv(WINAPI) u32 {
        const self: *CelerisUiaProvider = @fieldParentPtr("select", iface);
        return self.release();
    }
    fn select_Select(iface: *ISelectionItemProvider) callconv(WINAPI) HRESULT {
        const self: *CelerisUiaProvider = @fieldParentPtr("select", iface);
        // Selecting an unselected item is the same click a user makes; an already
        // selected item is left as-is. The gate runs on the UI thread against
        // fresh state (uia.shouldActuate), not here on the COM thread.
        self.fireInvoke(.select);
        return S_OK;
    }
    fn select_RemoveFromSelection(_: *ISelectionItemProvider) callconv(WINAPI) HRESULT {
        // Single-selection controls (radio/tab) can't clear their own selection;
        // there's no user gesture for it, so this is a no-op.
        return S_OK;
    }
    fn select_get_IsSelected(iface: *ISelectionItemProvider, pRetVal: *windows.BOOL) callconv(WINAPI) HRESULT {
        const self: *CelerisUiaProvider = @fieldParentPtr("select", iface);
        pRetVal.* = if (a11y.stateFlag(self.store, self.node_id, .checked)) .TRUE else .FALSE;
        return S_OK;
    }
    fn select_get_SelectionContainer(_: *ISelectionItemProvider, pRetVal: *?*IRawElementProviderSimple) callconv(WINAPI) HRESULT {
        // The container element is optional; most clients read IsSelected/Select
        // without it. Returning null keeps us from fabricating a provider whose
        // lifetime we'd have to own.
        pRetVal.* = null;
        return S_OK;
    }

    // --- Pure UIA Logic (Testable) ---
    pub const UiaTreeWalker = struct {
        registry: *reg.UIRegistry,
        store: *const props.PropertyStore,

        /// Delegates to `a11y.isVisible`: own geometry AND not clipped away by
        /// an `overflow_hidden` ancestor (e.g. a closed Menu/Dropdown panel —
        /// its rows keep their own fixed geometry even while the panel
        /// collapses to height 0 to hide them). A plain geometry-only check
        /// missed that, which is why a closed menu's rows used to still show
        /// up — named and invocable — in the UIA tree.
        pub fn isNodeVisible(self: UiaTreeWalker, id: reg.NodeId) bool {
            return a11y.isVisible(self.registry, self.store, id);
        }

        /// True when `id` should appear as a node in the tree `Navigate`
        /// exposes: visible AND a real control, not a decorative label a
        /// control already reports through its own name (`a11y.isControlElement`
        /// — e.g. a `Menu` row's checkmark/shortcut/label `Text` children, once
        /// the row itself carries an explicit accessible name). Without this,
        /// those Text nodes still walked the raw tree as their own elements —
        /// unnamed, and reporting whatever (possibly stale) geometry a leaf
        /// text node happens to have — pure noise once the row already speaks
        /// for them. Demoted text is treated like a zero-sized wrapper below:
        /// transparent for tree structure, its own (leaf) subtree counting as
        /// empty.
        fn isExposed(self: UiaTreeWalker, id: reg.NodeId) bool {
            return self.isNodeVisible(id) and a11y.isControlElement(self.registry, self.store, id);
        }

        /// Nearest visible ancestor, or the subtree's topmost node if none is
        /// visible. This is the node that owns `id` in the flattened tree, so
        /// sibling scans and `Parent` agree on who the parent is.
        fn visibleParent(self: UiaTreeWalker, id: reg.NodeId) reg.NodeId {
            var curr = (self.registry.getNode(id) orelse return reg.NULL_NODE).parent;
            var top: reg.NodeId = reg.NULL_NODE;
            var depth: usize = 0;
            while (curr != reg.NULL_NODE and depth < reg.MAX_TREE_DEPTH) : (depth += 1) {
                if (self.isExposed(curr)) return curr;
                top = curr;
                curr = (self.registry.getNode(curr) orelse break).parent;
            }
            return top;
        }

        /// First exposed node in `parent`'s flattened child list: children in
        /// order, descending *through* zero-sized wrappers and demoted
        /// decorative text instead of pruning them, and stopping at each
        /// exposed node.
        fn firstVisibleChild(self: UiaTreeWalker, parent: reg.NodeId, depth: usize) reg.NodeId {
            if (depth >= reg.MAX_TREE_DEPTH) return reg.NULL_NODE;
            const node = self.registry.getNode(parent) orelse return reg.NULL_NODE;
            var child = node.first_child;
            while (child != reg.NULL_NODE) {
                if (self.isExposed(child)) return child;
                const nested = self.firstVisibleChild(child, depth + 1);
                if (nested != reg.NULL_NODE) return nested;
                child = (self.registry.getNode(child) orelse break).next_sibling;
            }
            return reg.NULL_NODE;
        }

        fn lastVisibleChild(self: UiaTreeWalker, parent: reg.NodeId, depth: usize) reg.NodeId {
            if (depth >= reg.MAX_TREE_DEPTH) return reg.NULL_NODE;
            const node = self.registry.getNode(parent) orelse return reg.NULL_NODE;
            var child = node.first_child;
            var last: reg.NodeId = reg.NULL_NODE;
            while (child != reg.NULL_NODE) {
                if (self.isExposed(child)) {
                    last = child;
                } else {
                    const nested = self.lastVisibleChild(child, depth + 1);
                    if (nested != reg.NULL_NODE) last = nested;
                }
                child = (self.registry.getNode(child) orelse break).next_sibling;
            }
            return last;
        }

        /// Walk state for locating a node's neighbours within the flattened
        /// child list, in a single in-order pass.
        const SiblingScan = struct {
            target: reg.NodeId,
            prev: reg.NodeId = reg.NULL_NODE,
            next: reg.NodeId = reg.NULL_NODE,
            found: bool = false,
        };

        fn scanSiblings(self: UiaTreeWalker, parent: reg.NodeId, s: *SiblingScan, depth: usize) void {
            if (depth >= reg.MAX_TREE_DEPTH) return;
            const node = self.registry.getNode(parent) orelse return;
            var child = node.first_child;
            while (child != reg.NULL_NODE) {
                if (self.isExposed(child)) {
                    if (s.found) {
                        s.next = child;
                        return;
                    }
                    if (child == s.target) {
                        s.found = true;
                    } else {
                        s.prev = child;
                    }
                } else {
                    self.scanSiblings(child, s, depth + 1);
                    if (s.next != reg.NULL_NODE) return;
                }
                child = (self.registry.getNode(child) orelse break).next_sibling;
            }
        }

        pub fn navigate(self: UiaTreeWalker, node_id: reg.NodeId, direction: NavigateDirection) reg.NodeId {
            if (self.registry.getNode(node_id) == null) return reg.NULL_NODE;

            return switch (direction) {
                .Parent => self.visibleParent(node_id),
                .FirstChild => self.firstVisibleChild(node_id, 0),
                .LastChild => self.lastVisibleChild(node_id, 0),
                .NextSibling, .PreviousSibling => blk: {
                    const parent = self.visibleParent(node_id);
                    if (parent == reg.NULL_NODE) break :blk reg.NULL_NODE;
                    var scan = SiblingScan{ .target = node_id };
                    self.scanSiblings(parent, &scan, 0);
                    if (!scan.found) break :blk reg.NULL_NODE;
                    break :blk if (direction == .NextSibling) scan.next else scan.prev;
                },
            };
        }

        /// A pending winner during `hitTest`'s walk: the highest effective
        /// z-index seen so far containing the point, tie-broken by draw order
        /// (later-visited — deeper or later-sibling — wins), exactly the
        /// `sortHitNodesDescending` rule the renderer's real hit list uses
        /// (`render/renderer.zig`).
        const HitCandidate = struct {
            id: reg.NodeId = reg.NULL_NODE,
            z: f32 = -std.math.floatMax(f32),
            order: u32 = 0,
        };

        /// A clip rectangle in the same logical coordinate space as `Geometry`.
        const ClipRect = struct { x: f32, y: f32, w: f32, h: f32 };
        const INFINITE_CLIP: ClipRect = .{ .x = -1.0e9, .y = -1.0e9, .w = 2.0e9, .h = 2.0e9 };

        fn intersectClip(a: ClipRect, g: reg.Geometry) ClipRect {
            const x1 = @max(a.x, g.x);
            const y1 = @max(a.y, g.y);
            const x2 = @min(a.x + a.w, g.x + g.width);
            const y2 = @min(a.y + a.h, g.y + g.height);
            return .{ .x = x1, .y = y1, .w = @max(0, x2 - x1), .h = @max(0, y2 - y1) };
        }

        fn pointInClip(c: ClipRect, x: f32, y: f32) bool {
            return x >= c.x and x <= c.x + c.w and y >= c.y and y <= c.y + c.h;
        }

        /// The node UIA's `ElementFromPoint` should answer with: the same rule
        /// the renderer's real hit list uses (`core/events.zig` `hitTest`,
        /// `render/renderer.zig` `bakeNodeRecursive`) — z-index inherited down
        /// the tree unless a node sets its own (`.style(.z_index)`), highest
        /// effective z-index wins, ties broken by draw order (later-visited —
        /// deeper or a later sibling — wins). A plain document-order walk
        /// missed overlays entirely: a `Menu` panel positioned with
        /// `z-index: 100` over page content painted *earlier* in the tree
        /// (e.g. a MenuBar built before the app body) would lose to that
        /// later-built, lower/no-z-index content, so `ElementFromPoint` (and
        /// any UIA client driving it — Inspect.exe, WinAppDriver, a screen
        /// reader's point navigation) picked whatever was underneath the open
        /// menu instead of the menu row a real click actually hits.
        pub fn hitTest(self: UiaTreeWalker, root_id: reg.NodeId, x: f32, y: f32) reg.NodeId {
            var counter: u32 = 0;
            var best: HitCandidate = .{};
            self.hitTestWalk(root_id, x, y, 0, INFINITE_CLIP, &counter, &best, 0);
            return best.id;
        }

        fn hitTestWalk(
            self: UiaTreeWalker,
            node_id: reg.NodeId,
            x: f32,
            y: f32,
            current_z: f32,
            clip: ClipRect,
            counter: *u32,
            best: *HitCandidate,
            depth: usize,
        ) void {
            if (depth >= reg.MAX_TREE_DEPTH) return;
            const node = self.registry.getNode(node_id) orelse return;
            const g = node.geometry;

            var next_clip = clip;
            if (self.store.modifierFlag(node_id, .overflow_hidden)) {
                next_clip = intersectClip(clip, g);
            }

            const z_val = if (self.store.getStyle(node_id, .z_index)) |v| v.number else current_z;
            counter.* += 1;
            const order = counter.*;

            // A demoted decorative Text node (e.g. a Menu row's checkmark/
            // label — the row already carries the accessible name) is never
            // the answer to ElementFromPoint; the point resolves to its
            // control ancestor instead, same as it would in UIA's own
            // ControlView.
            if (g.width > 0 and g.height > 0 and containsPoint(g, x, y) and pointInClip(clip, x, y) and
                a11y.isControlElement(self.registry, self.store, node_id))
            {
                if (z_val > best.z or (z_val == best.z and order > best.order)) {
                    best.* = .{ .id = node_id, .z = z_val, .order = order };
                }
            }

            var child = node.first_child;
            while (child != reg.NULL_NODE) {
                self.hitTestWalk(child, x, y, z_val, next_clip, counter, best, depth + 1);
                child = (self.registry.getNode(child) orelse break).next_sibling;
            }
        }
    };

    pub fn containsPoint(g: reg.Geometry, x: f32, y: f32) bool {
        return x >= g.x and x <= g.x + g.width and y >= g.y and y <= g.y + g.height;
    }

    /// Logical geometry -> physical screen rect. `client_offset_*` is the
    /// client area's origin in physical screen pixels (from ClientToScreen);
    /// `scale` converts our logical units to physical ones on HiDPI monitors.
    pub fn computeScreenBounds(
        logical_geometry: reg.Geometry,
        client_offset_x: i32,
        client_offset_y: i32,
        scale: f32,
    ) [4]f64 {
        const s: f64 = @floatCast(scale);
        return [4]f64{
            @as(f64, logical_geometry.x) * s + @as(f64, @floatFromInt(client_offset_x)),
            @as(f64, logical_geometry.y) * s + @as(f64, @floatFromInt(client_offset_y)),
            @as(f64, logical_geometry.width) * s,
            @as(f64, logical_geometry.height) * s,
        };
    }

    /// Inverse of `computeScreenBounds` for a single point: physical screen
    /// coordinates (as UIA hands them to ElementProviderFromPoint) -> logical.
    pub fn screenToLogical(
        screen_x: f64,
        screen_y: f64,
        client_offset_x: i32,
        client_offset_y: i32,
        scale: f32,
    ) struct { x: f32, y: f32 } {
        const s: f64 = @floatCast(scale);
        const safe_s = if (s <= 0) 1.0 else s;
        return .{
            .x = @floatCast((screen_x - @as(f64, @floatFromInt(client_offset_x))) / safe_s),
            .y = @floatCast((screen_y - @as(f64, @floatFromInt(client_offset_y))) / safe_s),
        };
    }

    /// RuntimeId payload for a node. `UiaAppendRuntimeId` tells UIA to prefix
    /// this with the host HWND's id, so the pair is unique process-wide.
    pub fn computeRuntimeId(node_id: reg.NodeId) [2]i32 {
        return .{ UiaAppendRuntimeId, @bitCast(node_id) };
    }

    // --- IRawElementProviderFragment delegates ---
    fn fragment_QueryInterface(frag: *IRawElementProviderFragment, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT {
        const self: *CelerisUiaProvider = @fieldParentPtr("fragment", frag);
        return self.queryInterface(riid, ppvObject);
    }
    fn fragment_AddRef(frag: *IRawElementProviderFragment) callconv(WINAPI) u32 {
        const self: *CelerisUiaProvider = @fieldParentPtr("fragment", frag);
        return self.addRef();
    }
    fn fragment_Release(frag: *IRawElementProviderFragment) callconv(WINAPI) u32 {
        const self: *CelerisUiaProvider = @fieldParentPtr("fragment", frag);
        return self.release();
    }
    fn fragment_Navigate(frag: *IRawElementProviderFragment, direction: NavigateDirection, pRetVal: *?*IRawElementProviderFragment) callconv(WINAPI) HRESULT {
        const self: *CelerisUiaProvider = @fieldParentPtr("fragment", frag);
        pRetVal.* = null;

        const walker = UiaTreeWalker{ .registry = self.registry, .store = self.store };
        const target_id = walker.navigate(self.node_id, direction);

        if (target_id != reg.NULL_NODE) {
            self.yieldFragment(target_id, pRetVal);
        }
        return S_OK;
    }
    fn fragment_GetRuntimeId(frag: *IRawElementProviderFragment, pRetVal: *?*anyopaque) callconv(WINAPI) HRESULT {
        const self: *CelerisUiaProvider = @fieldParentPtr("fragment", frag);
        pRetVal.* = null;

        const rid = computeRuntimeId(self.node_id);
        const psa = SafeArrayCreateVector(VT_I4, 0, rid.len) orelse return S_OK;
        for (rid, 0..) |value, i| {
            const index = [_]i32{@intCast(i)};
            if (SafeArrayPutElement(psa, &index, &value) != S_OK) {
                _ = SafeArrayDestroy(psa);
                return S_OK;
            }
        }
        pRetVal.* = @ptrCast(psa);
        return S_OK;
    }
    fn fragment_get_BoundingRectangle(frag: *IRawElementProviderFragment, pRetVal: *[4]f64) callconv(WINAPI) HRESULT {
        const self: *CelerisUiaProvider = @fieldParentPtr("fragment", frag);
        pRetVal.* = [_]f64{ 0, 0, 0, 0 };

        if (self.registry.getNode(self.node_id)) |node| {
            var pt = POINT{ .x = 0, .y = 0 };
            _ = ClientToScreen(self.hwnd, &pt);

            const bounds = computeScreenBounds(node.geometry, pt.x, pt.y, self.scale);
            pRetVal[0] = bounds[0];
            pRetVal[1] = bounds[1];
            pRetVal[2] = bounds[2];
            pRetVal[3] = bounds[3];
        }
        return S_OK;
    }
    fn fragment_GetEmbeddedFragmentRoots(_: *IRawElementProviderFragment, pRetVal: *?*anyopaque) callconv(WINAPI) HRESULT {
        pRetVal.* = null;
        return S_OK;
    }
    fn fragment_SetFocus(frag: *IRawElementProviderFragment) callconv(WINAPI) HRESULT {
        const self: *CelerisUiaProvider = @fieldParentPtr("fragment", frag);
        // Route through the action channel so the engine actually moves keyboard
        // focus on the UI thread (a no-op here would leave screen-reader focus and
        // "focus then type" broken).
        if (self.actions) |ch| ch.set_focus(self.engine_id, self.node_id);
        return S_OK;
    }
    fn fragment_get_FragmentRoot(frag: *IRawElementProviderFragment, pRetVal: *?*IRawElementProviderFragmentRoot) callconv(WINAPI) HRESULT {
        const self: *CelerisUiaProvider = @fieldParentPtr("fragment", frag);
        pRetVal.* = null;

        var root_id = self.node_id;
        while (self.registry.getNode(root_id)) |n| {
            if (n.parent == reg.NULL_NODE) break;
            root_id = n.parent;
        }

        if (CelerisUiaProvider.create(self.allocator, root_id, self.registry, self.store, self.hwnd, true, self.scale)) |root_prov| {
            root_prov.focused = self.focused;
            root_prov.engine_id = self.engine_id;
            root_prov.actions = self.actions;
            root_prov.clients_listening = self.clients_listening;
            pRetVal.* = &root_prov.fragment_root;
        } else |_| {}

        return S_OK;
    }

    // --- IRawElementProviderFragmentRoot delegates ---
    fn root_QueryInterface(root: *IRawElementProviderFragmentRoot, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT {
        const self: *CelerisUiaProvider = @fieldParentPtr("fragment_root", root);
        return self.queryInterface(riid, ppvObject);
    }
    fn root_AddRef(root: *IRawElementProviderFragmentRoot) callconv(WINAPI) u32 {
        const self: *CelerisUiaProvider = @fieldParentPtr("fragment_root", root);
        return self.addRef();
    }
    fn root_Release(root: *IRawElementProviderFragmentRoot) callconv(WINAPI) u32 {
        const self: *CelerisUiaProvider = @fieldParentPtr("fragment_root", root);
        return self.release();
    }
    /// Wraps `node_id` in a fresh non-root provider and hands out a fragment
    /// reference the caller owns. Returns null on allocation failure.
    fn yieldFragment(self: *CelerisUiaProvider, node_id: reg.NodeId, pRetVal: *?*IRawElementProviderFragment) void {
        if (CelerisUiaProvider.create(self.allocator, node_id, self.registry, self.store, self.hwnd, false, self.scale)) |provider| {
            provider.focused = self.focused;
            provider.engine_id = self.engine_id;
            provider.actions = self.actions;
            provider.clients_listening = self.clients_listening;
            _ = provider.queryInterface(&IID_IRawElementProviderFragment, @ptrCast(pRetVal));
            _ = provider.release();
        } else |_| {}
    }

    /// Builds a throwaway non-root provider for `node_id`, runs `body` with its
    /// simple interface, then releases it. The raise APIs address the element that
    /// changed, so each notification needs a provider for that specific node — not
    /// the root. No-op when the node is gone. Call on the UI thread only.
    fn withNodeSimple(self: *CelerisUiaProvider, node_id: reg.NodeId, body: *const fn (*IRawElementProviderSimple) void) void {
        if (self.registry.getNode(node_id) == null) return;
        if (CelerisUiaProvider.create(self.allocator, node_id, self.registry, self.store, self.hwnd, false, self.scale)) |p| {
            p.focused = self.focused;
            p.engine_id = self.engine_id;
            p.actions = self.actions;
            p.clients_listening = self.clients_listening;
            body(&p.simple);
            _ = p.release();
        } else |_| {}
    }

    /// Fires UIA_AutomationFocusChangedEvent for `node_id` so screen readers speak
    /// the newly focused control. The engine calls this from its single focus
    /// funnel; gated on a listening client so an unobserved app pays nothing.
    pub fn raiseFocusChanged(self: *CelerisUiaProvider, node_id: reg.NodeId) void {
        if (!self.is_root) return;
        if (!self.clients_listening()) return;
        self.withNodeSimple(node_id, struct {
            fn body(s: *IRawElementProviderSimple) void {
                _ = UiaRaiseAutomationEvent(s, UIA_AutomationFocusChangedEventId);
            }
        }.body);
    }

    /// Fires UIA_AutomationPropertyChangedEvent(`prop_id`) for `node_id`, carrying
    /// `value` as the new value (old = VT_EMPTY). Takes ownership of a VT_BSTR
    /// value and frees it after the raise. Gated on a listening client.
    pub fn raisePropertyChanged(self: *CelerisUiaProvider, node_id: reg.NodeId, prop_id: i32, value: VARIANT) void {
        // Own the BSTR from here on: free it on every path so no early return leaks.
        defer if (value.vt == VT_BSTR) SysFreeString(value.u.bstrVal);
        if (!self.is_root) return;
        if (!self.clients_listening()) return;
        if (self.registry.getNode(node_id) == null) return;
        if (CelerisUiaProvider.create(self.allocator, node_id, self.registry, self.store, self.hwnd, false, self.scale)) |p| {
            p.focused = self.focused;
            p.engine_id = self.engine_id;
            p.actions = self.actions;
            const empty = VARIANT{ .vt = VT_EMPTY, .u = .{ .padding = [_]u8{0} ** 8 } };
            _ = UiaRaiseAutomationPropertyChangedEvent(&p.simple, prop_id, empty, value);
            _ = p.release();
        } else |_| {}
    }

    fn root_ElementProviderFromPoint(root: *IRawElementProviderFragmentRoot, x: f64, y: f64, pRetVal: *?*IRawElementProviderFragment) callconv(WINAPI) HRESULT {
        const self: *CelerisUiaProvider = @fieldParentPtr("fragment_root", root);
        pRetVal.* = null;

        // UIA passes physical screen coordinates; the tree is in logical ones.
        var pt = POINT{ .x = 0, .y = 0 };
        _ = ClientToScreen(self.hwnd, &pt);
        const local = screenToLogical(x, y, pt.x, pt.y, self.scale);

        const walker = UiaTreeWalker{ .registry = self.registry, .store = self.store };
        const target = walker.hitTest(self.node_id, local.x, local.y);
        if (target == reg.NULL_NODE or target == self.node_id) return S_OK;

        self.yieldFragment(target, pRetVal);
        return S_OK;
    }
    fn root_GetFocus(root: *IRawElementProviderFragmentRoot, pRetVal: *?*IRawElementProviderFragment) callconv(WINAPI) HRESULT {
        const self: *CelerisUiaProvider = @fieldParentPtr("fragment_root", root);
        pRetVal.* = null;

        const slot = self.focused orelse return S_OK;
        const focused = slot.* orelse return S_OK;
        if (focused == reg.NULL_NODE or focused == self.node_id) return S_OK;
        if (self.registry.getNode(focused) == null) return S_OK;

        self.yieldFragment(focused, pRetVal);
        return S_OK;
    }
};
