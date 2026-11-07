# UE 5.6 editor script for SurrounSyncArmory.pak (build-armory.ps1): the Colonel's Revenge Double Drum Magazine (user
# 2026-11-02) and the diamond finish (user 2026-11-03).
#  - SM_CRDoubleDrumMag from out/DoubleDrum.gltf (make_drummag.py) with M_CRDoubleDrumMag: colour from the palette,
#    the palette's alpha is the finish code (lowpoly.py: 0 matte, 0.5 gloss, 1 polished metal).
#  - M_ColonelsDiamond: crystal shards (T_DiamondFacets, make_diamond.py) whose brightness follows the luminance of a
#    "Detail" texture; armory.lua makes a dynamic instance of it with Detail = the game's weapon atlas and puts it on
#    the Colonel's Revenge.
#  - DA_CRDoubleDrumMag: the item, an instance of the game's item class (stub Blueprint at its exact path, as in
#    tools/glider/import_glider.py), a 200-round 5.56 magazine for the CRDrumMag socket.
#  - ModActor (BPModLoader spawns it at every level load): hard references load all of the above with the pak.
import json
import os
import unreal

MOD = "SurrounSyncArmory"
DEST = "/Game/Mods/" + MOD
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
SRC = os.path.join(OUT, "DoubleDrum.gltf")
# M_ColonelsDiamond's parameter defaults (see the diamond finish below)
DIAMOND_LOOK = {"Ice": (0.93, 0.97, 1.0), "FacetScale": 0.03, "Tilt": 0.4, "Iris": 0.7, "IdSpread": 3.0,
                "ViewSpread": 1.6, "Drift": 0.03, "LitLow": 0.38, "Gain": 1.6, "DarkShade": 0.45, "Metallic": 0.25,
                "Roughness": 0.1, "Glow": 0.18, "SparkGain": 5.0, "SparkPower": 60.0, "Wobble": 0.6}

tools = unreal.AssetToolsHelpers.get_asset_tools()
lib = unreal.EditorAssetLibrary
mel = unreal.MaterialEditingLibrary
bel = unreal.BlueprintEditorLibrary
MP = unreal.MaterialProperty

CHAR_DIR = "/Game/Character/BaseRig"   # the rider's stand-in skeleton (import_rider), never packed
for d in (DEST, CHAR_DIR):
    if lib.does_directory_exist(d):
        lib.delete_directory(d)
    lib.make_directory(d)


def import_file(path, folder, name=None, save=True):
    t = unreal.AssetImportTask()
    t.filename = path
    t.destination_path = folder
    if name:
        t.destination_name = name
    t.automated = True
    t.replace_existing = True
    t.save = save
    tools.import_asset_tasks([t])


def palette_texture(path, name, srgb=True):
    """Nearest filter, no mips, uncompressed: a face never picks up a neighbouring swatch and alpha stays exact."""
    import_file(path, DEST, name, save=False)
    tex = lib.load_asset(DEST + "/" + name)
    if tex is None:
        raise RuntimeError(name + " did not import")
    tex.set_editor_property("filter", unreal.TextureFilter.TF_NEAREST)
    tex.set_editor_property("mip_gen_settings", unreal.TextureMipGenSettings.TMGS_NO_MIPMAPS)
    tex.set_editor_property("srgb", srgb)
    tex.set_editor_property("compression_settings", unreal.TextureCompressionSettings.TC_EDITOR_ICON)
    tex.set_editor_property("never_stream", True)
    lib.save_loaded_asset(tex)
    return tex


def const(mat, v, x, y):
    c = mel.create_material_expression(mat, unreal.MaterialExpressionConstant, x, y)
    c.set_editor_property("r", v)
    return c


def scalar(mat, name, v, x, y):
    p = mel.create_material_expression(mat, unreal.MaterialExpressionScalarParameter, x, y)
    p.set_editor_property("parameter_name", name)
    p.set_editor_property("default_value", v)
    return p


def colour(mat, name, rgb, x, y):
    p = mel.create_material_expression(mat, unreal.MaterialExpressionVectorParameter, x, y)
    p.set_editor_property("parameter_name", name)
    p.set_editor_property("default_value", unreal.LinearColor(rgb[0], rgb[1], rgb[2], 1.0))
    return p


def wire(src, out, dst, pin):
    """A connection that silently did not take would compile into a wrong look: stop the build instead."""
    if not mel.connect_material_expressions(src, out, dst, pin):
        raise RuntimeError("could not connect %s to pin %s" % (src.get_name(), pin))


