// SurrounSyncBridge: carries the mod's link files between the two games over Steam P2P, using the
// game's own steam_api64.dll. Also handles join requests, passwords, public games, voice and update checks.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
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
        createCall = Steam.SteamAPI_ISteamMatchmaking_CreateLobby(MM(), listed ? 2 : 0, 2);
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

class TestNet : INet
{
    readonly int port;
    string role = "idle";
    TcpListener listener;
    TcpClient client;
    NetworkStream stream;
    readonly object qlock = new object();
    readonly Queue<byte[]>[] queues = { new Queue<byte[]>(), new Queue<byte[]>() };
    ulong pendingRequest;
    long nextConnect;

    public TestNet(int port) { this.port = port; }
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
    public ulong Me { get { return role == "host" ? 1001UL : 1002UL; } }
    public string MyName { get { return "Test-" + role; } }
    public bool Init(Action<string> log) { return true; }

    public void SetPresence(string r)
    {
        if (r != role)
        {
            DropClient();
            if (listener != null && r != "host") { try { listener.Stop(); } catch { } listener = null; }
        }
        role = r;
        TryListen();
    }

    void TryListen()
    {
        if (role != "host" || listener != null) return;
        try { var l = new TcpListener(IPAddress.Loopback, port); l.Start(); listener = l; }
        catch { listener = null; }
    }

    void DropClient()
    {
        if (client != null) try { client.Close(); } catch { }
        client = null; stream = null;
        lock (qlock) { queues[0].Clear(); queues[1].Clear(); }
    }

    void StartReader(TcpClient c, ulong from)
    {
        var s = c.GetStream();
        var t = new Thread(() =>
        {
            try
            {
                var head = new byte[5];
                while (true)
                {
                    if (!ReadFull(s, head, 5)) break;
                    int len = BitConverter.ToInt32(head, 0);
                    var data = new byte[len];
                    if (!ReadFull(s, data, len)) break;
                    int ch = head[4] == 1 ? 1 : 0;
                    lock (qlock) queues[ch].Enqueue(data);
                }
            }
            catch { }
        });
        t.IsBackground = true;
        t.Start();
        if (role == "host") pendingRequest = from;
    }

    static bool ReadFull(NetworkStream s, byte[] b, int n)
    {
        int got = 0;
        while (got < n) { int k = s.Read(b, got, n - got); if (k <= 0) return false; got += k; }
        return true;
    }

    public void Pump(Func<ulong, bool> onSessionRequest, Action<string> log)
    {
        long t = Environment.TickCount;
        if (role == "host" && listener == null && t >= nextConnect) { nextConnect = t + 1000; TryListen(); }
        if (role == "host" && listener != null && listener.Pending())
        {
            var c = listener.AcceptTcpClient();
            c.NoDelay = true;
            if (client != null) try { client.Close(); } catch { }
            client = c; stream = c.GetStream();
            StartReader(c, 1002UL);
        }
        else if (role == "guest" && (client == null || !client.Connected) && t >= nextConnect)
        {
            nextConnect = t + 1000;
            try
            {
                var c = new TcpClient();
                c.NoDelay = true;
                c.Connect(IPAddress.Loopback, port);
                client = c; stream = c.GetStream();
                StartReader(c, 1001UL);
            }
            catch { client = null; }
        }
        if (pendingRequest != 0) { ulong p = pendingRequest; pendingRequest = 0; onSessionRequest(p); }
    }

    public bool Send(ulong to, byte[] data, bool reliable, int channel)
    {
        if (stream == null) return false;
        try
        {
            var frame = new byte[5 + data.Length];
            BitConverter.GetBytes(data.Length).CopyTo(frame, 0);
            frame[4] = (byte)channel;
            Buffer.BlockCopy(data, 0, frame, 5, data.Length);
            stream.Write(frame, 0, frame.Length);
            return true;
        }
        catch { stream = null; client = null; return false; }
    }

    public byte[] Read(int channel, out ulong from)
    {
        from = role == "host" ? 1002UL : 1001UL;
        if (channel < 0 || channel >= queues.Length) return null;
        lock (qlock) return queues[channel].Count > 0 ? queues[channel].Dequeue() : null;
    }

