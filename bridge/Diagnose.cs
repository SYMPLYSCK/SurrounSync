// Bug report diagnosis: turns SurrounSync's logs, the game's crash files and the install into explained findings
// (what happened in plain words, evidence, likely cause + how sure, what to try, where a developer should look).
// Runs only when a report is made - nothing here runs while playing. C# 5 (the csc that ships with Windows).

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

namespace SurrounSyncShared
{
    public sealed class Finding
    {
        public string Title = "", Category = "", Severity = "INFO", Confidence = "possible";
        public string What = "", Affects = "", Cause = "", Expected = "", Actual = "";
        public string PlayerTry = "", Workaround = "", DevLook = "", Repro = "";
        public List<string> Evidence = new List<string>();
        public int Count = 1;
    }

    public sealed class Diagnosis
    {
        public List<Finding> Findings = new List<Finding>();
        public List<string> Groups = new List<string>();
        public List<string> Timeline = new List<string>();
        public List<string> Context = new List<string>();
        public List<string> Missing = new List<string>();
        public string Role = "?", ModVersion = "?", Protocol = "?", Peer = "", TimelineFrom = "";
        public long Ms;
        public int Lines;
        public string CrashDir = "";
        public Finding Top { get { return Findings.Count > 0 ? Findings[0] : null; } }
        public string Level { get { return Top != null ? Top.Severity : "INFO"; } }
        public string Fingerprint { get { return (Top != null ? Top.Title + "|" + Top.Count : "none") + "|" + CrashDir; } }
    }

    public static class Diagnose
    {
        const int MaxGroups = 200, TimelineLines = 25, CrashWindowHours = 3;
        public static DateTime? ReplayAt;   // explaining an old report: its time instead of now

        public static int Rank(string sev)
        {
            return sev == "CRITICAL" ? 3 : sev == "ERROR" ? 2 : sev == "MINOR" ? 1 : 0;
        }
        public static int ColorOf(string sev)
        {
            return sev == "CRITICAL" ? 0xE53935 : sev == "ERROR" ? 0xFB8C00 : sev == "MINOR" ? 0xFDD835 : 0x43A047;
        }

        sealed class Line { public string Time, Level, Text, Raw; }
        sealed class Group { public string Sig, Level, First, Last, Sample; public int Count; }

        static readonly Regex LineRe = new Regex(@"^(\d\d:\d\d:\d\d) \[SurrounSync\]\[(\w+)\] (.*)$", RegexOptions.Compiled);

        static List<Line> Parse(string path, ref int count)
        {
            var list = new List<Line>();
            foreach (var raw in ReadLines(path))
            {
                count++;
                var m = LineRe.Match(raw);
                if (m.Success) list.Add(new Line { Time = m.Groups[1].Value, Level = m.Groups[2].Value, Text = m.Groups[3].Value, Raw = raw });
            }
            return list;
        }

        // The same problem with different numbers/names/paths counts as one.
        public static string Signature(string text)
        {
            string s = Regex.Replace(text, @"\s*\(x\d+ in \d+ s\)", "");
            s = Regex.Replace(s, @"\S*[\\/]Scripts[\\/]mirror[\\/]", "");
            s = Regex.Replace(s, @"Lost connection to .+?\.$", "Lost connection to <player>.");
            s = Regex.Replace(s, @"between you and .+? - ", "between you and <player> - ");
            s = Regex.Replace(s, @"-?\d+(\.\d+)?", "N");
            s = Regex.Replace(s, @"\s+", " ").Trim();
            return s.Length > 170 ? s.Substring(0, 170) : s;
        }

