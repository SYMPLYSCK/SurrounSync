// Realms: shared worlds kept on the SurrounSync Realms server between sessions (realms-backend/).
//
// The mod asks through the bridge's command file ("realm <seq> <verb> <args>"); every call runs in order on one
// worker thread and its answer lands in mirror_realms.txt ("op <seq> <verb> ok|fail <detail>"). Member keys and
// lease tokens never leave the bridge: they live in <dir>\Saved\SurrounSyncRealms\<id>\ and the mod only sees
// whether it is a member. World files travel as one zip of the flat files in the Realm's "up" folder; a
// download unpacks into its "down" folder after the hash check. The mod decides what goes in and what a
// downloaded world may contain.

using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

class Realms
{
    public const string DefaultUrl = "https://surrounsync-realms.surrounsync-realms.workers.dev";   // realms-backend, deployed 2026-10-26
    const int FORMAT = 1;                           // bundle layout version (the server keeps it per Realm)
    const int HEARTBEAT_MS = 60000;
    const int MAX_FILES = 32;
    const long MAX_BUNDLE = 16L * 1024 * 1024, MAX_UNPACKED = 32L * 1024 * 1024;
    const int MAX_OPS = 24;

    static readonly Regex ID = new Regex("^[0-9A-HJKMNP-TV-Z]{10}$");
    static readonly Regex FILE = new Regex("^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$");
    static readonly Regex MEMBER = new Regex("^[0-9A-Z]{8}$");
    static readonly Regex KEY = new Regex("^[A-Za-z0-9_-]{43}$");
    static readonly Regex TOKEN = new Regex("^[A-Za-z0-9_-]{32}$");

    readonly string dir, root, url, modVersion, protocol, gameBuild;
    readonly Action<string> log;
    readonly object writeLock = new object();
    readonly Queue<Job> jobs = new Queue<Job>();
    readonly AutoResetEvent signal = new AutoResetEvent(false);
    readonly object state = new object();
    readonly List<string> ops = new List<string>();                         // newest last
    readonly Dictionary<string, string> listed = new Dictionary<string, string>();  // id -> "realm ..." line
    readonly Dictionary<string, string> leases = new Dictionary<string, string>();  // id -> held|lost
    long lastBeat = Environment.TickCount;

    class Job { public string seq, verb; public string[] args; public string rest; public ulong steam; public string name; }

    public Realms(string dir, string apiUrl, string modDir, string build, Action<string> log)
    {
        this.dir = dir;
        root = Path.Combine(dir, "Saved", "SurrounSyncRealms");
        url = (apiUrl ?? "").TrimEnd('/');
        this.log = log;
        modVersion = SurrounSyncShared.Release.ModVersion(modDir) ?? "unknown";
        int p;
        protocol = int.TryParse(SurrounSyncShared.Release.ModProtocol(modDir), out p) && p > 0 ? p.ToString() : "1";
        gameBuild = string.IsNullOrEmpty(build) ? "unknown" : build;
        // a lease token left on disk is NOT heartbeated on its own: after a crash the player may sit at the main
        // menu, and keeping their lease alive would lock everyone else out. The mod sends "resume" while it hosts.
        var th = new Thread(Work) { IsBackground = true, Name = "realms" };
        th.Start();
        Write();
    }

    // the server's address: --realms-url, else %LOCALAPPDATA%\SurrounSync\realms_url.txt, else the built-in one
    public static string ResolveUrl(string arg)
    {
        if (!string.IsNullOrEmpty(arg)) return arg;
        try
        {
            string f = Path.Combine(SurrounSyncShared.Release.AppDir, "realms_url.txt");
            if (File.Exists(f))
            {
                string s = File.ReadAllText(f).Trim();
                if (s.StartsWith("https://") || s.StartsWith("http://127.0.0.1:")) return s;
            }
        }
        catch { }
        return DefaultUrl;
    }