    public void Accept(ulong id) { }
    public void Close(ulong id) { DropClient(); }
    public string NameOf(ulong id) { return id == 1001UL ? "Test-host" : "Test-guest"; }
    public int FriendCount() { return 0; }
    public List<KeyValuePair<ulong, string>> FriendsWithPresence(string r)
    {
        var l = new List<KeyValuePair<ulong, string>>();
        if (r == "host") l.Add(new KeyValuePair<ulong, string>(1001UL, "Test-host"));
        return l;
    }
    public void Shutdown() { try { if (client != null) client.Close(); if (listener != null) listener.Stop(); } catch { } }
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

class Voice
{
    IntPtr user = IntPtr.Zero;
    public bool Available { get { return user != IntPtr.Zero; } }
    public bool On;
    public int Key = 0x56;
    public double Volume = 1.0;
    public double Distance = 0;
    public bool Talking;
    uint rate = 24000;
    IntPtr wave = IntPtr.Zero;
    readonly List<IntPtr> queued = new List<IntPtr>();
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
    public void Tick(Func<byte[], bool> send)
    {
        if (!Available) return;
        long t = Environment.TickCount;
        if (t - focusAt > 300) { focusAt = t; focused = GameFocused(); }
        bool want = On && focused && (Win.GetAsyncKeyState(Key) & 0x8000) != 0;
        if (want != Talking)
        {
            Talking = want;
            if (want) Steam.SteamAPI_ISteamUser_StartVoiceRecording(user); else Steam.SteamAPI_ISteamUser_StopVoiceRecording(user);
        }
        uint avail;
        if (Steam.SteamAPI_ISteamUser_GetAvailableVoice(user, out avail, IntPtr.Zero, 0) != 0 || avail == 0) return;
        uint got;
        if (Steam.SteamAPI_ISteamUser_GetVoice(user, true, cbuf, (uint)cbuf.Length, out got, false, IntPtr.Zero, 0, IntPtr.Zero, 0) != 0 || got == 0) return;
        var pkt = new byte[got + 1];
        pkt[0] = (byte)'V';
        Buffer.BlockCopy(cbuf, 0, pkt, 1, (int)got);
        if (send(pkt)) Sent++;
    }

    double Gain() { double d = Distance; double g = d <= 5 ? 1.0 : d >= 50 ? 0.0 : 1.0 - (d - 5) / 45.0; return g * Volume; }

    public void Play(byte[] data, int offset)
    {
        if (!Available || !On) return;
        double g = Gain();
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
        Output(pcm, (int)got);
        Played++;
    }

    public bool Output(byte[] buf, int n)
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

    public void Shutdown()
    {
        if (Talking && Available) Steam.SteamAPI_ISteamUser_StopVoiceRecording(user);
        if (wave != IntPtr.Zero) { Win.waveOutClose(wave); wave = IntPtr.Zero; }
    }
}

class Bridge
{
    const int CHUNK = 256 * 1024;

    string role, other, dir, logPath, mutexName;
    bool auto, gameCheck = true;
    readonly List<KeyValuePair<ulong, string>> hosting = new List<KeyValuePair<ulong, string>>();
    ulong me, peer, configuredPeer, pendingFrom;
    string peerGame = "?";
    long lastHeard;
    string peerName = "";
    INet net;
    string epoch = DateTimeOffset.UtcNow.ToUnixTimeSeconds().ToString();
    readonly DateTime startedUtc = DateTime.UtcNow.AddSeconds(-30);
    string peerEpoch = null;
    string blobEpoch = null;
    long lastRx = 0;
    readonly Dictionary<string, string> sent = new Dictionary<string, string>();
    readonly Dictionary<string, DateTime> seenWrite = new Dictionary<string, DateTime>();
    readonly HashSet<string> loggedTx = new HashSet<string>(), loggedRx = new HashSet<string>();
    string lastPose = null;
    long txBytes, rxBytes, txPkts, rxPkts, txBlobs, rxBlobs;
    int msgId = 0;
    string chunkName; string chunkKey; string[] chunkParts; int chunkGot;