        public static Diagnosis Run(string win64, string local)
        {
            var sw = Stopwatch.StartNew();
            var d = new Diagnosis();
            string mod = win64 != null ? Path.Combine(win64, "ue4ss", "Mods", "SurrounSync") : null;
            d.ModVersion = Release.ModVersion(mod) ?? "?";
            d.Protocol = Release.ModProtocol(mod) ?? "?";

            // which game run to explain: the one that ended at the crash, else the newest
            string cur = win64 != null ? Path.Combine(win64, "mirror_log.txt") : null;
            string prev = win64 != null ? Path.Combine(win64, "mirror_log.1.txt") : null;
            string crash = NewestCrash(local);
            DateTime crashAt = crash != null ? Directory.GetLastWriteTime(crash) : DateTime.MinValue;
            bool recentCrash = crash != null && ((ReplayAt ?? DateTime.Now) - crashAt).TotalHours < CrashWindowHours;
            int n = 0;
            var curLines = cur != null ? Parse(cur, ref n) : new List<Line>();
            List<Line> runLines = curLines;
            d.TimelineFrom = "mirror_log.txt (the newest game run)";
            // a game restarted within minutes of the crash also has its newest log "near" it: the run that
            // started after the crash isn't the one that crashed (report 122034 explained the new run)
            if (recentCrash && prev != null && File.Exists(prev) && Near(File.GetLastWriteTime(prev), crashAt)
                && (!(File.Exists(cur) && Near(File.GetLastWriteTime(cur), crashAt)) || SecondsAfter(curLines, 0, crashAt) > 0))
            {
                runLines = Parse(prev, ref n);
                d.TimelineFrom = "mirror_log.1.txt (the game run that crashed)";
            }
            d.Lines = n;
            if (cur == null || !File.Exists(cur))
                d.Missing.Add("SurrounSync's log (mirror_log.txt) is missing - the mod may not have started in the last game run.");

            ReadContext(d, runLines, local);
            var groups = GroupProblems(runLines == curLines ? curLines : Concat(runLines, curLines));
            foreach (var g in groups)
                d.Groups.Add(string.Format("{0}x [{1}] {2} (first {3}, last {4})", g.Count, g.Level, g.Sig, g.First, g.Last));
            foreach (var g in groups)
            {
                var f = Known(g, d);
                if (f != null) Merge(d, f);
            }
            if (recentCrash)
            {
                var cf = CrashFinding(win64, crash, crashAt, d);
                double? after = runLines.Count > 0 ? SecondsAfter(runLines, runLines.Count - 1, crashAt) : null;
                if (after.HasValue)
                {
                    string at = runLines[runLines.Count - 1].Time;
                    double gap = -after.Value;
                    if (gap >= 0)
                        cf.Evidence.Add("Last SurrounSync log line " + at + ", " + (int)gap + " s before the crash"
                                        + (gap > 60 ? " (the game was probably frozen in between)" : ""));
                    else
                        cf.Evidence.Add("Last SurrounSync log line " + at + ", " + (int)-gap + " s after the crash's file time (the crash files were written late)");
                }
                d.Findings.Add(cf);
            }
            else if (crash != null) d.Context.Add("Newest game crash: " + crashAt.ToString("yyyy-MM-dd HH:mm") + " - older than " + CrashWindowHours + " h, not part of this report's findings.");
            Install(win64, d);
            Timeline(d, runLines);

            if (d.Findings.Count == 0)
                d.Findings.Add(new Finding
                {
                    Title = "No problem found in the logs", Category = "Player report", Severity = "INFO", Confidence = "confirmed",
                    What = "SurrounSync and the game recorded no errors, warnings or crashes for this game run.",
                    Affects = "Whatever you noticed isn't something the mod could detect, so your description is the main clue.",
                    Cause = "Unknown - there is no evidence in the logs.",
                    PlayerTry = "Describe what you saw, where you were and what you were doing, and if you can, what the other player saw.",
                    DevLook = "Read the player's message and the timeline; compare with the other player's report.",
                });
            // most severe first; at equal severity a crash leads (it's what the player noticed), then the most frequent
            d.Findings.Sort((a, b) => Rank(b.Severity) != Rank(a.Severity) ? Rank(b.Severity) - Rank(a.Severity)
                : IsCrash(b) != IsCrash(a) ? (IsCrash(b) ? 1 : -1) : b.Count - a.Count);
            if (d.Role == "?") d.Missing.Add("Couldn't tell whether this player was the host or the guest (no co-op session in the log).");
            else d.Missing.Add("Only this player's (" + d.Role + ") files are in this report - a report from the other player"
                               + (d.Peer != "" ? " (" + d.Peer + ")" : "") + " shows their side of the same moment.");
            sw.Stop();
            d.Ms = sw.ElapsedMilliseconds;
            return d;
        }

        static bool IsCrash(Finding f) { return f.Category.StartsWith("Crash") || f.Category == "Freeze"; }

        static bool Near(DateTime a, DateTime b) { return Math.Abs((a - b).TotalMinutes) < 10; }

        // Seconds from t to log line i (negative = before t), or null. Lines carry only the time of day:
        // the nearest reading within +-12 h is taken, so a run across midnight still compares right.
        static double? SecondsAfter(List<Line> lines, int i, DateTime t)
        {
            TimeSpan at;
            if (i < 0 || i >= lines.Count || !TimeSpan.TryParse(lines[i].Time, out at)) return null;
            double s = (at - t.TimeOfDay).TotalSeconds;
            if (s > 43200) s -= 86400;
            else if (s <= -43200) s += 86400;
            return s;
        }

        static List<Line> Concat(List<Line> a, List<Line> b) { var l = new List<Line>(a); l.AddRange(b); return l; }

        static void ReadContext(Diagnosis d, List<Line> lines, string local)
        {
            int noData = 0, lost = 0;
            string rtt = null, status = null;
            foreach (var l in lines)
            {
                var m = Regex.Match(l.Text, @"^phase1\[(host|guest)\]");
                if (m.Success) { d.Role = m.Groups[1].Value; status = l.Text; }
                if (l.Text.Contains("no data from the other game")) noData++;
                var lc = Regex.Match(l.Text, @"Lost connection to (.+?)\.$");
                if (lc.Success) { lost++; d.Peer = lc.Groups[1].Value; }
                var r = Regex.Match(l.Text, @"net round trip (\d+) ms");
                if (r.Success) rtt = r.Groups[1].Value;
            }
            try
            {
                foreach (var line in File.ReadAllLines(Path.Combine(local, "mirror_lobby.txt")))
                {
                    var m = Regex.Match(line, @"^peer (\d+) (.+)$");
                    if (m.Success && d.Peer == "") d.Peer = m.Groups[2].Value.Trim();
                }
            }
            catch { }
            d.Context.Add("Role: " + d.Role + (d.Peer != "" ? ", other player: " + d.Peer : ""));
            d.Context.Add("Connection: " + (rtt != null ? "last round trip " + rtt + " ms" : "no round-trip time logged")
                          + ", 'no data from the other game' " + noData + "x, lost connection " + lost + "x");
            if (status != null) d.Context.Add("Last sync status: " + (status.Length > 400 ? status.Substring(0, 400) + "..." : status));
        }

        static List<Group> GroupProblems(List<Line> lines)
        {
            var map = new Dictionary<string, Group>();
            var order = new List<Group>();
            foreach (var l in lines)
            {
                bool err = l.Level == "ERROR" || l.Text.Contains("safe() caught");
                if (!err && l.Level != "WARN") continue;
                string sig = Signature(l.Text);
                Group g;
                if (!map.TryGetValue(sig, out g))
                {
                    if (map.Count >= MaxGroups) continue;
                    g = new Group { Sig = sig, Level = err ? "ERROR" : "WARN", First = l.Time, Sample = l.Text };
                    map[sig] = g; order.Add(g);
                }
                var x = Regex.Match(l.Text, @"\(x(\d+) in \d+ s\)");
                int times;
                g.Count += x.Success && int.TryParse(x.Groups[1].Value, out times) ? times : 1;
                g.Last = l.Time;
            }
            order.Sort((a, b) => b.Count - a.Count);
            return order;
        }