    // ---- commands (main thread) ----

    public void Command(string line, ulong steam, string name)
    {
        var parts = line.Trim().Split(new[] { ' ' }, 3);
        if (parts.Length < 2) { log("realms: bad command '" + line + "'"); return; }
        var j = new Job { seq = parts[0], verb = parts[1], rest = parts.Length > 2 ? parts[2] : "", steam = steam, name = name };
        j.args = j.rest.Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
        if (!Regex.IsMatch(j.seq, "^[0-9]{1,9}$")) { log("realms: bad sequence in '" + line + "'"); return; }
        lock (jobs) jobs.Enqueue(j);
        signal.Set();
    }

    // ---- worker ----

    void Work()
    {
        while (true)
        {
            signal.WaitOne(5000);
            for (;;)
            {
                Job j = null;
                lock (jobs) if (jobs.Count > 0) j = jobs.Dequeue();
                if (j == null) break;
                string result;
                try { result = Run(j); }
                catch (Api e) { result = "fail " + e.Code + " " + Clean(e.Message); }
                catch (Exception e) { result = "fail error " + Clean(e.Message); }
                if (result.StartsWith("fail")) log("realms: " + j.verb + " failed: " + result.Substring(5));
                lock (state)
                {
                    ops.Add("op " + j.seq + " " + j.verb + " " + result);
                    while (ops.Count > MAX_OPS) ops.RemoveAt(0);
                }
                Write();
            }
            if (Environment.TickCount - lastBeat >= HEARTBEAT_MS) { lastBeat = Environment.TickCount; Heartbeats(); }
        }
    }

    string Run(Job j)
    {
        if (url == "") throw new Api("unset", "Realms aren't set up in this version");
        switch (j.verb)
        {
            case "list": return List();
            case "create": return Create(j);
            case "redeem": return Redeem(j);
            case "claim": return Claim(Id(j, 0), j);
            case "release": return Release(Id(j, 0));
            case "resume": return Resume(Id(j, 0));
            case "download": return Download(Id(j, 0));
            case "upload": return Upload(Id(j, 0), Gen(j, 1));
            case "invite": return Invite(Id(j, 0), j.args.Length > 1 && j.args[1] == "copy");
            case "rename":
                if (j.args.Length < 2) throw new Api("bad_input", "no name");
                return Rename(Id(j, 0), j.rest.Substring(j.rest.IndexOf(' ') + 1));
            case "leave": return Leave(Id(j, 0));
            case "delete": return Delete(Id(j, 0));
            case "rekey": return Rekey(Id(j, 0));
            case "forget": return Forget(Id(j, 0));
            case "copykey": return CopyKey(Id(j, 0));
            case "usekey": return UseKey(j.rest);
        }
        throw new Api("bad_command", "unknown Realm command " + j.verb);
    }

    static string Id(Job j, int i)
    {
        string s = i < j.args.Length ? j.args[i].ToUpperInvariant().Replace("-", "") : "";
        if (s.StartsWith("R") && s.Length == 11) s = s.Substring(1);
        if (!ID.IsMatch(s)) throw new Api("bad_input", "not a Realm id");
        return s;
    }
    static int Gen(Job j, int i)
    {
        int g;
        if (i >= j.args.Length || !int.TryParse(j.args[i], out g) || g < 1) throw new Api("bad_input", "bad generation");
        return g;
    }

    string List()
    {
        var seen = new Dictionary<string, string>();
        int bad = 0;
        foreach (var id in Known())
        {
            try
            {
                var s = Call("GET", "/realms/" + id, id, null, null);
                seen[id] = RealmLine(id, s);
                SaveInfo(id, Str(s, "name"));
            }
            catch (Api e)
            {
                bad++;
                // removed from the Realm or the Realm deleted: the key is useless now
                if (e.Code == "not_member" || e.Code == "no_realm") { Forget(id); continue; }
                seen[id] = "realm " + id + " offline - 0 0 - " + Clean(ReadInfo(id) ?? id);
            }
        }
        lock (state) { listed.Clear(); foreach (var kv in seen) listed[kv.Key] = kv.Value; }
        return "ok " + seen.Count + (bad > 0 ? " " + bad + "_unreachable" : "");
    }

