// Tests the bug report diagnosis (bridge/Diagnose.cs + Report in bridge/Common.cs) on made-up game folders whose
// log lines are copied from real tester reports. Built and run by tools/test-report.py.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using SurrounSyncShared;

static class TestReport
{
    static int failed;
    static string root;
    static string noHangs;   // the run's own empty hangs folder: real freeze notes on this PC must not leak into the tests

    static void Check(bool ok, string what)
    {
        Console.WriteLine((ok ? "  ok   " : "  FAIL ") + what);
        if (!ok) failed++;
    }

    static string Dir(string name)
    {
        string d = Path.Combine(root, name);
        if (Directory.Exists(d)) Directory.Delete(d, true);
        Directory.CreateDirectory(Path.Combine(d, "win64", "ue4ss", "Mods", "SurrounSync", "Scripts", "mirror"));
        Directory.CreateDirectory(Path.Combine(d, "local", "Saved", "Crashes"));
        File.WriteAllText(Path.Combine(d, "win64", "ue4ss", "Mods", "SurrounSync", "Scripts", "mirror", "version.lua"),
            "local version = {}\nversion.VERSION = \"0.11.0\"\nversion.PROTOCOL = 47\nreturn version\n");
        File.WriteAllText(Path.Combine(d, "win64", "ue4ss", "UE4SS.log"), "[2026-10-24] Event loop start\n");
        File.WriteAllBytes(Path.Combine(d, "win64", "ue4ss", "UE4SS.dll"), new byte[] { 77, 90 });
        File.WriteAllText(Path.Combine(d, "win64", "ue4ss", "Mods", "mods.txt"), "SurrounSync : 1\nKeybinds : 1\nSDTrainer : 1\n");
        return d;
    }

    static void Log(string d, string file, IEnumerable<string> lines, DateTime when)
    {
        string p = Path.Combine(d, "win64", file);
        File.WriteAllLines(p, lines);
        File.SetLastWriteTime(p, when);
    }

    static void Crash(string d, string name, string msg, string stack, DateTime when)
    {
        string c = Path.Combine(d, "local", "Saved", "Crashes", name);
        Directory.CreateDirectory(c);
        File.WriteAllText(Path.Combine(c, "CrashContext.runtime-xml"),
            "<FGenericCrashContext><RuntimeProperties><ErrorMessage>" + msg + "</ErrorMessage><CallStack>" + stack +
            "</CallStack></RuntimeProperties></FGenericCrashContext>");
        File.WriteAllBytes(Path.Combine(c, "UEMinidump.dmp"), new byte[16]);
        File.SetLastWriteTime(Path.Combine(c, "CrashContext.runtime-xml"), when);
        Directory.SetLastWriteTime(c, when);
    }

    static Diagnosis Run(string d) { return Diagnose.Run(Path.Combine(d, "win64"), Path.Combine(d, "local")); }

    static Finding Find(Diagnosis g, string titlePart)
    {
        return g.Findings.FirstOrDefault(f => f.Title.Contains(titlePart));
    }

    static string L(string time, string level, string text) { return time + " [SurrounSync][" + level + "] " + text; }

    const string Status = "phase1[guest]: rx 24.6/s, last 0.00s ago | ghost guest 1 m from you | zombies: 17 copies";
    const string Tactical = "safe() caught in tactical.send (x50 in 5 s): ...Win64/ue4ss/Mods/SurrounSync/Scripts/mirror\\tactical.lua:51: attempt to compare TrivialObject with number";

