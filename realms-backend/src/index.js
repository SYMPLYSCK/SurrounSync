// SurrounSync Realms backend (Cloudflare Worker + D1 + R2).
//
// A Realm is a shared world that lives here between sessions. Whoever starts it claims the host lease
// (one winner, ever), downloads the newest world, hosts it in their own game and uploads every save.
// Everyone else asks who holds the lease and joins that player over Steam P2P as usual.
//
// Auth: every member has a random key (only its sha256 is stored). Requests send
//   Authorization: Member <member_id>:<key>
// Uploading a world also needs the lease token, so only the current host can change the world, and only
// on top of the generation it holds.

const LEASE_SECONDS = 120;            // the host heartbeats every ~60 s
let leaseSeconds = LEASE_SECONDS;     // LEASE_SECONDS env var overrides it (tests only)
const INVITE_SECONDS = 7 * 24 * 3600;
const KEEP_GENERATIONS = 10;
const MAX_WORLD = 16 * 1024 * 1024;
const MAX_JSON = 4 * 1024;
const MAX_MEMBERS = 16;
const MAX_OPEN_INVITES = 20;
const LIMITS = {                      // per IP: [requests, window seconds]
    create: [5, 24 * 3600],
    redeem: [20, 3600],
    // every member call (list, heartbeat, uploads): only an abuse guard. 600 was hit in one evening by two games
    // on one connection (each list = one call per known Realm) - the host's heartbeat got refused, its lease lapsed
    auth: [10000, 3600],
    admin: [30, 3600],                // wrong admin tokens (the MOTD and the delist)
    browse: [600, 3600],              // the public server list (the REALMS page asks about once a minute while open)
    join: [20, 3600],                 // joining a public Realm (a wrong password counts too)
    publish: [20, 3600],              // putting a Realm on the server list, changing its password, taking it off
    report: [6, 24 * 3600],           // bug reports stored for the mod's makers
};
// Full bug reports (crash and hang dumps the Discord post can't carry): kept REPORT_DAYS, at most REPORT_MB_PER_DAY
// stored a day from everyone together, so junk uploads can't run the bucket up
const MAX_REPORT = 90 * 1024 * 1024;  // (a Workers request body takes 100 MB)
const REPORT_DAYS = 30;
const REPORT_MB_PER_DAY = 1024;
const REPORT_LEVELS = /^(CRITICAL|ERROR|MINOR|INFO)$/;
const REPORT_NAME = /^\d{10}-(CRITICAL|ERROR|MINOR|INFO)-[0-9A-Z]{8}\.zip$/;
const MAX_MOTD = 500;
// Public Realms: anyone may join one from the server list (with its password when it is locked). Those members
// can only play with whoever hosts it: no hosting, invites or world downloads. They have their own cap, so they
// never fill the invited places, and are pruned when unseen for a while.
const MAX_PUBLIC_MEMBERS = 48;
const PUBLIC_UNSEEN_SECONDS = 30 * 24 * 3600;
// a list member who never came back after joining (no claim: a real player opens the Realm right after joining)
// is pruned after a day, so made-up joins can't keep a Realm's public places full
const PUBLIC_NEVER_SEEN_SECONDS = 24 * 3600;
const MAX_LISTED = 100;
// List spam: one address lists at most this many Realms, and a listed Realm nobody hosted for this long drops off
// the list by itself (it stays public; hosting it again brings it back). An admin can take one off for good.
const MAX_LISTED_PER_IP = 3;
const MAX_LISTED_PER_NET = 6;   // ...and one IPv6 /48 this many (it holds 65536 /64 "addresses")
const LIST_STALE_SECONDS = 14 * 24 * 3600;
let listStale = LIST_STALE_SECONDS;   // LIST_STALE_SECONDS and PUBLIC_NEVER_SEEN_SECONDS env vars override (tests only)
// (WebCrypto on the dev PC, 2026-11-01: 20000 rounds 2.2 ms, 100000 10.9 ms - over the Workers free plan's 10 ms of
// CPU; not measured on Workers itself. Guessing is capped per Realm and per IP below, so the rounds only matter if
// the database leaks. Over the per-address cap a guess is refused before any hashing.)
const PBKDF2_ROUNDS = 20000;
const MIN_PASSWORD = 6;
// Wrong passwords per Realm per hour: one address gets a few, all addresses together more. One address can't lock
// the right password out for everyone; many addresses still can for the hour (members who joined keep playing).
const MAX_WRONG_PER_IP = 10;
const MAX_WRONG_PASSWORDS = 200;
const MAX_PLAYERS = 16;               // the most players a host can report (the game takes 4)

const B32 = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"; // Crockford: no I, L, O, U
const enc = new TextEncoder();

class ApiError extends Error {
    constructor(status, code, message) { super(message || code); this.status = status; this.code = code; }
}
const fail = (status, code, message) => { throw new ApiError(status, code, message); };

const now = () => Math.floor(Date.now() / 1000);

function json(data, status = 200, headers = {}) {
    return new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json", ...headers } });
}

function randomB32(n) {
    const bytes = crypto.getRandomValues(new Uint8Array(n));
    let s = "";
    for (const b of bytes) s += B32[b & 31];
    return s;
}