    // "realm <id> <role> <hostSteam|-> <headGen> <members> <hostName|-> <name>" - the name may hold spaces, so last
    string RealmLine(string id, Dictionary<string, object> s)
    {
        var you = s.ContainsKey("you") ? s["you"] as Dictionary<string, object> : null;
        var host = s.ContainsKey("host") ? s["host"] as Dictionary<string, object> : null;
        var head = s.ContainsKey("head") ? s["head"] as Dictionary<string, object> : null;
        var members = s.ContainsKey("members") ? s["members"] as object[] : null;
        string hostSteam = host != null ? Str(host, "steam_id") : "-";
        string hostName = host != null ? Str(host, "name").Replace(' ', '_') : "-";
        var line = new StringBuilder("realm " + id + " " + (you != null ? Str(you, "role") : "member") + " " + hostSteam + " "
            + (head != null ? Str(head, "gen") : "0") + " " + (members != null ? members.Length : 0) + " "
            + (hostName == "" ? "-" : hostName) + " " + Clean(Str(s, "name")));
        // then one "member <id> <role> <steam|-> <lastSeen> <name>" per member (the REALMS page lists them;
        // older mods skip the unknown key)
        if (members != null)
            foreach (var o in members)
            {
                var mm = o as Dictionary<string, object>;
                if (mm == null) continue;
                string ms = Str(mm, "steam_id"), seen = Str(mm, "last_seen"), mn = Clean(Str(mm, "name")).Trim();
                line.Append("\nmember ").Append(id).Append(' ').Append(Str(mm, "role") == "owner" ? "owner" : "member")
                    .Append(' ').Append(ms == "" ? "-" : ms).Append(' ').Append(seen == "" ? "0" : seen)
                    .Append(' ').Append(mn == "" ? "?" : mn);
            }
        return line.ToString();
    }

    string Create(Job j)
    {
        string name = Name(j.rest, 40);
        var b = new Dictionary<string, object> {
            { "name", name }, { "steam_id", j.steam.ToString() }, { "player_name", Name(j.name, 32) },
            { "format", FORMAT }, { "protocol", int.Parse(protocol) }, { "mod_version", modVersion }, { "game_build", gameBuild } };
        var r = Call("POST", "/realms", null, b, null);
        return Joined(r);
    }

    string Redeem(Job j)
    {
        string code = j.rest.Trim().ToUpperInvariant().Replace("-", "").Replace(" ", "");
        if (!Regex.IsMatch(code, "^[0-9A-HJKMNP-TV-Z]{16}$")) throw new Api("bad_input", "that isn't an invite code");
        var b = new Dictionary<string, object> { { "invite", code }, { "steam_id", j.steam.ToString() }, { "player_name", Name(j.name, 32) } };
        return Joined(Call("POST", "/invites/redeem", null, b, null));
    }

    // a new membership (create or redeem): the key goes to disk before anything else can fail
    string Joined(Dictionary<string, object> r)
    {
        string id = Str(r, "realm_id"), mid = Str(r, "member_id"), key = Str(r, "key");
        if (!ID.IsMatch(id) || !MEMBER.IsMatch(mid) || !KEY.IsMatch(key)) throw new Api("bad_reply", "the server sent a bad membership");
        Directory.CreateDirectory(RealmDir(id));
        WriteFile(KeyFile(id), mid + ":" + key + "\n");
        SaveInfo(id, Str(r, "name"));
        log("realms: joined Realm " + Str(r, "code") + " as " + mid);
        return "ok " + id + " " + Clean(Str(r, "name"));
    }

