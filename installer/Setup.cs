// SurrounSyncSetup.exe: installs, updates, checks and removes SurrounSync. Everything it installs is
// packed inside it (see tools/build-release.ps1).

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;
using SurrounSyncShared;

namespace SurrounSyncSetup
{
    class Installer
    {
        public Action<string> Log = delegate { };
        public Action<int> Progress = delegate { };

        const string ModPath = "game/ue4ss/Mods/SurrounSync/";
        public static string RecordFile { get { return Path.Combine(Release.AppDir, "install.txt"); } }

        static byte[] payloadBytes;
        static ZipArchive Payload()
        {
            if (payloadBytes == null)
            {
                using (var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("payload.zip"))
                {
                    if (s == null) return null;
                    using (var m = new MemoryStream()) { s.CopyTo(m); payloadBytes = m.ToArray(); }
                }
            }
            return new ZipArchive(new MemoryStream(payloadBytes), ZipArchiveMode.Read);
        }

        public static string ThisVersion()
        {
            try
            {
                using (var z = Payload())
                {
                    if (z == null) return null;
                    ZipArchiveEntry e = null;
                    foreach (var x in z.Entries) if (N(x) == ModPath + "Scripts/mirror/version.lua") e = x;
                    if (e == null) return null;
                    using (var r = new StreamReader(e.Open()))
                    {
                        var m = Regex.Match(r.ReadToEnd(), "VERSION\\s*=\\s*\"([^\"]+)\"");
                        return m.Success ? m.Groups[1].Value : null;
                    }
                }
            }
            catch { return null; }
        }

        static string N(ZipArchiveEntry e) { return e.FullName.Replace('\\', '/'); }

        public static string PayloadText(string name)
        {
            try
            {
                using (var z = Payload())
                {
                    if (z == null) return null;
                    foreach (var e in z.Entries) if (N(e) == name) using (var r = new StreamReader(e.Open())) return r.ReadToEnd().Trim();
                }
            }
            catch { }
            return null;
        }
        public static long PayloadLength(string name)
        {
            try { using (var z = Payload()) { if (z == null) return -1; foreach (var e in z.Entries) if (N(e) == name) return e.Length; } }
            catch { }
            return -1;
        }

        public static bool PayloadHas(string prefix)
        {
            try { using (var z = Payload()) { if (z == null) return false; foreach (var e in z.Entries) if (N(e).StartsWith(prefix)) return true; } }
            catch { }
            return false;
        }

        public static Dictionary<string, string> ReadRecord()
        {
            var d = new Dictionary<string, string>();
            try
            {
                if (!File.Exists(RecordFile)) return d;
                foreach (var line in File.ReadAllLines(RecordFile))
                {
                    int i = line.IndexOf('=');
                    if (i > 0) d[line.Substring(0, i).Trim()] = line.Substring(i + 1).Trim();
                }
            }
            catch { }
            return d;
        }
        static void WriteRecord(Dictionary<string, string> d)
        {
            Directory.CreateDirectory(Release.AppDir);
            var sb = new StringBuilder("# SurrounSync install record (SurrounSyncSetup.exe) - what to undo on uninstall\r\n");
            foreach (var kv in d) sb.Append(kv.Key).Append(" = ").Append(kv.Value).Append("\r\n");
            File.WriteAllText(RecordFile, sb.ToString());
        }

        public static string InstalledGame()
        {
            string g;
            if (ReadRecord().TryGetValue("game", out g) && Game.IsGame(g)) return g;
            return null;
        }
        public static string InstalledVersion(string game)
        {
            if (!Game.IsGame(game)) return null;
            return Release.ModVersion(ModsDir(game) == null ? null : Path.Combine(ModsDir(game), "SurrounSync"));
        }
        public static string ModsDir(string game)
        {
            string w = Game.Win64(game);
            if (File.Exists(Path.Combine(w, "ue4ss", "UE4SS.dll"))) return Path.Combine(w, "ue4ss", "Mods");
            return null;
        }
        public static bool IsLink(string path)
        {
            try { return Directory.Exists(path) && (new DirectoryInfo(path).Attributes & FileAttributes.ReparsePoint) != 0; }
            catch { return false; }
        }

        public static bool CanWrite(string dir)
        {
            try
            {
                string t = Path.Combine(dir, ".surrounsync_write_test");
                File.WriteAllText(t, "x");
                File.Delete(t);
                return true;
            }
            catch { return false; }
        }

        // PDS and its pak, only when an older setup installed them ("ours" in the record); a PDS the player
        // installed themselves is left alone.
        void RemoveOldPds(string game, string mods, Dictionary<string, string> rec)
        {
            string v;
            if (rec.TryGetValue("pds", out v) && v == "ours")
            {
                string pds = Path.Combine(mods, "PDS");
                if (!IsLink(pds) && Directory.Exists(pds)) { DeleteDir(pds); DisableMod(mods, "PDS"); Log("Removed PDS (no longer part of SurrounSync's setup)."); }
            }
            rec.Remove("pds");
            if (rec.TryGetValue("paks", out v))
                foreach (var n in v.Split('|'))
                {
                    string f = Path.Combine(game, "SurrounDead", "Content", "Paks", "~mods", n);
                    try { if (File.Exists(f)) { File.Delete(f); Log("Removed " + n + "."); } } catch { }
                }
            rec.Remove("paks");
        }

        public bool Install(string game)
        {
            if (!Game.IsGame(game)) { Log("SurrounDead wasn't found in " + game + "."); return false; }
            if (Game.Running(game)) { Log("SurrounDead is running - close the game, then try again."); return false; }
            string w64 = Game.Win64(game);
            using (var z = Payload())
            {
                if (z == null) { Log("This setup has no SurrounSync files inside it (a broken download?)."); return false; }
                var rec = ReadRecord();
                string oldGame; rec.TryGetValue("game", out oldGame);
                if (oldGame != null && !string.Equals(Path.GetFullPath(oldGame), Path.GetFullPath(game), StringComparison.OrdinalIgnoreCase))
                    rec = new Dictionary<string, string>();
                rec["game"] = game;
                Progress(5);

                string ue = Path.Combine(w64, "ue4ss");
                if (File.Exists(Path.Combine(ue, "UE4SS.dll")))
                {
                    Log("UE4SS is already installed - keeping it.");
                    if (!rec.ContainsKey("ue4ss")) rec["ue4ss"] = "theirs";
                    if (!File.Exists(Path.Combine(w64, "dwmapi.dll")))
                    {
                        Extract(z, "game/", w64, e => N(e) == "game/dwmapi.dll");
                        Log("Put back UE4SS's starter file (dwmapi.dll) - it was missing.");
                    }
                }
                else if (File.Exists(Path.Combine(w64, "UE4SS.dll")))
                {
                    Log("An old UE4SS (2.x, in Binaries\\Win64) is installed - SurrounSync needs UE4SS 3. Remove the old one " +
                        "(UE4SS.dll, UE4SS-settings.ini, dwmapi.dll / xinput1_3.dll and the Mods folder next to the game) and run this again.");
                    return false;
                }
                else
                {
                    Extract(z, "game/", w64, e => !N(e).StartsWith(ModPath));
                    rec["ue4ss"] = "ours";
                    Log("Installed UE4SS.");
                }
                Progress(30);

                string mods = Path.Combine(ue, "Mods");
                Directory.CreateDirectory(mods);
                string old = Path.Combine(mods, "MirrorCoop");
                if (Directory.Exists(old) && !IsLink(old)) { DeleteDir(old); Log("Removed the old MirrorCoop folder (now SurrounSync)."); }
                if (!IsLink(old)) DisableMod(mods, "MirrorCoop");
                string target = Path.Combine(mods, "SurrounSync");
                if (IsLink(target)) Log("Mods\\SurrounSync is a developer link - left as it is.");
                else
                {
                    // staged: the new mod is unpacked next to Mods first and swapped in whole, so a file still
                    // in use (the bridge exits a few seconds after the game) can't leave a half-deleted mod
                    StopBridges(target);
                    string fresh = Path.Combine(ue, "SurrounSync.new"), prev = Path.Combine(ue, "SurrounSync.old");
                    if (Directory.Exists(fresh)) DeleteDir(fresh);
                    if (Directory.Exists(prev)) DeleteDir(prev);
                    Extract(z, ModPath, fresh, null);
                    // bug reports compare this with the game's build (game update after this release?)
                    try { string mb = PayloadText("made_for_build.txt"); if (!string.IsNullOrEmpty(mb)) File.WriteAllText(Path.Combine(fresh, "made_for_build.txt"), mb.Trim()); }
                    catch { }
                    try { Directory.SetCurrentDirectory(Path.GetTempPath()); } catch { }
                    if (Directory.Exists(target)) MoveDir(target, prev);
                    try { MoveDir(fresh, target); }
                    catch
                    {
                        if (Directory.Exists(prev) && !Directory.Exists(target)) MoveDir(prev, target);
                        throw;
                    }
                    try { if (Directory.Exists(prev)) DeleteDir(prev); }
                    catch (Exception ex) { Log("Note: couldn't remove the old copy " + prev + " (" + ex.Message + ") - it is removed next time."); }
                    Log("Installed SurrounSync " + (ThisVersion() ?? "") + ".");
                }
                EnableMod(mods, "SurrounSync");
                foreach (var c in Doctor.Conflicts)
                {
                    string list = Path.Combine(mods, "mods.txt");
                    bool on = false;
                    try { on = Regex.IsMatch(File.ReadAllText(list), "^\\s*" + c + "\\s*:\\s*1\\s*$", RegexOptions.Multiline); } catch { }
                    if (on) { DisableMod(mods, c); Log("Switched off " + c + " (an older multiplayer mod - it fights with SurrounSync)."); }
                }
                Progress(55);

                // Older setups could install PDS (blood and gore) and its pak; this setup no longer ships them.
                // Take away only what an older setup put there (a pak made for an older game build can crash a newer game).
                RemoveOldPds(game, mods, rec);
                Progress(70);

                Unblock(target); Unblock(ue); Unblock(Path.Combine(w64, "dwmapi.dll"));
                {
                    string how, alias = LocalAlias.Ensure(w64, out how);
                    if (how != "plain")
                        Log(alias != null ? "Your Windows user name has letters the mod can't use in file paths - it reaches your saves through " + alias + " (" + how + ")."
                                          : "WARNING: your Windows user name has letters the mod can't use in file paths, and no safe path could be made (" + how + "). Send a bug report.");
                }

                string set = Path.Combine(w64, "mirror_settings.txt");
                if (!File.Exists(set) || Regex.IsMatch(File.ReadAllText(set), "^\\s*transport\\s*=\\s*file", RegexOptions.Multiline) &&
                    !Regex.IsMatch(File.ReadAllText(set), "^\\s*devtest\\s*=\\s*on", RegexOptions.Multiline))
                    File.WriteAllText(set, "# SurrounSync settings for this PC (edit in Notepad, restart the game).\r\n" +
                        "# loglevel = debug   more detail in mirror_log.txt when reporting a problem\r\ntransport = steam\r\npeer = \r\nnetsim = off\r\n");
                string role = Path.Combine(w64, "mirror_role.txt");
                if (!File.Exists(role) || File.ReadAllText(role).Trim() == "off") File.WriteAllText(role, "auto");

                string saved = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SurrounDead", "Saved");
                for (int i = 1; i <= 8; i++)
                {
                    Directory.CreateDirectory(Path.Combine(saved, "SaveGames", "SurrounSync_Session_" + i));
                    try { Directory.Delete(Path.Combine(saved, "SaveGames", "MirrorCoop_Session_" + i), false); } catch { }
                }
                string oldBackups = Path.Combine(saved, "MirrorBackups"), backupsDir = Path.Combine(saved, "SurrounSyncBackups");
                if (Directory.Exists(oldBackups) && !Directory.Exists(backupsDir))
                {
                    try { Directory.Move(oldBackups, backupsDir); Log("Moved your save backups to " + backupsDir + "."); }
                    catch (Exception e) { Log("Your save backups stay in " + oldBackups + " (" + e.Message + ")."); }
                }
                if (!Directory.Exists(oldBackups)) Directory.CreateDirectory(backupsDir);
                Progress(80);

                rec["version"] = ThisVersion() ?? "?";
                rec["installed"] = DateTime.Now.ToString("yyyy-MM-dd HH:mm");
                WriteRecord(rec);
                string me = KeepSetup();
                Register(me, rec["version"]);
                Progress(90);

                CheckConnector(target);
                Progress(100);
            }
            Log("");
            Log("Done! Start SurrounDead through Steam, load a save, open the handbook (J) and pick the CO-OP tab:");
            Log("  HOST A GAME - friends can join your world.   JOIN - a friend who is hosting, or their friend code.");
            return true;
        }