    static void RepeatedErrorsAreGroupedAndExplained()
    {
        Console.WriteLine("repeated_errors_are_grouped_and_explained");
        string d = Dir("tactical");
        var lines = new List<string> { L("10:00:00", "INFO", "SurrounSync 0.11.0 (protocol 47) starting (role=auto from mirror_role.txt)"), L("10:00:05", "INFO", Status) };
        for (int i = 0; i < 70; i++) lines.Add(L("10:01:" + (i % 60).ToString("00"), "WARN", Tactical));
        lines.Add(L("10:02:00", "WARN", "safe() caught in tactical.send: ...Win64/ue4ss/Mods/SurrounSync/Scripts/mirror\\tactical.lua:52: attempt to compare TrivialObject with number"));
        Log(d, "mirror_log.txt", lines, DateTime.Now);
        var g = Run(d);
        var f = Find(g, "Flashlight/laser");
        Check(f != null && f.Count == 70 * 50 + 1, "70 batched lines (x50 each) + 1 plain line count as 3501 of one problem");
        Check(g.Groups.Count == 1, "lines that differ only in numbers are one group");
        Check(f != null && f.Severity == "ERROR" && f.Confidence == "confirmed", "a known error is explained, marked confirmed");
        Check(f != null && f.PlayerTry.Contains("Update SurrounSync") && f.Workaround.Contains("Unequip"), "the player gets the fix version and a workaround");
        Check(f != null && f.DevLook.Contains("tactical.lua"), "the developer is pointed at tactical.lua");
        Check(g.Role == "guest", "the role comes from the sync status lines");
    }

    static void VersionMismatchSaveSafetyAndConnection()
    {
        Console.WriteLine("version_mismatch_save_safety_and_connection");
        string d = Dir("mixed");
        var lines = new List<string> { L("11:00:00", "INFO", "phase1[host]: rx 20/s") };
        for (int i = 0; i < 3; i++) lines.Add(L("11:00:1" + i, "ERROR", "phase1: the other game sends poses but no protocol announcement - it runs an OLDER SurrounSync; restart it"));
        lines.Add(L("11:01:00", "ERROR", "slotguard: refused copy_character_home: AutoSave3 is not one of your saves"));
        for (int i = 0; i < 6; i++) lines.Add(L("11:02:0" + i, "WARN", "notify: Lost connection to Dilucaa."));
        lines.Add(L("11:03:00", "ERROR", "safe() caught in vehicles.tick: ...Scripts/mirror\\vehicles.lua:123: attempt to index a nil value (field 'FuelComponent')"));
        Log(d, "mirror_log.txt", lines, DateTime.Now);
        var g = Run(d);
        Check(g.Top != null && g.Top.Title.StartsWith("Save protection") && g.Top.Severity == "CRITICAL", "save safety is the top (CRITICAL) finding");
        var v = Find(g, "different SurrounSync versions");
        Check(v != null && v.Count == 3 && v.Expected != "" && v.Actual != "", "version mismatch: grouped, with expected vs actual");
        var c = Find(g, "Connection to the other player dropped");
        Check(c != null && c.Count == 6 && c.Severity == "ERROR" && c.Confidence == "likely", "6 dropped connections = ERROR, cause only 'likely'");
        Check(g.Peer == "Dilucaa" && g.Role == "host", "the other player's name and this role are known");
        var e = Find(g, "car sync (vehicles.lua:123)");
        Check(e != null && e.What.Contains("wasn't there") && e.DevLook.Contains("vehicles.lua line 123"), "an unknown Lua error names the feature, the plain meaning and the line");
        Check(g.Missing.Any(m => m.Contains("other player") && m.Contains("Dilucaa")), "asks for the other player's report");
    }