    string Claim(string id, Job j)
    {
        var b = new Dictionary<string, object> { { "steam_id", j.steam.ToString() }, { "name", Name(j.name, 32) } };
        int status;
        var r = Call("POST", "/realms/" + id + "/lease", id, b, null, out status);
        if (status == 409)
        {
            var h = r.ContainsKey("host") ? r["host"] as Dictionary<string, object> : null;
            return "ok hosted " + (h != null ? Str(h, "steam_id") : "0") + " " + (h != null ? Clean(Str(h, "name")) : "");
        }
        string token = Str(r, "lease_token");
        if (!TOKEN.IsMatch(token)) throw new Api("bad_reply", "the server sent a bad lease");
        WriteFile(LeaseFile(id), token + "\n");
        lock (state) leases[id] = "held";
        lastBeat = Environment.TickCount;
        log("realms: hosting " + id + " (newest world " + Str(r, "head_gen") + ")");
        return "ok won " + Str(r, "head_gen");
    }

    string Release(string id)
    {
        string token = Token(id);
        try { if (token != null) Call("DELETE", "/realms/" + id + "/lease", id, null, Lease(token)); }
        finally { DropLease(id, null); }
        return "ok";
    }

    // the bridge restarted while the mod hosts: heartbeat the token on disk again (the server says if it still counts)
    string Resume(string id)
    {
        string token = Token(id);
        if (token == null) { DropLease(id, "lost"); throw new Api("lease_lost", "no lease to resume"); }
        try { Call("POST", "/realms/" + id + "/lease/heartbeat", id, null, Lease(token)); }
        catch (Api e) { if (e.Code == "lease_lost") DropLease(id, "lost"); throw; }
        lock (state) leases[id] = "held";
        lastBeat = Environment.TickCount;
        return "ok";
    }

    void DropLease(string id, string why)
    {
        try { File.Delete(LeaseFile(id)); } catch { }
        lock (state) { if (why != null) leases[id] = why; else leases.Remove(id); }
    }

    void Heartbeats()
    {
        List<string> held;
        lock (state) { held = new List<string>(); foreach (var kv in leases) if (kv.Value == "held") held.Add(kv.Key); }
        foreach (var id in held)
        {
            string token = Token(id);
            if (token == null) { DropLease(id, "lost"); continue; }
            try { Call("POST", "/realms/" + id + "/lease/heartbeat", id, null, Lease(token)); }
            catch (Api e)
            {
                log("realms: heartbeat for " + id + ": " + e.Code);
                if (e.Code == "lease_lost" || e.Code == "not_member" || e.Code == "no_realm") { DropLease(id, "lost"); Write(); }
            }
        }
    }

    string Download(string id)
    {
        string down = Path.Combine(RealmDir(id), "down");
        if (Directory.Exists(down)) Directory.Delete(down, true);
        Directory.CreateDirectory(down);
        string gen, sha;
        byte[] data = Fetch("/realms/" + id + "/world", id, out gen, out sha);
        if (data == null) return "ok none";
        if (Sha(data) != sha) throw new Api("bad_hash", "the download was damaged");
        int n = Unpack(data, down);
        return "ok " + gen + " " + n;
    }

    string Upload(string id, int gen)
    {
        string token = Token(id);
        if (token == null) throw new Api("lease_lost", "you are not hosting this Realm");
        byte[] data = Pack(Path.Combine(RealmDir(id), "up"));
        var h = Lease(token);
        h["X-Sha256"] = Sha(data);
        try { CallRaw("PUT", "/realms/" + id + "/world/" + gen, id, data, "application/octet-stream", h); }
        catch (Api e) { if (e.Code == "lease_lost") DropLease(id, "lost"); throw; }
        lastBeat = Environment.TickCount;   // an upload extends the lease
        return "ok " + gen + " " + data.Length;
    }

