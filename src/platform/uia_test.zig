const std = @import("std");
const testing = std.testing;
const uia = @import("uia.zig");
const reg = @import("../core/registry.zig");
const props = @import("../core/properties.zig");
const a11y = @import("../core/accessibility.zig");

test "ariaRoleToControlType maps semantic roles to real UIA control types" {
    // The roles a11y.accessibleRole emits must land on their proper UIA type,
    // not collapse to Group. Unknown roles fall back to Group.
    try testing.expectEqual(uia.UIA_ButtonControlTypeId, uia.ariaRoleToControlType("button"));
    try testing.expectEqual(uia.UIA_CheckBoxControlTypeId, uia.ariaRoleToControlType("checkbox"));
    try testing.expectEqual(uia.UIA_CheckBoxControlTypeId, uia.ariaRoleToControlType("switch"));
    try testing.expectEqual(uia.UIA_RadioButtonControlTypeId, uia.ariaRoleToControlType("radio"));
    try testing.expectEqual(uia.UIA_EditControlTypeId, uia.ariaRoleToControlType("textbox"));
    try testing.expectEqual(uia.UIA_ComboBoxControlTypeId, uia.ariaRoleToControlType("combobox"));
    try testing.expectEqual(uia.UIA_ToolBarControlTypeId, uia.ariaRoleToControlType("toolbar"));
    try testing.expectEqual(uia.UIA_SeparatorControlTypeId, uia.ariaRoleToControlType("separator"));
    try testing.expectEqual(uia.UIA_TextControlTypeId, uia.ariaRoleToControlType("text"));
    try testing.expectEqual(uia.UIA_ImageControlTypeId, uia.ariaRoleToControlType("img"));
    try testing.expectEqual(uia.UIA_GroupControlTypeId, uia.ariaRoleToControlType("group"));
    try testing.expectEqual(uia.UIA_GroupControlTypeId, uia.ariaRoleToControlType("unknown-role"));
}

var g_stub_invoke_calls: u32 = 0;
var g_stub_invoke_node: reg.NodeId = reg.NULL_NODE;
var g_stub_invoke_engine: i32 = 0;
var g_stub_invoke_intent: uia.InvokeIntent = .activate;

fn stubInvoke(engine_id: i32, node_id: reg.NodeId, intent: uia.InvokeIntent) callconv(.c) void {
    g_stub_invoke_calls += 1;
    g_stub_invoke_node = node_id;
    g_stub_invoke_engine = engine_id;
    g_stub_invoke_intent = intent;
}

var g_stub_set_text_calls: u32 = 0;
var g_stub_set_text_buf: [256]u8 = undefined;
var g_stub_set_text_len: usize = 0;

fn stubSetText(engine_id: i32, node_id: reg.NodeId, text: [*]const u8, len: usize) callconv(.c) void {
    _ = engine_id;
    _ = node_id;
    g_stub_set_text_calls += 1;
    const n = @min(len, g_stub_set_text_buf.len);
    @memcpy(g_stub_set_text_buf[0..n], text[0..n]);
    g_stub_set_text_len = n;
}

var g_stub_focus_node: reg.NodeId = reg.NULL_NODE;

fn stubSetFocus(engine_id: i32, node_id: reg.NodeId) callconv(.c) void {
    _ = engine_id;
    g_stub_focus_node = node_id;
}

const stub_channel = uia.ActionChannel{ .invoke = stubInvoke, .set_text = stubSetText, .set_focus = stubSetFocus };

test "GetPatternProvider exposes Invoke on buttons and Toggle on checkboxes only" {
    var registry = reg.UIRegistry.init(testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);
    const dummy_hwnd: std.os.windows.HWND = @ptrFromInt(0x1234);

    const btn = try registry.createNode(.box);
    registry.nodes.items[btn].geometry = .{ .width = 40, .height = 20 };
    try store.registerNode(btn);
    try store.setModifier(btn, .role, .{ .string = try store.stringAllocator().dupe(u8, "button") });

    const cb = try registry.createNode(.box);
    registry.nodes.items[cb].geometry = .{ .width = 20, .height = 20 };
    try store.registerNode(cb);
    try store.setModifier(cb, .role, .{ .string = try store.stringAllocator().dupe(u8, "checkbox") });

    // Button: Invoke yes, Toggle no.
    var pb = try uia.CelerisUiaProvider.create(testing.allocator, btn, &registry, &store, dummy_hwnd, false, 1.0);
    defer pb.releaseRef();
    var out: ?*uia.IUnknown = null;
    _ = pb.simple.vtbl.GetPatternProvider(&pb.simple, uia.UIA_InvokePatternId, &out);
    try testing.expect(out != null);
    _ = out.?.vtbl.Release(out.?); // drop the ref GetPatternProvider added
    out = null;
    _ = pb.simple.vtbl.GetPatternProvider(&pb.simple, uia.UIA_TogglePatternId, &out);
    try testing.expect(out == null);

    // Checkbox: Toggle yes, Invoke no.
    var pc = try uia.CelerisUiaProvider.create(testing.allocator, cb, &registry, &store, dummy_hwnd, false, 1.0);
    defer pc.releaseRef();
    out = null;
    _ = pc.simple.vtbl.GetPatternProvider(&pc.simple, uia.UIA_TogglePatternId, &out);
    try testing.expect(out != null);
    _ = out.?.vtbl.Release(out.?);
    out = null;
    _ = pc.simple.vtbl.GetPatternProvider(&pc.simple, uia.UIA_InvokePatternId, &out);
    try testing.expect(out == null);
}