function randomKey(nbytes) {
    const bytes = crypto.getRandomValues(new Uint8Array(nbytes));
    return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function sha256hex(data) {
    const buf = typeof data === "string" ? enc.encode(data) : data;
    const d = new Uint8Array(await crypto.subtle.digest("SHA-256", buf));
    return [...d].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function sameHash(a, b) {
    if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
    const x = enc.encode(a), y = enc.encode(b);
    if (crypto.subtle.timingSafeEqual) return crypto.subtle.timingSafeEqual(x, y);
    let diff = 0;
    for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
    return diff === 0;
}

// ---- input checks (reject, never repair) ----

function text(v, field, max, shown) {
    if (typeof v !== "string") fail(400, "bad_input", field + " must be text");
    const s = v.trim();
    if (s.length < 1 || s.length > max) fail(400, "bad_input", `${field} must be 1-${max} characters`);
    if (/[\u0000-\u001f\u007f]/.test(s)) fail(400, "bad_input", field + " has control characters");
    // shown = a Realm name on the list: direction overrides and invisible characters would let it pass for
    // another Realm's. Not for player names: those are Steam persona names sent as they are, and emoji (ZWJ)
    // and some scripts (ZWNJ) need joiners, so ZWJ/ZWNJ are allowed in Realm names too.
    if (shown && /[\u00ad\u034f\u061c\u115f\u1160\u180e\u200b\u200e\u200f\u202a-\u202e\u2060-\u2064\u2066-\u2069\u3164\ufeff\uffa0]/.test(s))
        fail(400, "bad_input", field + " has invisible or direction characters");
    return s;
}
function steamId(v) {
    if (typeof v !== "string" || !/^\d{17}$/.test(v)) fail(400, "bad_input", "steam_id must be a 17-digit SteamID64");
    return v;
}
function int(v, field, min, max) {
    if (!Number.isInteger(v) || v < min || v > max) fail(400, "bad_input", `${field} must be a whole number ${min}-${max}`);
    return v;
}
// Realm ids travel as codes (R-XXXXX-XXXXX, any case, dashes optional) or bare ids. The code's R goes only
// when 11 characters are left: a bare id can itself start with R (RWE288BGVE lost its R and was refused).
function realmId(v) {
    let s = String(v || "").toUpperCase().replace(/-/g, "");
    if (s.length === 11 && s[0] === "R") s = s.slice(1);
    if (!/^[0-9A-HJKMNP-TV-Z]{10}$/.test(s)) fail(400, "bad_input", "not a Realm code");
    return s;
}
const realmCode = (id) => `R-${id.slice(0, 5)}-${id.slice(5)}`;
function inviteCode(v) {
    const s = String(v || "").toUpperCase().replace(/[\s-]/g, "");
    if (!/^[0-9A-HJKMNP-TV-Z]{16}$/.test(s)) fail(400, "bad_input", "not an invite code");
    return s;
}
const showInvite = (c) => c.match(/.{4}/g).join("-");
// a Steam ping location string (ISteamNetworkingUtils::ConvertPingLocationToString, at most 1024): printable ASCII
function pingLoc(v) {
    if (typeof v !== "string" || v.length > 1024 || !/^[\x20-\x7e]*$/.test(v)) fail(400, "bad_input", "bad ping location");
    return v === "" ? null : v;
}

async function passHash(password, saltHex) {
    const salt = new Uint8Array(saltHex.match(/../g).map((x) => parseInt(x, 16)));
    const key = await crypto.subtle.importKey("raw", enc.encode(password), "PBKDF2", false, ["deriveBits"]);
    const bits = new Uint8Array(await crypto.subtle.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt, iterations: PBKDF2_ROUNDS }, key, 256));
    return [...bits].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function body(request) {
    const len = Number(request.headers.get("content-length") || "0");
    if (len > MAX_JSON) fail(413, "too_large");
    // (read up to the cap only: a body sent without a length was read whole first)
    const raw = request.body ? new TextDecoder().decode(await blob(request, MAX_JSON, true)) : "";
    if (!raw) return {};
    try {
        const v = JSON.parse(raw);
        if (v === null || typeof v !== "object" || Array.isArray(v)) throw new Error();
        return v;
    } catch { fail(400, "bad_json"); }
}

// Reads a binary upload up to max bytes; stops reading as soon as it is over. (canEmpty: a JSON body may be empty)
async function blob(request, max, canEmpty = false) {
    const len = Number(request.headers.get("content-length") || "0");
    if (len > max) fail(413, "too_large");
    if (!request.body) { if (canEmpty) return new Uint8Array(0); fail(400, "empty"); }
    const reader = request.body.getReader();
    const parts = [];
    let n = 0;
    for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        n += value.byteLength;
        if (n > max) { await reader.cancel(); fail(413, "too_large"); }
        parts.push(value);
    }
    if (n === 0 && !canEmpty) fail(400, "empty");
    const out = new Uint8Array(n);
    let at = 0;
    for (const p of parts) { out.set(p, at); at += p.byteLength; }
    return out;
}

function claimedHash(request) {
    const h = (request.headers.get("x-sha256") || "").toLowerCase();
    if (!/^[0-9a-f]{64}$/.test(h)) fail(400, "bad_input", "X-Sha256 header missing");
    return h;
}

// ---- rate limits and auth ----

