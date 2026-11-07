"""Builds the hang glider model (low poly, flat shaded) as out/Glider.gltf + .bin and its colour palette out/Palette.png.
No Blender needed: every part is made here from a few measured points. Run: python tools/glider/make_glider.py [--preview]
Model frame while building: X forward, Y right, Z up, metres; origin = the middle of the base bar (the pilot's hands).
Colours: every face's UVs point at the middle of one swatch of Palette.png (sRGB colour; alpha 255 = metal, 0 = cloth or
tape), the usual low-poly palette texture. Vertex colours were tried first: in game the faces came out black (kit
2026-11-02; the engine's default material on the same mesh lit fine), so the colour no longer depends on them."""
import json
import math
import os
import struct
import sys
import zlib

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")


def srgb(h, a=0.0):
    c = [int(h[i:i + 2], 16) / 255.0 for i in (1, 3, 5)]
    lin = [x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4 for x in c]
    return lin + [a]


def shade(c, k):
    return [c[0] * k, c[1] * k, c[2] * k, c[3]]


RED, ORANGE, CREAM, TEAL = srgb("#B8332B"), srgb("#E0672A"), srgb("#EDE3C8"), srgb("#1F7A80")
CHARCOAL, ALU, STEEL, GRIP, FITTING = srgb("#2B2F36"), srgb("#B4B8BE", 1), srgb("#6E7378", 1), srgb("#141414"), srgb("#3A3D42", 1)
PANELS = [RED, ORANGE, CREAM, TEAL, CREAM, ORANGE, RED]   # root to tip, one per batten bay

tris = []   # (p0, p1, p2, colour, outward hint or None)


def add(a, b, c, col, hint=None):
    tris.append((a, b, c, col, hint))


def quad(a, b, c, d, col, hint=None):
    add(a, b, c, col, hint)
    add(a, c, d, col, hint)