    static void CrashesAreExplainedWithTheModStep()
    {
        Console.WriteLine("crashes_are_explained_with_the_mod_step");
        DateTime at = DateTime.Now.AddMinutes(-20);
        string d = Dir("gpu");
        Log(d, "mirror_log.txt", new[] { L("12:00:00", "INFO", "phase1[host]: rx 20/s") }, at.AddSeconds(-2));
        File.WriteAllText(Path.Combine(d, "win64", "mirror_step.txt"), "12:00:01 game (mod tick done)");
        File.SetLastWriteTime(Path.Combine(d, "win64", "mirror_step.txt"), at.AddSeconds(-1));
        Crash(d, "UECC-1", "GPU Crash dump Triggered", "SurrounDead_Win64_Shipping 0x00007ff6 + 1234", at);
        var g = Run(d);
        Check(g.Top != null && g.Top.Title == "Game crash in the graphics driver" && g.Top.Confidence == "likely", "GPU crash: graphics driver, likely");
        Check(g.Top != null && g.Top.Cause.Contains("wasn't running any of its own code"), "the mod step shows the mod was idle");
        Check(g.Top != null && g.Top.Evidence.Any(x => x.Contains("GPU Crash dump")), "the crash message is evidence");

        d = Dir("ue4ss");
        Log(d, "mirror_log.txt", new[] { L("12:00:00", "INFO", "phase1[guest]: rx 20/s") }, at.AddSeconds(-2));
        File.WriteAllText(Path.Combine(d, "win64", "mirror_step.txt"), "03:55:43 hook /Game/JigSInventory/Jigsaw/Widgets/JContextMenu/JigContextMenuComp.JigContextMenuComp_C:OnJigItemRightClick");
        File.SetLastWriteTime(Path.Combine(d, "win64", "mirror_step.txt"), at.AddSeconds(-1));
        Crash(d, "UECC-2", "Unhandled Exception: EXCEPTION_ACCESS_VIOLATION reading address 0x0000000000000040", "UE4SS 0x00007ffa + 1aa", at);
        g = Run(d);
        Check(g.Top != null && g.Top.Title.Contains("UE4SS") && g.Top.Confidence == "likely", "UE4SS crash during a mod hook: likely the mod");
        Check(g.Top != null && g.Top.Cause.Contains("backpack names") && g.Top.DevLook.Contains("names.lua"), "the hook maps to backpack names / names.lua");

        d = Dir("known");
        Log(d, "mirror_log.txt", new[] { L("12:00:00", "INFO", "phase1[guest]: rx 20/s") }, at);
        Crash(d, "UECC-3", "Unhandled Exception: EXCEPTION_ACCESS_VIOLATION reading address 0x0000000000000360",
            "SurrounDead_Win64_Shipping 0x00007ff7 + 3ecd5ff", at);
        g = Run(d);
        Check(g.Top != null && g.Top.Title.Contains("car driving over zombie copies"), "a known crash address is recognised");
        Check(g.Missing.Any(m => m.Contains("No SurrounSync step file")), "a missing step file is reported as missing information");

        d = Dir("files");
        Log(d, "mirror_log.txt", new[] { L("12:00:00", "INFO", "x") }, at);
        Crash(d, "UECC-4", "LowLevelFatalError [File:D:\\build\\Archive.cpp] [Line: 762] BulkData compressed header read error. This package may be corrupt!",
            "SurrounDead_Win64_Shipping", at);
        g = Run(d);
        Check(g.Top != null && g.Top.Category == "Crash (game files)" && g.Top.PlayerTry.Contains("Verify integrity"), "a corrupt-package crash says verify the game files");

        d = Dir("hang");
        Log(d, "mirror_log.txt", new[] { L("12:00:00", "INFO", "x") }, at);
        Crash(d, "UECC-5", "GameThread timed out waiting for RenderThread after 120.00 seconds:", "SurrounDead-Win64-Shipping 0x00007ff7 + 13950be", at);
        g = Run(d);
        Check(g.Top != null && g.Top.Category == "Freeze", "a render-thread timeout is a freeze (hang), also with zero mod errors");
    }

