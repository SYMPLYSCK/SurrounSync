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
    public static int HeartbeatMs = 60000;          // --realm-beat <ms> (tests)
    const int MAX_FILES = 32;
    const long MAX_BUNDLE = 16L * 1024 * 1024, MAX_UNPACKED = 32L * 1024 * 1024;
    const int MAX_OPS = 24;

    static readonly Regex ID = new Regex("^[0-9A-HJKMNP-TV-Z]{10}$");
    static readonly Regex FILE = new Regex("^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$");
    static readonly Regex MEMBER = new Regex("^[0-9A-Z]{8}$");
    // the owner's game rules, "<key> <value> ..." (the server checks the same shape)
    static readonly Regex RULES = new Regex("^[a-z]{1,16} [a-z0-9]{1,8}( [a-z]{1,16} [a-z0-9]{1,8}){0,31}$");
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
    readonly Dictionary<string, string> rulesOf = new Dictionary<string, string>(); // id -> the owner's rules (none = not set)
    long lastBeat = Environment.TickCount;
    // The mod says "hosting <id>" about every 30 s while it holds a Realm (game tick, or a timer while paused). A lease
    // it stopped confirming isn't heartbeated any more, so the server frees it within its 2 min: a hung game, or a
    // host who left without a release (0.14.2: the game's MAIN MENU), kept the Realm "hosted" for as long as the game
    // stayed open. A mod that never sent one (older) keeps the old behaviour. A late confirmation picks it up again.
    public static int HostingStaleMs = 150000;      // --hosting-stale <ms> (tests)
    readonly Dictionary<string, int> hostingAt = new Dictionary<string, int>();   // id -> TickCount of the last one
    readonly HashSet<string> staleLogged = new HashSet<string>();
    // The public server list (REALMS page, SERVERS): "server ..." lines from the last browse. The host's heartbeat
    // tells the server its player count and Steam ping location; browsing estimates each live host's ping from it.
    const int MAX_SERVERS = 100;
    readonly List<string> servers = new List<string>();
    long serversAt;
    volatile int playersNow = -1, playersMax = -1;
    public Func<string> PingLocation;            // this PC's Steam ping location (null = not known yet)
    public Func<string, int> PingTo;             // estimated ms to a ping location (-1 = unknown)
    bool beatBodyRefused;
    public void SetPlayers(int now, int max) { playersNow = now; playersMax = max; }

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
        if (url != "") new Thread(MotdLoop) { IsBackground = true, Name = "motd" }.Start();
    }

    // ---- message of the day (tools/motd.ps1 sets it on the server): mirror_motd.txt for the mod ----

    // every minute, so a sent message shows within one (user 2026-10-31); one ~80-byte GET, 60 an hour per player
    public static int MotdSeconds = 60;             // --motd-every <s> (tests)
    const int MAX_MOTD = 500;
    static readonly Regex MOTD_ID = new Regex("^[0-9A-HJKMNP-TV-Z]{8}$");
    string lastMotd, lastMotdError;

    void MotdLoop()
    {
        for (;;)
        {
            try { Motd(); lastMotdError = null; }
            catch (Exception e)
            {
                // (a server without the motd route, or offline: logged once until it changes, not every minute)
                string err = e is Api ? ((Api)e).Code + " " + Clean(e.Message) : Clean(e.Message);
                if (err != lastMotdError) log("motd: couldn't fetch the message of the day: " + err);
                lastMotdError = err;
            }
            Thread.Sleep(Math.Max(1, MotdSeconds) * 1000);
        }
    }

    // "motd <id> <expires, unix s, 0 = never> <text>" or "motd none", then END. A failed fetch keeps the file as it was.
    void Motd()
    {
        int status;
        byte[] data = CallRaw("GET", "/motd", null, null, null, null, out status, false);
        Dictionary<string, object> j;
        try { j = new JavaScriptSerializer().DeserializeObject(Encoding.UTF8.GetString(data)) as Dictionary<string, object>; }
        catch { throw new Api("bad_reply", "the server sent something unreadable"); }
        if (j == null) throw new Api("bad_reply", "the server sent something unreadable");
        string id = Str(j, "id"), text = Clean(Str(j, "text")).Trim();
        long exp;
        string line;
        if (id == "") line = "motd none";
        else if (!MOTD_ID.IsMatch(id) || text == "" || text.Length > MAX_MOTD || !long.TryParse(Str(j, "expires_at"), out exp) || exp < 0)
            throw new Api("bad_reply", "the server sent a message without its checks");
        else line = "motd " + id + " " + exp + " " + text;
        if (line == lastMotd) return;
        lock (writeLock) WriteFile(Path.Combine(dir, "mirror_motd.txt"), line + "\nEND\n");
        lastMotd = line;
        log("motd: " + (id == "" ? "no message of the day" : "message of the day " + id));
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
        if (j.verb == "hosting")
        {
            // (no server call: noted here, answered at once)
            string result = "fail bad_input not a Realm id";
            if (j.args.Length == 1 && ID.IsMatch(j.args[0]))
            {
                lock (state)
                {
                    hostingAt[j.args[0]] = Environment.TickCount;
                    if (staleLogged.Remove(j.args[0])) log("realms: " + j.args[0] + " confirmed again - heartbeats go on");
                }
                result = "ok";
            }
            lock (state) { ops.Add("op " + j.seq + " hosting " + result); while (ops.Count > MAX_OPS) ops.RemoveAt(0); }
            Write();
            return;
        }
        lock (jobs) jobs.Enqueue(j);
        signal.Set();
    }

    // ---- worker ----

    void Work()
    {
        while (true)
        {
            signal.WaitOne(Math.Max(100, Math.Min(5000, HeartbeatMs)));
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
            if (Environment.TickCount - lastBeat >= HeartbeatMs) { lastBeat = Environment.TickCount; Heartbeats(); }
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
            case "rules":
                if (j.args.Length < 3) throw new Api("bad_input", "no rules");
                return Rules(Id(j, 0), j.rest.Substring(j.rest.IndexOf(' ') + 1));
            case "leave": return Leave(Id(j, 0));
            case "delete": return Delete(Id(j, 0));
            case "rekey": return Rekey(Id(j, 0));
            case "forget": return Forget(Id(j, 0));
            case "copykey": return CopyKey(Id(j, 0));
            case "usekey": return UseKey(j.rest);
            case "browse": return Browse();
            case "public":
                if (j.args.Length < 2 || (j.args[1] != "on" && j.args[1] != "off")) throw new Api("bad_input", "public <id> on [password] | off");
                return SetPublic(Id(j, 0), j.args[1] == "on", After(j.rest, 2));
            case "joinpublic": return JoinPublic(Id(j, 0), After(j.rest, 1), j);
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
    // the text after the first n words (a password may hold spaces)
    static string After(string rest, int n)
    {
        string s = (rest ?? "").TrimStart();
        for (int i = 0; i < n && s != ""; i++)
        {
            int sp = s.IndexOf(' ');
            s = sp < 0 ? "" : s.Substring(sp + 1).TrimStart();
        }
        return s.Trim();
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
                TakeRules(id, s);
                SaveInfo(id, Str(s, "name"));
                if (File.Exists(RefusedFile(id))) DeleteLogged(RefusedFile(id));   // (the server knows the key again)
            }
            catch (Api e)
            {
                bad++;
                // removed from the Realm or the Realm deleted - or the server got it wrong for a while (2026-10-30: ids
                // starting with R were refused): the key is kept until the refusals have lasted for days
                if ((e.Code == "not_member" || e.Code == "no_realm") && Refused(id)) { Forget(id); continue; }
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
        // "pub <id> <listed 0|1> <locked 0|1> <invited|public>": on the server list, and how I joined it
        line.Append("\npub ").Append(id).Append(' ').Append(Str(s, "public") == "True" ? "1" : "0").Append(' ')
            .Append(Str(s, "locked") == "True" ? "1" : "0").Append(' ').Append(you != null && Str(you, "via") == "public" ? "public" : "invited");
        return line.ToString();
    }

    // ---- the public server list ----

    // "server <id> <live 0|1> <locked 0|1> <players> <max> <ping ms|-> <mine 0|1> <name>" per listed Realm
    string Browse()
    {
        var r = Call("GET", "/realms/public", null, null, null);
        var list = r.ContainsKey("realms") ? r["realms"] as object[] : null;
        if (list == null) throw new Api("bad_reply", "the server sent no list");
        var lines = new List<string>();
        foreach (var o in list)
        {
            var x = o as Dictionary<string, object>;
            string id = x == null ? "" : Str(x, "realm_id");
            if (!ID.IsMatch(id) || lines.Count >= MAX_SERVERS) continue;
            int players, max;
            if (!int.TryParse(Str(x, "players"), out players) || players < 0 || players > 64) players = 0;
            if (!int.TryParse(Str(x, "max_players"), out max) || max < 0 || max > 64) max = 0;
            bool live = Str(x, "live") == "True", locked = Str(x, "locked") == "True";
            int ping = -1;
            string loc = Str(x, "ping_loc");
            if (live && loc != "" && loc.Length <= 1024 && PingTo != null)
                try { ping = PingTo(loc); } catch { ping = -1; }
            string name = Clean(Str(x, "name")).Trim();
            if (name.Length > 40) name = name.Substring(0, 40);
            lines.Add("server " + id + " " + (live ? 1 : 0) + " " + (locked ? 1 : 0) + " " + players + " " + max + " "
                + (ping >= 0 && ping < 100000 ? ping.ToString() : "-") + " " + (File.Exists(KeyFile(id)) ? 1 : 0) + " " + (name == "" ? id : name));
        }
        lock (state) { servers.Clear(); servers.AddRange(lines); serversAt = DateTimeOffset.UtcNow.ToUnixTimeSeconds(); }
        return "ok " + lines.Count;
    }

    // the owner lists the Realm (open, or locked with a password) or takes it off; the password only goes to the server
    string SetPublic(string id, bool on, string password)
    {
        var b = new Dictionary<string, object> { { "public", on } };
        if (on && password != "")
        {
            if (password.Length > 64 || Clean(password) != password) throw new Api("bad_input", "a password is 1-64 plain characters");
            b["password"] = password;
        }
        var r = Call("PUT", "/realms/" + id + "/public", id, b, null);
        bool locked = Str(r, "locked") == "True";
        try { var s = Call("GET", "/realms/" + id, id, null, null); lock (state) listed[id] = RealmLine(id, s); }
        catch (Api e) { log("realms: list after public " + id + ": " + e.Code); }
        log("realms: " + id + (on ? " listed publicly" + (locked ? " (locked)" : "") : " taken off the public list"));
        return on ? "ok on " + (locked ? "locked" : "open") : "ok off";
    }

    // JOIN from the server list: a membership of my own (a key like an invite gives), then the mod plays it as usual
    string JoinPublic(string id, string password, Job j)
    {
        if (File.Exists(KeyFile(id)))
        {
            // a key the server no longer knows (the owner locked or unlisted it, a newer list join with my Steam id,
            // the never-seen prune) is set aside and a fresh membership made: JOIN used to answer ok with the dead key,
            // so the player stayed out until the 3-day refusal rule forgot it (Sentinel review 2026-11-01)
            try { Call("GET", "/realms/" + id, id, null, null); return "ok " + id + " " + Clean(ReadInfo(id) ?? id); }
            catch (Api e) { if (!Gone(e, id, "join")) throw; Forget(id); }
        }
        var b = new Dictionary<string, object> { { "steam_id", j.steam.ToString() }, { "player_name", Name(j.name, 32) } };
        if (password != "")
        {
            if (password.Length > 64 || Clean(password) != password) throw new Api("bad_password", "wrong password");
            b["password"] = password;
        }
        return Joined(Call("POST", "/realms/" + id + "/join", null, b, null));
    }

    // what the host's heartbeat tells the server list (null: nothing known, or the server refused it once)
    Dictionary<string, object> BeatBody()
    {
        if (beatBodyRefused) return null;
        var b = new Dictionary<string, object>();
        int n = playersNow, max = playersMax;
        if (n >= 0 && n <= 64) b["players"] = n;
        if (max >= 1 && max <= 64) b["max_players"] = max;
        string loc = null;
        if (PingLocation != null) try { loc = PingLocation(); } catch { loc = null; }
        if (!string.IsNullOrEmpty(loc) && loc.Length <= 1024 && Clean(loc) == loc) b["ping_loc"] = loc;
        return b.Count > 0 ? b : null;
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
        try { TakeRules(id, Call("POST", "/realms/" + id + "/lease/heartbeat", id, null, Lease(token))); }
        catch (Api e) { if (e.Code == "lease_lost") DropLease(id, "lost"); throw; }
        lock (state) leases[id] = "held";
        lastBeat = Environment.TickCount;
        return "ok";
    }

    // a Realm is hosted from this PC right now (its lease held)
    public bool HoldsLease()
    {
        lock (state) { foreach (var kv in leases) if (kv.Value == "held") return true; }
        return false;
    }

    void DropLease(string id, string why)
    {
        try { File.Delete(LeaseFile(id)); } catch { }
        lock (state) { if (why != null) leases[id] = why; else leases.Remove(id); }
    }

    // the game closed while hosting (quit or crash without ending the Realm): free it now, not when the lease runs out
    // 2 min later - members saw the host as still playing all that time
    public void ReleaseHeld()
    {
        List<string> held;
        lock (state) { held = new List<string>(); foreach (var kv in leases) if (kv.Value == "held") held.Add(kv.Key); }
        foreach (var id in held)
        {
            try { Release(id); log("realms: game closed - released " + id); }
            catch (Exception e) { log("realms: release of " + id + " at exit failed: " + Clean(e.Message)); }
        }
    }

    void Heartbeats()
    {
        List<string> held;
        lock (state) { held = new List<string>(); foreach (var kv in leases) if (kv.Value == "held") held.Add(kv.Key); }
        foreach (var id in held)
        {
            string token = Token(id);
            if (token == null) { DropLease(id, "lost"); continue; }
            int at; bool stale;
            lock (state) stale = hostingAt.TryGetValue(id, out at) && unchecked(Environment.TickCount - at) > HostingStaleMs;
            if (stale)
            {
                bool first; lock (state) first = staleLogged.Add(id);
                if (first) log("realms: the game hasn't confirmed hosting " + id + " for " + HostingStaleMs / 1000 + " s - no more heartbeats, the server frees it");
                continue;
            }
            // (the answer carries the owner's rules: a change reaches the host's game within a minute)
            try
            {
                Dictionary<string, object> answer = null;
                var body = BeatBody();
                try { answer = Call("POST", "/realms/" + id + "/lease/heartbeat", id, body, Lease(token)); }
                catch (Api e)
                {
                    if (body == null || (e.Code != "bad_input" && e.Code != "bad_json")) throw;
                    // the server list's numbers must never cost the lease: the plain heartbeat goes at once, and from now on
                    beatBodyRefused = true;
                    log("realms: heartbeat details refused (" + Clean(e.Message) + ") - plain heartbeats from now on");
                }
                if (answer == null) answer = Call("POST", "/realms/" + id + "/lease/heartbeat", id, null, Lease(token));
                if (TakeRules(id, answer)) Write();
            }
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

    // The game rules every host of the Realm plays by (hostrules.lua): only the owner may set them (the server answers
    // owner_only otherwise); hosts get them with the list and the heartbeat.
    string Rules(string id, string rules)
    {
        rules = rules.Trim();
        if (rules.Length > 512 || !RULES.IsMatch(rules)) throw new Api("bad_input", "bad rules");
        TakeRules(id, Call("PUT", "/realms/" + id + "/rules", id, new Dictionary<string, object> { { "rules", rules } }, null));
        return "ok";
    }

    // the owner's rules out of a status, heartbeat or rules answer; true when they changed. An answer without the
    // field (an older server) changes nothing.
    bool TakeRules(string id, Dictionary<string, object> r)
    {
        if (r == null || !r.ContainsKey("rules")) return false;
        string s = Str(r, "rules");
        if (s.Length > 512 || !RULES.IsMatch(s)) s = "";
        lock (state)
        {
            string old;
            if (!rulesOf.TryGetValue(id, out old)) old = "";
            if (old == s) return false;
            if (s == "") rulesOf.Remove(id); else rulesOf[id] = s;
        }
        return true;
    }

    // LEAVE / DELETE of a Realm the server no longer has me in (removed, left on another PC, deleted): the player wants
    // it gone, so it is forgotten here too. It wasn't (2026-10-30 17:46: "Couldn't leave TEst (not_member ...)" twice,
    // the Realm stayed in the list).
    string Leave(string id)
    {
        try { Call("DELETE", "/realms/" + id + "/members/" + Member(id).Key, id, null, null); }
        catch (Api e) { if (!Gone(e, id, "leave")) throw; }
        return Forget(id);
    }

    string Delete(string id)
    {
        try { Call("DELETE", "/realms/" + id, id, null, null); }
        catch (Api e) { if (!Gone(e, id, "delete")) throw; }
        return Forget(id);
    }

    bool Gone(Api e, string id, string verb)
    {
        if (e.Code != "not_member" && e.Code != "no_realm") return false;
        log("realms: " + verb + " " + id + ": " + e.Code + " - forgetting it on this PC");
        return true;
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

    // One more "not a member" / "no such Realm" for this key: true once they have come REFUSED_TIMES times over at
    // least REFUSED_DAYS days (refused.txt: "<first unix s> <count>"; a good answer removes it)
    const int REFUSED_TIMES = 5;
    const long REFUSED_DAYS = 3;
    bool Refused(string id)
    {
        long now = DateTimeOffset.UtcNow.ToUnixTimeSeconds(), first = now;
        int count = 0;
        string path = RefusedFile(id);
        if (File.Exists(path))
        {
            try
            {
                var p = File.ReadAllText(path).Trim().Split(' ');
                long f; int c;
                if (p.Length == 2 && long.TryParse(p[0], out f) && int.TryParse(p[1], out c) && f <= now) { first = f; count = c; }
            }
            catch (Exception e) { log("realms: can't read " + path + " (" + e.Message + ") - counting from now"); }
        }
        count++;
        // (unwritten, the count stays low and the key is kept: the safe side)
        try { WriteFile(path, first + " " + count + "\n"); }
        catch (Exception e) { log("realms: can't write " + path + " (" + e.Message + ")"); }
        bool gone = count >= REFUSED_TIMES && now - first >= REFUSED_DAYS * 86400;
        if (!gone && count == 1) log("realms: the server doesn't know my key for " + id + " - kept, shown offline");
        return gone;
    }

    // the key only: the Realm's world copies stay on disk until the mod clears them. The key is moved aside, never
    // deleted (member.key.forgotten): one a server mistake took can be put back by hand
    string Forget(string id)
    {
        string k = KeyFile(id), old = k + ".forgotten";
        try { if (File.Exists(k)) { if (File.Exists(old)) File.Delete(old); File.Move(k, old); } }
        catch (Exception e)
        {
            // (it must stop counting as a membership: as before, removed outright)
            log("realms: can't move the key of " + id + " aside (" + e.Message + ") - deleting it");
            DeleteLogged(k);
        }
        DeleteLogged(RefusedFile(id));
        DropLease(id, null);
        lock (state) { listed.Remove(id); rulesOf.Remove(id); }
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
    string RefusedFile(string id) { return Path.Combine(RealmDir(id), "refused.txt"); }
    void DeleteLogged(string path)
    {
        try { File.Delete(path); }
        catch (Exception e) { log("realms: can't delete " + path + " (" + e.Message + ")"); }
    }
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
            // "rules <id> <key> <value> ..." (older mods skip the unknown key)
            foreach (var kv in rulesOf) sb.Append("rules ").Append(kv.Key).Append(' ').Append(kv.Value).Append('\n');
            // "servers <unix s of the last browse> <count>", then its "server ..." lines (older mods skip both)
            if (serversAt > 0)
            {
                sb.Append("servers ").Append(serversAt).Append(' ').Append(servers.Count).Append('\n');
                foreach (var l in servers) sb.Append(l).Append('\n');
            }
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