test "Invoke and Toggle fire the action channel on the real input path" {
    var registry = reg.UIRegistry.init(testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);
    const dummy_hwnd: std.os.windows.HWND = @ptrFromInt(0x1234);

    const btn = try registry.createNode(.box);
    registry.nodes.items[btn].geometry = .{ .width = 40, .height = 20 };
    try store.registerNode(btn);
    try store.setModifier(btn, .role, .{ .string = try store.stringAllocator().dupe(u8, "button") });

    var p = try uia.CelerisUiaProvider.create(testing.allocator, btn, &registry, &store, dummy_hwnd, false, 1.0);
    defer p.releaseRef();
    p.engine_id = 7;
    p.actions = &stub_channel;

    g_stub_invoke_calls = 0;
    g_stub_invoke_node = reg.NULL_NODE;
    _ = p.invoke.vtbl.Invoke(&p.invoke);
    try testing.expectEqual(@as(u32, 1), g_stub_invoke_calls);
    try testing.expectEqual(btn, g_stub_invoke_node);
    try testing.expectEqual(@as(i32, 7), g_stub_invoke_engine);
    try testing.expectEqual(uia.InvokeIntent.activate, g_stub_invoke_intent);

    // Toggle drives the same channel with the same (always-fire) intent.
    _ = p.toggle.vtbl.Toggle(&p.toggle);
    try testing.expectEqual(@as(u32, 2), g_stub_invoke_calls);
    try testing.expectEqual(uia.InvokeIntent.activate, g_stub_invoke_intent);
}

test "shouldActuate gates Expand/Collapse/Select on fresh state; activate always fires" {
    // The gate that used to run on the COM thread now runs on the UI thread via
    // this pure rule against fresh state.
    try testing.expect(uia.shouldActuate(.activate, false, false));
    try testing.expect(uia.shouldActuate(.activate, true, true));
    // Expand only when collapsed; Collapse only when expanded.
    try testing.expect(uia.shouldActuate(.expand, false, false));
    try testing.expect(!uia.shouldActuate(.expand, true, false));
    try testing.expect(uia.shouldActuate(.collapse, true, false));
    try testing.expect(!uia.shouldActuate(.collapse, false, false));
    // Select only when not already selected.
    try testing.expect(uia.shouldActuate(.select, false, false));
    try testing.expect(!uia.shouldActuate(.select, false, true));
}

test "get_ToggleState reflects the checked modifier" {
    var registry = reg.UIRegistry.init(testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);
    const dummy_hwnd: std.os.windows.HWND = @ptrFromInt(0x1234);

    const cb = try registry.createNode(.box);
    try store.registerNode(cb);
    try store.setModifier(cb, .role, .{ .string = try store.stringAllocator().dupe(u8, "checkbox") });

    var p = try uia.CelerisUiaProvider.create(testing.allocator, cb, &registry, &store, dummy_hwnd, false, 1.0);
    defer p.releaseRef();

    var state: uia.ToggleState = .Indeterminate;
    _ = p.toggle.vtbl.get_ToggleState(&p.toggle, &state);
    try testing.expectEqual(uia.ToggleState.Off, state);

    try store.setModifier(cb, .checked, .{ .boolean = true });
    _ = p.toggle.vtbl.get_ToggleState(&p.toggle, &state);
    try testing.expectEqual(uia.ToggleState.On, state);
}

extern "oleaut32" fn SysAllocString(str: [*:0]const u16) callconv(std.builtin.CallingConvention.winapi) ?*u16;

test "ValuePattern: GetPatternProvider gates on textbox; SetValue drives set_text" {
    var registry = reg.UIRegistry.init(testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);
    const dummy_hwnd: std.os.windows.HWND = @ptrFromInt(0x1234);

    const edit = try registry.createNode(.box);
    try store.registerNode(edit);
    try store.setModifier(edit, .role, .{ .string = try store.stringAllocator().dupe(u8, "textbox") });

    var p = try uia.CelerisUiaProvider.create(testing.allocator, edit, &registry, &store, dummy_hwnd, false, 1.0);
    defer p.releaseRef();
    p.actions = &stub_channel;

    // Value pattern is exposed; Invoke is not.
    var out: ?*uia.IUnknown = null;
    _ = p.simple.vtbl.GetPatternProvider(&p.simple, uia.UIA_ValuePatternId, &out);
    try testing.expect(out != null);
    _ = out.?.vtbl.Release(out.?);
    out = null;
    _ = p.simple.vtbl.GetPatternProvider(&p.simple, uia.UIA_InvokePatternId, &out);
    try testing.expect(out == null);

    // SetValue decodes the UTF-16 BSTR and hands the UTF-8 to the channel.
    const bstr = SysAllocString(std.unicode.utf8ToUtf16LeStringLiteral("Hola"));
    defer uia.SysFreeString(bstr);
    g_stub_set_text_calls = 0;
    g_stub_set_text_len = 0;
    _ = p.value.vtbl.SetValue(&p.value, bstr);
    try testing.expectEqual(@as(u32, 1), g_stub_set_text_calls);
    try testing.expectEqualStrings("Hola", g_stub_set_text_buf[0..g_stub_set_text_len]);
    // The read-only guard now runs on the UI thread in setNodeTextViaInput (against
    // fresh state), not in the COM-thread SetValue — so it isn't observable here.
}