def hlsl(mat, label, kind, inputs, code, x, y):
    """A Custom node; inputs: pin name -> (expression, its output name)."""
    c = mel.create_material_expression(mat, unreal.MaterialExpressionCustom, x, y)
    c.set_editor_property("description", label)
    c.set_editor_property("output_type", kind)
    c.set_editor_property("code", code)
    pins = []
    for name in inputs:
        p = unreal.CustomInput()
        p.set_editor_property("input_name", name)
        pins.append(p)
    c.set_editor_property("inputs", pins)
    for name, (src, out) in inputs.items():
        wire(src, out, c, name)
    return c


def import_mesh(src, name):
    import_file(src, DEST + "/Import")
    m = None
    for p in lib.list_assets(DEST + "/Import", recursive=True):
        a = lib.load_asset(p)
        unreal.log("ARMORY imported " + p + " " + a.get_class().get_name())
        if isinstance(a, unreal.StaticMesh):
            m = a
    if m is None:
        raise RuntimeError("no static mesh came out of " + src)
    lib.rename_asset(m.get_path_name().split(".")[0], DEST + "/" + name)
    return lib.load_asset(DEST + "/" + name)


def palette_material(name, pal):
    """Colour from the palette, finish from its alpha."""
    mat = tools.create_asset(name, DEST, unreal.Material, unreal.MaterialFactoryNew())
    vc = mel.create_material_expression(mat, unreal.MaterialExpressionTextureSample, -900, 0)
    vc.set_editor_property("texture", pal)
    vc.set_editor_property("sampler_type", unreal.MaterialSamplerType.SAMPLERTYPE_COLOR)
    mel.connect_material_property(vc, "RGB", MP.MP_BASE_COLOR)
    # metallic = saturate(2A - 1): 1 for metal, 0 for gloss and matte
    a2 = mel.create_material_expression(mat, unreal.MaterialExpressionMultiply, -550, 200)
    mel.connect_material_expressions(vc, "A", a2, "A")
    mel.connect_material_expressions(const(mat, 2.0, -700, 200), "", a2, "B")
    a21 = mel.create_material_expression(mat, unreal.MaterialExpressionSubtract, -400, 200)
    mel.connect_material_expressions(a2, "", a21, "A")
    mel.connect_material_expressions(const(mat, 1.0, -700, 280), "", a21, "B")
    metal = mel.create_material_expression(mat, unreal.MaterialExpressionSaturate, -250, 200)
    mel.connect_material_expressions(a21, "", metal, "")
    mel.connect_material_property(metal, "", MP.MP_METALLIC)
    # roughness = lerp(0.82, 0.12, saturate(2A)): matte black stays matte, gold and the window are polished
    shiny = mel.create_material_expression(mat, unreal.MaterialExpressionSaturate, -400, 380)
    mel.connect_material_expressions(a2, "", shiny, "")
    rough = mel.create_material_expression(mat, unreal.MaterialExpressionLinearInterpolate, -250, 380)
    mel.connect_material_expressions(const(mat, 0.82, -550, 340), "", rough, "A")
    mel.connect_material_expressions(const(mat, 0.12, -550, 440), "", rough, "B")
    mel.connect_material_expressions(shiny, "", rough, "Alpha")
    mel.connect_material_property(rough, "", MP.MP_ROUGHNESS)
    mel.recompile_material(mat)
    lib.save_loaded_asset(mat)
    return mat


def finish_mesh(m, mat):
    m.set_material(0, mat)
    try:
        unreal.EditorStaticMeshLibrary.remove_collisions(m)   # worn or on a gun, never something to stand on
    except Exception as e:
        unreal.log_warning("ARMORY remove_collisions: %s" % e)
    lib.save_loaded_asset(m)
    lib.delete_directory(DEST + "/Import")


# --- the magazine mesh ----------------------------------------------------------------------------------------------
mesh = import_mesh(SRC, "SM_CRDoubleDrumMag")
pal = palette_texture(os.path.join(OUT, "Palette.png"), "T_CRDoubleDrumPalette")
mat = palette_material("M_CRDoubleDrumMag", pal)
finish_mesh(mesh, mat)

# --- the diamond finish for the gun ---------------------------------------------------------------------------------
# Shards from T_DiamondFacets, each with its own tilt and id: mostly ice white, some strongly coloured, some dark.
#  - Mapped from the mesh's own position before skinning, never the atlas UVs (islands cut the shards at every seam and
#    stretch them), through a vertex interpolator because that node only exists in the vertex shader. The plane is
#    picked per triangle from its normal, so a shard stays one flat hard-edged piece and never swims when the gun moves.
#  - The tilts stay in world space on purpose: a held gun turns with the camera, so tilts in the gun's frame would give
#    every shard the same view angle all the time and the colours would never move; this way they run as you look round.
#  - Metallic stays low: a mirror metal shows only the world (the gold read olive in the green daylight), so the ice
#    white comes mostly from diffuse light, which also goes dark at night where a strong emissive would not.
#  - k = saturate(luminance(Detail) * Gain) keeps the atlas' dark parts (grip, seams) as darker crystal.
# All scalar/vector parameters, so armory.lua's dynamic instance can tune them live.
white = palette_texture(os.path.join(OUT, "White.png"), "T_White")
facets_tex = palette_texture(os.path.join(OUT, "DiamondFacets.png"), "T_DiamondFacets", srgb=False)
FLOAT3 = unreal.CustomMaterialOutputType.CMOT_FLOAT3
FLOAT4 = unreal.CustomMaterialOutputType.CMOT_FLOAT4
diamond = tools.create_asset("M_ColonelsDiamond", DEST, unreal.Material, unreal.MaterialFactoryNew())
LOOK = DIAMOND_LOOK


