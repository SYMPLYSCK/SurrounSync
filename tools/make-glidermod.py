"""SurrounSync's Hang Glider as its own mod: a plain zip plus version-glider.json (user 2026-11-10: "Make sure the
standalone pak has everything needed to be installed as its own mod"). tools/build-release.ps1 runs it on its staged
setup payload, next to tools/make-modzip.py.

    python -I tools/make-glidermod.py <payload dir> <dist dir>
    python -I tools/make-glidermod.py --folder <dir>      only the Lua mod folder, into <dir> (tools/test-sync.py)

The zip mirrors the game's install folder (the one that holds SurrounDead.exe): unzip it there. It holds
- ue4ss/Mods/SurrounSyncGlider: mod/SurrounSyncGlider's main.lua + standalone.lua and SurrounSync's own glider files
  (mirror/glider.lua, glideritem.lua, modrecipe.lua, copied, never a second copy kept in git), with an enabled.txt;
- Content/Paks/LogicMods/SurrounSyncGlider.pak: the model and the Hang Glider item (tools/glider builds it);
- UE4SS and BPModLoaderMod (which loads Paks/LogicMods), as SurrounSync's zip has them: "keep_if_present".
With SurrounSync installed the glider mod stays off by itself (SurrounSync flies the glider, in co-op too).
"""
import hashlib
import json
import os
import re
import shutil
import sys
import time
import zipfile

REPO_SLUG = "SYMPLYSCK/SurrounSync"
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
SRC = os.path.join(REPO, "mod", "SurrounSyncGlider")
MIRROR = os.path.join(REPO, "mod", "SurrounSync", "Scripts", "mirror")
COPIED = ["glider.lua", "glideritem.lua", "modrecipe.lua"]
OWN = ["Scripts/main.lua", "Scripts/standalone.lua", "README.txt"]
# what standalone.lua puts in package.loaded (base.install): a glider file that requires anything else would fail
# in the game without SurrounSync, so the build stops
STANDS_IN = {"mirror.log", "mirror.util", "mirror.game", "mirror.jig", "mirror.peers", "mirror.events", "mirror.ghost",
             "mirror.notify"}
WIN64 = "SurrounDead/Binaries/Win64/"
CONTENT = "SurrounDead/Content/"
MOD = WIN64 + "ue4ss/Mods/SurrounSyncGlider/"
PAK = CONTENT + "Paks/LogicMods/SurrounSyncGlider.pak"
# the UE4SS loader, UE4SS and BPModLoaderMod (+ the UEHelpers it requires): an installer keeps what is there
SHARED = [WIN64 + "dwmapi.dll", WIN64 + "ue4ss/UE4SS.dll", WIN64 + "ue4ss/UE4SS-settings.ini", WIN64 + "ue4ss/LICENSE",
          WIN64 + "ue4ss/UE4SS_Signatures/", WIN64 + "ue4ss/Mods/BPModLoaderMod/", WIN64 + "ue4ss/Mods/shared/UEHelpers/"]
SHARED_FROM = {"game/dwmapi.dll", "game/ue4ss/UE4SS.dll", "game/ue4ss/UE4SS-settings.ini", "game/ue4ss/LICENSE"}
SHARED_DIRS = ["game/ue4ss/UE4SS_Signatures/", "game/ue4ss/Mods/BPModLoaderMod/", "game/ue4ss/Mods/shared/UEHelpers/"]


def read(path, default=""):
    try:
        with open(path, encoding="utf-8-sig") as f:
            return f.read().strip()
    except OSError:
        return default


def version():
    vlua = read(os.path.join(MIRROR, "version.lua"))
    return re.search(r'VERSION\s*=\s*"([^"]+)"', vlua).group(1)


def folder_files():
    """{path in the mod folder: bytes} - the whole Lua mod"""
    out = {}
    for rel in OWN:
        with open(os.path.join(SRC, rel.replace("/", os.sep)), "rb") as f:
            out[rel] = f.read()
    for name in COPIED:
        with open(os.path.join(MIRROR, name), "rb") as f:
            out["Scripts/mirror/" + name] = f.read()
    out["Scripts/mirror/glider_version.lua"] = ('return "%s"\n' % version()).encode("ascii")
    out["enabled.txt"] = b""   # UE4SS starts a mod with an enabled.txt in its folder
    have = {"mirror." + n[:-4] for n in COPIED} | {"mirror.glider_version", "standalone"}
    for rel, data in out.items():
        if rel.endswith(".lua"):
            for name in re.findall(r'require\("([^"]+)"\)', data.decode("utf-8")):
                if name not in have and name not in STANDS_IN:
                    sys.exit("%s requires %s: neither copied nor stood in for by standalone.lua - the glider mod "
                             "would fail without SurrounSync" % (rel, name))
    return out


