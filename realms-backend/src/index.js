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
const MAX_CHARACTER = 2 * 1024 * 1024;
const MAX_JSON = 4 * 1024;
const MAX_MEMBERS = 16;
const MAX_OPEN_INVITES = 20;
const LIMITS = {                      // per IP: [requests, window seconds]
    create: [5, 24 * 3600],
    redeem: [20, 3600],
    // every member call (list, heartbeat, uploads): only an abuse guard. 600 was hit in one evening by two games
    // on one connection (each list = one call per known Realm) - the host's heartbeat got refused, its lease lapsed
    auth: [10000, 3600],
};

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

function text(v, field, max) {
    if (typeof v !== "string") fail(400, "bad_input", field + " must be text");
    const s = v.trim();
    if (s.length < 1 || s.length > max) fail(400, "bad_input", `${field} must be 1-${max} characters`);
    if (/[\u0000-\u001f\u007f]/.test(s)) fail(400, "bad_input", field + " has control characters");
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

async function body(request) {
    const len = Number(request.headers.get("content-length") || "0");
    if (len > MAX_JSON) fail(413, "too_large");
    const raw = await request.text();
    if (raw.length > MAX_JSON) fail(413, "too_large");
    if (!raw) return {};
    try {
        const v = JSON.parse(raw);
        if (v === null || typeof v !== "object" || Array.isArray(v)) throw new Error();
        return v;
    } catch { fail(400, "bad_json"); }
}

// Reads a binary upload up to max bytes; stops reading as soon as it is over.
async function blob(request, max) {
    const len = Number(request.headers.get("content-length") || "0");
    if (len > max) fail(413, "too_large");
    if (!request.body) fail(400, "empty");
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
    if (n === 0) fail(400, "empty");
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

async function limit(env, request, action) {
    const [max, window] = LIMITS[action];
    const ip = request.headers.get("cf-connecting-ip") || "local";
    const t = now(), start = t - (t % window);
    const row = await env.DB.prepare(
        "INSERT INTO hits (bucket, n, reset_at) VALUES (?, 1, ?) ON CONFLICT(bucket) DO UPDATE SET n = n + 1 RETURNING n")
        .bind(`${action}:${ip}:${start}`, start + window).first();
    if (row && row.n > max) fail(429, "slow_down", "too many requests, try again later");
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

async function newMember(env, rid, steam, name, role) {
    for (let i = 0; i < 3; i++) {
        const mid = randomB32(8), key = randomKey(32);
        const r = await env.DB.prepare(
            "INSERT OR IGNORE INTO members (realm_id, member_id, key_hash, steam_id, name, role, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)")
            .bind(rid, mid, await sha256hex(key), steam, name, role, now()).run();
        if (r.meta.changes === 1) return { member_id: mid, key };
    }
    fail(500, "id_clash");
}

const worldKey = (rid, gen) => `realms/${rid}/world/${String(gen).padStart(10, "0")}`;
const charKey = (rid, mid) => `realms/${rid}/char/${mid}`;

// ---- handlers ----

async function createRealm(env, request) {
    await limit(env, request, "create");
    const b = await body(request);
    const name = text(b.name, "name", 40), steam = steamId(b.steam_id), player = text(b.player_name, "player_name", 32);
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

async function status(env, r, me) {
    const t = now();
    const { results } = await env.DB.prepare(
        "SELECT member_id, name, steam_id, role, last_seen FROM members WHERE realm_id = ? ORDER BY created_at").bind(r.id).all();
    return json({
        realm_id: r.id, code: realmCode(r.id), name: r.name, format: r.format, mod_version: r.mod_version,
        protocol: r.protocol, game_build: r.game_build,
        head: r.head_gen > 0 ? { gen: r.head_gen, sha256: r.head_hash, size: r.head_size, member_id: r.head_member, at: r.head_at } : null,
        host: leaseActive(r, t) ? { member_id: r.lease_member, steam_id: r.lease_steam, name: r.lease_name, expires_in: r.lease_expires - t } : null,
        members: results,
        you: { member_id: me.member_id, role: me.role },
    });
}

async function rename(env, request, r, me) {
    if (me.role !== "owner") fail(403, "owner_only");
    const b = await body(request);
    const name = text(b.name, "name", 40);
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
    const res = await env.DB.prepare(
        `UPDATE realms SET lease_member = ?, lease_steam = ?, lease_name = ?, lease_token = ?, lease_expires = ?
         WHERE id = ? AND (lease_token IS NULL OR lease_expires <= ? OR lease_member = ?)`)
        .bind(me.member_id, steam, name, token, t + leaseSeconds, r.id, t, me.member_id).run();
    if (res.meta.changes !== 1) {
        const cur = await realm(env, r.id);
        return json({ won: false, host: { member_id: cur.lease_member, steam_id: cur.lease_steam, name: cur.lease_name,
            expires_in: cur.lease_expires - t } }, 409);
    }
    await env.DB.prepare("UPDATE members SET last_seen = ?, steam_id = ?, name = ? WHERE realm_id = ? AND member_id = ?")
        .bind(t, steam, name, r.id, me.member_id).run();
    return json({ won: true, lease_token: token, expires_in: leaseSeconds, head_gen: r.head_gen, head_sha256: r.head_hash });
}

// Works on an expired lease too as long as nobody else claimed it since (the token would have changed).
async function heartbeat(env, request, r, me) {
    const token = leaseToken(request);
    const res = await env.DB.prepare(
        "UPDATE realms SET lease_expires = ? WHERE id = ? AND lease_token = ? AND lease_member = ?")
        .bind(now() + leaseSeconds, r.id, token, me.member_id).run();
    if (res.meta.changes !== 1) fail(409, "lease_lost", "someone else is hosting this Realm now");
    return json({ expires_in: leaseSeconds });
}

async function release(env, request, r, me) {
    const token = leaseToken(request);
    const res = await env.DB.prepare(
        `UPDATE realms SET lease_member = NULL, lease_steam = NULL, lease_name = NULL, lease_token = NULL, lease_expires = NULL
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
    const t = now();
    const counts = await env.DB.prepare(
        `SELECT (SELECT COUNT(*) FROM members WHERE realm_id = ?1) AS members,
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
        `SELECT (SELECT COUNT(*) FROM members WHERE realm_id = i.realm_id) AS n,
                (SELECT COUNT(*) FROM members WHERE realm_id = i.realm_id AND steam_id = ?2) AS mine
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
    const after = await env.DB.prepare("SELECT COUNT(*) AS n FROM members WHERE realm_id = ?").bind(r.id).first();
    if (after.n > MAX_MEMBERS) {
        await env.DB.prepare("DELETE FROM members WHERE realm_id = ? AND member_id = ?").bind(r.id, m.member_id).run();
        await env.DB.prepare("UPDATE invites SET used_at = NULL WHERE code_hash = ?").bind(h).run();
        fail(409, "full", `a Realm has at most ${MAX_MEMBERS} members`);
    }
    return json({ realm_id: r.id, code: realmCode(r.id), name: r.name, ...m }, 201);
}

async function removeMember(env, r, me, mid) {
    if (mid === me.member_id) {
        if (me.role === "owner") fail(409, "owner_must_transfer", "give the Realm to another member before leaving");
    } else if (me.role !== "owner") fail(403, "owner_only");
    const res = await env.DB.prepare("DELETE FROM members WHERE realm_id = ? AND member_id = ?").bind(r.id, mid).run();
    if (res.meta.changes !== 1) fail(404, "no_member");
    await env.WORLDS.delete(charKey(r.id, mid));
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
        env.DB.prepare("UPDATE members SET role = 'owner' WHERE realm_id = ? AND member_id = ? AND role = 'member'").bind(r.id, mid),
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

// Each member's own Realm character: only they can read or write it. X-Base-Gen must match the stored
// generation, so two copies of the same player can't silently overwrite each other.
async function uploadCharacter(env, request, r, me) {
    const base = Number(request.headers.get("x-base-gen"));
    if (!Number.isInteger(base) || base < 0) fail(400, "bad_input", "X-Base-Gen header missing");
    if (base !== me.char_gen) fail(409, "stale", `your newest character is generation ${me.char_gen}`);
    const want = claimedHash(request);
    const data = await blob(request, MAX_CHARACTER);
    const got = await sha256hex(data);
    if (got !== want) fail(400, "bad_hash", "upload damaged in transit");
    const gen = base + 1;
    const res = await env.DB.prepare(
        "UPDATE members SET char_gen = ?, char_hash = ?, char_size = ? WHERE realm_id = ? AND member_id = ? AND char_gen = ?")
        .bind(gen, got, data.byteLength, r.id, me.member_id, base).run();
    if (res.meta.changes !== 1) fail(409, "stale", "your character changed during the upload");
    await env.WORLDS.put(charKey(r.id, me.member_id), data, { customMetadata: { sha256: got, gen: String(gen) } });
    return json({ gen, sha256: got, size: data.byteLength }, 201);
}

async function downloadCharacter(env, r, me) {
    if (me.char_gen < 1) fail(404, "no_character", "no character uploaded yet");
    const obj = await env.WORLDS.get(charKey(r.id, me.member_id));
    if (!obj) fail(404, "no_character");
    return new Response(obj.body, { headers: {
        "content-type": "application/octet-stream", "x-gen": obj.customMetadata.gen, "x-sha256": obj.customMetadata.sha256 } });
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
    if (p[1] !== "realms" || p.length < 3) fail(404, "not_found");

    const rid = realmId(p[2]);
    const me = await member(env, request, rid);
    const r = await realm(env, rid);
    const sub = p.slice(3).join("/");

    if (sub === "" && m === "GET") return status(env, r, me);
    if (sub === "" && m === "PATCH") return rename(env, request, r, me);
    if (sub === "" && m === "DELETE") return deleteRealm(env, r, me);
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
    if (sub === "character" && m === "PUT") return uploadCharacter(env, request, r, me);
    if (sub === "character" && m === "GET") return downloadCharacter(env, r, me);
    if (p[3] === "members" && p.length === 5 && m === "DELETE") return removeMember(env, r, me, p[4]);
    if (p[3] === "members" && p[5] === "owner" && p.length === 6 && m === "POST") return transferOwner(env, r, me, p[4]);
    fail(404, "not_found");
}

export default {
    async fetch(request, env) {
        leaseSeconds = Number(env.LEASE_SECONDS) || LEASE_SECONDS;
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
        ]);
    },
};