def knob(name, x, y):
    return scalar(diamond, name, LOOK[name], x, y), ""


det = mel.create_material_expression(diamond, unreal.MaterialExpressionTextureSampleParameter2D, -2000, 0)
det.set_editor_property("parameter_name", "Detail")
det.set_editor_property("texture", white)
det.set_editor_property("sampler_type", unreal.MaterialSamplerType.SAMPLERTYPE_COLOR)
w = mel.create_material_expression(diamond, unreal.MaterialExpressionConstant3Vector, -2000, 250)
w.set_editor_property("constant", unreal.LinearColor(0.3, 0.59, 0.11, 1.0))
lum = mel.create_material_expression(diamond, unreal.MaterialExpressionDotProduct, -1800, 100)
wire(det, "RGB", lum, "A")
wire(w, "", lum, "B")
lum2 = mel.create_material_expression(diamond, unreal.MaterialExpressionMultiply, -1650, 100)
wire(lum, "", lum2, "A")
wire(knob("Gain", -1800, 220)[0], "", lum2, "B")
k = mel.create_material_expression(diamond, unreal.MaterialExpressionSaturate, -1500, 100)
wire(lum2, "", k, "")

sheet = mel.create_material_expression(diamond, unreal.MaterialExpressionTextureObjectParameter, -2000, -400)
sheet.set_editor_property("parameter_name", "Facets")
sheet.set_editor_property("texture", facets_tex)
sheet.set_editor_property("sampler_type", unreal.MaterialSamplerType.SAMPLERTYPE_LINEAR_COLOR)
rest = mel.create_material_expression(diamond, unreal.MaterialExpressionPreSkinnedPosition, -2000, -250)
rest_ps = mel.create_material_expression(diamond, unreal.MaterialExpressionVertexInterpolator, -1800, -250)
wire(rest, "", rest_ps, "")
view = mel.create_material_expression(diamond, unreal.MaterialExpressionCameraVectorWS, -1500, 300)
vnorm = mel.create_material_expression(diamond, unreal.MaterialExpressionVertexNormalWS, -1500, -500)
clock = mel.create_material_expression(diamond, unreal.MaterialExpressionTime, -1500, 400)

F = hlsl(diamond, "Facet: tilt in RGB, id in A", FLOAT4,
         {"Tex": (sheet, ""), "P": (rest_ps, ""), "Scale": knob("FacetScale", -1800, -150)}, """
float3 G = abs(cross(ddx(P), ddy(P)));
float2 uv = (G.z >= G.x && G.z >= G.y) ? P.xy : (G.y >= G.x ? P.xz + 0.37 / Scale : P.yz + 0.71 / Scale);
return Texture2DSampleLevel(Tex, TexSampler, uv * Scale, 0);
""", -1200, -400)
N = hlsl(diamond, "Tilted normal", FLOAT3, {"VN": (vnorm, ""), "F": (F, ""), "Tilt": knob("Tilt", -1200, -560)},
         "return normalize(VN + (F.rgb * 2 - 1) * Tilt);", -850, -500)
