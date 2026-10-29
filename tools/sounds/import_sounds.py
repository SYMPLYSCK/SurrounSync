# UE 5.6 editor script: import the dog sounds and make the LogicMods mod actor that holds them.
# BPModLoader spawns /Game/Mods/<Mod>/ModActor from Paks/LogicMods/<Mod>.pak at every level load; its inactive
# AudioComponents hard-reference the sounds, so the engine loads them (SurrounSync never loads assets from Lua).
import os
import unreal

MOD = "SurrounSyncSounds"
DEST = "/Game/Mods/" + MOD
WAVS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "wav")
NAMES = ["DogBark1", "DogBark2", "DogGrowl", "DogBarking"]

tools = unreal.AssetToolsHelpers.get_asset_tools()
lib = unreal.EditorAssetLibrary

tasks = []
for n in NAMES:
    t = unreal.AssetImportTask()
    t.filename = os.path.join(WAVS, n + ".wav")
    t.destination_path = DEST
    t.destination_name = n
    t.automated = True
    t.replace_existing = True
    t.save = True
    tasks.append(t)
tools.import_asset_tasks(tasks)

# distance falloff like a loud animal: full to 4 m, gone at 45 m
att_path = DEST + "/DogAttenuation"
if lib.does_asset_exist(att_path):
    lib.delete_asset(att_path)
att = tools.create_asset("DogAttenuation", DEST, unreal.SoundAttenuation, unreal.SoundAttenuationFactory())
s = att.get_editor_property("attenuation")
s.set_editor_property("attenuation_shape", unreal.AttenuationShape.SPHERE)
s.set_editor_property("attenuation_shape_extents", unreal.Vector(400.0, 0.0, 0.0))
s.set_editor_property("falloff_distance", 4100.0)
s.set_editor_property("spatialize", True)
att.set_editor_property("attenuation", s)
lib.save_loaded_asset(att)

waves = []
for n in NAMES:
    w = lib.load_asset(DEST + "/" + n)
    w.set_editor_property("attenuation_settings", att)
    lib.save_loaded_asset(w)
    waves.append(w)

bp_path = DEST + "/ModActor"
if lib.does_asset_exist(bp_path):
    lib.delete_asset(bp_path)
factory = unreal.BlueprintFactory()
factory.set_editor_property("parent_class", unreal.Actor)
bp = tools.create_asset("ModActor", DEST, unreal.Blueprint, factory)

sub = unreal.get_engine_subsystem(unreal.SubobjectDataSubsystem)
root = sub.k2_gather_subobject_data_for_blueprint(bp)[0]
for n, w in zip(NAMES, waves):
    params = unreal.AddNewSubobjectParams(parent_handle=root, new_class=unreal.AudioComponent, blueprint_context=bp)
    handle, fail = sub.add_new_subobject(params)
    if not fail.is_empty():
        raise RuntimeError("component for %s: %s" % (n, fail))
    sub.rename_subobject(handle, unreal.Text(n))
    comp = unreal.SubobjectDataBlueprintFunctionLibrary.get_object(unreal.SubobjectDataBlueprintFunctionLibrary.get_data(handle))
    comp.set_editor_property("sound", w)
    comp.set_editor_property("auto_activate", False)

unreal.BlueprintEditorLibrary.compile_blueprint(bp)
lib.save_loaded_asset(bp)
unreal.log("SURROUNSYNC_SOUNDS_OK " + ", ".join(NAMES))