test "ValuePattern: get_IsReadOnly and get_Value reflect the store" {
    var registry = reg.UIRegistry.init(testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);
    const dummy_hwnd: std.os.windows.HWND = @ptrFromInt(0x1234);

    // A textbox whose displayed value lives on a child text node (TextInput shape).
    const edit = try registry.createNode(.box);
    try store.registerNode(edit);
    try store.setModifier(edit, .role, .{ .string = try store.stringAllocator().dupe(u8, "textbox") });
    const txt = try registry.createNode(.text);
    try store.registerNode(txt);
    registry.appendChild(edit, txt);
    store.setTextContent(txt, try store.stringAllocator().dupe(u8, "abc"));

    var p = try uia.CelerisUiaProvider.create(testing.allocator, edit, &registry, &store, dummy_hwnd, false, 1.0);
    defer p.releaseRef();

    var ro: std.os.windows.BOOL = .TRUE;
    _ = p.value.vtbl.get_IsReadOnly(&p.value, &ro);
    try testing.expectEqual(std.os.windows.BOOL.FALSE, ro);
    try store.setModifier(edit, .readonly, .{ .boolean = true });
    _ = p.value.vtbl.get_IsReadOnly(&p.value, &ro);
    try testing.expectEqual(std.os.windows.BOOL.TRUE, ro);

    // get_Value returns the child text; free the BSTR it hands back.
    var val: ?*u16 = null;
    _ = p.value.vtbl.get_Value(&p.value, &val);
    try testing.expect(val != null);
    const len = std.mem.len(@as([*:0]const u16, @ptrCast(val.?)));
    var u8buf: [16]u8 = undefined;
    const n = try std.unicode.utf16LeToUtf8(&u8buf, @as([*]const u16, @ptrCast(val.?))[0..len]);
    try testing.expectEqualStrings("abc", u8buf[0..n]);
    uia.SysFreeString(val);
}

test "ValuePattern: exposed via the cursor=text inference (real TextInput shape, no explicit role)" {
    var registry = reg.UIRegistry.init(testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);
    const dummy_hwnd: std.os.windows.HWND = @ptrFromInt(0x1234);

    // Mirror what TextInput.build produces: a clickable+focusable box whose only
    // "textbox" signal is the I-beam cursor modifier (NO explicit .role), with the
    // displayed value on a child text node.
    const edit = try registry.createNode(.box);
    try store.registerNode(edit);
    try store.setModifier(edit, .cursor, .{ .string = try store.stringAllocator().dupe(u8, "text") });
    try store.setModifier(edit, .clickable, .{ .string = try store.stringAllocator().dupe(u8, "n1") });
    try store.setModifier(edit, .focusable, .{ .string = try store.stringAllocator().dupe(u8, "n1") });
    const txt = try registry.createNode(.text);
    try store.registerNode(txt);
    registry.appendChild(edit, txt);
    store.setTextContent(txt, try store.stringAllocator().dupe(u8, "abc"));

    var p = try uia.CelerisUiaProvider.create(testing.allocator, edit, &registry, &store, dummy_hwnd, false, 1.0);
    defer p.releaseRef();

    // ControlType must be Edit AND the Value pattern must be exposed off the same node.
    var variant: uia.VARIANT = undefined;
    _ = p.simple.vtbl.GetPropertyValue(&p.simple, uia.UIA_ControlTypePropertyId, &variant);
    try testing.expectEqual(uia.UIA_EditControlTypeId, variant.u.lVal);

    var out: ?*uia.IUnknown = null;
    _ = p.simple.vtbl.GetPatternProvider(&p.simple, uia.UIA_ValuePatternId, &out);
    try testing.expect(out != null);
    _ = out.?.vtbl.Release(out.?);
}

test "ExpandCollapse: state tracks .expanded; Expand/Collapse pass the right intent" {
    var registry = reg.UIRegistry.init(testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);
    const dummy_hwnd: std.os.windows.HWND = @ptrFromInt(0x1234);

    const combo = try registry.createNode(.box);
    try store.registerNode(combo);
    try store.setModifier(combo, .role, .{ .string = try store.stringAllocator().dupe(u8, "combobox") });

    var p = try uia.CelerisUiaProvider.create(testing.allocator, combo, &registry, &store, dummy_hwnd, false, 1.0);
    defer p.releaseRef();
    p.actions = &stub_channel;

    // Pattern is exposed for a combobox.
    var out: ?*uia.IUnknown = null;
    _ = p.simple.vtbl.GetPatternProvider(&p.simple, uia.UIA_ExpandCollapsePatternId, &out);
    try testing.expect(out != null);
    _ = out.?.vtbl.Release(out.?);

    // Collapsed initially; flips to Expanded when the modifier is set.
    var state: uia.ExpandCollapseState = .PartiallyExpanded;
    _ = p.expand.vtbl.get_ExpandCollapseState(&p.expand, &state);
    try testing.expectEqual(uia.ExpandCollapseState.Collapsed, state);
    try store.setModifier(combo, .expanded, .{ .boolean = true });
    _ = p.expand.vtbl.get_ExpandCollapseState(&p.expand, &state);
    try testing.expectEqual(uia.ExpandCollapseState.Expanded, state);

    // Expand/Collapse each fire the channel with their intent; whether the click
    // actually runs is decided on the UI thread by shouldActuate (tested above).
    g_stub_invoke_calls = 0;
    _ = p.expand.vtbl.Expand(&p.expand);
    try testing.expectEqual(@as(u32, 1), g_stub_invoke_calls);
    try testing.expectEqual(uia.InvokeIntent.expand, g_stub_invoke_intent);
    _ = p.expand.vtbl.Collapse(&p.expand);
    try testing.expectEqual(@as(u32, 2), g_stub_invoke_calls);
    try testing.expectEqual(uia.InvokeIntent.collapse, g_stub_invoke_intent);
}