def write_folder(dst):
    if os.path.exists(dst):
        shutil.rmtree(dst)
    for rel, data in folder_files().items():
        p = os.path.join(dst, rel.replace("/", os.sep))
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as f:
            f.write(data)


def shared_files(payload):
    """[(path in the zip, file on disk)]: UE4SS and BPModLoaderMod from SurrounSync's payload"""
    out = []
    for root, _, fs in os.walk(payload):
        for f in fs:
            full = os.path.join(root, f)
            rel = os.path.relpath(full, payload).replace(os.sep, "/")
            if rel in SHARED_FROM or any(rel.startswith(d) for d in SHARED_DIRS):
                out.append((WIN64 + rel[len("game/"):], full))
    return sorted(out)


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--folder":
        write_folder(os.path.abspath(sys.argv[2]))
        print("Wrote the glider mod folder to " + sys.argv[2])
        return
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    payload, dist = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
    ver = version()
    pak = os.path.join(payload, "content", "Paks", "LogicMods", "SurrounSyncGlider.pak")
    if not os.path.isfile(pak):
        sys.exit("the payload has no SurrounSyncGlider.pak: " + pak)
    shared = shared_files(payload)
    names = {t for t, _ in shared}
    for need in (WIN64 + "dwmapi.dll", WIN64 + "ue4ss/UE4SS.dll", WIN64 + "ue4ss/Mods/BPModLoaderMod/Scripts/main.lua",
                 WIN64 + "ue4ss/Mods/shared/UEHelpers/UEHelpers.lua"):
        if need not in names:
            sys.exit("the payload has no " + need)
    name = "SurrounSyncGlider-%s.zip" % ver
    zpath = os.path.join(dist, name)
    files = folder_files()
    with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for rel in sorted(files):
            z.writestr(MOD + rel, files[rel])
        z.write(pak, PAK)
        for to, full in shared:
            z.write(full, to)
        # (BPModLoaderMod on by its own enabled.txt where this UE4SS is new; one already listed in mods.txt starts once,
        # kit UE4SS.log 2026-11-10: SurrounDeadGore and FPVDrone, listed and with an enabled.txt, each started once)
        z.writestr(WIN64 + "ue4ss/Mods/BPModLoaderMod/enabled.txt", "")
    h = hashlib.sha256()
    with open(zpath, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    info = {
        "schema": 1,
        "name": "SurrounSyncGlider",
        "title": "SurrounSync Hang Glider",
        "version": ver,
        "released": time.strftime("%Y-%m-%d"),
        "game": {"name": "SurrounDead", "steam_app_id": 1645820,
                 "build": read(os.path.join(payload, "made_for_build.txt")),
                 "branch": read(os.path.join(payload, "made_for_beta.txt")),
                 "requires_exact_build": True,
                 "how_to_read": "steamapps/appmanifest_1645820.acf: \"buildid\" and UserConfig \"BetaKey\" (missing or \"public\" = the normal branch)"},
        "download": {"url": "https://github.com/%s/releases/download/v%s/%s" % (REPO_SLUG, ver, name),
                     "file": name, "size": os.path.getsize(zpath), "sha256": h.hexdigest()},
        "install": {
            "unzip_to": "the game's install folder, the one that holds SurrounDead.exe (Steam: steamapps/common/SurrounDead)",
            "enabled_by": MOD + "enabled.txt",
            "files": [MOD, PAK],
            "keep_if_present": SHARED,
            "needs_on": {"BPModLoaderMod": "loads Paks/LogicMods/SurrounSyncGlider.pak (a 1 in ue4ss/Mods/mods.txt, or its enabled.txt)"},
            "not_with": "SurrounSync already has the glider: with SurrounSync on, this mod stays off by itself",
        },
        "notes": "https://github.com/%s/releases/tag/v%s" % (REPO_SLUG, ver),
    }
    with open(os.path.join(dist, "version-glider.json"), "w", encoding="ascii", newline="\n") as f:
        json.dump(info, f, indent=2)
        f.write("\n")
    print("Built %s (%.1f MB) and version-glider.json" % (zpath, os.path.getsize(zpath) / 2 ** 20))


if __name__ == "__main__":
    main()
