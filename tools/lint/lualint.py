"""Lua lint for the mod: syntax errors and undeclared names (a typo is just nil at runtime).

    python -I tools/lint/lualint.py mod/SurrounSync/Scripts/mirror/*.lua

Needs luaparser: pip install --target tools/lint/luapkg luaparser (or set LUAPARSER_PATH).
"""
import sys, os
sys.path.insert(0, os.environ.get("LUAPARSER_PATH", os.path.join(os.path.dirname(os.path.abspath(__file__)), "luapkg")))
from luaparser import ast, astnodes as N
KNOWN = set("""print require load pcall error type tostring tonumber pairs ipairs table string math os io select setmetatable getmetatable next rawget rawset unpack collectgarbage coroutine debug package _G
FindAllOf FindFirstOf StaticFindObject StaticConstructObject LoadAsset RegisterHook RegisterKeyBind Key ModifierKey FName FText NotifyOnNewObject ExecuteInGameThread LoopAsync ExecuteWithDelay""".split())
def visit(node, scopes, out, f):
    def declared(name): return any(name in s for s in scopes)
    def walk(n):
        if isinstance(n, list):
            for x in n: walk(x)
            return
        if not isinstance(n, N.Node): return
        if isinstance(n, N.Block):
            scopes.append(set()); walk(n.body); scopes.pop(); return
        if isinstance(n, N.LocalAssign):
            walk(n.values)
            for t in n.targets: scopes[-1].add(t.id)
            return
        if isinstance(n, N.LocalFunction):
            scopes[-1].add(n.name.id)
            scopes.append(set(a.id for a in n.args if isinstance(a, N.Name))); walk(n.body); scopes.pop(); return
        if isinstance(n, (N.Function, N.AnonymousFunction, N.Method)):
            if isinstance(n, N.Function): walk_target(n.name)
            args = set(a.id for a in n.args if isinstance(a, N.Name))
            if isinstance(n, N.Method): args.add("self"); walk(n.source)
            scopes.append(args); walk(n.body); scopes.pop(); return
        if isinstance(n, N.Fornum):
            walk(n.start); walk(n.stop); walk(n.step)
            scopes.append({n.target.id}); walk(n.body); scopes.pop(); return
        if isinstance(n, N.Forin):
            walk(n.iter)
            scopes.append(set(t.id for t in n.targets)); walk(n.body); scopes.pop(); return
        if isinstance(n, N.Index):
            walk(n.value)
            if n.notation == N.IndexNotation.SQUARE: walk(n.idx)
            return
        if isinstance(n, N.Invoke):
            walk(n.source); walk(n.args); return
        if isinstance(n, N.Field):
            if getattr(n, "between_brackets", False): walk(n.key)
            walk(n.value); return
        if isinstance(n, N.Name):
            if not declared(n.id) and n.id not in KNOWN: out.add(n.id)
            return
        for k, v in vars(n).items():
            if k in ("comments", "first_token", "last_token", "line", "start_char", "stop_char"): continue
            walk(v)
    def walk_target(t):
        walk(t)
    walk(node)
def unterminated_strings(src):
    """Lines where a '...' or "..." string runs past the end of the line (a raw newline inside a short
    string: invalid Lua, but luaparser accepts it). Skips comments and [[long strings]]."""
    out, in_long, q = [], False, None
    for no, line in enumerate(src.split("\n"), 1):
        i, n = 0, len(line)
        while i < n:
            c = line[i]
            if in_long:
                j = line.find("]]", i)
                if j < 0: i = n; break
                in_long, i = False, j + 2; continue
            if q:
                if c == "\\": i += 2; continue
                if c == q: q = None
                i += 1; continue
            if line.startswith("--", i):
                if line.startswith("--[[", i): in_long, i = True, i + 4; continue
                break
            if line.startswith("[[", i): in_long, i = True, i + 2; continue
            if c in "\"'": q = c
            i += 1
        if q:
            out.append(no); q = None
    return out


bad = 0
for f in sys.argv[1:]:
    src = open(f, encoding="utf-8").read()
    lines = unterminated_strings(src)
    if lines:
        bad += 1
        print("STRING", os.path.basename(f), "unterminated string on line(s)", lines)
    try:
        tree = ast.parse(src)
    except Exception as e:
        bad += 1
        print("SYNTAX", os.path.basename(f), str(e)[:300])
        continue
    out = set()
    visit(tree, [set()], out, f)
    if out:
        bad += 1
        print("GLOBALS", os.path.basename(f), sorted(out))
print("lint: %d file(s), %d problem(s)" % (len(sys.argv) - 1, bad))
sys.exit(1 if bad else 0)
