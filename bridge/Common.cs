// Shared by the bridge and the setup: finding the game, release info, and bug reports.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace SurrounSyncShared
{
    public static class Release
    {
        public const string Repo = "SYMPLYSCK/SurrounSync";
        public const string SetupName = "SurrounSyncSetup.exe";

        public static string AppDir
        {
            get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SurrounSync"); }
        }

        public static string SourceUrl()
        {
            try
            {
                string f = Path.Combine(AppDir, "update_source.txt");
                if (File.Exists(f))
                {
                    string s = File.ReadAllText(f).Trim();
                    if (s.StartsWith("http://") || s.StartsWith("https://")) return s;
                }
            }
            catch { }
            return "https://api.github.com/repos/" + Repo + "/releases/latest";
        }

        public class Info
        {
            public string Version;
            public string SetupUrl;
            public string PageUrl;
            public string Notes;
        }

        public static Info Latest(int timeoutMs, out string error)
        {
            error = null;
            try
            {
                ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
                var req = (HttpWebRequest)WebRequest.Create(SourceUrl());
                req.UserAgent = "SurrounSync-Updater";
                req.Accept = "application/vnd.github+json";
                req.Timeout = timeoutMs; req.ReadWriteTimeout = timeoutMs;
                string json;
                using (var resp = req.GetResponse())
                using (var r = new StreamReader(resp.GetResponseStream(), Encoding.UTF8)) json = r.ReadToEnd();
                var info = new Info();
                info.Version = Clean(Field(json, "tag_name"));
                info.PageUrl = Field(json, "html_url");
                info.Notes = Field(json, "body");
                var m = Regex.Match(json, "\"browser_download_url\"\\s*:\\s*\"([^\"]*" + Regex.Escape(SetupName) + ")\"");
                if (m.Success) info.SetupUrl = m.Groups[1].Value;
                if (string.IsNullOrEmpty(info.Version)) { error = "no version in the release"; return null; }
                return info;
            }
            catch (WebException e)
            {
                var hr = e.Response as HttpWebResponse;
                error = hr != null && hr.StatusCode == HttpStatusCode.NotFound ? "no release published yet" : e.Message;
                return null;
            }
            catch (Exception e) { error = e.Message; return null; }
        }

        static string Field(string json, string key)
        {
            var m = Regex.Match(json, "\"" + key + "\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"");
            if (!m.Success) return null;
            return Regex.Unescape(m.Groups[1].Value);
        }

        public static string Clean(string v)
        {
            if (v == null) return null;
            v = v.Trim();
            if (v.StartsWith("v") || v.StartsWith("V")) v = v.Substring(1);
            return v;
        }

        public static int Compare(string a, string b)
        {
            a = Clean(a) ?? ""; b = Clean(b) ?? "";
            string pa = "", pb = "";
            int i = a.IndexOf('-'); if (i >= 0) { pa = a.Substring(i + 1); a = a.Substring(0, i); }
            i = b.IndexOf('-'); if (i >= 0) { pb = b.Substring(i + 1); b = b.Substring(0, i); }
            var x = a.Split('.'); var y = b.Split('.');
            for (int k = 0; k < Math.Max(x.Length, y.Length); k++)
            {
                int u = 0, w = 0;
                if (k < x.Length) int.TryParse(x[k], out u);
                if (k < y.Length) int.TryParse(y[k], out w);
                if (u != w) return u < w ? -1 : 1;
            }
            if (pa == pb) return 0;
            if (pa == "") return 1;
            if (pb == "") return -1;
            return string.CompareOrdinal(pa, pb);
        }

        public static string ModVersion(string modDir) { return VersionField(modDir, "VERSION"); }
        public static string ModProtocol(string modDir) { return VersionField(modDir, "PROTOCOL"); }
        static string VersionField(string modDir, string key)
        {
            try
            {
                string f = Path.Combine(modDir, "Scripts", "mirror", "version.lua");
                if (!File.Exists(f)) return null;
                var m = Regex.Match(File.ReadAllText(f), key + "\\s*=\\s*\"?([0-9A-Za-z.\\-]+)\"?");
                return m.Success ? m.Groups[1].Value : null;
            }
            catch { return null; }
        }

        public static bool Download(string url, string path, Action<int> progress, out string error)
        {
            error = null;
            try
            {
                ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
                var req = (HttpWebRequest)WebRequest.Create(url);
                req.UserAgent = "SurrounSync-Updater";
                req.Timeout = 30000; req.ReadWriteTimeout = 30000;
                using (var resp = req.GetResponse())
                using (var src = resp.GetResponseStream())
                using (var dst = File.Create(path))
                {
                    long total = resp.ContentLength, done = 0;
                    var buf = new byte[65536];
                    int n;
                    while ((n = src.Read(buf, 0, buf.Length)) > 0)
                    {
                        dst.Write(buf, 0, n);
                        done += n;
                        if (progress != null && total > 0) progress((int)(done * 100 / total));
                    }
                }
                return true;
            }
            catch (Exception e) { error = e.Message; try { File.Delete(path); } catch { } return false; }
        }
    }

    public static class Game
    {
        public const string AppId = "1645820";
        public const string Exe = "SurrounDead-Win64-Shipping.exe";
        // Engine the mod (and its UE4SS signatures and bundled pak) are made for.
        public const string Engine = "5.6";

        public static string EngineOf(string win64)
        {
            try
            {
                var v = FileVersionInfo.GetVersionInfo(Path.Combine(win64, Exe));
                return v.FileMajorPart + "." + v.FileMinorPart + "." + v.FileBuildPart;
            }
            catch { return null; }
        }

        public static bool EngineOk(string win64)
        {
            string e = EngineOf(win64);
            return e == null || e.StartsWith(Engine + ".");
        }

        public static string Win64(string game) { return Path.Combine(game, "SurrounDead", "Binaries", "Win64"); }
        public static bool IsGame(string game)
        {
            return !string.IsNullOrEmpty(game) && File.Exists(Path.Combine(Win64(game), Exe));
        }

        public static string Find()
        {
            var roots = new List<string>();
            foreach (var k in new[] { @"HKEY_CURRENT_USER\Software\Valve\Steam", @"HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Valve\Steam" })
            {
                foreach (var v in new[] { "SteamPath", "InstallPath" })
                {
                    try { var s = Registry.GetValue(k, v, null) as string; if (!string.IsNullOrEmpty(s)) roots.Add(s.Replace('/', '\\')); }
                    catch { }
                }
            }
            roots.Add(@"C:\Program Files (x86)\Steam");
            var libs = new List<string>();
            foreach (var r in roots)
            {
                if (!libs.Contains(r)) libs.Add(r);
                try
                {
                    string vdf = Path.Combine(r, "steamapps", "libraryfolders.vdf");
                    if (!File.Exists(vdf)) continue;
                    foreach (Match m in Regex.Matches(File.ReadAllText(vdf), "\"path\"\\s+\"([^\"]+)\""))
                    {
                        string p = m.Groups[1].Value.Replace("\\\\", "\\");
                        if (!libs.Contains(p)) libs.Add(p);
                    }
                }
                catch { }
            }
            foreach (var l in libs)
            {
                string g = Path.Combine(l, "steamapps", "common", "SurrounDead");
                if (IsGame(g)) return g;
            }
            return null;
        }

        public static string BuildId(string game)
        {
            try
            {
                string mf = Path.Combine(Path.GetDirectoryName(Path.GetDirectoryName(game)), "appmanifest_" + AppId + ".acf");
                var m = Regex.Match(File.ReadAllText(mf), "\"buildid\"\\s+\"(\\d+)\"");
                return m.Success ? m.Groups[1].Value : "?";
            }
            catch { return "?"; }
        }

        public static bool Running(string game)
        {
            string exe = Path.Combine(Win64(game), Exe);
            foreach (var p in Process.GetProcessesByName(Path.GetFileNameWithoutExtension(Exe)))
            {
                try { if (string.Equals(p.MainModule.FileName, exe, StringComparison.OrdinalIgnoreCase)) return true; }
                catch { return true; }
            }
            return false;
        }
    }

    public static class Report
    {
        public static string Create(string win64, out string error) { return Create(win64, out error, false, null); }
        public static string Create(string win64, out string error, bool lite) { return Create(win64, out error, lite, null); }

        public static string OutDir;   // tests: where report zips go instead of the desktop

        // message = what the player typed into the bug report box (kept as message.txt in the zip and shown with the post)
        public static string Create(string win64, out string error, bool lite, string message)
        {
            error = null;
            try
            {
                if (win64 == null || !File.Exists(Path.Combine(win64, Game.Exe)))
                {
                    string g = Game.Find();
                    win64 = g != null ? Game.Win64(g) : null;
                }
                string desk = OutDir ?? Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
                if (string.IsNullOrEmpty(desk) || !Directory.Exists(desk)) desk = Release.AppDir;
                Directory.CreateDirectory(desk);
                string zip = lite ? Path.Combine(Path.GetTempPath(), "SurrounSync-report-small.zip")
                    : Path.Combine(desk, "SurrounSync-report-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".zip");
                tail = lite ? 3 * 1024 * 1024 : 0;
                string local = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SurrounDead");
                using (var fs = new FileStream(zip, FileMode.Create))
                using (var z = new ZipArchive(fs, ZipArchiveMode.Create))
                {
                    message = string.IsNullOrEmpty(message) || message.Trim() == "" ? null : Diagnose.Scrub(message.Trim());
                    Add(z, "report.txt", Encoding.UTF8.GetBytes(Diagnose.Scrub(Summary(win64, local, message))));
                    if (message != null)
                        Add(z, "message.txt", Encoding.UTF8.GetBytes(message));
                    if (win64 != null)
                    {
                        foreach (var n in new[] { "mirror_log.txt", "mirror_log.1.txt", "mirror_log.2.txt", "mirror_step.txt", "mirror_step.1.txt", "mirror_settings.txt", "mirror_role.txt" })
                            if (!(lite && n == "mirror_log.2.txt")) AddFile(z, Path.Combine(win64, n), "game/" + n);
                        AddFile(z, Path.Combine(win64, "ue4ss", "UE4SS.log"), "game/UE4SS.log");
                        AddFile(z, Path.Combine(win64, "ue4ss", "Mods", "mods.txt"), "game/mods.txt");
                        AddFile(z, Path.Combine(win64, "ue4ss", "UE4SS-settings.ini"), "game/UE4SS-settings.ini");
                    }
                    try { foreach (var f in Directory.GetFiles(local, "mirror_bridge*.log")) AddFile(z, f, "connector/" + Path.GetFileName(f)); }
                    catch { }
                    AddFile(z, Path.Combine(local, "Saved", "Logs", "SurrounDead.log"), "game/SurrounDead.log");
                    string crash = NewestCrash(local);
                    if (crash != null)
                        foreach (var f in Directory.GetFiles(crash))
                        {
                            var fi = new FileInfo(f);
                            if (fi.Length < 8 * 1024 * 1024 && !(lite && fi.Extension.ToLowerInvariant() == ".dmp")) AddFile(z, f, "crash/" + fi.Name);
                        }
                }
                return zip;
            }
            catch (Exception e) { error = e.Message; return null; }
        }

        public sealed class Triage { public string Level = "INFO"; public int Color = 0x43A047; public List<string> Reasons = new List<string>(); }

        static readonly string[] SaveAlarms = {
            "slotguard: refused", "couldn't copy the character home", "GHOST ActorPreSave", "GHOST ActorLoaded",
            "did NOT save", "unreadable session log", "session log - nothing was done", "was NOT copied over it",
        };
        static readonly string[] SaveNotes = { "session: firewall", "co-op character not applied" };

        public static Triage Classify(string win64)
        {
            var t = new Triage();
            int errors = 0, warns = 0, alarms = 0, notes = 0;
            string firstError = null, firstAlarm = null;
            if (win64 != null)
                foreach (var line in ReadLines(Path.Combine(win64, "mirror_log.txt")))
                {
                    if (line.Contains("[ERROR]") || line.Contains("safe() caught")) { errors++; if (firstError == null) firstError = line; }
                    else if (line.Contains("[WARN]")) warns++;
                    foreach (var a in SaveAlarms) if (line.Contains(a)) { alarms++; if (firstAlarm == null) firstAlarm = line; break; }
                    foreach (var n in SaveNotes) if (line.Contains(n)) { notes++; break; }
                }
            string local = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SurrounDead");
            string crash = NewestCrash(local);
            bool crashed = false;
            if (crash != null)
            {
                var when = Directory.GetLastWriteTime(crash);
                if ((DateTime.Now - when).TotalHours < 3)
                {
                    crashed = true;
                    string msg = "";
                    try
                    {
                        var m = Regex.Match(File.ReadAllText(Path.Combine(crash, "CrashContext.runtime-xml")), "<ErrorMessage>([^<]*)</ErrorMessage>");
                        if (m.Success) msg = ": " + m.Groups[1].Value.Trim();
                    }
                    catch { }
                    if (msg.Length > 220) msg = msg.Substring(0, 220) + "...";
                    t.Reasons.Add("Game crashed at " + when.ToString("HH:mm") + msg);
                }
            }
            if (alarms > 0) t.Reasons.Add("Save safety acted " + alarms + "x - first: " + Short(firstAlarm));
            if (notes > 0) t.Reasons.Add("Save protection redirected or kept something " + notes + "x (worked as designed - check why)");
            if (errors > 0) t.Reasons.Add(errors + " mod error(s) this run - first: " + Short(firstError));
            if (warns > 0) t.Reasons.Add(warns + " warning(s) this run");
            if (crashed || alarms > 0) { t.Level = "CRITICAL"; t.Color = 0xE53935; }
            else if (errors > 0) { t.Level = "ERROR"; t.Color = 0xFB8C00; }
            else if (warns > 0 || notes > 0) { t.Level = "MINOR"; t.Color = 0xFDD835; }
            else t.Reasons.Add("No errors or crashes in the logs - the player saw something the logs don't show");
            return t;
        }

        static string Short(string line)
        {
            if (line == null) return "";
            int i = line.IndexOf("] ", StringComparison.Ordinal);
            string s = (i >= 0 ? line.Substring(i + 2) : line).Trim();
            return s.Length > 200 ? s.Substring(0, 200) + "..." : s;
        }

        static string Reporter()
        {
            try
            {
                string f = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SurrounDead", "mirror_lobby.txt");
                foreach (var line in File.ReadAllLines(f))
                {
                    var m = Regex.Match(line, "^me (\\d+) \\S+ (.+)$");
                    if (m.Success) return m.Groups[2].Value.Trim() + " (" + m.Groups[1].Value + ")";
                }
            }
            catch { }
            return "";
        }

        static string NewestCrash(string local)
        {
            try
            {
                string dir = Path.Combine(local, "Saved", "Crashes");
                if (!Directory.Exists(dir)) return null;
                string best = null; DateTime t = DateTime.MinValue;
                foreach (var d in Directory.GetDirectories(dir))
                {
                    var w = Directory.GetLastWriteTime(d);
                    if (w > t) { t = w; best = d; }
                }
                return best;
            }
            catch { return null; }
        }

        static string Summary(string win64, string local, string message)
        {
            var sb = new StringBuilder();
            sb.AppendLine("SurrounSync bug report - " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
            sb.AppendLine("Send this zip to the SurrounSync developer along with what you were doing when it went wrong.");
            sb.AppendLine();
            try { sb.Append(Diagnose.Text(Diagnose.Run(win64, local), message)); }
            catch (Exception e) { sb.AppendLine("(diagnosis failed: " + e.Message + ")"); }
            sb.AppendLine();
            sb.AppendLine("==================== SYSTEM DETAILS ====================");
            var tri = Classify(win64);
            sb.AppendLine("Severity: " + tri.Level);
            foreach (var r in tri.Reasons) sb.AppendLine("  - " + r);
            string who = Reporter();
            if (who != "") sb.AppendLine("From: " + who);
            sb.AppendLine();
            string mod = win64 != null ? Path.Combine(win64, "ue4ss", "Mods", "SurrounSync") : null;
            sb.AppendLine("SurrounSync: " + (Release.ModVersion(mod) ?? "?") + " (protocol " + (Release.ModProtocol(mod) ?? "?") + ")");
            string game = win64 != null ? Path.GetFullPath(Path.Combine(win64, "..", "..", "..")) : null;
            sb.AppendLine("Game: " + (game ?? "?") + " (Steam build " + (game != null ? Game.BuildId(game) : "?") + ")");
            string ue4ss = win64 != null ? Path.Combine(win64, "ue4ss", "UE4SS.dll") : null;
            string uv = "missing";
            try { if (ue4ss != null && File.Exists(ue4ss)) uv = FileVersionInfo.GetVersionInfo(ue4ss).FileVersion ?? "present"; } catch { }
            sb.AppendLine("UE4SS: " + uv);
            if (win64 != null)
            {
                string eng = Game.EngineOf(win64);
                long size = 0;
                try { size = new FileInfo(Path.Combine(win64, Game.Exe)).Length; } catch { }
                sb.AppendLine("Game program: Unreal " + (eng ?? "?") + ", " + size + " bytes" + (Game.EngineOk(win64) ? "" :
                    "  <-- NOT the current game (needs Unreal " + Game.Engine + "): mismatched game files. Verify the game files in Steam."));
                string ul = ReadText(Path.Combine(win64, "ue4ss", "UE4SS.log"));
                if (ul != null && (ul.Contains("Fatal Error") || ul.Contains("AOB scans could not be completed")))
                    sb.AppendLine("UE4SS start: FAILED (" + (ul.Contains("Found EngineVersion: " + Game.Engine) ? "signature scan" : "game version not supported") +
                        ") - no mods ran in that game run");
                sb.AppendLine(@"Pak mods (Content\Paks\~mods, LogicMods):");
                int paks = 0;
                foreach (var sub in new[] { "~mods", "LogicMods" })
                    try
                    {
                        string d = Path.Combine(game, "SurrounDead", "Content", "Paks", sub);
                        if (!Directory.Exists(d)) continue;
                        foreach (var f in Directory.GetFiles(d, "*.pak", SearchOption.AllDirectories))
                        {
                            var fi = new FileInfo(f);
                            sb.AppendLine("  " + sub + "\\" + f.Substring(d.Length + 1) + " (" + fi.Length + " bytes, " + fi.LastWriteTime.ToString("yyyy-MM-dd") + ")");
                            paks++;
                        }
                    }
                    catch { }
                if (paks == 0) sb.AppendLine("  none");
            }
            sb.AppendLine("Windows: " + WindowsName() + " (" + (Environment.Is64BitOperatingSystem ? "64" : "32") + "-bit)");
            sb.AppendLine("Memory: " + MemoryText());
            sb.AppendLine("Steam running: " + (Process.GetProcessesByName("steam").Length > 0 ? "yes" : "no"));
            sb.AppendLine("Game running: " + (Process.GetProcessesByName("SurrounDead-Win64-Shipping").Length > 0 ? "yes" : "no"));
            sb.AppendLine();
            if (win64 != null)
            {
                sb.AppendLine("Enabled UE4SS mods:");
                try
                {
                    foreach (var line in File.ReadAllLines(Path.Combine(win64, "ue4ss", "Mods", "mods.txt")))
                    {
                        var m = Regex.Match(line, "^\\s*([^;:#]+?)\\s*:\\s*1\\s*$");
                        if (m.Success) sb.AppendLine("  " + m.Groups[1].Value);
                    }
                }
                catch { sb.AppendLine("  (mods.txt not readable)"); }
                sb.AppendLine();
                sb.AppendLine("Problems in the last game run (mirror_log.txt):");
                int errors = 0, warns = 0;
                var last = new List<string>();
                foreach (var line in ReadLines(Path.Combine(win64, "mirror_log.txt")))
                {
                    bool e = line.Contains("[ERROR]") || line.Contains("safe() caught");
                    bool w = line.Contains("[WARN]");
                    if (e) errors++; else if (w) warns++;
                    if (e || w) { last.Add(line); if (last.Count > 40) last.RemoveAt(0); }
                }
                sb.AppendLine("  " + errors + " error(s), " + warns + " warning(s)" + (last.Count > 0 ? " - the last " + last.Count + ":" : ""));
                foreach (var l in last) sb.AppendLine("  " + l);
            }
            sb.AppendLine();
            string crash = NewestCrash(local);
            if (crash != null)
            {
                sb.AppendLine("Newest game crash: " + Directory.GetLastWriteTime(crash).ToString("yyyy-MM-dd HH:mm") + " (" + Path.GetFileName(crash) + ")");
                try
                {
                    var ctx = Path.Combine(crash, "CrashContext.runtime-xml");
                    string xml = File.ReadAllText(ctx);
                    var m = Regex.Match(xml, "<ErrorMessage>([^<]*)</ErrorMessage>");
                    if (m.Success) sb.AppendLine("  " + m.Groups[1].Value.Trim());
                    var en = Regex.Match(xml, "<EngineVersion>([^<]*)</EngineVersion>");
                    if (en.Success) sb.AppendLine("  engine at crash: " + en.Groups[1].Value.Trim());
                    var cs = Regex.Match(xml, @"<CallStack>([^<\s]*)");
                    if (cs.Success) sb.AppendLine("  crashed in: " + cs.Groups[1].Value.Trim() +
                        (cs.Groups[1].Value.StartsWith("UE4SS") ? " (a script mod's call - SurrounSync or another UE4SS mod)" : " (the game itself)"));
                }
                catch { }
                try
                {
                    // mirror_step*.txt = the mod step running when that run ended; use the run that ended at the crash
                    DateTime at = Directory.GetLastWriteTime(crash);
                    foreach (var n in new[] { "mirror_step.txt", "mirror_step.1.txt" })
                    {
                        string p = Path.Combine(win64, n);
                        if (!File.Exists(p)) continue;
                        double gap = (at - File.GetLastWriteTime(p)).TotalSeconds;
                        if (gap < -5 || gap > 600) continue;
                        sb.AppendLine("  SurrounSync step at the crash: " + File.ReadAllText(p).Trim() + " (" + n + ")");
                        break;
                    }
                }
                catch { }
            }
            else sb.AppendLine("No game crash reports.");
            return sb.ToString();
        }

        static string WindowsName()
        {
            const string K = @"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion";
            try
            {
                string name = (Registry.GetValue(K, "ProductName", "Windows") as string) ?? "Windows";
                string build = (Registry.GetValue(K, "CurrentBuild", "") as string) ?? "";
                string disp = (Registry.GetValue(K, "DisplayVersion", "") as string) ?? "";
                int b;
                if (int.TryParse(build, out b) && b >= 22000) name = name.Replace("Windows 10", "Windows 11");
                return name + (disp != "" ? " " + disp : "") + (build != "" ? ", build " + build : "");
            }
            catch { return "Windows"; }
        }

        static string MemoryText()
        {
            try
            {
                var pc = new Microsoft.VisualBasic.Devices.ComputerInfo();
                return (pc.TotalPhysicalMemory >> 30) + " GB RAM, " + (pc.AvailablePhysicalMemory >> 30) + " GB free";
            }
            catch { return "?"; }
        }

        static byte[] ReadShared(string path)
        {
            using (var f = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            using (var m = new MemoryStream()) { f.CopyTo(m); return m.ToArray(); }
        }

        static string ReadText(string path)
        {
            try { var d = File.Exists(path) ? ReadShared(path) : null; return d == null ? null : Encoding.UTF8.GetString(d); }
            catch { return null; }
        }

        static IEnumerable<string> ReadLines(string path)
        {
            byte[] b = null;
            try { if (File.Exists(path)) b = ReadShared(path); } catch { }
            if (b == null) yield break;
            using (var r = new StringReader(Encoding.UTF8.GetString(b)))
            {
                string line;
                while ((line = r.ReadLine()) != null) yield return line;
            }
        }

        [ThreadStatic] static int tail;
        static void AddFile(ZipArchive z, string path, string name)
        {
            try
            {
                if (!File.Exists(path)) return;
                byte[] d = ReadShared(path);
                if (tail > 0 && d.Length > tail) { var t = new byte[tail]; Array.Copy(d, d.Length - tail, t, 0, tail); d = t; }
                // text files are scrubbed of credentials, tokens and the Windows user name on the way into the zip
                string ext = Path.GetExtension(path).ToLowerInvariant();
                if (ext == ".txt" || ext == ".log" || ext == ".ini" || ext == ".xml" || ext == ".runtime-xml")
                    d = Encoding.UTF8.GetBytes(Diagnose.Scrub(Encoding.UTF8.GetString(d)));
                Add(z, name, d);
            }
            catch { }
        }

        public const long MaxUpload = 9L * 1024 * 1024;

        public static bool CanSend { get { return ReportTarget.Webhook.StartsWith("https://") || ReportTarget.Webhook.StartsWith("http://127.0.0.1:"); } }

        public static bool Send(string zip, string win64, out string error)
        {
            error = null;
            if (!CanSend) { error = "this build has no report address"; return false; }
            string file = zip;
            try
            {
                string message = "";
                try
                {
                    using (var a = ZipFile.OpenRead(zip))
                    {
                        var e = a.GetEntry("message.txt");
                        if (e != null) using (var r = new StreamReader(e.Open())) message = r.ReadToEnd().Trim();
                    }
                }
                catch { }
                if (new FileInfo(zip).Length > MaxUpload)
                {
                    string e2;
                    file = Create(win64, out e2, true, message);
                    if (file == null) { error = "couldn't make a smaller copy: " + e2; return false; }
                    if (new FileInfo(file).Length > MaxUpload) { error = "the report is too big to send"; return false; }
                }
                string local = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SurrounDead");
                var dg = Diagnose.Run(win64, local);
                var tri = Classify(win64);
                string level = Diagnose.Rank(tri.Level) > Diagnose.Rank(dg.Level) ? tri.Level : dg.Level;
                if (Duplicate(dg.Fingerprint, message, out error)) return false;
                string icon = level == "CRITICAL" ? "🔴" : level == "ERROR" ? "🟠" : level == "MINOR" ? "🟡" : "🟢";
                string desc = Diagnose.Scrub(Post(dg, message));
                string who = Reporter();
                string json = "{\"content\":" + JsonString(icon + " **" + level + "** bug report" + (who != "" ? " from " + who : ""))
                    + ",\"embeds\":[{\"title\":" + JsonString(Trunc(icon + " " + dg.Top.Title, 250))
                    + ",\"description\":" + JsonString(Trunc(desc, 4000)) + ",\"color\":" + Diagnose.ColorOf(level) + "}]}";
                string uploadName = "SurrounSync-" + level + "-" + Path.GetFileName(zip).Replace("SurrounSync-report-", "");
                ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
                string b = "----SurrounSync" + DateTime.Now.Ticks.ToString("x");
                var req = (HttpWebRequest)WebRequest.Create(ReportTarget.Webhook);
                req.Method = "POST";
                req.ContentType = "multipart/form-data; boundary=" + b;
                req.Timeout = 120000;
                req.UserAgent = "SurrounSync";
                using (var body = new MemoryStream())
                {
                    Action<string> w = t => { var x = Encoding.UTF8.GetBytes(t); body.Write(x, 0, x.Length); };
                    w("--" + b + "\r\nContent-Disposition: form-data; name=\"payload_json\"\r\nContent-Type: application/json\r\n\r\n" + json + "\r\n");
                    w("--" + b + "\r\nContent-Disposition: form-data; name=\"files[0]\"; filename=\"" + uploadName
                        + "\"\r\nContent-Type: application/zip\r\n\r\n");
                    var data = File.ReadAllBytes(file);
                    body.Write(data, 0, data.Length);
                    w("\r\n--" + b + "--\r\n");
                    req.ContentLength = body.Length;
                    using (var rs = req.GetRequestStream()) body.WriteTo(rs);
                }
                using (var resp = (HttpWebResponse)req.GetResponse())
                {
                    int code = (int)resp.StatusCode;
                    if (code < 200 || code >= 300) { error = "the report server answered " + code; return false; }
                }
                Remember(dg.Fingerprint);
                return true;
            }
            catch (WebException we)
            {
                var r = we.Response as HttpWebResponse;
                error = r != null ? "the report server answered " + (int)r.StatusCode : we.Message;
                return false;
            }
            catch (Exception e) { error = e.Message; return false; }
            finally { if (file != zip) try { File.Delete(file); } catch { } }
        }

        static string Trunc(string s, int n) { return s.Length > n ? s.Substring(0, n - 3) + "..." : s; }

        // The Discord post: the player summary, the findings with how sure each is, then the versions.
        public static string Post(Diagnosis d, string message)
        {
            var t = d.Top;
            var sb = new StringBuilder();
            if (!string.IsNullOrEmpty(message)) sb.Append("**Message:** ").Append(Trunc(message.Replace('`', '\''), 1200)).Append("\n\n");
            sb.Append("**What happened:** ").Append(t.What).Append('\n');
            if (t.Affects != "") sb.Append("**Affects:** ").Append(t.Affects).Append('\n');
            if (t.Cause != "") sb.Append("**Why (").Append(t.Confidence).Append("):** ").Append(Trunc(t.Cause, 500)).Append('\n');
            if (t.PlayerTry != "") sb.Append("**Player can try:** ").Append(t.PlayerTry).Append('\n');
            if (t.DevLook != "") sb.Append("**Look at:** ").Append(Trunc(t.DevLook, 300)).Append('\n');
            foreach (var e in t.Evidence) sb.Append("> ").Append(Trunc(e.Replace('`', '\''), 300)).Append('\n');
            if (d.Findings.Count > 1)
            {
                sb.Append("\n**Also found:**\n");
                for (int i = 1; i < d.Findings.Count && i < 8; i++)
                {
                    var f = d.Findings[i];
                    sb.Append("• [").Append(f.Severity).Append(", ").Append(f.Confidence).Append("] ").Append(f.Title)
                      .Append(f.Count > 1 ? " (" + f.Count + "x)" : "").Append('\n');
                }
            }
            sb.Append('\n');
            foreach (var c in d.Context) if (!c.StartsWith("Last sync status")) sb.Append(Trunc(c, 300)).Append('\n');
            return sb.ToString();
        }

        // The same problem sent again within 15 minutes with nothing new from the player isn't sent twice.
        static string LastFile() { return Path.Combine(Release.AppDir, "last_report.txt"); }
        public static bool Duplicate(string fingerprint, string message, out string error)
        {
            error = null;
            if (!string.IsNullOrEmpty(message)) return false;
            try
            {
                var parts = File.ReadAllText(LastFile()).Split('\n');
                long ticks;
                if (parts.Length >= 2 && parts[1].Trim() == fingerprint && long.TryParse(parts[0].Trim(), out ticks))
                {
                    double min = (DateTime.UtcNow - new DateTime(ticks, DateTimeKind.Utc)).TotalMinutes;
                    if (min >= 0 && min < 15)
                    {
                        error = "the same report was already sent " + (int)min + " min ago - add a message to send it again";
                        return true;
                    }
                }
            }
            catch { }
            return false;
        }
        public static void Remember(string fingerprint)
        {
            try { Directory.CreateDirectory(Release.AppDir); File.WriteAllText(LastFile(), DateTime.UtcNow.Ticks + "\n" + fingerprint); } catch { }
        }

        static string JsonString(string s)
        {
            var sb = new StringBuilder("\"");
            foreach (char c in s)
            {
                if (c == '"' || c == '\\') sb.Append('\\').Append(c);
                else if (c == '\n') sb.Append("\\n");
                else if (c == '\r') { }
                else if (c < ' ') sb.Append(' ');
                else sb.Append(c);
            }
            return sb.Append('"').ToString();
        }

        static void Add(ZipArchive z, string name, byte[] data)
        {
            var e = z.CreateEntry(name, CompressionLevel.Optimal);
            using (var s = e.Open()) s.Write(data, 0, data.Length);
        }
    }
}