    static void TheCrashedRunIsTheOneExplained()
    {
        Console.WriteLine("the_crashed_run_is_the_one_explained");
        DateTime at = DateTime.Now.AddMinutes(-30);
        string d = Dir("prevrun");
        Log(d, "mirror_log.1.txt", new[] { L("09:00:00", "INFO", "phase1[guest]: rx 20/s"), L("09:00:10", "INFO", "vehicles: got in BigRig"),
                                          L("09:00:11", "INFO", "zombies: copy 12 hit by car") }, at.AddSeconds(-3));
        Log(d, "mirror_log.txt", new[] { L("09:40:00", "INFO", "SurrounSync 0.11.0 (protocol 47) starting"), L("09:40:01", "INFO", "SurrounSync ready.") }, DateTime.Now);
        Crash(d, "UECC-6", "Unhandled Exception: EXCEPTION_ACCESS_VIOLATION reading address 0x58", "SurrounDead_Win64_Shipping", at);
        var g = Run(d);
        Check(g.TimelineFrom.Contains("mirror_log.1.txt"), "after a restart, the run that crashed is explained");
        Check(g.Timeline.Count == 2 && g.Timeline[1].Contains("hit by car"), "the timeline is the last events before the crash, status lines left out");
        Check(g.Top != null && g.Top.Confidence == "possible" && g.Top.Cause.Contains("Unknown"), "no step info = cause stays unknown, confidence 'possible'");

        // restarted within 2 minutes: the new run's log is also "near" the crash, but it began after it
        DateTime ca = DateTime.Now.AddMinutes(-5);
        Func<int, string> t = s => ca.AddSeconds(s).ToString("HH:mm:ss");
        d = Dir("quickrestart");
        Log(d, "mirror_log.1.txt", new[] { L(t(-60), "INFO", "phase1[host]: rx 20/s"), L(t(-5), "INFO", "loot: open seen (init): BP_Zombie_Roamer_C") }, ca.AddSeconds(-5));
        Log(d, "mirror_log.txt", new[] { L(t(47), "INFO", "SurrounSync 0.12.0 (protocol 48) starting"), L(t(98), "INFO", "SurrounSync ready.") }, ca.AddSeconds(98));
        Crash(d, "UECC-8", "Unhandled Exception: EXCEPTION_ACCESS_VIOLATION reading address 0xffffffffffffffff", "UE4SS", ca);
        g = Run(d);
        Check(g.TimelineFrom.Contains("mirror_log.1.txt"), "a quick restart: the run that crashed is explained, not the new one");
        Check(g.Top != null && g.Top.Evidence.Any(x => x.Contains("5 s before the crash")), "the last line's gap is seconds, not a day");

        d = Dir("oldcrash");
        Log(d, "mirror_log.txt", new[] { L("09:40:00", "INFO", "SurrounSync ready.") }, DateTime.Now);
        Crash(d, "UECC-7", "GPU Crash dump Triggered", "SurrounDead_Win64_Shipping", DateTime.Now.AddDays(-2));
        g = Run(d);
        Check(g.Findings.Count == 1 && g.Top.Title == "No problem found in the logs", "a 2-day-old crash isn't blamed on this run");
        Check(g.Context.Any(c => c.Contains("older than")), "but it is mentioned");
    }

    static void MissingLogsAndQuietRuns()
    {
        Console.WriteLine("missing_logs_and_quiet_runs");
        string d = Dir("empty");
        var g = Run(d);
        Check(g.Missing.Any(m => m.Contains("mirror_log.txt") && m.Contains("missing")), "a missing log is reported, not invented");
        Check(g.Top.Title == "No problem found in the logs" && g.Top.Severity == "INFO", "nothing found = INFO, the player's message is the clue");
        string text = Diagnose.Text(g, null);
        Check(text.Contains("didn't describe what happened"), "no message is listed as missing information");
        Check(text.IndexOf("PLAYER SUMMARY") < text.IndexOf("DEVELOPER DIAGNOSTICS"), "player summary first, developer diagnostics second");
        g = Diagnose.Run(null, Path.Combine(d, "local"));
        Check(g.Missing.Any(m => m.Contains("game folder wasn't found")), "no game folder at all is handled");
    }

    static void SensitiveDataIsFiltered()
    {
        Console.WriteLine("sensitive_data_is_filtered");
        string user = Environment.UserName;
        string raw = "webhook https://discord.com/api/webhooks/123456/abcDEF_ghi and password=hunter2 token: abc123 " +
                     "mail me@example.com path C:\\Users\\" + user + "\\AppData\\x key " + new string('A', 60) +
                     " | bridge: password set | password cleared";
        string s = Diagnose.Scrub(raw);
        Check(!s.Contains("abcDEF") && s.Contains("[webhook hidden]"), "webhook addresses are hidden");
        Check(!s.Contains("hunter2") && !s.Contains("abc123"), "passwords and tokens are hidden");
        Check(!s.Contains("me@example.com"), "e-mail addresses are hidden");
        Check(user.Length < 2 || !s.Contains("\\Users\\" + user + "\\"), "the Windows user name is hidden in paths");
        Check(!s.Contains(new string('A', 60)), "long secrets are hidden");
        Check(s.Contains("password set") && s.Contains("password cleared"), "harmless status words stay readable");
    }