def sub(a, b): return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
def addv(a, b): return [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
def mul(a, k): return [a[0] * k, a[1] * k, a[2] * k]
def dot(a, b): return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
def cross(a, b): return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
def lerp(a, b, t): return [a[i] + (b[i] - a[i]) * t for i in range(3)]


def norm(a):
    n = math.sqrt(dot(a, a)) or 1.0
    return [a[0] / n, a[1] / n, a[2] / n]


def tube(a, b, r, sides, col, caps=True, segments=None):
    """A straight n-sided tube from a to b; segments = [(t0, t1, colour)] colours parts of it (grip tape)."""
    ax = norm(sub(b, a))
    up = [0, 0, 1] if abs(ax[2]) < 0.9 else [1, 0, 0]
    u = norm(cross(ax, up))
    v = cross(ax, u)
    ring = [addv(mul(u, math.cos(2 * math.pi * k / sides) * r), mul(v, math.sin(2 * math.pi * k / sides) * r)) for k in range(sides)]
    parts = segments or [(0.0, 1.0, col)]
    for t0, t1, c in parts:
        p0, p1 = lerp(a, b, t0), lerp(a, b, t1)
        for k in range(sides):
            o0, o1 = ring[k], ring[(k + 1) % sides]
            mid = mul(addv(o0, o1), 0.5)
            quad(addv(p0, o0), addv(p0, o1), addv(p1, o1), addv(p1, o0), c, mid)
    if caps:
        for p, s in ((a, -1), (b, 1)):
            for k in range(sides):
                add(p, addv(p, ring[k]), addv(p, ring[(k + 1) % sides]), parts[0 if s < 0 else -1][2], mul(ax, s))


def knuckle(p, r, col):
    """A small octahedron: the bolted fittings at the frame's corners."""
    d = [[r, 0, 0], [-r, 0, 0], [0, r, 0], [0, -r, 0], [0, 0, r], [0, 0, -r]]
    for x in (0, 1):
        for y in (2, 3):
            for z in (4, 5):
                a, b, c = addv(p, d[x]), addv(p, d[y]), addv(p, d[z])
                add(a, b, c, col, addv(addv(d[x], d[y]), d[z]))


# --- the sail -----------------------------------------------------------------------------------------------------
NOSE = [1.45, 0.0, 1.70]
TAIL = [-1.15, 0.0, 1.62]
TIP = [-0.85, 2.75, 1.86]
STATIONS = len(PANELS)
ROWS = [0.0, 0.11, 0.45, 0.78, 1.0]   # chord fractions: leading-edge band, two body rows, trailing band
BILLOW, THICK = 0.15, 0.025


def sail_point(s, c, side):
    le = lerp(NOSE, [TIP[0], TIP[1] * side, TIP[2]], s)
    te = lerp(TAIL, [TIP[0], TIP[1] * side, TIP[2]], s)
    p = lerp(le, te, c)
    taper = 1.0 - s ** 1.6
    p[2] += BILLOW * math.sin(math.pi * c) * taper + 0.07 * c * s   # cloth billows up; the tips are twisted (washout)
    return p


def scallop(s0, s1, side):
    """Trailing edge between two battens: the cloth pulls forward in a curve."""
    m = sail_point((s0 + s1) / 2, 1.0, side)
    pull = 0.12 * (1.0 - 0.5 * (s0 + s1) / 2)
    return addv(m, [pull, 0, 0.01])


for side in (1, -1):
    for i in range(STATIONS):
        s0, s1 = i / STATIONS, (i + 1) / STATIONS
        col = PANELS[i]
        for layer, dz, k, hint in (("top", 0.0, 1.0, [0, 0, 1]), ("bottom", -THICK, 0.62, [0, 0, -1])):
            def P(s, c):
                p = sail_point(s, c, side)
                return [p[0], p[1], p[2] + dz]
            for r in range(len(ROWS) - 1):
                c0, c1 = ROWS[r], ROWS[r + 1]
                band = CHARCOAL if r == 0 else (shade(col, 0.86) if r == len(ROWS) - 2 else col)
                band = shade(band, k)
                if r < len(ROWS) - 2:
                    quad(P(s0, c0), P(s1, c0), P(s1, c1), P(s0, c1), band, hint)
                else:   # last row ends in the scalloped trailing edge
                    m = scallop(s0, s1, side)
                    m = [m[0], m[1], m[2] + dz]
                    add(P(s0, c0), P(s1, c0), m, band, hint)
                    add(P(s0, c0), m, P(s0, c1), band, hint)
                    add(P(s1, c0), P(s1, c1), m, band, hint)
        # the cloth's edge along the scallops (top to bottom)
        m = scallop(s0, s1, side)
        for a, b in ((sail_point(s0, 1.0, side), m), (m, sail_point(s1, 1.0, side))):
            out = [-1, 0, 0]
            quad(a, b, [b[0], b[1], b[2] - THICK], [a[0], a[1], a[2] - THICK], shade(col, 0.5), out)
        # battens: thin raised ribs on top along each station
        if i > 0:
            a, b = sail_point(s0, ROWS[1], side), sail_point(s0, 0.97, side)
            for t in range(4):
                p0, p1 = lerp(a, b, t / 4), lerp(a, b, (t + 1) / 4)
                h0, h1 = sail_point(s0, ROWS[1] + (0.97 - ROWS[1]) * t / 4, side), sail_point(s0, ROWS[1] + (0.97 - ROWS[1]) * (t + 1) / 4, side)
                w = [0, 0.012 * side, 0]
                quad(addv(h0, [0, 0, 0.008]), addv(h1, [0, 0, 0.008]), addv(addv(h1, w), [0, 0, 0.008]), addv(addv(h0, w), [0, 0, 0.008]),
                     srgb("#F4F1EA"), [0, 0, 1])

# --- frame --------------------------------------------------------------------------------------------------------
LE_DROP = [0, 0, -0.025]
for side in (1, -1):
    tip = [TIP[0], TIP[1] * side, TIP[2]]
    tube(addv(NOSE, LE_DROP), addv(tip, LE_DROP), 0.045, 8, CHARCOAL)                       # leading-edge sleeve
    tube(addv(tip, LE_DROP), addv(addv(tip, [-0.10, 0.06 * side, 0.0]), LE_DROP), 0.03, 6, ALU)  # tube end past the cloth

keel_z = -0.06
tube(addv(NOSE, [0.05, 0, keel_z]), addv(TAIL, [-0.12, 0, keel_z]), 0.028, 6, ALU)                 # keel
cb = [sail_point(0.42, 0.0, s) for s in (1, -1)]
tube(addv(cb[0], [0, 0, -0.07]), addv(cb[1], [0, 0, -0.07]), 0.024, 6, ALU)                        # crossbar
APEX = [0.25, 0.0, 1.57]
KING = [0.18, 0.0, 2.25]
tube(addv(APEX, [0, 0, 0.05]), KING, 0.022, 6, ALU)                                               # kingpost
BASE = [[0.55, 0.72, 0.0], [0.55, -0.72, 0.0]]
for b in BASE:
    tube(APEX, b, 0.026, 6, ALU)                                                                   # A-frame downtubes
    knuckle(b, 0.05, FITTING)
knuckle(APEX, 0.06, FITTING)
knuckle(KING, 0.035, FITTING)
tube(BASE[1], BASE[0], 0.026, 8, ALU, segments=[(0.0, 0.19, ALU), (0.19, 0.40, GRIP), (0.40, 0.60, ALU),
                                                (0.60, 0.81, GRIP), (0.81, 1.0, ALU)])            # base bar, grip tape
# hang strap and its carabiner (where a harness would clip in)
tube([0.20, 0.0, 1.55], [0.20, 0.0, 1.08], 0.018, 4, RED)
knuckle([0.20, 0.0, 1.05], 0.035, FITTING)

# rigging wires: base bar corners and kingpost top to nose, tips and tail
wire_ends = [NOSE, TAIL, [TIP[0], TIP[1], TIP[2]], [TIP[0], -TIP[1], TIP[2]]]
for b, side in ((BASE[0], 1), (BASE[1], -1)):
    for e in (NOSE, TAIL, [TIP[0], TIP[1] * side, TIP[2]]):
        tube(b, addv(e, [0, 0, -0.06]), 0.006, 4, STEEL, caps=False)
for e in wire_ends:
    tube(KING, addv(e, [0, 0, 0.0]), 0.005, 4, STEEL, caps=False)

# nose cap
tube(addv(NOSE, [0.0, 0, -0.025]), addv(NOSE, [0.12, 0, -0.03]), 0.05, 8, CHARCOAL)


# --- write glTF -----------------------------------------------------------------------------------------------------
def to_gltf(p):
    # glTF is +Y up, metres; UE's Interchange takes glTF x, z, y as UE X, Y, Z (measured: bounds of the first import).
    # So forward goes in x and the side in z, and the mesh comes out nose along UE +X.
    return [p[0], p[2], p[1]]


CELL = 8   # swatch size in pixels (no mips, nearest filter: a face samples only its own swatch)


def palette():
    swatches = []
    for t in tris:
        key = tuple(round(x, 5) for x in t[3])
        if key not in swatches:
            swatches.append(key)
    return swatches


def write_png(path, swatches):
    w, h = CELL * len(swatches), CELL
    raw = b""
    for _ in range(h):
        row = b"\x00"
        for s in swatches:
            px = bytes([round((1.055 * min(1.0, x) ** (1 / 2.4) - 0.055) * 255) if x > 0.0031308 else round(max(0.0, x) * 12.92 * 255)
                        for x in s[:3]])   # linear -> sRGB
            row += (px + bytes([255 if s[3] > 0.5 else 0])) * CELL
        raw += row

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def build():
    pos, nrm, col, uv = [], [], [], []
    swatches = palette()
    for a, b, c, colour, hint in tris:
        k = swatches.index(tuple(round(x, 5) for x in colour))
        st = [(k + 0.5) / len(swatches), 0.5]
        A, B, C = to_gltf(a), to_gltf(b), to_gltf(c)
        n = norm(cross(sub(B, A), sub(C, A)))
        if hint is not None:
            if dot(n, to_gltf(hint)) < 0:
                B, C = C, B
                n = mul(n, -1)
        for p in (A, B, C):
            pos.append(p); nrm.append(n); col.append(colour); uv.append(st)
    return pos, nrm, col, uv, swatches


def write():
    pos, nrm, col, uv, swatches = build()
    os.makedirs(OUT, exist_ok=True)
    write_png(os.path.join(OUT, "Palette.png"), swatches)
    n = len(pos)
    blob = b"".join(struct.pack("<3f", *p) for p in pos)
    blob += b"".join(struct.pack("<3f", *p) for p in nrm)
    blob += b"".join(struct.pack("<2f", *p) for p in uv)
    blob += b"".join(struct.pack("<I", i) for i in range(n))
    lo = [min(p[i] for p in pos) for i in range(3)]
    hi = [max(p[i] for p in pos) for i in range(3)]
    with open(os.path.join(OUT, "Glider.bin"), "wb") as f:
        f.write(blob)
    off_n, off_c, off_i = n * 12, n * 24, n * 32
    g = {
        "asset": {"version": "2.0", "generator": "SurrounSync make_glider.py"},
        "scene": 0, "scenes": [{"nodes": [0]}],
        "nodes": [{"name": "Glider", "mesh": 0}],
        "meshes": [{"name": "Glider", "primitives": [{"attributes": {"POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2}, "indices": 3, "material": 0}]}],
        "materials": [{"name": "M_Glider", "pbrMetallicRoughness": {"baseColorFactor": [1, 1, 1, 1], "metallicFactor": 0, "roughnessFactor": 0.8}}],
        "buffers": [{"uri": "Glider.bin", "byteLength": len(blob)}],
        "bufferViews": [
            {"buffer": 0, "byteOffset": 0, "byteLength": n * 12, "target": 34962},
            {"buffer": 0, "byteOffset": off_n, "byteLength": n * 12, "target": 34962},
            {"buffer": 0, "byteOffset": off_c, "byteLength": n * 8, "target": 34962},
            {"buffer": 0, "byteOffset": off_i, "byteLength": n * 4, "target": 34963},
        ],
        "accessors": [
            {"bufferView": 0, "componentType": 5126, "count": n, "type": "VEC3", "min": lo, "max": hi},
            {"bufferView": 1, "componentType": 5126, "count": n, "type": "VEC3"},
            {"bufferView": 2, "componentType": 5126, "count": n, "type": "VEC2"},
            {"bufferView": 3, "componentType": 5125, "count": n, "type": "SCALAR"},
        ],
    }
    with open(os.path.join(OUT, "Glider.gltf"), "w") as f:
        json.dump(g, f, indent=1)
    print("Glider.gltf: %d triangles, %d colours, size %.2f x %.2f x %.2f m (forward x up x side)"
          % (n // 3, len(swatches), hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2]))
    return pos, nrm, col


def preview(pos, nrm, col):
    """Shaded renders from three sides into out/preview.png (to judge the look before it goes into the game)."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from mpl_toolkits.mplot3d.art3d import Poly3DCollection
    light = norm([0.4, 0.8, 0.5])
    views = [(25, 35, "front three-quarter"), (5, 90, "side"), (-30, 150, "from below, behind"), (90, 0, "top")]
    fig = plt.figure(figsize=(16, 12), facecolor="#8FA3B5")
    for k, (el, az, name) in enumerate(views):
        ax = fig.add_subplot(2, 2, k + 1, projection="3d", facecolor="#8FA3B5")
        faces, colours = [], []
        for t in range(0, len(pos), 3):
            # matplotlib: x = forward(gltf x), y = side(gltf z), z = up(gltf y)
            faces.append([[p[0], p[2], p[1]] for p in pos[t:t + 3]])
            n = nrm[t]
            d = max(0.0, dot(n, light))
            c = col[t]
            base = [x ** (1 / 2.2) for x in c[:3]]
            spec = 0.25 * d ** 8 if c[3] > 0.5 else 0.0
            colours.append([min(1, b * (0.38 + 0.62 * d) + spec) for b in base])
        pc = Poly3DCollection(faces, facecolors=colours, edgecolors="none")
        ax.add_collection3d(pc)
        ax.set_xlim(-2.8, 2.8); ax.set_ylim(-2.8, 2.8); ax.set_zlim(-0.6, 2.6)
        ax.set_box_aspect((5.6, 5.6, 3.2))
        ax.set_proj_type("ortho")
        ax.view_init(elev=el, azim=az)
        ax.set_axis_off()
        ax.set_title(name)
    plt.tight_layout()
    fig.savefig(os.path.join(OUT, "preview.png"), dpi=70)
    print("preview:", os.path.join(OUT, "preview.png"))


if __name__ == "__main__":
    p, n, c = write()
    if "--preview" in sys.argv:
        preview(p, n, c)
