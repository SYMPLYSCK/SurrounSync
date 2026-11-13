"""The mod as a plain zip plus version.json, for other installers (a friend's universal SurrounDead mod installer).
tools/build-release.ps1 runs it on its staged setup payload; tools/publish-release.ps1 uploads both to the release.

    python -I tools/make-modzip.py <payload dir> <dist dir>

The zip mirrors the game's install folder (the one that holds SurrounDead.exe): unzip it there. SurrounSync switches
itself on with an enabled.txt in its folder (no mods.txt edit); SyncFX and the gore mod come switched off, as the
setup installs them. version.json lists the shared UE4SS files under "keep_if_present": other UE4SS mods use them too.

version.json always sits at https://github.com/<repo>/releases/latest/download/version.json.
"""
import hashlib
import json
import os
import re
import sys
import time
import zipfile

REPO_SLUG = "SYMPLYSCK/SurrounSync"
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
WIN64 = "SurrounDead/Binaries/Win64/"
CONTENT = "SurrounDead/Content/"
# the UE4SS loader, UE4SS itself and the loaders SurrounSync needs: an installer keeps what another mod put there
SHARED = [WIN64 + "dwmapi.dll", WIN64 + "ue4ss/UE4SS.dll", WIN64 + "ue4ss/UE4SS-settings.ini", WIN64 + "ue4ss/LICENSE",
          WIN64 + "ue4ss/UE4SS_Signatures/", WIN64 + "ue4ss/Mods/BPModLoaderMod/", WIN64 + "ue4ss/Mods/shared/UEHelpers/"]


def where(rel):
    """the payload's own layout (the setup's) -> the game folder's; None: not shipped in the zip"""
    if rel.startswith("game/"):
        return WIN64 + rel[len("game/"):]
    if rel.startswith("content/"):
        return CONTENT + rel[len("content/"):]
    if rel == "gore/SurrounDeadGore.pak":
        return CONTENT + "Paks/LogicMods/SurrounDeadGore.pak.off"   # off, like the setup leaves it
    return None


def read(path, default=""):
    try:
        with open(path, encoding="utf-8-sig") as f:
            return f.read().strip()
    except OSError:
        return default


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    payload, dist = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
    vlua = read(os.path.join(REPO, "mod", "SurrounSync", "Scripts", "mirror", "version.lua"))
    version = re.search(r'VERSION\s*=\s*"([^"]+)"', vlua).group(1)
    protocol = int(re.search(r"PROTOCOL\s*=\s*(\d+)", vlua).group(1))
    name = "SurrounSync-%s.zip" % version
    zpath = os.path.join(dist, name)
    files = []
    for root, _, fs in os.walk(payload):
        for f in fs:
            full = os.path.join(root, f)
            to = where(os.path.relpath(full, payload).replace(os.sep, "/"))
            if to:
                files.append((to, full))
    files.sort()
    mod = WIN64 + "ue4ss/Mods/SurrounSync/"
    if not any(t.startswith(mod + "Scripts/") for t, _ in files) or not any(t == mod + "bridge/SurrounSyncBridge.exe" for t, _ in files):
        sys.exit("the payload has no SurrounSync mod or bridge: " + payload)
    with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for to, full in files:
            z.write(full, to)
        z.writestr(mod + "enabled.txt", "")   # UE4SS starts a mod with an enabled.txt in its folder
    h = hashlib.sha256()
    with open(zpath, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    ue4ss = os.path.join(payload, "game", "ue4ss", "UE4SS.dll")
    with open(ue4ss, "rb") as f:
        ue4ss_sha = hashlib.sha256(f.read()).hexdigest()
    info = {
        "schema": 1,
        "name": "SurrounSync",
        "version": version,
        "protocol": protocol,
        "released": time.strftime("%Y-%m-%d"),
        # only this game build on this Steam branch ("" = the normal one): SurrounSync's own setup refuses any other
        # (Steam: buildid and UserConfig/BetaKey in steamapps/appmanifest_1645820.acf); an installer should too
        "game": {"name": "SurrounDead", "steam_app_id": 1645820,
                 "build": read(os.path.join(payload, "made_for_build.txt")),
                 "branch": read(os.path.join(payload, "made_for_beta.txt")),
                 "requires_exact_build": True,
                 "how_to_read": "steamapps/appmanifest_1645820.acf: \"buildid\" and UserConfig \"BetaKey\" (missing or \"public\" = the normal branch)"},
        "download": {"url": "https://github.com/%s/releases/download/v%s/%s" % (REPO_SLUG, version, name),
                     "file": name, "size": os.path.getsize(zpath), "sha256": h.hexdigest()},
        "install": {
            "unzip_to": "the game's install folder, the one that holds SurrounDead.exe (Steam: steamapps/common/SurrounDead)",
            "enabled_by": mod + "enabled.txt",
            "keep_if_present": SHARED,
            "ue4ss_dll_sha256": ue4ss_sha,
            "off_by_default": [WIN64 + "ue4ss/Mods/SyncFX/", WIN64 + "ue4ss/Mods/SurrounDeadGore/",
                               CONTENT + "Paks/LogicMods/SurrounDeadGore.pak.off"],
        },
        "setup": "https://github.com/%s/releases/download/v%s/SurrounSyncSetup.exe" % (REPO_SLUG, version),
        "notes": "https://github.com/%s/releases/tag/v%s" % (REPO_SLUG, version),
    }
    with open(os.path.join(dist, "version.json"), "w", encoding="ascii", newline="\n") as f:
        json.dump(info, f, indent=2)
        f.write("\n")
    print("Built %s (%.1f MB, %d files) and version.json" % (zpath, os.path.getsize(zpath) / 2 ** 20, len(files) + 1))


if __name__ == "__main__":
    main()