        static void Merge(Diagnosis d, Finding f)
        {
            foreach (var o in d.Findings)
                if (o.Title == f.Title)
                {
                    o.Count += f.Count;
                    foreach (var e in f.Evidence) if (o.Evidence.Count < 6 && !o.Evidence.Contains(e)) o.Evidence.Add(e);
                    return;
                }
            d.Findings.Add(f);
        }

        static bool OlderOrSame(string v, string than) { return v != "?" && Release.Compare(v, than) <= 0; }

        static readonly Dictionary<string, string> Features = new Dictionary<string, string>
        {
            { "tactical", "flashlight/laser attachment sync" }, { "vehicles", "car sync" }, { "zombies", "zombie sync" },
            { "loot", "container loot sync" }, { "drops", "dropped item sync" }, { "builds", "building sync" },
            { "names", "backpack names" }, { "bedtags", "bed names" }, { "session", "joining, leaving and save handling" },
            { "slotguard", "save protection" }, { "audio", "sound sharing" }, { "throwables", "grenade/molotov/flare sync" },
            { "world", "time and weather sync" }, { "harvest", "mining and wood sync" }, { "corpses", "corpse loot sync" },
            { "deathbags", "death bags" }, { "teleport", "/goto and /bring" }, { "ghost", "the other player's character" },
            { "phase1", "the main sync loop" }, { "link", "the connection" }, { "xp", "XP sharing" }, { "fire", "gunshot sharing" },
            { "doors", "door sync" }, { "power", "power sync" }, { "infest", "infestation sync" }, { "jig", "inventory items" },
            { "menu", "the CO-OP menu" }, { "journal_tab", "the CO-OP menu" }, { "chat", "chat" }, { "lights", "light sync" },
            { "look", "the other player's clothing" }, { "anim", "the other player's animations" }, { "nametag", "name tags" },
        };
        public static string FeatureOf(string module)
        {
            string f;
            return module != null && Features.TryGetValue(module, out f) ? f : (module ?? "an unknown part of the mod");
        }

        static string LuaPlain(string msg)
        {
            if (msg.Contains("attempt to index") && msg.Contains("nil")) return "the mod tried to use a game object that wasn't there (already gone, or not loaded yet)";
            if (msg.Contains("attempt to compare")) return "the mod got a different kind of value from the game than it expected";
            if (msg.Contains("attempt to call")) return "a game function the mod expected doesn't exist (it may have changed in a game update)";
            if (msg.Contains("attempt to perform arithmetic")) return "the mod tried to calculate with a value the game didn't provide";
            return "the mod's code hit an unexpected error";
        }

