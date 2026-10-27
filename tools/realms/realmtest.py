r"""Realm experiments: prepare / clean up throwaway test slots. Never writes the player's own saves.

  python -I realmtest.py prep <name> <source_slot> [--with-character]   copy a world (and optionally the character)
  python -I realmtest.py devtest on|off                                 host install mirror_settings.txt test mode
  python -I realmtest.py cleanup                                        remove RealmTest_* slots, restore profile

Test slots are named RealmTest_* (not co-op names: the mod empties co-op slots at startup and sends a player out
of a co-op slot outside a session). The EMS profile SurrounDead.sav and EmsUser.ini (CurrentSaveGameName = the
game's Continue) are backed up on the first prep and restored by cleanup. Run cleanup with the game closed: the game
rewrites EmsUser.ini when it exits.
"""
import os, shutil, sys

SAVED = os.path.join(os.environ["LOCALAPPDATA"], "SurrounDead", "Saved")
SAVES = os.path.join(SAVED, "SaveGames")
STATE = os.path.join(os.environ["LOCALAPPDATA"], "SurrounSync", "realmtest")
PROFILE = os.path.join(SAVES, "SurrounDead.sav")
PROFILE_BAK = os.path.join(STATE, "SurrounDead.sav.realmtest-bak")
# EMS keeps the current slot (Continue, and the slot a New Game saves into) here, not in the profile
EMSINI = os.path.join(SAVED, "Config", "Windows", "EmsUser.ini")
EMSINI_BAK = os.path.join(STATE, "EmsUser.ini.realmtest-bak")
SETTINGS = r"C:\Program Files (x86)\Steam\steamapps\common\SurrounDead\SurrounDead\Binaries\Win64\mirror_settings.txt"
SETTINGS_BAK = os.path.join(STATE, "mirror_settings.txt.realmtest-bak")
WORLD = ["Level.sav", "General.sav", "Difficulties.sav", "Slot.sav", "Thumb.sav", "Thumb.jpg"]
CHAR = ["Player.sav", "PlayerInfo.sav"]
SIDECARS = ["_SDQuests.sav", "_SkillTree.sav", "_Quests.sav"]
PREFIX = "RealmTest_"


def prep(name, src, with_char):
    assert name.startswith(PREFIX), "test slots must start with " + PREFIX
    s, d = os.path.join(SAVES, src), os.path.join(SAVES, name)
    assert os.path.isdir(s), "no slot " + src
    os.makedirs(STATE, exist_ok=True)
    if not os.path.exists(PROFILE_BAK) and os.path.exists(PROFILE):
        shutil.copy2(PROFILE, PROFILE_BAK)
        print("profile backed up ->", PROFILE_BAK)
    if not os.path.exists(EMSINI_BAK) and os.path.exists(EMSINI):
        shutil.copy2(EMSINI, EMSINI_BAK)
        print("EMS current slot backed up ->", EMSINI_BAK)
    os.makedirs(d, exist_ok=True)
    for f in WORLD + (CHAR if with_char else []):
        if os.path.exists(os.path.join(s, f)):
            shutil.copy2(os.path.join(s, f), os.path.join(d, f))
    if with_char:
        for x in SIDECARS:
            if os.path.exists(os.path.join(SAVES, src + x)):
                shutil.copy2(os.path.join(SAVES, src + x), os.path.join(SAVES, name + x))
    print("prepared", name, "from", src, ":", sorted(os.listdir(d)))


def devtest(on):
    os.makedirs(STATE, exist_ok=True)
    lines = open(SETTINGS, encoding="utf-8").read().splitlines() if os.path.exists(SETTINGS) else []
    if on:
        if not os.path.exists(SETTINGS_BAK):
            shutil.copy2(SETTINGS, SETTINGS_BAK)
        lines = [l for l in lines if not l.strip().lower().startswith("devtest")] + ["devtest = on"]
        with open(SETTINGS, "w", encoding="utf-8", newline="\r\n") as f:
            f.write("\n".join(lines) + "\n")
    elif os.path.exists(SETTINGS_BAK):
        shutil.copy2(SETTINGS_BAK, SETTINGS)
        os.remove(SETTINGS_BAK)
    print("settings:", [l for l in open(SETTINGS, encoding="utf-8").read().splitlines() if "=" in l])


def cleanup():
    for n in os.listdir(SAVES):
        p = os.path.join(SAVES, n)
        if n.startswith(PREFIX):
            (shutil.rmtree if os.path.isdir(p) else os.remove)(p)
            print("removed", n)
    if os.path.exists(PROFILE_BAK):
        shutil.copy2(PROFILE_BAK, PROFILE)
        os.remove(PROFILE_BAK)
        print("profile restored")
    if os.path.exists(EMSINI_BAK):
        shutil.copy2(EMSINI_BAK, EMSINI)
        os.remove(EMSINI_BAK)
        print("EMS current slot restored")


if __name__ == "__main__":
    a = sys.argv[1:]
    if a[0] == "prep":
        prep(a[1], a[2], "--with-character" in a)
    elif a[0] == "devtest":
        devtest(a[1] == "on")
    elif a[0] == "cleanup":
        cleanup()