RB = hlsl(diamond, "Rainbow, by shard and view", FLOAT3,
          {"F": (F, ""), "V": (view, ""), "T": (clock, ""), "IdSpread": knob("IdSpread", -1200, -200),
           "ViewSpread": knob("ViewSpread", -1200, -120), "Drift": knob("Drift", -1200, -40)}, """
float phase = F.a * IdSpread + dot(F.rgb * 2 - 1, V) * ViewSpread + T * Drift;
return 0.5 + 0.5 * cos(6.28318 * (phase + float3(0, 0.33, 0.67)));
""", -850, -200)
BASE = hlsl(diamond, "Base colour", FLOAT3,
            {"F": (F, ""), "RB": (RB, ""), "K": (k, ""), "Ice": (colour(diamond, "Ice", LOOK["Ice"], -850, 0), ""),
             "Iris": knob("Iris", -850, 160), "LitLow": knob("LitLow", -850, 240),
             "DarkShade": knob("DarkShade", -850, 320)}, """
float lit = lerp(LitLow, 1, pow(frac(F.a * 7.13), 0.35));
float iris = saturate(Iris * (frac(F.a * 3.7) > 0.72 ? 1.0 : 0.15));
return lerp(Ice.rgb, 0.45 + 0.55 * RB, iris) * lit * lerp(DarkShade, 1, K);
""", -500, -100)
EMIT = hlsl(diamond, "Glow and glints", FLOAT3,
            {"BASE": (BASE, ""), "RB": (RB, ""), "F": (F, ""), "N": (N, ""), "V": (view, ""), "T": (clock, ""),
             "K": (k, ""), "Glow": knob("Glow", -500, 200), "Gain": knob("SparkGain", -500, 280),
             "Power": knob("SparkPower", -500, 360), "Wobble": knob("Wobble", -500, 440)}, """
float a = T * Wobble + F.a * 6.28318;
float3 R = reflect(-V, N);
float s = pow(saturate(dot(R, normalize(float3(cos(a) * 0.25, sin(a) * 0.25, 1)))), Power)
        + pow(saturate(dot(N, V)), Power * 2);
float pick = frac(F.a * 13.7) > 0.68 ? 1 : 0;
return BASE * Glow + (0.4 + 0.6 * RB) * s * pick * Gain * (0.25 + 0.75 * K);
""", -150, 200)
for src, prop in ((BASE, MP.MP_BASE_COLOR), (knob("Metallic", -150, 0)[0], MP.MP_METALLIC),
                  (knob("Roughness", -150, 80)[0], MP.MP_ROUGHNESS), (N, MP.MP_NORMAL), (EMIT, MP.MP_EMISSIVE_COLOR)):
    if not mel.connect_material_property(src, "", prop):
        raise RuntimeError("could not connect %s" % prop)
diamond.set_editor_property("tangent_space_normal", False)   # the Normal above is in world space
diamond.set_editor_property("used_with_skeletal_mesh", True)   # the gun is a skeletal mesh
mel.recompile_material(diamond)
lib.save_loaded_asset(diamond)


# --- the item -------------------------------------------------------------------------------------------------------
# Stubs at the game's exact paths (cooked, kept out of the pak: build-armory.ps1 packs Mods/<Mod> only); the game
# resolves each import to its real class or asset. Every stub default differs from the item's value, so the versioned
# (tagged) cook writes every value and nothing falls back to the real class's defaults.
def stub_blueprint(folder, name, parent):
    if lib.does_asset_exist(folder + "/" + name):
        lib.delete_asset(folder + "/" + name)
    f = unreal.BlueprintFactory()
    f.set_editor_property("parent_class", parent)
    bp = tools.create_asset(name, folder, unreal.Blueprint, f)
    bel.compile_blueprint(bp)
    lib.save_loaded_asset(bp)
    return bp


def tag(name):
    t = unreal.GameplayTag()
    t.import_text('(TagName="%s")' % name)
    if str(t.export_text()).find(name) < 0:
        raise RuntimeError("gameplay tag %s did not take (%s)" % (name, t.export_text()))
    return t


def tags(*names):
    c = unreal.GameplayTagContainer()
    c.import_text("(GameplayTags=(%s))" % ",".join('(TagName="%s")' % n for n in names))
    for n in names:
        if str(c.export_text()).find(n) < 0:
            raise RuntimeError("tag container lost %s (%s)" % (n, c.export_text()))
    return c


NAMED = "/Game/Inventory/Items/Pickups/Attachments/Named/ColonelsRevenge"
LOCAL = "/Game/Inventory/Items/LocalAttachments/Mags"
pickup_cls = bel.generated_class(stub_blueprint(NAMED, "BP_ColonelsRevengeDrumMagPickup", unreal.Actor))
local_cls = bel.generated_class(stub_blueprint(LOCAL, "BP_ColonelsRevengeDrumMagLocalAttachment", unreal.Actor))

item_bp = stub_blueprint("/Game/JigSInventory/Jigsaw/Data/DataAsset", "JigsawItem_DataAsset", unreal.PrimaryDataAsset)
T = bel.get_basic_type_by_name
S = lambda s: bel.get_struct_type(s.static_struct())   # noqa: E731
TAG, TAGS, V2, XF = S(unreal.GameplayTag), S(unreal.GameplayTagContainer), S(unreal.Vector2D), S(unreal.Transform)
ODD_TAG, ODD_TAGS = tag("Jig.Rarity.Named"), tags("Jig.ItemType.WeaponAttachment")
DESC = ("Two drums, one feed tower: 200 rounds of 5.56 for the Colonel's Revenge. "
        "Matte black with polished platinum trim. Heavy, slow to load, and it does not stop.")