        // Known log problems -> explained findings. Returns null for warnings that need no finding of their own.
        static Finding Known(Group g, Diagnosis d)
        {
            string s = g.Sample;
            var f = new Finding { Count = g.Count };
            f.Evidence.Add(g.Count + "x between " + g.First + " and " + g.Last + ": " + Trunc(s, 260));
            if (s.Contains("tactical") && s.Contains("TrivialObject"))
            {
                f.Title = "Flashlight/laser attachment sync error"; f.Category = "Mod error"; f.Severity = g.Count > 100 ? "ERROR" : "MINOR";
                f.Confidence = "confirmed";
                f.What = "SurrounSync kept failing while checking the lights on your weapon attachments (" + g.Count + " times).";
                f.Affects = "The other player may not see your flashlight or laser. The repeated error also costs a little performance.";
                f.Cause = "The mod read a light that this attachment type doesn't have (each attachment has only some of the lights).";
                f.PlayerTry = OlderOrSame(d.ModVersion, "0.11.0") ? "Update SurrounSync - this is fixed in versions after 0.11.0."
                    : "Report it - this version (" + d.ModVersion + ") should already have the fix.";
                f.Workaround = "Unequip flashlight/laser attachments until you update (restart the game if one was equipped).";
                f.DevLook = "mod/SurrounSync/Scripts/mirror/tactical.lua - intensity()/scan of SpotLight/PointLight per attachment class.";
                f.Repro = "Equip a flashlight or laser attachment and play with or without a co-op partner.";
                return f;
            }
            if (s.Contains("runs an OLDER SurrounSync"))
            {
                f.Title = "The two players have different SurrounSync versions"; f.Category = "Compatibility"; f.Severity = "ERROR"; f.Confidence = "confirmed";
                f.What = "The other game talks an older SurrounSync language than yours, so the sync can't work properly.";
                f.Affects = "Joining, and most shared things (zombies, loot, cars).";
                f.Expected = "Both games run the same SurrounSync version."; f.Actual = "The other game sends data without the version announcement newer versions send.";
                f.Cause = "One player updated SurrounSync and the other didn't (or has an old copy still installed).";
                f.PlayerTry = "Both players: run SurrounSync Setup and update to the newest version, then restart the game.";
                f.DevLook = "mirror/phase1.lua protocol handshake; mirror/version.lua PROTOCOL (" + d.Protocol + " here).";
                return f;
            }
            if (s.Contains("slotguard: refused") || s.Contains("couldn't copy your co-op character home") || s.Contains("couldn't copy the character home"))
            {
                f.Title = "Save protection refused a save action"; f.Category = "Save safety"; f.Severity = "CRITICAL"; f.Confidence = "confirmed";
                f.What = "SurrounSync stopped itself from changing a save it wasn't sure about. Your saves were left alone.";
                f.Affects = "Your co-op character may not have been copied back to your own save yet; the mod retries on the next start.";
                f.Cause = "The save it was about to change didn't look like one of yours (or the co-op slot was empty): " + Trunc(Signature(s), 160);
                f.PlayerTry = "Load one of your own saves (not 'SurrounSync_Session'), then restart the game once so the mod can retry.";
                f.Workaround = "Don't play inside the SurrounSync_Session slot directly.";
                f.DevLook = "mirror/slotguard.lua (refusal checks) and mirror/session.lua copy_character_home / session log.";
                return f;
            }
            if (s.Contains("playing the co-op slot itself") || s.Contains("Load one of your own saves first"))
            {
                f.Title = "Joined from the co-op save slot"; f.Category = "Player setup"; f.Severity = "MINOR"; f.Confidence = "confirmed";
                f.What = "The game was running the SurrounSync co-op slot instead of one of your own saves, so joining was refused.";
                f.Affects = "Joining only - nothing was changed.";
                f.PlayerTry = "Load one of your own saves from the main menu, then join.";
                f.DevLook = "mirror/session.lua join checks.";
                return f;
            }
            if (s.Contains("host could not export its world"))
            {
                f.Title = "The host couldn't share its world"; f.Category = "Joining"; f.Severity = "ERROR"; f.Confidence = "confirmed";
                f.What = "When the guest joined, the host's game couldn't write the copy of its world the guest loads.";
                f.Affects = "The guest can't join until this works.";
                f.Cause = "Unknown from this log alone - the lines just before it in the timeline usually say why (save busy, disk).";
                f.PlayerTry = "Host: make sure the disk has free space, save the game normally once, then let the guest join again.";
                f.DevLook = "mirror/session.lua export path (host side) and the timeline lines before the error.";
                return f;
            }
            if (s.Contains("no data from the other game") || s.Contains("Lost connection to"))
            {
                if (g.Count < 3 && s.Contains("no data")) return null;
                f.Title = "Connection to the other player dropped"; f.Category = "Connection"; f.Severity = g.Count >= 5 ? "ERROR" : "MINOR";
                f.Confidence = "likely";
                f.What = "The other player's game stopped sending data for a while (" + g.Count + "x).";
                f.Affects = "During those moments the other player freezes or vanishes, and shared actions can arrive late.";
                f.Cause = "Their game was paused, loading, frozen or closed, or the internet connection between you dropped. The log can't tell which.";
                f.PlayerTry = "Check whether the other player's game froze or crashed at the same time. If not, check both internet connections.";
                f.DevLook = "connector logs (connector/mirror_bridge*.log) around " + g.First + "; mirror/link.lua peer age.";
                return f;
            }
            if (s.Contains("could not hook"))
            {
                f.Title = "SurrounSync couldn't attach to a game function"; f.Category = "Compatibility"; f.Severity = "ERROR"; f.Confidence = "likely";
                f.What = "A part of the game the mod needs couldn't be found or attached to.";
                f.Affects = "The feature using it won't work; if it's the player hook, most of the mod won't start.";
                f.Cause = "A game update probably renamed or changed it, or the mod tried before the game had loaded it (it retries).";
                f.PlayerTry = "Make sure both SurrounDead and SurrounSync are up to date.";
                f.DevLook = "util.ensure_hook path in the message: " + Trunc(Signature(s), 160);
                return f;
            }
            if (s.Contains("Mod check:") && s.Contains("differ"))
            {
                f.Title = "The players use different mods"; f.Category = "Compatibility"; f.Severity = "MINOR"; f.Confidence = "possible";
                f.What = "Some other mods are installed for one player but not the other.";
                f.Affects = "Those mods can change things the other game doesn't know about, which may cause differences.";
                f.Cause = "Possible only - different mods don't always cause problems. " + Trunc(Signature(s), 160);
                f.PlayerTry = "If something looks different between you, try with the same mods on both sides.";
                f.DevLook = "mirror/compat.lua classification of the named mods.";
                return f;
            }
            if (s.Contains("Couldn't back up your save"))
            {
                f.Title = "Couldn't back up the save before joining"; f.Category = "Save safety"; f.Severity = "ERROR"; f.Confidence = "confirmed";
                f.What = "SurrounSync makes a backup of your save before a join and couldn't, so the join was stopped.";
                f.Affects = "Joining only - your save was not changed.";
                f.PlayerTry = "Free some disk space, then try again.";
                f.DevLook = "mirror/backups.lua.";
                return f;
            }
            if (s.Contains("Steam connection (SurrounSyncBridge) stopped"))
            {
                f.Title = "The Steam connector stopped"; f.Category = "Connection"; f.Severity = "ERROR"; f.Confidence = "confirmed";
                f.What = "SurrounSync's Steam connector (SurrounSyncBridge.exe) stopped and was restarted.";
                f.Affects = "The co-op connection drops while it restarts.";
                f.Cause = "See the connector log for why - antivirus can also stop it.";
                f.PlayerTry = "If it repeats, check that your antivirus isn't blocking SurrounSyncBridge.exe.";
                f.DevLook = "connector/mirror_bridge*.log at " + g.First + ".";
                return f;
            }
            var lua = Regex.Match(s, @"safe\(\) caught in ([\w\.]+).*?(\w+)\.lua:(\d+): (.*)$");
            if (lua.Success)
            {
                string file = lua.Groups[2].Value, msg = lua.Groups[4].Value;
                f.Title = "Error in " + FeatureOf(file) + " (" + file + ".lua:" + lua.Groups[3].Value + ")";
                f.Category = "Mod error"; f.Severity = "ERROR"; f.Confidence = "confirmed";
                f.What = "SurrounSync's " + FeatureOf(file) + " hit an error " + g.Count + "x: " + LuaPlain(msg) + ".";
                f.Affects = FeatureOf(file) + " may not have worked at those moments. The mod caught it and kept running.";
                f.Cause = "Confirmed error, cause not yet known: '" + Trunc(msg, 200) + "' in " + lua.Groups[1].Value + ".";
                f.PlayerTry = "Tell the developer what you were doing at " + g.First + " (see the timeline).";
                f.DevLook = "mod/SurrounSync/Scripts/mirror/" + file + ".lua line " + lua.Groups[3].Value + ", called from " + lua.Groups[1].Value + ".";
                f.Repro = "Use " + FeatureOf(file) + " the way the timeline shows before " + g.First + ".";
                return f;
            }
            if (g.Level == "ERROR")
            {
                var mm = Regex.Match(s, @"^\[?(\w+)[\]:]");
                string module = mm.Success ? mm.Groups[1].Value : null;
                f.Title = "Error in " + FeatureOf(module) + ": " + Trunc(Signature(s), 90);
                f.Category = "Mod error"; f.Severity = "ERROR"; f.Confidence = "confirmed";
                f.What = "SurrounSync reported a problem in " + FeatureOf(module) + " (" + g.Count + "x).";
                f.Affects = "Probably " + FeatureOf(module) + ".";
                f.Cause = "Not known yet - the message is: " + Trunc(s, 200);
                f.PlayerTry = "Tell the developer what you were doing at " + g.First + ".";
                f.DevLook = module != null ? "mod/SurrounSync/Scripts/mirror/" + module + ".lua" : "search the mod for the message text";
                return f;
            }
            return null;
        }

