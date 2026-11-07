# UE 5.6 editor script: import out/Glider.gltf (make_glider.py) as SM_Glider with its palette material M_Glider,
# and make the LogicMods mod actor that holds it. BPModLoader spawns /Game/Mods/<Mod>/ModActor from
# Paks/LogicMods/<Mod>.pak at every level load; its hidden mesh component hard-references SM_Glider, so the engine
# loads it and Lua finds it (SurrounSync never loads assets from Lua). Also the Hang Glider item, DA_HangGlider (below).
import os
import unreal

MOD = "SurrounSyncGlider"
DEST = "/Game/Mods/" + MOD
SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out", "Glider.gltf")

tools = unreal.AssetToolsHelpers.get_asset_tools()
lib = unreal.EditorAssetLibrary
mel = unreal.MaterialEditingLibrary

if lib.does_directory_exist(DEST):
    lib.delete_directory(DEST)
lib.make_directory(DEST)

t = unreal.AssetImportTask()
t.filename = SRC
t.destination_path = DEST + "/Import"
t.automated = True
t.replace_existing = True
t.save = True
tools.import_asset_tasks([t])

mesh = None
for p in lib.list_assets(DEST + "/Import", recursive=True):
    a = lib.load_asset(p)
    unreal.log("GLIDER imported " + p + " " + a.get_class().get_name())
    if isinstance(a, unreal.StaticMesh):
        mesh = a
if mesh is None:
    raise RuntimeError("no static mesh came out of " + SRC)
lib.rename_asset(mesh.get_path_name().split(".")[0], DEST + "/SM_Glider")
mesh = lib.load_asset(DEST + "/SM_Glider")

# Palette texture (make_glider.py): one swatch per colour, alpha = metal. Nearest filter and no mips, so a face never
# picks up a neighbouring swatch; alpha stays linear data next to the sRGB colour.
pt = unreal.AssetImportTask()
pt.filename = os.path.join(os.path.dirname(SRC), "Palette.png")
pt.destination_path = DEST
pt.destination_name = "T_GliderPalette"
pt.automated = True
pt.replace_existing = True
pt.save = False
tools.import_asset_tasks([pt])
tex = lib.load_asset(DEST + "/T_GliderPalette")
if tex is None:
    raise RuntimeError("palette texture did not import")
tex.set_editor_property("filter", unreal.TextureFilter.TF_NEAREST)
tex.set_editor_property("mip_gen_settings", unreal.TextureMipGenSettings.TMGS_NO_MIPMAPS)
tex.set_editor_property("srgb", True)
tex.set_editor_property("compression_settings", unreal.TextureCompressionSettings.TC_EDITOR_ICON)   # uncompressed BGRA8
tex.set_editor_property("never_stream", True)
lib.save_loaded_asset(tex)

# Material: colour from the palette, alpha = metal (frame) or not (cloth, tape); metal is smoother.
mat = tools.create_asset("M_Glider", DEST, unreal.Material, unreal.MaterialFactoryNew())
vc = mel.create_material_expression(mat, unreal.MaterialExpressionTextureSample, -700, 0)
vc.set_editor_property("texture", tex)
vc.set_editor_property("sampler_type", unreal.MaterialSamplerType.SAMPLERTYPE_COLOR)
rough = mel.create_material_expression(mat, unreal.MaterialExpressionLinearInterpolate, -300, 200)
cloth = mel.create_material_expression(mat, unreal.MaterialExpressionConstant, -500, 160)
cloth.set_editor_property("r", 0.85)
metal = mel.create_material_expression(mat, unreal.MaterialExpressionConstant, -500, 260)
metal.set_editor_property("r", 0.32)
mel.connect_material_property(vc, "RGB", unreal.MaterialProperty.MP_BASE_COLOR)
mel.connect_material_property(vc, "A", unreal.MaterialProperty.MP_METALLIC)
mel.connect_material_expressions(cloth, "", rough, "A")
mel.connect_material_expressions(metal, "", rough, "B")
mel.connect_material_expressions(vc, "A", rough, "Alpha")
mel.connect_material_property(rough, "", unreal.MaterialProperty.MP_ROUGHNESS)
mel.recompile_material(mat)
lib.save_loaded_asset(mat)