# name, pin type, stub default (never the item's value), the item's value; values follow the game's
# DA_ColonelsRevengeDrumMag (kit dump 2026-11-02) except capacity, size, weight, price and the look
ITEM = [
    ("ItemId", T("name"), "Stub", "ColonelsRevengeDoubleDrumMag"),
    ("Name", T("text"), unreal.Text("Stub"), unreal.Text("Colonel's Revenge Double Drum Magazine")),
    ("Description", T("text"), unreal.Text("Stub"), unreal.Text(DESC)),
    ("SlotDimensions", V2, unreal.Vector2D(9, 9), unreal.Vector2D(3, 2)),
    ("ItemType", TAG, ODD_TAG, tag("Jig.ItemType.WeaponAttachment")),
    ("Rarity", TAG, tag("Jig.AttachmentType.Mag"), tag("Jig.Rarity.Named")),
    ("LootType", T("byte"), 0, 18),
    ("Count", T("int"), 7, 1),
    ("CanStack?", T("bool"), True, False),
    ("MaxStack", T("int"), 99, 1),
    ("Weight", T("real"), -1.0, 2.2),
    ("Price", T("real"), -1.0, 240.0),
    ("PickupClass", bel.get_class_reference_type(unreal.Actor), None, pickup_cls),
    ("IsContainer?", T("bool"), False, True),
    ("IsLoader?", T("bool"), True, False),
    ("ContainerCapacity", T("int"), -1, 200),
    ("SupportsAttachments?", T("bool"), True, False),
    ("ContainerDimensions", bel.get_array_type(V2), [], [unreal.Vector2D(2, 2)]),
    ("ContainerSupportedItems", TAGS, ODD_TAGS, tags("Jig.ItemType.Ammunition")),
    ("ContainerOnlySupportedIDs", bel.get_array_type(bel.get_object_reference_type(unreal.PrimaryDataAsset)), [], None),  # set below
    ("OpenContainerOnDoubleClick?", T("bool"), True, False),
    ("AddSpecialContainerToInspector", T("bool"), True, False),
    ("ContextMenuOptions", TAGS, ODD_TAGS, tags("Jig.Context.Inspect", "Jig.Context.Drop", "Jig.Context.Unload")),
    ("StaticMeshToInspect", bel.get_object_reference_type(unreal.StaticMesh), None, mesh),
    # the icon (BP_ItemSnapCaptor renders StaticMeshToInspect): front three-quarter, both drums and a window in view
    ("InspectTransform", XF, unreal.Transform(unreal.Vector(9, 9, 9), unreal.Rotator(0, 0, 0), unreal.Vector(9, 9, 9)),
     unreal.Transform(unreal.Vector(0, 0, 0), unreal.Rotator(roll=0.0, pitch=0.0, yaw=-150.0), unreal.Vector(1, 1, 1))),
    ("FOV", T("real"), -1.0, 9.0),
    ("MaxZoomIn", T("real"), -1.0, 1.0),
    ("MaxZoomOut", T("real"), -1.0, 100.0),
    ("UseAsInventoryImage?", T("bool"), False, True),
    ("ShareSnapWithSimilarItems?", T("bool"), True, False),   # its own icon, never the game drum's
    ("ActionbarAngle", T("real"), 1.0, -45.0),
    ("ActionbarScale", T("real"), -1.0, 2.0),
    ("Local_AttachSocket", T("name"), "Stub", "CRDrumMag"),
    ("Local_AttachmentType", TAG, ODD_TAG, tag("Jig.AttachmentType.Mag")),
    ("Local_ActorClass", bel.get_class_reference_type(unreal.Actor), None, local_cls),
    ("ShowEquippedContentByDefault?", T("bool"), False, True),
    ("CanBeDisassembled?", T("bool"), True, False),
]
STUB_VARS = [(n, pin, stub) for n, pin, stub, _ in ITEM]
for name, pin, _ in STUB_VARS:
    if not bel.add_member_variable(item_bp, name, pin):
        raise RuntimeError("item stub variable " + name)
bel.compile_blueprint(item_bp)
item_cls = bel.generated_class(item_bp)
stub_cdo = unreal.get_default_object(item_cls)
for name, _, stub in STUB_VARS:
    if stub is not None:
        stub_cdo.set_editor_property(name, stub)
lib.save_loaded_asset(item_bp)

# the one ammo the magazine takes: a stub of the game's DA_556Ammo at its path (not packed; the game has the real one)
daf = unreal.DataAssetFactory()
daf.set_editor_property("data_asset_class", item_cls)
AMMO_DIR = "/Game/Inventory/Items/DataAssets/Attachments/Ammo"
if lib.does_asset_exist(AMMO_DIR + "/DA_556Ammo"):
    lib.delete_asset(AMMO_DIR + "/DA_556Ammo")
ammo = tools.create_asset("DA_556Ammo", AMMO_DIR, item_cls, daf)
lib.save_loaded_asset(ammo)

