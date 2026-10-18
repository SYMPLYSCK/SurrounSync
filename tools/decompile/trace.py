import json, sys
import ksize, kdump_lib as K
src, ug, out = sys.argv[1], sys.argv[2], sys.argv[3]
entries = [a.split("=") for a in sys.argv[4:]]
d = json.load(open(src, encoding="utf-8")); K.load(d)
bc = [e for e in d["Exports"] if e.get("ObjectName") == ug][0]["ScriptBytecode"]
offs = []; o = 0
for s in bc: offs.append(o); o += ksize.size(s)
idx = {off: i for i, off in enumerate(offs)}
with open(out, "w", encoding="utf-8") as f:
    for name, start in entries:
        seen = set(); work = [int(start)]
        while work:
            i = idx[work.pop()]
            while i < len(bc) and i not in seen:
                seen.add(i); s = bc[i]; t = ksize.T(s)
                if t == "EX_Jump": work.append(s["CodeOffset"]); break
                if t == "EX_JumpIfNot": work.append(s["CodeOffset"])
                if t == "EX_PushExecutionFlow": work.append(s["PushingAddress"])
                if t in ("EX_PopExecutionFlow", "EX_Return", "EX_EndOfScript"): break
                if t == "EX_PopExecutionFlowIfNot": pass
                if t == "EX_ComputedJump": break
                i += 1
        f.write(f"\n===== {name} @ {start}  ({len(seen)} stmts) =====\n")
        for i in sorted(seen):
            line = K.r(bc[i])
            if line: f.write(f"{offs[i]:7d}  {line}\n")
print("ok")