        // the running mod step (mirror_step*.txt) -> which feature
        public static string StepFeature(string step)
        {
            if (step == null) return null;
            if (Regex.IsMatch(step, @"\bgame \(")) return "";   // between mod steps: the game was running its own code
            string s = step.ToLowerInvariant();
            string[,] map = {
                { "jigcontextmenu", "names" }, { "onhovertooltip", "names" }, { "jighelpercomp", "bedtags" }, { "vehicle", "vehicles" },
                { "damagecomponent", "zombies" }, { "zombie", "zombies" }, { "buildable", "builds" }, { "buildingcomponent", "builds" },
                { "throwable", "throwables" }, { "sound", "audio" }, { "audio", "audio" }, { "flashlight", "tactical" }, { "laser", "tactical" },
                { "pickup", "drops" }, { "harvest", "harvest" }, { "trader", "zombies" }, { "jigcomponent", "loot" }, { "medicalcomponent", "zombies" },
                { "door", "doors" }, { "bp_playercharacter", "phase1" },
            };
            for (int i = 0; i < map.GetLength(0); i++) if (s.Contains(map[i, 0])) return map[i, 1];
            var m = Regex.Match(step, @"^\S+ (\w+)");
            return m.Success && Features.ContainsKey(m.Groups[1].Value) ? m.Groups[1].Value : null;
        }