    readonly HashSet<ulong> approved = new HashSet<ulong>();
    readonly HashSet<ulong> blocked = new HashSet<ulong>();
    readonly Dictionary<ulong, KeyValuePair<string, long>> requests = new Dictionary<ulong, KeyValuePair<string, long>>();
    string kickedLine = null; long kickedAt = 0;
    volatile string updateVersion = null;
    volatile string reportLine = null;
    const long REQUEST_TIMEOUT = 60000;
    const int MAX_POSE = 2048, MAX_HELLO = 256, MAX_PART = CHUNK + 1024, MAX_PARTS = 32;
    const double PKT_RATE = 600, PKT_BURST = 3000, BYTE_RATE = 4.0 * 1024 * 1024, BYTE_BURST = 16.0 * 1024 * 1024;
    double pktTokens = PKT_BURST, byteTokens = BYTE_BURST; long tokensAt = 0;
    readonly Queue<long> drops = new Queue<long>();
    readonly Dictionary<string, long> dropLogged = new Dictionary<string, long>();
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
    static long Unix() { return DateTimeOffset.UtcNow.ToUnixTimeSeconds(); }

    void Log(string m)
    {
        string line = DateTime.Now.ToString("HH:mm:ss") + " " + m;
        Console.WriteLine(line);
        try { File.AppendAllText(logPath, line + "\r\n"); } catch { }
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
        bool played = v.Output(new byte[(int)(24000 * 2 * 0.3)], (int)(24000 * 2 * 0.3));
        Thread.Sleep(400);
        v.Shutdown();
        sn.Shutdown();
        Console.WriteLine("SMOKE: voice results ok " + ok + ", no data " + nodata + ", other " + other + " (last code " + lastOther + "); waveOut " + (played ? "ok" : "FAILED"));
        return played && other == 0 ? 0 : 1;
    }

    int Run(string[] args)
    {
        dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SurrounDead");
        role = "guest"; bool selftest = false; int testPort = 0;
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--role" && i + 1 < args.Length) role = args[++i];
            else if (args[i] == "--peer" && i + 1 < args.Length) ulong.TryParse(args[++i], out configuredPeer);
            else if (args[i] == "--selftest") selftest = true;
            else if (args[i] == "--dir" && i + 1 < args.Length) dir = args[++i];
            else if (args[i] == "--test-net" && i + 1 < args.Length) int.TryParse(args[++i], out testPort);
            else if (args[i] == "--no-game-check") gameCheck = false;
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
            if (!created) { Log("another bridge for role " + role + " is running on " + dir + " - exiting"); return 0; }
            net = testPort > 0 ? (INet)new TestNet(testPort) : new SteamNet();
            if (!net.Init(Log)) return 2;
            me = net.Me;
            voice.Init(net.SteamUser, Log);
            net.SetPresence(role);
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
            try { Loop(); }
            finally
            {
                if (peer != 0) net.Close(peer);
                try { File.Delete(Path.Combine(dir, "mirror_clock_offset.txt")); } catch { }
                try { File.Delete(PeerNameFile()); } catch { }
                try { File.Delete(Path.Combine(dir, "mirror_bridge_status_" + role + ".txt")); } catch { }
                if (auto) { try { File.Delete(LobbyFile()); } catch { } }
                voice.Shutdown();
                net.Shutdown();
                Log("bridge stopped");
            }
        }
        return 0;
    }

    string PeerNameFile() { return Path.Combine(dir, "mirror_peer_" + role + ".name"); }

    void ClearPeerFiles()
    {
        try { File.Delete(PeerNameFile()); } catch { }
        try
        {
            foreach (var f in Directory.GetFiles(dir, "mirror_*_" + other + ".txt"))
                try { File.Delete(f); } catch { }
        }
        catch { }
    }