test "SelectionItem: IsSelected tracks .checked; Select passes the select intent" {
    var registry = reg.UIRegistry.init(testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);
    const dummy_hwnd: std.os.windows.HWND = @ptrFromInt(0x1234);

    const rb = try registry.createNode(.box);
    try store.registerNode(rb);
    try store.setModifier(rb, .role, .{ .string = try store.stringAllocator().dupe(u8, "radio") });

    var p = try uia.CelerisUiaProvider.create(testing.allocator, rb, &registry, &store, dummy_hwnd, false, 1.0);
    defer p.releaseRef();
    p.actions = &stub_channel;

    var out: ?*uia.IUnknown = null;
    _ = p.simple.vtbl.GetPatternProvider(&p.simple, uia.UIA_SelectionItemPatternId, &out);
    try testing.expect(out != null);
    _ = out.?.vtbl.Release(out.?);

    var sel: std.os.windows.BOOL = .TRUE;
    _ = p.select.vtbl.get_IsSelected(&p.select, &sel);
    try testing.expectEqual(std.os.windows.BOOL.FALSE, sel);

    // Select fires the channel with the select intent; the "only when unselected"
    // gate runs on the UI thread (shouldActuate, tested above).
    g_stub_invoke_calls = 0;
    _ = p.select.vtbl.Select(&p.select);
    try testing.expectEqual(@as(u32, 1), g_stub_invoke_calls);
    try testing.expectEqual(uia.InvokeIntent.select, g_stub_invoke_intent);

    // IsSelected tracks .checked.
    try store.setModifier(rb, .checked, .{ .boolean = true });
    _ = p.select.vtbl.get_IsSelected(&p.select, &sel);
    try testing.expectEqual(std.os.windows.BOOL.TRUE, sel);
}

test "variant builders tag VARIANTs correctly (VARIANT_TRUE is -1)" {
    // The raise path itself (UiaRaiseAutomationEvent / property-changed) is Windows
    // integration validated with Inspect.exe/NVDA, not a unit test — a bogus HWND
    // into the real API is unsafe. What we can pin here is the VARIANT encoding the
    // engine hands it, since a wrong tag would misreport state to a screen reader.
    const vi = uia.variantI4(1);
    try testing.expectEqual(uia.VT_I4, vi.vt);
    try testing.expectEqual(@as(i32, 1), vi.u.lVal);

    const bt = uia.variantBool(true);
    try testing.expectEqual(uia.VT_BOOL, bt.vt);
    try testing.expectEqual(@as(i16, -1), bt.u.boolVal); // Win32 VARIANT_TRUE
    const bf = uia.variantBool(false);
    try testing.expectEqual(@as(i16, 0), bf.u.boolVal);

    const bs = uia.variantBStr("hi");
    try testing.expectEqual(uia.VT_BSTR, bs.vt);
    try testing.expect(bs.u.bstrVal != null);
    uia.SysFreeString(bs.u.bstrVal); // we own it when a raise doesn't consume it
}