    static void ReportPackageAndDuplicates()
    {
        Console.WriteLine("report_package_and_duplicates");
        string d = Dir("package");
        Log(d, "mirror_log.txt", new[] { L("13:00:00", "INFO", "phase1[host]: rx 20/s"),
                                        L("13:00:01", "INFO", "save at C:\\Users\\" + Environment.UserName + "\\AppData\\Local\\SurrounDead"),
                                        L("13:00:02", "WARN", Tactical) }, DateTime.Now);
        string outDir = Path.Combine(d, "out");
        Directory.CreateDirectory(outDir);
        Report.OutDir = outDir;
        string err;
        string zip = Report.Create(Path.Combine(d, "win64"), out err, false, "My car vanished after I got out. pw=secret1");
        Check(zip != null && File.Exists(zip), "the report zip is made (" + (err ?? "ok") + ")");
        if (zip == null) return;
        using (var a = ZipFile.OpenRead(zip))
        {
            var names = a.Entries.Select(e => e.FullName).ToList();
            Check(names.Contains("report.txt") && names.Contains("message.txt") && names.Contains("game/mirror_log.txt"), "report.txt, message.txt and the log are packed");
            string rep = new StreamReader(a.GetEntry("report.txt").Open()).ReadToEnd();
            Check(rep.Contains("PLAYER SUMMARY") && rep.Contains("DEVELOPER DIAGNOSTICS") && rep.Contains("SYSTEM DETAILS"), "report.txt has both levels and the old system details");
            Check(rep.Contains("Your message: My car vanished") && !rep.Contains("secret1"), "the message is included, its password hidden");
            string log = new StreamReader(a.GetEntry("game/mirror_log.txt").Open()).ReadToEnd();
            Check(Environment.UserName.Length < 2 || !log.Contains("\\Users\\" + Environment.UserName + "\\"), "packed logs are scrubbed");
        }
        var g = Run(d);
        string post = Report.Post(g, "hi");
        Check(post.StartsWith("**Message:** hi") && post.Contains("**What happened:**") && post.Length < 4000, "the Discord post leads with the message and the plain summary");

        string last = Path.Combine(Release.AppDir, "last_report.txt");
        string keep = File.Exists(last) ? File.ReadAllText(last) : null;
        try
        {
            Report.Remember(g.Fingerprint);
            string e1, e2;
            Check(Report.Duplicate(g.Fingerprint, "", out e1) && e1.Contains("already sent"), "the same report within 15 min isn't sent twice");
            Check(!Report.Duplicate(g.Fingerprint, "new detail", out e2), "but it is when the player adds a message");
            Check(!Report.Duplicate(g.Fingerprint + "x", "", out e2), "and a different problem is always sent");
        }
        finally { if (keep != null) File.WriteAllText(last, keep); else File.Delete(last); }
    }

    static void PerformanceIsBounded()
    {
        Console.WriteLine("performance_is_bounded");
        string d = Dir("big");
        var lines = new List<string>(200000);
        var r = new Random(1);
        for (int i = 0; i < 200000; i++)
        {
            int k = i % 10;
            lines.Add(k == 0 ? L("14:00:00", "WARN", Tactical) : k == 1 ? L("14:00:00", "ERROR", "loot: odd thing number " + r.Next() + " in box " + r.Next())
                : k == 2 ? L("14:00:00", "WARN", "unique warning text variant " + (char)('a' + r.Next(26)) + (char)('a' + r.Next(26)) + (char)('a' + r.Next(26)))
                : L("14:00:00", "INFO", Status));
        }
        Log(d, "mirror_log.txt", lines, DateTime.Now);
        var sw = Stopwatch.StartNew();
        var g = Run(d);
        sw.Stop();
        Console.WriteLine("       200000 log lines (~" + new FileInfo(Path.Combine(d, "win64", "mirror_log.txt")).Length / 1048576 + " MB) diagnosed in " + sw.ElapsedMilliseconds + " ms");
        Check(g.Groups.Count <= 200, "distinct problem groups are capped (" + g.Groups.Count + ")");
        Check(g.Timeline.Count <= 25, "the timeline is bounded");
        Check(sw.ElapsedMilliseconds < 15000, "a huge log is diagnosed in reasonable time");
    }