    // "invite <id> copy" (the INVITE buttons) also puts the code on the clipboard - here, off the game thread: the
    // mod's own clip call froze the game for a second. ADD FRIENDS HERE sends codes over the link: no copy.
    string Invite(string id, bool copy)
    {
        var r = Call("POST", "/realms/" + id + "/invites", id, null, null);
        string code = Str(r, "invite");
        if (!copy) return "ok " + code;
        string b = code.Replace("-", "");   // (the server sends it dashed already)
        string shown = b.Length > 12 ? b.Substring(0, 4) + "-" + b.Substring(4, 4) + "-" + b.Substring(8, 4) + "-" + b.Substring(12) : code;
        bool copied;
        try { copied = Clip(shown); }
        catch (Exception e) { Console.Error.WriteLine("realms: invite copy failed: " + e.Message); copied = false; }
        return "ok " + code + (copied ? " copied" : " nocopy");
    }

    internal static bool Clip(string text)
    {
        var p = new System.Diagnostics.Process();
        p.StartInfo = new System.Diagnostics.ProcessStartInfo("clip.exe") { UseShellExecute = false, RedirectStandardInput = true, CreateNoWindow = true };
        p.Start();
        p.StandardInput.Write(text);
        p.StandardInput.Close();
        return p.WaitForExit(5000) && p.ExitCode == 0;
    }

    string Rename(string id, string name)
    {
        var r = Call("PATCH", "/realms/" + id, id, new Dictionary<string, object> { { "name", Name(name, 40) } }, null);
        SaveInfo(id, Str(r, "name"));
        return "ok";
    }

    string Leave(string id)
    {
        string mid = Member(id).Key;
        Call("DELETE", "/realms/" + id + "/members/" + mid, id, null, null);
        return Forget(id);
    }

    string Delete(string id)
    {
        Call("DELETE", "/realms/" + id, id, null, null);
        return Forget(id);
    }

    string Rekey(string id)
    {
        var r = Call("POST", "/realms/" + id + "/key", id, null, null);
        string mid = Str(r, "member_id"), key = Str(r, "key");
        if (!MEMBER.IsMatch(mid) || !KEY.IsMatch(key)) throw new Api("bad_reply", "the server sent a bad key");
        WriteFile(KeyFile(id), mid + ":" + key + "\n");
        return "ok";
    }

    // COPY MY KEY / USE A KEY (a new PC, a reinstall): the key goes straight to the clipboard from here, so it never
    // passes through the mod or a log. Text form: SSRK1.<realm id>.<member id>.<key> (base64url has no dots).
    static readonly Regex KEYTEXT = new Regex(@"^SSRK1\.([0-9A-HJKMNP-TV-Z]{10})\.([0-9A-Z]{8})\.([A-Za-z0-9_-]{43})$");

    string CopyKey(string id)
    {
        var m = Member(id);
        if (!Clip("SSRK1." + id + "." + m.Key + "." + m.Value)) throw new Api("clipboard", "couldn't copy to the clipboard");
        return "ok";
    }

    // the pasted key is checked with the server before it replaces anything on disk
    string UseKey(string text)
    {
        var mt = KEYTEXT.Match((text ?? "").Trim());
        if (!mt.Success) throw new Api("bad_input", "that isn't a Realm key");
        string id = mt.Groups[1].Value, auth = "Member " + mt.Groups[2].Value + ":" + mt.Groups[3].Value;
        var s = Call("GET", "/realms/" + id, null, null, new Dictionary<string, string> { { "Authorization", auth } });
        Directory.CreateDirectory(RealmDir(id));
        WriteFile(KeyFile(id), mt.Groups[2].Value + ":" + mt.Groups[3].Value + "\n");
        SaveInfo(id, Str(s, "name"));
        lock (state) listed[id] = RealmLine(id, s);
        log("realms: key for Realm " + id + " restored");
        return "ok " + id + " " + Clean(Str(s, "name"));
    }