item = tools.create_asset("DA_CRDoubleDrumMag", DEST, item_cls, daf)
for name, _, _, value in ITEM:
    item.set_editor_property(name, [ammo] if name == "ContainerOnlySupportedIDs" else value)
lib.save_loaded_asset(item)
for name, _, stub, _ in ITEM:
    v, s = item.get_editor_property(name), stub_cdo.get_editor_property(name)
    if hasattr(v, "export_text"):
        v, s = v.export_text(), s.export_text()
    unreal.log("ARMORY item %s = %s (stub %s)" % (name, v, s))
    if str(v) == str(s):
        raise RuntimeError("item value %s equals the stub default: it would not be written" % name)

# --- the mod actor --------------------------------------------------------------------------------------------------
factory = unreal.BlueprintFactory()
factory.set_editor_property("parent_class", unreal.Actor)
bp = tools.create_asset("ModActor", DEST, unreal.Blueprint, factory)
sub = unreal.get_engine_subsystem(unreal.SubobjectDataSubsystem)
root = sub.k2_gather_subobject_data_for_blueprint(bp)[0]
handle, fail = sub.add_new_subobject(unreal.AddNewSubobjectParams(parent_handle=root, new_class=unreal.StaticMeshComponent,
                                                                  blueprint_context=bp))
if not fail.is_empty():
    raise RuntimeError("mesh component: %s" % fail)
sub.rename_subobject(handle, unreal.Text("DoubleDrum"))
comp = unreal.SubobjectDataBlueprintFunctionLibrary.get_object(unreal.SubobjectDataBlueprintFunctionLibrary.get_data(handle))
comp.set_editor_property("static_mesh", mesh)
comp.set_editor_property("visible", False)
comp.set_editor_property("hidden_in_game", True)
comp.set_collision_enabled(unreal.CollisionEnabled.NO_COLLISION)
HELD = (("DoubleDrumMag", unreal.PrimaryDataAsset, item), ("DiamondFinish", unreal.MaterialInterface, diamond))
for var, ty, _ in HELD:
    if not bel.add_member_variable(bp, var, bel.get_object_reference_type(ty)):
        raise RuntimeError("mod actor variable " + var)
bel.compile_blueprint(bp)
cdo = unreal.get_default_object(bel.generated_class(bp))
for var, _, value in HELD:
    cdo.set_editor_property(var, value)
lib.save_loaded_asset(bp)
unreal.log("ARMORY mod actor holds %s" % [str(cdo.get_editor_property(v)) for v, _, _ in HELD])


# --- the hover bike (mirror/hoverbike.lua; SD_HoverBike\Export, user 2026-11-03) -------------------------------------
# Not on the mod actor: only a game with a bike loads these, so a sequence that won't load against the game's skeleton
# can't take every level load with it.
BIKE = os.environ.get("SD_HOVERBIKE_EXPORT", r"C:\Users\arkis\Desktop\Modding\Projects\SD_HoverBike\Export")
BIKE_TOL = 0.1    # cm, the import's bounds against hoverbike_spec.json
GLOW = 5.0        # the spec's emission strength (5 orange and red, 6 white)
BONES = 67        # /Game/Character/BaseRig/BaseRig_Skeleton


def bike_material(name, base, orm, glow=None):
    m = tools.create_asset(name, DEST, unreal.Material, unreal.MaterialFactoryNew())
    bc = mel.create_material_expression(m, unreal.MaterialExpressionTextureSample, -600, 0)
    bc.set_editor_property("texture", base)
    bc.set_editor_property("sampler_type", unreal.MaterialSamplerType.SAMPLERTYPE_COLOR)
    mel.connect_material_property(bc, "RGB", MP.MP_BASE_COLOR)
    o = mel.create_material_expression(m, unreal.MaterialExpressionTextureSample, -600, 300)
    o.set_editor_property("texture", orm)
    o.set_editor_property("sampler_type", unreal.MaterialSamplerType.SAMPLERTYPE_LINEAR_COLOR)
    mel.connect_material_property(o, "R", MP.MP_AMBIENT_OCCLUSION)
    mel.connect_material_property(o, "G", MP.MP_ROUGHNESS)
    mel.connect_material_property(o, "B", MP.MP_METALLIC)
    if glow is not None:
        k = mel.create_material_expression(m, unreal.MaterialExpressionConstant, -450, -200)
        k.set_editor_property("r", glow)
        x = mel.create_material_expression(m, unreal.MaterialExpressionMultiply, -300, -150)
        mel.connect_material_expressions(bc, "RGB", x, "A")
        mel.connect_material_expressions(k, "", x, "B")
        mel.connect_material_property(x, "", MP.MP_EMISSIVE_COLOR)
    m.set_editor_property("used_with_skeletal_mesh", True)   # or the game draws its default grey material on the bike
    mel.recompile_material(m)
    lib.save_loaded_asset(m)
    return m