    // a guest's game froze 7 times with no crash report (2026-10-27): a report made while the game hangs carries a dump
    static void FrozenGameGetsAHangDump()
    {
        Console.WriteLine("frozen_game_gets_a_hang_dump");
        string self = Process.GetCurrentProcess().MainModule.FileName;
        var p = Process.Start(new ProcessStartInfo(self, "--hang") { UseShellExecute = false });
        try
        {
            bool hung = false;
            for (int i = 0; i < 60 && !hung; i++) { System.Threading.Thread.Sleep(250); p.Refresh(); hung = p.MainWindowHandle != IntPtr.Zero && !p.Responding; }
            Check(hung, "the stand-in game window stops responding");
            Report.HangProcess = Path.GetFileNameWithoutExtension(self);
            string d = Dir("hang");
            Log(d, "mirror_log.txt", new[] { L("13:00:00", "INFO", "session: checkpoint save (items changed hands)") }, DateTime.Now);
            string outDir = Path.Combine(d, "out");
            Directory.CreateDirectory(outDir);
            Report.OutDir = outDir;
            string err;
            string zip = Report.Create(Path.Combine(d, "win64"), out err, false, null);
            Check(zip != null, "the report is made (" + (err ?? "ok") + ")");
            if (zip == null) return;
            using (var a = ZipFile.OpenRead(zip))
            {
                var dump = a.GetEntry("hang/SurrounDead-hang.dmp");
                var note = a.GetEntry("hang/hang.txt");
                string text = note != null ? new StreamReader(note.Open()).ReadToEnd() : "";
                Check(dump != null && dump.Length > 1024, "the frozen game's dump is packed (" + text.Trim() + ")");
                Check(text.Contains("not responding"), "hang.txt says the game wasn't responding");
                var hangs = a.Entries.Where(e => e.FullName.StartsWith("hang/")).Select(e => e.FullName).ToList();
                Check(hangs.Count == 2, "only the frozen process is dumped, not this responding one (" + string.Join(", ", hangs) + ")");
            }
        }
        finally
        {
            try { p.Kill(); } catch { }
            Report.HangProcess = "SurrounDead-Win64-Shipping";
        }
    }

