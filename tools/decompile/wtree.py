"""Print a UMG widget tree from a UAssetGUI tojson dump: hierarchy + style properties.
usage: python -I wtree.py <asset.json> [--props]"""
import json, sys

d = json.load(open(sys.argv[1], encoding="utf-8"))
imports, exports = d["Imports"], d["Exports"]


def name(i):
    if i is None or i == 0:
        return None
    if i < 0:
        return imports[-i - 1]["ObjectName"]
    return exports[i - 1]["ObjectName"]


def cls(e):
    return name(e.get("ClassIndex"))


def props(e):
    return {p.get("Name"): p for p in (e.get("Data") or [])}


def short(p, depth=0):
    """compact value of a property"""
    t = p.get("$type", "").split(".")[-1].split(",")[0]
    v = p.get("Value")
    if t in ("ObjectPropertyData",):
        return name(v)
    if t in ("TextPropertyData",):
        return repr(p.get("CultureInvariantString") or p.get("SourceString") or (p.get("Value") or ""))
    if t in ("StrPropertyData", "NamePropertyData", "EnumPropertyData", "BytePropertyData"):
        return str(v if v is not None else p.get("EnumValue"))
    if t in ("BoolPropertyData", "FloatPropertyData", "IntPropertyData", "DoublePropertyData"):
        return str(v)
    if t in ("StructPropertyData",) and isinstance(v, list) and depth < 5:
        inner = ", ".join("%s=%s" % (q.get("Name"), short(q, depth + 1)) for q in v if q.get("Name"))
        return "{" + inner + "}"
    if t == "LinearColorPropertyData" and isinstance(v, dict):
        f = lambda x: float(str(x).replace("+", "")) if x not in (None, "") else 0.0
        return "rgba(%.2f,%.2f,%.2f,%.2f)" % (f(v.get("R")), f(v.get("G")), f(v.get("B")), f(v.get("A")))
    if t in ("Vector2DPropertyData", "VectorPropertyData") and isinstance(v, dict):
        return "(%s,%s)" % (v.get("X"), v.get("Y"))
    if isinstance(v, list) and v and isinstance(v[0], dict) and "Value" in v[0] and depth < 5:
        return "[" + ", ".join(short(q, depth + 1) for q in v[:12]) + "]"
    return t


children = {}
slot_of = {}
for i, e in enumerate(exports, 1):
    pr = props(e)
    if "Parent" in pr and "Content" in pr:
        parent, content = pr["Parent"].get("Value"), pr["Content"].get("Value")
        children.setdefault(parent, []).append((content, i))
        slot_of[content] = i
roots = []
for i, e in enumerate(exports, 1):
    c = cls(e) or ""
    if c == "WidgetTree":
        rw = props(e).get("RootWidget")
        if rw:
            roots.append(rw.get("Value"))

SHOW = ("Text", "Font", "ColorAndOpacity", "Brush", "WidgetStyle", "Background", "BrushColor", "Padding",
        "Visibility", "Justification", "ContentColorAndOpacity", "BackgroundColor", "ActiveWidgetIndex",
        "ToolTipText", "RenderOpacity", "MinDesiredWidth", "WidthOverride", "HeightOverride")
want_props = "--props" in sys.argv


def show(i, ind):
    e = exports[i - 1]
    pr = props(e)
    line = "  " * ind + "%s [%s]" % (e["ObjectName"], cls(e))
    if pr.get("Text"):
        line += " text=" + short(pr["Text"])
    print(line)
    if want_props:
        for k in SHOW:
            if k in pr and k != "Text":
                print("  " * ind + "    ." + k + " = " + short(pr[k])[:400])
        si = slot_of.get(i)
        if si:
            sp = props(exports[si - 1])
            for k in ("Padding", "Size", "HorizontalAlignment", "VerticalAlignment", "LayoutData"):
                if k in sp:
                    print("  " * ind + "    slot." + k + " = " + short(sp[k])[:300])
    for content, _ in children.get(i, []):
        show(content, ind + 1)


for r in roots:
    show(r, 0)
