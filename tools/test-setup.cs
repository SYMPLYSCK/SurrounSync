// Setup Doctor tests: a fake Steam library + fake %LOCALAPPDATA%\SurrounDead, then Check and the automatic fixes.
// Built and run by tools/test-setup.py (never touches the real game or saves; Steam / verify fixes are not run).
using System;
using System.Collections.Generic;
using System.IO;
using SurrounSyncSetup;

static class SetupTest
{
    static int fails;
    static void Ok(bool c, string what) { Console.WriteLine((c ? "ok   " : "FAIL ") + what); if (!c) fails++; }
    static Finding Find(List<Finding> f, string text)
    {
        foreach (var x in f) if (x.What.Contains(text)) return x;
        return null;
    }
    static void W(string path, string text) { Directory.CreateDirectory(Path.GetDirectoryName(path)); File.WriteAllText(path, text); }

    // one HTTP response on a local port: says Content-Length: length, sends only `send` bytes, then closes
    static string Serve(int length, int send)
    {
        var l = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
        l.Start();
        int port = ((System.Net.IPEndPoint)l.LocalEndpoint).Port;
        new System.Threading.Thread(() =>
        {
            using (var c = l.AcceptTcpClient())
            using (var s = c.GetStream())
            {
                var buf = new byte[4096];
                s.Read(buf, 0, buf.Length);
                var head = System.Text.Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Length: " + length + "\r\nConnection: close\r\n\r\n");
                s.Write(head, 0, head.Length);
                s.Write(new byte[send], 0, send);
            }
            l.Stop();
        }) { IsBackground = true }.Start();
        return "http://127.0.0.1:" + port + "/SurrounSyncSetup.exe";
    }