// An IPv6 address counts by its /64: one home connection gets a whole /64, so per address it never ran out
function ipKey(ip) {
    const v4 = /(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/.exec(ip);   // (also an IPv4-mapped ::ffff:a.b.c.d)
    if (v4 || !ip.includes(":")) return v4 ? v4[1] : ip;
    const [head, tail = ""] = ip.toLowerCase().split("::");
    const a = head ? head.split(":") : [], b = tail ? tail.split(":") : [];
    const all = ip.includes("::") ? [...a, ...Array(Math.max(0, 8 - a.length - b.length)).fill("0"), ...b] : a;
    return all.slice(0, 4).map((x) => x.replace(/^0+(?=.)/, "")).join(":") + "::/64";
}

async function bump(env, bucket, window) {
    const t = now(), start = t - (t % window);
    const row = await env.DB.prepare(
        "INSERT INTO hits (bucket, n, reset_at) VALUES (?, 1, ?) ON CONFLICT(bucket) DO UPDATE SET n = n + 1 RETURNING n")
        .bind(`${bucket}:${start}`, start + window).first();
    return row ? row.n : 0;
}

const ipOf = (request) => ipKey(request.headers.get("cf-connecting-ip") || "local");

async function limit(env, request, action) {
    const [max, window] = LIMITS[action];
    if (await bump(env, `${action}:${ipOf(request)}`, window) > max) fail(429, "slow_down", "too many requests, try again later");
}

async function bumpBy(env, bucket, window, n) {
    const t = now(), start = t - (t % window);
    const row = await env.DB.prepare(
        "INSERT INTO hits (bucket, n, reset_at) VALUES (?1, ?3, ?2) ON CONFLICT(bucket) DO UPDATE SET n = n + ?3 RETURNING n")
        .bind(`${bucket}:${start}`, start + window, n).first();
    return row ? row.n : 0;
}

async function hitsNow(env, bucket, window) {
    const t = now();
    const row = await env.DB.prepare("SELECT n FROM hits WHERE bucket = ?").bind(`${bucket}:${t - (t % window)}`).first();
    return row ? row.n : 0;
}

async function member(env, request, rid) {
    await limit(env, request, "auth");
    const m = /^Member ([0-9A-Z]{8}):([A-Za-z0-9_-]{43})$/.exec(request.headers.get("authorization") || "");
    if (!m) fail(401, "no_key", "missing or malformed member key");
    const row = await env.DB.prepare("SELECT * FROM members WHERE realm_id = ? AND member_id = ?").bind(rid, m[1]).first();
    // same answer for "no such member" and "wrong key"
    if (!row || !sameHash(row.key_hash, await sha256hex(m[2]))) fail(403, "not_member", "not a member of this Realm");
    return row;
}

async function realm(env, rid) {
    const r = await env.DB.prepare("SELECT * FROM realms WHERE id = ?").bind(rid).first();
    if (!r) fail(404, "no_realm", "no such Realm");
    return r;
}

const leaseActive = (r, t) => r.lease_token != null && r.lease_expires > t;

function leaseToken(request) {
    const t = request.headers.get("x-lease-token") || "";
    if (!/^[A-Za-z0-9_-]{32}$/.test(t)) fail(400, "bad_input", "X-Lease-Token header missing");
    return t;
}

async function newMember(env, rid, steam, name, role, via = null) {
    for (let i = 0; i < 3; i++) {
        const mid = randomB32(8), key = randomKey(32), t = now();
        const r = await env.DB.prepare(
            "INSERT OR IGNORE INTO members (realm_id, member_id, key_hash, steam_id, name, role, created_at, via, last_seen) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)")
            .bind(rid, mid, await sha256hex(key), steam, name, role, t, via, null).run();
        if (r.meta.changes === 1) return { member_id: mid, key };
    }
    fail(500, "id_clash");
}

const worldKey = (rid, gen) => `realms/${rid}/world/${String(gen).padStart(10, "0")}`;

// ---- handlers ----

async function createRealm(env, request) {
    await limit(env, request, "create");
    const b = await body(request);
    const name = text(b.name, "name", 40, true), steam = steamId(b.steam_id), player = text(b.player_name, "player_name", 32);
    const format = int(b.format, "format", 1, 1000), protocol = int(b.protocol, "protocol", 1, 100000);
    const modVersion = text(b.mod_version, "mod_version", 32), build = text(b.game_build, "game_build", 32);
    for (let i = 0; i < 3; i++) {
        const rid = randomB32(10);
        const r = await env.DB.prepare(
            "INSERT OR IGNORE INTO realms (id, name, created_at, format, mod_version, protocol, game_build) VALUES (?, ?, ?, ?, ?, ?, ?)")
            .bind(rid, name, now(), format, modVersion, protocol, build).run();
        if (r.meta.changes !== 1) continue;
        const m = await newMember(env, rid, steam, player, "owner");
        return json({ realm_id: rid, code: realmCode(rid), name, ...m }, 201);
    }
    fail(500, "id_clash");
}

const isPublic = (me) => me.via === "public";
function invitedOnly(me) { if (isPublic(me)) fail(403, "invited_only", "only invited members can do that"); }

async function status(env, r, me) {
    const t = now();
    // a member from the server list sees only itself in the list: the others' Steam ids are the invited group's
    const { results } = isPublic(me)
        ? await env.DB.prepare("SELECT member_id, name, steam_id, role, last_seen, via FROM members WHERE realm_id = ? AND member_id = ?")
            .bind(r.id, me.member_id).all()
        : await env.DB.prepare("SELECT member_id, name, steam_id, role, last_seen, via FROM members WHERE realm_id = ? ORDER BY created_at")
            .bind(r.id).all();
    return json({
        realm_id: r.id, code: realmCode(r.id), name: r.name, format: r.format, mod_version: r.mod_version,
        protocol: r.protocol, game_build: r.game_build,
        head: r.head_gen > 0 ? { gen: r.head_gen, sha256: r.head_hash, size: r.head_size, member_id: r.head_member, at: r.head_at } : null,
        host: leaseActive(r, t) ? { member_id: r.lease_member, steam_id: r.lease_steam, name: r.lease_name, expires_in: r.lease_expires - t } : null,
        members: results,
        you: { member_id: me.member_id, role: me.role, via: me.via ?? null },
        rules: r.rules ?? null,
        public: r.public === 1, locked: r.pass_hash != null,
    });
}

// The owner lists the Realm on the public server list or takes it off. password: "" or absent = open, text = locked;
// only its PBKDF2 hash is kept. Taking it off, or a new password, removes the members who joined from the list.
async function setPublic(env, request, r, me) {
    if (me.role !== "owner") fail(403, "owner_only");
    await limit(env, request, "publish");
    const b = await body(request);
    if (typeof b.public !== "boolean") fail(400, "bad_input", "public must be true or false");
    if (b.public && r.list_banned === 1) fail(403, "delisted", "this Realm was taken off the server list and can't go back on it");
    const ip = ipOf(request);
    if (b.public) {
        // (a name kept from before the invisible-character check must pass it before it is shown on the list;
        // audit 2026-11-03)
        try { text(r.name, "name", 40, true); }
        catch (e) {
            if (!(e instanceof ApiError)) throw e;
            fail(400, "bad_name", "rename this Realm before listing it: its name has invisible or direction characters");
        }
        // one IPv6 /48 (a site: 65536 /64s, each its own "connection" above) lists at most MAX_LISTED_PER_NET
        if (ip.endsWith("::/64")) {
            const net = ip.split(":").slice(0, 3).join(":") + ":";
            const k = await env.DB.prepare(
                "SELECT COUNT(*) AS n FROM realms WHERE public = 1 AND substr(listed_ip, 1, ?1) = ?2 AND id != ?3")
                .bind(net.length, net, r.id).first();
            if (k.n >= MAX_LISTED_PER_NET) fail(429, "too_many_listed", `one network can list at most ${MAX_LISTED_PER_NET} Realms`);
        }
        const n = await env.DB.prepare("SELECT COUNT(*) AS n FROM realms WHERE public = 1 AND listed_ip = ? AND id != ?").bind(ip, r.id).first();
        if (n.n >= MAX_LISTED_PER_IP) fail(429, "too_many_listed", `one connection can list at most ${MAX_LISTED_PER_IP} Realms`);
    }
    let salt = null, hash = null;
    if (b.public && b.password !== undefined && b.password !== null && b.password !== "") {
        const pw = text(b.password, "password", 64);
        if (pw.length < MIN_PASSWORD) fail(400, "bad_input", `a password needs at least ${MIN_PASSWORD} characters`);
        salt = [...crypto.getRandomValues(new Uint8Array(16))].map((x) => x.toString(16).padStart(2, "0")).join("");
        hash = await passHash(pw, salt);
    }
    // Taking it off the list or setting a new password removes everyone who joined from the list: the host's game
    // lets members in without asking, so they would otherwise keep walking in (security review 2026-11-01)
    const closing = !b.public || hash != null;
    const res = await env.DB.batch([
        // listed_at only moves when it goes on the list (changing the password doesn't reset the stale clock)
        env.DB.prepare(`UPDATE realms SET public = ?1, pass_salt = ?2, pass_hash = ?3,
                listed_ip = CASE WHEN ?1 THEN ?4 ELSE NULL END,
                listed_at = CASE WHEN ?1 AND public = 1 THEN listed_at WHEN ?1 THEN ?5 ELSE NULL END
             WHERE id = ?6`).bind(b.public ? 1 : 0, salt, hash, ip, now(), r.id),
        env.DB.prepare("DELETE FROM members WHERE realm_id = ? AND via = 'public' AND ?").bind(r.id, closing ? 1 : 0),
    ]);
    return json({ public: b.public, locked: hash != null, removed: res[1].meta.changes });
}

// The public server list. No auth; it shows no Steam ids or member names. Players and the ping location only
// while someone hosts (the host's heartbeat sends them).
async function listPublic(env, request) {
    await limit(env, request, "browse");
    const t = now();
    const { results } = await env.DB.prepare(
        `SELECT id, name, mod_version, protocol, pass_hash IS NOT NULL AS locked, players, max_players, ping_loc,
                (lease_token IS NOT NULL AND lease_expires > ?1) AS live
         FROM realms WHERE public = 1 AND list_banned = 0
             AND ((lease_token IS NOT NULL AND lease_expires > ?1) OR MAX(COALESCE(hosted_at, 0), COALESCE(listed_at, 0)) > ?3)
         ORDER BY live DESC, MAX(COALESCE(hosted_at, 0), COALESCE(listed_at, 0)) DESC, name LIMIT ?2`)
        .bind(t, MAX_LISTED, t - listStale).all();
    // (live first, then the most recently hosted or listed: by name alone, "AAA..." Realms nobody plays took the
    // MAX_LISTED places from real ones; audit 2026-11-03)
    return json({ realms: results.map((x) => ({
        realm_id: x.id, code: realmCode(x.id), name: x.name, mod_version: x.mod_version, protocol: x.protocol,
        locked: x.locked === 1, live: x.live === 1,
        players: x.live === 1 ? (x.players ?? 0) : 0, max_players: x.live === 1 ? (x.max_players ?? 0) : 0,
        ping_loc: x.live === 1 ? (x.ping_loc ?? null) : null,
    })) });
}

// Joining a public Realm from the list. A private (or missing) Realm gets the same answer, so the list is the only
// way to find one.
async function joinPublic(env, request, rid) {
    await limit(env, request, "join");
    const b = await body(request);
    const steam = steamId(b.steam_id), name = text(b.player_name, "player_name", 32);
    const r = await env.DB.prepare("SELECT * FROM realms WHERE id = ?").bind(rid).first();
    if (!r || r.public !== 1) fail(404, "no_realm", "no such public Realm");
    if (r.list_banned === 1) fail(404, "no_realm", "no such public Realm");
    if (r.pass_hash != null) {
        // wrong guesses are capped per address and, so many addresses can't share the guessing, per Realm
        const wrong = `badpw:${rid}`, mine = `badpw:${rid}:${ipOf(request)}`;
        if (await hitsNow(env, mine, 3600) >= MAX_WRONG_PER_IP || await hitsNow(env, wrong, 3600) >= MAX_WRONG_PASSWORDS)
            fail(429, "slow_down", "too many wrong passwords for this Realm, try again later");
        const pw = typeof b.password === "string" ? b.password.trim() : "";
        if (!pw || pw.length > 64 || !sameHash(await passHash(pw, r.pass_salt), r.pass_hash)) {
            await bump(env, mine, 3600);
            await bump(env, wrong, 3600);
            fail(403, "bad_password", "wrong password");
        }
    }
    // The Steam id is the client's word (no Steam ticket check yet), so a list join must never block the real
    // player: an id already in from the list is replaced (newest key wins; the host's game lets that Steam id in
    // either way). A made-up id can't get anyone into a game: the host's game sees the joiner's real id from Steam.
    // An invited member's id gets a list membership like any other: answering "already a member" told anyone who
    // asked which Steam ids are in the Realm (audit 2026-11-03). The member's own game never asks: the bridge's
    // JoinPublic uses the key it has (and the invited membership stays when the list one goes).
    const counts = await env.DB.prepare(
        "SELECT COUNT(*) AS n FROM members WHERE realm_id = ?1 AND via = 'public' AND steam_id != ?2").bind(rid, steam).first();
    if (counts.n >= MAX_PUBLIC_MEMBERS) fail(409, "full", "this Realm has no free public places");
    await env.DB.prepare("DELETE FROM members WHERE realm_id = ? AND via = 'public' AND steam_id = ?").bind(rid, steam).run();
    const m = await newMember(env, rid, steam, name, "member", "public");
    const after = await env.DB.prepare("SELECT COUNT(*) AS n FROM members WHERE realm_id = ? AND via = 'public'").bind(rid).first();
    if (after.n > MAX_PUBLIC_MEMBERS) {
        await env.DB.prepare("DELETE FROM members WHERE realm_id = ? AND member_id = ?").bind(rid, m.member_id).run();
        fail(409, "full", "this Realm has no free public places");
    }
    return json({ realm_id: rid, code: realmCode(rid), name: r.name, ...m }, 201);
}

// The game rules every host of the Realm plays by ("pvp off players 4 ..."): only the owner sets them. The keys and
// values are the mod's; the server only checks the shape.
const RULES = /^[a-z]{1,16} [a-z0-9]{1,8}( [a-z]{1,16} [a-z0-9]{1,8}){0,31}$/;
async function setRules(env, request, r, me) {
    if (me.role !== "owner") fail(403, "owner_only");
    const b = await body(request);
    if (typeof b.rules !== "string" || b.rules.length > 512 || !RULES.test(b.rules)) fail(400, "bad_input", "bad rules");
    await env.DB.prepare("UPDATE realms SET rules = ? WHERE id = ?").bind(b.rules, r.id).run();
    return json({ rules: b.rules });
}

async function rename(env, request, r, me) {
    if (me.role !== "owner") fail(403, "owner_only");
    const b = await body(request);
    const name = text(b.name, "name", 40, true);
    await env.DB.prepare("UPDATE realms SET name = ? WHERE id = ?").bind(name, r.id).run();
    return json({ name });
}

async function deleteRealm(env, r, me) {
    if (me.role !== "owner") fail(403, "owner_only");
    let cursor;
    do {
        const page = await env.WORLDS.list({ prefix: `realms/${r.id}/`, cursor });
        if (page.objects.length) await env.WORLDS.delete(page.objects.map((o) => o.key));
        cursor = page.truncated ? page.cursor : undefined;
    } while (cursor);
    await env.DB.batch([
        env.DB.prepare("DELETE FROM generations WHERE realm_id = ?").bind(r.id),
        env.DB.prepare("DELETE FROM invites WHERE realm_id = ?").bind(r.id),
        env.DB.prepare("DELETE FROM members WHERE realm_id = ?").bind(r.id),
        env.DB.prepare("DELETE FROM realms WHERE id = ?").bind(r.id),
    ]);
    return json({ deleted: true });
}

// One winner: the update only matches while nobody else holds a live lease. The same member may re-claim
// (their game restarted); that issues a new token, so a stale copy of their old game can't upload.
async function claim(env, request, r, me) {
    const b = await body(request);
    const steam = steamId(b.steam_id), name = text(b.name, "name", 32);
    const t = now(), token = randomKey(24);
    const hostAnswer = (cur) => json({ won: false, host: { member_id: cur.lease_member, steam_id: cur.lease_steam, name: cur.lease_name,
        expires_in: cur.lease_expires - t } }, 409);
    // a member from the server list joins whoever hosts it, never hosts it
    if (isPublic(me)) {
        // (off the list: no more host address for them, even if a removal missed one)
        if (r.public !== 1) fail(403, "invited_only", "this Realm isn't public any more");
        // seen only when it led to a game: a claim while nobody hosts kept made-up joins past their one-day prune,
        // one call each, and so the Realm's public places full (audit 2026-11-02)
        if (leaseActive(r, t)) {
            await env.DB.prepare("UPDATE members SET last_seen = ?, steam_id = ?, name = ? WHERE realm_id = ? AND member_id = ?")
                .bind(t, steam, name, r.id, me.member_id).run();
            return hostAnswer(r);
        }
        fail(403, "invited_only", "nobody is hosting this Realm right now");
    }
    const res = await env.DB.prepare(
        `UPDATE realms SET lease_member = ?, lease_steam = ?, lease_name = ?, lease_token = ?, lease_expires = ?,
                players = NULL, max_players = NULL, ping_loc = NULL, hosted_at = ?
         WHERE id = ? AND (lease_token IS NULL OR lease_expires <= ? OR lease_member = ?)`)
        .bind(me.member_id, steam, name, token, t + leaseSeconds, t, r.id, t, me.member_id).run();
    if (res.meta.changes !== 1) return hostAnswer(await realm(env, r.id));
    await env.DB.prepare("UPDATE members SET last_seen = ?, steam_id = ?, name = ? WHERE realm_id = ? AND member_id = ?")
        .bind(t, steam, name, r.id, me.member_id).run();
    return json({ won: true, lease_token: token, expires_in: leaseSeconds, head_gen: r.head_gen, head_sha256: r.head_hash });
}

// Works on an expired lease too as long as nobody else claimed it since (the token would have changed).
async function heartbeat(env, request, r, me) {
    const token = leaseToken(request);
    // optional: { players, max_players, ping_loc } for the public server list (an empty body keeps the old values)
    const b = await body(request);
    const has = (k) => b[k] !== undefined && b[k] !== null;
    const players = has("players") ? int(b.players, "players", 0, MAX_PLAYERS) : null;
    const maxPlayers = has("max_players") ? int(b.max_players, "max_players", 1, MAX_PLAYERS) : null;
    const loc = has("ping_loc") ? pingLoc(b.ping_loc) : null;
    const res = await env.DB.prepare(
        `UPDATE realms SET lease_expires = ?, players = COALESCE(?, players), max_players = COALESCE(?, max_players),
                ping_loc = CASE WHEN ? THEN ? ELSE ping_loc END, hosted_at = ?
         WHERE id = ? AND lease_token = ? AND lease_member = ?`)
        .bind(now() + leaseSeconds, players, maxPlayers, has("ping_loc") ? 1 : 0, loc, now(), r.id, token, me.member_id).run();
    if (res.meta.changes !== 1) fail(409, "lease_lost", "someone else is hosting this Realm now");
    // (the host picks up the owner's rule changes here, within a minute)
    return json({ expires_in: leaseSeconds, rules: r.rules ?? null });
}

async function release(env, request, r, me) {
    const token = leaseToken(request);
    const res = await env.DB.prepare(
        `UPDATE realms SET lease_member = NULL, lease_steam = NULL, lease_name = NULL, lease_token = NULL, lease_expires = NULL,
                players = NULL, max_players = NULL, ping_loc = NULL
         WHERE id = ? AND lease_token = ? AND lease_member = ?`).bind(r.id, token, me.member_id).run();
    return json({ released: res.meta.changes === 1 });
}

async function uploadWorld(env, request, r, me, gen) {
    const token = leaseToken(request);
    if (r.lease_token == null || !sameHash(r.lease_token, token) || r.lease_member !== me.member_id) {
        fail(409, "lease_lost", "you are not hosting this Realm");
    }
    if (gen !== r.head_gen + 1) fail(409, "stale", `the newest world is generation ${r.head_gen}`);
    const want = claimedHash(request);
    const data = await blob(request, MAX_WORLD);
    const got = await sha256hex(data);
    if (got !== want) fail(400, "bad_hash", "upload damaged in transit");
    const key = worldKey(r.id, gen);
    await env.WORLDS.put(key, data, { customMetadata: { sha256: got, gen: String(gen), member: me.member_id } });
    // the head only moves if nothing changed since the checks above; otherwise the object goes again
    const t = now();
    const res = await env.DB.prepare(
        `UPDATE realms SET head_gen = ?, head_hash = ?, head_size = ?, head_member = ?, head_at = ?, lease_expires = ?
         WHERE id = ? AND head_gen = ? AND lease_token = ? AND lease_member = ?`)
        .bind(gen, got, data.byteLength, me.member_id, t, t + leaseSeconds, r.id, gen - 1, token, me.member_id).run();
    if (res.meta.changes !== 1) {
        // Two uploads of one generation (a timed-out retry) share the key: when the other one moved the head to
        // this gen, the object is the head's - deleting it left the head pointing at nothing (audit N18). Keep it
        // and make the head describe the bytes that are stored now (whichever put landed last).
        const cur = await realm(env, r.id);
        const obj = cur.head_gen === gen ? await env.WORLDS.head(key) : null;
        if (obj) {
            const h = obj.customMetadata.sha256;
            await env.DB.prepare("UPDATE realms SET head_hash = ?, head_size = ? WHERE id = ? AND head_gen = ?")
                .bind(h, obj.size, r.id, gen).run();
            await env.DB.prepare("UPDATE generations SET hash = ?, size = ? WHERE realm_id = ? AND gen = ?")
                .bind(h, obj.size, r.id, gen).run();
        } else {
            await env.WORLDS.delete(key);
        }
        fail(409, "stale", "the Realm changed during the upload");
    }
    await env.DB.prepare("INSERT OR REPLACE INTO generations (realm_id, gen, hash, size, member_id, created_at) VALUES (?, ?, ?, ?, ?, ?)")
        .bind(r.id, gen, got, data.byteLength, me.member_id, t).run();
    const old = gen - KEEP_GENERATIONS;
    if (old >= 1) {
        const { results } = await env.DB.prepare("SELECT gen FROM generations WHERE realm_id = ? AND gen <= ?").bind(r.id, old).all();
        if (results.length) {
            await env.WORLDS.delete(results.map((x) => worldKey(r.id, x.gen)));
            await env.DB.prepare("DELETE FROM generations WHERE realm_id = ? AND gen <= ?").bind(r.id, old).run();
        }
    }
    return json({ gen, sha256: got, size: data.byteLength }, 201);
}

async function downloadWorld(env, r, gen) {
    const g = gen ?? r.head_gen;
    if (g < 1) fail(404, "no_world", "nothing uploaded yet");
    const obj = await env.WORLDS.get(worldKey(r.id, g));
    if (!obj) fail(404, "no_world", `generation ${g} is not kept`);
    return new Response(obj.body, { headers: {
        "content-type": "application/octet-stream", "x-gen": String(g), "x-sha256": obj.customMetadata.sha256 } });
}

async function listGenerations(env, r) {
    const { results } = await env.DB.prepare(
        "SELECT gen, hash AS sha256, size, member_id, created_at FROM generations WHERE realm_id = ? ORDER BY gen DESC").bind(r.id).all();
    return json({ generations: results });
}

async function createInvite(env, r, me) {
    invitedOnly(me);
    const t = now();
    const counts = await env.DB.prepare(
        `SELECT (SELECT COUNT(*) FROM members WHERE realm_id = ?1 AND via IS NULL) AS members,
                (SELECT COUNT(*) FROM invites WHERE realm_id = ?1 AND used_at IS NULL AND expires_at > ?2) AS open`)
        .bind(r.id, t).first();
    if (counts.members >= MAX_MEMBERS) fail(409, "full", `a Realm has at most ${MAX_MEMBERS} members`);
    if (counts.open >= MAX_OPEN_INVITES) fail(409, "too_many_invites", "too many unused invites");
    const code = randomB32(16);
    await env.DB.prepare("INSERT INTO invites (code_hash, realm_id, created_by, created_at, expires_at) VALUES (?, ?, ?, ?, ?)")
        .bind(await sha256hex(code), r.id, me.member_id, t, t + INVITE_SECONDS).run();
    return json({ invite: showInvite(code), expires_in: INVITE_SECONDS }, 201);
}

async function redeem(env, request) {
    await limit(env, request, "redeem");
    const b = await body(request);
    const code = inviteCode(b.invite), steam = steamId(b.steam_id), name = text(b.player_name, "player_name", 32);
    const t = now(), h = await sha256hex(code);
    // a full Realm keeps the invite unused
    const full = await env.DB.prepare(
        `SELECT (SELECT COUNT(*) FROM members WHERE realm_id = i.realm_id AND via IS NULL) AS n,
                (SELECT COUNT(*) FROM members WHERE realm_id = i.realm_id AND via IS NULL AND steam_id = ?2) AS mine
         FROM invites i WHERE code_hash = ?1`).bind(h, steam).first();
    if (full && full.n >= MAX_MEMBERS) fail(409, "full", `a Realm has at most ${MAX_MEMBERS} members`);
    // a second invite for the same player made a second member row (audit N19)
    if (full && full.mine > 0) fail(409, "already_member", "you are already a member of this Realm");
    // used up in the same statement that checks it: two redeems of one code can't both win
    const inv = await env.DB.prepare(
        "UPDATE invites SET used_at = ? WHERE code_hash = ? AND used_at IS NULL AND expires_at > ? RETURNING realm_id").bind(t, h, t).first();
    if (!inv) fail(404, "bad_invite", "that invite is wrong, used or expired");
    const r = await realm(env, inv.realm_id);
    const m = await newMember(env, r.id, steam, name, "member");
    // the count above and the insert are separate statements: parallel redeems could pass the cap together -
    // the one over it is undone and its invite works again
    const after = await env.DB.prepare("SELECT COUNT(*) AS n FROM members WHERE realm_id = ? AND via IS NULL").bind(r.id).first();
    if (after.n > MAX_MEMBERS) {
        await env.DB.prepare("DELETE FROM members WHERE realm_id = ? AND member_id = ?").bind(r.id, m.member_id).run();
        await env.DB.prepare("UPDATE invites SET used_at = NULL WHERE code_hash = ?").bind(h).run();
        fail(409, "full", `a Realm has at most ${MAX_MEMBERS} members`);
    }
    // invited now: a list membership with this Steam id (theirs, or one made up in their name) goes, and a
    // list join can't block the invite (see joinPublic)
    await env.DB.prepare("DELETE FROM members WHERE realm_id = ? AND via = 'public' AND steam_id = ?").bind(r.id, steam).run();
    return json({ realm_id: r.id, code: realmCode(r.id), name: r.name, ...m }, 201);
}

async function removeMember(env, r, me, mid) {
    if (mid === me.member_id) {
        if (me.role === "owner") fail(409, "owner_must_transfer", "give the Realm to another member before leaving");
    } else if (me.role !== "owner") fail(403, "owner_only");
    const res = await env.DB.prepare("DELETE FROM members WHERE realm_id = ? AND member_id = ?").bind(r.id, mid).run();
    if (res.meta.changes !== 1) fail(404, "no_member");
    // a removed host loses the lease too
    await env.DB.prepare(
        `UPDATE realms SET lease_member = NULL, lease_steam = NULL, lease_name = NULL, lease_token = NULL, lease_expires = NULL
         WHERE id = ? AND lease_member = ?`).bind(r.id, mid).run();
    return json({ removed: mid });
}

async function transferOwner(env, r, me, mid) {
    if (me.role !== "owner") fail(403, "owner_only");
    if (mid === me.member_id) fail(400, "bad_input", "you already own it");
    const [to] = await env.DB.batch([
        // (not to a member from the server list: they can't host)
        env.DB.prepare("UPDATE members SET role = 'owner' WHERE realm_id = ? AND member_id = ? AND role = 'member' AND via IS NULL").bind(r.id, mid),
        env.DB.prepare(`UPDATE members SET role = 'member' WHERE realm_id = ? AND member_id = ?
                        AND EXISTS (SELECT 1 FROM members WHERE realm_id = ? AND member_id = ? AND role = 'owner')`)
            .bind(r.id, me.member_id, r.id, mid),
    ]);
    if (to.meta.changes !== 1) fail(404, "no_member");
    return json({ owner: mid });
}

async function rotateKey(env, r, me) {
    const key = randomKey(32);
    await env.DB.prepare("UPDATE members SET key_hash = ? WHERE realm_id = ? AND member_id = ?")
        .bind(await sha256hex(key), r.id, me.member_id).run();
    return json({ member_id: me.member_id, key });
}

// ---- message of the day: one message from the mod's makers to every player ----
// GET is public (every bridge asks every minute, Realms or not). PUT/DELETE need Authorization: Admin <token>,
// the token being the MOTD_TOKEN secret (npx wrangler secret put MOTD_TOKEN); without that secret they don't exist.

async function admin(env, request) {
    const want = env.MOTD_TOKEN;
    if (typeof want !== "string" || want.length < 32) fail(404, "not_found");
    // only wrong tokens count: the admin's own calls ran into the cap on the 31st delist of an hour (audit 2026-11-02)
    const [max, window] = LIMITS.admin, bucket = `admin:${ipOf(request)}`;
    if (await hitsNow(env, bucket, window) >= max) fail(429, "slow_down", "too many requests, try again later");
    const m = /^Admin (\S{1,256})$/.exec(request.headers.get("authorization") || "");
    if (!m || !sameHash(await sha256hex(m[1]), await sha256hex(want))) {
        await bump(env, bucket, window);
        fail(403, "not_admin", "not allowed");
    }
}

async function getMotd(env) {
    const r = await env.DB.prepare("SELECT msg_id, text, created_at, expires_at FROM motd WHERE id = 1").first();
    if (!r || (r.expires_at && r.expires_at <= now())) return json({ id: null });
    return json({ id: r.msg_id, text: r.text, created_at: r.created_at, expires_at: r.expires_at || 0 });
}

// { text, and optionally hours (1-2160) or minutes (1-129600): it goes by itself after that }; a new message
// replaces the old one
async function setMotd(env, request) {
    await admin(env, request);
    const b = await body(request);
    const t = text(b.text, "text", MAX_MOTD);
    const given = (v) => v !== undefined && v !== null;
    if (given(b.hours) && given(b.minutes)) fail(400, "bad_input", "give hours or minutes, not both");
    const life = given(b.minutes) ? int(b.minutes, "minutes", 1, 90 * 24 * 60) * 60
        : given(b.hours) ? int(b.hours, "hours", 1, 90 * 24) * 3600 : 0;
    const id = randomB32(8), at = now(), till = life ? at + life : null;
    await env.DB.prepare("INSERT OR REPLACE INTO motd (id, msg_id, text, created_at, expires_at) VALUES (1, ?, ?, ?, ?)")
        .bind(id, t, at, till).run();
    return json({ id, text: t, created_at: at, expires_at: till || 0 });
}

async function clearMotd(env, request) {
    await admin(env, request);
    await env.DB.prepare("DELETE FROM motd WHERE id = 1").run();
    return json({ id: null });
}

// Takes a Realm off the server list for good (spam, a rude name): { realm_id, undo? }. Its list members go; the
// owner and invited members keep it as a private Realm. undo: true lets the owner list it again.
async function delist(env, request) {
    await admin(env, request);
    const b = await body(request);
    const rid = realmId(b.realm_id);
    const undo = b.undo === true;
    const res = await env.DB.batch([
        env.DB.prepare(`UPDATE realms SET list_banned = ?1, public = CASE WHEN ?1 THEN 0 ELSE public END,
                listed_ip = CASE WHEN ?1 THEN NULL ELSE listed_ip END WHERE id = ?2`).bind(undo ? 0 : 1, rid),
        env.DB.prepare("DELETE FROM members WHERE realm_id = ? AND via = 'public' AND ?").bind(rid, undo ? 0 : 1),
    ]);
    if (res[0].meta.changes !== 1) fail(404, "no_realm", "no such Realm");
    return json({ realm_id: rid, delisted: !undo, removed: res[1].meta.changes });
}

// ---- full bug reports: anyone stores one (a zip, limited), only the admin lists, reads and deletes them ----

const reportKey = (name) => `reports/${name}`;

async function storeReport(env, request) {
    const level = (request.headers.get("x-report-level") || "").toUpperCase();
    if (!REPORT_LEVELS.test(level)) fail(400, "bad_input", "X-Report-Level missing");
    const len = Number(request.headers.get("content-length") || "0");
    if (!Number.isInteger(len) || len <= 0) fail(411, "length_required", "Content-Length missing");
    if (len < 22) fail(400, "bad_input", "not a zip");
    if (len > MAX_REPORT) fail(413, "too_large");
    if (!request.body) fail(400, "empty");
    await limit(env, request, "report");
    // the day's total is counted before the body is read: an upload that ends up refused still counts
    const mb = Math.ceil(len / (1024 * 1024));
    if (await bumpBy(env, "report_mb:all", 24 * 3600, mb) > (Number(env.REPORT_MB_PER_DAY) || REPORT_MB_PER_DAY))
        fail(429, "slow_down", "no room for more reports today");
    // streamed into R2 (a worker has 128 MB: a 90 MB report read whole didn't fit), the zip's first bytes checked on
    // the way; FixedLengthStream refuses a body longer or shorter than its Content-Length
    const name = `${now()}-${level}-${randomB32(8)}.zip`, key = reportKey(name);
    const MAGIC = [0x50, 0x4b, 0x03, 0x04];
    let seen = 0;
    const check = new TransformStream({
        transform(chunk, c) {
            for (let i = 0; seen + i < MAGIC.length && i < chunk.byteLength; i++)
                if (chunk[i] !== MAGIC[seen + i]) throw new ApiError(400, "bad_input", "not a zip");
            seen += chunk.byteLength;
            c.enqueue(chunk);
        },
    });
    const fixed = new FixedLengthStream(len);
    const [piped, put] = await Promise.allSettled([
        request.body.pipeThrough(check).pipeTo(fixed.writable),
        env.WORLDS.put(key, fixed.readable, { customMetadata: { level } }),
    ]);
    if (piped.status === "rejected" || put.status === "rejected") {
        try { await env.WORLDS.delete(key); } catch (_) { /* nothing was stored */ }
        // nothing kept: its share of the day's budget goes back (declared 90 MB of junk used it up: review R12)
        await bumpBy(env, "report_mb:all", 24 * 3600, -mb);
        const why = piped.status === "rejected" ? piped.reason : put.reason;
        if (why instanceof ApiError) throw why;
        fail(400, "bad_input", "the upload broke off");
    }
    return json({ name, size: len });
}

async function listReports(env, request) {
    await admin(env, request);
    const cursor = new URL(request.url).searchParams.get("cursor") || undefined;
    const page = await env.WORLDS.list({ prefix: "reports/", cursor, limit: 500 });
    return json({
        reports: page.objects.map((o) => ({ name: o.key.slice(8), size: o.size, uploaded: Math.floor(o.uploaded.getTime() / 1000) })),
        cursor: page.truncated ? page.cursor : null,
    });
}

function reportName(v) {
    if (!REPORT_NAME.test(v || "")) fail(400, "bad_input", "bad report name");
    return v;
}

async function getReport(env, request, name) {
    await admin(env, request);
    const obj = await env.WORLDS.get(reportKey(reportName(name)));
    if (!obj) fail(404, "no_report", "no such report");
    return new Response(obj.body, { headers: { "content-type": "application/zip", "content-length": String(obj.size) } });
}

async function deleteReport(env, request, name) {
    await admin(env, request);
    await env.WORLDS.delete(reportKey(reportName(name)));
    return json({ name, deleted: true });
}

// the cron's share: reports older than REPORT_DAYS go (a few pages a day is plenty for what the cap lets in)
async function pruneReports(env, t) {
    let cursor;
    for (let i = 0; i < 20; i++) {
        const page = await env.WORLDS.list({ prefix: "reports/", cursor, limit: 500 });
        const old = page.objects.filter((o) => o.uploaded.getTime() / 1000 < t - REPORT_DAYS * 24 * 3600).map((o) => o.key);
        if (old.length) await env.WORLDS.delete(old);
        if (!page.truncated) break;
        cursor = page.cursor;
    }
}

// ---- routing ----

async function route(request, env) {
    const url = new URL(request.url);
    const p = url.pathname.replace(/\/+$/, "").split("/").slice(1);
    const m = request.method;
    if (p[0] !== "v1") fail(404, "not_found");
    if (p.length === 1 && m === "GET") return json({ service: "surrounsync-realms", time: now() });
    if (p[1] === "realms" && p.length === 2 && m === "POST") return createRealm(env, request);
    if (p[1] === "invites" && p[2] === "redeem" && p.length === 3 && m === "POST") return redeem(env, request);
    if (p[1] === "motd" && p.length === 2) {
        if (m === "GET") return getMotd(env);
        if (m === "PUT") return setMotd(env, request);
        if (m === "DELETE") return clearMotd(env, request);
    }
    if (p[1] === "realms" && p[2] === "public" && p.length === 3 && m === "GET") return listPublic(env, request);
    if (p[1] === "admin" && p[2] === "delist" && p.length === 3 && m === "POST") return delist(env, request);
    if (p[1] === "reports" && p.length === 2 && m === "POST") return storeReport(env, request);
    if (p[1] === "admin" && p[2] === "reports" && p.length === 3 && m === "GET") return listReports(env, request);
    if (p[1] === "admin" && p[2] === "reports" && p.length === 4) {
        if (m === "GET") return getReport(env, request, p[3]);
        if (m === "DELETE") return deleteReport(env, request, p[3]);
    }
    if (p[1] !== "realms" || p.length < 3) fail(404, "not_found");

    const rid = realmId(p[2]);
    if (p[3] === "join" && p.length === 4 && m === "POST") return joinPublic(env, request, rid);
    const me = await member(env, request, rid);
    const r = await realm(env, rid);
    const sub = p.slice(3).join("/");

    if (sub === "public" && m === "PUT") return setPublic(env, request, r, me);
    // the world is the invited group's: a member from the server list only joins the host's game
    if ((sub === "world" || sub === "generations" || p[3] === "world") && m === "GET") invitedOnly(me);

    if (sub === "" && m === "GET") return status(env, r, me);
    if (sub === "" && m === "PATCH") return rename(env, request, r, me);
    if (sub === "" && m === "DELETE") return deleteRealm(env, r, me);
    if (sub === "rules" && m === "PUT") return setRules(env, request, r, me);
    if (sub === "lease" && m === "POST") return claim(env, request, r, me);
    if (sub === "lease" && m === "DELETE") return release(env, request, r, me);
    if (sub === "lease/heartbeat" && m === "POST") return heartbeat(env, request, r, me);
    if (sub === "world" && m === "GET") return downloadWorld(env, r, null);
    if (sub === "generations" && m === "GET") return listGenerations(env, r);
    if (p[3] === "world" && p.length === 5) {
        const gen = Number(p[4]);
        if (!Number.isInteger(gen) || gen < 1) fail(400, "bad_input", "bad generation");
        if (m === "PUT") return uploadWorld(env, request, r, me, gen);
        if (m === "GET") return downloadWorld(env, r, gen);
    }
    if (sub === "invites" && m === "POST") return createInvite(env, r, me);
    if (sub === "key" && m === "POST") return rotateKey(env, r, me);
    if (p[3] === "members" && p.length === 5 && m === "DELETE") return removeMember(env, r, me, p[4]);
    if (p[3] === "members" && p[5] === "owner" && p.length === 6 && m === "POST") return transferOwner(env, r, me, p[4]);
    fail(404, "not_found");
}

export default {
    async fetch(request, env) {
        leaseSeconds = Number(env.LEASE_SECONDS) || LEASE_SECONDS;
        listStale = Number(env.LIST_STALE_SECONDS) || LIST_STALE_SECONDS;
        try {
            return await route(request, env);
        } catch (e) {
            if (e instanceof ApiError) return json({ error: e.code, message: e.message }, e.status);
            console.error("unhandled", e && e.stack || e);
            return json({ error: "server_error", message: "something went wrong on the server" }, 500);
        }
    },
    async scheduled(_event, env) {
        const t = now();
        await env.DB.batch([
            env.DB.prepare("DELETE FROM invites WHERE expires_at < ? OR used_at < ?").bind(t, t - INVITE_SECONDS),
            env.DB.prepare("DELETE FROM hits WHERE reset_at < ?").bind(t),
            env.DB.prepare("DELETE FROM members WHERE via = 'public' AND COALESCE(last_seen, created_at) < ?").bind(t - PUBLIC_UNSEEN_SECONDS),
            env.DB.prepare("DELETE FROM members WHERE via = 'public' AND last_seen IS NULL AND created_at < ?")
                .bind(t - (Number(env.PUBLIC_NEVER_SEEN_SECONDS) || PUBLIC_NEVER_SEEN_SECONDS)),
        ]);
        await pruneReports(env, t);
    },
};