def skeletal_ui():
    ui = unreal.FbxImportUI()
    ui.set_editor_property("import_mesh", True)
    ui.set_editor_property("import_as_skeletal", True)
    ui.set_editor_property("mesh_type_to_import", unreal.FBXImportType.FBXIT_SKELETAL_MESH)
    ui.set_editor_property("automated_import_should_detect_type", False)
    ui.set_editor_property("import_materials", False)
    ui.set_editor_property("import_textures", False)
    ui.set_editor_property("import_animations", False)
    ui.set_editor_property("create_physics_asset", False)
    skd = ui.get_editor_property("skeletal_mesh_import_data")
    skd.set_editor_property("convert_scene", True)
    skd.set_editor_property("import_uniform_scale", 1.0)
    skd.set_editor_property("import_morph_targets", False)
    return ui


def import_with(path, folder, name, ui):
    t = unreal.AssetImportTask()
    t.filename = path
    t.destination_path = folder
    t.destination_name = name
    t.automated = True
    t.replace_existing = True
    t.save = True
    t.options = ui
    tools.import_asset_tasks([t])


def import_bike():
    with open(os.path.join(BIKE, "hoverbike_spec.json"), "r") as f:
        spec = json.load(f)
    base = palette_texture(os.path.join(BIKE, "T_HoverBike_BaseColor.png"), "T_HoverBike_BaseColor")
    orm = palette_texture(os.path.join(BIKE, "T_HoverBike_ORM.png"), "T_HoverBike_ORM", srgb=False)
    mats = {"M_HoverBike": bike_material("M_HoverBike", base, orm),
            "M_HoverBike_Props": bike_material("M_HoverBike_Props", base, orm),
            "M_HoverBike_Glow": bike_material("M_HoverBike_Glow", base, orm, GLOW)}
    import_with(os.path.join(BIKE, "SK_HoverBike.fbx"), DEST, "SK_HoverBike", skeletal_ui())
    sk = lib.load_asset(DEST + "/SK_HoverBike")
    if not isinstance(sk, unreal.SkeletalMesh):
        raise RuntimeError("SK_HoverBike.fbx gave no skeletal mesh (%s)" % lib.list_assets(DEST, recursive=True))
    b = sk.get_bounds()
    o, e = b.origin, b.box_extent
    got = [o.x - e.x, o.y - e.y, o.z - e.z, o.x + e.x, o.y + e.y, o.z + e.z]
    want = spec["mesh"]["bounds_ue_cm"]["min"] + spec["mesh"]["bounds_ue_cm"]["max"]
    unreal.log("ARMORY bounds SK_HoverBike %s (spec %s)" % (["%.3f" % v for v in got], want))
    if any(abs(g - w) > BIKE_TOL for g, w in zip(got, want)):
        raise RuntimeError("SK_HoverBike's bounds %s are not the spec's %s: turned, mirrored or scaled" % (got, want))
    slots = sk.get_editor_property("materials")
    names = [str(s.get_editor_property("material_slot_name")) for s in slots]
    unreal.log("ARMORY material slots SK_HoverBike %s" % names)
    if sorted(names) != sorted(mats):
        raise RuntimeError("SK_HoverBike's slots %s are not the spec's %s" % (names, sorted(mats)))
    for s in slots:
        s.set_editor_property("material_interface", mats[str(s.get_editor_property("material_slot_name"))])
    sk.set_editor_property("materials", slots)
    lib.save_loaded_asset(sk)