        void CheckConnector(string modDir)
        {
            string exe = Path.Combine(modDir, "bridge", "SurrounSyncBridge.exe");
            if (!File.Exists(exe))
            {
                Log("WARNING: SurrounSyncBridge.exe is missing - your antivirus probably removed it. Restore it from quarantine " +
                    "(or allow the game folder), then run Repair.");
                return;
            }
            if (Process.GetProcessesByName("steam").Length == 0)
            {
                Log("(Steam isn't running, so the Steam connection wasn't tested now - start Steam before the game.)");
                return;
            }
            try
            {
                string tmp = Path.Combine(Path.GetTempPath(), "SurrounSyncSelfTest");
                Directory.CreateDirectory(tmp);
                var psi = new ProcessStartInfo(exe, "--role guest --selftest --dir \"" + tmp + "\"")
                { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = Path.GetDirectoryName(exe) };
                using (var p = Process.Start(psi))
                {
                    if (!p.WaitForExit(20000)) { try { p.Kill(); } catch { } Log("WARNING: the Steam connection test didn't finish."); return; }
                    string log = "";
                    try { log = File.ReadAllText(Path.Combine(tmp, "mirror_bridge_guest.log")); } catch { }
                    var m = Regex.Match(log, "my id (\\d+)");
                    if (p.ExitCode == 0 && log.Contains("selftest: network OK"))
                        Log("Steam connection OK" + (m.Success ? " (Steam ID " + m.Groups[1].Value + ")" : "") + ".");
                    else
                        Log("WARNING: the Steam connection couldn't start (code " + p.ExitCode + "). Is Steam logged in? " +
                            "Did an antivirus block SurrounSyncBridge.exe?");
                }
            }
            catch (Exception e) { Log("WARNING: couldn't test the Steam connection: " + e.Message); }
        }

        public bool Uninstall(string game)
        {
            var rec = ReadRecord();
            if (game == null) rec.TryGetValue("game", out game);
            if (Game.IsGame(game))
            {
                if (Game.Running(game)) { Log("SurrounDead is running - close the game, then try again."); return false; }
                string w64 = Game.Win64(game);
                string mods = ModsDir(game);
                if (mods != null)
                {
                    string target = Path.Combine(mods, "SurrounSync");
                    if (IsLink(target)) Log("Mods\\SurrounSync is a developer link - left as it is.");
                    else if (Directory.Exists(target)) { DeleteDir(target); Log("Removed SurrounSync."); }
                    DisableMod(mods, "SurrounSync");
                    string v;
                    RemoveOldPds(game, mods, rec);
                    if (rec.TryGetValue("ue4ss", out v) && v == "ours")
                    {
                        var others = OtherMods(mods);
                        if (others.Count == 0)
                        {
                            DeleteDir(Path.Combine(w64, "ue4ss"));
                            TryDelete(Path.Combine(w64, "dwmapi.dll"));
                            Log("Removed UE4SS.");
                        }
                        else Log("UE4SS kept - other mods use it (" + string.Join(", ", others.ToArray()) + ").");
                    }
                }
                foreach (var f in Directory.GetFiles(w64, "mirror_*")) TryDelete(f);
            }
            else Log("The game folder from the install wasn't found - removing the rest.");
            string local = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SurrounDead");
            try { foreach (var f in Directory.GetFiles(local, "mirror_*")) if (!f.EndsWith(".sav")) TryDelete(f); } catch { }
            Unregister();
            string bk = Path.Combine(local, "Saved", "SurrounSyncBackups");
            if (!Directory.Exists(bk) && Directory.Exists(Path.Combine(local, "Saved", "MirrorBackups"))) bk = Path.Combine(local, "Saved", "MirrorBackups");
            Log("Your saves (and their backups in " + bk + ") were kept.");
            Log("SurrounSync is uninstalled.");
            return true;
        }

        // SurrounSync's own UE4SS files again (when the record says this setup installed them and some are gone).
        public bool ReinstallUe4ss(string game)
        {
            using (var z = Payload())
            {
                if (z == null) { Log("This setup has no UE4SS inside it (a broken download?)."); return false; }
                Extract(z, "game/", Game.Win64(game), e => !N(e).StartsWith(ModPath));
            }
            Log("Put SurrounSync's UE4SS files back.");
            return true;
        }

        // Another mod's UE4SS that can't attach to this game: keep it as ue4ss-old-<time>, unpack ours, copy the
        // other mods (and their on/off lists) over. REPAIR afterwards puts SurrounSync in.
        public bool SwapUe4ss(string game)
        {
            string w64 = Game.Win64(game), ue = Path.Combine(w64, "ue4ss");
            string old = Path.Combine(w64, "ue4ss-old-" + DateTime.Now.ToString("yyyyMMdd-HHmmss"));
            using (var z = Payload())
            {
                if (z == null) { Log("This setup has no UE4SS inside it (a broken download?)."); return false; }
                MoveDir(ue, old);
                string oldDwm = Path.Combine(w64, "dwmapi.dll");
                if (File.Exists(oldDwm)) File.Copy(oldDwm, Path.Combine(old, "dwmapi.dll"), true);
                try { Extract(z, "game/", w64, e => !N(e).StartsWith(ModPath)); }
                catch
                {
                    if (Directory.Exists(ue)) DeleteDir(ue);
                    MoveDir(old, ue);
                    throw;
                }
            }
            string om = Path.Combine(old, "Mods"), nm = Path.Combine(ue, "Mods");
            Directory.CreateDirectory(nm);
            if (Directory.Exists(om))
            {
                foreach (var d in Directory.GetDirectories(om))
                {
                    string n = Path.GetFileName(d);
                    if (n == "SurrounSync" || n.StartsWith("SurrounSync.") || Directory.Exists(Path.Combine(nm, n))) continue;
                    CopyDir(d, Path.Combine(nm, n));
                }
                foreach (var n in new[] { "mods.txt", "mods.json" })
                    if (File.Exists(Path.Combine(om, n))) File.Copy(Path.Combine(om, n), Path.Combine(nm, n), true);
            }
            var rec = ReadRecord(); rec["ue4ss"] = "ours"; WriteRecord(rec);
            Log("Swapped in SurrounSync's UE4SS. The old one is kept in " + old + " (your other mods were copied over).");
            return true;
        }

        public static void CopyDir(string from, string to)
        {
            Directory.CreateDirectory(to);
            foreach (var f in Directory.GetFiles(from)) File.Copy(f, Path.Combine(to, Path.GetFileName(f)), true);
            foreach (var d in Directory.GetDirectories(from)) CopyDir(d, Path.Combine(to, Path.GetFileName(d)));
        }

        static List<string> OtherMods(string mods)
        {
            var list = new List<string>();
            foreach (var d in Directory.GetDirectories(mods))
            {
                string n = Path.GetFileName(d);
                if (n == "SurrounSync" || n == "shared") continue;
                list.Add(n);
            }
            return list;
        }