        static Finding CrashFinding(string win64, string crash, DateTime at, Diagnosis d)
        {
            d.CrashDir = Path.GetFileName(crash);
            string xml = ReadText(Path.Combine(crash, "CrashContext.runtime-xml")) ?? "";
            string msg = Tag(xml, "ErrorMessage"), stack = Tag(xml, "CallStack");
            string module = Regex.Match(stack, @"^\s*([A-Za-z0-9_\-]+)").Groups[1].Value;
            string step = null, stepFile = null;
            if (win64 != null)
                foreach (var n in new[] { "mirror_step.txt", "mirror_step.1.txt" })
                {
                    string p = Path.Combine(win64, n);
                    if (!File.Exists(p)) continue;
                    double gap = (at - File.GetLastWriteTime(p)).TotalSeconds;
                    if (gap < -5 || gap > 600) continue;
                    step = (ReadText(p) ?? "").Trim(); stepFile = n;
                    break;
                }
            string feat = StepFeature(step);
            var f = new Finding { Category = "Crash", Severity = "CRITICAL" };
            f.Evidence.Add("Game crash at " + at.ToString("yyyy-MM-dd HH:mm:ss") + " (" + d.CrashDir + ")");
            if (msg != "") f.Evidence.Add("Error: " + Trunc(Regex.Replace(msg, @"\s+", " "), 300));
            if (stack != "") f.Evidence.Add("Crashed in: " + Trunc(Frames(stack), 300));
            if (step != null) f.Evidence.Add("SurrounSync step at the crash (" + stepFile + "): " + step);
            else d.Missing.Add("No SurrounSync step file matches the crash time, so it's unknown what the mod was doing (older version, or crash_steps off).");
            if (!File.Exists(Path.Combine(crash, "UEMinidump.dmp"))) d.Missing.Add("The crash folder has no minidump.");
            string modPart = feat == null ? "" : feat == "" ? " SurrounSync wasn't running any of its own code at that moment." :
                " SurrounSync's " + FeatureOf(feat) + " code was running at that moment.";
            f.DevLook = "Crash folder crash/ in the zip (minidump: stack only). " +
                (feat != null && feat != "" ? "Start with mod/SurrounSync/Scripts/mirror/" + feat + ".lua around the step's hook. " : "") +
                "Correlate with the timeline lines just before " + at.ToString("HH:mm:ss") + ".";
            f.Repro = "Repeat what the timeline shows just before " + at.ToString("HH:mm:ss") + (step != null ? " (the mod was at: " + Trunc(step, 120) + ")" : "") + ".";

            if (msg.Contains("GPU Crash") || msg.Contains("DXGI_ERROR") || msg.Contains("D3D12") || msg.Contains("D3D11"))
            {
                f.Title = "Game crash in the graphics driver"; f.Category = "Crash (graphics)"; f.Confidence = "likely";
                f.What = "The game closed because the graphics card driver stopped responding (the game saved a GPU crash dump).";
                f.Affects = "The whole game session for this player.";
                f.Cause = "Rendering/driver side: the graphics driver or card failed while drawing. SurrounSync doesn't draw anything itself." + modPart;
                f.PlayerTry = "Update your graphics driver and lower the graphics settings (or turn off frame generation / upscaling if you use them).";
                f.Workaround = "Lower graphics settings until the driver is updated.";
                return f;
            }
            if (msg.Contains("timed out waiting for RenderThread"))
            {
                f.Title = "Game froze (render thread stopped responding)"; f.Category = "Freeze"; f.Confidence = "likely";
                f.What = "The game froze for 2 minutes and then closed itself, because its drawing part stopped responding.";
                f.Affects = "The whole game session for this player.";
                f.Cause = "Usually the graphics driver or an overloaded GPU/CPU; the log can't confirm which." + modPart;
                f.PlayerTry = "Update your graphics driver, close big background programs and lower the graphics settings.";
                return f;
            }
            if (msg.Contains("LowLevelFatalError") && (msg.Contains("Serialization") || msg.Contains("AsyncLoading") || msg.Contains("BulkData") || msg.Contains("corrupt")))
            {
                bool mismatch = win64 != null && !Game.EngineOk(win64);
                f.Title = "Game crash loading damaged or mismatched game files"; f.Category = "Crash (game files)";
                f.Confidence = mismatch ? "confirmed" : "likely";
                f.What = "The game couldn't read one of its own files and closed.";
                f.Affects = "The game can crash again whenever it loads that file.";
                f.Cause = (mismatch ? "Confirmed: the game program is from a different game version than its files. " :
                    "A game file is damaged or from another version (a pak mod or an interrupted update can do this). ") + modPart;
                f.PlayerTry = "In Steam: right-click SurrounDead -> Properties -> Installed Files -> Verify integrity of game files.";
                f.Workaround = "Remove pak mods listed under 'Pak mods' in the report until the files are verified.";
                return f;
            }
            if (msg.IndexOf("out of memory", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                f.Title = "Game ran out of memory"; f.Category = "Crash (memory)"; f.Confidence = "confirmed";
                f.What = "The game closed because Windows couldn't give it more memory.";
                f.Affects = "The whole game session for this player.";
                f.Cause = "Too little free memory (RAM + page file) for the game and the programs running next to it." + modPart;
                f.PlayerTry = "Close big background programs and let Windows manage the page file size.";
                return f;
            }
            bool inUe4ss = module.StartsWith("UE4SS", StringComparison.OrdinalIgnoreCase);
            if (stack.Contains("1de5ad") && inUe4ss)
            {
                f.Title = "Known crash: first moment after a respawn/reload"; f.Confidence = "likely";
                f.What = "The game crashed right after you respawned or a world reloaded.";
                f.Affects = "The game session; nothing in the saves.";
                f.Cause = "Known: the mod kept using objects from the old world after a reload. Fixed in versions after 0.11.0 (world-reset clean-up)." + modPart;
                f.PlayerTry = OlderOrSame(d.ModVersion, "0.11.0") ? "Update SurrounSync." : "Report it - this version should already have the fix.";
                f.DevLook = "mirror/game.lua on_world_reset; modules that cache UObjects. " + f.DevLook;
                return f;
            }
            if (stack.Contains("3ecd5ff"))
            {
                f.Title = "Known crash: car driving over zombie copies"; f.Confidence = "likely";
                f.What = "The game crashed while a car drove over zombies the mod copies from the host.";
                f.Affects = "The game session of the player whose car hit the zombies.";
                f.Cause = "Known, still under investigation: a car hit on a zombie copy uses an object that is already gone." + modPart;
                f.Workaround = "Avoid running over zombies as the guest until this is fixed.";
                f.DevLook = "mirror/vehicles.lua + mirror/zombies.lua (copy damage forwarding). " + f.DevLook;
                return f;
            }
            f.Title = inUe4ss ? "Game crash inside the script loader (UE4SS)" : "Game crash";
            f.Confidence = feat != null && feat != "" ? "likely" : "possible";
            f.What = "The game closed unexpectedly" + (msg.Contains("ACCESS_VIOLATION") ? " (it used memory that was no longer valid)" : "") + ".";
            f.Affects = "The whole game session for this player.";
            if (feat != null && feat != "")
                f.Cause = "Likely related to SurrounSync's " + FeatureOf(feat) + ": the crash happened while that code was running (" + Trunc(step, 140) + ").";
            else if (feat == "")
                f.Cause = (inUe4ss ? "UE4SS was running a script mod's call, but SurrounSync's own step had finished - another UE4SS mod or something the mod changed earlier is possible."
                    : "The game crashed in its own code while SurrounSync was idle. Possibly a game bug, or something the mod changed earlier - not known.");
            else
                f.Cause = "Unknown - no SurrounSync step information for this crash.";
            f.PlayerTry = "Tell the developer what you were doing just before the crash. If it repeats at the same moment, note it.";
            return f;
        }

        // "A A A B" -> "A (x3) B" (the crash context lists one module name per frame)
        static string Frames(string stack)
        {
            var parts = Regex.Split(stack.Trim(), @"\s+");
            var sb = new StringBuilder();
            string prev = null; int run = 0;
            Action flush = () => { if (prev != null) sb.Append(sb.Length > 0 ? " " : "").Append(prev).Append(run > 1 ? " (x" + run + ")" : ""); };
            foreach (var p0 in parts)
            {
                string p = p0.Trim();
                if (p == "") continue;
                if (p == prev) { run++; continue; }
                flush(); prev = p; run = 1;
            }
            flush();
            return sb.ToString();
        }

        static void Install(string win64, Diagnosis d)
        {
            if (win64 == null) { d.Missing.Add("The game folder wasn't found, so game/UE4SS files aren't in this report."); return; }
            string game = Path.GetFullPath(Path.Combine(win64, "..", "..", ".."));
            string build = Game.BuildId(game) ?? "?";
            string ue = Path.Combine(win64, "ue4ss");
            string uv = "missing";
            try { string dll = Path.Combine(ue, "UE4SS.dll"); if (File.Exists(dll)) uv = FileVersionInfo.GetVersionInfo(dll).FileVersion ?? "present"; } catch { }
            string eng = Game.EngineOf(win64) ?? "?";
            d.Context.Add("Versions: SurrounSync " + d.ModVersion + " (protocol " + d.Protocol + "), game Steam build " + build + " (Unreal " + eng + "), UE4SS " + uv);
            if (!Game.EngineOk(win64))
                d.Findings.Add(new Finding
                {
                    Title = "Game program and game files don't match", Category = "Compatibility", Severity = "CRITICAL", Confidence = "confirmed",
                    What = "The game's program is Unreal " + eng + " but this game version needs Unreal " + Game.Engine + ".",
                    Affects = "Crashes and missing content - the mod can't fix this.",
                    Cause = "An old or copied game program next to newer files (or the reverse).",
                    PlayerTry = "In Steam: Properties -> Installed Files -> Verify integrity of game files, then run SurrounSync Setup (REPAIR).",
                    Evidence = { "Unreal " + eng + " found, " + Game.Engine + " expected" },
                });
            if (uv == "missing")
                d.Findings.Add(new Finding
                {
                    Title = "UE4SS is missing", Category = "Install", Severity = "CRITICAL", Confidence = "confirmed",
                    What = "The script loader SurrounSync runs in isn't installed in this game.", Affects = "SurrounSync can't run at all.",
                    PlayerTry = "Run SurrounSync Setup and click REPAIR / REINSTALL.", Evidence = { "no " + Path.Combine("ue4ss", "UE4SS.dll") },
                });
            string ul = ReadText(Path.Combine(ue, "UE4SS.log"));
            if (ul == null) d.Missing.Add("UE4SS.log is missing.");
            else if (ul.Contains("Fatal Error") || ul.Contains("AOB scans could not be completed"))
                d.Findings.Add(new Finding
                {
                    Title = "UE4SS failed to start", Category = "Compatibility", Severity = "CRITICAL", Confidence = "confirmed",
                    What = "The script loader couldn't start in this game run, so no script mods (including SurrounSync) ran.",
                    Affects = "Everything SurrounSync does.",
                    Cause = ul.Contains("Found EngineVersion: " + Game.Engine) ? "Its scan of the game program failed (a game update can do this)."
                        : "This game version isn't supported by the installed UE4SS.",
                    PlayerTry = "Update SurrounSync (it ships a matching UE4SS) and verify the game files in Steam.",
                    Evidence = { "UE4SS.log: Fatal Error / AOB scans could not be completed" },
                });
            string made = ReadText(Path.Combine(ue, "Mods", "SurrounSync", "made_for_build.txt"));
            long a, b;
            if (made != null && long.TryParse(made.Trim(), out a) && long.TryParse(build, out b) && a != b)
                d.Findings.Add(new Finding
                {
                    Title = b > a ? "The game updated after this SurrounSync was made" : "The game is older than this SurrounSync",
                    Category = "Compatibility", Severity = "MINOR", Confidence = "possible",
                    What = "SurrounSync " + d.ModVersion + " was made for game build " + a + "; this game is build " + b + ".",
                    Affects = "Possibly nothing - but game updates can change things the mod relies on.",
                    Cause = "Possible only: a version difference is not proof of a problem.",
                    PlayerTry = b > a ? "Check for a SurrounSync update." : "Update the game in Steam (Betas: Experimental 0.8), then verify files.",
                    DevLook = "Patch notes between builds " + Math.Min(a, b) + " and " + Math.Max(a, b) + "; hooks/properties the findings above touch.",
                    Evidence = { "made_for_build.txt " + a + ", appmanifest buildid " + b },
                });
            var others = new List<string>();
            try
            {
                foreach (var line in File.ReadAllLines(Path.Combine(ue, "Mods", "mods.txt")))
                {
                    var m = Regex.Match(line, @"^\s*([^;:#]+?)\s*:\s*1\s*$");
                    if (!m.Success) continue;
                    string nm = m.Groups[1].Value;
                    if (nm != "SurrounSync" && nm != "Keybinds" && nm != "BPModLoaderMod" && nm != "BPML_GenericFunctions" && nm != "ConsoleEnablerMod" && nm != "ConsoleCommandsMod")
                        others.Add(nm);
                }
            }
            catch { }
            if (others.Count > 0) d.Context.Add("Other UE4SS mods enabled: " + string.Join(", ", others.ToArray()) + " (not proof of a problem; relevant if a crash is inside UE4SS)");
        }

        static readonly Regex Noise = new Regex(@"^(phase1(\[\w+\])?: (rx |net round trip|link file|link bridge)|perf: |hooked /|devtest: )", RegexOptions.Compiled);

        static void Timeline(Diagnosis d, List<Line> lines)
        {
            var keep = new List<string>();
            for (int i = lines.Count - 1; i >= 0 && keep.Count < TimelineLines; i--)
            {
                if (Noise.IsMatch(lines[i].Text)) continue;
                keep.Add(lines[i].Time + " [" + lines[i].Level + "] " + Trunc(lines[i].Text, 240));
            }
            keep.Reverse();
            d.Timeline = keep;
            if (keep.Count == 0) d.Missing.Add("No recent events in the log.");
        }

        // Plain-language part first (for the player), then the technical part (for the developer).
        public static string Text(Diagnosis d, string message)
        {
            var sb = new StringBuilder();
            var t = d.Top;
            sb.AppendLine("==================== PLAYER SUMMARY ====================");
            sb.AppendLine("Issue:    " + t.Title);
            sb.AppendLine("Category: " + t.Category + "    Severity: " + t.Severity + "    How sure: " + t.Confidence);
            sb.AppendLine("Report made: " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "    Role: " + d.Role + "    SurrounSync " + d.ModVersion);
            sb.AppendLine();
            Para(sb, "What happened", t.What);
            Para(sb, "What it affects", t.Affects);
            Para(sb, "Why", t.Cause);
            Para(sb, "Expected", t.Expected);
            Para(sb, "Actual", t.Actual);
            Para(sb, "What you can try", t.PlayerTry);
            Para(sb, "Until then", t.Workaround);
            if (!string.IsNullOrEmpty(message)) Para(sb, "Your message", message);
            if (d.Findings.Count > 1)
            {
                sb.AppendLine("Also found:");
                for (int i = 1; i < d.Findings.Count && i < 8; i++)
                    sb.AppendLine("  - [" + d.Findings[i].Severity + "] " + d.Findings[i].Title + (d.Findings[i].Count > 1 ? " (" + d.Findings[i].Count + "x)" : ""));
            }
            sb.AppendLine();
            sb.AppendLine("================= DEVELOPER DIAGNOSTICS =================");
            foreach (var c in d.Context) sb.AppendLine(c);
            sb.AppendLine();
            for (int i = 0; i < d.Findings.Count; i++)
            {
                var f = d.Findings[i];
                sb.AppendLine("[" + (i + 1) + "] " + f.Title + "  {" + f.Category + ", " + f.Severity + ", " + f.Confidence + (f.Count > 1 ? ", " + f.Count + "x" : "") + "}");
                Para(sb, "    Cause", f.Cause);
                foreach (var e in f.Evidence) sb.AppendLine("    Evidence: " + e);
                Para(sb, "    Look at", f.DevLook);
                Para(sb, "    Reproduce", f.Repro);
                sb.AppendLine();
            }
            sb.AppendLine("Confidence: confirmed = shown directly by the files; likely = strong evidence; possible = fits, not proven.");
            sb.AppendLine();
            sb.AppendLine("Repeated problems (grouped by message, " + d.Groups.Count + "):");
            if (d.Groups.Count == 0) sb.AppendLine("  none");
            for (int i = 0; i < d.Groups.Count && i < 30; i++) sb.AppendLine("  " + d.Groups[i]);
            sb.AppendLine();
            sb.AppendLine("Recent events (" + d.TimelineFrom + ", status lines left out):");
            foreach (var l in d.Timeline) sb.AppendLine("  " + l);
            sb.AppendLine();
            sb.AppendLine("Missing information:");
            if (string.IsNullOrEmpty(message)) d.Missing.Insert(0, "The player didn't describe what happened.");
            foreach (var m in d.Missing) sb.AppendLine("  - " + m);
            sb.AppendLine();
            sb.AppendLine("Diagnosis took " + d.Ms + " ms over " + d.Lines + " log lines (made at report time only - nothing runs while playing).");
            return sb.ToString();
        }

        static void Para(StringBuilder sb, string label, string text)
        {
            if (string.IsNullOrEmpty(text)) return;
            sb.AppendLine(label + ": " + text);
        }

        // Credentials, tokens, webhook addresses, e-mails and the Windows user name never leave the PC.
        public static string Scrub(string s)
        {
            if (string.IsNullOrEmpty(s)) return s;
            s = Regex.Replace(s, @"https?://(?:\w+\.)?discord(?:app)?\.com/api/webhooks/\S+", "[webhook hidden]", RegexOptions.IgnoreCase);
            s = Regex.Replace(s, @"(?i)\b(password|passwd|pw|token|secret|api[_-]?key|auth|ticket)(\s*[=:]\s*|\s+)(?!set\b|cleared\b|hidden\b)[^\s,;""']+", "$1$2[hidden]");
            s = Regex.Replace(s, @"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", "[email hidden]");
            s = Regex.Replace(s, @"\b[A-Za-z0-9+/_-]{48,}={0,2}", "[long token hidden]");
            string user = Environment.UserName;
            if (!string.IsNullOrEmpty(user) && user.Length > 1)
                s = Regex.Replace(s, @"([\\/]Users[\\/])" + Regex.Escape(user) + @"(?=[\\/])", "$1<user>", RegexOptions.IgnoreCase);
            return s;
        }

        static string Tag(string xml, string tag)
        {
            var m = Regex.Match(xml, "<" + tag + ">([^<]*)</" + tag + ">");
            return m.Success ? m.Groups[1].Value.Trim() : "";
        }

        public static string NewestCrash(string local)
        {
            try
            {
                string dir = Path.Combine(local, "Saved", "Crashes");
                if (!Directory.Exists(dir)) return null;
                string best = null; DateTime t = DateTime.MinValue;
                foreach (var dd in Directory.GetDirectories(dir))
                {
                    var w = Directory.GetLastWriteTime(dd);
                    if (w > t) { t = w; best = dd; }
                }
                return best;
            }
            catch { return null; }
        }

        static string Trunc(string s, int n) { return s == null ? "" : s.Length > n ? s.Substring(0, n - 3) + "..." : s; }

        static string ReadText(string path)
        {
            try
            {
                if (!File.Exists(path)) return null;
                using (var f = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                using (var r = new StreamReader(f, Encoding.UTF8)) return r.ReadToEnd();
            }
            catch { return null; }
        }

        static IEnumerable<string> ReadLines(string path)
        {
            string t = ReadText(path);
            if (t == null) yield break;
            using (var r = new StringReader(t))
            {
                string line;
                while ((line = r.ReadLine()) != null) yield return line;
            }
        }
    }
}