    static int Main()
    {
        string root = Path.Combine(Path.GetTempPath(), "test-setup-" + Guid.NewGuid().ToString("N").Substring(0, 8));
        string game = Path.Combine(root, "steamapps", "common", "SurrounDead");
        string w64 = Path.Combine(game, "SurrounDead", "Binaries", "Win64");
        W(Path.Combine(w64, "SurrounDead-Win64-Shipping.exe"), "");
        W(Path.Combine(game, "SurrounDead", "Content", "Paks", "SurrounDead-Windows.pak"), "");
        W(Path.Combine(root, "steamapps", "appmanifest_1645820.acf"),
          "\"AppState\"\n{\n\t\"StateFlags\"\t\t\"4\"\n\t\"buildid\"\t\t\"123\"\n\t\"TargetBuildID\"\t\t\"123\"\n\t\"UserConfig\"\n\t{\n\t\t\"BetaKey\"\t\t\"experimental\"\n\t}\n}\n");
        string local = Path.Combine(root, "local", "SurrounDead");
        Doctor.LocalDir = local;
        string saves = Path.Combine(local, "Saved", "SaveGames");
        string ini = Path.Combine(local, "Saved", "Config", "Windows", "EmsUser.ini");
        W(ini, ";METADATA=(Diff=true, UseCommands=true)\r\n[/Script/EasyMultiSave.EMSObject]\r\nCurrentSaveGameName=SurrounSync_Session_3\r\nCurrentSaveUserName=\r\n");
        W(Path.Combine(saves, "QuickSaveOld", "Player.sav"), "a");
        File.SetLastWriteTime(Path.Combine(saves, "QuickSaveOld", "Player.sav"), DateTime.Now.AddDays(-2));
        W(Path.Combine(saves, "QuickSaveNew", "Player.sav"), "b");
        W(Path.Combine(saves, "SurrounSync_Session_3", "Player.sav"), "c");
        W(Path.Combine(saves, "SurrounSync_Session_3_Quests.sav"), "q");
        W(Path.Combine(saves, "SurrounSync_Session_4", "Player.sav"), "d");
        W(Path.Combine(saves, "SurrounSync_Session_4", "SurrounSync-coop.txt"), "marker");
        File.SetAttributes(Path.Combine(saves, "QuickSaveNew", "Player.sav"), FileAttributes.ReadOnly);
        // UE4SS 2 in Win64 + an old multiplayer mod switched on by its enabled.txt in UE4SS 3's Mods
        W(Path.Combine(w64, "UE4SS.dll"), "v2"); W(Path.Combine(w64, "xinput1_3.dll"), "x"); W(Path.Combine(w64, "Mods", "Old", "enabled.txt"), "");
        string mods = Path.Combine(w64, "ue4ss", "Mods");
        W(Path.Combine(w64, "ue4ss", "UE4SS.dll"), "v3"); W(Path.Combine(w64, "dwmapi.dll"), "d");
        W(Path.Combine(mods, "mods.txt"), "SurrounSync : 0\r\n");
        W(Path.Combine(mods, "SurrounDeadMP", "enabled.txt"), "");
        W(Path.Combine(mods, "SurrounSync", "Scripts", "main.lua"), "");
        try
        {
            Ok(Doctor.IsCoopSlot("SurrounSync_Session_3") && Doctor.IsCoopSlot("mirrorcoop_session") && !Doctor.IsCoopSlot("QuickSave1") &&
               !Doctor.IsCoopSlot("SurrounSync_Session_x"), "co-op slot names");
            string v = Doctor.Versions(game);
            Ok(v.Contains("build 123") && v.Contains("experimental") && v.Contains("UE4SS"), "version line: " + v);

            var f = Doctor.Check(game);
            foreach (var x in f) Console.WriteLine("     [" + x.Kind + (x.Fixable ? ",fix" : "") + "] " + x.What);
            var ems = Find(f, "Continue opens a co-op");
            Ok(ems != null && ems.Do != null && ems.Fix.Contains("QuickSaveNew"), "stuck Continue found, points at the newest own save");
            var slot3 = Find(f, "co-op slot SurrounSync_Session_3");
            Ok(slot3 != null && slot3.Do != null, "unmarked co-op slot with progress found");
            Ok(Find(f, "SurrounSync_Session_4") == null, "marked co-op slot left alone");
            var ro = Find(f, "read-only");
            Ok(ro != null && ro.Do != null, "read-only save found");
            var v2 = Find(f, "UE4SS (version 2)");
            Ok(v2 != null && v2.Do != null && v2.Repair, "UE4SS 2 found (move + repair)");
            var mp = Find(f, "SurrounDeadMP switches itself on");
            Ok(mp != null && mp.Do != null, "self-enabled conflict mod found");
            var off = Find(f, "switched off in UE4SS's mods.txt");
            Ok(off != null && off.Repair, "SurrounSync off -> repair");
            Ok(Doctor.FixableCount(f) >= 6, "fixable count " + Doctor.FixableCount(f));

            Action<string> log = s => Console.WriteLine("     > " + s);
            ems.Do(log); slot3.Do(log); ro.Do(log); v2.Do(log); mp.Do(log);
            Ok(Doctor.EmsCurrent() == "QuickSaveNew" && File.ReadAllText(ini).Contains("CurrentSaveUserName=\r\n"), "Continue now QuickSaveNew, rest of the ini kept");
            var rescued = Directory.GetDirectories(Path.Combine(local, "Saved", "SurrounSyncBackups"), "rescued-SurrounSync_Session_3-*");
            Ok(rescued.Length == 1 && File.Exists(Path.Combine(rescued[0], "SurrounSync_Session_3", "Player.sav")) &&
               File.Exists(Path.Combine(rescued[0], "SurrounSync_Session_3_Quests.sav")), "co-op slot backed up with its sidecar");
            Ok(File.Exists(Path.Combine(saves, "SurrounSync_Session_3", "Player.sav")), "co-op slot itself untouched");
            Ok((File.GetAttributes(Path.Combine(saves, "QuickSaveNew", "Player.sav")) & FileAttributes.ReadOnly) == 0, "save writable again");
            var bk = Directory.GetDirectories(w64, "UE4SS-2-backup-*");
            Ok(!File.Exists(Path.Combine(w64, "UE4SS.dll")) && !Directory.Exists(Path.Combine(w64, "Mods")) && bk.Length == 1 &&
               File.Exists(Path.Combine(bk[0], "xinput1_3.dll")) && File.Exists(Path.Combine(w64, "dwmapi.dll")), "UE4SS 2 moved, UE4SS 3's dwmapi kept");
            Ok(File.Exists(Path.Combine(mods, "SurrounDeadMP", "enabled.txt.off")), "conflict mod switched off");

            var g = Doctor.Check(game);
            Ok(Find(g, "Continue opens") == null && Find(g, "read-only") == null && Find(g, "version 2") == null && Find(g, "SurrounDeadMP") == null,
               "fixed problems gone on re-check");
            var again = Find(g, "co-op slot SurrounSync_Session_3");
            Ok(again != null && again.Do == null && again.Fix.Contains("backup copy is in"), "backed-up slot: no second backup");

            // an open co-op session: the mod brings the player home itself - Continue is left alone
            W(Path.Combine(saves, "mirror_coop_session.txt"), "x");
            File.WriteAllText(ini, "[/Script/EasyMultiSave.EMSObject]\r\nCurrentSaveGameName=SurrounSync_Session_3\r\n");
            Ok(Find(Doctor.Check(game), "Continue opens") == null, "open session: Continue not touched");
            Ok(Find(Doctor.Check(Path.Combine(root, "nope")), "wasn't found") != null, "not a game folder");
            // a Windows user name the mod's Lua can't spell: an ASCII alias of the save folder (8.3 name or junction)
            string ru = Path.Combine(root, "Дмитрий", "SurrounDead");
            Directory.CreateDirectory(ru);
            string how, alias = SurrounSyncShared.LocalAlias.Ensure(w64, ru, out how);
            string afile = Path.Combine(w64, SurrounSyncShared.LocalAlias.FileName);
            Ok(alias != null && SurrounSyncShared.LocalAlias.Ascii(alias) && Directory.Exists(alias) && File.Exists(afile) &&
               File.ReadAllText(afile).Trim() == alias, "non-ASCII save folder -> ASCII alias (" + how + ": " + alias + ")");
            if (alias != null)
            {
                File.WriteAllText(Path.Combine(alias, "probe.txt"), "x");
                Ok(File.Exists(Path.Combine(ru, "probe.txt")), "a file written through the alias is in the real folder");
                string how2, alias2 = SurrounSyncShared.LocalAlias.Ensure(w64, ru, out how2);
                Ok(alias2 == alias, "running it again keeps the same alias");
                if (how == "junction") try { Directory.Delete(alias); } catch { }
            }
            SurrounSyncShared.LocalAlias.NoShortNames = true;
            string hj, j = SurrounSyncShared.LocalAlias.Ensure(w64, ru, out hj);
            SurrounSyncShared.LocalAlias.NoShortNames = false;
            Ok(hj == "junction" && j != null && SurrounSyncShared.LocalAlias.Ascii(j) && File.Exists(Path.Combine(j, "probe.txt")),
               "without 8.3 names: a junction under ProgramData (" + j + ")");
            if (j != null) try { Directory.Delete(j); } catch { }
            Ok(Directory.Exists(ru) && File.Exists(Path.Combine(ru, "probe.txt")), "removing the junction leaves the real folder alone");
            SurrounSyncShared.LocalAlias.Ensure(w64, Path.Combine(root, "plain"), out how);
            Ok(how == "plain" && !File.Exists(afile), "an ASCII folder needs no alias (the file is removed)");

            Ok(Find(Doctor.Check(game), "wrong Steam branch") == null, "on Experimental: no branch problem");
            string acf = Path.Combine(root, "steamapps", "appmanifest_1645820.acf");
            string acfText = File.ReadAllText(acf);
            // only the game version it was made for (user 2026-11-10): the other 0.8 branch is the wrong one too now
            // (this test setup has no payload: made on "experimental", no build recorded)
            File.WriteAllText(acf, acfText.Replace("experimental", ""));
            var onNormal = Find(Doctor.Check(game), "wrong Steam branch");
            Ok(onNormal != null && onNormal.Kind == "problem" && onNormal.Fix.Contains("\"Experimental 0.8\""),
               "made on Experimental, game on the normal branch -> wrong branch, told to pick Experimental 0.8");
            var refused = new List<string>();
            Ok(!new Installer { Log = refused.Add }.Install(game) && refused.Count > 0 && refused[0].StartsWith("NOT INSTALLED: Your SurrounDead is on the wrong Steam branch")
               && refused.Exists(l => l.StartsWith("What to do: In Steam")), "...and Install refuses it, saying why and what to do");
            // "previous" is the old 0.7.1
            File.WriteAllText(acf, acfText.Replace("experimental", "previous"));
            var br = Find(Doctor.Check(game), "wrong Steam branch");
            Ok(br != null && br.What.Contains("0.7.1") && br.Fix.Contains("\"Experimental 0.8\""),
               "previous branch -> wrong branch, told it is 0.7.1 and which branch to pick");
            File.WriteAllText(acf, acfText);
            var allowed = new List<string>();
            new Installer { Log = allowed.Add }.Install(game);
            Ok(!allowed.Exists(l => l.StartsWith("NOT INSTALLED")), "the right branch: Install goes past the version check (" + (allowed.Count > 0 ? allowed[0] : "") + ")");
            // the rule itself, with a recorded build (as a real release has)
            Func<string[], string> kind = p => p == null ? "ok" : p[2];
            Ok(kind(Doctor.VersionProblem("26471822", "", "26471822", null, true, "5.6")) == "ok", "the build and branch it was made for: installs");
            var old = Doctor.VersionProblem("26471822", "", "26467602", null, true, "5.6");
            Ok(kind(old) == "older" && old[0].Contains("26467602") && old[0].Contains("26471822") && old[0].Contains("won't install"),
               "an older game build: refused, both builds named");
            var nw = Doctor.VersionProblem("26471822", "", "26480000", null, true, "5.6");
            Ok(kind(nw) == "newer" && nw[0].Contains("NEWER") && nw[1].Contains("SurrounSync update"), "a newer game build: refused, told to wait for the SurrounSync update");
            var wb = Doctor.VersionProblem("26471822", "", "26471822", "experimental", true, "5.6");
            Ok(kind(wb) == "branch" && wb[1].Contains("\"None\" (the normal branch)"), "made on the normal branch, game on Experimental: refused, told to pick None");
            Ok(kind(Doctor.VersionProblem("26471822", "", null, null, true, "5.6")) == "unknown", "the game's build can't be read: refused");
            Ok(kind(Doctor.VersionProblem("", "", "123", null, false, "5.3.2")) == "engine", "an old game program (Unreal 5.3): refused");
            Ok(kind(Doctor.VersionProblem("", "", "123", null, false, "0.0.0")) == "ok", "a program version that can't be read alone doesn't refuse");
            Ok(kind(Doctor.VersionProblem("", "", "123", null, true, "5.6")) == "ok", "no build recorded (an old setup): only the branch is checked");

            // the updater: a download whose connection closes early is a failure, never a cut-off setup to run
            string dl = Path.Combine(root, "dl.exe"), err;
            Ok(!SurrounSyncShared.Release.Download(Serve(1000, 10), dl, null, out err) && err.Contains("cut off") && !File.Exists(dl),
               "cut-off download fails and leaves no file (" + err + ")");
            Ok(SurrounSyncShared.Release.Download(Serve(1000, 1000), dl, null, out err) && new FileInfo(dl).Length == 1000,
               "complete download succeeds (" + err + ")");
            // the setup a GitHub release names is run: only this repo's own release files are taken
            if (SurrounSyncShared.Release.SourceUrl().StartsWith("https://api.github.com/"))
            {
                string own = "https://github.com/" + SurrounSyncShared.Release.Repo + "/releases/download/v1.2.0/SurrounSyncSetup.exe";
                Ok(SurrounSyncShared.Release.SetupUrlOk(own), "this repo's release setup is taken");
                Ok(!SurrounSyncShared.Release.SetupUrlOk("https://example.com/SurrounSyncSetup.exe")
                   && !SurrounSyncShared.Release.SetupUrlOk("http://github.com/" + SurrounSyncShared.Release.Repo + "/releases/download/v1/SurrounSyncSetup.exe")
                   && !SurrounSyncShared.Release.SetupUrlOk("https://github.com/someone/else/releases/download/v1/SurrounSyncSetup.exe"),
                   "another host, plain http or another repo's setup is not");
            }
            else Console.WriteLine("  (skipped the setup-url check: update_source.txt points somewhere else)");

            // SyncFX in the setup: a new install has it loaded (switched off by SyncFX's own default); an update keeps
            // the player's on/off and settings, and a SyncFX that ran before 0.14.1 (always on when loaded) stays on
            string fxMods = Path.Combine(root, "fxgame", "Mods");
            Directory.CreateDirectory(fxMods);
            var ms = new MemoryStream();
            using (var za = new System.IO.Compression.ZipArchive(ms, System.IO.Compression.ZipArchiveMode.Create, true))
                foreach (var n in new[] { "game/ue4ss/Mods/SyncFX/Scripts/main.lua", "game/ue4ss/Mods/SyncFX/SyncFX.ini" })
                    using (var w = new StreamWriter(za.CreateEntry(n).Open())) w.Write("new");
            ms.Position = 0;
            var inst = new Installer();
            var rec = new Dictionary<string, string>();
            File.WriteAllText(Path.Combine(fxMods, "mods.txt"), "SurrounSync : 1");
            using (var za = new System.IO.Compression.ZipArchive(ms, System.IO.Compression.ZipArchiveMode.Read, true))
                inst.InstallSyncFx(za, fxMods, rec);
            string fx = Path.Combine(fxMods, "SyncFX");
            string fxUser = Path.Combine(fx, "SyncFX.user.ini");
            Ok(File.ReadAllText(Path.Combine(fxMods, "mods.txt")) == "SurrounSync : 1\r\nSyncFX : 1\r\n" && File.Exists(Path.Combine(fx, "Scripts", "main.lua"))
               && rec["syncfx"] == "ours" && !File.Exists(fxUser), "new install: SyncFX unpacked and loaded, no on/off written (starts off)");
            Action<string, string, string> update = (version, list, user) =>
            {
                rec["version"] = version;
                File.WriteAllText(Path.Combine(fxMods, "mods.txt"), list);
                if (user == null) { if (File.Exists(fxUser)) File.Delete(fxUser); } else W(fxUser, user);
                ms.Position = 0;
                using (var za = new System.IO.Compression.ZipArchive(ms, System.IO.Compression.ZipArchiveMode.Read, true))
                    inst.InstallSyncFx(za, fxMods, rec);
            };
            W(Path.Combine(fx, "Scripts", "gone.lua"), "old");
            update("0.14.0", "SurrounSync : 1\r\nSyncFX : 1\r\n", "grain = 20");
            Ok(File.ReadAllText(Path.Combine(fxMods, "mods.txt")).Contains("SyncFX : 1") && File.ReadAllText(fxUser) == "grain = 20\r\nenabled = on\r\n"
               && !File.Exists(Path.Combine(fx, "Scripts", "gone.lua")) && File.ReadAllText(Path.Combine(fx, "Scripts", "main.lua")) == "new",
               "update from 0.14.0 with SyncFX on: settings kept, it stays on (enabled = on added), old scripts replaced");
            update("0.14.0", "SurrounSync : 1\r\nSyncFX : 1\r\n", null);
            Ok(File.ReadAllText(fxUser) == "enabled = on\r\n", "update from 0.14.0, SyncFX on, no settings file yet: it stays on");
            update("0.14.0", "SurrounSync : 1\r\nSyncFX : 1\r\n", "enabled = off\r\n");
            Ok(File.ReadAllText(fxUser) == "enabled = off\r\n", "update: a saved on/off is never overwritten");
            update("0.14.1", "SurrounSync : 1\r\nSyncFX : 1\r\n", "grain = 20");
            Ok(File.ReadAllText(fxUser) == "grain = 20", "update from 0.14.1+: nothing added (its on/off is SyncFX's own)");
            update("0.14.0", "SurrounSync : 1\r\nSyncFX : 0\r\n", null);
            Ok(File.ReadAllText(Path.Combine(fxMods, "mods.txt")).Contains("SyncFX : 0") && !File.Exists(fxUser),
               "update with SyncFX not loaded: the player's OFF kept, nothing written");

            // uninstall takes SyncFX away: a ReShade it had set aside (SyncFX off) comes back; a reinstalled one is kept
            string rw = Path.Combine(root, "rsgame");
            W(Path.Combine(rw, "dxgi.dll.syncfx-off"), "reshade");
            inst.RestoreReShade(rw);
            Ok(File.Exists(Path.Combine(rw, "dxgi.dll")) && File.ReadAllText(Path.Combine(rw, "dxgi.dll")) == "reshade"
               && !File.Exists(Path.Combine(rw, "dxgi.dll.syncfx-off")), "uninstall: ReShade set aside by SyncFX is put back");
            W(Path.Combine(rw, "dxgi.dll.syncfx-off"), "older");
            inst.RestoreReShade(rw);
            Ok(File.ReadAllText(Path.Combine(rw, "dxgi.dll")) == "reshade", "uninstall: a dxgi.dll already there is not overwritten");
            inst.RestoreReShade(null);
            Ok(true, "uninstall: no game folder - no throw");

            // The gore mod: a new install has it off (mods.txt 0, its pak as .pak.off); an update keeps the player's
            // on/off and settings.ini and writes the new pak under the matching name; uninstall removes both
            string gg = Path.Combine(root, "ggame"), gmods = Path.Combine(gg, "Mods");
            string logic = Path.Combine(gg, "SurrounDead", "Content", "Paks", "LogicMods");
            string gpak = Path.Combine(logic, "SurrounDeadGore.pak"), gini = Path.Combine(gmods, "SurrounDeadGore", "settings.ini");
            Directory.CreateDirectory(gmods);
            Directory.CreateDirectory(Path.Combine(gg, "SurrounDead", "Content"));
            var gms = new MemoryStream();
            using (var za = new System.IO.Compression.ZipArchive(gms, System.IO.Compression.ZipArchiveMode.Create, true))
                foreach (var n in new[] { "game/ue4ss/Mods/SurrounDeadGore/Scripts/main.lua", "game/ue4ss/Mods/SurrounDeadGore/settings.ini",
                                          "gore/SurrounDeadGore.pak" })
                    using (var w = new StreamWriter(za.CreateEntry(n).Open())) w.Write("new");
            var grec = new Dictionary<string, string>();
            Action<string> gore = list =>
            {
                if (list != null) File.WriteAllText(Path.Combine(gmods, "mods.txt"), list);
                gms.Position = 0;
                using (var za = new System.IO.Compression.ZipArchive(gms, System.IO.Compression.ZipArchiveMode.Read, true))
                    inst.InstallGore(za, gg, gmods, grec);
            };
            gore("SurrounSync : 1");
            Ok(File.ReadAllText(Path.Combine(gmods, "mods.txt")) == "SurrounSync : 1\r\nSurrounDeadGore : 0\r\n"
               && File.Exists(Path.Combine(gmods, "SurrounDeadGore", "Scripts", "main.lua")) && File.ReadAllText(gini) == "new"
               && File.Exists(gpak + ".off") && !File.Exists(gpak) && grec["gore"] == "ours" && grec["gore_pak"] == "ours",
               "gore, new install: unpacked, listed off, its pak as .pak.off");
            W(gini, "blood = 2");
            W(Path.Combine(gmods, "SurrounDeadGore", "Scripts", "gone.lua"), "old");
            gore("SurrounSync : 1\r\nSurrounDeadGore : 1\r\n");
            Ok(File.ReadAllText(Path.Combine(gmods, "mods.txt")) == "SurrounSync : 1\r\nSurrounDeadGore : 1\r\n" && File.ReadAllText(gini) == "blood = 2"
               && File.Exists(gpak) && !File.Exists(gpak + ".off") && !File.Exists(Path.Combine(gmods, "SurrounDeadGore", "Scripts", "gone.lua")),
               "gore, update with it on: stays on, its pak live, settings.ini kept, old scripts replaced");
            gore("SurrounSync : 1\r\nSurrounDeadGore : 0\r\n");
            Ok(File.ReadAllText(Path.Combine(gmods, "mods.txt")) == "SurrounSync : 1\r\nSurrounDeadGore : 0\r\n"
               && File.Exists(gpak + ".off") && !File.Exists(gpak), "gore, update with it off: stays off, its pak .pak.off");
            W(Path.Combine(gmods, "SurrounDeadGore", "enabled.txt"), "");
            gore("SurrounSync : 1\r\n");
            Ok(File.ReadAllText(Path.Combine(gmods, "mods.txt")) == "SurrounSync : 1\r\n" && File.Exists(gpak),
               "gore, a standalone install on through enabled.txt: kept on, nothing added to mods.txt");
            File.Delete(Path.Combine(gmods, "SurrounDeadGore", "enabled.txt"));
            File.WriteAllText(Path.Combine(gmods, "mods.txt"), "SurrounSync : 1\r\nSurrounDeadGore : 1\r\n");
            inst.RemoveGore(gg, gmods, grec);
            Ok(!Directory.Exists(Path.Combine(gmods, "SurrounDeadGore")) && !File.Exists(gpak) && !File.Exists(gpak + ".off")
               && !File.ReadAllText(Path.Combine(gmods, "mods.txt")).Contains("SurrounDeadGore : 1"), "gore, uninstall: mod and pak gone, not loaded");

            // The FPV drone's copy that came with SurrounSync 1.1.0 (bundled.txt): an update or uninstall removes it;
            // a bought copy over it (owned.txt) or a separately installed FPVDrone (no bundled.txt) is never touched
            string dg = Path.Combine(root, "dgame"), dmods = Path.Combine(dg, "Mods"), ddir = Path.Combine(dmods, "FPVDrone");
            Directory.CreateDirectory(dmods);
            // FPVDrone bought and unpacked over the 1.1.0 copy: bundled.txt left behind, owned.txt says it's theirs
            File.WriteAllText(Path.Combine(dmods, "mods.txt"), "SurrounSync : 1\r\nFPVDrone : 1\r\n");
            W(Path.Combine(ddir, "Scripts", "main.lua"), "bought");
            W(Path.Combine(ddir, "bundled.txt"), "");
            W(Path.Combine(ddir, "owned.txt"), "");
            var drec = new Dictionary<string, string> { { "fpvdrone", "ours" } };
            inst.RemoveDrone(dmods, drec);
            Ok(File.ReadAllText(Path.Combine(ddir, "Scripts", "main.lua")) == "bought" && !drec.ContainsKey("fpvdrone"),
               "drone, update: a bought copy over the bundled one is never removed, and no longer counted as ours");
            // the 1.1.0 copy as it came (bundled.txt, no owned.txt)
            File.Delete(Path.Combine(ddir, "owned.txt"));
            drec["fpvdrone"] = "ours";
            inst.RemoveDrone(dmods, drec);
            Ok(!Directory.Exists(ddir) && !File.ReadAllText(Path.Combine(dmods, "mods.txt")).Contains("FPVDrone : 1") && !drec.ContainsKey("fpvdrone"),
               "drone, update: the copy 1.1.0 brought is gone, not loaded");
            W(Path.Combine(ddir, "Scripts", "main.lua"), "theirs");
            var orec = new Dictionary<string, string> { { "fpvdrone", "ours" } };
            inst.RemoveDrone(dmods, orec);
            Ok(File.Exists(Path.Combine(ddir, "Scripts", "main.lua")), "drone: a separately installed FPVDrone is never removed");
            inst.RemoveDrone(dmods, new Dictionary<string, string>());
            Ok(File.Exists(Path.Combine(ddir, "Scripts", "main.lua")), "drone: no record, nothing touched");

            // SurrounSync's content: the intro (the player's own kept and put back), the sound pak, BPModLoaderMod
            string cg = Path.Combine(root, "cgame"), cmods = Path.Combine(cg, "Mods");
            string movies = Path.Combine(cg, "SurrounDead", "Content", "Movies"), intro = Path.Combine(movies, "UE5 Intro.mp4");
            Directory.CreateDirectory(cmods);
            W(intro, "theirs");
            File.WriteAllText(Path.Combine(cmods, "mods.txt"), "SurrounSync : 1\r\n");
            var cms = new MemoryStream();
            using (var za = new System.IO.Compression.ZipArchive(cms, System.IO.Compression.ZipArchiveMode.Create, true))
                foreach (var n in new[] { "content/Movies/UE5 Intro.mp4", "content/Paks/LogicMods/SurrounSyncSounds.pak",
                                          "content/Paks/LogicMods/SurrounSyncGlider.pak", "content/Paks/LogicMods/SurrounSyncArmory.pak",
                                          "game/ue4ss/Mods/BPModLoaderMod/Scripts/main.lua" })
                    using (var w = new StreamWriter(za.CreateEntry(n).Open())) w.Write("ours");
            var crec = new Dictionary<string, string>();
            string pak = Path.Combine(cg, "SurrounDead", "Content", "Paks", "LogicMods", "SurrounSyncSounds.pak");
            string glpak = Path.Combine(cg, "SurrounDead", "Content", "Paks", "LogicMods", "SurrounSyncGlider.pak");
            string arpak = Path.Combine(cg, "SurrounDead", "Content", "Paks", "LogicMods", "SurrounSyncArmory.pak");
            string drpak = Path.Combine(cg, "SurrounDead", "Content", "Paks", "LogicMods", "SurrounSyncDrone.pak");
            // (a SurrounSyncDrone.pak there before any SurrounSync setup ran is not ours: the first install keeps it)
            W(drpak, "1.1.0");
            bool drKeptFirst = false;
            for (int i = 0; i < 2; i++)
            {
                cms.Position = 0;
                using (var za = new System.IO.Compression.ZipArchive(cms, System.IO.Compression.ZipArchiveMode.Read, true))
                    inst.InstallContent(za, cg, cmods, crec);
                if (i == 0) drKeptFirst = File.Exists(drpak);
            }
            Ok(File.Exists(glpak) && File.Exists(arpak), "content: the glider and armory paks in LogicMods");
            Ok(drKeptFirst && !File.Exists(drpak), "content, update: 1.1.0's SurrounSyncDrone.pak removed (only once an earlier setup put the paks in)");
            Ok(File.ReadAllText(intro) == "ours" && File.ReadAllText(intro + ".surrounsync-original") == "theirs",
               "content: our intro in, the player's own kept (also after an update)");
            Ok(File.Exists(pak) && File.Exists(Path.Combine(cmods, "BPModLoaderMod", "Scripts", "main.lua"))
               && File.ReadAllText(Path.Combine(cmods, "mods.txt")).Contains("BPModLoaderMod : 1"),
               "content: the sound pak in LogicMods, BPModLoaderMod added and switched on where it was missing");
            inst.RemoveContent(cg, cmods, crec);
            Ok(File.ReadAllText(intro) == "theirs" && !File.Exists(intro + ".surrounsync-original") && !File.Exists(pak) && !File.Exists(glpak) && !File.Exists(arpak) && !File.Exists(drpak)
               && !Directory.Exists(Path.Combine(cmods, "BPModLoaderMod")) && !File.ReadAllText(Path.Combine(cmods, "mods.txt")).Contains("BPModLoaderMod"),
               "uninstall: the player's intro back, our pak and BPModLoaderMod gone");
            W(Path.Combine(cmods, "BPModLoaderMod", "Scripts", "main.lua"), "their loader");
            File.WriteAllText(Path.Combine(cmods, "mods.txt"), "SurrounSync : 1\r\nBPModLoaderMod : 0\r\n");
            cms.Position = 0;
            using (var za = new System.IO.Compression.ZipArchive(cms, System.IO.Compression.ZipArchiveMode.Read, true))
                inst.InstallContent(za, cg, cmods, crec);
            inst.RemoveContent(cg, cmods, crec);
            Ok(File.ReadAllText(Path.Combine(cmods, "BPModLoaderMod", "Scripts", "main.lua")) == "their loader"
               && File.ReadAllText(Path.Combine(cmods, "mods.txt")).Contains("BPModLoaderMod : 0"),
               "a player's own BPModLoaderMod and its on/off are never touched");
            // the Hang Glider installed on its own too (make-glidermod.py's zip): uninstalling SurrounSync leaves it its
            // pak and the loader that loads it
            {
                string gcg = Path.Combine(root, "glgame"), gmods2 = Path.Combine(gcg, "Mods");
                Directory.CreateDirectory(gmods2);
                Directory.CreateDirectory(Path.Combine(gcg, "SurrounDead", "Content"));   // (InstallContent needs the game's Content)
                File.WriteAllText(Path.Combine(gmods2, "mods.txt"), "SurrounSync : 1\r\n");
                var glrec = new Dictionary<string, string>();
                cms.Position = 0;
                using (var za = new System.IO.Compression.ZipArchive(cms, System.IO.Compression.ZipArchiveMode.Read, true))
                    inst.InstallContent(za, gcg, gmods2, glrec);
                W(Path.Combine(gmods2, "SurrounSyncGlider", "Scripts", "main.lua"), "glider");
                inst.RemoveContent(gcg, gmods2, glrec);
                string lm = Path.Combine(gcg, "SurrounDead", "Content", "Paks", "LogicMods");
                Ok(File.Exists(Path.Combine(lm, "SurrounSyncGlider.pak")), "uninstall with the glider mod there: its pak kept");
                Ok(!File.Exists(Path.Combine(lm, "SurrounSyncSounds.pak")) && !File.Exists(Path.Combine(lm, "SurrounSyncArmory.pak")),
                   "uninstall with the glider mod there: our other paks gone");
                Ok(File.Exists(Path.Combine(gmods2, "BPModLoaderMod", "Scripts", "main.lua"))
                   && File.ReadAllText(Path.Combine(gmods2, "mods.txt")).Contains("BPModLoaderMod : 1"),
                   "uninstall with the glider mod there: BPModLoaderMod kept, still on");
            }
            // a game without an intro of its own: ours goes again at uninstall (nothing of the player's to put back)
            File.Delete(intro);
            var nrec = new Dictionary<string, string>();
            for (int i = 0; i < 2; i++)
            {
                cms.Position = 0;
                using (var za = new System.IO.Compression.ZipArchive(cms, System.IO.Compression.ZipArchiveMode.Read, true))
                    inst.InstallContent(za, cg, cmods, nrec);
            }
            bool introIn = File.ReadAllText(intro) == "ours" && !File.Exists(intro + ".surrounsync-original");
            inst.RemoveContent(cg, cmods, nrec);
            Ok(introIn && !File.Exists(intro), "no intro of the game's own: ours in, and gone again at uninstall (also after an update)");
            // a player's own BPModLoaderMod without UE4SS's shared UEHelpers ("module 'UEHelpers' not found" at every start,
            // player report 2026-10-30: no dog sounds): UEHelpers goes in, theirs stays; uninstall takes only ours
            var hms = new MemoryStream();
            using (var za = new System.IO.Compression.ZipArchive(hms, System.IO.Compression.ZipArchiveMode.Create, true))
                foreach (var n in new[] { "content/Paks/LogicMods/SurrounSyncSounds.pak", "game/ue4ss/Mods/BPModLoaderMod/Scripts/main.lua",
                                          "game/ue4ss/Mods/shared/UEHelpers/UEHelpers.lua" })
                    using (var w = new StreamWriter(za.CreateEntry(n).Open())) w.Write("ours");
            string uhf = Path.Combine(cmods, "shared", "UEHelpers", "UEHelpers.lua");
            var hrec = new Dictionary<string, string>();
            hms.Position = 0;
            using (var za = new System.IO.Compression.ZipArchive(hms, System.IO.Compression.ZipArchiveMode.Read, true))
                inst.InstallContent(za, cg, cmods, hrec);
            Ok(File.Exists(uhf) && File.ReadAllText(Path.Combine(cmods, "BPModLoaderMod", "Scripts", "main.lua")) == "their loader",
               "UEHelpers added next to the player's own BPModLoaderMod (left as it was)");
            inst.RemoveContent(cg, cmods, hrec);
            Ok(!File.Exists(uhf) && File.Exists(Path.Combine(cmods, "BPModLoaderMod", "Scripts", "main.lua")), "uninstall: our UEHelpers gone, their loader kept");
            W(uhf, "their helpers");
            var hrec2 = new Dictionary<string, string>();
            hms.Position = 0;
            using (var za = new System.IO.Compression.ZipArchive(hms, System.IO.Compression.ZipArchiveMode.Read, true))
                inst.InstallContent(za, cg, cmods, hrec2);
            inst.RemoveContent(cg, cmods, hrec2);
            Ok(File.ReadAllText(uhf) == "their helpers", "a UEHelpers already there is never replaced or removed");
        }
        finally
        {
            try
            {
                foreach (var p in Directory.GetFiles(root, "*", SearchOption.AllDirectories)) File.SetAttributes(p, FileAttributes.Normal);
                Directory.Delete(root, true);
            }
            catch { }
        }
        Console.WriteLine(fails == 0 ? "ALL PASSED" : fails + " FAILED");
        return fails == 0 ? 0 : 1;
    }
}