mesh.set_material(0, mat)
try:
    unreal.EditorStaticMeshLibrary.remove_collisions(mesh)   # carried, never something to stand on
except Exception as e:
    unreal.log_warning("GLIDER remove_collisions: %s" % e)
lib.save_loaded_asset(mesh)

# whatever else the import made (material instances of the importer's own materials) must not go into the pak
lib.delete_directory(DEST + "/Import")

# The Hang Glider item (user 2026-11-02): DA_HangGlider, an instance of the game's item class
# /Game/JigSInventory/Jigsaw/Data/DataAsset/JigsawItem_DataAsset_C. This project has no game classes, so a stub
# Blueprint stands at that exact path with only the variables the item sets; the stubs are cooked but stay out of the
# pak (build-glider.ps1 packs Mods/<Mod> only), and the game resolves the import to its real class. The cook is
# versioned (tagged properties), so the game reads the item's values by name, whatever the stub's layout.
# A tagged property is written only where it differs from the stub's default: the stub defaults are odd values no
# item uses, so every value below is written and nothing falls back to the real class's defaults
# (Sentinel R11: the real CDO has CanBeDisassembled? true, Weight 1, Price 5).
ITEM_CLASS_DIR = "/Game/JigSInventory/Jigsaw/Data/DataAsset"
PICKUP_DIR = "/Game/Inventory/Items/Pickups/Other/Junk"   # a dropped glider shows the fire extinguisher's pickup
bel = unreal.BlueprintEditorLibrary


def stub_blueprint(folder, name, parent):
    if lib.does_asset_exist(folder + "/" + name):
        lib.delete_asset(folder + "/" + name)
    f = unreal.BlueprintFactory()
    f.set_editor_property("parent_class", parent)
    return tools.create_asset(name, folder, unreal.Blueprint, f)


pickup_bp = stub_blueprint(PICKUP_DIR, "BP_FireExtinguisherPickup", unreal.Actor)
bel.compile_blueprint(pickup_bp)
lib.save_loaded_asset(pickup_bp)
pickup_cls = bel.generated_class(pickup_bp)

item_bp = stub_blueprint(ITEM_CLASS_DIR, "JigsawItem_DataAsset", unreal.PrimaryDataAsset)
# name, pin type, stub default (never an item's value), the glider's value
ITEM = [
    ("ItemId", bel.get_basic_type_by_name("name"), "Stub", "HangGlider"),
    ("Name", bel.get_basic_type_by_name("text"), unreal.Text("Stub"), unreal.Text("Hang Glider")),
    ("Description", bel.get_basic_type_by_name("text"), unreal.Text("Stub"),
     unreal.Text("A folded hang glider. Jump in the air with a 5 m drop below to open it; Jump again to let go.")),
    # 2x2 (user 2026-11-02: "Make it a 2x2 grid item so the icon fits better")
    ("SlotDimensions", bel.get_struct_type(unreal.Vector2D.static_struct()), unreal.Vector2D(9, 9), unreal.Vector2D(2, 2)),
    ("CanStack?", bel.get_basic_type_by_name("bool"), True, False),
    ("MaxStack", bel.get_basic_type_by_name("int"), 99, 1),
    ("Weight", bel.get_basic_type_by_name("real"), -1.0, 4.0),
    ("Price", bel.get_basic_type_by_name("real"), -1.0, 120.0),
    ("PickupClass", bel.get_class_reference_type(unreal.Actor), None, pickup_cls),
    ("StaticMeshToInspect", bel.get_object_reference_type(unreal.StaticMesh), None, mesh),
    # the icon (BP_ItemSnapCaptor: camera 200 cm off, FOV below): the sail tilted 70 deg toward the camera, centred;
    # tuned live in the kit 2026-11-02 (FOV 30 / pitch -20 rendered the wing edge-on and tiny)
    ("InspectTransform", bel.get_struct_type(unreal.Transform.static_struct()),
     unreal.Transform(unreal.Vector(9, 9, 9), unreal.Rotator(0, 0, 0), unreal.Vector(9, 9, 9)),
     unreal.Transform(unreal.Vector(0, 0, -4), unreal.Rotator(roll=0.0, pitch=70.0, yaw=0.0), unreal.Vector(0.1, 0.1, 0.1))),
    ("FOV", bel.get_basic_type_by_name("real"), -1.0, 14.0),
    ("UseAsInventoryImage?", bel.get_basic_type_by_name("bool"), False, True),
    ("CanBeDisassembled?", bel.get_basic_type_by_name("bool"), True, False),
]
for name, pin, _, _ in ITEM:
    if not bel.add_member_variable(item_bp, name, pin):
        raise RuntimeError("item stub variable " + name)
