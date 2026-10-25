// SurrounSyncBridge: carries the mod's link files between the two games over Steam P2P, using the
// game's own steam_api64.dll. Also handles join requests, passwords, public games, voice and update checks.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

static class Steam
{
    const string DLL = "steam_api64.dll";
    [DllImport(DLL)] public static extern bool SteamAPI_Init();
    [DllImport(DLL)] public static extern void SteamAPI_Shutdown();
    [DllImport(DLL)] public static extern int SteamAPI_GetHSteamPipe();
    [DllImport(DLL)] public static extern void SteamAPI_ManualDispatch_Init();
    [DllImport(DLL)] public static extern void SteamAPI_ManualDispatch_RunFrame(int pipe);
    [DllImport(DLL)] [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool SteamAPI_ManualDispatch_GetNextCallback(int pipe, out CallbackMsg msg);
    [DllImport(DLL)] public static extern void SteamAPI_ManualDispatch_FreeLastCallback(int pipe);

    [DllImport(DLL)] public static extern IntPtr SteamAPI_SteamNetworking_v006();
    [DllImport(DLL)] [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool SteamAPI_ISteamNetworking_SendP2PPacket(IntPtr self, ulong id, byte[] data, uint len, int sendType, int channel);
    [DllImport(DLL)] [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool SteamAPI_ISteamNetworking_IsP2PPacketAvailable(IntPtr self, out uint size, int channel);
    [DllImport(DLL)] [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool SteamAPI_ISteamNetworking_ReadP2PPacket(IntPtr self, byte[] dest, uint cap, out uint size, out ulong from, int channel);
    [DllImport(DLL)] [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool SteamAPI_ISteamNetworking_AcceptP2PSessionWithUser(IntPtr self, ulong id);
    [DllImport(DLL)] [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool SteamAPI_ISteamNetworking_AllowP2PPacketRelay(IntPtr self, [MarshalAs(UnmanagedType.I1)] bool allow);
    [DllImport(DLL)] [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool SteamAPI_ISteamNetworking_CloseP2PSessionWithUser(IntPtr self, ulong id);
    [StructLayout(LayoutKind.Sequential)]
    public struct P2PSessionState
    {
        public byte Active, Connecting, Error, UsingRelay;
        public int BytesQueued, PacketsQueued;
        public uint RemoteIP;
        public ushort RemotePort;
    }
    [DllImport(DLL)] [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool SteamAPI_ISteamNetworking_GetP2PSessionState(IntPtr self, ulong id, out P2PSessionState state);

    [DllImport(DLL)] public static extern IntPtr SteamAPI_SteamUser_v021();
    [DllImport(DLL)] public static extern void SteamAPI_ISteamUser_StartVoiceRecording(IntPtr self);
    [DllImport(DLL)] public static extern void SteamAPI_ISteamUser_StopVoiceRecording(IntPtr self);
    [DllImport(DLL)] public static extern int SteamAPI_ISteamUser_GetAvailableVoice(IntPtr self, out uint compressed, IntPtr uncompressedDeprecated, uint rateDeprecated);
    [DllImport(DLL)] public static extern int SteamAPI_ISteamUser_GetVoice(IntPtr self, [MarshalAs(UnmanagedType.I1)] bool wantCompressed, byte[] dest, uint destSize, out uint written,
        [MarshalAs(UnmanagedType.I1)] bool wantUncompressedDeprecated, IntPtr d2, uint s2, IntPtr w2, uint r2);
    [DllImport(DLL)] public static extern int SteamAPI_ISteamUser_DecompressVoice(IntPtr self, byte[] src, uint srcSize, byte[] dest, uint destSize, out uint written, uint rate);
    [DllImport(DLL)] public static extern uint SteamAPI_ISteamUser_GetVoiceOptimalSampleRate(IntPtr self);
    [DllImport(DLL)] public static extern IntPtr SteamAPI_SteamMatchmaking_v009();
    [DllImport(DLL)] public static extern ulong SteamAPI_ISteamMatchmaking_CreateLobby(IntPtr self, int type, int maxMembers);
    [DllImport(DLL)] [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool SteamAPI_ISteamMatchmaking_SetLobbyData(IntPtr self, ulong lobby, byte[] key, byte[] value);
    [DllImport(DLL)] public static extern void SteamAPI_ISteamMatchmaking_LeaveLobby(IntPtr self, ulong lobby);
    [DllImport(DLL)] public static extern void SteamAPI_ISteamMatchmaking_AddRequestLobbyListStringFilter(IntPtr self, byte[] key, byte[] value, int comparison);
    [DllImport(DLL)] public static extern void SteamAPI_ISteamMatchmaking_AddRequestLobbyListDistanceFilter(IntPtr self, int filter);
    [DllImport(DLL)] public static extern void SteamAPI_ISteamMatchmaking_AddRequestLobbyListResultCountFilter(IntPtr self, int max);
    [DllImport(DLL)] public static extern ulong SteamAPI_ISteamMatchmaking_RequestLobbyList(IntPtr self);
    [DllImport(DLL)] public static extern ulong SteamAPI_ISteamMatchmaking_GetLobbyByIndex(IntPtr self, int i);
    [DllImport(DLL)] public static extern IntPtr SteamAPI_ISteamMatchmaking_GetLobbyData(IntPtr self, ulong lobby, byte[] key);
    [DllImport(DLL)] [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool SteamAPI_ManualDispatch_GetAPICallResult(int pipe, ulong call, IntPtr result, int size, int expected, [MarshalAs(UnmanagedType.I1)] out bool failed);
    [DllImport(DLL)] public static extern ulong SteamAPI_ISteamUser_GetSteamID(IntPtr self);

    [DllImport(DLL)] public static extern IntPtr SteamAPI_SteamFriends_v017();
    [DllImport(DLL)] [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool SteamAPI_ISteamFriends_SetRichPresence(IntPtr self, byte[] key, byte[] value);
    [DllImport(DLL)] public static extern void SteamAPI_ISteamFriends_ClearRichPresence(IntPtr self);
    [DllImport(DLL)] public static extern int SteamAPI_ISteamFriends_GetFriendCount(IntPtr self, int flags);
    [DllImport(DLL)] public static extern ulong SteamAPI_ISteamFriends_GetFriendByIndex(IntPtr self, int i, int flags);
    [DllImport(DLL)] public static extern void SteamAPI_ISteamFriends_RequestFriendRichPresence(IntPtr self, ulong id);
    [DllImport(DLL)] public static extern IntPtr SteamAPI_ISteamFriends_GetFriendRichPresence(IntPtr self, ulong id, byte[] key);
    [DllImport(DLL)] public static extern IntPtr SteamAPI_ISteamFriends_GetFriendPersonaName(IntPtr self, ulong id);
    [DllImport(DLL)] public static extern IntPtr SteamAPI_ISteamFriends_GetPersonaName(IntPtr self);

    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    public struct CallbackMsg { public int User; public int Callback; public IntPtr Param; public int ParamSize; }

    public static byte[] Z(string s) { return Encoding.UTF8.GetBytes(s + "\0"); }
    public static string S(IntPtr p)
    {
        if (p == IntPtr.Zero) return "";
        int n = 0;
        while (Marshal.ReadByte(p, n) != 0) n++;
        var b = new byte[n];
        Marshal.Copy(p, b, 0, n);
        return Encoding.UTF8.GetString(b);
    }
}

interface INet
{
    bool Init(Action<string> log);
    ulong Me { get; }
    string MyName { get; }
    bool Send(ulong to, byte[] data, bool reliable, int channel);
    byte[] Read(int channel, out ulong from);
    void Pump(Func<ulong, bool> onSessionRequest, Action<string> log);
    void Accept(ulong id);
    void Close(ulong id);
    string NameOf(ulong id);
    string Route(ulong id);
    void SetPresence(string role);
    List<KeyValuePair<ulong, string>> FriendsWithPresence(string role);
    int FriendCount();
    void SetPublic(bool on, bool listed, Dictionary<string, string> data);
    string PublicState { get; }
    IntPtr SteamUser { get; }
    void RequestServers();
    List<Dictionary<string, string>> Servers { get; }
    void Shutdown();
}

class SteamNet : INet
{
    const int SEND_UNRELIABLE = 1, SEND_RELIABLE = 2;
    const int FRIEND_IMMEDIATE = 4;
    const int CB_P2P_SESSION_REQUEST = 1202, CB_P2P_SESSION_FAIL = 1203;
    IntPtr net, friends;
    int pipe;
    ulong me;
    string myName = "";
    readonly byte[] buf = new byte[1 << 21];

    public ulong Me { get { return me; } }
    public string MyName { get { return myName; } }

    public bool Init(Action<string> log)
    {
        try { Directory.SetCurrentDirectory(AppDomain.CurrentDomain.BaseDirectory); } catch { }
        Environment.SetEnvironmentVariable("SteamAppId", "1645820");
        Environment.SetEnvironmentVariable("SteamGameId", "1645820");
        if (!Steam.SteamAPI_Init()) { log("SteamAPI_Init FAILED - is Steam running and logged in?"); return false; }
        Steam.SteamAPI_ManualDispatch_Init();
        pipe = Steam.SteamAPI_GetHSteamPipe();
        net = Steam.SteamAPI_SteamNetworking_v006();
        friends = Steam.SteamAPI_SteamFriends_v017();
        me = Steam.SteamAPI_ISteamUser_GetSteamID(Steam.SteamAPI_SteamUser_v021());
        Steam.SteamAPI_ISteamNetworking_AllowP2PPacketRelay(net, true);
        myName = Steam.S(Steam.SteamAPI_ISteamFriends_GetPersonaName(friends));
        return true;
    }

    public bool Send(ulong to, byte[] data, bool reliable, int channel)
    {
        return Steam.SteamAPI_ISteamNetworking_SendP2PPacket(net, to, data, (uint)data.Length,
            reliable ? SEND_RELIABLE : SEND_UNRELIABLE, channel);
    }

    public byte[] Read(int channel, out ulong from)
    {
        from = 0;
        uint size;
        if (!Steam.SteamAPI_ISteamNetworking_IsP2PPacketAvailable(net, out size, channel)) return null;
        byte[] dest = size <= buf.Length ? buf : new byte[size];
        uint got;
        if (!Steam.SteamAPI_ISteamNetworking_ReadP2PPacket(net, dest, (uint)dest.Length, out got, out from, channel)) return null;
        var outp = new byte[got];
        Buffer.BlockCopy(dest, 0, outp, 0, (int)got);
        return outp;
    }

    public void Pump(Func<ulong, bool> onSessionRequest, Action<string> log)
    {
        Steam.SteamAPI_ManualDispatch_RunFrame(pipe);
        Steam.CallbackMsg msg;
        while (Steam.SteamAPI_ManualDispatch_GetNextCallback(pipe, out msg))
        {
            callbacksSeen++;
            try
            {
                if (msg.Callback == CB_P2P_SESSION_REQUEST && msg.ParamSize >= 8)
                {
                    ulong from = (ulong)Marshal.ReadInt64(msg.Param);
                    if (onSessionRequest(from)) Accept(from);
                }
                else if (msg.Callback == CB_CALL_COMPLETED && msg.ParamSize >= 16) CallDone(msg.Param);
                else if (smokeLog) log("callback " + msg.Callback + " size " + msg.ParamSize);
                else if (msg.Callback == CB_P2P_SESSION_FAIL && msg.ParamSize >= 9)
                    log("P2P session failed, error " + Marshal.ReadByte(msg.Param, 8)
                        + " (1 = target not running the bridge, 2 = no rights, 3 = Steam not connected, 4 = timeout)");
            }
            finally { Steam.SteamAPI_ManualDispatch_FreeLastCallback(pipe); }
        }
    }

    public void Accept(ulong id) { Steam.SteamAPI_ISteamNetworking_AcceptP2PSessionWithUser(net, id); }
    public void Close(ulong id) { Steam.SteamAPI_ISteamNetworking_CloseP2PSessionWithUser(net, id); }
    public string NameOf(ulong id) { return Steam.S(Steam.SteamAPI_ISteamFriends_GetFriendPersonaName(friends, id)); }

    // how the session runs: through a Steam relay or direct, and how much is still waiting to go out
    public string Route(ulong id)
    {
        Steam.P2PSessionState s;
        if (id == 0 || !Steam.SteamAPI_ISteamNetworking_GetP2PSessionState(net, id, out s)) return "route ?";
        return string.Format("route {0} queued {1} B", s.UsingRelay != 0 ? "relay" : "direct", s.BytesQueued);
    }

    const int CB_CALL_COMPLETED = 703, CB_LOBBY_CREATED = 513, CB_LOBBY_MATCH_LIST = 510;
    static readonly string[] LOBBY_KEYS = { "surrounsync", "name", "proto", "locked", "players", "host" };
    IntPtr mm = IntPtr.Zero;
    public bool smokeLog = false;
    public int callbacksSeen = 0;
    ulong lobby = 0, createCall = 0, listCall = 0;
    string publicState = "off";
    Dictionary<string, string> lobbyData = null, lobbySet = new Dictionary<string, string>();
    List<Dictionary<string, string>> servers = new List<Dictionary<string, string>>();
    public string PublicState { get { return publicState; } }
    public List<Dictionary<string, string>> Servers { get { return servers; } }
    public IntPtr SteamUser { get { return Steam.SteamAPI_SteamUser_v021(); } }

    IntPtr MM() { if (mm == IntPtr.Zero) mm = Steam.SteamAPI_SteamMatchmaking_v009(); return mm; }
    void ApplyLobbyData()
    {
        if (lobby == 0 || lobbyData == null) return;
        foreach (var kv in lobbyData)
        {
            string old;
            if (lobbySet.TryGetValue(kv.Key, out old) && old == kv.Value) continue;
            Steam.SteamAPI_ISteamMatchmaking_SetLobbyData(MM(), lobby, Steam.Z(kv.Key), Steam.Z(kv.Value));
            lobbySet[kv.Key] = kv.Value;
        }
    }
    public void SetPublic(bool on, bool listed, Dictionary<string, string> data)
    {
        if (!on)
        {
            if (lobby != 0) Steam.SteamAPI_ISteamMatchmaking_LeaveLobby(MM(), lobby);
            lobby = 0; createCall = 0; lobbySet.Clear(); publicState = "off";
            return;
        }
        lobbyData = data;
        if (lobby != 0) { ApplyLobbyData(); return; }
        if (createCall != 0) return;
        createCall = Steam.SteamAPI_ISteamMatchmaking_CreateLobby(MM(), listed ? 2 : 0, 4);
        publicState = "creating";
    }
    public string Debug() { return "createCall=" + createCall + " lobby=" + lobby + " mm=" + mm; }
    public void RequestServers()
    {
        Steam.SteamAPI_ISteamMatchmaking_AddRequestLobbyListStringFilter(MM(), Steam.Z("surrounsync"), Steam.Z("1"), 0);
        Steam.SteamAPI_ISteamMatchmaking_AddRequestLobbyListDistanceFilter(MM(), 3);
        Steam.SteamAPI_ISteamMatchmaking_AddRequestLobbyListResultCountFilter(MM(), 50);
        listCall = Steam.SteamAPI_ISteamMatchmaking_RequestLobbyList(MM());
        servers = null;
    }
    void CallDone(IntPtr p)
    {
        ulong call = (ulong)Marshal.ReadInt64(p);
        IntPtr res = Marshal.AllocHGlobal(64);
        try
        {
            bool failed;
            if (call == createCall && createCall != 0)
            {
                createCall = 0;
                if (Steam.SteamAPI_ManualDispatch_GetAPICallResult(pipe, call, res, 16, CB_LOBBY_CREATED, out failed) && !failed
                    && Marshal.ReadInt32(res) == 1)
                {
                    lobby = (ulong)Marshal.ReadInt64(res, 8);
                    lobbySet.Clear();
                    ApplyLobbyData();
                    publicState = "on";
                }
                else publicState = "failed";
            }
            else if (call == listCall && listCall != 0)
            {
                listCall = 0;
                var found = new List<Dictionary<string, string>>();
                if (Steam.SteamAPI_ManualDispatch_GetAPICallResult(pipe, call, res, 4, CB_LOBBY_MATCH_LIST, out failed) && !failed)
                {
                    int n = Marshal.ReadInt32(res);
                    for (int i = 0; i < n && i < 50; i++)
                    {
                        ulong id = Steam.SteamAPI_ISteamMatchmaking_GetLobbyByIndex(MM(), i);
                        var d = new Dictionary<string, string>();
                        foreach (var k in LOBBY_KEYS) d[k] = Steam.S(Steam.SteamAPI_ISteamMatchmaking_GetLobbyData(MM(), id, Steam.Z(k)));
                        d["id"] = id.ToString();
                        found.Add(d);
                    }
                }
                servers = found;
            }
        }
        finally { Marshal.FreeHGlobal(res); }
    }
    public void SetPresence(string role) { Steam.SteamAPI_ISteamFriends_SetRichPresence(friends, Steam.Z("surrounsync"), Steam.Z(role)); }
    public int FriendCount() { return Steam.SteamAPI_ISteamFriends_GetFriendCount(friends, FRIEND_IMMEDIATE); }

    public List<KeyValuePair<ulong, string>> FriendsWithPresence(string role)
    {
        var list = new List<KeyValuePair<ulong, string>>();
        int n = FriendCount();
        for (int i = 0; i < n; i++)
        {
            ulong f = Steam.SteamAPI_ISteamFriends_GetFriendByIndex(friends, i, FRIEND_IMMEDIATE);
            Steam.SteamAPI_ISteamFriends_RequestFriendRichPresence(friends, f);
            string rp = Steam.S(Steam.SteamAPI_ISteamFriends_GetFriendRichPresence(friends, f, Steam.Z("surrounsync")));
            if (rp == role) list.Add(new KeyValuePair<ulong, string>(f, NameOf(f)));
        }
        return list;
    }

    public void Shutdown()
    {
        SetPublic(false, false, null);
        Steam.SteamAPI_ISteamFriends_ClearRichPresence(friends);
        Steam.SteamAPI_Shutdown();
    }
}

// Loopback stand-in for Steam: the host listens on 127.0.0.1:<port>, every guest bridge connects to it.
// Ids: host 1001, guests 1002 (default) or SURROUNSYNC_TEST_ID / --test-id, so up to three guests can run on one PC.
// Each connection starts with an id frame (channel 9), so the host knows who sent what.
class TestNet : INet
{
    readonly int port;
    readonly ulong guestId;
    string role = "idle";
    TcpListener listener;
    string listenError;
    bool listenLogged;
    long nextConnect;
    TcpClient connecting;
    IAsyncResult connectAr;
    long connectStarted;
    readonly object qlock = new object();
    readonly Queue<KeyValuePair<ulong, byte[]>>[] queues = { new Queue<KeyValuePair<ulong, byte[]>>(), new Queue<KeyValuePair<ulong, byte[]>>(), new Queue<KeyValuePair<ulong, byte[]>>() };
    readonly Queue<ulong> pendingRequests = new Queue<ulong>();

    class Conn
    {
        public TcpClient client;
        public volatile NetworkStream stream;   // (cleared by its writer thread when a write fails)
        public readonly Queue<byte[]> outq = new Queue<byte[]>();
        public readonly AutoResetEvent signal = new AutoResetEvent(false);
        public ulong id;
        public volatile bool dead;
    }
    readonly Dictionary<ulong, Conn> conns = new Dictionary<ulong, Conn>();   // host: by guest id; guest: 1001 = the host
    readonly List<Conn> unnamed = new List<Conn>();                          // host: accepted, id frame not read yet

    public TestNet(int port, ulong guestId)
    {
        this.port = port;
        this.guestId = guestId >= 1002 ? guestId : 1002UL;
    }
    public IntPtr SteamUser { get { return IntPtr.Zero; } }
    string publicState = "off";
    List<Dictionary<string, string>> servers = new List<Dictionary<string, string>>();
    public string PublicState { get { return publicState; } }
    public List<Dictionary<string, string>> Servers { get { return servers; } }
    public void SetPublic(bool on, bool listed, Dictionary<string, string> data)
    {
        publicState = on ? "on" : "off";
        try
        {
            string f = Path.Combine(Path.GetTempPath(), "mirror_testnet_public_" + port + ".txt");
            if (!on) { File.Delete(f); return; }
            var sb = new StringBuilder();
            foreach (var kv in data) sb.Append(kv.Key).Append('=').Append(kv.Value).Append('\n');
            File.WriteAllText(f, sb.ToString());
        }
        catch { }
    }
    public void RequestServers()
    {
        servers = new List<Dictionary<string, string>>();
        try
        {
            string f = Path.Combine(Path.GetTempPath(), "mirror_testnet_public_" + port + ".txt");
            if (!File.Exists(f)) return;
            var d = new Dictionary<string, string>();
            foreach (var line in File.ReadAllLines(f)) { int i = line.IndexOf('='); if (i > 0) d[line.Substring(0, i)] = line.Substring(i + 1); }
            d["id"] = "1001";
            servers.Add(d);
        }
        catch { }
    }
    public ulong Me { get { return role == "host" ? 1001UL : guestId; } }
    public string MyName { get { return Me == 1001UL ? "Test-host" : Me == 1002UL ? "Test-guest" : "Test-guest" + (Me - 1000); } }
    public bool Init(Action<string> log) { return true; }

    public void SetPresence(string r)
    {
        if (r != role)
        {
            DropAll();
            if (listener != null && r != "host") { try { listener.Stop(); } catch { } listener = null; }
        }
        role = r;
        TryListen();
    }

    void TryListen()
    {
        if (role != "host" || listener != null) return;
        try { var l = new TcpListener(IPAddress.Loopback, port); l.Start(); listener = l; listenError = null; listenLogged = false; }
        catch (Exception e) { listener = null; listenError = e.Message; }
    }

    void DropConn(Conn c)
    {
        c.dead = true;
        try { c.client.Close(); } catch { }
        c.signal.Set();
    }

    void DropAll()
    {
        lock (qlock)
        {
            foreach (var c in conns.Values) DropConn(c);
            foreach (var c in unnamed) DropConn(c);
            conns.Clear(); unnamed.Clear();
            foreach (var q in queues) q.Clear();
        }
        if (connecting != null) try { connecting.Close(); } catch { }
        connecting = null;
    }

    static bool ReadFull(NetworkStream s, byte[] b, int n)
    {
        int got = 0;
        while (got < n) { int k = s.Read(b, got, n - got); if (k <= 0) return false; got += k; }
        return true;
    }

    // frames: <len:4> <channel:1> <data>; channel 9 = the sender's id (first frame of a connection)
    void StartReader(Conn c, ulong knownId)
    {
        var s = c.stream;
        var t = new Thread(() =>
        {
            ulong from = knownId;
            try
            {
                var head = new byte[5];
                while (!c.dead)
                {
                    if (!ReadFull(s, head, 5)) break;
                    int len = BitConverter.ToInt32(head, 0);
                    if (len < 0 || len > (1 << 22)) break;
                    var data = new byte[len];
                    if (!ReadFull(s, data, len)) break;
                    if (head[4] == 9)
                    {
                        if (len >= 8 && from == 0)
                        {
                            from = BitConverter.ToUInt64(data, 0);
                            lock (qlock)
                            {
                                unnamed.Remove(c);
                                Conn old;
                                if (conns.TryGetValue(from, out old) && old != c) DropConn(old);
                                c.id = from; conns[from] = c;
                                pendingRequests.Enqueue(from);
                            }
                        }
                        continue;
                    }
                    if (from == 0) continue;
                    int ch = head[4] <= 2 ? head[4] : 0;
                    lock (qlock) queues[ch].Enqueue(new KeyValuePair<ulong, byte[]>(from, data));
                }
            }
            catch { }
            c.dead = true;
            lock (qlock) { Conn cur; if (from != 0 && conns.TryGetValue(from, out cur) && cur == c) conns.Remove(from); unnamed.Remove(c); }
        });
        t.IsBackground = true;
        t.Start();
    }

    // writes go out on the connection's own thread, like Steam's send that only queues
    void StartWriter(Conn c)
    {
        var t = new Thread(() =>
        {
            try
            {
                while (!c.dead)
                {
                    byte[] f = null;
                    lock (c.outq) if (c.outq.Count > 0) f = c.outq.Dequeue();
                    if (f != null) { c.stream.Write(f, 0, f.Length); continue; }
                    c.signal.WaitOne(1000);
                }
            }
            catch { c.dead = true; }
        });
        t.IsBackground = true;
        t.Start();
    }

    static byte[] Frame(byte[] data, int channel)
    {
        var frame = new byte[5 + data.Length];
        BitConverter.GetBytes(data.Length).CopyTo(frame, 0);
        frame[4] = (byte)channel;
        Buffer.BlockCopy(data, 0, frame, 5, data.Length);
        return frame;
    }

    public void Pump(Func<ulong, bool> onSessionRequest, Action<string> log)
    {
        long t = Environment.TickCount;
        if (role == "host" && listener == null && t >= nextConnect) { nextConnect = t + 1000; TryListen(); if (listenError != null) log("testnet: can't listen: " + listenError); }
        if (listener != null && !listenLogged) { listenLogged = true; log("testnet: listening on " + port); }
        while (role == "host" && listener != null && listener.Pending())
        {
            var tc = listener.AcceptTcpClient();
            tc.NoDelay = true;
            var c = new Conn { client = tc, stream = tc.GetStream() };
            lock (qlock) unnamed.Add(c);
            log("testnet: accepted " + tc.Client.RemoteEndPoint);
            StartWriter(c);
            StartReader(c, 0);
        }
        if (role == "guest")
        {
            Conn host;
            lock (qlock) conns.TryGetValue(1001UL, out host);
            if (host != null && host.dead) { lock (qlock) conns.Remove(1001UL); host = null; }
            // the connect runs on while the loop goes on (antivirus made loopback connects take 0.3-9 s)
            if (host == null && connecting != null)
            {
                if (connectAr.IsCompleted)
                {
                    var tc = connecting;
                    connecting = null;
                    try
                    {
                        tc.EndConnect(connectAr);
                        var c = new Conn { client = tc, stream = tc.GetStream(), id = 1001UL };
                        lock (c.outq) c.outq.Enqueue(Frame(BitConverter.GetBytes(guestId), 9));
                        lock (qlock) conns[1001UL] = c;
                        log("testnet: connected from " + tc.Client.LocalEndPoint + " in " + (t - connectStarted) + " ms as " + guestId);
                        StartWriter(c);
                        StartReader(c, 1001UL);
                    }
                    catch { try { tc.Close(); } catch { } nextConnect = t + 1000; }
                }
                else if (t - connectStarted > 15000)
                {
                    log("testnet: connect still pending after 15 s - starting over");
                    try { connecting.Close(); } catch { }
                    connecting = null; nextConnect = t + 1000;
                }
            }
            else if (host == null && t >= nextConnect)
            {
                nextConnect = t + 1000;
                try
                {
                    var tc = new TcpClient();
                    tc.NoDelay = true;
                    connectAr = tc.BeginConnect(IPAddress.Loopback, port, null, null);
                    connecting = tc; connectStarted = t;
                }
                catch { connecting = null; }
            }
        }
        while (true)
        {
            ulong p;
            lock (qlock) { if (pendingRequests.Count == 0) break; p = pendingRequests.Dequeue(); }
            if (role == "host") onSessionRequest(p);
        }
    }

    public bool Send(ulong to, byte[] data, bool reliable, int channel)
    {
        Conn c;
        lock (qlock) conns.TryGetValue(to, out c);
        if (c == null || c.dead || c.stream == null) return false;
        lock (c.outq) c.outq.Enqueue(Frame(data, channel));
        c.signal.Set();
        return true;
    }

    public byte[] Read(int channel, out ulong from)
    {
        from = 0;
        if (channel < 0 || channel >= queues.Length) return null;
        lock (qlock)
        {
            if (queues[channel].Count == 0) return null;
            var kv = queues[channel].Dequeue();
            from = kv.Key;
            return kv.Value;
        }
    }

    public void Accept(ulong id) { }
    public void Close(ulong id)
    {
        lock (qlock)
        {
            Conn c;
            if (conns.TryGetValue(id, out c)) { DropConn(c); conns.Remove(id); }
        }
    }
    // (SURROUNSYNC_TEST_STRANGERS=1: answer like Steam does for someone who isn't your friend)
    public string NameOf(ulong id)
    {
        if (Environment.GetEnvironmentVariable("SURROUNSYNC_TEST_STRANGERS") == "1") return "[unknown]";
        return id == 1001UL ? "Test-host" : id == 1002UL ? "Test-guest" : "Test-guest" + (id - 1000);
    }
    public string Route(ulong id) { return "route test queued 0 B"; }
    public int FriendCount() { return 0; }
    public List<KeyValuePair<ulong, string>> FriendsWithPresence(string r)
    {
        var l = new List<KeyValuePair<ulong, string>>();
        if (r == "host") l.Add(new KeyValuePair<ulong, string>(1001UL, "Test-host"));
        return l;
    }
    public void Shutdown() { DropAll(); try { if (listener != null) listener.Stop(); } catch { } }
}

static class Win
{
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vk);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    public struct WAVEFORMATEX { public ushort tag, channels; public uint rate, bytesPerSec; public ushort blockAlign, bits, cbSize; }
    [StructLayout(LayoutKind.Sequential)]
    public struct WAVEHDR { public IntPtr data; public uint length, recorded; public IntPtr user; public uint flags, loops; public IntPtr next, reserved; }
    [DllImport("winmm.dll")] public static extern int waveOutOpen(out IntPtr h, int device, ref WAVEFORMATEX fmt, IntPtr cb, IntPtr inst, int flags);
    [DllImport("winmm.dll")] public static extern int waveOutPrepareHeader(IntPtr h, IntPtr hdr, int size);
    [DllImport("winmm.dll")] public static extern int waveOutUnprepareHeader(IntPtr h, IntPtr hdr, int size);
    [DllImport("winmm.dll")] public static extern int waveOutWrite(IntPtr h, IntPtr hdr, int size);
    [DllImport("winmm.dll")] public static extern int waveOutClose(IntPtr h);
}

// One player we hear: their own wave output (Windows mixes several), loudness by their distance.
class VoiceOut
{
    public double Distance = 0;
    public long HeardAt = -100000;   // when their last voice packet arrived (TickCount)
    public bool Talking { get { return Environment.TickCount - HeardAt < 400; } }
    IntPtr wave = IntPtr.Zero;
    readonly List<IntPtr> queued = new List<IntPtr>();

    public bool Output(byte[] buf, int n, uint rate)
    {
        int hsize = Marshal.SizeOf(typeof(Win.WAVEHDR));
        if (wave == IntPtr.Zero)
        {
            var fmt = new Win.WAVEFORMATEX { tag = 1, channels = 1, rate = rate, bytesPerSec = rate * 2, blockAlign = 2, bits = 16, cbSize = 0 };
            if (Win.waveOutOpen(out wave, -1, ref fmt, IntPtr.Zero, IntPtr.Zero, 0) != 0) { wave = IntPtr.Zero; return false; }
        }
        for (int i = queued.Count - 1; i >= 0; i--)
        {
            var h = (Win.WAVEHDR)Marshal.PtrToStructure(queued[i], typeof(Win.WAVEHDR));
            if ((h.flags & 1) != 0)
            {
                Win.waveOutUnprepareHeader(wave, queued[i], hsize);
                Marshal.FreeHGlobal(h.data); Marshal.FreeHGlobal(queued[i]);
                queued.RemoveAt(i);
            }
        }
        if (queued.Count > 40) return false;
        IntPtr mem = Marshal.AllocHGlobal(n);
        Marshal.Copy(buf, 0, mem, n);
        var hdr = new Win.WAVEHDR { data = mem, length = (uint)n };
        IntPtr hp = Marshal.AllocHGlobal(hsize);
        Marshal.StructureToPtr(hdr, hp, false);
        if (Win.waveOutPrepareHeader(wave, hp, hsize) != 0 || Win.waveOutWrite(wave, hp, hsize) != 0)
        {
            Marshal.FreeHGlobal(mem); Marshal.FreeHGlobal(hp); return false;
        }
        queued.Add(hp);
        return true;
    }

    public void Close() { if (wave != IntPtr.Zero) { Win.waveOutClose(wave); wave = IntPtr.Zero; } }
}

class Voice
{
    IntPtr user = IntPtr.Zero;
    public bool Available { get { return user != IntPtr.Zero; } }
    public bool On;
    public int Key = 0x56;
    public double Volume = 1.0;
    public bool Talking;
    uint rate = 24000;
    readonly byte[] cbuf = new byte[16 * 1024], pcm = new byte[96 * 1024];
    public long Sent, Played;
    string gameExe;

    public void Init(IntPtr steamUser, Action<string> log)
    {
        user = steamUser;
        if (user == IntPtr.Zero) return;
        try { rate = Steam.SteamAPI_ISteamUser_GetVoiceOptimalSampleRate(user); } catch { }
        if (rate < 8000 || rate > 48000) rate = 24000;
        try { gameExe = Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, @"..\..\..\..\SurrounDead-Win64-Shipping.exe")); } catch { }
        log("voice ready (" + rate + " Hz)");
    }

    bool GameFocused()
    {
        try
        {
            uint pid; Win.GetWindowThreadProcessId(Win.GetForegroundWindow(), out pid);
            var p = Process.GetProcessById((int)pid);
            return p.ProcessName == "SurrounDead-Win64-Shipping"
                && (gameExe == null || string.Equals(p.MainModule.FileName, gameExe, StringComparison.OrdinalIgnoreCase));
        }
        catch { return false; }
    }

    long focusAt = 0; bool focused = false;
    // the packet we recorded this loop (or null): the bridge sends it to everyone who should hear us
    public byte[] Tick()
    {
        if (!Available) return null;
        long t = Environment.TickCount;
        if (t - focusAt > 300) { focusAt = t; focused = GameFocused(); }
        bool want = On && focused && (Win.GetAsyncKeyState(Key) & 0x8000) != 0;
        if (want != Talking)
        {
            Talking = want;
            if (want) Steam.SteamAPI_ISteamUser_StartVoiceRecording(user); else Steam.SteamAPI_ISteamUser_StopVoiceRecording(user);
        }
        uint avail;
        if (Steam.SteamAPI_ISteamUser_GetAvailableVoice(user, out avail, IntPtr.Zero, 0) != 0 || avail == 0) return null;
        uint got;
        if (Steam.SteamAPI_ISteamUser_GetVoice(user, true, cbuf, (uint)cbuf.Length, out got, false, IntPtr.Zero, 0, IntPtr.Zero, 0) != 0 || got == 0) return null;
        var pkt = new byte[got + 1];
        pkt[0] = (byte)'V';
        Buffer.BlockCopy(cbuf, 0, pkt, 1, (int)got);
        Sent++;
        return pkt;
    }

    double Gain(double d) { double g = d <= 5 ? 1.0 : d >= 50 ? 0.0 : 1.0 - (d - 5) / 45.0; return g * Volume; }

    public void Play(VoiceOut who, byte[] data, int offset)
    {
        who.HeardAt = Environment.TickCount;
        if (!Available || !On) return;
        double g = Gain(who.Distance);
        if (g <= 0.001) return;
        var src = new byte[data.Length - offset];
        Buffer.BlockCopy(data, offset, src, 0, src.Length);
        uint got;
        if (Steam.SteamAPI_ISteamUser_DecompressVoice(user, src, (uint)src.Length, pcm, (uint)pcm.Length, out got, rate) != 0 || got == 0) return;
        for (int i = 0; i + 1 < got; i += 2)
        {
            int v = (short)(pcm[i] | (pcm[i + 1] << 8));
            v = (int)(v * g);
            if (v > 32767) v = 32767; else if (v < -32768) v = -32768;
            pcm[i] = (byte)(v & 0xff); pcm[i + 1] = (byte)((v >> 8) & 0xff);
        }
        who.Output(pcm, (int)got, rate);
        Played++;
    }

    public bool Output(VoiceOut who, byte[] buf, int n) { return who.Output(buf, n, rate); }

    public void Shutdown()
    {
        if (Talking && Available) Steam.SteamAPI_ISteamUser_StopVoiceRecording(user);
    }
}

// One other player. The host has one per guest (slot 1..3); a guest has one for the host (slot 0) and one per
// other guest ("mate", reached through the host's bridge: 'X' <id:8> <packet>). Files: we send
// mirror_<name>_<outTag>.txt, we write what arrives to mirror_<name>_<inTag>.txt. The first guest's link (host
// side) and the host link (guest side) keep the old two-player names (host/guest), so two players work as before.
class PeerLink
{
    public ulong id;
    public int slot;
    public bool mate;
    public string outTag, inTag;
    public bool primary { get { return outTag == "host" || outTag == "guest"; } }
    public string name = "";
    public string game = "?";
    public string epoch = null;          // their bridge session, from their 'H'
    public string blobEpoch = null;
    public int gen = 0;                  // host: bumped when this guest (re)connects; guest: the host's number for a mate
    public long lastRx, lastHeard, lastHello, lastNameSent, pingAt, quietAt;
    public double rtt = -1;
    public readonly Dictionary<string, string> sent = new Dictionary<string, string>();
    public readonly Dictionary<string, DateTime> seenWrite = new Dictionary<string, DateTime>();
    public readonly HashSet<string> loggedTx = new HashSet<string>(), loggedRx = new HashSet<string>();
    public string lastPose = null;
    public long txBytes, rxBytes, txPkts, rxPkts, txBlobs, rxBlobs;
    public string chunkName, chunkKey; public string[] chunkParts; public int chunkGot;
    public int rxFragId = -1, rxFragHave; public byte[][] rxFrags;
    public readonly Dictionary<string, long> blobGen = new Dictionary<string, long>();
    public readonly string indexRun = DateTime.UtcNow.Ticks.ToString();
    public double pktTokens = -1, byteTokens; public long tokensAt;
    public readonly Queue<long> drops = new Queue<long>();
    public readonly Dictionary<string, long> dropLogged = new Dictionary<string, long>();
    public readonly VoiceOut voice = new VoiceOut();
    public bool Connected { get { return epoch != null; } }
    public bool liveSent;
}

class Bridge
{
    const int CHUNK = 256 * 1024;

    string role, other, dir, logPath, mutexName;
    bool auto, gameCheck = true;
    readonly List<KeyValuePair<ulong, string>> hosting = new List<KeyValuePair<ulong, string>>();
    ulong me, configuredPeer, pendingFrom;
    INet net;
    string epoch = DateTimeOffset.UtcNow.ToUnixTimeSeconds().ToString();
    readonly DateTime startedUtc = DateTime.UtcNow.AddSeconds(-30);
    int msgId = 0;
    readonly List<PeerLink> links = new List<PeerLink>();
    int maxGuests = 3, mySlot = -1, rosterGen = 0;
    readonly Dictionary<ulong, int> slotOf = new Dictionary<ulong, int>();   // host: the slot each guest had, kept for a rejoin
    bool rosterDirty = true; long rosterAt = 0; string rosterFile = null;
    PeerLink HostLink() { foreach (var l in links) if (!l.mate && l.slot == 0) return l; return null; }
    PeerLink Direct(ulong id) { foreach (var l in links) if (!l.mate && l.id == id) return l; return null; }
    PeerLink Mate(ulong id) { foreach (var l in links) if (l.mate && l.id == id) return l; return null; }
    PeerLink Primary() { foreach (var l in links) if (l.primary) return l; return null; }
    int Guests() { int n = 0; foreach (var l in links) if (!l.mate && l.slot > 0) n++; return n; }
    bool Reachable(PeerLink l) { if (!l.mate) return true; var h = HostLink(); return h != null && h.Connected; }
    string NameFile(PeerLink l) { return Path.Combine(dir, "mirror_peer_" + l.outTag + ".name"); }
    string StatusFile(string outTag) { return Path.Combine(dir, "mirror_bridge_status_" + outTag + ".txt"); }
    string ClockFile(PeerLink l) { return Path.Combine(dir, l.primary ? "mirror_clock_offset.txt" : "mirror_clock_offset_" + l.outTag + ".txt"); }

    readonly HashSet<ulong> approved = new HashSet<ulong>();
    readonly HashSet<ulong> blocked = new HashSet<ulong>();
    readonly Dictionary<ulong, KeyValuePair<string, long>> requests = new Dictionary<ulong, KeyValuePair<string, long>>();
    string kickedLine = null; long kickedAt = 0;
    volatile string updateVersion = null;
    volatile string reportLine = null;
    const long REQUEST_TIMEOUT = 60000;
    const int MAX_POSE = 2048, MAX_HELLO = 256, MAX_PART = CHUNK + 1024, MAX_PARTS = 32;
    const double PKT_RATE = 600, PKT_BURST = 3000, BYTE_RATE = 4.0 * 1024 * 1024, BYTE_BURST = 16.0 * 1024 * 1024;
    const int KICK_DROPS = 20; const long KICK_WINDOW = 10000;
    byte[] passKey = null;
    byte[] joinKey = null;
    readonly Dictionary<ulong, string> challenges = new Dictionary<ulong, string>();
    readonly Dictionary<ulong, long> challengedAt = new Dictionary<ulong, long>();
    readonly Dictionary<ulong, int> badTries = new Dictionary<ulong, int>();
    readonly HashSet<ulong> passOk = new HashSet<ulong>();
    string joinError = null;
    bool publicOn = false; string publicName = "", publicProto = "?";
    bool browsing = false;
    readonly Voice voice = new Voice();
    long voiceCfgAt = 0;
    bool answered = false;

    static long Now() { return Environment.TickCount; }

    // Watchdog: the loop is single-threaded, so one call that blocks (Steam, a file) froze the whole link
    // (2026-10-24: guest bridge silent ~40 s; the mod's restart then quit because this one still held the
    // mutex). Each loop step is named; stuck > STALL_EXIT ms -> log the step and exit so the restart works.
    volatile string step = "start";
    long beat = Environment.TickCount;
    const int STALL_LOG = 4000, STALL_EXIT = 12000;
    void Step(string s) { step = s; Interlocked.Exchange(ref beat, Environment.TickCount); }
    void StartWatchdog()
    {
        var th = new Thread(() =>
        {
            bool logged = false;
            while (true)
            {
                Thread.Sleep(500);
                long stuck = Environment.TickCount - Interlocked.Read(ref beat);
                if (stuck < STALL_LOG) { logged = false; continue; }
                if (!logged) { logged = true; Log("loop stuck in " + step + " for " + stuck / 1000.0 + " s"); }
                if (stuck >= STALL_EXIT)
                {
                    Log("loop stuck in " + step + " for " + stuck / 1000 + " s - exiting so the game can restart the bridge");
                    Environment.Exit(4);
                }
            }
        });
        th.IsBackground = true;
        th.Start();
    }
    static long Unix() { return DateTimeOffset.UtcNow.ToUnixTimeSeconds(); }

    readonly object logLock = new object();
    void Log(string m)
    {
        string line = DateTime.Now.ToString("HH:mm:ss") + " " + m;
        lock (logLock)
        {
            Console.WriteLine(line);
            try { File.AppendAllText(logPath, line + "\r\n"); } catch { }
        }
    }

    static int Main(string[] args)
    {
        var b = new Bridge();
        try { return b.Run(args); }
        catch (Exception e) { b.Log("FATAL " + e); return 1; }
    }

    int LobbySmoke()
    {
        logPath = Path.Combine(Path.GetTempPath(), "mirror_lobby_smoke.log");
        var sn = new SteamNet();
        sn.smokeLog = true;
        if (!sn.Init(Log)) { Console.WriteLine("SMOKE: Steam init failed"); return 2; }
        var d = new Dictionary<string, string>();
        d["surrounsync"] = "1"; d["name"] = "smoke"; d["proto"] = "0"; d["locked"] = "0"; d["players"] = "1/2"; d["host"] = sn.Me.ToString();
        sn.SetPublic(true, false, d);
        Console.WriteLine("SMOKE: " + sn.Debug());
        long t0 = Environment.TickCount;
        Console.WriteLine("SMOKE: friends " + sn.FriendCount() + ", hosting friends " + sn.FriendsWithPresence("host").Count);
        while (sn.PublicState == "creating" && Environment.TickCount - t0 < 30000) { sn.Pump(id => false, m => Console.WriteLine("SMOKE log: " + m)); Thread.Sleep(50); }
        Console.WriteLine("SMOKE: callbacks seen " + sn.callbacksSeen);
        string st = sn.PublicState;
        sn.SetPublic(false, false, null);
        sn.Shutdown();
        Console.WriteLine("SMOKE: lobby " + st);
        return st == "on" ? 0 : 1;
    }

    int VoiceSmoke()
    {
        logPath = Path.Combine(Path.GetTempPath(), "mirror_voice_smoke.log");
        var sn = new SteamNet();
        if (!sn.Init(m => Console.WriteLine("SMOKE log: " + m))) { Console.WriteLine("SMOKE: Steam init failed"); return 2; }
        var v = new Voice();
        v.Init(sn.SteamUser, m => Console.WriteLine("SMOKE log: " + m));
        Steam.SteamAPI_ISteamUser_StartVoiceRecording(sn.SteamUser);
        int ok = 0, nodata = 0, other = 0, lastOther = 0;
        long t0 = Environment.TickCount;
        while (Environment.TickCount - t0 < 2000)
        {
            sn.Pump(id => false, m => { });
            uint avail;
            int r = Steam.SteamAPI_ISteamUser_GetAvailableVoice(sn.SteamUser, out avail, IntPtr.Zero, 0);
            if (r == 0) ok++; else if (r == 3) nodata++; else { other++; lastOther = r; }
            Thread.Sleep(50);
        }
        Steam.SteamAPI_ISteamUser_StopVoiceRecording(sn.SteamUser);
        var vo = new VoiceOut();
        bool played = v.Output(vo, new byte[(int)(24000 * 2 * 0.3)], (int)(24000 * 2 * 0.3));
        Thread.Sleep(400);
        vo.Close();
        v.Shutdown();
        sn.Shutdown();
        Console.WriteLine("SMOKE: voice results ok " + ok + ", no data " + nodata + ", other " + other + " (last code " + lastOther + "); waveOut " + (played ? "ok" : "FAILED"));
        return played && other == 0 ? 0 : 1;
    }

    int Run(string[] args)
    {
        dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SurrounDead");
        role = "guest"; bool selftest = false; int testPort = 0; ulong testId = 0;
        ulong.TryParse(Environment.GetEnvironmentVariable("SURROUNSYNC_TEST_ID") ?? "", out testId);
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--role" && i + 1 < args.Length) role = args[++i];
            else if (args[i] == "--peer" && i + 1 < args.Length) ulong.TryParse(args[++i], out configuredPeer);
            else if (args[i] == "--selftest") selftest = true;
            else if (args[i] == "--dir" && i + 1 < args.Length) dir = args[++i];
            else if (args[i] == "--test-net" && i + 1 < args.Length) int.TryParse(args[++i], out testPort);
            else if (args[i] == "--no-game-check") gameCheck = false;
            else if (args[i] == "--test-id" && i + 1 < args.Length) ulong.TryParse(args[++i], out testId);
            else if (args[i] == "--lobby-smoke") return LobbySmoke();
            else if (args[i] == "--voice-smoke") return VoiceSmoke();
        }
        auto = role == "auto";
        if (auto) role = "idle";
        other = role == "host" ? "guest" : "host";
        logPath = Path.Combine(dir, auto ? "mirror_bridge.log" : "mirror_bridge_" + role + ".log");
        mutexName = "SurrounSyncBridge_" + (auto ? "auto" : role) + "_" + (dir.GetHashCode() & 0x7fffffff);
        try { File.WriteAllText(logPath, ""); } catch { }
        if (auto) { try { File.Delete(CmdFile()); } catch { } }

        bool created;
        using (var mutex = new Mutex(true, mutexName, out created))
        {
            // a stuck old bridge exits on its own watchdog within ~12 s: wait for it instead of quitting at once
            if (!created)
            {
                Log("another bridge for role " + role + " is running on " + dir + " - waiting up to 20 s for it to go");
                try { created = mutex.WaitOne(20000); } catch (AbandonedMutexException) { created = true; }
                if (!created) { Log("the other bridge is still running - exiting"); return 0; }
                Log("the old bridge is gone - taking over");
            }
            net = testPort > 0 ? (INet)new TestNet(testPort, testId) : new SteamNet();
            if (!net.Init(Log)) return 2;
            me = net.Me;
            voice.Init(net.SteamUser, Log);
            net.SetPresence(role); me = net.Me;
            Log("bridge " + role + " up" + (testPort > 0 ? " (TEST NET on 127.0.0.1:" + testPort + ")" : "") + " - my id " + me
                + ", folder " + dir + (configuredPeer != 0 ? ", peer from config " + configuredPeer : ", looking for a Steam friend"));
            if (selftest)
            {
                Log("selftest: network OK, my id " + me + ", friends " + net.FriendCount());
                net.Shutdown();
                return 0;
            }
            ClearPeerFiles();
            if (auto) StartUpdateCheck();
            StartWriter();
            StartWatchdog();
            try { Loop(); }
            finally
            {
                FlushWrites();
                foreach (var l in links)
                {
                    if (!l.mate) try { net.Close(l.id); } catch { }
                    try { File.Delete(ClockFile(l)); } catch { }
                    try { File.Delete(NameFile(l)); } catch { }
                    try { File.Delete(StatusFile(l.outTag)); } catch { }
                    l.voice.Close();
                }
                try { File.Delete(StatusFile(role)); } catch { }
                try { File.Delete(RosterFile()); } catch { }
                if (auto) { try { File.Delete(LobbyFile()); } catch { } }
                voice.Shutdown();
                net.Shutdown();
                Log("bridge stopped");
            }
        }
        return 0;
    }

    string RosterFile() { return Path.Combine(dir, "mirror_roster.txt"); }

    // what the other players sent us before (the files of every link this role can have), and their names
    void ClearPeerFiles()
    {
        var tails = new List<string> { "_" + other + ".txt" };
        for (int s = 1; s <= 3; s++) tails.Add("_from" + s + ".txt");
        Func<string, bool> mine = n => n.StartsWith("mirror_") && (n.StartsWith("mirror_peer_") && n.EndsWith(".name") || tails.Exists(t => n.EndsWith(t)));
        DropQueuedWrites(mine);
        try { foreach (var f in Directory.GetFiles(dir, "mirror_*")) if (mine(Path.GetFileName(f))) try { File.Delete(f); } catch { } }
        catch { }
    }

    // one link's files, when it goes away
    void ClearLinkFiles(PeerLink l)
    {
        string tail = "_" + l.inTag + ".txt", nf = Path.GetFileName(NameFile(l));
        Func<string, bool> mine = n => n == nf || (n.StartsWith("mirror_") && n.EndsWith(tail));
        DropQueuedWrites(mine);
        try { foreach (var f in Directory.GetFiles(dir, "mirror_*" + tail)) try { File.Delete(f); } catch { } } catch { }
        try { File.Delete(NameFile(l)); } catch { }
        if (!l.primary) { try { File.Delete(ClockFile(l)); } catch { } try { File.Delete(StatusFile(l.outTag)); } catch { } }
    }

    void DropLink(PeerLink l, string why)
    {
        if (!l.mate) try { net.Close(l.id); } catch { }
        ClearLinkFiles(l);
        l.voice.Close();
        links.Remove(l);
        rosterDirty = true;
        Log("left " + l.name + " (" + l.id + ")" + (l.mate ? " [via the host]" : "") + " - " + why);
    }

    void DropAllLinks(string why)
    {
        foreach (var l in new List<PeerLink>(links)) DropLink(l, why);
        mySlot = -1;
    }

    void Loop()
    {
        long lastHello = 0, lastScan = -10000, lastGameCheck = 0, lastStatus = 0, lastBlobScan = 0;
        long lastLobby = -10000, lastCmd = 0, lastPoseRead = 0;
        int gameMissing = 0;
        while (true)
        {
            long t = Now();
            Step("steam callbacks");
            net.Pump(OnSessionRequest, Log);
            if (auto && t - lastCmd > 250)
            {
                Step("command file"); lastCmd = t; ReadCommand(); ExpireRequests(t);
                if (browsing && net.Servers != null) { browsing = false; Log("found " + net.Servers.Count + " public game(s)"); WriteLobby(); }
            }
            if (auto && t - lastLobby > 2000) { Step("lobby file"); lastLobby = t; WriteLobby(); }
            if (role == "idle")
            {
                Step("idle receive"); Drain(0); Drain(1);
                Step("idle sleep"); Thread.Sleep(20);
                if (GameGone(ref lastGameCheck, ref gameMissing)) { Log("game closed - exiting"); return; }
                continue;
            }
            if (role == "guest" && HostLink() == null && t - lastScan > 3000) { Step("friend scan"); lastScan = t; Discover(); }
            foreach (var l in new List<PeerLink>(links))
            {
                if (t - l.lastHello > 1000 && Reachable(l))
                {
                    Step("hello"); l.lastHello = t;
                    SendRaw(l, 'H', epoch + " " + Unix() + " " + role + " " + (!gameCheck || gameMissing == 0 ? "1" : "0"), false);
                    // Steam only knows the names of your friends ("[unknown]" for anyone else): we say ours
                    if (t - l.lastNameSent > 5000) { l.lastNameSent = t; SendRaw(l, 'N', net.MyName ?? "", false); }
                }
                if (l.lastRx != 0 && t - l.lastRx > 20000 && t - l.quietAt > 20000)
                {
                    Log("no packets from " + l.name + " for 20 s");
                    l.quietAt = t;
                    if (configuredPeer == 0 && role == "guest" && l.slot == 0) DropLink(l, "lost");
                }
            }
            if (links.Count > 0)
            {
                if (t - lastPoseRead >= 10) { Step("pose send"); lastPoseRead = t; foreach (var l in links) if (CanPump(l)) PumpPose(l); }
                if (t - lastBlobScan > 15) { Step("blob send"); lastBlobScan = t; PumpBlobs(); }
            }
            Step("ping"); foreach (var l in links) Ping(l, t);
            Step("receive"); Receive(0); Receive(1);
            if (voice.Available) Receive(2);
            Step("voice");
            var vp = voice.Tick();
            // the host talks to every guest; a guest only to the host, whose bridge passes it on to the others
            if (vp != null) foreach (var l in links) if (!l.mate && (role == "host" || l.slot == 0)) SendBytesRaw(l, vp, false, 2);
            if (role == "host") foreach (var l in links) if (Live(l) != l.liveSent) { l.liveSent = !l.liveSent; rosterDirty = true; }
            if (role == "host" && (rosterDirty || t - rosterAt > 5000)) { Step("roster"); SendRoster(t); }
            if (t - voiceCfgAt > 250) { voiceCfgAt = t; ReadVoiceSettings(); }
            WriteVoiceState();
            if (t - lastStatus > 2000) { Step("status file"); lastStatus = t; WriteStatus(); }
            Step("game check");
            if (GameGone(ref lastGameCheck, ref gameMissing)) { Log("game closed - exiting"); return; }
            Step("sleep"); Thread.Sleep(4);
        }
    }

    bool GameGone(ref long last, ref int missing)
    {
        if (!gameCheck) return false;
        long t = Now();
        if (t - last <= 2000) return missing >= 5;
        last = t;
        if (Process.GetProcessesByName("SurrounDead-Win64-Shipping").Length == 0) missing++; else missing = 0;
        return missing >= 5;
    }

    string AllowFile() { return Path.Combine(dir, "mirror_allow.txt"); }
    HashSet<ulong> AllowList()
    {
        var set = new HashSet<ulong>();
        string s;
        lock (writeLock) pendingWrites.TryGetValue(AllowFile(), out s);
        if (s == null) s = ReadShared(AllowFile());
        if (s != null) foreach (var line in s.Split('\n')) { ulong id; if (ulong.TryParse(line.Trim(), out id)) set.Add(id); }
        return set;
    }
    void AddToAllowList(ulong id)
    {
        var set = AllowList();
        if (!set.Add(id)) return;
        var sb = new StringBuilder();
        foreach (var x in set) sb.Append(x).Append('\n');
        try { WriteAtomic(AllowFile(), sb.ToString()); } catch { }
    }
    bool Approved(ulong id) { return !auto || approved.Contains(id) || AllowList().Contains(id); }

    void Request(ulong from)
    {
        if (blocked.Contains(from) || requests.ContainsKey(from)) return;
        if (passKey != null && !passOk.Contains(from) && !AllowList().Contains(from))
        {
            long at;
            if (!challenges.ContainsKey(from) || (challengedAt.TryGetValue(from, out at) && Now() - at > 3000)) Challenge(from);
            return;
        }
        string name = net.NameOf(from);
        if (string.IsNullOrEmpty(name)) name = from.ToString();
        requests[from] = new KeyValuePair<string, long>(name, Now());
        Log("join request from " + name + " (" + from + ") - waiting for the host's answer");
        WriteLobby();
    }
    void TakeOrRequest(ulong from, string why)
    {
        if (blocked.Contains(from) || Direct(from) != null) return;
        if (Approved(from)) AddGuest(from, why); else Request(from);
    }

    static byte[] KeyOf(string password) { using (var h = SHA256.Create()) return h.ComputeHash(Encoding.UTF8.GetBytes(password)); }
    static string Answer(byte[] key, string nonce, ulong id)
    {
        using (var h = new HMACSHA256(key))
        {
            var b = h.ComputeHash(Encoding.UTF8.GetBytes(nonce + ":" + id));
            var sb = new StringBuilder();
            foreach (var x in b) sb.Append(x.ToString("x2"));
            return sb.ToString();
        }
    }
    static bool SameText(string a, string b)
    {
        if (a == null || b == null || a.Length != b.Length) return false;
        int d = 0;
        for (int i = 0; i < a.Length; i++) d |= a[i] ^ b[i];
        return d == 0;
    }
    bool SendTo(ulong to, char type, string body)
    {
        byte[] data = Encoding.UTF8.GetBytes(type + body);
        return net.Send(to, data, true, 1);
    }
    void Challenge(ulong from)
    {
        var rnd = new byte[16];
        using (var r = RandomNumberGenerator.Create()) r.GetBytes(rnd);
        var sb = new StringBuilder();
        foreach (var x in rnd) sb.Append(x.ToString("x2"));
        challenges[from] = sb.ToString();
        challengedAt[from] = Now();
        net.Accept(from);
        SendTo(from, 'C', challenges[from]);
        Log("password check sent to " + from);
    }
    void CheckAnswer(ulong from, string body)
    {
        string nonce;
        if (passKey == null || !challenges.TryGetValue(from, out nonce)) return;
        challenges.Remove(from);
        if (body != "none" && SameText(body, Answer(passKey, nonce, from)))
        {
            passOk.Add(from); badTries.Remove(from);
            Log("password right from " + from);
            Request(from);
            return;
        }
        int n; badTries.TryGetValue(from, out n);
        if (body != "none") badTries[from] = ++n;
        string why = body == "none" ? "needpass" : (n >= 3 ? "blocked" : "badpass");
        if (why == "blocked") blocked.Add(from);
        Log("password " + (body == "none" ? "missing" : "wrong") + " from " + from + " (" + n + ")" + (why == "blocked" ? " - blocked until you host again" : ""));
        SendTo(from, 'R', why);
    }

    bool OnSessionRequest(ulong from)
    {
        if (role == "idle")
        {
            pendingFrom = from;
            Log("session request from " + from + " while idle - kept until you host");
            return false;
        }
        if (blocked.Contains(from)) return false;
        if (Direct(from) != null) return true;
        if (role == "host")
        {
            if (!Approved(from)) { Request(from); return false; }
            return AddGuest(from, "it connected to us") != null;
        }
        if (HostLink() == null && from == configuredPeer && from != 0) { SetHost(from, "it connected to us"); return true; }
        Log("ignored a session request from " + from + (HostLink() != null ? " (in " + HostLink().name + "'s game)" : ""));
        return false;
    }

    void Drain(int channel)
    {
        ulong from;
        for (int k = 0; k < 500 && net.Read(channel, out from) != null; k++) { }
    }

    string CmdFile() { return Path.Combine(dir, "mirror_bridge_cmd.txt"); }
    string LobbyFile() { return Path.Combine(dir, "mirror_lobby.txt"); }

    void ReadCommand()
    {
        string c = ReadShared(CmdFile());
        if (c == null) return;
        try { File.Delete(CmdFile()); } catch { }
        c = c.Trim();
        if (c == "password" || c.StartsWith("password "))
        {
            string pw = c.Length > 9 ? c.Substring(9) : "";
            passKey = pw.Length > 0 ? KeyOf(pw) : null;
            passOk.Clear(); challenges.Clear(); badTries.Clear();
            Log(passKey != null ? "password set" : "password cleared");
            UpdatePublic();
            WriteLobby();
            return;
        }
        if (c == "host" || c.StartsWith("join"))
        {
            if (role != "idle")
            {
                DropAllLinks("switching");
                ClearPeerFiles();
                pendingFrom = 0;
            }
            if (c == "host") { role = "host"; configuredPeer = 0; slotOf.Clear(); }
            else
            {
                role = "guest";
                ulong id = 0;
                var parts = c.Split(' ');
                if (parts.Length > 1) ulong.TryParse(parts[1], out id);
                int at = parts.Length > 2 ? c.IndexOf(' ', c.IndexOf(' ') + 1) : -1;
                joinKey = at > 0 && at + 1 < c.Length ? KeyOf(c.Substring(at + 1)) : null;
                joinError = null; answered = false;
                if (id == me && id != 0) Log("warning: that's your own code - nobody can answer it on Steam");
                if (net is TestNet && id != 0) id = 1001UL;
                configuredPeer = id;
            }
            other = role == "host" ? "guest" : "host";
            epoch = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds().ToString();
            net.SetPresence(role); me = net.Me;
            ClearPeerFiles();
            Log("menu: now " + role + (configuredPeer != 0 ? " - connecting to " + configuredPeer : role == "guest" ? " - looking for a friend who hosts" : " - friends can join"));
            if (role == "host")
            {
                blocked.Clear(); requests.Clear(); approved.Clear();
                passOk.Clear(); challenges.Clear(); badTries.Clear();
                if (pendingFrom != 0) { ulong p = pendingFrom; pendingFrom = 0; TakeOrRequest(p, "it asked to join before you hosted"); }
            }
            WriteLobby();
        }
        else if (c.StartsWith("accept ") || c.StartsWith("allow ") || c.StartsWith("decline "))
        {
            var parts = c.Split(' ');
            ulong id;
            if (parts.Length < 2 || !ulong.TryParse(parts[1], out id)) { Log("bad command '" + c + "'"); return; }
            string name = requests.ContainsKey(id) ? requests[id].Key : id.ToString();
            requests.Remove(id);
            if (parts[0] == "decline")
            {
                blocked.Add(id);
                SendTo(id, 'R', "declined");
                Log("declined " + name + " (" + id + ")");
            }
            else
            {
                approved.Add(id);
                if (parts[0] == "allow") AddToAllowList(id);
                Log((parts[0] == "allow" ? "always allowed " : "accepted ") + name + " (" + id + ")");
                if (role == "host" && Direct(id) == null) AddGuest(id, "the host accepted");
            }
            WriteLobby();
        }
        else if (c == "public off" || c.StartsWith("public on "))
        {
            publicOn = c != "public off";
            if (publicOn)
            {
                var parts = c.Split(new[] { ' ' }, 4);
                publicProto = parts.Length > 2 ? parts[2] : "?";
                publicName = parts.Length > 3 ? parts[3] : net.MyName;
            }
            Log(publicOn ? "public listing on: " + publicName : "public listing off");
            UpdatePublic();
            WriteLobby();
        }
        else if (c == "browse")
        {
            net.RequestServers(); browsing = true;
            Log("searching for public games");
        }
        else if (c.StartsWith("kick "))
        {
            ulong id; var l = ulong.TryParse(c.Substring(5).Trim(), out id) ? Direct(id) : null;
            if (role == "host" && l != null && l.slot > 0) Kick(l, "the host removed them");
            else Log("kick: nobody with id " + c.Substring(5));
        }
        else if (c.StartsWith("slots "))
        {
            int n; if (int.TryParse(c.Substring(6).Trim(), out n)) maxGuests = Math.Max(1, Math.Min(3, n));
            Log("up to " + maxGuests + " guest(s)");
            UpdatePublic(); WriteLobby();
        }
        else if (c == "stop")
        {
            DropAllLinks("stopped");
            ClearPeerFiles();
            pendingFrom = 0; configuredPeer = 0;
            requests.Clear(); approved.Clear(); blocked.Clear(); slotOf.Clear();
            role = "idle"; other = "host";
            net.SetPresence("idle");
            publicOn = false; UpdatePublic();
            Log("menu: stopped - idle");
            WriteLobby();
        }
        else if (c == "update") StartUpdater();
        else if (c == "report" || c.StartsWith("report ")) StartReport(c.Length > 7 ? c.Substring(7) : null);
        else if (c == "clearallow") { try { File.Delete(AllowFile()); } catch { } Log("always-allowed list cleared"); WriteLobby(); }
        else Log("unknown command '" + c + "'");
    }

    void WriteLobby()
    {
        hosting.Clear();
        hosting.AddRange(net.FriendsWithPresence("host"));
        var sb = new StringBuilder();
        sb.Append("me ").Append(me).Append(' ').Append(me & 0xFFFFFFFFUL).Append(' ').Append(Clean(net.MyName)).Append('\n');
        sb.Append("role ").Append(role).Append('\n');
        sb.Append("time ").Append(Unix()).Append('\n');
        var pl = Primary();
        if (pl != null) sb.Append("peer ").Append(pl.id).Append(' ').Append(Clean(pl.name)).Append(' ').Append(pl.Connected ? "connected" : "connecting").Append('\n');
        // every other player: "player <slot> <id> <state> <outTag> <name>" (slot 0 = the host)
        foreach (var l in links)
            sb.Append("player ").Append(l.slot).Append(' ').Append(l.id).Append(' ')
              .Append(!l.Connected ? "connecting" : Now() - l.lastRx > 20000 ? "lost" : "connected").Append(' ').Append(l.outTag).Append(' ').Append(Clean(l.name)).Append('\n');
        if (role == "host") sb.Append("slots ").Append(maxGuests).Append('\n');
        if (mySlot >= 0) sb.Append("myslot ").Append(mySlot).Append('\n');
        foreach (var h in hosting) sb.Append("host ").Append(h.Key).Append(' ').Append(Clean(h.Value)).Append('\n');
        foreach (var r in requests) sb.Append("request ").Append(r.Key).Append(' ').Append(Clean(r.Value.Key)).Append('\n');
        if (kickedLine != null && Now() - kickedAt < 30000) sb.Append(kickedLine).Append('\n');
        sb.Append("allowed ").Append(AllowList().Count).Append('\n');
        if (passKey != null) sb.Append("password on\n");
        if (role == "host") sb.Append("public ").Append(publicOn ? net.PublicState : "off").Append('\n');
        var found = net.Servers;
        if (found != null)
            foreach (var d in found)
            {
                string id; d.TryGetValue("id", out id);
                string host; d.TryGetValue("host", out host);
                if (host == net.Me.ToString()) continue;
                sb.Append("server ").Append(string.IsNullOrEmpty(host) ? id : host)
                  .Append(' ').Append(Get(d, "locked", "0")).Append(' ').Append(Get(d, "players", "?"))
                  .Append(' ').Append(Get(d, "proto", "?")).Append(' ').Append(Clean(Get(d, "name", "?"))).Append('\n');
            }
        if (joinError != null) sb.Append("joinerror ").Append(joinError).Append('\n');
        sb.Append("voice ").Append(!voice.Available ? "unavailable" : !voice.On ? "off" : voice.Talking ? "talking" : "on").Append('\n');
        if (updateVersion != null) sb.Append("update ").Append(updateVersion).Append('\n');
        if (reportLine != null) sb.Append(reportLine).Append('\n');
        sb.Append("END\n");
        try { WriteAtomic(LobbyFile(), sb.ToString()); } catch { }
    }

    static string Clean(string s) { return (s ?? "").Replace('\n', ' ').Replace('\r', ' '); }

    static string ModDir() { return Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "..")); }
    static string Win64Dir() { return Path.GetFullPath(Path.Combine(ModDir(), "..", "..", "..")); }

    void StartUpdateCheck()
    {
        var th = new Thread(() =>
        {
            try
            {
                Thread.Sleep(4000);
                string mine = SurrounSyncShared.Release.ModVersion(ModDir());
                if (mine == null) { Log("update check: no version.lua next to the connector - skipped"); return; }
                string cache = Path.Combine(SurrounSyncShared.Release.AppDir, "update_check.txt");
                string latest = null;
                try
                {
                    var f = File.Exists(cache) ? File.ReadAllText(cache).Trim().Split(' ') : new string[0];
                    long at;
                    if (f.Length == 2 && long.TryParse(f[0], out at) && Unix() - at < 6 * 3600) latest = f[1];
                }
                catch { }
                if (latest == null)
                {
                    string err;
                    var info = SurrounSyncShared.Release.Latest(10000, out err);
                    if (info == null) { Log("update check: " + err); return; }
                    latest = info.Version;
                    try { Directory.CreateDirectory(SurrounSyncShared.Release.AppDir); File.WriteAllText(cache, Unix() + " " + latest); } catch { }
                }
                if (SurrounSyncShared.Release.Compare(latest, mine) > 0)
                {
                    updateVersion = latest;
                    Log("update check: SurrounSync " + latest + " is out (this is " + mine + ")");
                }
                else Log("update check: up to date (" + mine + ", newest " + latest + ")");
            }
            catch (Exception e) { Log("update check failed: " + e.Message); }
        });
        th.IsBackground = true;
        th.Start();
    }

    void StartUpdater()
    {
        string setup = Path.Combine(SurrounSyncShared.Release.AppDir, SurrounSyncShared.Release.SetupName);
        try
        {
            if (File.Exists(setup))
            {
                Process.Start(new ProcessStartInfo(setup, "--update --wait-game") { UseShellExecute = true });
                Log("update: started " + setup);
            }
            else
            {
                Process.Start(new ProcessStartInfo("https://github.com/" + SurrounSyncShared.Release.Repo + "/releases/latest") { UseShellExecute = true });
                Log("update: no installed setup - opened the release page");
            }
        }
        catch (Exception e) { Log("update: couldn't start the updater: " + e.Message); }
    }

    // message = what the player typed into the in-game bug report box (may be null)
    void StartReport(string message)
    {
        if (reportLine == "reporting") return;
        reportLine = "reporting";
        WriteLobby();
        var th = new Thread(() =>
        {
            string err;
            string zip = SurrounSyncShared.Report.Create(Win64Dir(), out err, false, message);
            Log(zip != null ? "bug report saved: " + zip : "bug report failed: " + err);
            if (zip == null) { reportLine = "reporterror " + Clean(err); return; }
            string sent = "off";
            if (SurrounSyncShared.Report.CanSend)
            {
                reportLine = "reporting";
                string serr;
                sent = SurrounSyncShared.Report.Send(zip, Win64Dir(), out serr) ? "ok" : "failed:" + Clean(serr);
                Log("bug report upload: " + sent);
            }
            reportLine = "report " + zip + "\nreportsent " + sent;
        });
        th.IsBackground = true;
        th.Start();
    }
    static string Get(Dictionary<string, string> d, string k, string def) { string v; return d.TryGetValue(k, out v) && v != "" ? v.Replace(' ', '_') : def; }

    // "me 0|1 peer 0|1" - who is talking right now, for the speaking icon on the name tag. Written only on a change.
    string voiceState = null;
    void WriteVoiceState()
    {
        var pv = Primary();
        var vsb = new StringBuilder("me " + (voice.Talking ? 1 : 0) + " peer " + (pv != null && pv.voice.Talking ? 1 : 0));
        foreach (var l in links) vsb.Append(' ').Append(l.outTag).Append(' ').Append(l.voice.Talking ? 1 : 0);
        string st = vsb.ToString();
        if (st == voiceState) return;
        voiceState = st;
        try { WriteAtomic(Path.Combine(dir, "mirror_voice_state.txt"), st); } catch { }
    }

    void ReadVoiceSettings()
    {
        string s = ReadShared(Path.Combine(dir, "mirror_voice.txt"));
        if (s == null) return;
        var f = s.Trim().Split(' ');
        for (int i = 0; i + 1 < f.Length; i += 2)
        {
            double v; if (!double.TryParse(f[i + 1], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out v)) continue;
            if (f[i] == "on") voice.On = v != 0;
            else if (f[i] == "key" && v > 0 && v < 256) voice.Key = (int)v;
            else if (f[i] == "volume") voice.Volume = Math.Max(0, Math.Min(1, v / 100.0));
            else if (f[i] == "dist") { var p = Primary(); if (p != null) p.voice.Distance = v; }
            else if (f[i].StartsWith("dist_")) { string tag = f[i].Substring(5); foreach (var l in links) if (l.outTag == tag) l.voice.Distance = v; }
        }
    }

    void UpdatePublic()
    {
        if (!(publicOn && role == "host")) { net.SetPublic(false, false, null); return; }
        var d = new Dictionary<string, string>();
        d["surrounsync"] = "1"; d["name"] = publicName; d["proto"] = publicProto;
        d["locked"] = passKey != null ? "1" : "0"; d["players"] = (1 + Guests()) + "/" + (1 + maxGuests); d["host"] = net.Me.ToString();
        net.SetPublic(true, true, d);
    }

    PeerLink NewLink(ulong id, int slot, bool mate, string name, string why)
    {
        var l = new PeerLink { id = id, slot = slot, mate = mate };
        if (role == "host") { l.outTag = slot == 1 ? "host" : "to" + slot; l.inTag = slot == 1 ? "guest" : "from" + slot; }
        else if (slot == 0) { l.outTag = "guest"; l.inTag = "host"; }
        else { l.outTag = "to" + slot; l.inTag = "from" + slot; }
        l.name = !string.IsNullOrEmpty(name) ? name : net.NameOf(id);
        if (string.IsNullOrEmpty(l.name)) l.name = id.ToString();
        l.lastHeard = l.lastRx = Now();
        links.Add(l);
        rosterDirty = true;
        if (!mate) net.Accept(id);
        Log("peer " + l.name + " (" + id + ")" + (role == "host" ? " in slot " + slot : mate ? " - another guest, slot " + slot : "") + " - " + why);
        try { WriteAtomic(NameFile(l), l.name); } catch { }
        if (Reachable(l))
        {
            SendRaw(l, 'H', epoch + " " + Unix() + " " + role, false);
            SendRaw(l, 'N', net.MyName ?? "", true);
            l.lastNameSent = Now();
        }
        UpdatePublic();
        WriteLobby();
        WriteRoster();
        return l;
    }

    void SetHost(ulong id, string why) { if (HostLink() == null) NewLink(id, 0, false, null, why); }

    // a free slot for this guest: the one it had before if that's still free, else the lowest one nobody had
    PeerLink AddGuest(ulong id, string why)
    {
        var l = Direct(id);
        if (l != null) return l;
        int slot = 0, had;
        Func<int, bool> free = s => !links.Exists(x => !x.mate && x.slot == s);
        if (slotOf.TryGetValue(id, out had) && had <= maxGuests && free(had)) slot = had;
        for (int s = 1; s <= maxGuests && slot == 0; s++) if (free(s) && !slotOf.ContainsValue(s)) slot = s;
        for (int s = 1; s <= maxGuests && slot == 0; s++) if (free(s)) slot = s;
        if (slot == 0)
        {
            // full: a guest silent for 30 s gives its place up
            PeerLink stale = null;
            foreach (var x in links) if (!x.mate && Now() - x.lastRx > 30000 && (stale == null || x.lastRx < stale.lastRx)) stale = x;
            if (stale == null)
            {
                Log("can't take " + id + " - the game is full (" + maxGuests + " guests)");
                SendTo(id, 'R', "full");
                return null;
            }
            slot = stale.slot;
            DropLink(stale, "silent for 30 s, its place goes to " + id);
        }
        slotOf[id] = slot;
        string asked = requests.ContainsKey(id) ? requests[id].Key : null;
        requests.Remove(id);
        l = NewLink(id, slot, false, asked, why);
        l.gen = ++rosterGen;
        return l;
    }

    // host: who is in the game ('W', reliable) - sent on every change and every 5 s; "<slot> <id> <gen> <name>"
    void SendRoster(long t)
    {
        rosterDirty = false; rosterAt = t;
        var sb = new StringBuilder();
        sb.Append("0 ").Append(me).Append(" 0 ").Append(Clean(net.MyName)).Append('\n');
        foreach (var l in links) if (Live(l)) sb.Append(l.slot).Append(' ').Append(l.id).Append(' ').Append(l.gen).Append(' ').Append(Clean(l.name)).Append('\n');
        string body = sb.ToString();
        foreach (var l in links) if (l.Connected) SendRaw(l, 'W', body, true);
        WriteRoster();
    }

    // guest: the host's list -> a link for every other guest (their traffic goes through the host's bridge)
    void TakeRoster(PeerLink from, string body)
    {
        if (from.slot != 0 || from.mate) return;
        var seen = new HashSet<ulong>();
        foreach (var line in body.Split('\n'))
        {
            var f = line.Split(new[] { ' ' }, 4);
            int slot, gen; ulong id;
            if (f.Length < 3 || !int.TryParse(f[0], out slot) || !ulong.TryParse(f[1], out id) || !int.TryParse(f[2], out gen)) continue;
            if (id == me) { if (mySlot != slot) { mySlot = slot; Log("I'm guest " + slot + " in " + from.name + "'s game"); WriteLobby(); } continue; }
            if (slot <= 0 || slot > 3) continue;
            seen.Add(id);
            var m = Mate(id);
            if (m != null && m.slot != slot) { DropLink(m, "moved to another slot"); m = null; }
            if (m == null) { m = NewLink(id, slot, true, f.Length > 3 ? f[3] : null, "in " + from.name + "'s game"); m.gen = gen; }
            else if (m.gen != gen)
            {
                // they reconnected to the host: what we sent while they were gone never arrived
                m.gen = gen; m.epoch = null; m.sent.Clear(); m.lastPose = null;
            }
        }
        foreach (var m in new List<PeerLink>(links)) if (m.mate && !seen.Contains(m.id)) DropLink(m, "left " + from.name + "'s game");
        WriteRoster();
    }

    // mirror_roster.txt for the mod: "me <slot> <id> <role>", then "peer <outTag> <inTag> <slot> <id> <state> <name>"
    void WriteRoster()
    {
        var sb = new StringBuilder("v1\n");
        sb.Append("me ").Append(role == "host" ? 0 : mySlot).Append(' ').Append(me).Append(' ').Append(role).Append('\n');
        foreach (var l in links)
            sb.Append("peer ").Append(l.outTag).Append(' ').Append(l.inTag).Append(' ').Append(l.slot).Append(' ').Append(l.id).Append(' ')
              .Append(Live(l) ? "connected" : l.Connected ? "silent" : "connecting").Append(' ').Append(Clean(l.name)).Append('\n');
        sb.Append("END\n");
        string text = sb.ToString();
        if (text == rosterFile) return;
        rosterFile = text;
        try { WriteAtomic(RosterFile(), text); } catch { }
    }

    // in the game right now: connected and heard from lately (a crashed guest keeps its slot, but leaves the list)
    bool Live(PeerLink l) { return l.Connected && Now() - l.lastRx < 20000; }

    bool CanPump(PeerLink l) { return Reachable(l) && (!l.mate || l.Connected); }

    static bool NameKnown(string n, ulong id)
    {
        return !string.IsNullOrEmpty(n) && n != "[unknown]" && n != id.ToString();
    }

    // the other player told us their Steam name: use it when Steam doesn't know them
    void TakePeerName(PeerLink l, string body)
    {
        string n = Clean(body).Trim();
        if (n.Length > 32) n = n.Substring(0, 32);
        if (n == "" || n == "[unknown]" || n == l.name || NameKnown(l.name, l.id)) return;
        l.name = n;
        rosterDirty = true;
        Log("the other player is " + n);
        try { WriteAtomic(NameFile(l), l.name); } catch { }
        WriteRoster();
        UpdatePublic();
        WriteLobby();
    }

    void Discover()
    {
        if (role == "host" && auto) return;
        if (configuredPeer != 0) { SetHost(configuredPeer, "from your code"); return; }
        var found = net.FriendsWithPresence(other);
        if (found.Count > 0) SetHost(found[0].Key, "Steam friend running SurrounSync as " + other);
    }

    // a packet to one player: straight to them, or for another guest wrapped for the host's bridge to pass on
    bool SendBytesRaw(PeerLink l, byte[] data, bool reliable, int channel)
    {
        bool ok;
        if (l.mate)
        {
            var h = HostLink();
            if (h == null || !h.Connected) return false;
            ok = net.Send(h.id, Wrap(l.id, data), reliable, channel);
        }
        else ok = net.Send(l.id, data, reliable, channel);
        if (ok) { l.txPkts++; l.txBytes += data.Length; }
        return ok;
    }

    static byte[] Wrap(ulong id, byte[] data) { return Wrap(id, data, 0); }
    static byte[] Wrap(ulong id, byte[] data, int offset)
    {
        var p = new byte[9 + data.Length - offset];
        p[0] = (byte)'X';
        BitConverter.GetBytes(id).CopyTo(p, 1);
        Buffer.BlockCopy(data, offset, p, 9, data.Length - offset);
        return p;
    }

    bool SendBytes(PeerLink l, char type, byte[] payload, bool reliable)
    {
        var data = new byte[payload.Length + 1];
        data[0] = (byte)type;
        Buffer.BlockCopy(payload, 0, data, 1, payload.Length);
        return SendBytesRaw(l, data, reliable, reliable ? 1 : 0);
    }

    // 'F' <id:4> <index:1> <count:1> <part>
    bool SendFragments(PeerLink l, byte[] z, int parts)
    {
        int id = ++fragId;
        for (int i = 0; i < parts; i++)
        {
            int off = i * FRAG, len = Math.Min(FRAG, z.Length - off);
            var p = new byte[6 + len];
            BitConverter.GetBytes(id).CopyTo(p, 0);
            p[4] = (byte)i; p[5] = (byte)parts;
            Buffer.BlockCopy(z, off, p, 6, len);
            if (!SendBytes(l, 'F', p, false)) return false;
        }
        return true;
    }

    static byte[] Deflate(byte[] raw)
    {
        using (var m = new MemoryStream())
        {
            using (var d = new DeflateStream(m, CompressionLevel.Fastest, true)) d.Write(raw, 0, raw.Length);
            return m.ToArray();
        }
    }

    // capped, so a bad packet can't unpack into something huge
    static string Inflate(byte[] z, int offset, int cap)
    {
        using (var src = new MemoryStream(z, offset, z.Length - offset))
        using (var d = new DeflateStream(src, CompressionMode.Decompress))
        using (var m = new MemoryStream())
        {
            var buf = new byte[16384];
            int n;
            while ((n = d.Read(buf, 0, buf.Length)) > 0)
            {
                m.Write(buf, 0, n);
                if (m.Length > cap) throw new InvalidDataException("too big");
            }
            return Encoding.UTF8.GetString(m.ToArray());
        }
    }

    // fragments of the newest latest-wins blob; an older or incomplete one is simply dropped
    // (data[o] = 'F', then <id:4> <index:1> <count:1> <part>)
    void TakeFragment(PeerLink l, byte[] data, int o)
    {
        if (data.Length - o < 8) return;
        int id = BitConverter.ToInt32(data, o + 1), idx = data[o + 5], count = data[o + 6];
        if (count == 0 || count > MAX_FRAGS || idx >= count) { Dropped(l, "size F"); return; }
        if (id != l.rxFragId)
        {
            if (l.rxFragId >= 0 && id < l.rxFragId && l.rxFragId - id < 100000) return;     // late part of an older one
            l.rxFragId = id; l.rxFrags = new byte[count][]; l.rxFragHave = 0;
        }
        if (l.rxFrags == null || l.rxFrags.Length != count || l.rxFrags[idx] != null) return;   // (already complete / mismatched)
        l.rxFrags[idx] = new byte[data.Length - o - 7];
        Buffer.BlockCopy(data, o + 7, l.rxFrags[idx], 0, data.Length - o - 7);
        if (++l.rxFragHave < count) return;
        int total = 0;
        foreach (var f in l.rxFrags) total += f.Length;
        var z = new byte[total];
        int at = 0;
        foreach (var f in l.rxFrags) { Buffer.BlockCopy(f, 0, z, at, f.Length); at += f.Length; }
        l.rxFrags = null;
        Handle(l, 'B', Inflate(z, 0, MAX_PART));
    }

    bool SendRaw(PeerLink l, char type, string body, bool reliable)
    {
        byte[] data = Encoding.UTF8.GetBytes(type + body);
        if (!reliable && data.Length > (l.mate ? 1190 : 1200)) reliable = true;
        return SendBytesRaw(l, data, reliable, reliable ? 1 : 0);
    }

    static string ReadShared(string path)
    {
        try
        {
            using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            using (var r = new StreamReader(fs, Encoding.UTF8)) return r.ReadToEnd();
        }
        catch { return null; }
    }

    // Every file the game reads is written by one writer thread, never by the network loop: on a PC where
    // each write takes long (antivirus scanning every new file, a slow or busy disk) the loop used to wait on
    // ~30 writes a second - round trips of 1-4 s, then a write stuck past the watchdog and the bridge quit
    // and restarted every ~35 s (friend test 2026-10-24). Queued writes of the same file keep only the
    // newest content; a re-queued file moves to the back, so a blob always lands before the index bump
    // that announces it.
    readonly object writeLock = new object();
    readonly Dictionary<string, string> pendingWrites = new Dictionary<string, string>();
    readonly List<string> writeOrder = new List<string>();
    readonly AutoResetEvent writeSignal = new AutoResetEvent(false);
    long slowWriteLogAt = -60000;

    static bool TryWrite(string path, string content)
    {
        string tmp = path + ".tmp";
        try
        {
            File.WriteAllText(tmp, content, new UTF8Encoding(false));
            if (File.Exists(path)) File.Replace(tmp, path, null); else File.Move(tmp, path);
            return true;
        }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
    }

    void WriteAtomic(string path, string content)
    {
        lock (writeLock)
        {
            if (pendingWrites.ContainsKey(path)) writeOrder.Remove(path);
            pendingWrites[path] = content;
            writeOrder.Add(path);
        }
        writeSignal.Set();
    }

    // drops queued writes whose file name passes the filter (the other game's old blobs after it restarted)
    void DropQueuedWrites(Func<string, bool> drop)
    {
        lock (writeLock)
            foreach (var p in new List<string>(writeOrder))
                if (drop(Path.GetFileName(p))) { writeOrder.Remove(p); pendingWrites.Remove(p); }
    }

    void StartWriter()
    {
        var th = new Thread(() =>
        {
            while (true)
            {
                writeSignal.WaitOne(250);
                while (true)
                {
                    string path, content;
                    lock (writeLock)
                    {
                        if (writeOrder.Count == 0) break;
                        path = writeOrder[0]; writeOrder.RemoveAt(0);
                        content = pendingWrites[path]; pendingWrites.Remove(path);
                    }
                    long t0 = Environment.TickCount;
                    bool ok = false;
                    for (int i = 0; i < 3 && !ok; i++) { ok = TryWrite(path, content); if (!ok) Thread.Sleep(1); }
                    long took = Environment.TickCount - t0;
                    if (took > 500 && Environment.TickCount - slowWriteLogAt > 60000)
                    {
                        slowWriteLogAt = Environment.TickCount;
                        Log("slow disk: writing " + Path.GetFileName(path) + " took " + took + " ms (antivirus or a busy disk?) - the link keeps running, only file updates wait");
                    }
                    if (!ok)
                    {
                        // the game had it open: try again shortly unless a newer content replaced it meanwhile
                        lock (writeLock) if (!pendingWrites.ContainsKey(path)) { pendingWrites[path] = content; writeOrder.Add(path); }
                        Thread.Sleep(2);
                    }
                }
            }
        });
        th.IsBackground = true;
        th.Start();
    }

    // the last queued writes before the bridge stops (up to 2 s)
    void FlushWrites()
    {
        long t0 = Environment.TickCount;
        while (Environment.TickCount - t0 < 2000)
        {
            lock (writeLock) if (writeOrder.Count == 0) return;
            writeSignal.Set();
            Thread.Sleep(10);
        }
    }

    void PumpPose(PeerLink l)
    {
        string s = ReadShared(Path.Combine(dir, "mirror_link_" + l.outTag + ".txt"));
        if (s == null) return;
        s = s.TrimEnd('\r', '\n');
        if (!s.EndsWith(" END") || s == l.lastPose) return;
        l.lastPose = s;
        SendRaw(l, 'P', s, false);
    }

    // one folder listing for every link: mirror_<name>_<outTag>.txt goes to the link with that tag
    void PumpBlobs()
    {
        string[] files;
        try { files = Directory.GetFiles(dir, "mirror_*.txt"); } catch { return; }
        var byTag = new Dictionary<string, PeerLink>();
        foreach (var l in links) if (CanPump(l)) byTag[l.outTag] = l;
        if (byTag.Count == 0) return;
        foreach (var path in files)
        {
            string file = Path.GetFileName(path);
            if (file.StartsWith("mirror_link_") || file.StartsWith("mirror_index_") || file.StartsWith("mirror_bridge_")) continue;
            int us = file.LastIndexOf('_');
            if (us <= "mirror".Length) continue;
            string tag = file.Substring(us + 1, file.Length - us - 1 - ".txt".Length);
            PeerLink l;
            if (!byTag.TryGetValue(tag, out l)) continue;
            DateTime w;
            try { w = File.GetLastWriteTimeUtc(path); } catch { continue; }
            if (w < startedUtc) continue;
            DateTime prev;
            if (l.seenWrite.TryGetValue(file, out prev) && prev == w && l.sent.ContainsKey(file)) continue;
            step = "blob send (read " + file + ")";     // finer label, same timer
            string s = ReadShared(path);
            if (s != null) s = s.Replace("\r\n", "\n");
            if (s == null || !s.EndsWith("\nEND\n")) continue;
            l.seenWrite[file] = w;
            string last;
            if (l.sent.TryGetValue(file, out last) && last == s) continue;
            string name = file.Substring("mirror_".Length, us - "mirror_".Length);
            step = "blob send (send " + name + ", " + s.Length + " chars)";
            if (SendBlob(l, name, s)) l.sent[file] = s;
        }
    }

    // Blobs over COMPRESS_FROM go deflated ('Z'). Blobs that are replaced many times a second (zombie snapshots,
    // the car being driven) go unreliable in fragments ('F'): a lost one is replaced by the next a moment later,
    // and they no longer hold up everything else on the reliable channel while Steam resends them.
    static readonly HashSet<string> LatestWins = new HashSet<string> { "zombies", "drive" };
    const int COMPRESS_FROM = 512, FRAG = 1100, MAX_FRAGS = 64;
    int fragId;

    bool SendBlob(PeerLink l, string name, string body)
    {
        bool ok;
        if (body.Length > COMPRESS_FROM && body.Length <= CHUNK)
        {
            byte[] z = Deflate(Encoding.UTF8.GetBytes(epoch + "\n" + name + "\n" + body));
            int parts = (z.Length + FRAG - 1) / FRAG;
            ok = LatestWins.Contains(name) && parts <= MAX_FRAGS ? SendFragments(l, z, parts) : SendBytes(l, 'Z', z, true);
            if (ok)
            {
                l.txBlobs++;
                if (l.loggedTx.Add(name)) Log("sent " + name + " to " + l.name + " (" + body.Length + " chars, " + z.Length + " B compressed)");
            }
            return ok;
        }
        if (body.Length <= CHUNK) ok = SendRaw(l, 'B', epoch + "\n" + name + "\n" + body, true);
        else
        {
            int id = ++msgId, count = (body.Length + CHUNK - 1) / CHUNK;
            ok = true;
            for (int i = 0; i < count && ok; i++)
            {
                string part = body.Substring(i * CHUNK, Math.Min(CHUNK, body.Length - i * CHUNK));
                ok = SendRaw(l, 'K', epoch + " " + id + " " + i + " " + count + "\n" + name + "\n" + part, true);
            }
        }
        if (ok)
        {
            l.txBlobs++;
            if (l.loggedTx.Add(name)) Log("sent " + name + " to " + l.name + " (" + body.Length + " chars)" + (body.Length > CHUNK ? " in pieces" : ""));
        }
        return ok;
    }

    void ExpireRequests(long t)
    {
        List<ulong> old = null;
        foreach (var r in requests) if (t - r.Value.Value > REQUEST_TIMEOUT) { if (old == null) old = new List<ulong>(); old.Add(r.Key); }
        if (old == null) return;
        foreach (var id in old) { Log("join request from " + requests[id].Key + " timed out (no answer in 60 s)"); requests.Remove(id); }
        WriteLobby();
    }

    // rate and size limits per player; o = where the packet starts (after a relay header)
    bool WithinLimits(PeerLink l, byte[] data, int o)
    {
        long t = Now();
        if (l.pktTokens < 0) { l.pktTokens = PKT_BURST; l.byteTokens = BYTE_BURST; l.tokensAt = t; }
        double dt = (t - l.tokensAt) / 1000.0; l.tokensAt = t;
        l.pktTokens = Math.Min(PKT_BURST, l.pktTokens + dt * PKT_RATE);
        l.byteTokens = Math.Min(BYTE_BURST, l.byteTokens + dt * BYTE_RATE);
        int len = data.Length - o;
        if (l.pktTokens < 1 || l.byteTokens < len) { Dropped(l, "rate"); return false; }
        l.pktTokens -= 1; l.byteTokens -= len;
        char type = len > 0 ? (char)data[o] : '?';
        int max = type == 'P' ? MAX_POSE : type == 'H' ? MAX_HELLO : (type == 'B' || type == 'K' || type == 'Z') ? MAX_PART
                : (type == 'C' || type == 'A' || type == 'R' || type == 'T' || type == 'N') ? 256 : type == 'V' ? 8192 : type == 'F' ? FRAG + 16
                : type == 'W' ? 1024 : type == 'X' ? MAX_PART + 9 : 0;
        if (len > max) { Dropped(l, "size " + type + " " + len + " B"); return false; }
        return true;
    }

    void Dropped(PeerLink l, string why)
    {
        long t = Now();
        string kind = why.Split(' ')[0];
        long last;
        if (!l.dropLogged.TryGetValue(kind, out last) || t - last > KICK_WINDOW) { l.dropLogged[kind] = t; Log("dropped a packet from " + l.name + " (" + why + ")"); }
        l.drops.Enqueue(t);
        while (l.drops.Count > 0 && t - l.drops.Peek() > KICK_WINDOW) l.drops.Dequeue();
        // another guest's packets come through the host: only the host link and the host's guests can be cut off
        if (l.drops.Count >= KICK_DROPS && !l.mate && links.Contains(l)) Kick(l, "too much data");
    }

    void Kick(PeerLink l, string why)
    {
        Log("disconnected " + l.name + " (" + l.id + "): " + why + " - blocked until you host again");
        blocked.Add(l.id); approved.Remove(l.id);
        kickedLine = "kicked " + l.id + " " + Clean(l.name); kickedAt = Now();
        if (role == "host") SendTo(l.id, 'R', "kicked");
        DropLink(l, "kicked");
        WriteLobby();
    }

    void Receive(int channel)
    {
        for (int k = 0; k < 500; k++)
        {
            ulong from;
            byte[] data = net.Read(channel, out from);
            if (data == null) break;
            var l = Direct(from);
            if (role == "host" && l == null && data.Length > 1 && data[0] == (byte)'A' && data.Length < 200)
            {
                CheckAnswer(from, Encoding.UTF8.GetString(data, 1, data.Length - 1));
                continue;
            }
            if (role == "host" && l == null && data.Length > 1 && data[0] == (byte)'N' && data.Length < 100)
            {
                // someone asking to join says who they are (Steam only names your friends)
                KeyValuePair<string, long> r;
                string n = Clean(Encoding.UTF8.GetString(data, 1, data.Length - 1)).Trim();
                if (n.Length > 32) n = n.Substring(0, 32);
                if (n != "" && requests.TryGetValue(from, out r) && !NameKnown(r.Key, from))
                {
                    requests[from] = new KeyValuePair<string, long>(n, r.Value);
                    WriteLobby();
                }
                continue;
            }
            if (role == "host" && l == null) { TakeOrRequest(from, "it sent us data"); l = Direct(from); }
            if (l == null) continue;
            l.rxPkts++; l.rxBytes += data.Length;
            if (!WithinLimits(l, data, 0)) continue;
            l.lastRx = Now(); l.lastHeard = l.lastRx;
            if (data[0] == (byte)'X') { Relayed(l, data, channel); continue; }
            ProcessPacket(l, data, 0);
        }
    }

    // a packet that came through the host's bridge: on the host, pass it on; on a guest, it's from another guest
    void Relayed(PeerLink from, byte[] data, int channel)
    {
        if (data.Length < 10) return;
        ulong id = BitConverter.ToUInt64(data, 1);
        if (role == "host")
        {
            var to = Direct(id);
            if (to == null || to == from || to.slot == 0 || !to.Connected) return;
            if (net.Send(to.id, Wrap(from.id, data, 9), channel == 1, channel)) { to.txPkts++; to.txBytes += data.Length; }
            return;
        }
        if (from.slot != 0) return;
        var m = Mate(id);
        if (m == null) return;           // not in the host's list (yet)
        m.rxPkts++; m.rxBytes += data.Length - 9;
        if (!WithinLimits(m, data, 9)) return;
        m.lastRx = Now(); m.lastHeard = m.lastRx;
        ProcessPacket(m, data, 9);
    }

    void ProcessPacket(PeerLink l, byte[] data, int o)
    {
        byte t = data[o];
        if (t == (byte)'V')
        {
            voice.Play(l.voice, data, o + 1);
            // the host passes a guest's voice on to the other guests
            if (role == "host" && !l.mate)
                foreach (var x in links) if (x != l && x.slot > 0 && x.Connected && net.Send(x.id, Wrap(l.id, data, o), false, 2)) { x.txPkts++; x.txBytes += data.Length; }
            return;
        }
        if (t == (byte)'Z' || t == (byte)'F')
        {
            try { if (t == (byte)'Z') Handle(l, 'B', Inflate(data, o + 1, MAX_PART)); else TakeFragment(l, data, o); }
            catch (Exception e) { Dropped(l, "bad " + (char)t + " " + e.Message); }
            return;
        }
        string msg = Encoding.UTF8.GetString(data, o, data.Length - o);
        if (msg.Length == 0) return;
        try { Handle(l, msg[0], msg.Substring(1)); } catch (Exception e) { Log("handle " + msg[0] + ": " + e.Message); }
    }

    void BlobEpoch(PeerLink l, string ep)
    {
        if (ep == l.blobEpoch) return;
        if (l.blobEpoch != null) Log(l.name + "'s game restarted - cleared its old data");
        l.blobEpoch = ep;
        try
        {
            string tail = "_" + l.inTag + ".txt";
            DropQueuedWrites(n => n.StartsWith("mirror_") && n.EndsWith(tail) && !n.StartsWith("mirror_link_"));
            foreach (var f in Directory.GetFiles(dir, "mirror_*" + tail))
                if (!Path.GetFileName(f).StartsWith("mirror_link_")) try { File.Delete(f); } catch { }
        }
        catch { }
    }

    void WriteBlob(PeerLink l, string name, string body)
    {
        if (name.Length == 0 || name.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0) return;
        WriteAtomic(Path.Combine(dir, "mirror_" + name + "_" + l.inTag + ".txt"), body);
        BumpIndex(l, name);
        l.rxBlobs++;
        if (l.loggedRx.Add(name)) Log("got " + name + " from " + l.name + " (" + body.Length + " chars)");
    }

    // One small file the game reads instead of opening every blob file each frame: a counter per blob name,
    // bumped after the blob is written. The first token changes per link so the game drops old counters.
    void BumpIndex(PeerLink l, string name)
    {
        long g;
        l.blobGen.TryGetValue(name, out g);
        l.blobGen[name] = g + 1;
        var sb = new StringBuilder("v1 ").Append(l.indexRun).Append('\n');
        foreach (var kv in l.blobGen) sb.Append(kv.Key).Append(' ').Append(kv.Value).Append('\n');
        sb.Append("END\n");
        WriteAtomic(Path.Combine(dir, "mirror_index_" + l.inTag + ".txt"), sb.ToString());
    }

    // bridge-to-bridge round trip, without the games in between (what the network itself costs)
    void Ping(PeerLink l, long t)
    {
        if (t - l.pingAt < 2000 || !CanPump(l)) return;
        l.pingAt = t;
        SendRaw(l, 'T', "q" + t, false);
    }

    void Handle(PeerLink l, char type, string body)
    {
        if (type == 'T')
        {
            long sent;
            if (body.StartsWith("q")) SendRaw(l, 'T', "a" + body.Substring(1), false);
            else if (body.StartsWith("a") && long.TryParse(body.Substring(1), out sent))
            {
                double r = Now() - sent;
                if (r >= 0 && r < 30000) l.rtt = l.rtt < 0 ? r : l.rtt * 0.7 + r * 0.3;
            }
            return;
        }
        if (type == 'P')
        {
            int a = body.IndexOf(' '), b2 = a < 0 ? -1 : body.IndexOf(' ', a + 1);
            if (b2 < 0) return;
            string line = body.Substring(0, a) + " " + Unix() + body.Substring(b2);
            WriteAtomic(Path.Combine(dir, "mirror_link_" + l.inTag + ".txt"), line + "\n");
        }
        else if (type == 'B')
        {
            int n1 = body.IndexOf('\n');
            int n2 = n1 < 0 ? -1 : body.IndexOf('\n', n1 + 1);
            if (n2 < 0) return;
            BlobEpoch(l, body.Substring(0, n1));
            WriteBlob(l, body.Substring(n1 + 1, n2 - n1 - 1), body.Substring(n2 + 1));
        }
        else if (type == 'K')
        {
            int n1 = body.IndexOf('\n');
            int n2 = n1 < 0 ? -1 : body.IndexOf('\n', n1 + 1);
            if (n2 < 0) return;
            var h = body.Substring(0, n1).Split(' ');
            if (h.Length < 4) return;
            string name = body.Substring(n1 + 1, n2 - n1 - 1);
            int idx, count;
            if (!int.TryParse(h[2], out idx) || !int.TryParse(h[3], out count) || count <= 0 || idx >= count) return;
            if (count > MAX_PARTS) { Dropped(l, "size K " + count + " parts"); return; }
            BlobEpoch(l, h[0]);
            string key = h[0] + " " + h[1];
            if (key != l.chunkKey || idx == 0) { l.chunkKey = key; l.chunkName = name; l.chunkParts = new string[count]; l.chunkGot = 0; }
            if (l.chunkParts[idx] == null) { l.chunkParts[idx] = body.Substring(n2 + 1); l.chunkGot++; }
            if (l.chunkGot == count)
            {
                WriteBlob(l, l.chunkName, string.Concat(l.chunkParts));
                l.chunkKey = null; l.chunkParts = null;
            }
        }
        else if (type == 'C' && role == "guest" && l.slot == 0 && !l.mate)
        {
            if (answered) return;
            answered = true;
            SendRaw(l, 'A', joinKey == null ? "none" : Answer(joinKey, body.Trim(), me), true);
            Log("answered the host's password check" + (joinKey == null ? " (no password typed)" : ""));
        }
        else if (type == 'R' && role == "guest" && l.slot == 0 && !l.mate)
        {
            joinError = body.Trim();
            Log("the host refused: " + joinError);
            WriteLobby();
        }
        else if (type == 'W' && role == "guest") TakeRoster(l, body);
        else if (type == 'N') TakePeerName(l, body);
        else if (type == 'H')
        {
            var f = body.Split(' ');
            long remote;
            if (f.Length >= 2 && long.TryParse(f[1], out remote))
                WriteAtomic(ClockFile(l), (Unix() - remote).ToString());
            if (f.Length >= 4) l.game = f[3] == "1" ? "alive" : "gone";
            if (f.Length >= 1 && f[0] != l.epoch)
            {
                l.epoch = f[0];
                Log("connected to " + l.name + " (their session " + l.epoch + ")");
                l.sent.Clear(); l.lastPose = null;
                rosterDirty = true;
                if (role == "host") l.gen = ++rosterGen;
                // the host's bridge restarted: what we sent the other guests through it may be lost
                if (role == "guest" && l.slot == 0) foreach (var m in links) if (m.mate) { m.epoch = null; m.sent.Clear(); m.lastPose = null; }
                WriteRoster();
                WriteLobby();
            }
        }
    }

    void WriteStatus()
    {
        // the first guest's / the host's link keeps the old file name; a host without guests says "searching"
        if (Primary() == null && role != "idle") WriteStatusOf(null, role);
        foreach (var l in links) WriteStatusOf(l, l.outTag);
    }

    void WriteStatusOf(PeerLink l, string tag)
    {
        double hb = l == null || l.lastHeard == 0 ? -1 : (Now() - l.lastHeard) / 1000.0;
        string s = string.Format("bridge {0}: me {1}, peer {2} ({3}), last rx {4:0.0} s, pkts tx {5} rx {6}, KB tx {7:0} rx {8:0}, blobs tx {9} rx {10} peer_hb {4:0.0} peer_game {12} at {11}",
            role, me, l == null ? "searching" : l.name, l == null ? 0 : l.id, hb,
            l == null ? 0 : l.txPkts, l == null ? 0 : l.rxPkts, l == null ? 0 : l.txBytes / 1024.0, l == null ? 0 : l.rxBytes / 1024.0,
            l == null ? 0 : l.txBlobs, l == null ? 0 : l.rxBlobs, Unix(), l == null ? "?" : l.game)
            + (l != null && l.rtt >= 0 ? string.Format(" rtt {0:0} ms", l.rtt) : " rtt ?")
            + (l != null ? " " + (l.mate ? "route via-host" : net.Route(l.id)) + " slot " + l.slot : "");
        try { WriteAtomic(StatusFile(tag), s); } catch { }
    }
}
