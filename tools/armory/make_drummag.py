"""The Colonel's Revenge Double Drum Magazine (user 2026-11-02: "a brand new Drum mag double drum mag", "matte black
with gold trim"; the trim went platinum with the gun's diamond finish 2026-11-03): a twin-drum (C-Mag style) 200-round
5.56 magazine. Two drums side by side, axes along the gun, joined under a feed tower that goes into the mag well; matte
black polymer, polished platinum rims, bezels, pinstripes and winding keys, smoked front windows showing the rounds, a
brass round on the feed lips and "200" in platinum on the tower.

Frame and size follow the game's own drum mesh (Weapon_ColsRevenge_att_drummag, measured in the kit 2026-11-02:
bounds centred on the origin, extent 8.64 x 7.21 x 12.66 cm, X across the gun, Y along it, Z up), so the model sits on
the same CRDrumMag socket: tower top at Z +12.6 like the game's drum, each drum about 12 cm across.

python make_drummag.py [--preview]  ->  out/DoubleDrum.gltf + .bin + Palette.png (+ out/preview.png)"""
import math
import os
import sys

from lowpoly import GLOSS, METAL, Mesh, srgb, write_png

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")

BLACK = srgb("#121214")           # matte black polymer
BLACK_RIB = srgb("#1B1B1E")       # grip ribs, a shade lighter so the ridges read
TRIM = [0.82, 0.86, 0.92, METAL]  # polished icy platinum (linear), to sit with the gun's diamond finish
TRIM_DEEP = srgb("#8E97A6", METAL)  # recessed platinum (primers, key flats), so the trim has depth
SMOKE = srgb("#24242C", GLOSS)    # smoked window
BRASS = srgb("#C9A24A", METAL)    # cartridge brass
COPPER = srgb("#B5653A", METAL)   # bullet tip

SIDES = 28            # drum smoothness (flat shaded: 28 facets read as round at arm's length)
DR = 6.0              # drum radius
DX, DZ = 7.0, -5.0    # drum centres: X = +-DX, Z = DZ
DY = 5.6              # drums run Y -DY .. +DY
BEVEL = 0.6           # end bevel depth along Y
DRUM_SCALE = 0.75     # the drums and bridge are drawn at this size (build)
TB = 1.6              # Z of the tower's foot (top of the bridge), the point the drums scale about
TX, TY = 1.9, 3.6     # feed tower half width (across the gun) and half length (along it)
LIP = 10.2            # Z of the feed lips' top (the game's own mag reaches +10.16)


def drum(m, sx):
    cx = sx * DX
    def at(y):   # a point on this drum's axis
        return [cx, y, DZ]
    # shell: straight middle, bevelled ends
    m.cylinder(at(-DY + BEVEL), at(DY - BEVEL), DR, SIDES, BLACK, caps=(False, False))
    m.frustum(at(DY - BEVEL), at(DY), DR, DR - 0.55, SIDES, BLACK)
    m.frustum(at(-DY + BEVEL), at(-DY), DR, DR - 0.55, SIDES, BLACK)
    # platinum rims at both shoulders and a fine platinum pinstripe round the middle
    for y0, y1 in ((DY - BEVEL - 0.55, DY - BEVEL), (-DY + BEVEL, -DY + BEVEL + 0.55)):
        m.cylinder(at(y0), at(y1), DR + 0.12, SIDES, TRIM, caps=(False, False))
        m.annulus(at(y1 if y1 > 0 else y0), [0, 1 if y1 > 0 else -1, 0], DR, DR + 0.12, SIDES, TRIM)
        m.annulus(at(y0 if y1 > 0 else y1), [0, -1 if y1 > 0 else 1, 0], DR, DR + 0.12, SIDES, TRIM)
    m.cylinder(at(-0.12), at(0.12), DR + 0.06, SIDES, TRIM, caps=(False, False))
    # raised grip ribs either side of the pinstripe
    for y in (-3.2, -2.2, 1.6, 2.6):
        m.cylinder(at(y), at(y + 0.45), DR + 0.1, SIDES, BLACK_RIB, caps=(False, False))   # (1 mm steps: no end faces)

    face = DR - 0.55
    # front: black face, platinum bezel, smoked window, the rounds spiralling inside, a platinum hub
    m.disc(at(DY), [0, 1, 0], face, SIDES, BLACK)
    m.annulus(at(DY + 0.08), [0, 1, 0], 4.25, 4.95, SIDES, TRIM)
    m.cylinder(at(DY), at(DY + 0.08), 4.95, SIDES, TRIM, caps=(False, False))
    m.disc(at(DY + 0.04), [0, 1, 0], 4.25, SIDES, SMOKE)
    for ring, n, r in ((3.25, 11, 0.5), (2.05, 7, 0.46)):
        for k in range(n):
            a = 2 * math.pi * k / n + ring
            p = [cx + math.cos(a) * ring, DY + 0.06, DZ + math.sin(a) * ring]
            m.disc(p, [0, 1, 0], r, 10, BRASS)
            m.disc([p[0], DY + 0.07, p[2]], [0, 1, 0], r * 0.38, 8, TRIM_DEEP)
    m.cylinder(at(DY), at(DY + 0.35), 0.95, 16, TRIM, caps=(False, True))
    # rear: black face, platinum bezel, the winding key (platinum boss, black T bar with platinum end caps)
    m.disc(at(-DY), [0, -1, 0], face, SIDES, BLACK)
    m.annulus(at(-DY - 0.08), [0, -1, 0], 4.25, 4.95, SIDES, TRIM)
    m.cylinder(at(-DY), at(-DY - 0.08), 4.95, SIDES, TRIM, caps=(False, False))
    m.cylinder(at(-DY), at(-DY - 0.7), 1.7, 20, TRIM, caps=(False, True), cap_col=TRIM_DEEP)
    m.box([cx - 2.6, -DY - 1.45, DZ - 0.42], [cx + 2.6, -DY - 0.7, DZ + 0.42], BLACK)
    for x0, x1 in ((cx - 2.95, cx - 2.6), (cx + 2.6, cx + 2.95)):   # platinum end caps on the T bar
        m.box([x0, -DY - 1.5, DZ - 0.5], [x1, -DY - 0.65, DZ + 0.5], TRIM)


