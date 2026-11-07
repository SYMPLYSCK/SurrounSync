"""Low-poly mesh helpers for the armory models (flat shaded, one palette swatch per face): parts are added into a Mesh,
which writes a glTF + .bin and its palette PNG for the UE 5.6 import. Same palette scheme as tools/glider/make_glider.py:
every face's UVs point at the middle of one swatch (sRGB colour; alpha 255 = metal, 0 = not), nearest filter, no mips.
Model units are centimetres in UE's frame (X, Y, Z up); the glTF is written in metres (the import scales by 100)."""
import json
import math
import os
import struct
import zlib

# Finish code in the palette's alpha (import_armory.py's material reads it): MATTE = rough dielectric (roughness 0.82),
# GLOSS = smooth dielectric (0.12, the smoked window), METAL = polished metal (metallic 1, roughness 0.12).
MATTE, GLOSS, METAL = 0.0, 0.5, 1.0


def srgb(h, finish=MATTE):
    c = [int(h[i:i + 2], 16) / 255.0 for i in (1, 3, 5)]
    return [x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4 for x in c] + [finish]


def sub(a, b): return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
def addv(a, b): return [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
def mul(a, k): return [a[0] * k, a[1] * k, a[2] * k]
def dot(a, b): return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
def cross(a, b): return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
def lerp(a, b, t): return [a[i] + (b[i] - a[i]) * t for i in range(3)]


def norm(a):
    n = math.sqrt(dot(a, a)) or 1.0
    return [a[0] / n, a[1] / n, a[2] / n]


CELL = 8   # swatch size in pixels


class Mesh:
    def __init__(self):
        self.tris = []   # (p0, p1, p2, colour, outward hint or None)

    def tri(self, a, b, c, col, hint=None):
        self.tris.append((a, b, c, col, hint))

    def quad(self, a, b, c, d, col, hint=None):
        self.tri(a, b, c, col, hint)
        self.tri(a, c, d, col, hint)

    def box(self, lo, hi, col, faces="xXyYzZ"):
        """An axis-aligned box from corner lo to corner hi; faces picks the sides drawn (x = -X ... Z = +Z)."""
        x0, y0, z0 = lo
        x1, y1, z1 = hi
        c = mul(addv(lo, hi), 0.5)
        sides = {
            "x": ([x0, y0, z0], [x0, y1, z0], [x0, y1, z1], [x0, y0, z1]),
            "X": ([x1, y0, z0], [x1, y1, z0], [x1, y1, z1], [x1, y0, z1]),
            "y": ([x0, y0, z0], [x1, y0, z0], [x1, y0, z1], [x0, y0, z1]),
            "Y": ([x0, y1, z0], [x1, y1, z0], [x1, y1, z1], [x0, y1, z1]),
            "z": ([x0, y0, z0], [x1, y0, z0], [x1, y1, z0], [x0, y1, z0]),
            "Z": ([x0, y0, z1], [x1, y0, z1], [x1, y1, z1], [x0, y1, z1]),
        }
        for f in faces:
            q = sides[f]
            self.quad(*q, col, sub(mul(addv(q[0], q[2]), 0.5), c))

    def cylinder(self, a, b, r, sides, col, caps=(True, True), cap_col=None, phase=0.0):
        """An n-sided prism from a to b of radius r; caps = (start, end) closed; cap_col colours the caps."""
        ax = norm(sub(b, a))
        up = [0, 0, 1] if abs(ax[2]) < 0.9 else [1, 0, 0]
        u = norm(cross(ax, up))
        v = cross(ax, u)
        ring = [addv(mul(u, math.cos(phase + 2 * math.pi * k / sides) * r), mul(v, math.sin(phase + 2 * math.pi * k / sides) * r))
                for k in range(sides)]
        for k in range(sides):
            o0, o1 = ring[k], ring[(k + 1) % sides]
            self.quad(addv(a, o0), addv(a, o1), addv(b, o1), addv(b, o0), col, mul(addv(o0, o1), 0.5))
        for p, s, on in ((a, -1, caps[0]), (b, 1, caps[1])):
            if on:
                for k in range(sides):
                    self.tri(p, addv(p, ring[k]), addv(p, ring[(k + 1) % sides]), cap_col or col, mul(ax, s))

    def frustum(self, a, b, ra, rb, sides, col, phase=0.0):
        """An open n-sided cone section from a (radius ra) to b (radius rb): bevels and stepped rims."""
        ax = norm(sub(b, a))
        up = [0, 0, 1] if abs(ax[2]) < 0.9 else [1, 0, 0]
        u = norm(cross(ax, up))
        v = cross(ax, u)
        ring = [addv(mul(u, math.cos(phase + 2 * math.pi * k / sides)), mul(v, math.sin(phase + 2 * math.pi * k / sides)))
                for k in range(sides)]
        for k in range(sides):
            o0, o1 = ring[k], ring[(k + 1) % sides]
            mid = mul(addv(o0, o1), 0.5)
            hint = addv(mid, mul(ax, (ra - rb) / max(1e-6, math.sqrt(dot(sub(b, a), sub(b, a))))))
            self.quad(addv(a, mul(o0, ra)), addv(a, mul(o1, ra)), addv(b, mul(o1, rb)), addv(b, mul(o0, rb)), col, hint)

    def annulus(self, centre, normal, r0, r1, sides, col, phase=0.0):
        """A flat ring between radii r0 < r1 facing along normal (bezels)."""
        ax = norm(normal)
        up = [0, 0, 1] if abs(ax[2]) < 0.9 else [1, 0, 0]
        u = norm(cross(ax, up))
        v = cross(ax, u)
        d = [addv(mul(u, math.cos(phase + 2 * math.pi * k / sides)), mul(v, math.sin(phase + 2 * math.pi * k / sides))) for k in range(sides)]
        for k in range(sides):
            o0, o1 = d[k], d[(k + 1) % sides]
            self.quad(addv(centre, mul(o0, r0)), addv(centre, mul(o1, r0)), addv(centre, mul(o1, r1)), addv(centre, mul(o0, r1)), col, ax)

    def disc(self, centre, normal, r, sides, col, phase=0.0):
        """A flat n-gon facing along normal."""
        ax = norm(normal)
        up = [0, 0, 1] if abs(ax[2]) < 0.9 else [1, 0, 0]
        u = norm(cross(ax, up))
        v = cross(ax, u)
        pts = [addv(centre, addv(mul(u, math.cos(phase + 2 * math.pi * k / sides) * r), mul(v, math.sin(phase + 2 * math.pi * k / sides) * r)))
               for k in range(sides)]
        for k in range(sides):
            self.tri(centre, pts[k], pts[(k + 1) % sides], col, ax)

    # --- output -----------------------------------------------------------------------------------------------------
    def swatches(self):
        out = []
        for t in self.tris:
            key = tuple(round(x, 5) for x in t[3])
            if key not in out:
                out.append(key)
        return out

    def bounds(self):
        pts = [p for t in self.tris for p in t[:3]]
        return [min(p[i] for p in pts) for i in range(3)], [max(p[i] for p in pts) for i in range(3)]

    def write(self, out_dir, name):
        """out_dir/<name>.gltf + .bin + Palette.png. glTF is +Y up in metres; UE's Interchange takes glTF x, z, y as
        UE X, Y, Z (tools/glider, measured), so a UE point (x, y, z) cm is written as (x, z, y) / 100."""
        sw = self.swatches()
        pos, nrm, uv = [], [], []
        for a, b, c, colour, hint in self.tris:
            k = sw.index(tuple(round(x, 5) for x in colour))
            st = [(k + 0.5) / len(sw), 0.5]
            A, B, C = ([p[0] / 100, p[2] / 100, p[1] / 100] for p in (a, b, c))
            n = norm(cross(sub(B, A), sub(C, A)))
            if hint is not None and dot(n, [hint[0], hint[2], hint[1]]) < 0:
                B, C = C, B
                n = mul(n, -1)
            for p in (A, B, C):
                pos.append(p); nrm.append(n); uv.append(st)
        os.makedirs(out_dir, exist_ok=True)
        write_png(os.path.join(out_dir, "Palette.png"), sw)
        n = len(pos)
        blob = b"".join(struct.pack("<3f", *p) for p in pos)
        blob += b"".join(struct.pack("<3f", *p) for p in nrm)
        blob += b"".join(struct.pack("<2f", *p) for p in uv)
        blob += b"".join(struct.pack("<I", i) for i in range(n))
        lo = [min(p[i] for p in pos) for i in range(3)]
        hi = [max(p[i] for p in pos) for i in range(3)]
        with open(os.path.join(out_dir, name + ".bin"), "wb") as f:
            f.write(blob)
        g = {
            "asset": {"version": "2.0", "generator": "SurrounSync tools/armory"},
            "scene": 0, "scenes": [{"nodes": [0]}],
            "nodes": [{"name": name, "mesh": 0}],
            "meshes": [{"name": name, "primitives": [{"attributes": {"POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2}, "indices": 3, "material": 0}]}],
            "materials": [{"name": "M_" + name, "pbrMetallicRoughness": {"baseColorFactor": [1, 1, 1, 1], "metallicFactor": 0, "roughnessFactor": 0.8}}],
            "buffers": [{"uri": name + ".bin", "byteLength": len(blob)}],
            "bufferViews": [
                {"buffer": 0, "byteOffset": 0, "byteLength": n * 12, "target": 34962},
                {"buffer": 0, "byteOffset": n * 12, "byteLength": n * 12, "target": 34962},
                {"buffer": 0, "byteOffset": n * 24, "byteLength": n * 8, "target": 34962},
                {"buffer": 0, "byteOffset": n * 32, "byteLength": n * 4, "target": 34963},
            ],
            "accessors": [
                {"bufferView": 0, "componentType": 5126, "count": n, "type": "VEC3", "min": lo, "max": hi},
                {"bufferView": 1, "componentType": 5126, "count": n, "type": "VEC3"},
                {"bufferView": 2, "componentType": 5126, "count": n, "type": "VEC2"},
                {"bufferView": 3, "componentType": 5125, "count": n, "type": "SCALAR"},
            ],
        }
        with open(os.path.join(out_dir, name + ".gltf"), "w") as f:
            json.dump(g, f, indent=1)
        blo, bhi = self.bounds()
        print(f"{name}.gltf: {n // 3} triangles, {len(sw)} colours, X {blo[0]:.1f}..{bhi[0]:.1f}  "
              f"Y {blo[1]:.1f}..{bhi[1]:.1f}  Z {blo[2]:.1f}..{bhi[2]:.1f} cm")

    def preview(self, path, views, lim):
        """Shaded orthographic renders (UE frame) to judge the look before it goes into the game."""
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        from mpl_toolkits.mplot3d.art3d import Poly3DCollection
        light = norm([0.35, 0.55, 0.75])
        fig = plt.figure(figsize=(14, 10), facecolor="#8FA3B5")
        for k, (el, az, title) in enumerate(views):
            ax = fig.add_subplot(2, 2, k + 1, projection="3d", facecolor="#8FA3B5")
            faces, colours = [], []
            for a, b, c, col, hint in self.tris:
                n = norm(cross(sub(b, a), sub(c, a)))
                if hint is not None and dot(n, hint) < 0:
                    n = mul(n, -1)
                d = abs(dot(n, light))
                base = [x ** (1 / 2.2) for x in col[:3]]
                spec = (0.55 * d ** 10 if col[3] > 0.75 else 0.3 * d ** 30 if col[3] > 0.25 else 0.0)
                # UE is left-handed: Y is drawn mirrored so the render reads as the game shows it
                faces.append([[p[0], -p[1], p[2]] for p in (a, b, c)])
                colours.append([min(1, x * (0.35 + 0.65 * d) + spec) for x in base])
            ax.add_collection3d(Poly3DCollection(faces, facecolors=colours, edgecolors="none"))
            ax.set_xlim(-lim, lim); ax.set_ylim(-lim, lim); ax.set_zlim(-lim, lim)
            ax.set_box_aspect((1, 1, 1))
            ax.set_proj_type("ortho")
            ax.view_init(elev=el, azim=az)
            ax.set_axis_off()
            ax.set_title(title)
        plt.tight_layout()
        fig.savefig(path, dpi=110)
        print("preview:", path)


def write_png(path, swatches):
    w, h = CELL * len(swatches), CELL
    raw = b""
    for _ in range(h):
        row = b"\x00"
        for s in swatches:
            px = bytes([round((1.055 * min(1.0, x) ** (1 / 2.4) - 0.055) * 255) if x > 0.0031308 else round(max(0.0, x) * 12.92 * 255)
                        for x in s[:3]])   # linear -> sRGB
            row += (px + bytes([round(max(0.0, min(1.0, s[3])) * 255)])) * CELL   # finish code (FINISH below)
        raw += row

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))