def import_rider():
    # a stand-in at the game's exact path, so the sequences reference the game's skeleton; it stays out of the pak
    # (build-armory.ps1 packs Content/Mods/SurrounSyncArmory only), as HANDOFF_Rider.md plans
    rider = os.path.join(BIKE, "Rider")
    import_with(os.path.join(rider, "BaseRig_Skeleton_stub.fbx"), CHAR_DIR, "BaseRig", skeletal_ui())
    skel = lib.load_asset(CHAR_DIR + "/BaseRig_Skeleton")
    if not isinstance(skel, unreal.Skeleton):
        raise RuntimeError("no stub skeleton (%s)" % lib.list_assets(CHAR_DIR, recursive=True))
    pose = unreal.AnimPoseExtensions.get_reference_pose(skel)
    bones = [str(n) for n in unreal.AnimPoseExtensions.get_bone_names(pose)]
    unreal.log("ARMORY stub skeleton bones %d: %s" % (len(bones), bones))
    if len(bones) != BONES:
        raise RuntimeError("the stub skeleton has %d bones, the game's %d" % (len(bones), BONES))
    # cooked tracks are matched to the skeleton's bone list, so the order must be the game's (read from its cooked asset)
    ref = os.path.join(os.path.dirname(BIKE), "rider", "baserig_skel.json")
    with open(ref, "r") as f:
        game_bones = [b["name"] for b in json.load(f)]
    if bones != game_bones:
        raise RuntimeError("the stub's bone order is not the game's: %s" % [
            (i, a, b) for i, (a, b) in enumerate(zip(bones, game_bones)) if a != b][:8])
    unreal.log("ARMORY stub bone order matches the game's skeleton (%d)" % len(bones))
    for name in ("A_Rider_Sit", "A_Rider_Drive"):
        ui = unreal.FbxImportUI()
        ui.set_editor_property("import_mesh", False)
        ui.set_editor_property("import_as_skeletal", True)
        ui.set_editor_property("import_animations", True)
        ui.set_editor_property("mesh_type_to_import", unreal.FBXImportType.FBXIT_ANIMATION)
        ui.set_editor_property("automated_import_should_detect_type", False)
        ui.set_editor_property("import_materials", False)
        ui.set_editor_property("import_textures", False)
        ui.set_editor_property("create_physics_asset", False)
        ui.set_editor_property("skeleton", skel)
        ad = ui.get_editor_property("anim_sequence_import_data")
        ad.set_editor_property("convert_scene", True)
        ad.set_editor_property("import_uniform_scale", 1.0)
        ad.set_editor_property("animation_length", unreal.FBXAnimationLengthImportType.FBXALIT_EXPORTED_TIME)
        import_with(os.path.join(rider, name + ".fbx"), DEST, name, ui)
        # (the importer may add the take's name)
        found = [a for a in lib.list_assets(DEST, recursive=False) if a.rsplit("/", 1)[-1].split(".")[0].startswith(name)]
        if not found:
            raise RuntimeError(name + " did not import (%s)" % lib.list_assets(DEST, recursive=True))
        at = found[0].split(".")[0]
        if at != DEST + "/" + name:
            unreal.log("ARMORY %s came in as %s" % (name, at))
            if not lib.rename_asset(at, DEST + "/" + name):
                raise RuntimeError("couldn't name " + at)
        seq = lib.load_asset(DEST + "/" + name)
        if not isinstance(seq, unreal.AnimSequence):
            raise RuntimeError(name + " is no animation sequence: " + str(seq))
        unreal.log("ARMORY %s: %.3f s, skeleton %s" % (name, seq.get_play_length(), seq.get_editor_property("skeleton").get_path_name()))
        lib.save_loaded_asset(seq)


# the bike's sounds (make_bike_sounds.py), played by hoverbike.lua: uncompressed, since the motors' pitch moves all the time,
# and on one attenuation as FPVDrone's, for something bigger: 2D within 4 m (the rider's chase camera is near 6 m behind, and
# all round it), fading from 8 m to gone at 158 m.
def import_bike_sounds():
    att = tools.create_asset("BikeAttenuation", DEST, unreal.SoundAttenuation, unreal.SoundAttenuationFactory())
    s = att.get_editor_property("attenuation")
    s.set_editor_property("attenuate", True)
    s.set_editor_property("attenuation_shape", unreal.AttenuationShape.SPHERE)
    s.set_editor_property("attenuation_shape_extents", unreal.Vector(800.0, 0.0, 0.0))
    s.set_editor_property("falloff_distance", 15000.0)
    s.set_editor_property("distance_algorithm", unreal.AttenuationDistanceModel.NATURAL_SOUND)
    s.set_editor_property("spatialize", True)
    s.set_editor_property("non_spatialized_radius_start", 800.0)
    s.set_editor_property("non_spatialized_radius_end", 400.0)
    att.set_editor_property("attenuation", s)
    lib.save_loaded_asset(att)
    for name in ("BikeMotor", "BikeWind"):
        import_file(os.path.join(OUT, "wav", name + ".wav"), DEST, name)
        w = lib.load_asset(DEST + "/" + name)
        w.set_editor_property("looping", True)
        w.set_editor_property("attenuation_settings", att)
        w.set_sound_asset_compression_type(unreal.SoundAssetCompressionType.PCM)
        lib.save_loaded_asset(w)
        unreal.log("ARMORY sound %s looping %s, %.2f s, %s" % (name, w.get_editor_property("looping"),
                                                               w.get_editor_property("duration"),
                                                               w.get_sound_asset_compression_type()))


import_bike()
import_rider()
import_bike_sounds()

box = mesh.get_bounding_box()
unreal.log("ARMORY %s bounds min %s max %s" % (mesh.get_name(), box.min, box.max))
unreal.log("ARMORY assets %s" % lib.list_assets(DEST, recursive=True))
unreal.log("SURROUNSYNC_ARMORY_OK")