test "UIA Provider Navigation and RefCounting" {
    var registry = reg.UIRegistry.init(testing.allocator);
    defer registry.deinit();

    var store = props.PropertyStore.init(testing.allocator);
    defer store.deinit();

    // Create a tree:
    // Root (0)
    //  |- Child1 (1)
    //  |- Child2 (2)

    const root_id = try registry.createNode(.box);
    registry.nodes.items[root_id].geometry = .{ .width = 100, .height = 100 };
    try store.registerNode(root_id);
    const child1_id = try registry.createNode(.box);
    registry.nodes.items[child1_id].geometry = .{ .width = 50, .height = 50 };
    try store.registerNode(child1_id);
    const child2_id = try registry.createNode(.text);
    registry.nodes.items[child2_id].geometry = .{ .width = 50, .height = 50 };
    try store.registerNode(child2_id);

    registry.appendChild(root_id, child1_id);
    registry.appendChild(root_id, child2_id); // child2 after child1

    // Add some properties
    store.setTextContent(child2_id, try store.stringAllocator().dupe(u8, "Hello UIA"));
    try store.setModifier(child1_id, .role, .{ .string = try store.stringAllocator().dupe(u8, "button") });

    const dummy_hwnd: std.os.windows.HWND = @ptrFromInt(0x1234);

    // Create Root Provider
    var root_provider = try uia.CelerisUiaProvider.create(testing.allocator, root_id, &registry, &store, dummy_hwnd, true, 1.0);
    defer {
        _ = root_provider.simple.vtbl.Release(&root_provider.simple);
    }

    try testing.expectEqual(@as(u32, 1), root_provider.ref_count);

    // Test Navigate (FirstChild)
    var frag_child1: ?*uia.IRawElementProviderFragment = null;
    var hr = root_provider.fragment.vtbl.Navigate(&root_provider.fragment, .FirstChild, &frag_child1);
    try testing.expectEqual(uia.S_OK, hr);
    try testing.expect(frag_child1 != null);
    const fc1 = frag_child1.?;
    defer _ = fc1.vtbl.Release(fc1);

    // Verify Child1 Provider
    const child1_provider: *uia.CelerisUiaProvider = @fieldParentPtr("fragment", frag_child1.?);
    try testing.expectEqual(child1_id, child1_provider.node_id);
    try testing.expectEqual(@as(u32, 1), child1_provider.ref_count);

    // Test GetPropertyValue (ControlType for button)
    var variant: uia.VARIANT = undefined;
    hr = child1_provider.simple.vtbl.GetPropertyValue(&child1_provider.simple, uia.UIA_ControlTypePropertyId, &variant);
    try testing.expectEqual(uia.S_OK, hr);
    try testing.expectEqual(uia.VT_I4, variant.vt);
    try testing.expectEqual(uia.UIA_ButtonControlTypeId, variant.u.lVal);

    // Test Navigate (NextSibling from Child1)
    var frag_child2: ?*uia.IRawElementProviderFragment = null;
    hr = frag_child1.?.vtbl.Navigate(frag_child1.?, .NextSibling, &frag_child2);
    try testing.expectEqual(uia.S_OK, hr);
    try testing.expect(frag_child2 != null);
    const fc2 = frag_child2.?;
    defer _ = fc2.vtbl.Release(fc2);

    const child2_provider: *uia.CelerisUiaProvider = @fieldParentPtr("fragment", frag_child2.?);
    try testing.expectEqual(child2_id, child2_provider.node_id);

    // Test GetPropertyValue (Name for text)
    hr = child2_provider.simple.vtbl.GetPropertyValue(&child2_provider.simple, uia.UIA_NamePropertyId, &variant);
    try testing.expectEqual(uia.S_OK, hr);
    try testing.expectEqual(uia.VT_BSTR, variant.vt);
    // BSTR is UTF-16, let's just ensure it's not null and we free it
    try testing.expect(variant.u.bstrVal != null);
    uia.SysFreeString(variant.u.bstrVal);

    // GetRuntimeId must hand back a real SAFEARRAY, and a distinct one per node.
    var rid_root: ?*anyopaque = null;
    hr = root_provider.fragment.vtbl.GetRuntimeId(&root_provider.fragment, &rid_root);
    try testing.expectEqual(uia.S_OK, hr);
    try testing.expect(rid_root != null);
    uia.destroyRuntimeId(rid_root);

    // GetFocus reports nothing when the host doesn't track focus...
    var focus_frag: ?*uia.IRawElementProviderFragment = null;
    hr = root_provider.fragment_root.vtbl.GetFocus(&root_provider.fragment_root, &focus_frag);
    try testing.expectEqual(uia.S_OK, hr);
    try testing.expect(focus_frag == null);

    // ...and returns the focused node once wired to a focus slot.
    const focus_slot: ?reg.NodeId = child1_id;
    root_provider.focused = &focus_slot;
    hr = root_provider.fragment_root.vtbl.GetFocus(&root_provider.fragment_root, &focus_frag);
    try testing.expectEqual(uia.S_OK, hr);
    try testing.expect(focus_frag != null);
    const ff = focus_frag.?;
    defer _ = ff.vtbl.Release(ff);
    const focus_provider: *uia.CelerisUiaProvider = @fieldParentPtr("fragment", ff);
    try testing.expectEqual(child1_id, focus_provider.node_id);
}

test "uia computeScreenBounds at 1.0 scale" {
    const geom = reg.Geometry{ .x = 10.5, .y = 20.5, .width = 100, .height = 50 };
    const bounds = uia.CelerisUiaProvider.computeScreenBounds(geom, 200, 150, 1.0);
    try testing.expectEqual(@as(f64, 210.5), bounds[0]);
    try testing.expectEqual(@as(f64, 170.5), bounds[1]);
    try testing.expectEqual(@as(f64, 100.0), bounds[2]);
    try testing.expectEqual(@as(f64, 50.0), bounds[3]);
}

test "uia computeScreenBounds applies DPI scale" {
    // 150% HiDPI: logical geometry must be scaled to physical pixels, while the
    // client offset from ClientToScreen is already physical and is not scaled.
    const geom = reg.Geometry{ .x = 10, .y = 20, .width = 100, .height = 50 };
    const bounds = uia.CelerisUiaProvider.computeScreenBounds(geom, 200, 150, 1.5);
    try testing.expectEqual(@as(f64, 215.0), bounds[0]); // 10*1.5 + 200
    try testing.expectEqual(@as(f64, 180.0), bounds[1]); // 20*1.5 + 150
    try testing.expectEqual(@as(f64, 150.0), bounds[2]);
    try testing.expectEqual(@as(f64, 75.0), bounds[3]);
}

test "uia screenToLogical inverts computeScreenBounds" {
    const geom = reg.Geometry{ .x = 40, .y = 60, .width = 10, .height = 10 };
    const bounds = uia.CelerisUiaProvider.computeScreenBounds(geom, 200, 150, 2.0);
    const local = uia.CelerisUiaProvider.screenToLogical(bounds[0], bounds[1], 200, 150, 2.0);
    try testing.expectApproxEqAbs(@as(f32, 40), local.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 60), local.y, 0.001);
}

test "uia computeRuntimeId is unique per node and UIA-prefixed" {
    const a = uia.CelerisUiaProvider.computeRuntimeId(7);
    const b = uia.CelerisUiaProvider.computeRuntimeId(8);
    try testing.expectEqual(uia.UiaAppendRuntimeId, a[0]);
    try testing.expectEqual(@as(i32, 7), a[1]);
    try testing.expect(!std.mem.eql(i32, &a, &b));
}