    void Loop()
    {
        long lastHello = 0, lastScan = -10000, lastGameCheck = 0, lastStatus = 0, lastBlobScan = 0;
        long lastLobby = -10000, lastCmd = 0, lastPoseRead = 0;
        int gameMissing = 0;
        while (true)
        {
            long t = Now();
            net.Pump(OnSessionRequest, Log);
            if (auto && t - lastCmd > 250)
            {
                lastCmd = t; ReadCommand(); ExpireRequests(t);
                if (browsing && net.Servers != null) { browsing = false; Log("found " + net.Servers.Count + " public game(s)"); WriteLobby(); }
            }
            if (auto && t - lastLobby > 2000) { lastLobby = t; WriteLobby(); }
            if (role == "idle")
            {
                Drain(0); Drain(1);
                FlushWrites();
                Thread.Sleep(20);
                if (GameGone(ref lastGameCheck, ref gameMissing)) { Log("game closed - exiting"); return; }
                continue;
            }
            if (peer == 0 && t - lastScan > 3000) { lastScan = t; Discover(); }
            if (peer != 0 && t - lastHello > 1000)
            {
                lastHello = t;
                SendRaw('H', epoch + " " + Unix() + " " + role + " " + (!gameCheck || gameMissing == 0 ? "1" : "0"), false);
            }
            if (peer != 0 && lastRx != 0 && t - lastRx > 20000)
            {
                Log("no packets from " + peerName + " for 20 s");
                lastRx = t;
                if (configuredPeer == 0 && role == "guest") { peer = 0; peerEpoch = null; }
            }
            if (peer != 0)
            {
                if (t - lastPoseRead >= 10) { lastPoseRead = t; PumpPose(); }
                if (t - lastBlobScan > 15) { lastBlobScan = t; PumpBlobs(); }
            }
            Receive(0); Receive(1);
            if (voice.Available) Receive(2);
            if (peer != 0) voice.Tick(pkt => { bool ok = net.Send(peer, pkt, false, 2); if (ok) { txPkts++; txBytes += pkt.Length; } return ok; });
            if (t - voiceCfgAt > 250) { voiceCfgAt = t; ReadVoiceSettings(); }
            FlushWrites();
            if (t - lastStatus > 2000) { lastStatus = t; WriteStatus(); }
            if (GameGone(ref lastGameCheck, ref gameMissing)) { Log("game closed - exiting"); return; }
            Thread.Sleep(4);
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
        string s = ReadShared(AllowFile());
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
        if (blocked.Contains(from)) return;
        if (Approved(from)) SetPeer(from, why); else Request(from);
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
        bool ok = net.Send(to, data, true, 1);
        if (ok) { txPkts++; txBytes += data.Length; }
        return ok;
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
        if (role == "host" && peer == 0 && !Approved(from)) { Request(from); return false; }
        bool ok = (peer == 0 && (role == "host" || from == configuredPeer)) || from == peer;
        if (ok) { if (peer == 0) SetPeer(from, "it connected to us"); return true; }
        Log("ignored a session request from " + from + " (talking to " + peer + ")");
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
                if (peer != 0) { try { net.Close(peer); } catch { } Log("left " + peerName + " (" + peer + ") - switching"); }
                ClearPeerFiles();
                peer = 0; peerEpoch = null; pendingFrom = 0;
                sent.Clear(); lastPose = null;
                try { File.Delete(PeerNameFile()); } catch { }
            }
            if (c == "host") { role = "host"; configuredPeer = 0; }
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
            net.SetPresence(role);
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
                if (role == "host" && peer == 0) SetPeer(id, "the host accepted");
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
        else if (c == "stop")
        {
            if (peer != 0) { try { net.Close(peer); } catch { } Log("left " + peerName + " (" + peer + ") - stopped"); }
            ClearPeerFiles();
            peer = 0; peerEpoch = null; pendingFrom = 0; configuredPeer = 0;
            sent.Clear(); lastPose = null; requests.Clear(); approved.Clear(); blocked.Clear();
            try { File.Delete(PeerNameFile()); } catch { }
            role = "idle"; other = "host";
            net.SetPresence("idle");
            publicOn = false; UpdatePublic();
            Log("menu: stopped - idle");
            WriteLobby();
        }
        else if (c == "update") StartUpdater();
        else if (c == "report") StartReport();
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
        if (peer != 0) sb.Append("peer ").Append(peer).Append(' ').Append(Clean(peerName)).Append(' ').Append(peerEpoch != null ? "connected" : "connecting").Append('\n');
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

    void StartReport()
    {
        if (reportLine == "reporting") return;
        reportLine = "reporting";
        WriteLobby();
        var th = new Thread(() =>
        {
            string err;
            string zip = SurrounSyncShared.Report.Create(Win64Dir(), out err);
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
            else if (f[i] == "dist") voice.Distance = v;
        }
    }

    void UpdatePublic()
    {
        if (!(publicOn && role == "host")) { net.SetPublic(false, false, null); return; }
        var d = new Dictionary<string, string>();
        d["surrounsync"] = "1"; d["name"] = publicName; d["proto"] = publicProto;
        d["locked"] = passKey != null ? "1" : "0"; d["players"] = (peer != 0 ? "2" : "1") + "/2"; d["host"] = net.Me.ToString();
        net.SetPublic(true, true, d);
    }

    void SetPeer(ulong id, string why)
    {
        peer = id; peerGame = "?"; lastHeard = Now();
        peerName = net.NameOf(id);
        if (string.IsNullOrEmpty(peerName)) peerName = id.ToString();
        net.Accept(id);
        lastRx = Now(); peerEpoch = null;
        sent.Clear(); lastPose = null;
        Log("peer " + peerName + " (" + id + ") - " + why);
        UpdatePublic();
        try { WriteAtomic(PeerNameFile(), peerName); } catch { }
        SendRaw('H', epoch + " " + Unix() + " " + role, false);
    }

    void Discover()
    {
        if (role == "host" && auto) return;
        if (configuredPeer != 0) { SetPeer(configuredPeer, "from your code"); return; }
        var found = net.FriendsWithPresence(other);
        if (found.Count > 0) SetPeer(found[0].Key, "Steam friend running SurrounSync as " + other);
    }

    bool SendRaw(char type, string body, bool reliable)
    {
        if (peer == 0) return false;
        byte[] data = Encoding.UTF8.GetBytes(type + body);
        if (!reliable && data.Length > 1200) reliable = true;
        bool ok = net.Send(peer, data, reliable, reliable ? 1 : 0);
        if (ok) { txPkts++; txBytes += data.Length; }
        return ok;
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

    readonly Dictionary<string, string> pendingWrites = new Dictionary<string, string>();

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
        pendingWrites.Remove(path);
        for (int i = 0; i < 3; i++)
        {
            if (TryWrite(path, content)) return;
            Thread.Sleep(1);
        }
        pendingWrites[path] = content;
    }

    void FlushWrites()
    {
        if (pendingWrites.Count == 0) return;
        foreach (var kv in new List<KeyValuePair<string, string>>(pendingWrites))
            if (TryWrite(kv.Key, kv.Value)) pendingWrites.Remove(kv.Key);
    }

    void PumpPose()
    {
        string s = ReadShared(Path.Combine(dir, "mirror_link_" + role + ".txt"));
        if (s == null) return;
        s = s.TrimEnd('\r', '\n');
        if (!s.EndsWith(" END") || s == lastPose) return;
        lastPose = s;
        SendRaw('P', s, false);
    }

    void PumpBlobs()
    {
        string[] files;
        try { files = Directory.GetFiles(dir, "mirror_*_" + role + ".txt"); } catch { return; }
        foreach (var path in files)
        {
            string file = Path.GetFileName(path);
            if (file.StartsWith("mirror_link_")) continue;
            DateTime w;
            try { w = File.GetLastWriteTimeUtc(path); } catch { continue; }
            if (w < startedUtc) continue;
            DateTime prev;
            if (seenWrite.TryGetValue(file, out prev) && prev == w && sent.ContainsKey(file)) continue;
            string s = ReadShared(path);
            if (s != null) s = s.Replace("\r\n", "\n");
            if (s == null || !s.EndsWith("\nEND\n")) continue;
            seenWrite[file] = w;
            string last;
            if (sent.TryGetValue(file, out last) && last == s) continue;
            string name = file.Substring("mirror_".Length, file.Length - "mirror_".Length - ("_" + role + ".txt").Length);
            if (SendBlob(name, s)) sent[file] = s;
        }
    }

    bool SendBlob(string name, string body)
    {
        bool ok;
        if (body.Length <= CHUNK) ok = SendRaw('B', epoch + "\n" + name + "\n" + body, true);
        else
        {
            int id = ++msgId, count = (body.Length + CHUNK - 1) / CHUNK;
            ok = true;
            for (int i = 0; i < count && ok; i++)
            {
                string part = body.Substring(i * CHUNK, Math.Min(CHUNK, body.Length - i * CHUNK));
                ok = SendRaw('K', epoch + " " + id + " " + i + " " + count + "\n" + name + "\n" + part, true);
            }
        }
        if (ok)
        {
            txBlobs++;
            if (loggedTx.Add(name)) Log("sent " + name + " (" + body.Length + " chars)" + (body.Length > CHUNK ? " in pieces" : ""));
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

    bool WithinLimits(byte[] data)
    {
        long t = Now();
        if (tokensAt == 0) tokensAt = t;
        double dt = (t - tokensAt) / 1000.0; tokensAt = t;
        pktTokens = Math.Min(PKT_BURST, pktTokens + dt * PKT_RATE);
        byteTokens = Math.Min(BYTE_BURST, byteTokens + dt * BYTE_RATE);
        if (pktTokens < 1 || byteTokens < data.Length) { Dropped("rate"); return false; }
        pktTokens -= 1; byteTokens -= data.Length;
        char type = data.Length > 0 ? (char)data[0] : '?';
        int max = type == 'P' ? MAX_POSE : type == 'H' ? MAX_HELLO : (type == 'B' || type == 'K') ? MAX_PART
                : (type == 'C' || type == 'A' || type == 'R') ? 256 : type == 'V' ? 8192 : 0;
        if (data.Length > max) { Dropped("size " + type + " " + data.Length + " B"); return false; }
        return true;
    }

    void Dropped(string why)
    {
        long t = Now();
        string kind = why.Split(' ')[0];
        long last;
        if (!dropLogged.TryGetValue(kind, out last) || t - last > KICK_WINDOW) { dropLogged[kind] = t; Log("dropped a packet from " + peerName + " (" + why + ")"); }
        drops.Enqueue(t);
        while (drops.Count > 0 && t - drops.Peek() > KICK_WINDOW) drops.Dequeue();
        if (drops.Count >= KICK_DROPS && peer != 0) Kick("too much data");
    }

    void Kick(string why)
    {
        ulong id = peer;
        Log("disconnected " + peerName + " (" + id + "): " + why + " - blocked until you host again");
        blocked.Add(id); approved.Remove(id);
        kickedLine = "kicked " + id + " " + Clean(peerName); kickedAt = Now();
        try { net.Close(id); } catch { }
        ClearPeerFiles();
        peer = 0; peerEpoch = null; drops.Clear();
        chunkKey = null; chunkParts = null;
        try { File.Delete(PeerNameFile()); } catch { }
        WriteLobby();
    }

    void Receive(int channel)
    {
        for (int k = 0; k < 500; k++)
        {
            ulong from;
            byte[] data = net.Read(channel, out from);
            if (data == null) break;
            if (role == "host" && from != peer && data.Length > 1 && data[0] == (byte)'A' && data.Length < 200)
            {
                CheckAnswer(from, Encoding.UTF8.GetString(data, 1, data.Length - 1));
                continue;
            }
            if (peer == 0 && role == "host") TakeOrRequest(from, "it sent us data");
            if (from != peer) continue;
            rxPkts++; rxBytes += data.Length;
            if (!WithinLimits(data)) continue;
            lastRx = Now(); lastHeard = lastRx;
            if (data[0] == (byte)'V') { voice.Play(data, 1); continue; }
            string msg = Encoding.UTF8.GetString(data);
            if (msg.Length == 0) continue;
            try { Handle(msg[0], msg.Substring(1)); } catch (Exception e) { Log("handle " + msg[0] + ": " + e.Message); }
        }
    }

    void BlobEpoch(string ep)
    {
        if (ep == blobEpoch) return;
        if (blobEpoch != null) Log("the other game restarted - cleared its old data");
        blobEpoch = ep;
        try
        {
            foreach (var f in Directory.GetFiles(dir, "mirror_*_" + other + ".txt"))
                if (!Path.GetFileName(f).StartsWith("mirror_link_")) try { File.Delete(f); } catch { }
        }
        catch { }
    }

    void WriteBlob(string name, string body)
    {
        if (name.Length == 0 || name.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0) return;
        WriteAtomic(Path.Combine(dir, "mirror_" + name + "_" + other + ".txt"), body);
        rxBlobs++;
        if (loggedRx.Add(name)) Log("got " + name + " (" + body.Length + " chars)");
    }

    void Handle(char type, string body)
    {
        if (type == 'P')
        {
            int a = body.IndexOf(' '), b2 = a < 0 ? -1 : body.IndexOf(' ', a + 1);
            if (b2 < 0) return;
            string line = body.Substring(0, a) + " " + Unix() + body.Substring(b2);
            WriteAtomic(Path.Combine(dir, "mirror_link_" + other + ".txt"), line + "\n");
        }
        else if (type == 'B')
        {
            int n1 = body.IndexOf('\n');
            int n2 = n1 < 0 ? -1 : body.IndexOf('\n', n1 + 1);
            if (n2 < 0) return;
            BlobEpoch(body.Substring(0, n1));
            WriteBlob(body.Substring(n1 + 1, n2 - n1 - 1), body.Substring(n2 + 1));
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
            if (count > MAX_PARTS) { Dropped("size K " + count + " parts"); return; }
            BlobEpoch(h[0]);
            string key = h[0] + " " + h[1];
            if (key != chunkKey || idx == 0) { chunkKey = key; chunkName = name; chunkParts = new string[count]; chunkGot = 0; }
            if (chunkParts[idx] == null) { chunkParts[idx] = body.Substring(n2 + 1); chunkGot++; }
            if (chunkGot == count)
            {
                WriteBlob(chunkName, string.Concat(chunkParts));
                chunkKey = null; chunkParts = null;
            }
        }
        else if (type == 'C' && role == "guest")
        {
            if (answered) return;
            answered = true;
            SendRaw('A', joinKey == null ? "none" : Answer(joinKey, body.Trim(), me), true);
            Log("answered the host's password check" + (joinKey == null ? " (no password typed)" : ""));
        }
        else if (type == 'R' && role == "guest")
        {
            joinError = body.Trim();
            Log("the host refused: " + joinError);
            WriteLobby();
        }
        else if (type == 'H')
        {
            var f = body.Split(' ');
            long remote;
            if (f.Length >= 2 && long.TryParse(f[1], out remote))
                WriteAtomic(Path.Combine(dir, "mirror_clock_offset.txt"), (Unix() - remote).ToString());
            if (f.Length >= 4) peerGame = f[3] == "1" ? "alive" : "gone";
            if (f.Length >= 1 && f[0] != peerEpoch)
            {
                peerEpoch = f[0];
                Log("connected to " + peerName + " (their session " + peerEpoch + ")");
                sent.Clear(); lastPose = null;
            }
        }
    }

    void WriteStatus()
    {
        double hb = peer == 0 || lastHeard == 0 ? -1 : (Now() - lastHeard) / 1000.0;
        string s = string.Format("bridge {0}: me {1}, peer {2} ({3}), last rx {4:0.0} s, pkts tx {5} rx {6}, KB tx {7:0} rx {8:0}, blobs tx {9} rx {10} peer_hb {4:0.0} peer_game {12} at {11}",
            role, me, peer == 0 ? "searching" : peerName, peer, hb,
            txPkts, rxPkts, txBytes / 1024.0, rxBytes / 1024.0, txBlobs, rxBlobs, Unix(), peer == 0 ? "?" : peerGame);
        try { WriteAtomic(Path.Combine(dir, "mirror_bridge_status_" + role + ".txt"), s); } catch { }
    }
}
