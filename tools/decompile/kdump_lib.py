"""Print UAssetGUI-JSON Kismet bytecode as rough pseudo-code.
usage: python -I kdump.py <asset.json> <out.txt> [function-name-filter...]"""
import json, sys

imports = exports = None
def load(d):
    global imports, exports
    imports, exports = d["Imports"], d["Exports"]


def ref(i):
    if not isinstance(i, int) or i == 0:
        return "null"
    if i < 0:
        imp = imports[-i - 1]
        return imp["ObjectName"]
    return exports[i - 1].get("ObjectName", f"export{i}")


def prop(p):
    if not p:
        return "?"
    n = p.get("New") or {}
    path = n.get("Path") or []
    if path:
        return ".".join(path)
    old = p.get("Old")
    return ref(old) if old else "?"


def short(t):
    return t.split(",")[0].split(".")[-1]


def r(e):
    if e is None:
        return "None"
    if isinstance(e, list):
        return ", ".join(r(x) for x in e)
    if not isinstance(e, dict):
        return repr(e)
    t = short(e.get("$type", "?"))
    g = e.get
    if t in ("EX_LocalVariable", "EX_InstanceVariable", "EX_LocalOutVariable", "EX_DefaultVariable",
             "EX_ClassSparseDataVariable"):
        pre = {"EX_InstanceVariable": "self.", "EX_DefaultVariable": "default."}.get(t, "")
        return pre + prop(g("Variable"))
    if t == "EX_Self":
        return "self"
    if t in ("EX_NoObject", "EX_NoInterface"):
        return "null"
    if t == "EX_True":
        return "true"
    if t == "EX_False":
        return "false"
    if t in ("EX_IntConst", "EX_FloatConst", "EX_DoubleConst", "EX_ByteConst", "EX_Int64Const",
             "EX_UInt64Const", "EX_IntConstByte", "EX_SkipOffsetConst"):
        return str(g("Value"))
    if t in ("EX_NameConst",):
        return f"Name'{g('Value')}'"
    if t in ("EX_StringConst", "EX_UnicodeStringConst"):
        return f'"{g("Value")}"'
    if t == "EX_TextConst":
        v = g("Value") or {}
        return "Text" + json.dumps({k: v[k] for k in v if k != "$type"})[:120]
    if t == "EX_ObjectConst":
        return f"Obj<{ref(g('Value'))}>"
    if t in ("EX_SoftObjectConst",):
        return "Soft<" + r(g("Value")) + ">"
    if t in ("EX_CallMath", "EX_FinalFunction", "EX_LocalFinalFunction", "EX_CallMulticastDelegate"):
        return f"{ref(g('StackNode'))}({r(g('Parameters'))})"
    if t in ("EX_VirtualFunction", "EX_LocalVirtualFunction"):
        return f"{g('VirtualFunctionName')}({r(g('Parameters'))})"
    if t in ("EX_Context", "EX_Context_FailSilent", "EX_ClassContext"):
        return f"{r(g('ObjectExpression'))}.{r(g('ContextExpression'))}"
    if t in ("EX_InterfaceContext",):
        return r(g("InterfaceValue"))
    if t.startswith("EX_Let"):
        return f"{r(g('VariableExpression') or g('Variable'))} = {r(g('AssignmentExpression') or g('Expression'))}"
    if t in ("EX_DynamicCast", "EX_MetaCast", "EX_ObjToInterfaceCast", "EX_CrossInterfaceCast",
             "EX_InterfaceToObjCast"):
        return f"cast<{ref(g('ClassPtr'))}>({r(g('Target'))})"
    if t == "EX_PrimitiveCast":
        return f"pcast({r(g('Target'))})"
    if t == "EX_JumpIfNot":
        return f"if not ({r(g('BooleanExpression'))}) goto {g('CodeOffset')}"
    if t == "EX_Jump":
        return f"goto {g('CodeOffset')}"
    if t == "EX_ComputedJump":
        return f"goto [{r(g('CodeOffsetExpression'))}]"
    if t == "EX_PushExecutionFlow":
        return f"push {g('PushingAddress')}"
    if t == "EX_PopExecutionFlow":
        return "pop"
    if t == "EX_PopExecutionFlowIfNot":
        return f"pop if not ({r(g('BooleanExpression'))})"
    if t == "EX_Return":
        return f"return {r(g('ReturnExpression'))}"
    if t in ("EX_Nothing", "EX_EndOfScript", "EX_Tracepoint", "EX_WireTracepoint", "EX_NothingInt32"):
        return ""
    if t in ("EX_StructConst",):
        return f"{ref(g('Struct'))}{{{r(g('Value'))}}}"
    if t in ("EX_SetArray", "EX_ArrayConst"):
        return f"[{r(g('Elements'))}]"
    if t == "EX_StructMemberContext":
        return f"{r(g('StructExpression'))}.{prop(g('StructMemberExpression'))}"
    if t in ("EX_BindDelegate",):
        return f"bind({g('FunctionName')}, {r(g('Delegate'))}, {r(g('ObjectTerm'))})"
    if t in ("EX_AddMulticastDelegate", "EX_RemoveMulticastDelegate"):
        return f"{t[3:]}({r(g('Delegate'))}, {r(g('DelegateToAdd'))})"
    if t == "EX_InstanceDelegate":
        return f"delegate({g('FunctionName')})"
    if t == "EX_SwitchValue":
        return f"switch({r(g('IndexTerm'))}) default {r(g('DefaultTerm'))}"
    rest = {k: v for k, v in e.items() if k != "$type"}
    return t + "(" + ", ".join(f"{k}={r(v) if isinstance(v,(dict,list)) else v}" for k, v in rest.items()) + ")"