        static void EnableMod(string mods, string name)
        {
            string txt = Path.Combine(mods, "mods.txt");
            var lines = File.Exists(txt) ? new List<string>(File.ReadAllLines(txt)) : new List<string>();
            bool found = false;
            for (int i = 0; i < lines.Count; i++)
                if (Regex.IsMatch(lines[i], "^\\s*" + name + "\\s*:")) { lines[i] = name + " : 1"; found = true; }
            if (!found)
            {
                lines.Add(name + " : 1");
            }
            File.WriteAllLines(txt, lines.ToArray());
            string json = Path.Combine(mods, "mods.json");
            if (File.Exists(json))
            {
                string s = File.ReadAllText(json);
                if (Regex.IsMatch(s, "\"mod_name\"\\s*:\\s*\"" + name + "\""))
                    s = Regex.Replace(s, "(\"mod_name\"\\s*:\\s*\"" + name + "\"\\s*,\\s*\"mod_enabled\"\\s*:\\s*)false", "${1}true");
                else
                {
                    int at = s.LastIndexOf(']');
                    if (at > 0)
                    {
                        string before = s.Substring(0, at).TrimEnd();
                        string sep = before.EndsWith("[") ? "" : ",";
                        s = before + sep + "\r\n    {\r\n        \"mod_name\": \"" + name + "\",\r\n        \"mod_enabled\": true\r\n    }\r\n" + s.Substring(at);
                    }
                }
                File.WriteAllText(json, s);
            }
        }
        static void DisableMod(string mods, string name)
        {
            string txt = Path.Combine(mods, "mods.txt");
            if (File.Exists(txt))
            {
                var keep = new List<string>();
                foreach (var l in File.ReadAllLines(txt)) if (!Regex.IsMatch(l, "^\\s*" + name + "\\s*:")) keep.Add(l);
                File.WriteAllLines(txt, keep.ToArray());
            }
            string json = Path.Combine(mods, "mods.json");
            if (File.Exists(json))
            {
                string s = File.ReadAllText(json);
                s = Regex.Replace(s, "(\"mod_name\"\\s*:\\s*\"" + name + "\"\\s*,\\s*\"mod_enabled\"\\s*:\\s*)true", "${1}false");
                File.WriteAllText(json, s);
            }
        }

        static void Extract(ZipArchive z, string prefix, string to, Func<ZipArchiveEntry, bool> filter)
        {
            foreach (var e in z.Entries)
            {
                string n = N(e);
                if (!n.StartsWith(prefix) || n.EndsWith("/")) continue;
                if (filter != null && !filter(e)) continue;
                string rel = n.Substring(prefix.Length).Replace('/', '\\');
                string dst = Path.GetFullPath(Path.Combine(to, rel));
                if (!dst.StartsWith(Path.GetFullPath(to), StringComparison.OrdinalIgnoreCase)) continue;
                Directory.CreateDirectory(Path.GetDirectoryName(dst));
                e.ExtractToFile(dst, true);
            }
        }
        static void DeleteDir(string d)
        {
            if (IsLink(d)) { Directory.Delete(d); return; }
            for (int i = 0; ; i++)
            {
                try { foreach (var f in Directory.GetFiles(d, "*", SearchOption.AllDirectories)) File.SetAttributes(f, FileAttributes.Normal); Directory.Delete(d, true); return; }
                catch (IOException) { if (i >= 5) throw; Thread.Sleep(400); }
            }
        }
        static void MoveDir(string from, string to)
        {
            for (int i = 0; ; i++)
            {
                try { Directory.Move(from, to); return; }
                catch (IOException) { if (i >= 10) throw; Thread.Sleep(500); }
                catch (UnauthorizedAccessException) { if (i >= 10) throw; Thread.Sleep(500); }
            }
        }
        // The bridge runs from Mods\SurrounSyncridge and exits ~10 s after the game: wait for it, then end it.
        void StopBridges(string modDir)
        {
            string root = Path.GetFullPath(modDir).TrimEnd('\\') + "\\";
            for (int waited = 0; ; waited += 500)
            {
                var mine = new List<Process>();
                foreach (var p in Process.GetProcessesByName("SurrounSyncBridge"))
                {
                    string path = null;
                    try { path = p.MainModule.FileName; } catch { }
                    if (path == null || path.StartsWith(root, StringComparison.OrdinalIgnoreCase)) mine.Add(p);
                }
                if (mine.Count == 0) return;
                if (waited >= 20000)
                {
                    foreach (var p in mine) { try { p.Kill(); p.WaitForExit(5000); } catch { } }
                    Log("Closed the old Steam connector (it was still running).");
                    return;
                }
                Thread.Sleep(500);
            }
        }
        static void TryDelete(string f) { try { if (File.Exists(f)) { File.SetAttributes(f, FileAttributes.Normal); File.Delete(f); } } catch { } }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool DeleteFile(string path);
        static void Unblock(string path)
        {
            try
            {
                if (File.Exists(path)) DeleteFile(path + ":Zone.Identifier");
                else if (Directory.Exists(path))
                    foreach (var f in Directory.GetFiles(path, "*", SearchOption.AllDirectories)) DeleteFile(f + ":Zone.Identifier");
            }
            catch { }
        }