    // the bridge's game watch catches a freeze by itself: CPU per thread + a dump at 8 s, a freeze finding in the report
    static void GameWatchCatchesAFreeze()
    {
        Console.WriteLine("game_watch_catches_a_freeze");
        string self = Process.GetCurrentProcess().MainModule.FileName;
        string d = Dir("watch");
        GameWatch.HangDirOverride = Path.Combine(d, "hangs");
        var lines = new List<string>();
        var p = Process.Start(new ProcessStartInfo(self, "--hang") { UseShellExecute = false });
        try
        {
            new GameWatch(m => { lock (lines) lines.Add(m); }, Path.GetFileNameWithoutExtension(self)).Start();
            var until = DateTime.Now.AddSeconds(40);
            while (DateTime.Now < until && !Directory.Exists(GameWatch.HangDirOverride)) System.Threading.Thread.Sleep(500);
            System.Threading.Thread.Sleep(1000);
            string[] dumps = Directory.Exists(GameWatch.HangDirOverride) ? Directory.GetFiles(GameWatch.HangDirOverride, "hang-*.dmp") : new string[0];
            string[] notes = Directory.Exists(GameWatch.HangDirOverride) ? Directory.GetFiles(GameWatch.HangDirOverride, "hang-*.txt") : new string[0];
            string all; lock (lines) all = string.Join("\n", lines);
            Check(all.Contains("watch: the game stopped responding"), "the watch notices the frozen window");
            Check(dumps.Length == 1 && new FileInfo(dumps[0]).Length > 1024, "a dump is written by itself after 8 s (" + dumps.Length + ")");
            string note = notes.Length > 0 ? File.ReadAllText(notes[0]) : "";
            Check(note.Contains("busiest") && note.Contains("commit"), "the note has CPU per thread and memory (" + note.Trim() + ")");
            Check(all.Contains("watch: game ") && all.Contains("MB private"), "a health line is logged");
            var dg = Diagnose.Run(null, Path.Combine(d, "nolocal"));
            var fr = dg.Findings.FirstOrDefault(f => f.Category == "Freeze");
            Check(fr != null && fr.Severity == "CRITICAL" && fr.Evidence.Any(e => e.Contains("busiest")), "the report leads with the freeze and its CPU note");
        }
        finally
        {
            try { p.Kill(); } catch (InvalidOperationException) { }
            GameWatch.HangDirOverride = noHangs;
        }
        string ring = Path.Combine(d, "steps.txt");
        File.WriteAllText(ring, "66 21:20:19 812.400 session".PadRight(99) + "\n" + "65 21:20:19 812.390 zombies".PadRight(99) + "\n" + "garbage\n");
        string steps = Report.RecentSteps(ring);
        Check(steps != null && steps.IndexOf("zombies") < steps.IndexOf("session") && !steps.Contains("garbage"), "recent steps come out oldest first");
    }

    // audit N35/N36/N4: a friend's game freeze is named as such, the peer name has no state word, a load isn't a freeze
    static void PeerFreezeLoadAndPeerName()
    {
        Console.WriteLine("peer_freeze_load_and_peer_name");
        string d = Dir("peerfreeze");
        // (real line shapes, kit 2026-10-27: "last rx" on the link line is the connector's heartbeat - it stays low
        // through a game freeze; the game data's age is on the phase1[host] line)
        string lk = "phase1: link bridge host: me 7656, peer K3YBOARD32 (7657), last rx {0} s, pkts tx 1 rx 1, KB tx 0 rx 0, blobs tx 0 rx 0 peer_hb {0} peer_game {1} at 1793094228 rtt 300 ms";
        string gd = "phase1[host]: rx {0}/s, last {1}s ago | ghost {2} | zombies: sending 0 zombie(s)";
        Log(d, "mirror_log.txt", new[] {
            // a normal leave: their ghost goes at once, their game at home keeps sending
            L("03:10:10", "INFO", string.Format(lk, "0.0", "alive")), L("03:10:10", "INFO", string.Format(gd, "22.0", "0.99", "none")),
            L("03:10:15", "INFO", string.Format(lk, "0.4", "alive")), L("03:10:15", "INFO", string.Format(gd, "0.0", "5.99", "none")),
            L("03:10:20", "INFO", string.Format(lk, "0.4", "alive")), L("03:10:20", "INFO", string.Format(gd, "4.6", "0.03", "none")),
            // joined again, then their game froze for good and closed
            L("03:20:10", "INFO", string.Format(lk, "0.1", "alive")), L("03:20:10", "INFO", string.Format(gd, "27.4", "0.00", "host 2 m from you")),
            L("03:20:35", "WARN", "phase1: no data from the other game for 10 s (paused, loading or closed)"),
            L("03:20:40", "INFO", string.Format(lk, "0.3", "alive")), L("03:20:40", "INFO", string.Format(gd, "0.0", "25.45", "host 2 m from you")),
            L("03:20:45", "INFO", string.Format(lk, "0.3", "alive")), L("03:20:45", "INFO", string.Format(gd, "0.0", "30.45", "host 2 m from you")),
            L("03:21:10", "INFO", string.Format(lk, "-1.0", "gone")), L("03:21:10", "INFO", string.Format(gd, "0.0", "55.46", "host 2 m from you")),
        }, DateTime.Now);
        File.WriteAllText(Path.Combine(d, "local", "mirror_lobby.txt"), "peer 7657 ap connected\n");
        GameWatch.HangDirOverride = Path.Combine(d, "hangs");
        Directory.CreateDirectory(GameWatch.HangDirOverride);
        File.WriteAllText(Path.Combine(GameWatch.HangDirOverride, "hang-20261027-030000-1.txt"),
            "frozen 9 s " + GameWatch.DuringLoad + " | busiest: #1 900 ms\r\n");
        try
        {
            var g = Run(d);
            var pf = Find(g, "other player's game froze");
            Check(pf != null && pf.Count == 1 && pf.What.Contains("1x it then closed"), "the friend's game freeze (then close) is named");
            Check(g.Context.Any(c => c.Contains("other player: ap") && !c.Contains("ap connected")), "the lobby name has no state word");
            Check(Find(g, "world load took") != null && Find(g, "The game froze") == null, "a hang during a world load is a slow load, not a freeze");
        }
        finally { GameWatch.HangDirOverride = noHangs; }
    }

