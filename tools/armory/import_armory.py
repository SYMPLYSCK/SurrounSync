# UE 5.6 editor script for SurrounSyncArmory.pak (build-armory.ps1): the Colonel's Revenge Double Drum Magazine (user
# 2026-11-02).
#  - SM_CRDoubleDrumMag from out/DoubleDrum.gltf (make_drummag.py) with M_CRDoubleDrumMag: colour from the palette,
#    the palette's alpha is the finish code (lowpoly.py: 0 matte, 0.5 gloss, 1 polished metal).
#  - DA_CRDoubleDrumMag: the item, an instance of the game's item class (stub Blueprint at its exact path, as in
#    tools/glider/import_glider.py), a 200-round 5.56 magazine for the CRDrumMag socket.
#  - ModActor (BPModLoader spawns it at every level load): hard references load all of the above with the pak.
import os
import unreal

MOD = "SurrounSyncArmory"
DEST = "/Game/Mods/" + MOD
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
SRC = os.path.join(OUT, "DoubleDrum.gltf")

tools = unreal.AssetToolsHelpers.get_asset_tools()
lib = unreal.EditorAssetLibrary
mel = unreal.MaterialEditingLibrary
bel = unreal.BlueprintEditorLibrary
MP = unreal.MaterialProperty

if lib.does_directory_exist(DEST):
    lib.delete_directory(DEST)
lib.make_directory(DEST)


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
HELD = (("DoubleDrumMag", unreal.PrimaryDataAsset, item),)
for var, ty, _ in HELD:
    if not bel.add_member_variable(bp, var, bel.get_object_reference_type(ty)):
        raise RuntimeError("mod actor variable " + var)
bel.compile_blueprint(bp)
cdo = unreal.get_default_object(bel.generated_class(bp))
for var, _, value in HELD:
    cdo.set_editor_property(var, value)
lib.save_loaded_asset(bp)
unreal.log("ARMORY mod actor holds %s" % [str(cdo.get_editor_property(v)) for v, _, _ in HELD])


box = mesh.get_bounding_box()
unreal.log("ARMORY %s bounds min %s max %s" % (mesh.get_name(), box.min, box.max))
unreal.log("ARMORY assets %s" % lib.list_assets(DEST, recursive=True))
unreal.log("SURROUNSYNC_ARMORY_OK")