    // the key only: the Realm's world copies stay on disk until the mod clears them
    string Forget(string id)
    {
        try { File.Delete(KeyFile(id)); } catch { }
        DropLease(id, null);
        lock (state) listed.Remove(id);
        log("realms: no longer a member of " + id);
        return "ok";
    }

    // ---- bundle ----

    static byte[] Pack(string folder)
    {
        if (!Directory.Exists(folder)) throw new Api("no_world", "nothing to upload");
        var files = Directory.GetFiles(folder);
        if (files.Length == 0) throw new Api("no_world", "nothing to upload");
        if (files.Length > MAX_FILES) throw new Api("too_large", "too many files");
        using (var ms = new MemoryStream())
        {
            using (var z = new ZipArchive(ms, ZipArchiveMode.Create, true))
                foreach (var f in files)
                {
                    string n = Path.GetFileName(f);
                    if (!FILE.IsMatch(n)) throw new Api("bad_input", "bad file name " + n);
                    var e = z.CreateEntry(n, CompressionLevel.Optimal);
                    using (var src = File.OpenRead(f)) using (var dst = e.Open()) src.CopyTo(dst);
                }
            if (ms.Length > MAX_BUNDLE) throw new Api("too_large", "the world is too big to upload");
            return ms.ToArray();
        }
    }

    // flat files with plain names only, sizes capped while reading (a zip can claim any size)
    static int Unpack(byte[] data, string folder)
    {
        long total = 0; int n = 0;
        using (var z = new ZipArchive(new MemoryStream(data), ZipArchiveMode.Read))
        {
            if (z.Entries.Count > MAX_FILES) throw new Api("bad_world", "too many files in the world");
            foreach (var e in z.Entries)
            {
                if (!FILE.IsMatch(e.FullName)) throw new Api("bad_world", "bad file name in the world");
                string to = Path.Combine(folder, e.FullName);
                using (var src = e.Open()) using (var dst = File.Create(to))
                {
                    var buf = new byte[65536];
                    int k;
                    while ((k = src.Read(buf, 0, buf.Length)) > 0)
                    {
                        total += k;
                        if (total > MAX_UNPACKED) throw new Api("bad_world", "the world unpacks too big");
                        dst.Write(buf, 0, k);
                    }
                }
                n++;
            }
        }
        return n;
    }

    // ---- local files ----

    string RealmDir(string id) { return Path.Combine(root, id); }
    string KeyFile(string id) { return Path.Combine(RealmDir(id), "member.key"); }
    string LeaseFile(string id) { return Path.Combine(RealmDir(id), "lease.token"); }
    string InfoFile(string id) { return Path.Combine(RealmDir(id), "realm.txt"); }

    List<string> Known()
    {
        var ids = new List<string>();
        try { if (Directory.Exists(root)) foreach (var d in Directory.GetDirectories(root)) { string id = Path.GetFileName(d); if (ID.IsMatch(id) && File.Exists(KeyFile(id))) ids.Add(id); } }
        catch { }
        ids.Sort(StringComparer.Ordinal);
        return ids;
    }

    KeyValuePair<string, string> Member(string id)
    {
        string s = null;
        try { s = File.ReadAllText(KeyFile(id)).Trim(); } catch { }
        int at = s == null ? -1 : s.IndexOf(':');
        if (at < 0 || !MEMBER.IsMatch(s.Substring(0, at)) || !KEY.IsMatch(s.Substring(at + 1)))
            throw new Api("not_member", "you are not a member of this Realm on this PC");
        return new KeyValuePair<string, string>(s.Substring(0, at), s.Substring(at + 1));
    }

    string Token(string id)
    {
        try { string t = File.ReadAllText(LeaseFile(id)).Trim(); return TOKEN.IsMatch(t) ? t : null; } catch { return null; }
    }