def digit(m, glyph, y0, z0, sx):
    """A seven-segment digit in platinum on the tower side at X = sx * TX: y0 = the digit's left edge as seen from that
    side (UE is left-handed: from +X the reader's right is -Y), z0 its bottom; 0.8 wide, 1.4 tall, 0.22 strokes."""
    w, h, t = 0.8, 1.4, 0.22
    d = -sx                    # reading direction along Y
    x0, x1 = sx * TX, sx * (TX + 0.08)
    seg = {
        "a": (0, w, h - t, h), "d": (0, w, 0, t), "g": (0, w, h / 2 - t / 2, h / 2 + t / 2),
        "f": (0, t, h / 2, h), "b": (w - t, w, h / 2, h), "e": (0, t, 0, h / 2), "c": (w - t, w, 0, h / 2),
    }
    for s in {"2": "abged", "0": "abcdef"}[glyph]:
        u0, u1, v0, v1 = seg[s]
        ya, yb = sorted((y0 + d * u0, y0 + d * u1))
        m.box([min(x0, x1), ya, z0 + v0], [max(x0, x1), yb, z0 + v1], TRIM, faces="xX" + "yYzZ")


def build():
    m = Mesh()
    # the drums and the bridge are modelled at the first size and drawn at DRUM_SCALE about the tower's foot (user
    # 2026-11-02: "the drum is a bit too big"): 75% makes the pair 19.5 cm across, near the game's single drum (17.3)
    low = Mesh()
    for sx in (-1, 1):
        drum(low, sx)
    # bridge between the drums (the drums overlap it, so only its front, back, top and bottom show)
    low.box([-3.0, -5.0, -10.2], [3.0, 5.0, TB], BLACK)
    low.box([-3.25, -4.7, -10.65], [3.25, 4.7, -10.2], TRIM)              # platinum base plate
    low.box([-0.9, 4.95, -9.6], [0.9, 5.08, -1.4], TRIM, faces="Y")       # platinum spine, front and back
    low.box([-0.9, -5.08, -9.6], [0.9, -4.95, -1.4], TRIM, faces="y")
    low.box([-0.55, 5.08, -9.0], [0.55, 5.14, -2.0], BLACK, faces="Y")    # black inlay in the spine
    low.box([-0.55, -5.14, -9.0], [0.55, -5.08, -2.0], BLACK, faces="y")
    def s(p):
        return [p[0] * DRUM_SCALE, p[1] * DRUM_SCALE, TB + (p[2] - TB) * DRUM_SCALE]
    m.tris += [(s(a), s(b), s(c), col, hint) for a, b, c, col, hint in low.tris]
    # feed tower: the part that goes up into the gun's mag well, slimmer than the well so it sits inside it (user
    # 2026-11-02: "the mag is larger than the gun's mag hole"); the game's own mag is 4.9 x 10.3 cm at its widest
    # (curved body) and reaches Z +10.16, so the tower is 3.8 x 7.2 and its lips stop at Z +10.2
    m.box([-TX, -TY, TB], [TX, TY, LIP - 1.0], BLACK)
    m.box([-TX - 0.12, -TY - 0.12, TB], [TX + 0.12, TY + 0.12, TB + 0.55], TRIM)          # platinum collar at the drums
    m.box([-TX - 0.06, -TY - 0.06, 5.6], [TX + 0.06, TY + 0.06, 5.8], TRIM, faces="xXyY")  # platinum pinstripe
    # feed lips and the top round showing in them
    m.box([-TX + 0.3, -TY + 0.6, LIP - 1.0], [-0.9, TY - 0.6, LIP], BLACK)
    m.box([0.9, -TY + 0.6, LIP - 1.0], [TX - 0.3, TY - 0.6, LIP], BLACK)
    m.box([-0.9, -TY + 0.6, LIP - 1.0], [0.9, TY - 0.6, LIP - 0.7], BLACK, faces="Z")  # follower
    m.cylinder([0, -TY + 0.9, LIP - 0.45], [0, 1.4, LIP - 0.45], 0.42, 12, BRASS)
    m.frustum([0, 1.4, LIP - 0.45], [0, 2.6, LIP - 0.45], 0.42, 0.1, 12, COPPER)
    # "200" in platinum on both tower sides, between the collar and the pinstripe
    for sx in (-1, 1):
        for k, g in enumerate("200"):
            digit(m, g, (1.5 - 1.05 * k) if sx > 0 else (-1.5 + 1.05 * k), 3.0, sx)
    return m


if __name__ == "__main__":
    mesh = build()
    mesh.write(OUT, "DoubleDrum")
    write_png(os.path.join(OUT, "White.png"), [(1.0, 1.0, 1.0, 0.0)])   # M_ColonelsDiamond's stand-in Detail texture
    if "--preview" in sys.argv:
        mesh.preview(os.path.join(OUT, "preview.png"), [
            (15, -60, "front quarter (muzzle side)"), (15, 120, "rear quarter (winding keys)"),
            (0, 0, "side (\"200\")"), (90, -90, "top (feed lips)")], 10)