    // 3-4 players: every other player's module copy logs its own link line + game-data line, interleaved. One
    // friend frozen 15 s while the other plays on is one freeze, not one per status round.
    static void PeerFreezeWithSeveralPlayers()
    {
        Console.WriteLine("peer_freeze_with_several_players");
        string d = Dir("peerfreeze3");
        string lk = "phase1: link bridge host: me 7656, peer {0} ({1}), last rx 0.1 s, pkts tx 1 rx 1, KB tx 0 rx 0, blobs tx 0 rx 0 peer_hb 0.2 peer_game alive at 1793094228 rtt 30 ms";
        string gd = "phase1[host]: rx {0}/s, last {1}s ago | ghost host 3 m from you | zombies: sending 0 zombie(s)";
        var lines = new List<string>();
        int s = 0;
        foreach (var age in new[] { "0.01", "22.40", "27.40", "32.40", "0.02" })
        {
            string t = "04:00:" + (10 + s * 5).ToString("00");
            lines.Add(L(t, "INFO", string.Format(lk, "Anna", 7657))); lines.Add(L(t, "INFO", string.Format(gd, age == "0.01" || age == "0.02" ? "27.0" : "0.0", age)));
            lines.Add(L(t, "INFO", string.Format(lk, "Ben", 7658))); lines.Add(L(t, "INFO", string.Format(gd, "26.8", "0.03")));
            s++;
        }
        Log(d, "mirror_log.txt", lines.ToArray(), DateTime.Now);
        var g = Run(d);
        var pf = Find(g, "other player's game froze");
        Check(pf != null && pf.Count == 1, "one friend's freeze is counted once while another plays on (" + (pf == null ? "none" : pf.Count + "x: " + string.Join(" / ", pf.Evidence)) + ")");
    }

    static int Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "--hang")
        {
            var f = new System.Windows.Forms.Form();
            f.Show();
            System.Threading.Thread.Sleep(120000);
            return 0;
        }
        root = Path.Combine(Path.GetTempPath(), "surrounsync-test-report");
        Directory.CreateDirectory(root);
        noHangs = Path.Combine(Dir("nohangs"), "hangs");
        GameWatch.HangDirOverride = noHangs;
        var tests = new Action[] { RepeatedErrorsAreGroupedAndExplained, VersionMismatchSaveSafetyAndConnection, CrashesAreExplainedWithTheModStep,
                                   TheCrashedRunIsTheOneExplained, MissingLogsAndQuietRuns, SensitiveDataIsFiltered, ReportPackageAndDuplicates,
                                   PerformanceIsBounded, FrozenGameGetsAHangDump, GameWatchCatchesAFreeze, PeerFreezeLoadAndPeerName, PeerFreezeWithSeveralPlayers };
        foreach (var t in tests)
        {
            try { t(); }
            catch (Exception e) { failed++; Console.WriteLine("  FAIL " + t.Method.Name + " raised " + e); }
        }
        try { Directory.Delete(root, true); } catch { }
        Console.WriteLine();
        Console.WriteLine(failed == 0 ? "ALL PASSED" : failed + " FAILED");
        return failed == 0 ? 0 : 1;
    }
}