    void SaveInfo(string id, string name) { if (!string.IsNullOrEmpty(name)) try { WriteFile(InfoFile(id), "name=" + Clean(name) + "\n"); } catch { } }
    string ReadInfo(string id)
    {
        try { foreach (var l in File.ReadAllLines(InfoFile(id))) if (l.StartsWith("name=")) return l.Substring(5); } catch { }
        return null;
    }

    static void WriteFile(string path, string text)
    {
        string tmp = path + ".tmp";
        File.WriteAllText(tmp, text);
        if (File.Exists(path)) File.Replace(tmp, path, null); else File.Move(tmp, path);
    }

    void Write()
    {
        var sb = new StringBuilder();
        sb.Append("realms ").Append(url == "" ? "unset" : "on").Append(' ').Append(DateTimeOffset.UtcNow.ToUnixTimeSeconds()).Append('\n');
        lock (state)
        {
            foreach (var l in listed.Values) sb.Append(l).Append('\n');
            foreach (var kv in leases) sb.Append("lease ").Append(kv.Key).Append(' ').Append(kv.Value).Append('\n');
            foreach (var o in ops) sb.Append(o).Append('\n');
        }
        sb.Append("END\n");
        lock (writeLock)
            try { WriteFile(Path.Combine(dir, "mirror_realms.txt"), sb.ToString()); }
            catch (Exception e) { log("realms: couldn't write mirror_realms.txt: " + e.Message); }
    }

    // ---- HTTP ----

    class Api : Exception { public string Code; public Api(string code, string message) : base(message) { Code = code; } }

    static Dictionary<string, string> Lease(string token) { return new Dictionary<string, string> { { "X-Lease-Token", token } }; }

    Dictionary<string, object> Call(string method, string path, string id, Dictionary<string, object> body, Dictionary<string, string> headers)
    {
        int status;
        var r = Call(method, path, id, body, headers, out status);
        if (status == 409) throw Error(r, status);
        return r;
    }

    // 409 comes back to the caller (a lost lease claim is an answer, not a failure); other errors throw
    Dictionary<string, object> Call(string method, string path, string id, Dictionary<string, object> body, Dictionary<string, string> headers, out int status)
    {
        byte[] data = body == null ? null : Encoding.UTF8.GetBytes(new JavaScriptSerializer().Serialize(body));
        string text = Encoding.UTF8.GetString(CallRaw(method, path, id, data, "application/json", headers, out status, true));
        try { return (new JavaScriptSerializer().DeserializeObject(text) as Dictionary<string, object>) ?? new Dictionary<string, object>(); }
        catch { throw new Api("bad_reply", "the server sent something unreadable"); }
    }

    byte[] CallRaw(string method, string path, string id, byte[] data, string type, Dictionary<string, string> headers)
    {
        int status;
        return CallRaw(method, path, id, data, type, headers, out status, false);
    }

    byte[] CallRaw(string method, string path, string id, byte[] data, string type, Dictionary<string, string> headers, out int status, bool allow409)
    {
        ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
        var req = (HttpWebRequest)WebRequest.Create(url + "/v1" + path);
        req.Method = method;
        req.UserAgent = "SurrounSync-Realms/" + modVersion;
        req.Timeout = data != null && data.Length > 65536 ? 120000 : 20000;
        req.ReadWriteTimeout = req.Timeout;
        if (id != null) { var m = Member(id); req.Headers["Authorization"] = "Member " + m.Key + ":" + m.Value; }
        if (headers != null) foreach (var h in headers) req.Headers[h.Key] = h.Value;
        if (data != null)
        {
            req.ContentType = type;
            req.ContentLength = data.Length;
            using (var s = req.GetRequestStream()) s.Write(data, 0, data.Length);
        }
        else if (method == "POST" || method == "PUT" || method == "PATCH") req.ContentLength = 0;
        try
        {
            using (var resp = (HttpWebResponse)req.GetResponse())
            {
                status = (int)resp.StatusCode;
                return ReadAll(resp, MAX_BUNDLE);
            }
        }
        catch (WebException e)
        {
            var hr = e.Response as HttpWebResponse;
            if (hr == null) throw new Api("offline", "can't reach the Realms server (" + e.Status + ")");
            using (hr)
            {
                status = (int)hr.StatusCode;
                byte[] b = ReadAll(hr, 65536);
                if (status == 409 && allow409) return b;
                Dictionary<string, object> j = null;
                try { j = new JavaScriptSerializer().DeserializeObject(Encoding.UTF8.GetString(b)) as Dictionary<string, object>; } catch { }
                throw Error(j, status);
            }
        }
    }

