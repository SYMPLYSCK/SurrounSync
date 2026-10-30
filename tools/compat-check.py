"""Game-update compatibility check for SurrounSync.

Compares two UE4SS object dumps (UE4SS_ObjectDump.txt, made before and after a game update) and
reports what changed in the classes and structs the mod uses:

  python tools/compat-check.py diff OLD_DUMP NEW_DUMP     members removed/renamed per class, flagged when the mod names them
  python tools/compat-check.py refs DUMP                  every "/Game/..." and "/Script/..." path in the mod, checked against DUMP
  python tools/compat-check.py names OLD_DUMP NEW_DUMP    member names the mod uses that the update removed from every class

A dump only holds what was loaded when it was made, so a class missing from the new dump is reported
as "not in the new dump" (unloaded or removed), never as removed for certain.
"""
import os
import re
import sys
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(ROOT, 'mod', 'surrounsync', 'scripts')

LINE = re.compile(r'^\[[0-9A-F]+\] (\w+) (/[^ :]+)(?::([^ \[]+))?')
GUID = re.compile(r'_\d+_[0-9A-F]{32}$')
TEMP = ('CallFunc_', 'K2Node_', 'Temp_', 'CallFunc', 'EntryPoint', 'Local', 'UberGraphFrame')
OWNER_KINDS = ('Class', 'BlueprintGeneratedClass', 'WidgetBlueprintGeneratedClass', 'AnimBlueprintGeneratedClass',
               'ScriptStruct', 'UserDefinedStruct', 'UserDefinedEnum', 'Enum')


def stem(name):
    return GUID.sub('', name)


def parse(path):
    """-> owners {path: kind}, members {owner_path: {member_name: kind}}, objects {every object path}"""
    owners, members, objects = {}, defaultdict(dict), set()
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            m = LINE.match(line)
            if not m:
                continue
            kind, obj, member = m.groups()
            if member:
                # Function:Param - keep parameters (a signature change breaks calls and hooks), skip the
                # compiler's locals, which change with every recompile of the graph
                if ':' in member:
                    fn, local = member.split(':', 1)
                    if ':' in local or local.startswith(TEMP):
                        continue
                members[obj][member] = kind
            else:
                objects.add(obj)
                if kind in OWNER_KINDS:
                    owners[obj] = kind
    return owners, members, objects


def mod_sources():
    out = {}
    for d, _, files in os.walk(SCRIPTS):
        for fn in files:
            if fn.endswith('.lua'):
                p = os.path.join(d, fn)
                with open(p, encoding='utf-8', errors='replace') as f:
                    out[os.path.relpath(p, ROOT)] = f.read()
    return out


def mod_uses(name, sources):
    name = name.split(':')[0]   # a changed parameter matters where the mod names its function
    rx = re.compile(r'(?<![\w])' + re.escape(name) + r'(?![\w])')
    return [p for p, text in sources.items() if rx.search(text)]


def cmd_diff(old_path, new_path):
    old_owners, old_m, _ = parse(old_path)
    new_owners, new_m, _ = parse(new_path)
    sources = mod_sources()
    game = lambda p: p.startswith('/Game/') or p.startswith('/Script/SurrounDead')
    flagged, other, missing = [], [], []
    for owner in sorted(o for o in old_owners if game(o)):
        if owner not in new_owners:
            short = owner.rsplit('.', 1)[-1]
            if mod_uses(short, sources) or any(owner.split('.')[0] in t for t in sources.values()):
                missing.append(owner)
            continue
        old, new = old_m.get(owner, {}), new_m.get(owner, {})
        new_stems = defaultdict(list)
        for n in new:
            new_stems[stem(n)].append(n)
        for name in sorted(set(old) - set(new)):
            renamed = [n for n in new_stems.get(stem(name), []) if n not in old]
            what = f'{old[name]} {name}' + (f' -> renamed {renamed[0]}' if renamed else ' REMOVED')
            used = mod_uses(name, sources) or (not renamed and mod_uses(stem(name), sources))
            (flagged if used else other).append((owner, what, used))
        for name in sorted(set(new) - set(old)):
            if not any(stem(name) == stem(o) for o in old):
                other.append((owner, f'{new[name]} {name} ADDED', []))
    new_game_classes = sorted(o for o in new_owners if game(o) and o not in old_owners)

    print(f'== CHANGES THE MOD USES ({len(flagged)})')
    for owner, what, used in flagged:
        print(f'  {owner}: {what}\n      used in: {", ".join(used)}')
    print(f'\n== MOD-REFERENCED CLASSES NOT IN THE NEW DUMP ({len(missing)}) - unloaded or removed, check with refs')
    for o in missing:
        print('  ' + o)
    print(f'\n== OTHER MEMBER CHANGES ({len(other)})')
    for owner, what, _ in other:
        print(f'  {owner}: {what}')
    print(f'\n== NEW GAME CLASSES/STRUCTS ({len(new_game_classes)})')
    for o in new_game_classes:
        print('  ' + o)


def cmd_refs(dump_path):
    _, members, all_paths = parse(dump_path)
    packages = {p.split('.')[0] for p in all_paths}
    sources = mod_sources()
    refs = defaultdict(set)
    for p, text in sources.items():
        for lit in re.findall(r'"(/(?:Game|Script)/[^"]+)"', text):
            refs[lit].add(p)
    bad = 0
    for lit in sorted(refs):
        obj, _, member = lit.partition(':')
        if obj.endswith(('/', '_', '.')):
            ok = any(p.startswith(obj) for p in all_paths)         # prefix the mod builds paths from
        elif '.' not in obj:
            ok = obj in packages or any(p.startswith(obj + '/') for p in packages)
        else:
            ok = obj in all_paths or obj.replace('Default__', '') in all_paths
        if ok and member:
            ok = member in members.get(obj, {})
        if not ok:
            bad += 1
            print(f'  NOT FOUND {lit}\n      used in: {", ".join(sorted(refs[lit]))}')
    print(f'{len(refs)} paths checked, {bad} not found in {os.path.basename(dump_path)} '
          '(a dump only holds what was loaded: check NOT FOUND ones in a dump made in-game)')


def member_names(path):
    _, members, _ = parse(path)
    names = set()
    for m in members.values():
        for n in m:
            names.add(n.split(':')[0])
            names.add(stem(n.split(':')[0]))
    return names


def cmd_names(old_path, new_path):
    """Every PascalCase member name the mod uses (obj.Name, obj:Name(, obj["Name"]) that the old dump had and the
    new one has nowhere. Names in neither dump are UE4SS API calls or the mod's own tables and are skipped."""
    old, new = member_names(old_path), member_names(new_path)
    sources = mod_sources()
    used = defaultdict(set)
    for p, text in sources.items():
        for rx in (r'[\w\)\]]\.([A-Z][A-Za-z0-9_]*)', r':([A-Z][A-Za-z0-9_]*)\(', r'\["([^"\]\n]+)"\]'):
            for n in re.findall(rx, text):
                used[n].add(p)
    gone = sorted(n for n in used if n in old and n not in new)
    print(f'{len(used)} names used by the mod, {sum(1 for n in used if n in new)} found in the new dump, '
          f'{len(gone)} only in the old dump:')
    for n in gone:
        print(f'  GONE {n}\n      used in: {", ".join(sorted(used[n]))}')


if __name__ == '__main__':
    if len(sys.argv) == 4 and sys.argv[1] == 'diff':
        cmd_diff(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 4 and sys.argv[1] == 'names':
        cmd_names(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 3 and sys.argv[1] == 'refs':
        cmd_refs(sys.argv[2])
    else:
        print(__doc__)
        sys.exit(2)
