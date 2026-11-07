"""The facets of the Colonel's Revenge diamond finish (user 2026-11-03: "make it look like the bo2 diamond camo"):
out/DiamondFacets.png, a tiling sheet of hard-edged crystal shards for M_ColonelsDiamond (import_armory.py).
Every shard is one flat colour: RGB its tilt (a unit vector, 0.5 + 0.5 * n), A its id (1..255 / 255). No gradients and
no filtering, so a shard stays one mirror facet in the game (import_armory's palette_texture: nearest, no mips).
Seeded: the same file every build."""
import os
import random

import numpy as np
from PIL import Image, ImageDraw

SIZE = 1024
CELLS = 13        # shards across the sheet, before the splits
JITTER = 0.34     # how far a corner wanders, in cells
SPLIT = 0.55      # chance a shard splits in two, each level: big shards among small ones
LEVELS = 2
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out", "DiamondFacets.png")


def corners(rng):
    """A jittered grid that wraps: the corner past the edge is the first corner again, one sheet over."""
    jit = {}
    for x in range(CELLS):
        for y in range(CELLS):
            jit[x, y] = (rng.uniform(-JITTER, JITTER), rng.uniform(-JITTER, JITTER))

    def at(x, y):
        dx, dy = jit[x % CELLS, y % CELLS]
        return (x + dx) * SIZE / CELLS, (y + dy) * SIZE / CELLS
    return at


def split(tri, level, rng, out):
    """Long side cut near its middle: slivers and wedges, the way a cut stone looks, not a regular mesh."""
    if level >= LEVELS or rng.random() > SPLIT:
        out.append(tri)
        return
    sides = [(0, 1, 2), (1, 2, 0), (2, 0, 1)]
    i, j, k = max(sides, key=lambda s: (tri[s[0]][0] - tri[s[1]][0]) ** 2 + (tri[s[0]][1] - tri[s[1]][1]) ** 2)
    t = rng.uniform(0.35, 0.65)
    m = (tri[i][0] + (tri[j][0] - tri[i][0]) * t, tri[i][1] + (tri[j][1] - tri[i][1]) * t)
    split((tri[i], m, tri[k]), level + 1, rng, out)
    split((m, tri[j], tri[k]), level + 1, rng, out)


def shards(rng):
    at = corners(rng)
    out = []
    for x in range(CELLS):
        for y in range(CELLS):
            a, b, c, d = at(x, y), at(x + 1, y), at(x + 1, y + 1), at(x, y + 1)
            pair = ((a, b, c), (a, c, d)) if rng.random() < 0.5 else ((a, b, d), (b, c, d))
            for tri in pair:
                split(tri, 0, rng, out)
    return out


def tilt(rng):
    """A unit vector, evenly over the sphere: the material adds it to the surface normal."""
    while True:
        v = np.array([rng.gauss(0, 1), rng.gauss(0, 1), rng.gauss(0, 1)])
        n = np.linalg.norm(v)
        if n > 1e-3:
            return v / n


def build():
    rng = random.Random(20261103)
    tris = shards(rng)
    if len(tris) >= 2 ** 24:
        raise RuntimeError("too many shards")
    # shard index + 1 per texel (0 = not drawn yet); drawn nine times over so the shards past the edge wrap
    ids = Image.new("I", (SIZE, SIZE), 0)
    draw = ImageDraw.Draw(ids)
    for i, tri in enumerate(tris):
        for ox in (-SIZE, 0, SIZE):
            for oy in (-SIZE, 0, SIZE):
                draw.polygon([(p[0] + ox, p[1] + oy) for p in tri], fill=i + 1)
    index = np.asarray(ids, dtype=np.int64).copy()
    # rounding leaves hairline cracks between shards: a crack texel joins the shard beside it, so the edge stays hard
    for _ in range(8):
        bare = index == 0
        if not bare.any():
            break
        for axis, step in ((0, 1), (0, -1), (1, 1), (1, -1)):
            index = np.where(index == 0, np.roll(index, step, axis=axis), index)
    if (index == 0).any():
        raise RuntimeError("the shards left %d texels bare" % int((index == 0).sum()))
    table = np.zeros((len(tris) + 1, 4), dtype=np.uint8)
    for i in range(len(tris)):
        n = tilt(rng)
        table[i + 1, :3] = np.clip(np.round((n * 0.5 + 0.5) * 255), 0, 255)
        table[i + 1, 3] = rng.randint(1, 255)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    Image.fromarray(table[index], "RGBA").save(OUT)
    print("DiamondFacets.png: %d shards, %d x %d" % (len(tris), SIZE, SIZE))


if __name__ == "__main__":
    build()