    // GET of a binary: null when the server has nothing yet (404 no_world)
    byte[] Fetch(string path, string id, out string gen, out string sha)
    {
        gen = sha = null;
        ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
        var req = (HttpWebRequest)WebRequest.Create(url + "/v1" + path);
        req.UserAgent = "SurrounSync-Realms/" + modVersion;
        req.Timeout = req.ReadWriteTimeout = 120000;
        var m = Member(id);
        req.Headers["Authorization"] = "Member " + m.Key + ":" + m.Value;
        try
        {
            using (var resp = (HttpWebResponse)req.GetResponse())
            {
                gen = resp.Headers["x-gen"]; sha = (resp.Headers["x-sha256"] ?? "").ToLowerInvariant();
                int g;
                if (!int.TryParse(gen, out g) || g < 1 || !Regex.IsMatch(sha, "^[0-9a-f]{64}$")) throw new Api("bad_reply", "the server sent a world without its checks");
                return ReadAll(resp, MAX_BUNDLE);
            }
        }
        catch (WebException e)
        {
            var hr = e.Response as HttpWebResponse;
            if (hr == null) throw new Api("offline", "can't reach the Realms server (" + e.Status + ")");
            using (hr)
            {
                Dictionary<string, object> j = null;
                try { j = new JavaScriptSerializer().DeserializeObject(Encoding.UTF8.GetString(ReadAll(hr, 65536))) as Dictionary<string, object>; } catch { }
                var err = Error(j, (int)hr.StatusCode);
                if (err.Code == "no_world") return null;
                throw err;
            }
        }
    }

    static Api Error(Dictionary<string, object> j, int status)
    {
        string code = j != null ? Str(j, "error") : "";
        string msg = j != null ? Str(j, "message") : "";
        return new Api(code != "" ? code : "http_" + status, msg != "" ? msg : "the server answered " + status);
    }

    static byte[] ReadAll(WebResponse resp, long max)
    {
        using (var s = resp.GetResponseStream())
        using (var ms = new MemoryStream())
        {
            var buf = new byte[65536];
            int n;
            while ((n = s.Read(buf, 0, buf.Length)) > 0)
            {
                ms.Write(buf, 0, n);
                if (ms.Length > max) throw new Api("too_large", "the server sent too much");
            }
            return ms.ToArray();
        }
    }

    static string Sha(byte[] data)
    {
        using (var h = SHA256.Create())
        {
            var sb = new StringBuilder();
            foreach (var b in h.ComputeHash(data)) sb.Append(b.ToString("x2"));
            return sb.ToString();
        }
    }

    static string Str(Dictionary<string, object> d, string k)
    {
        object v;
        return d != null && d.TryGetValue(k, out v) && v != null ? Convert.ToString(v, System.Globalization.CultureInfo.InvariantCulture) : "";
    }

    static string Name(string s, int max)
    {
        s = Clean(s ?? "").Trim();
        if (s.Length > max) s = s.Substring(0, max);
        return s == "" ? "Player" : s;
    }

    static string Clean(string s)
    {
        var sb = new StringBuilder();
        foreach (char c in s ?? "") sb.Append(c < ' ' || c == '\u007f' ? ' ' : c);
        return sb.ToString();
    }
}
