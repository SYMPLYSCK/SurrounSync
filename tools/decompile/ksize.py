"""Serialized (in-memory) size of UAssetAPI-JSON Kismet expressions, UE5 LWC layout."""
P = 8
N = 12
def T(e): return e["$type"].split(",")[0].split(".")[-1]
def lst(x): return sum(size(i) for i in (x or []))
def text(v):
    t = v.get("TextLiteralType")
    t = {0:"Empty",1:"LocalizedText",2:"InvariantText",3:"LiteralString",4:"StringTableEntry"}.get(t,t)
    if t == "Empty": return 0
    if t == "LocalizedText": return size(v["LocalizedSource"])+size(v["LocalizedKey"])+size(v["LocalizedNamespace"])
    if t == "InvariantText": return size(v["InvariantLiteralString"])
    if t == "LiteralString": return size(v["LiteralString"])
    if t == "StringTableEntry": return P+size(v["StringTableId"])+size(v["StringTableKey"])
    raise ValueError(f"text type {t}")
def size(e):
    t = T(e); g = e.get
    fixed = {"EX_LocalVariable":P,"EX_InstanceVariable":P,"EX_DefaultVariable":P,"EX_LocalOutVariable":P,
      "EX_ClassSparseDataVariable":P,"EX_Self":0,"EX_True":0,"EX_False":0,"EX_NoObject":0,"EX_NoInterface":0,
      "EX_Nothing":0,"EX_EndOfScript":0,"EX_PopExecutionFlow":0,"EX_Tracepoint":0,"EX_WireTracepoint":0,
      "EX_IntZero":0,"EX_IntOne":0,"EX_IntConst":4,"EX_FloatConst":4,"EX_DoubleConst":8,"EX_ByteConst":1,
      "EX_IntConstByte":1,"EX_Int64Const":8,"EX_UInt64Const":8,"EX_SkipOffsetConst":4,"EX_NameConst":N,
      "EX_ObjectConst":P,"EX_VectorConst":24,"EX_RotationConst":24,"EX_TransformConst":80,"EX_Vector3fConst":12,
      "EX_Jump":4,"EX_PushExecutionFlow":4,"EX_InstanceDelegate":N,"EX_PropertyConst":P}
    if t in fixed: return 1+fixed[t]
    if t == "EX_BitFieldConst": return 1+P+1
    if t == "EX_StringConst": return 1+len(g("Value"))+1
    if t == "EX_UnicodeStringConst": return 1+2*(len(g("Value"))+1)
    if t == "EX_TextConst": return 1+1+text(g("Value"))
    if t in ("EX_Return","EX_ComputedJump","EX_PopExecutionFlowIfNot","EX_InterfaceContext","EX_SoftObjectConst",
             "EX_FieldPathConst","EX_ClearMulticastDelegate"):
        k = {"EX_Return":"ReturnExpression","EX_ComputedJump":"CodeOffsetExpression","EX_PopExecutionFlowIfNot":"BooleanExpression",
             "EX_InterfaceContext":"InterfaceValue","EX_SoftObjectConst":"Value","EX_FieldPathConst":"Value",
             "EX_ClearMulticastDelegate":"DelegateToClear"}[t]
        return 1+size(g(k))
    if t == "EX_JumpIfNot": return 1+4+size(g("BooleanExpression"))
    if t == "EX_Let": return 1+P+size(g("Variable"))+size(g("Expression"))
    if t.startswith("EX_Let") and t != "EX_LetValueOnPersistentFrame": return 1+size(g("VariableExpression"))+size(g("AssignmentExpression"))
    if t == "EX_LetValueOnPersistentFrame": return 1+P+size(g("AssignmentExpression"))
    if t in ("EX_Context","EX_Context_FailSilent","EX_ClassContext"): return 1+size(g("ObjectExpression"))+4+P+size(g("ContextExpression"))
    if t in ("EX_FinalFunction","EX_LocalFinalFunction","EX_CallMath"): return 1+P+lst(g("Parameters"))+1
    if t == "EX_CallMulticastDelegate": return 1+P+size(g("Delegate"))+lst(g("Parameters"))+1
    if t in ("EX_VirtualFunction","EX_LocalVirtualFunction"): return 1+N+lst(g("Parameters"))+1
    if t == "EX_StructMemberContext": return 1+P+size(g("StructExpression"))
    if t in ("EX_DynamicCast","EX_MetaCast","EX_ObjToInterfaceCast","EX_CrossInterfaceCast","EX_InterfaceToObjCast"): return 1+P+size(g("Target"))
    if t == "EX_PrimitiveCast": return 1+1+size(g("Target"))
    if t == "EX_StructConst": return 1+P+4+lst(g("Value"))+1
    if t == "EX_SetArray": return 1+size(g("AssigningProperty"))+lst(g("Elements"))+1
    if t == "EX_ArrayConst": return 1+P+4+lst(g("Elements"))+1
    if t == "EX_SetMap": return 1+size(g("MapProperty"))+4+lst(g("Elements"))+1
    if t == "EX_MapConst": return 1+P+P+4+lst(g("Elements"))+1
    if t == "EX_SetSet": return 1+size(g("SetProperty"))+4+lst(g("Elements"))+1
    if t == "EX_BindDelegate": return 1+N+size(g("Delegate"))+size(g("ObjectTerm"))
    if t in ("EX_AddMulticastDelegate","EX_RemoveMulticastDelegate"): return 1+size(g("Delegate"))+size(g("DelegateToAdd"))
    if t == "EX_ArrayGetByRef": return 1+size(g("ArrayVariable"))+size(g("ArrayIndex"))
    if t == "EX_SwitchValue":
        return 1+2+4+size(g("IndexTerm"))+sum(size(c["CaseIndexValueTerm"])+4+size(c["CaseTerm"]) for c in g("Cases"))+size(g("DefaultTerm"))
    raise ValueError("unknown "+t)