test "uia GetPropertyValue reports IsEnabled from the disabled modifier" {
    var registry = reg.UIRegistry.init(testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(testing.allocator);
    defer store.deinit();
    store.setRegistry(&registry);

    const enabled_id = try registry.createNode(.box);
    registry.nodes.items[enabled_id].geometry = .{ .width = 50, .height = 50 };
    try store.registerNode(enabled_id);

    const disabled_id = try registry.createNode(.box);
    registry.nodes.items[disabled_id].geometry = .{ .width = 50, .height = 50 };
    try store.registerNode(disabled_id);
    try store.setModifier(disabled_id, .disabled, .{ .boolean = true });

    const dummy_hwnd: std.os.windows.HWND = @ptrFromInt(0x1234);

    // An element with no `disabled` modifier must report enabled, or UIA
    // automation refuses to invoke it and nothing in the window is clickable.
    var p1 = try uia.CelerisUiaProvider.create(testing.allocator, enabled_id, &registry, &store, dummy_hwnd, false, 1.0);
    defer _ = p1.simple.vtbl.Release(&p1.simple);
    var variant: uia.VARIANT = undefined;
    var hr = p1.simple.vtbl.GetPropertyValue(&p1.simple, uia.UIA_IsEnabledPropertyId, &variant);
    try testing.expectEqual(uia.S_OK, hr);
    try testing.expectEqual(uia.VT_BOOL, variant.vt);
    try testing.expectEqual(@as(i16, -1), variant.u.boolVal); // VARIANT_TRUE

    var p2 = try uia.CelerisUiaProvider.create(testing.allocator, disabled_id, &registry, &store, dummy_hwnd, false, 1.0);
    defer _ = p2.simple.vtbl.Release(&p2.simple);
    hr = p2.simple.vtbl.GetPropertyValue(&p2.simple, uia.UIA_IsEnabledPropertyId, &variant);
    try testing.expectEqual(uia.S_OK, hr);
    try testing.expectEqual(uia.VT_BOOL, variant.vt);
    try testing.expectEqual(@as(i16, 0), variant.u.boolVal); // VARIANT_FALSE
}

test "uia navigate descends through zero-sized wrappers" {
    // Reproduces the reported empty content Group: a sized container whose
    // children hang under zero-sized wrappers. Pruning at the wrapper hid the
    // whole subtree, so Navigate reported no children at all.
    var registry = reg.UIRegistry.init(testing.allocator);
    defer registry.deinit();

    const content = try registry.createNode(.box);
    registry.nodes.items[content].geometry = .{ .x = 0, .y = 0, .width = 882, .height = 622 };

    // Zero-sized wrapper holding two real, visible controls.
    const wrapper = try registry.createNode(.box);
    registry.nodes.items[wrapper].geometry = .{ .width = 0, .height = 0 };
    const search = try registry.createNode(.box);
    registry.nodes.items[search].geometry = .{ .x = 0, .y = 0, .width = 200, .height = 24 };
    const refresh = try registry.createNode(.box);
    registry.nodes.items[refresh].geometry = .{ .x = 210, .y = 0, .width = 48, .height = 24 };

    // A directly-visible sibling after the wrapper.
    const list = try registry.createNode(.box);
    registry.nodes.items[list].geometry = .{ .x = 0, .y = 30, .width = 882, .height = 580 };

    registry.appendChild(content, wrapper);
    registry.appendChild(wrapper, search);
    registry.appendChild(wrapper, refresh);
    registry.appendChild(content, list);

    var store = props.PropertyStore.init(testing.allocator);
    defer store.deinit();
    const walker = uia.CelerisUiaProvider.UiaTreeWalker{ .registry = &registry, .store = &store };

    // The wrapper is transparent: its children are hoisted into `content`.
    try testing.expectEqual(search, walker.navigate(content, .FirstChild));
    try testing.expectEqual(refresh, walker.navigate(search, .NextSibling));
    try testing.expectEqual(list, walker.navigate(refresh, .NextSibling));
    try testing.expectEqual(reg.NULL_NODE, walker.navigate(list, .NextSibling));
    try testing.expectEqual(list, walker.navigate(content, .LastChild));

    // Walking back gives the same order.
    try testing.expectEqual(refresh, walker.navigate(list, .PreviousSibling));
    try testing.expectEqual(search, walker.navigate(refresh, .PreviousSibling));
    try testing.expectEqual(reg.NULL_NODE, walker.navigate(search, .PreviousSibling));

    // Parent agrees with the flattened child list — both skip the wrapper.
    try testing.expectEqual(content, walker.navigate(search, .Parent));
    try testing.expectEqual(content, walker.navigate(refresh, .Parent));

    // Hit-testing must see through the wrapper too.
    try testing.expectEqual(refresh, walker.hitTest(content, 230, 10));
}

test "uia hitTest finds deepest node and prefers later siblings" {
    var registry = reg.UIRegistry.init(testing.allocator);
    defer registry.deinit();

    // root (0,0,200x200) > child (50,50,100x100) > grandchild (60,60,20x20)
    const root = try registry.createNode(.box);
    registry.nodes.items[root].geometry = .{ .x = 0, .y = 0, .width = 200, .height = 200 };
    const child = try registry.createNode(.box);
    registry.nodes.items[child].geometry = .{ .x = 50, .y = 50, .width = 100, .height = 100 };
    const grandchild = try registry.createNode(.box);
    registry.nodes.items[grandchild].geometry = .{ .x = 60, .y = 60, .width = 20, .height = 20 };
    // Overlapping later sibling of `child`, painted on top.
    const overlay = try registry.createNode(.box);
    registry.nodes.items[overlay].geometry = .{ .x = 100, .y = 100, .width = 100, .height = 100 };

    registry.appendChild(root, child);
    registry.appendChild(child, grandchild);
    registry.appendChild(root, overlay);

    var store = props.PropertyStore.init(testing.allocator);
    defer store.deinit();
    const walker = uia.CelerisUiaProvider.UiaTreeWalker{ .registry = &registry, .store = &store };

    try testing.expectEqual(grandchild, walker.hitTest(root, 65, 65));
    try testing.expectEqual(child, walker.hitTest(root, 55, 90));
    try testing.expectEqual(root, walker.hitTest(root, 5, 5));
    // Inside both `child` and `overlay`; the later sibling wins.
    try testing.expectEqual(overlay, walker.hitTest(root, 120, 120));
    // Outside the root entirely.
    try testing.expectEqual(reg.NULL_NODE, walker.hitTest(root, 500, 500));
}

test "uia UiaTreeWalker" {
    var registry = reg.UIRegistry.init(testing.allocator);
    defer registry.deinit();

    // Node 0: visible parent
    const n0 = try registry.createNode(.box);
    registry.nodes.items[n0].geometry = .{ .width = 100, .height = 100 };

    // Node 1: invisible child
    const n1 = try registry.createNode(.box);
    registry.nodes.items[n1].geometry = .{ .width = 0, .height = 0 };

    // Node 2: visible child
    const n2 = try registry.createNode(.box);
    registry.nodes.items[n2].geometry = .{ .width = 50, .height = 50 };

    registry.appendChild(n0, n1);
    registry.appendChild(n0, n2);

    var store = props.PropertyStore.init(testing.allocator);
    defer store.deinit();
    const walker = uia.CelerisUiaProvider.UiaTreeWalker{ .registry = &registry, .store = &store };

    // n0 -> FirstChild -> skips n1 (0-size) -> returns n2
    try testing.expectEqual(n2, walker.navigate(n0, .FirstChild));
    // n2 -> PreviousSibling -> skips n1 (0-size) -> returns NULL
    try testing.expectEqual(reg.NULL_NODE, walker.navigate(n2, .PreviousSibling));
    // n0 -> LastChild -> n2
    try testing.expectEqual(n2, walker.navigate(n0, .LastChild));
}

test "uia UiaTreeWalker: a closed Menu-style panel hides its rows via clipping, not just their own geometry" {
    // Regression: `Menu`'s panel keeps a nonzero width even when closed (it's
    // content-measured) and only its *height* collapses to 0 via
    // `overflow_hidden`; the rows inside keep their own fixed (nonzero) row
    // geometry regardless. A geometry-only visibility check therefore saw the
    // rows as visible — named, bounded, and invocable via UIA — even while
    // the panel was closed.
    var registry = reg.UIRegistry.init(testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(testing.allocator);
    defer store.deinit();

    const panel = try registry.createNode(.box);
    registry.nodes.items[panel].geometry = .{ .x = 200, .y = 150, .width = 200, .height = 0 };
    try store.registerNode(panel);
    try store.setModifier(panel, .overflow_hidden, .{ .number = 1 });

    const row = try registry.createNode(.box);
    registry.nodes.items[row].geometry = .{ .x = 200, .y = 154, .width = 200, .height = 28 };
    try store.registerNode(row);
    registry.appendChild(panel, row);

    const walker = uia.CelerisUiaProvider.UiaTreeWalker{ .registry = &registry, .store = &store };

    try testing.expect(!walker.isNodeVisible(row));
    try testing.expectEqual(reg.NULL_NODE, walker.navigate(panel, .FirstChild));

    // Once "opened" (panel regains height), the row is visible again.
    registry.nodes.items[panel].geometry.height = 100;
    try testing.expect(walker.isNodeVisible(row));
    try testing.expectEqual(row, walker.navigate(panel, .FirstChild));
}

test "uia UiaTreeWalker.hitTest: a z-indexed overlay wins over content built later in document order" {
    // Regression: a `Menu` row overlaps page content — same as this suite's
    // other regression, but content built AFTER the menu in document order
    // (as it typically is: a MenuBar sits at the top of the tree, the app
    // body after it). The old `hitTest` walked children in plain document
    // order ("later sibling wins", no z-index), so a later-built body node
    // under the menu's open panel out-"won" the panel's own `z-index: 100` —
    // ElementFromPoint (and any UIA client using it: Inspect.exe,
    // WinAppDriver, Playwright for Windows, a screen reader's point
    // navigation) picked the body content instead of the menu row a real
    // mouse click actually lands on.
    var registry = reg.UIRegistry.init(testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(testing.allocator);
    defer store.deinit();

    const root = try registry.createNode(.box);
    registry.nodes.items[root].geometry = .{ .x = 0, .y = 0, .width = 800, .height = 600 };
    try store.registerNode(root);

    // Menu overlay, built FIRST (document order), sits over the point at
    // z-index 100 (matches `menu.zig`'s panel).
    const menu_panel = try registry.createNode(.box);
    registry.nodes.items[menu_panel].geometry = .{ .x = 600, .y = 300, .width = 200, .height = 100 };
    try store.registerNode(menu_panel);
    try store.setStyle(menu_panel, .z_index, .{ .number = 100 });
    registry.appendChild(root, menu_panel);

    const menu_row = try registry.createNode(.box);
    registry.nodes.items[menu_row].geometry = .{ .x = 600, .y = 320, .width = 200, .height = 28 };
    try store.registerNode(menu_row);
    registry.appendChild(menu_panel, menu_row);

    // Body content, built AFTER the menu, at the default z-index (0), covering
    // the same point.
    const body = try registry.createNode(.box);
    registry.nodes.items[body].geometry = .{ .x = 0, .y = 0, .width = 800, .height = 600 };
    try store.registerNode(body);
    registry.appendChild(root, body);

    const taskbar_row = try registry.createNode(.box);
    registry.nodes.items[taskbar_row].geometry = .{ .x = 600, .y = 320, .width = 200, .height = 28 };
    try store.registerNode(taskbar_row);
    registry.appendChild(body, taskbar_row);

    const walker = uia.CelerisUiaProvider.UiaTreeWalker{ .registry = &registry, .store = &store };

    // The point sits inside both `menu_row` and `taskbar_row`; the menu's
    // z-index must win despite being built (and thus visited) first.
    try testing.expectEqual(menu_row, walker.hitTest(root, 650, 330));
}

test "uia UiaTreeWalker: a Menu row's decorative label Text is transparent to Navigate and ElementFromPoint" {
    // Pending item from the sibling reports on closed-menu rows: once a Menu
    // row carries its own accessible name (menu.zig's `b.ariaLabel(row, ...)`),
    // its checkmark/label `Text` children are pure noise — `a11y.isControlElement`
    // already flags them `IsControlElement=false`, but the raw UIA tree
    // (`Navigate`) and `ElementFromPoint` still walked into them as their own
    // elements, unnamed, with just their own leaf geometry. They must be
    // transparent, like a zero-sized layout wrapper: skipped in the flattened
    // child list, and never the answer to a point that lands on them — the
    // row (which already speaks for them) is.
    var registry = reg.UIRegistry.init(testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(testing.allocator);
    defer store.deinit();

    const row = try registry.createNode(.box);
    registry.nodes.items[row].geometry = .{ .x = 200, .y = 150, .width = 200, .height = 28 };
    try store.registerNode(row);
    try store.setModifier(row, .clickable, .{ .string = try store.stringAllocator().dupe(u8, "cut") });
    try store.setModifier(row, .label, .{ .string = try store.stringAllocator().dupe(u8, "Cut") });

    const label = try registry.createNode(.text);
    registry.nodes.items[label].geometry = .{ .x = 212, .y = 154, .width = 40, .height = 20 };
    try store.registerNode(label);
    registry.appendChild(row, label);

    const walker = uia.CelerisUiaProvider.UiaTreeWalker{ .registry = &registry, .store = &store };

    // The label is demoted (its ancestor `row` is role="button" via `clickable`).
    try testing.expect(!a11y.isControlElement(&registry, &store, label));

    // Navigate never surfaces it as a child — the row looks childless.
    try testing.expectEqual(reg.NULL_NODE, walker.navigate(row, .FirstChild));

    // A point inside the label's own bounds resolves to the row, not the label.
    try testing.expectEqual(row, walker.hitTest(row, 220, 160));
}

test "uia accessibleName: a Menu's dismiss backdrop carries an explicit name, not empty" {
    // Regression: the root Menu's full-window dismiss backdrop is `clickableAuto`'d
    // (hoisting it to UIA role Button, per `a11y.isControlElement`) so it can catch
    // outside clicks, but menu.zig never set `ariaLabel` on it — same class of bug
    // fixed for rows in 9a465a9 (rows named themselves after checkmark glyphs).
    // Screen readers/UIA would report an unnamed Button spanning the whole panel.
    var registry = reg.UIRegistry.init(testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(testing.allocator);
    defer store.deinit();

    const backdrop = try registry.createNode(.box);
    try store.registerNode(backdrop);
    try store.setModifier(backdrop, .clickable, .{ .string = try store.stringAllocator().dupe(u8, "dismiss") });
    try store.setModifier(backdrop, .label, .{ .string = try store.stringAllocator().dupe(u8, "Close menu") });

    try testing.expect(a11y.isControlElement(&registry, &store, backdrop));
    try testing.expectEqualStrings("Close menu", a11y.accessibleName(&registry, &store, backdrop));
}

fn stubClientsListeningTrue() bool {
    return true;
}

// raiseFocusChanged/raisePropertyChanged early-return whenever
// UiaClientsAreListening() (the real extern) reports no client — which is always,
// in CI, since no screen reader is attached. Without overriding the policy, this
// test would pass even if the create()/release() pairing inside those functions
// were broken, because the body would never run. `clients_listening` exists
// precisely so this path is reachable from a unit test.
test "raiseFocusChanged/raisePropertyChanged do not leak the throwaway provider" {
    var registry = reg.UIRegistry.init(testing.allocator);
    defer registry.deinit();
    var store = props.PropertyStore.init(testing.allocator);
    defer store.deinit();

    const root_id = try registry.createNode(.box);
    try store.registerNode(root_id);
    const child_id = try registry.createNode(.box);
    try store.registerNode(child_id);
    registry.appendChild(root_id, child_id);

    const dummy_hwnd: std.os.windows.HWND = @ptrFromInt(0x1234);
    var root_provider = try uia.CelerisUiaProvider.create(testing.allocator, root_id, &registry, &store, dummy_hwnd, true, 1.0);
    defer _ = root_provider.simple.vtbl.Release(&root_provider.simple);
    root_provider.clients_listening = stubClientsListeningTrue;

    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        root_provider.raiseFocusChanged(child_id);
        root_provider.raisePropertyChanged(child_id, uia.UIA_ValueValuePropertyId, uia.variantI4(1));
    }
    // testing.allocator's DebugAllocator asserts zero leaks at test teardown —
    // if any temp provider from the 100 calls above wasn't released, this test
    // fails right here without any explicit assertion needed.
}