        const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\SurrounSync";
        static string StartMenuDir
        {
            get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "SurrounSync"); }
        }

        static string KeepSetup()
        {
            Directory.CreateDirectory(Release.AppDir);
            string me = Assembly.GetExecutingAssembly().Location;
            string kept = Path.Combine(Release.AppDir, Release.SetupName);
            if (!string.Equals(Path.GetFullPath(me), Path.GetFullPath(kept), StringComparison.OrdinalIgnoreCase))
            {
                for (int i = 0; ; i++)
                {
                    try { File.Copy(me, kept, true); break; }
                    catch (IOException) { if (i >= 10) throw; Thread.Sleep(300); }
                }
            }
            return kept;
        }

        static void Register(string exe, string version)
        {
            try
            {
                using (var k = Registry.CurrentUser.CreateSubKey(UninstallKey))
                {
                    k.SetValue("DisplayName", "SurrounSync (SurrounDead co-op)");
                    k.SetValue("DisplayVersion", version);
                    k.SetValue("Publisher", "SurrounSync");
                    k.SetValue("DisplayIcon", exe);
                    k.SetValue("InstallLocation", Release.AppDir);
                    k.SetValue("UninstallString", "\"" + exe + "\" --uninstall");
                    k.SetValue("ModifyPath", "\"" + exe + "\"");
                    k.SetValue("URLInfoAbout", "https://github.com/" + Release.Repo);
                    k.SetValue("EstimatedSize", 30000, RegistryValueKind.DWord);
                    k.SetValue("NoRepair", 1, RegistryValueKind.DWord);
                }
            }
            catch { }
            try
            {
                Directory.CreateDirectory(StartMenuDir);
                Shortcut(Path.Combine(StartMenuDir, "SurrounSync Setup.lnk"), exe, "", "Install, update or uninstall SurrounSync");
                Shortcut(Path.Combine(StartMenuDir, "SurrounSync Bug Report.lnk"), exe, "--report", "Save a SurrounSync bug report on the desktop");
            }
            catch { }
        }

        static void Unregister()
        {
            try { Registry.CurrentUser.DeleteSubKeyTree(@"Software\Microsoft\Windows\CurrentVersion\Uninstall\MirrorCoop", false); } catch { }
            try { Registry.CurrentUser.DeleteSubKeyTree(UninstallKey, false); } catch { }
            try { if (Directory.Exists(StartMenuDir)) Directory.Delete(StartMenuDir, true); } catch { }
            try { TryDelete(RecordFile); TryDelete(Path.Combine(Release.AppDir, "update_check.txt")); } catch { }
            string kept = Path.Combine(Release.AppDir, Release.SetupName);
            try
            {
                Process.Start(new ProcessStartInfo("cmd.exe", "/c ping 127.0.0.1 -n 4 > nul & del /f /q \"" + kept + "\" & rmdir /s /q \"" + Release.AppDir + "\"")
                { CreateNoWindow = true, UseShellExecute = false });
            }
            catch { }
        }

        static void Shortcut(string lnk, string target, string args, string desc)
        {
            var t = Type.GetTypeFromProgID("WScript.Shell");
            object sh = Activator.CreateInstance(t);
            object sc = t.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, sh, new object[] { lnk });
            var st = sc.GetType();
            st.InvokeMember("TargetPath", BindingFlags.SetProperty, null, sc, new object[] { target });
            st.InvokeMember("Arguments", BindingFlags.SetProperty, null, sc, new object[] { args });
            st.InvokeMember("Description", BindingFlags.SetProperty, null, sc, new object[] { desc });
            st.InvokeMember("IconLocation", BindingFlags.SetProperty, null, sc, new object[] { target + ",0" });
            st.InvokeMember("Save", BindingFlags.InvokeMethod, null, sc, null);
        }
    }

    class Finding
    {
        public string Kind;
        public string What, Fix;
        public string Auto;                    // what FIX does about it, shown while it runs
        public Func<Action<string>, bool> Do;  // the automatic fix (null: REPAIR or the player); true = fixed, false = started/half
        public bool Repair;                    // REPAIR (Installer.Install) fixes it
        public Finding(string k, string w, string f) { Kind = k; What = w; Fix = f; }
        public bool Fixable { get { return Do != null || Repair; } }
    }

    static class Doctor
    {
        public static readonly string[] Conflicts = { "SurrounDeadMP", "SurrounDeadMPInput", "SplitScreenMod" };
        // %LOCALAPPDATA%\SurrounDead (a field so the setup test can point it at a fake folder)
        public static string LocalDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SurrounDead");
        static readonly Regex CoopSlot = new Regex("^(SurrounSync|MirrorCoop)_Session(_\\d+)?$", RegexOptions.IgnoreCase);
        public static bool IsCoopSlot(string n) { return !string.IsNullOrEmpty(n) && CoopSlot.IsMatch(n); }
        const string CoopMarker = "SurrounSync-coop.txt";
        static string Stamp() { return DateTime.Now.ToString("yyyyMMdd-HHmmss"); }

        static string ReadShared(string path)
        {
            try
            {
                using (var s = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                using (var r = new StreamReader(s)) return r.ReadToEnd();
            }
            catch { return ""; }
        }

        // ---- Steam's appmanifest_1645820.acf ----
        static string Manifest(string game)
        {
            try { return ReadShared(Path.Combine(Path.GetDirectoryName(Path.GetDirectoryName(game)), "appmanifest_" + Game.AppId + ".acf")); }
            catch { return ""; }
        }
        static string Acf(string acf, string key)
        {
            var m = Regex.Match(acf, "\"" + key + "\"\\s+\"([^\"]*)\"");
            return m.Success ? m.Groups[1].Value : null;
        }
        // what Steam's Betas list shows for a branch key
        public static string BranchName(string key)
        {
            if (key == null) return "None";
            return key == "experimental" ? "Experimental 0.8" : key;
        }
        public static string BetaOf(string game) { string b = Acf(Manifest(game), "BetaKey"); return string.IsNullOrEmpty(b) || b == "public" ? null : b; }

        // ---- UE4SS ----
        static string Ue4ssLog(string ue) { return ReadShared(Path.Combine(ue, "UE4SS.log")); }
        static string Ue4ssVersion(string log)
        {
            var m = Regex.Match(log, "UE4SS - v([0-9][^ \\r\\n]*)");
            return m.Success ? m.Groups[1].Value : null;
        }
        static bool OursUe4ss(string ue)
        {
            long ours = Installer.PayloadLength("game/ue4ss/UE4SS.dll"), theirs = -1;
            try { theirs = new FileInfo(Path.Combine(ue, "UE4SS.dll")).Length; } catch { }
            return ours <= 0 || theirs <= 0 || ours == theirs;
        }

        // One line for the window: game build / beta / engine and the UE4SS that is in the game.
        public static string Versions(string game)
        {
            if (!Game.IsGame(game)) return "";
            string w64 = Game.Win64(game), ue = Path.Combine(w64, "ue4ss");
            string build = Game.BuildId(game), beta = BetaOf(game), eng = Game.EngineOf(w64);
            string s = "Game build " + build + (beta != null ? " (Steam beta \"" + beta + "\")" : "") + (eng != null && eng != "0.0.0" ? " · Unreal " + eng : "");
            string want = Installer.PayloadText("made_for_build.txt");
            if (!string.IsNullOrEmpty(want) && want != build) s += " · made for " + want;
            if (!File.Exists(Path.Combine(ue, "UE4SS.dll")))
                s += File.Exists(Path.Combine(w64, "UE4SS.dll")) ? "   ·   UE4SS 2 (too old)" : "   ·   UE4SS not installed";
            else
            {
                string v = Ue4ssVersion(Ue4ssLog(ue));
                s += "   ·   UE4SS " + (v ?? "3") + (OursUe4ss(ue) ? " (SurrounSync's)" : " (another mod's copy)");
            }
            return s;
        }

        static string Installed()
        {
            string v;
            return Installer.ReadRecord().TryGetValue("installed", out v) ? v : null;
        }

        public static List<Finding> Check(string game)
        {
            var f = new List<Finding>();
            Func<string, string, string, Finding> add = (k, w, x) => { var n = new Finding(k, w, x); f.Add(n); return n; };
            if (!Game.IsGame(game))
            {
                var nf = add("problem", "SurrounDead wasn't found in that folder.",
                    "Click Browse and pick the SurrounDead folder (the one with SurrounDead.exe in it). In Steam: right-click " +
                    "SurrounDead -> Manage -> Browse local files shows where it is.");
                if (Game.Find() != null) nf.Auto = "Find the game in your Steam libraries";   // done by the window / FixAll
                return f;
            }
            string w64 = Game.Win64(game), ue = Path.Combine(w64, "ue4ss"), mods = Path.Combine(ue, "Mods");
            string modDir = Path.Combine(mods, "SurrounSync");
            string local = LocalDir;
            string saves = Path.Combine(local, "Saved", "SaveGames");
            bool running = Game.Running(game);
            Func<Action<string>, bool> verify = log =>
            {
                Process.Start("steam://validate/" + Game.AppId);
                log("Steam now checks SurrounDead's files and downloads what is missing or old (watch Steam's Downloads page).");
                log("When Steam is done, click Check again.");
                return false;
            };

            // ---- the game itself ----
            string acf = Manifest(game), beta = BetaOf(game);
            // the Steam branch this SurrounSync was built on (made_for_beta.txt, "" = the normal one; older setups: experimental)
            string wantBeta = Installer.PayloadText("made_for_beta.txt") ?? "experimental";
            if (wantBeta == "" || wantBeta == "public") wantBeta = null;
            string betaNote = beta != null ? " You are on the Steam beta \"" + beta + "\"." : " You are on the normal (non-beta) branch.";
            string betaFix = "In Steam: right-click SurrounDead -> Properties -> Betas -> pick \"" + BranchName(wantBeta) + "\". ";
            if (beta != wantBeta)
                add("problem", "Your SurrounDead is on the wrong Steam branch:" + betaNote + " SurrounSync is made for \"" + BranchName(wantBeta) +
                    "\". The CO-OP tab may not show up, and players on different branches can't play together.",
                    betaFix + "Steam then downloads that version. Click Check again when it's done.");
            string want = Installer.PayloadText("made_for_build.txt"), have = Game.BuildId(game);
            long a, b;
            if (!string.IsNullOrEmpty(want) && long.TryParse(want, out a) && long.TryParse(have, out b) && a != b)
            {
                if (b < a)
                {
                    var x = add("problem", "Your SurrounDead is an OLDER version (build " + have + ") than this SurrounSync was made for (build " + want + ")." + betaNote +
                        " The CO-OP tab may not show up, and the game can crash when joining.",
                        (beta != wantBeta ? betaFix : "") + "FIX makes Steam check and update the game files. Then click Check again.");
                    x.Auto = "Ask Steam to update and verify SurrounDead"; x.Do = verify;
                }
                else
                    add("warning", "Your SurrounDead is NEWER (build " + have + ") than this SurrounSync was made for (build " + want + "). " +
                        "It usually works, but a game update can break parts of the mod.",
                        "If something doesn't work, check for a SurrounSync update (this window shows the newest release) and send a bug report.");
            }
            if (!Game.EngineOk(w64))
            {
                var x = add("problem", "Your SurrounDead program is an old version (Unreal " + Game.EngineOf(w64) + ") - SurrounSync needs the current game (Unreal " +
                    Game.Engine + ")." + betaNote + " Mods won't start, and pak mods made for the current game crash it while loading.",
                    (beta != wantBeta ? betaFix : "") + "FIX makes Steam check and update the game files. Then click Check again.");
                x.Auto = "Ask Steam to update and verify SurrounDead"; x.Do = verify;
            }
            int flags;
            string target = Acf(acf, "TargetBuildID"), buildid = Acf(acf, "buildid");
            if (int.TryParse(Acf(acf, "StateFlags") ?? "", out flags) && (flags & (2 | 32 | 128 | 256 | 512 | 1024)) != 0 ||
                !string.IsNullOrEmpty(target) && target != "0" && buildid != null && target != buildid)
            {
                var x = add("problem", "Steam hasn't finished updating SurrounDead (or found damaged game files).",
                    "Let Steam finish the update (Steam -> Downloads). FIX asks Steam to verify the game files.");
                x.Auto = "Ask Steam to finish and verify SurrounDead"; x.Do = verify;
            }
            string paks = Path.Combine(game, "SurrounDead", "Content", "Paks");
            if (!File.Exists(Path.Combine(paks, "SurrounDead-Windows.pak")))
            {
                var x = add("problem", "The game's main data file (SurrounDead-Windows.pak) is missing.", "FIX asks Steam to verify the game files.");
                x.Auto = "Ask Steam to verify SurrounDead"; x.Do = verify;
            }
            if (running) add("info", "SurrounDead is running.", "Close the game before you install, repair or uninstall (FIX waits for it).");

            // ---- UE4SS ----
            bool hasUe = File.Exists(Path.Combine(ue, "UE4SS.dll"));
            if (File.Exists(Path.Combine(w64, "UE4SS.dll")))
            {
                var x = add("problem", "An old UE4SS (version 2) is in the game folder - SurrounSync needs UE4SS 3.",
                    "FIX moves the old UE4SS files into a backup folder next to the game (nothing is deleted) and installs UE4SS 3.");
                x.Auto = "Move the old UE4SS 2 out of the way"; x.Repair = true;
                bool v3 = hasUe;
                x.Do = log => MoveOldUe4ss(w64, v3, log);
            }
            if (!hasUe) add("problem", "UE4SS (the mod loader) isn't installed.", "Click FIX (or INSTALL / REPAIR).").Repair = true;
            string ulog = hasUe ? Ue4ssLog(ue) : "";
            bool ours = hasUe && OursUe4ss(ue);
            string mine; Installer.ReadRecord().TryGetValue("ue4ss", out mine);
            // what the last game run's UE4SS.log says (only if it was written after this install)
            DateTime inst, logT = DateTime.MinValue;
            try { logT = File.GetLastWriteTime(Path.Combine(ue, "UE4SS.log")); } catch { }
            bool fresh = ulog != "" && !running && (!DateTime.TryParseExact(Installed() ?? "", "yyyy-MM-dd HH:mm", null,
                System.Globalization.DateTimeStyles.None, out inst) || logT > inst);
            bool scanFail = fresh && ulog.IndexOf("Scan attempt", StringComparison.OrdinalIgnoreCase) >= 0 &&
                            ulog.IndexOf("scan successful", StringComparison.OrdinalIgnoreCase) < 0;
            if (hasUe)
            {
                if (!File.Exists(Path.Combine(w64, "dwmapi.dll")))
                    add("problem", "UE4SS's starter file (dwmapi.dll) is missing - no mods load at all.",
                        "Click FIX. If it disappears again, your antivirus removed it: restore it from quarantine and allow it.").Repair = true;
                if (ours && mine == "ours" && (!File.Exists(Path.Combine(ue, "UE4SS-settings.ini")) ||
                    Installer.PayloadHas("game/ue4ss/UE4SS_Signatures/") && !Directory.Exists(Path.Combine(ue, "UE4SS_Signatures"))))
                {
                    var x = add("problem", "Some of UE4SS's files are missing.", "FIX puts SurrounSync's UE4SS back.");
                    x.Auto = "Reinstall UE4SS"; x.Do = log => new Installer { Log = log }.ReinstallUe4ss(game);
                }
                if (!ours)
                {
                    if (scanFail)
                    {
                        var x = add("problem", "UE4SS couldn't attach to the game in the last run - the UE4SS another mod brought doesn't fit this game version.",
                            "FIX swaps in SurrounSync's UE4SS: the old folder is kept as ue4ss-old-..., your other mods are copied over.");
                        x.Auto = "Swap in SurrounSync's UE4SS (the old one is kept)"; x.Repair = true;
                        x.Do = log => new Installer { Log = log }.SwapUe4ss(game);
                    }
                    else
                        add("warning", "A different UE4SS version is installed (another mod brought it). SurrounSync was tested with its own.",
                            "If the CO-OP tab is missing or the game crashes at start: rename the folder " + ue + " to ue4ss-old, click REPAIR, " +
                            "then copy your other mods from ue4ss-old\\Mods back into the new Mods folder. (FIX does this by itself once " +
                            "UE4SS's log shows it failing.)");
                }
                else if (scanFail)
                {
                    var x = add("problem", "UE4SS couldn't attach to the game in the last run - the game program doesn't match.",
                        "FIX asks Steam to verify the game files." + (beta != wantBeta ? " " + betaFix : ""));
                    x.Auto = "Ask Steam to verify SurrounDead"; x.Do = verify;
                }
            }

            // ---- SurrounSync's files and switches ----
            if (hasUe)
            {
                if (!File.Exists(Path.Combine(modDir, "Scripts", "main.lua")))
                    add("problem", "SurrounSync's files aren't in the game.", "Click FIX (or INSTALL / REPAIR).").Repair = true;
                else if (fresh && !scanFail && ulog.IndexOf("Starting Lua mod 'SurrounSync'", StringComparison.Ordinal) < 0)
                    add("problem", "SurrounSync didn't start in the last game run.", "Click FIX - it reinstalls and switches it on.").Repair = true;
                foreach (var left in new[] { Path.Combine(ue, "SurrounSync.new"), Path.Combine(ue, "SurrounSync.old"), Path.Combine(mods, "MirrorCoop") })
                    if (Directory.Exists(left) && !Installer.IsLink(left))
                        add("warning", "A half-finished update left " + left + " behind.", "Click FIX (it cleans it up).").Repair = true;
                string list = Path.Combine(mods, "mods.txt");
                string txt = ReadShared(list);
                if (txt != "" && !Regex.IsMatch(txt, "^\\s*SurrounSync\\s*:\\s*1\\s*$", RegexOptions.Multiline))
                    add("problem", "SurrounSync is switched off in UE4SS's mods.txt.", "Click FIX (it switches it on).").Repair = true;
                foreach (var c in Conflicts)
                    if (Regex.IsMatch(txt, "^\\s*" + c + "\\s*:\\s*1\\s*$", RegexOptions.Multiline))
                        add("problem", c + " is switched on - it's an older multiplayer mod and fights with SurrounSync.",
                            "Click FIX (it switches it off), or open " + list + " in Notepad and change \"" + c + " : 1\" to \"" + c + " : 0\".").Repair = true;
                // mods that switch themselves on with an enabled.txt (they never show in mods.txt)
                var self = new List<string>();
                try
                {
                    foreach (var d in Directory.GetDirectories(mods))
                    {
                        string n = Path.GetFileName(d);
                        if (n == "SurrounSync" || n == "shared" || !File.Exists(Path.Combine(d, "enabled.txt"))) continue;
                        if (Regex.IsMatch(txt, "^\\s*" + Regex.Escape(n) + "\\s*:", RegexOptions.Multiline)) continue;
                        if (Array.IndexOf(Conflicts, n) >= 0)
                        {
                            string en = Path.Combine(d, "enabled.txt");
                            var x = add("problem", n + " switches itself on (enabled.txt) - it's an older multiplayer mod and fights with SurrounSync.",
                                "FIX renames its enabled.txt to enabled.txt.off.");
                            x.Auto = "Switch off " + n;
                            x.Do = log => { File.Move(en, en + ".off"); log("Renamed " + en + " to enabled.txt.off."); return true; };
                        }
                        else self.Add(n);
                    }
                }
                catch { }
                if (self.Count > 0)
                    add("info", "Other mods running: " + string.Join(", ", self.ToArray()) + " (switched on by their own enabled.txt).",
                        "If co-op crashes or behaves oddly, try once without them: rename their enabled.txt to enabled.txt.off.");
                if (Directory.Exists(modDir) && !File.Exists(Path.Combine(modDir, "bridge", "SurrounSyncBridge.exe")))
                    add("problem", "The Steam connector (SurrounSyncBridge.exe) is missing - your antivirus probably removed it.",
                        "FIX puts it back. If it goes missing again, restore it from your antivirus' quarantine and add an exception for " +
                        Path.Combine(modDir, "bridge") + ".").Repair = true;
                string role = ReadShared(Path.Combine(w64, "mirror_role.txt")).Trim();
                if (role == "off") add("problem", "Co-op is switched off on this PC (mirror_role.txt says off).", "Click FIX.").Repair = true;
                string set = ReadShared(Path.Combine(w64, "mirror_settings.txt"));
                if (Regex.IsMatch(set, "^\\s*transport\\s*=\\s*file", RegexOptions.Multiline) && !Regex.IsMatch(set, "^\\s*devtest\\s*=\\s*on", RegexOptions.Multiline))
                    add("problem", "This PC is set to a one-PC test mode - it can't connect to friends over Steam.", "Click FIX (it sets Steam again).").Repair = true;
            }

            // ---- pak mods ----
            var pakMods = new List<string>();
            foreach (var sub in new[] { "~mods", "LogicMods" })
                try { foreach (var p in Directory.GetFiles(Path.Combine(paks, sub), "*.pak", SearchOption.AllDirectories)) pakMods.Add(sub + "\\" + p.Substring(Path.Combine(paks, sub).Length + 1)); }
                catch { }
            var tri = Report.Classify(w64);
            bool pakCrash = false;
            foreach (var r in tri.Reasons)
                if (r.StartsWith("Game crashed") && Regex.IsMatch(r, "BulkData|\\.pak|\\.ucas|\\.utoc|IoStore|corrupt|Serial", RegexOptions.IgnoreCase)) pakCrash = true;
            if (pakMods.Count > 0 && pakCrash && Game.EngineOk(w64))
            {
                var x = add("problem", "The last crash came from a game data file - most likely a pak mod made for another game version (" +
                    string.Join(", ", pakMods.ToArray()) + ").",
                    "FIX moves the pak mods into a folder next to them (nothing is deleted). Put them back one at a time to find the bad one.");
                x.Auto = "Move the pak mods out of the game's way";
                x.Do = log => MovePakMods(paks, log);
            }
            else if (pakMods.Count > 0)
                add("info", "Pak mods installed: " + string.Join(", ", pakMods.ToArray()) + ".",
                    "If the game crashes while loading after a game update, one of them is usually the cause.");

            // ---- Steam, disk ----
            if (Process.GetProcessesByName("steam").Length == 0)
            {
                var x = add("warning", "Steam isn't running.", "Start Steam and log in before you start SurrounDead - co-op goes through Steam. FIX starts it.");
                x.Auto = "Start Steam"; x.Do = log => { Process.Start("steam://open/main"); log("Started Steam - log in if it asks."); return true; };
            }
            try
            {
                var drive = new DriveInfo(Path.GetPathRoot(local));
                if (drive.AvailableFreeSpace < 2L * 1024 * 1024 * 1024)
                    add("warning", "Less than 2 GB free on drive " + drive.Name + " - saves and their backups live there.",
                        "Free up some space (empty the Recycle Bin, remove old downloads).");
            }
            catch { }

            // ---- saves ----
            string session = Path.Combine(saves, "mirror_coop_session.txt");
            bool open = File.Exists(session), bad = File.Exists(session + ".mirror-bad");
            if (open)
                add("info", "A co-op session wasn't finished (the game closed while you were in a friend's world).",
                    "Nothing to do: the next time you start the game, your character is brought home automatically.");
            if (bad)
                add("problem", "A damaged co-op session file was found, so SurrounSync left your co-op saves alone to be safe.",
                    "Click Bug report so the developer can help - your saves and their backups are untouched.");
            string cur = EmsCurrent();
            if (!open && !bad && IsCoopSlot(cur))
            {
                string own = NewestOwnSave(saves);
                var x = add("problem", "The game's Continue opens a co-op session save (" + cur + ") instead of your own world.",
                    own != null ? "FIX points Continue back at your newest own save (" + own + ")." : "Load your own save from Load Game once.");
                if (own != null) { x.Auto = "Point Continue at your own save"; x.Do = log => SetEmsCurrent(own, log); }
            }
            string backups = Path.Combine(local, "Saved", "SurrounSyncBackups");
            if (!open && !bad)
                try
                {
                    foreach (var d in Directory.GetDirectories(saves))
                    {
                        string n = Path.GetFileName(d);
                        if (!IsCoopSlot(n) || File.Exists(Path.Combine(d, CoopMarker))) continue;
                        if (!File.Exists(Path.Combine(d, "Player.sav")) && !File.Exists(Path.Combine(d, "Level.sav")) && !File.Exists(Path.Combine(d, "Slot.sav"))) continue;
                        bool kept = Directory.Exists(backups) && Directory.GetDirectories(backups, "rescued-" + n + "-*").Length > 0;
                        var x = add("warning", "The game saved progress into the co-op slot " + n + " (outside a co-op session), so SurrounSync won't empty it.",
                            (kept ? "A backup copy is in " + backups + ". " : "FIX makes a backup copy in " + backups + ". ") +
                            "Send a bug report so the developer can help you move it to a normal save.");
                        if (!kept) { string slot = n; x.Auto = "Back up the co-op slot " + n; x.Do = log => BackupSlot(saves, slot, backups, log); }
                    }
                }
                catch { }
            if (!LocalAlias.Ascii(local))
            {
                string alias = ReadShared(Path.Combine(w64, LocalAlias.FileName)).Trim();
                if (alias == "" || !Directory.Exists(alias))
                {
                    var x = add("problem", "Your Windows user name has letters the mod can't use in file paths, and its safe path to your saves is missing - " +
                        "saving, backups and joining fail.", "FIX makes the safe path again.");
                    x.Auto = "Make a safe path to your save folder";
                    x.Do = log =>
                    {
                        string how, made = LocalAlias.Ensure(w64, out how);
                        log(made != null ? "Saves are reached through " + made + " (" + how + ")." : "Couldn't make one (" + how + ").");
                        return made != null;
                    };
                }
            }
            var ro = ReadOnlyFiles(saves);
            string ems = EmsIni();
            if (File.Exists(ems) && (File.GetAttributes(ems) & FileAttributes.ReadOnly) != 0) ro.Add(ems);
            if (ro.Count > 0)
            {
                var x = add("problem", ro.Count + " save file(s) are read-only - the game can't save over them (first: " + ro[0] + ").", "FIX makes them writable again.");
                x.Auto = "Make the save files writable";
                x.Do = log => { foreach (var p in ro) File.SetAttributes(p, File.GetAttributes(p) & ~FileAttributes.ReadOnly); log("Fixed " + ro.Count + " file(s)."); return true; };
            }

            if (tri.Level == "CRITICAL" || tri.Level == "ERROR")
                add(tri.Level == "CRITICAL" ? "problem" : "warning", "Your last game run had trouble: " + string.Join("; ", tri.Reasons.ToArray()),
                    "Click Bug report - it goes straight to the developer. If the game crashed: close other big programs " +
                    "(browsers, Discord overlays), update your graphics driver, and verify the game files in Steam.");
            return f;
        }

        // ---- the automatic fixes ----
        static bool MoveOldUe4ss(string w64, bool hasV3, Action<string> log)
        {
            string bk = Path.Combine(w64, "UE4SS-2-backup-" + Stamp());
            Directory.CreateDirectory(bk);
            var names = new List<string> { "UE4SS.dll", "UE4SS-settings.ini", "UE4SS.log", "xinput1_3.dll", "UE4SS_Signatures", "Mods" };
            if (!hasV3) names.Add("dwmapi.dll");   // UE4SS 3 starts from its own dwmapi.dll; without it this one is UE4SS 2's
            foreach (var n in names)
            {
                string p = Path.Combine(w64, n);
                if (File.Exists(p)) File.Move(p, Path.Combine(bk, n));
                else if (Directory.Exists(p)) Directory.Move(p, Path.Combine(bk, n));
            }
            log("Moved the old UE4SS 2 files to " + bk + " (nothing deleted; its Lua mods are in there too).");
            return true;
        }

        static bool MovePakMods(string paks, Action<string> log)
        {
            string bk = Path.Combine(paks, "mods-off-" + Stamp());
            int n = 0;
            foreach (var sub in new[] { "~mods", "LogicMods" })
            {
                string from = Path.Combine(paks, sub);
                if (!Directory.Exists(from)) continue;
                foreach (var p in Directory.GetFiles(from, "*", SearchOption.AllDirectories))
                {
                    string ext = Path.GetExtension(p).ToLowerInvariant();
                    if (ext != ".pak" && ext != ".ucas" && ext != ".utoc" && ext != ".sig") continue;
                    string to = Path.Combine(bk, sub, p.Substring(from.Length + 1));
                    Directory.CreateDirectory(Path.GetDirectoryName(to));
                    File.Move(p, to);
                    n++;
                }
            }
            log("Moved " + n + " pak mod file(s) to " + bk + ".");
            return true;
        }

        public static string EmsIni() { return Path.Combine(LocalDir, "Saved", "Config", "Windows", "EmsUser.ini"); }
        public static string EmsCurrent()
        {
            var m = Regex.Match(ReadShared(EmsIni()), "^CurrentSaveGameName=(.*?)\\s*$", RegexOptions.Multiline);
            return m.Success ? m.Groups[1].Value : null;
        }
        static bool SetEmsCurrent(string slot, Action<string> log)
        {
            string ini = EmsIni();
            string s = File.ReadAllText(ini);
            s = Regex.Replace(s, "^CurrentSaveGameName=.*?(\\r?)$", "CurrentSaveGameName=" + slot.Replace("$", "$$") + "$1", RegexOptions.Multiline);
            File.WriteAllText(ini, s);
            log("Continue now opens " + slot + ".");
            return true;
        }

        // the own save (not a co-op slot) whose files were written last
        public static string NewestOwnSave(string saves)
        {
            string best = null; DateTime bt = DateTime.MinValue;
            try
            {
                foreach (var d in Directory.GetDirectories(saves))
                {
                    string n = Path.GetFileName(d);
                    if (IsCoopSlot(n) || !File.Exists(Path.Combine(d, "Player.sav"))) continue;
                    foreach (var p in Directory.GetFiles(d, "*.sav"))
                    {
                        var t = File.GetLastWriteTime(p);
                        if (t > bt) { bt = t; best = n; }
                    }
                }
            }
            catch { }
            return best;
        }

        static bool BackupSlot(string saves, string slot, string backups, Action<string> log)
        {
            string to = Path.Combine(backups, "rescued-" + slot + "-" + Stamp());
            Installer.CopyDir(Path.Combine(saves, slot), Path.Combine(to, slot));
            foreach (var p in Directory.GetFiles(saves, slot + "_*.sav")) File.Copy(p, Path.Combine(to, Path.GetFileName(p)));
            log("Copied " + slot + " to " + to + ".");
            return true;
        }

        static List<string> ReadOnlyFiles(string saves)
        {
            var l = new List<string>();
            try
            {
                foreach (var p in Directory.GetFiles(saves, "*.sav", SearchOption.AllDirectories))
                    if ((File.GetAttributes(p) & FileAttributes.ReadOnly) != 0 && p.IndexOf("SurrounSyncBackups", StringComparison.OrdinalIgnoreCase) < 0) l.Add(p);
            }
            catch { }
            return l;
        }

        public static int FixableCount(List<Finding> f)
        {
            int n = 0;
            foreach (var x in f) if (x.Kind != "info" && x.Fixable) n++;
            return n;
        }

        // FIX: every automatic fix the check found, then one REPAIR if any finding needs it, then a fresh check.
        public static List<Finding> FixAll(string game, Installer inst, Action<string, Color> say)
        {
            say("", UI.Text);
            say("FIXING", UI.Dim);
            if (Game.Running(game))
            {
                say("SurrounDead is running - close the game and FIX carries on by itself (nothing is changed while it runs)...", UI.Amber);
                while (Game.Running(game)) Thread.Sleep(1000);
                Thread.Sleep(3000);
            }
            bool repair = false; int tried = 0;
            foreach (var x in Check(game))
            {
                if (x.Repair) repair = true;
                if (x.Do == null) continue;
                tried++;
                say("> " + x.Auto, UI.Text);
                try { x.Do(s => say("   " + s, UI.Text)); }
                catch (Exception e) { say("   WARNING: that didn't work: " + e.Message, UI.Red); }
            }
            if (repair)
            {
                tried++;
                say("> Repair SurrounSync's files and switches", UI.Text);
                inst.Install(game);
            }
            if (tried == 0) say("Nothing here that FIX can do by itself.", UI.Dim);
            var after = Check(game);
            Print(after, say);
            return after;
        }

        public static bool Print(List<Finding> f, Action<string, Color> say)
        {
            say("", UI.Text);
            say("CHECKING YOUR SETUP", UI.Dim);
            bool fine = true;
            foreach (var x in f)
            {
                Color c = x.Kind == "problem" ? UI.Red : x.Kind == "warning" ? UI.Amber : UI.Dim;
                say((x.Kind == "problem" ? "PROBLEM: " : x.Kind == "warning" ? "CHECK: " : "NOTE: ") + x.What, c);
                say("   Fix: " + x.Fix, UI.Text);
                if (x.Kind == "problem") fine = false;
            }
            int n = FixableCount(f);
            if (f.Count == 0) say("Everything looks right.", UI.Green);
            else if (fine) say("Nothing stops co-op - see the notes above.", UI.Green);
            if (n > 0) say("Click FIX and SurrounSync Setup takes care of " + (n == 1 ? "it" : "the " + n + " fixable ones") + " for you.", UI.Green);
            return fine;
        }
    }

    class Flat : Button
    {
        public Color Back, Hover, Fore = Color.White;
        bool over;
        public Flat(string text, Color back, Color hover)
        {
            Text = text; Back = back; Hover = hover;
            FlatStyle = FlatStyle.Flat; FlatAppearance.BorderSize = 0; Cursor = Cursors.Hand;
            Font = new Font("Segoe UI Semibold", 10.5f); Height = 42;
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
        }
        protected override void OnMouseEnter(EventArgs e) { over = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { over = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Parent != null ? Parent.BackColor : BackColor);
            var r = new Rectangle(0, 0, Width - 1, Height - 1);
            using (var path = Round(r, 8))
            using (var b = new SolidBrush(!Enabled ? Color.FromArgb(48, 52, 50) : over ? Hover : Back)) g.FillPath(b, path);
            TextRenderer.DrawText(g, Text, Font, r, Enabled ? Fore : Color.FromArgb(120, 124, 122),
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);
        }
        public static GraphicsPath Round(Rectangle r, int rad)
        {
            var p = new GraphicsPath();
            p.AddArc(r.X, r.Y, rad * 2, rad * 2, 180, 90);
            p.AddArc(r.Right - rad * 2, r.Y, rad * 2, rad * 2, 270, 90);
            p.AddArc(r.Right - rad * 2, r.Bottom - rad * 2, rad * 2, rad * 2, 0, 90);
            p.AddArc(r.X, r.Bottom - rad * 2, rad * 2, rad * 2, 90, 90);
            p.CloseFigure();
            return p;
        }
    }

    class Bar : Control
    {
        int value;
        public int Value { get { return value; } set { this.value = Math.Max(0, Math.Min(100, value)); Invalidate(); } }
        public Bar() { SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true); Height = 6; }
        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.Clear(Color.FromArgb(38, 42, 40));
            int w = Width * value / 100;
            if (w > 0) using (var b = new LinearGradientBrush(new Rectangle(0, 0, Math.Max(1, w), Height), UI.Green, Color.FromArgb(170, 235, 160), 0f))
                    e.Graphics.FillRectangle(b, 0, 0, w, Height);
        }
    }

    static class UI
    {
        public static readonly Color Bg = Color.FromArgb(18, 21, 20);
        public static readonly Color Panel = Color.FromArgb(27, 31, 29);
        public static readonly Color Green = Color.FromArgb(108, 200, 110);
        public static readonly Color GreenHover = Color.FromArgb(132, 220, 130);
        public static readonly Color Grey = Color.FromArgb(52, 58, 55);
        public static readonly Color GreyHover = Color.FromArgb(70, 77, 73);
        public static readonly Color Text = Color.FromArgb(226, 230, 224);
        public static readonly Color Dim = Color.FromArgb(140, 148, 142);
        public static readonly Color Red = Color.FromArgb(214, 96, 86);
        public static readonly Color Amber = Color.FromArgb(232, 178, 72);
    }

    // Asks what went wrong before a bug report is made. Message is null when the player cancels.
    class ReportDialog : Form
    {
        public string Message;
        readonly TextBox box;

        public ReportDialog()
        {
            Text = "SurrounSync bug report";
            FormBorderStyle = FormBorderStyle.FixedDialog; MaximizeBox = false; MinimizeBox = false; ShowInTaskbar = false;
            StartPosition = FormStartPosition.CenterParent;
            ClientSize = new Size(520, 330);
            BackColor = UI.Bg; ForeColor = UI.Text; Font = new Font("Segoe UI", 9.5f);
            Controls.Add(new Label { Text = "ANYTHING ELSE TO ADD?", Left = 20, Top = 16, Width = 480, Height = 22, ForeColor = UI.Text,
                                     Font = new Font("Segoe UI Semibold", 11f), BackColor = Color.Transparent });
            Controls.Add(new Label { Text = "What happened, and what were you doing just before? (optional - logs are attached either way)",
                                     Left = 20, Top = 42, Width = 480, Height = 36, ForeColor = UI.Dim, BackColor = Color.Transparent });
            box = new TextBox { Left = 20, Top = 82, Width = 480, Height = 170, Multiline = true, AcceptsReturn = true,
                                ScrollBars = ScrollBars.Vertical, MaxLength = 1500, BackColor = UI.Panel, ForeColor = UI.Text,
                                BorderStyle = BorderStyle.FixedSingle, Font = new Font("Segoe UI", 10f) };
            Controls.Add(box);
            var send = new Flat("SEND", UI.Green, UI.GreenHover) { Left = 280, Top = 270, Width = 108, Fore = Color.FromArgb(14, 20, 15) };
            send.Font = new Font("Segoe UI Black", 10.5f);
            send.Click += delegate { Message = box.Text.Trim(); DialogResult = DialogResult.OK; Close(); };
            var cancel = new Flat("Cancel", UI.Grey, UI.GreyHover) { Left = 396, Top = 270, Width = 104 };
            cancel.Click += delegate { Message = null; DialogResult = DialogResult.Cancel; Close(); };
            Controls.AddRange(new Control[] { send, cancel });
            CancelButton = cancel;
            Shown += delegate { box.Focus(); };
        }

        public static string Ask(IWin32Window owner)
        {
            using (var d = new ReportDialog())
                return d.ShowDialog(owner) == DialogResult.OK ? (d.Message ?? "") : null;
        }
    }

    class SetupForm : Form
    {
        public const string Discord = "https://discord.gg/ghd92vCpe2";
        string reportMessage;
        readonly string mode; readonly bool waitGame;
        readonly string thisVersion = Installer.ThisVersion();
        TextBox gameBox; Label status, latestLabel, versions; Flat primary, uninstall, check, report, browse, fix; Bar bar; RichTextBox log;
        string latest; Release.Info latestInfo;
        static readonly Image logo = LoadLogo();
        static Image LoadLogo()
        {
            try { var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("logo.png"); return s != null ? Image.FromStream(s) : null; }
            catch { return null; }
        }
        bool busy;

        public SetupForm(string mode, bool waitGame, string game)
        {
            this.mode = mode; this.waitGame = waitGame;
            Text = "SurrounSync Setup";
            try { Icon = Icon.ExtractAssociatedIcon(Assembly.GetExecutingAssembly().Location); } catch { }
            FormBorderStyle = FormBorderStyle.FixedSingle; MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new Size(760, 560);
            BackColor = UI.Bg; ForeColor = UI.Text; Font = new Font("Segoe UI", 9.5f);
            DoubleBuffered = true;
            Build();
            gameBox.Text = game ?? Installer.InstalledGame() ?? Game.Find() ?? "";
            Shown += delegate
            {
                Refresh2(); primary.Focus(); CheckLatest(); Auto();
                string g0 = gameBox.Text.Trim();
                if (string.IsNullOrEmpty(this.mode) && Game.IsGame(g0) && Installer.InstalledVersion(g0) != null) Run("check");
            };
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
            using (var b = new LinearGradientBrush(new Rectangle(0, 0, ClientSize.Width, 118), Color.FromArgb(30, 40, 33), UI.Bg, 90f))
                g.FillRectangle(b, 0, 0, ClientSize.Width, 118);
            if (logo != null) { g.InterpolationMode = InterpolationMode.HighQualityBicubic; g.DrawImage(logo, 18, 15, 88, 88); }
            using (var f = new Font("Segoe UI Black", 26f))
                TextRenderer.DrawText(g, "SURROUNSYNC", f, new Point(118, 22), UI.Text);
            using (var f = new Font("Segoe UI", 10.5f))
                TextRenderer.DrawText(g, "Co-op for SurrounDead  ·  setup " + (thisVersion ?? "?"), f, new Point(122, 70), UI.Dim);
            using (var p = new Pen(Color.FromArgb(70, UI.Green), 2f) { DashStyle = DashStyle.Dash })
                g.DrawLine(p, 0, 117, ClientSize.Width, 117);
            base.OnPaint(e);
        }

        Label L(string text, int x, int y, int w, Color c, float size)
        {
            var l = new Label { Text = text, Left = x, Top = y, Width = w, Height = (int)(size * 2.4f), ForeColor = c, BackColor = Color.Transparent,
                                Font = new Font("Segoe UI", size), UseMnemonic = false };
            Controls.Add(l);
            return l;
        }

        void Build()
        {
            L("GAME FOLDER", 28, 136, 300, UI.Dim, 8.5f);
            gameBox = new TextBox { Left = 28, Top = 160, Width = 580, BackColor = UI.Panel, ForeColor = UI.Text, BorderStyle = BorderStyle.FixedSingle, Font = new Font("Segoe UI", 10.5f) };
            Controls.Add(gameBox);
            gameBox.TextChanged += delegate { if (!busy) Refresh2(); };
            browse = new Flat("Browse…", UI.Grey, UI.GreyHover) { Left = 620, Top = 156, Width = 112, Height = 34 };
            browse.Click += delegate
            {
                using (var d = new FolderBrowserDialog { Description = "Pick the SurrounDead folder (the one with SurrounDead.exe)" })
                    if (d.ShowDialog(this) == DialogResult.OK) gameBox.Text = d.SelectedPath;
            };
            Controls.Add(browse);
            status = L("", 28, 200, 560, UI.Text, 10.5f);
            latestLabel = L("", 28, 226, 560, UI.Dim, 9f);
            versions = L("", 28, 250, 704, UI.Dim, 9f);
            fix = new Flat("FIX", UI.Grey, UI.GreyHover) { Left = 600, Top = 202, Width = 132, Height = 42 };
            fix.Font = new Font("Segoe UI Black", 10.5f);
            fix.Click += delegate { Run("fix"); };
            Controls.Add(fix);

            primary = new Flat("INSTALL", UI.Green, UI.GreenHover) { Left = 28, Top = 288, Width = 236, Fore = Color.FromArgb(14, 20, 15) };
            primary.Font = new Font("Segoe UI Black", 11.5f);
            primary.Click += delegate { Run(primaryAction); };
            uninstall = new Flat("Uninstall", UI.Grey, UI.GreyHover) { Left = 276, Top = 288, Width = 112 };
            uninstall.Click += delegate
            {
                if (MessageBox.Show(this, "Remove SurrounSync from SurrounDead? Your saves and their backups stay.", "SurrounSync",
                    MessageBoxButtons.OKCancel, MessageBoxIcon.Question) == DialogResult.OK) Run("uninstall");
            };
            check = new Flat("Check", UI.Grey, UI.GreyHover) { Left = 400, Top = 288, Width = 104 };
            check.Click += delegate { Run("check"); };
            report = new Flat("Bug report", UI.Grey, UI.GreyHover) { Left = 516, Top = 288, Width = 120 };
            report.Click += delegate { AskAndReport(); };
            var logs = new Flat("Logs", UI.Grey, UI.GreyHover) { Left = 648, Top = 288, Width = 84 };
            logs.Click += delegate
            {
                string g = gameBox.Text.Trim();
                string dir = Game.IsGame(g) ? Game.Win64(g) : Release.AppDir;
                try { Process.Start("explorer.exe", "\"" + dir + "\""); } catch { }
            };
            Controls.AddRange(new Control[] { primary, uninstall, check, report, logs });

            var discord = new Flat("Join our Discord", Color.FromArgb(88, 101, 242), Color.FromArgb(110, 122, 250))
                          { Left = 560, Top = 38, Width = 172, Height = 38 };
            discord.Click += delegate { try { Process.Start(Discord); } catch { Say("Discord: " + Discord, UI.Text); } };
            Controls.Add(discord);

            bar = new Bar { Left = 28, Top = 344, Width = 704 };
            Controls.Add(bar);
            log = new RichTextBox { Left = 28, Top = 360, Width = 704, Height = 180, ReadOnly = true, BorderStyle = BorderStyle.None,
                                    BackColor = UI.Panel, ForeColor = UI.Text, Font = new Font("Consolas", 9.5f), DetectUrls = false };
            Controls.Add(log);
        }

        string primaryAction = "install";

        void Refresh2()
        {
            string g = gameBox.Text.Trim();
            bool ok = Game.IsGame(g);
            string inst = ok ? Installer.InstalledVersion(g) : null;
            if (!ok)
            {
                status.Text = g == "" ? "SurrounDead wasn't found - pick its folder with Browse." : "That folder isn't SurrounDead (no SurrounDead.exe inside).";
                status.ForeColor = UI.Red;
            }
            else if (inst == null) { status.Text = "SurrounSync isn't installed in this game yet."; status.ForeColor = UI.Text; }
            else
            {
                int c = Release.Compare(thisVersion, inst);
                status.Text = "Installed: SurrounSync " + inst + (c > 0 ? "  →  this setup has " + thisVersion : c == 0 ? "  (up to date with this setup)" : "  (newer than this setup)");
                status.ForeColor = UI.Text;
            }
            string act = inst == null ? "install" : Release.Compare(thisVersion, inst) > 0 ? "update" : "repair";
            primaryAction = act;
            primary.Text = act == "install" ? "INSTALL" : act == "update" ? "UPDATE TO " + thisVersion : "REPAIR / REINSTALL";
            primary.Enabled = ok && !busy;
            uninstall.Enabled = !busy && (inst != null || File.Exists(Installer.RecordFile));
            report.Enabled = !busy;
            check.Enabled = !busy;
            fix.Enabled = !busy && (ok || Game.Find() != null);
            browse.Enabled = !busy;
            versions.Text = ok ? Doctor.Versions(g) : "";
            ShowLatest(inst);
        }

        void ShowLatest(string inst)
        {
            if (latest == null) { latestLabel.Text = "Checking for the newest release…"; return; }
            if (latest == "") { latestLabel.Text = "Newest release: couldn't check (offline?)."; latestLabel.ForeColor = UI.Dim; return; }
            int c = Release.Compare(latest, thisVersion);
            latestLabel.Text = "Newest release: " + latest + (c > 0 ? " - newer than this setup. Click DOWNLOAD & INSTALL to get it." : " - this setup is current.");
            latestLabel.ForeColor = c > 0 ? UI.Green : UI.Dim;
            if (c > 0 && latestInfo != null && latestInfo.SetupUrl != null && !busy)
            {
                primaryAction = "download";
                primary.Text = "DOWNLOAD & INSTALL " + latest;
                primary.Enabled = true;
            }
        }

        void CheckLatest()
        {
            ThreadPool.QueueUserWorkItem(_ =>
            {
                string err;
                var info = Release.Latest(8000, out err);
                BeginInvoke((Action)delegate
                {
                    latestInfo = info;
                    latest = info != null ? info.Version : "";
                    if (info == null) Say("Release check: " + err, UI.Dim);
                    if (!busy) Refresh2();
                    if (mode == "update") Auto2();
                });
            });
        }

        void Auto()
        {
            if (mode == "install") Run("install");
            else if (mode == "uninstall")
            {
                if (MessageBox.Show(this, "Remove SurrounSync from SurrounDead? Your saves and their backups stay.", "SurrounSync",
                    MessageBoxButtons.OKCancel, MessageBoxIcon.Question) == DialogResult.OK) Run("uninstall");
            }
            else if (mode == "report") AskAndReport();
            else if (mode == "fix") Run("fix");
            else if (mode == "update") Say("Checking for an update…", UI.Text);
        }
        void Auto2()
        {
            string g = gameBox.Text.Trim();
            string inst = Game.IsGame(g) ? Installer.InstalledVersion(g) : null;
            if (latestInfo == null) { Say("Couldn't reach the release page - try again later.", UI.Red); return; }
            if (Release.Compare(latestInfo.Version, inst ?? "0") <= 0) { Say("SurrounSync " + inst + " is the newest version - nothing to update.", UI.Green); return; }
            if (Release.Compare(thisVersion, latestInfo.Version) >= 0) Run("install");
            else if (latestInfo.SetupUrl != null) Run("download");
            else Say("The newest release has no setup attached - get it from its page: " + latestInfo.PageUrl, UI.Red);
        }

        void Say(string s, Color c)
        {
            if (InvokeRequired) { BeginInvoke((Action)delegate { Say(s, c); }); return; }
            log.SelectionStart = log.TextLength; log.SelectionColor = c;
            log.AppendText(s + "\n");
            log.ScrollToCaret();
        }

        void AskAndReport()
        {
            if (busy) return;
            string msg = ReportDialog.Ask(this);
            if (msg == null) { Say("Bug report cancelled.", UI.Dim); return; }
            reportMessage = msg;
            Run("report");
        }

        void Run(string what)
        {
            if (busy) return;
            string g = gameBox.Text.Trim();
            if (what == "fix" && !Game.IsGame(g) && Game.Find() != null)
            {
                g = Game.Find();
                gameBox.Text = g;
                Say("Found SurrounDead in " + g + ".", UI.Text);
            }
            if ((what == "install" || what == "update" || what == "repair" || what == "fix") && Game.IsGame(g) && !Installer.CanWrite(Game.Win64(g)))
            {
                // (the in-game UPDATE button: keep waiting for the game to close, or the install hits its locked files)
                if (Program.Elevate((what == "fix" ? "--fix" : "--install") + " --game \"" + g + "\"" + (waitGame ? " --wait-game" : ""))) { Close(); return; }
                Say("No permission to write into the game folder, and administrator rights weren't given.", UI.Red);
                return;
            }
            busy = true; Refresh2(); bar.Value = 0;
            var inst = new Installer();
            inst.Log = s => Say(s, s.StartsWith("WARNING") ? UI.Red : UI.Text);
            inst.Progress = p => BeginInvoke((Action)delegate { bar.Value = p; });
            var th = new Thread(() =>
            {
                bool ok = false;
                try
                {
                    if (what == "uninstall") ok = inst.Uninstall(Game.IsGame(g) ? g : null);
                    else if (what == "report") ok = MakeReport(g, inst.Log, reportMessage);
                    else if (what == "check") { var found = Doctor.Check(g); ok = Doctor.Print(found, Say); ShowFixable(found); }
                    else if (what == "fix") { var found = Doctor.FixAll(g, inst, Say); ShowFixable(found); ok = true; }
                    else if (what == "download") ok = DownloadAndRun(g, inst.Log, inst.Progress);
                    else
                    {
                        if (waitGame && Game.IsGame(g) && Game.Running(g))
                        {
                            inst.Log("The update installs when SurrounDead is closed - waiting for the game to close…");
                            while (Game.Running(g)) Thread.Sleep(1000);
                            Thread.Sleep(2000);
                        }
                        ok = inst.Install(g);
                        if (ok) { var found = Doctor.Check(g); Doctor.Print(found, Say); ShowFixable(found); }
                        if (ok) Say("Questions, help or a co-op partner: join the SurrounSync Discord - " + Discord, UI.Green);
                    }
                }
                catch (Exception e) { inst.Log("WARNING: " + e.Message); }
                BeginInvoke((Action)delegate
                {
                    busy = false; Refresh2();
                    if (what == "download" && ok) Close();
                    else if (what == "uninstall" && ok) { primary.Enabled = false; }
                    if (!ok && what != "report" && what != "check" && what != "fix") Say("Nothing more was changed.", UI.Dim);
                });
            });
            th.IsBackground = true;
            th.Start();
        }

        // the FIX button turns amber with the number of problems it can fix
        void ShowFixable(List<Finding> found)
        {
            if (InvokeRequired) { BeginInvoke((Action)delegate { ShowFixable(found); }); return; }
            int n = Doctor.FixableCount(found);
            fix.Text = n > 0 ? "FIX " + n + (n == 1 ? " PROBLEM" : " PROBLEMS") : "FIX";
            fix.Back = n > 0 ? UI.Amber : UI.Grey; fix.Hover = n > 0 ? Color.FromArgb(244, 196, 100) : UI.GreyHover;
            fix.Fore = n > 0 ? Color.FromArgb(20, 16, 8) : Color.White;
            fix.Invalidate();
        }

        bool DownloadAndRun(string g, Action<string> say, Action<int> progress)
        {
            say("Downloading SurrounSync " + latestInfo.Version + "…");
            string tmp = Path.Combine(Path.GetTempPath(), "SurrounSyncSetup-" + latestInfo.Version + ".exe");
            string err;
            if (!Release.Download(latestInfo.SetupUrl, tmp, progress, out err)) { say("WARNING: download failed: " + err); return false; }
            say("Starting the new setup…");
            Process.Start(new ProcessStartInfo(tmp, "--install --game \"" + g + "\"" + (waitGame ? " --wait-game" : ""))
            { UseShellExecute = true });
            return true;
        }

        public static bool MakeReport(string g, Action<string> say) { return MakeReport(g, say, null); }

        public static bool MakeReport(string g, Action<string> say, string message)
        {
            string err;
            string zip = Report.Create(Game.IsGame(g) ? Game.Win64(g) : null, out err, false, message);
            if (zip == null) { say("WARNING: couldn't save the bug report: " + err); return false; }
            say("Bug report saved: " + zip);
            if (Report.CanSend)
            {
                say("Sending it to the SurrounSync developer...");
                string serr;
                if (Report.Send(zip, Game.IsGame(g) ? Game.Win64(g) : null, out serr))
                {
                    say(string.IsNullOrEmpty(message) ? "Sent - the developer has it. Tell them what you were doing when it went wrong."
                                                      : "Sent with your message - the developer has it.");
                    return true;
                }
                say("WARNING: couldn't send it (" + serr + ").");
            }
            say("Send this zip to the SurrounSync developer, with what you were doing when it went wrong.");
            try { Process.Start("explorer.exe", "/select,\"" + zip + "\""); } catch { }
            return true;
        }
    }

    static class Program
    {
        [STAThread]
        static int Main(string[] args)
        {
            string mode = "", game = null; bool quiet = false, wait = false;
            for (int i = 0; i < args.Length; i++)
            {
                string a = args[i].ToLowerInvariant();
                if (a == "--install" || a == "--update" || a == "--uninstall" || a == "--report" || a == "--check" || a == "--fix") mode = a.Substring(2);
                else if (a == "--game" && i + 1 < args.Length) game = args[++i];
                else if (a == "--quiet") quiet = true;
                else if (a == "--wait-game") wait = true;
                else if (a == "--no-pds") { }  // older setups/updaters still pass it
                else if (a == "--version") { Console.WriteLine(Installer.ThisVersion() ?? "?"); return 0; }
            }
            if (quiet) return Quiet(mode, game, wait);
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new SetupForm(mode, wait, game));
            return 0;
        }

        static int Quiet(string mode, string game, bool wait)
        {
            Directory.CreateDirectory(Release.AppDir);
            var logFile = Path.Combine(Release.AppDir, "setup.log");
            File.WriteAllText(logFile, "SurrounSyncSetup " + (Installer.ThisVersion() ?? "?") + " " + mode + " " + DateTime.Now + "\r\n");
            var inst = new Installer();
            inst.Log = s => { try { File.AppendAllText(logFile, s + "\r\n"); } catch { } Console.WriteLine(s); };
            game = game ?? Installer.InstalledGame() ?? Game.Find();
            try
            {
                if (mode == "uninstall") return inst.Uninstall(game) ? 0 : 1;
                if (mode == "report") return SetupForm.MakeReport(game ?? "", inst.Log) ? 0 : 1;
                if (mode == "check") return Doctor.Print(Doctor.Check(game ?? ""), (t, c) => inst.Log(t)) ? 0 : 1;
                if (game == null) { inst.Log("SurrounDead wasn't found - pass --game <folder>."); return 2; }
                if (mode == "fix") { var after = Doctor.FixAll(game, inst, (t, c) => inst.Log(t)); return Doctor.FixableCount(after) == 0 ? 0 : 1; }
                if (wait) while (Game.Running(game)) Thread.Sleep(1000);
                if (!inst.Install(game)) return 1;
                Doctor.Print(Doctor.Check(game), (t, c) => inst.Log(t));
                return 0;
            }
            catch (Exception e) { inst.Log("FAILED: " + e); return 3; }
        }

        public static bool Elevate(string args)
        {
            try
            {
                Process.Start(new ProcessStartInfo(Assembly.GetExecutingAssembly().Location, args) { UseShellExecute = true, Verb = "runas" });
                return true;
            }
            catch { return false; }
        }
    }
}