bel.compile_blueprint(item_bp)
item_cls = bel.generated_class(item_bp)
stub_cdo = unreal.get_default_object(item_cls)
for name, _, stub, _ in ITEM:
    if stub is not None:
        stub_cdo.set_editor_property(name, stub)
lib.save_loaded_asset(item_bp)

daf = unreal.DataAssetFactory()
daf.set_editor_property("data_asset_class", item_cls)
item = tools.create_asset("DA_HangGlider", DEST, item_cls, daf)
for name, _, _, value in ITEM:
    item.set_editor_property(name, value)
lib.save_loaded_asset(item)
for name, _, stub, value in ITEM:
    unreal.log("GLIDER item %s = %s (stub %s)" % (name, item.get_editor_property(name), stub_cdo.get_editor_property(name)))

bp_path = DEST + "/ModActor"
factory = unreal.BlueprintFactory()
factory.set_editor_property("parent_class", unreal.Actor)
bp = tools.create_asset("ModActor", DEST, unreal.Blueprint, factory)
sub = unreal.get_engine_subsystem(unreal.SubobjectDataSubsystem)
root = sub.k2_gather_subobject_data_for_blueprint(bp)[0]
params = unreal.AddNewSubobjectParams(parent_handle=root, new_class=unreal.StaticMeshComponent, blueprint_context=bp)
handle, fail = sub.add_new_subobject(params)
if not fail.is_empty():
    raise RuntimeError("mesh component: %s" % fail)
sub.rename_subobject(handle, unreal.Text("Glider"))
comp = unreal.SubobjectDataBlueprintFunctionLibrary.get_object(unreal.SubobjectDataBlueprintFunctionLibrary.get_data(handle))
comp.set_editor_property("static_mesh", mesh)
comp.set_editor_property("visible", False)
comp.set_editor_property("hidden_in_game", True)
comp.set_collision_enabled(unreal.CollisionEnabled.NO_COLLISION)
# the item rides along the same way: a hard reference loads DA_HangGlider with the ModActor
if not bel.add_member_variable(bp, "HangGlider", bel.get_object_reference_type(unreal.PrimaryDataAsset)):
    raise RuntimeError("mod actor variable HangGlider")
unreal.BlueprintEditorLibrary.compile_blueprint(bp)
unreal.get_default_object(bel.generated_class(bp)).set_editor_property("HangGlider", item)
lib.save_loaded_asset(bp)
unreal.log("GLIDER mod actor holds %s" % unreal.get_default_object(bel.generated_class(bp)).get_editor_property("HangGlider"))

box = mesh.get_bounding_box()
mats = [m.get_path_name() if m else "None" for m in [mesh.get_material(i) for i in range(mesh.get_num_sections(0))]]
deps = unreal.AssetRegistryHelpers.get_asset_registry().get_dependencies(
    DEST + "/SM_Glider", unreal.AssetRegistryDependencyOptions(include_hard_package_references=True))
unreal.log("GLIDER bounds min %s max %s" % (box.min, box.max))
unreal.log("GLIDER materials %s" % mats)
unreal.log("GLIDER mesh depends on %s" % [str(d) for d in (deps or [])])
unreal.log("GLIDER assets %s" % lib.list_assets(DEST, recursive=True))
unreal.log("SURROUNSYNC_GLIDER_OK")
