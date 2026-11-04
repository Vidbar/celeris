using System.Collections.Generic;
using Celeris.Interop;

namespace Celeris.Core;

/// <summary>A node in the UI tree. The first element mounted becomes the window's root.</summary>
public abstract class Element
{
    internal uint NodeId { get; private set; }
    internal int EngineId { get; private set; }

    public List<Element> Children { get; } = new();
    public Layout Layout { get; set; } = new();
    public Style Style { get; set; } = new();

    public string? ActionId { get; set; }

    protected abstract uint NodeTypeValue { get; }

    internal virtual void Mount(int engineId, uint parentNodeId = uint.MaxValue)
    {
        EngineId = engineId;
        NodeId = (uint)Native.Check(CelerisInterop.celeris_node_create(engineId, NodeTypeValue), "node_create");

        Layout.Apply(engineId, NodeId);
        Style.Apply(engineId, NodeId);

        ApplyModifiers();

        foreach (var child in Children)
        {
            child.Mount(engineId, NodeId);
        }

        if (parentNodeId != uint.MaxValue)
        {
            Native.Check(CelerisInterop.celeris_node_append_child(engineId, parentNodeId, NodeId), "node_append_child");
        }
    }

    protected virtual void ApplyModifiers()
    {
        if (ActionId != null)
        {
            Native.Check(CelerisInterop.celeris_node_add_modifier(EngineId, NodeId, "clickable", ActionId), "modifier clickable");
            Native.Check(CelerisInterop.celeris_node_add_modifier(EngineId, NodeId, "hoverable", ActionId), "modifier hoverable");
        }
    }
}

public class Box : Element
{
    protected override uint NodeTypeValue => 0; // 0 = Box
}

public class Column : Box
{
    public Column()
    {
        Layout.FlexDirection = "column";
    }
}

public class Row : Box
{
    public Row()
    {
        Layout.FlexDirection = "row";
    }
}

public class TextElement : Element
{
    protected override uint NodeTypeValue => 1; // 1 = Text
    public string Content { get; set; }

    public TextElement(string content)
    {
        Content = content;
    }

    protected override void ApplyModifiers()
    {
        base.ApplyModifiers();
        Native.Check(CelerisInterop.celeris_node_set_text_content(EngineId, NodeId, Content), "node_set_text_content");
    }
}
