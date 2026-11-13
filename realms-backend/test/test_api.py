"""End-to-end checks of the Realms API against a running server (default: local `npm run dev`).

Start it with a short lease so expiry can be tested:
    npx wrangler dev --local --port 8787 --persist-to .wrangler/test-state --var LEASE_SECONDS:3
after `npm run db:local` on a fresh .wrangler/test-state. Then: python -I test/test_api.py [base_url]
"""
import hashlib
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request

BASE = (sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8787").rstrip("/")
STEAM_A, STEAM_B, STEAM_C = "76561190000000001", "76561190000000002", "76561190000000003"
failures = []


def call(method, path, body=None, auth=None, headers=None, raw=None):
    h = dict(headers or {})
    data = None
    if raw is not None:
        data = raw
        h["content-type"] = "application/octet-stream"
    elif body is not None:
        data = json.dumps(body).encode()
        h["content-type"] = "application/json"
    if auth:
        h["authorization"] = "Member %s:%s" % (auth["member_id"], auth["key"])
    req = urllib.request.Request(BASE + path, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.read(), dict(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read(), dict(e.headers)


def j(resp):
    try:
        return json.loads(resp[1])
    except ValueError:
        return {}


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  -> " + str(detail)[:300]))
    if not cond:
        failures.append(name)


def sha(b):
    return hashlib.sha256(b).hexdigest()


def upload(rid, who, token, gen, data, digest=None):
    return call("PUT", "/v1/realms/%s/world/%d" % (rid, gen), auth=who, raw=data,
                headers={"x-lease-token": token, "x-sha256": digest or sha(data)})


def listed(rid):
    lst = call("GET", "/v1/realms/public")
    return lst, next((x for x in j(lst).get("realms", []) if x["realm_id"] == rid), None)


def public_server_list():
    S = ["7656119000000010%d" % i for i in range(8)]
    c = call("POST", "/v1/realms", {"name": "Open Realm", "steam_id": S[0], "player_name": "Carol",
                                    "format": 1, "protocol": 58, "mod_version": "1.0.0", "game_build": "123"})
    C = j(c)
    rid = C["realm_id"]
    D = j(call("POST", "/v1/invites/redeem", {"invite": j(call("POST", "/v1/realms/%s/invites" % rid, auth=C))["invite"],
                                              "steam_id": S[1], "player_name": "Dan"}))
    _, row = listed(rid)
    check("public: a new Realm is not listed", row is None)
    check("public: a private Realm can't be joined", call("POST", "/v1/realms/%s/join" % rid, {"steam_id": S[2], "player_name": "Eve"})[0] == 404)
    check("public: only the owner lists it", call("PUT", "/v1/realms/%s/public" % rid, {"public": True}, auth=D)[0] == 403)
    check("public: bad flag refused", call("PUT", "/v1/realms/%s/public" % rid, {"public": "yes"}, auth=C)[0] == 400)
    p = call("PUT", "/v1/realms/%s/public" % rid, {"public": True}, auth=C)
    check("public: owner lists it, open", p[0] == 200 and j(p).get("public") is True and j(p).get("locked") is False, p)
    lst, row = listed(rid)
    check("public: listed, offline, 0 players, unlocked", row is not None and row["live"] is False and row["players"] == 0
          and row["locked"] is False and row["name"] == "Open Realm", row)
    check("public: the list shows no Steam ids or member names", S[0].encode() not in lst[1] and b"Carol" not in lst[1], lst[1][:300])
    check("public: status shows the flag to members", j(call("GET", "/v1/realms/" + rid, auth=C)).get("public") is True)

    e = call("POST", "/v1/realms/%s/join" % rid, {"steam_id": S[2], "player_name": "Eve"})
    check("public: anyone joins an open one", e[0] == 201 and j(e)["realm_id"] == rid and j(e).get("key"), e)
    E = j(e)
    st = j(call("GET", "/v1/realms/" + rid, auth=E))
    check("public: a list member sees only itself", [x["member_id"] for x in st.get("members", [])] == [E["member_id"]]
          and st["you"]["via"] == "public", st)
    check("public: invited members still see everyone", len(j(call("GET", "/v1/realms/" + rid, auth=D))["members"]) == 3)
    e2 = call("POST", "/v1/realms/%s/join" % rid, {"steam_id": S[2], "player_name": "Eve"})
    check("public: joining again replaces the old list membership (the newest key works, the old one stops)",
          e2[0] == 201 and call("GET", "/v1/realms/" + rid, auth=E)[0] == 403
          and call("GET", "/v1/realms/" + rid, auth=j(e2))[0] == 200
          and len(j(call("GET", "/v1/realms/" + rid, auth=D))["members"]) == 3, e2)
    E = j(e2) if e2[0] == 201 else E
    # (a 409 "already a member" told anyone which Steam ids are in the Realm; audit 2026-11-03)
    dj = call("POST", "/v1/realms/%s/join" % rid, {"steam_id": S[1], "player_name": "Dan"})
    check("public: an invited member's Steam id joins like any other (no member-or-not answer)",
          dj[0] == 201 and j(dj).get("member_id") != D["member_id"], dj)
    check("public: ...and the invited membership keeps working", call("GET", "/v1/realms/" + rid, auth=D)[0] == 200
          and j(call("GET", "/v1/realms/" + rid, auth=D))["you"]["via"] is None)
    cl = call("POST", "/v1/realms/%s/lease" % rid, {"steam_id": S[2], "name": "Eve"}, auth=E)
    check("public: a list member can't host it", cl[0] == 403 and j(cl).get("error") == "invited_only", cl)
    check("public: ...nor make invites", call("POST", "/v1/realms/%s/invites" % rid, auth=E)[0] == 403)
    check("public: ...nor download the world", call("GET", "/v1/realms/%s/world" % rid, auth=E)[0] == 403
          and call("GET", "/v1/realms/%s/world/1" % rid, auth=E)[0] == 403
          and call("GET", "/v1/realms/%s/generations" % rid, auth=E)[0] == 403)
    check("public: ...nor become the owner", call("POST", "/v1/realms/%s/members/%s/owner" % (rid, E["member_id"]), auth=C)[0] == 404)

    tok = j(call("POST", "/v1/realms/%s/lease" % rid, {"steam_id": S[0], "name": "Carol"}, auth=C))["lease_token"]
    hb = lambda b: call("POST", "/v1/realms/%s/lease/heartbeat" % rid, b, auth=C, headers={"x-lease-token": tok})
    h = hb({"players": 2, "max_players": 4, "ping_loc": "fra=12+1/14+2,ams=20+2"})
    check("public: the host's heartbeat sends players and ping", h[0] == 200, h)
    _, row = listed(rid)
    check("public: listed live with players, cap and ping", row and row["live"] is True and row["players"] == 2
          and row["max_players"] == 4 and row["ping_loc"] == "fra=12+1/14+2,ams=20+2", row)
    check("public: an empty heartbeat keeps them", hb(None)[0] == 200 and listed(rid)[1]["players"] == 2)
    for bad in ({"players": 99}, {"max_players": 0}, {"ping_loc": "a\tb"}, {"ping_loc": "é"}, {"ping_loc": "x" * 1025}, {"players": "2"}):
        check("public: bad heartbeat refused %s" % str(bad)[:30], hb(bad)[0] == 400)
    cl = call("POST", "/v1/realms/%s/lease" % rid, {"steam_id": S[2], "name": "Eve"}, auth=E)
    check("public: a list member is told who hosts", cl[0] == 409 and j(cl)["host"]["steam_id"] == S[0], cl)

    check("public: a password under 6 characters refused",
          call("PUT", "/v1/realms/%s/public" % rid, {"public": True, "password": "abcde"}, auth=C)[0] == 400)
    p = call("PUT", "/v1/realms/%s/public" % rid, {"public": True, "password": "hunter2"}, auth=C)
    check("public: owner locks it; who joined open is removed (Eve and Dan's list join)", j(p).get("locked") is True and j(p).get("removed") == 2
          and call("GET", "/v1/realms/" + rid, auth=E)[0] == 403, p)
    check("public: listed as locked", listed(rid)[1]["locked"] is True)
    r = call("POST", "/v1/realms/%s/join" % rid, {"steam_id": S[3], "player_name": "Fay"})
    check("public: locked, no password refused", r[0] == 403 and j(r).get("error") == "bad_password", r)
    check("public: locked, wrong password refused",
          call("POST", "/v1/realms/%s/join" % rid, {"steam_id": S[3], "player_name": "Fay", "password": "hunter3"})[0] == 403)
    f = call("POST", "/v1/realms/%s/join" % rid, {"steam_id": S[3], "player_name": "Fay", "password": "hunter2"})
    check("public: locked, right password joins", f[0] == 201, f)
    F = j(f)
    raw = call("GET", "/v1/realms/" + rid, auth=C)[1]
    check("public: the password is never sent back", b"hunter2" not in raw and b"pass_" not in raw, raw[:200])

    call("DELETE", "/v1/realms/%s/lease" % rid, auth=C, headers={"x-lease-token": tok})
    _, row = listed(rid)
    check("public: release clears players and ping", row and row["live"] is False and row["players"] == 0 and row["ping_loc"] is None, row)
    tok = j(call("POST", "/v1/realms/%s/lease" % rid, {"steam_id": S[0], "name": "Carol"}, auth=C))["lease_token"]
    _, row = listed(rid)
    check("public: a new claim starts with no players or ping", row and row["live"] is True and row["players"] == 0 and row["ping_loc"] is None, row)
    call("DELETE", "/v1/realms/%s/lease" % rid, auth=C, headers={"x-lease-token": tok})

    p = call("PUT", "/v1/realms/%s/public" % rid, {"public": False}, auth=C)
    check("public: owner takes it off the list", j(p).get("public") is False and listed(rid)[1] is None, p)
    check("public: off the list, join refused", call("POST", "/v1/realms/%s/join" % rid, {"steam_id": S[4], "player_name": "Gil"})[0] == 404)
    cl = call("POST", "/v1/realms/%s/lease" % rid, {"steam_id": S[3], "name": "Fay"}, auth=F)
    check("public: unlisting removes list members (no host address for them)", j(p).get("removed") == 1 and cl[0] == 403
          and b"steam_id" not in cl[1], cl)
    check("public: invited members stay", call("GET", "/v1/realms/" + rid, auth=D)[0] == 200)

    # wrong passwords: 10 an hour per address, 200 per Realm from all addresses (the 2 wrong ones above count)
    call("PUT", "/v1/realms/%s/public" % rid, {"public": True, "password": "letmein"}, auth=C)
    ip = lambda s: {"cf-connecting-ip": s}
    codes = [call("POST", "/v1/realms/%s/join" % rid, {"steam_id": S[6], "player_name": "Ivy", "password": "nope%d" % i},
                  headers=ip("203.0.113.1"))[0] for i in range(11)]
    check("public: one address gets 10 wrong passwords an hour, then 429", codes == [403] * 10 + [429], codes)
    r = call("POST", "/v1/realms/%s/join" % rid, {"steam_id": S[6], "player_name": "Ivy", "password": "letmein"}, headers=ip("203.0.113.2"))
    check("public: ...which doesn't lock the right password out for anyone else", r[0] == 201, r)
    codes = [call("POST", "/v1/realms/%s/join" % rid, {"steam_id": S[6], "player_name": "Ivy", "password": "nope%d" % i},
                  headers=ip("203.0.113.%d" % (10 + i // 10)))[0] for i in range(200)]
    check("public: wrong passwords capped per Realm (200 an hour from all addresses, then 429)",
          codes.count(403) == 188 and codes[188:] == [429] * 12, (codes.count(403), codes[180:]))
    r = call("POST", "/v1/realms/%s/join" % rid, {"steam_id": S[6], "player_name": "Ivy", "password": "letmein"}, headers=ip("203.0.113.99"))
    check("public: ...then the right one waits too (many addresses can still do that for the hour)", r[0] == 429, r)
    # one IPv6 /64 is one address for the limits (open again: the wrong-password cap is spent)
    call("PUT", "/v1/realms/%s/public" % rid, {"public": True}, auth=C)
    codes =[call("POST", "/v1/realms/%s/join" % rid, {"steam_id": S[7], "player_name": "Jo"},
                  headers={"cf-connecting-ip": "2001:db8:5:6:%x::1" % i})[0] for i in range(22)]
    check("public: an IPv6 /64 shares one join limit", 429 in codes, codes)

    call("PUT", "/v1/realms/%s/public" % rid, {"public": True}, auth=C)
    codes = [call("POST", "/v1/realms/%s/join" % rid, {"steam_id": S[5], "player_name": "Hal", "password": "x"})[0] for _ in range(22)]
    check("public: joining is rate limited", 429 in codes, codes)
    call("DELETE", "/v1/realms/" + rid, auth=C)


def security_checks():
    """Squatting with made-up Steam ids, list spam, the admin delist, pruning list joins that never came back and
    stale listings. Needs a server started with LIST_STALE_SECONDS:30, PUBLIC_NEVER_SEEN_SECONDS:2 and
    --test-scheduled; with MOTD_TOKEN set (and REALMS_ADMIN_TOKEN here) the delist is tested too."""
    ip = lambda s: {"cf-connecting-ip": s}
    S = ["7656119000000020%d" % i for i in range(8)]

    def new(name, steam, addr):
        return j(call("POST", "/v1/realms", {"name": name, "steam_id": steam, "player_name": "Own", "format": 1,
                                             "protocol": 58, "mod_version": "1.0.0", "game_build": "123"}, headers=ip(addr)))

    O = new("Squat Realm", S[0], "198.51.100.1")
    rid = O["realm_id"]
    call("PUT", "/v1/realms/%s/public" % rid, {"public": True}, auth=O, headers=ip("198.51.100.1"))
    # a list join made up in someone else's name blocks neither their invite nor their own list join
    q = j(call("POST", "/v1/realms/%s/join" % rid, {"steam_id": S[1], "player_name": "Fake"}, headers=ip("198.51.100.50")))
    inv = j(call("POST", "/v1/realms/%s/invites" % rid, auth=O))["invite"]
    r = call("POST", "/v1/invites/redeem", {"invite": inv, "steam_id": S[1], "player_name": "Real"}, headers=ip("198.51.100.51"))
    check("squat: a list join in someone's name doesn't block their invite", r[0] == 201, r)
    check("squat: ...and the made-up list membership is gone", call("GET", "/v1/realms/" + rid, auth=q)[0] == 403)
    q = j(call("POST", "/v1/realms/%s/join" % rid, {"steam_id": S[2], "player_name": "Fake"}, headers=ip("198.51.100.50")))
    r = call("POST", "/v1/realms/%s/join" % rid, {"steam_id": S[2], "player_name": "Real"}, headers=ip("198.51.100.51"))
    check("squat: ...nor their own list join (the made-up one is replaced)",
          r[0] == 201 and call("GET", "/v1/realms/" + rid, auth=q)[0] == 403, r)

    # a list join that never opens the Realm (no claim) is pruned after PUBLIC_NEVER_SEEN_SECONDS
    # ...and a claim while nobody hosts doesn't count as coming back (one call each kept made-up joins for 30 days)
    gone = j(call("POST", "/v1/realms/%s/join" % rid, {"steam_id": S[3], "player_name": "Ghost"}, headers=ip("198.51.100.52")))
    seen = j(call("POST", "/v1/realms/%s/join" % rid, {"steam_id": S[4], "player_name": "Pat"}, headers=ip("198.51.100.52")))
    poke = j(call("POST", "/v1/realms/%s/join" % rid, {"steam_id": S[7], "player_name": "Poke"}, headers=ip("198.51.100.54")))
    host = call("POST", "/v1/realms/%s/lease" % rid, {"steam_id": S[0], "name": "Own"}, auth=O)
    cl = call("POST", "/v1/realms/%s/lease" % rid, {"steam_id": S[4], "name": "Pat"}, auth=seen)
    time.sleep(3.5)   # (the owner's 3 s lease runs out)
    nobody = call("POST", "/v1/realms/%s/lease" % rid, {"steam_id": S[7], "name": "Poke"}, auth=poke)
    time.sleep(2.5)
    sc = call("GET", "/__scheduled?cron=*+*+*+*+*")
    check("prune: a list join that never came back is removed, one that joined a host stays",
          sc[0] == 200 and host[0] == 200 and cl[0] == 409 and call("GET", "/v1/realms/" + rid, auth=gone)[0] == 403
          and call("GET", "/v1/realms/" + rid, auth=seen)[0] == 200, (sc[0], host[0], cl[0]))
    check("prune: a claim while nobody hosts doesn't keep a list join", nobody[0] == 403
          and call("GET", "/v1/realms/" + rid, auth=poke)[0] == 403, nobody)
    # names that pass for another Realm's (direction override, zero-width space)
    for bad in ("Real\u202emlaeR", "Re\u200bal", "Re\u3164al"):
        r = call("POST", "/v1/realms", {"name": bad, "steam_id": S[6], "player_name": "Own", "format": 1, "protocol": 58,
                                        "mod_version": "1.0.0", "game_build": "123"}, headers=ip("198.51.100.60"))
        check("names: invisible or direction characters refused (%s)" % ascii(bad), r[0] == 400, r)
    # Steam persona names reach the server as they are: an emoji with a ZWJ, a soft hyphen, a ZWNJ
    ok = call("POST", "/v1/realms", {"name": "Pride \U0001f3f3\ufe0f\u200d\U0001f308", "steam_id": S[6],
                                     "player_name": "Ka\u00adt \u200c\U0001f469\u200d\U0001f4bb", "format": 1,
                                     "protocol": 58, "mod_version": "1.0.0", "game_build": "123"},
              headers=ip("198.51.100.61"))
    check("names: player names keep joiners and soft hyphens, Realm names keep emoji joiners", ok[0] == 201, ok)
    if ok[0] == 201:
        cl = call("POST", "/v1/realms/%s/lease" % j(ok)["realm_id"], {"steam_id": S[6], "name": "Rainbow \U0001f3f3\ufe0f\u200d\U0001f308"},
                  auth=j(ok))
        check("names: a claim with an emoji joiner in the Steam name is not refused", cl[0] == 200, cl)

    # list spam: one address lists at most 3 Realms, and changes listings at most 20 times an hour
    many = [new("Spam %d" % i, S[5], "198.51.100.9") for i in range(4)]
    listed_at = time.time()
    put = lambda x, on: call("PUT", "/v1/realms/%s/public" % x["realm_id"], {"public": on}, auth=x, headers=ip("198.51.100.9"))[0]
    codes = [put(x, True) for x in many]
    check("spam: one address lists at most 3 Realms", codes == [200, 200, 200, 429], codes)
    check("spam: ...taking one off frees a place", put(many[0], False) == 200 and put(many[3], True) == 200)
    codes = [put(many[0], False) for _ in range(16)]
    check("spam: listing changes are rate limited per address", 429 in codes, codes)
    # one IPv6 /48 lists at most 6, though each /64 in it is its own address (audit 2026-11-03)
    net = [new("Net %d" % i, S[5], "2001:db8:48:%x::1" % i) for i in range(7)]
    codes = [call("PUT", "/v1/realms/%s/public" % x["realm_id"], {"public": True}, auth=x,
                  headers=ip("2001:db8:48:%x::1" % i))[0] for i, x in enumerate(net)]
    check("spam: one IPv6 /48 lists at most 6 Realms", codes == [200] * 6 + [429], codes)
    o = call("PUT", "/v1/realms/%s/public" % net[6]["realm_id"], {"public": True}, auth=net[6], headers=ip("2001:db8:49::1"))
    check("spam: ...another /48 still lists", o[0] == 200, o)
    # the list puts the most recently listed or hosted first, not "AAA..." names nobody plays
    old = new("AAA Old", S[5], "198.51.100.70")
    put_at = lambda x, a: call("PUT", "/v1/realms/%s/public" % x["realm_id"], {"public": True}, auth=x, headers=ip(a))[0]
    put_at(old, "198.51.100.70")
    time.sleep(1.2)
    fresh = new("ZZZ Fresh", S[5], "198.51.100.71")
    put_at(fresh, "198.51.100.71")
    ids = [x["realm_id"] for x in j(call("GET", "/v1/realms/public")).get("realms", [])]
    check("list: a newer listing comes before an older one with an earlier name",
          fresh["realm_id"] in ids and old["realm_id"] in ids and ids.index(fresh["realm_id"]) < ids.index(old["realm_id"]), ids)

    # the admin delist (needs the MOTD_TOKEN secret on the server)
    token = os.environ.get("REALMS_ADMIN_TOKEN", "")
    d = call("POST", "/v1/admin/delist", {"realm_id": rid}, headers={"authorization": "Admin " + "x" * 40})
    if not token:
        check("delist: a server without the admin secret has no delist", d[0] == 404, d)
    else:
        check("delist: a wrong admin token refused", d[0] == 403, d)
        adm = {"authorization": "Admin " + token}
        d = call("POST", "/v1/admin/delist", {"realm_id": rid}, headers=adm)
        check("delist: the admin takes it off the list", d[0] == 200 and j(d).get("delisted") is True and listed(rid)[1] is None, d)
        check("delist: its list members go and nobody joins it",
              call("GET", "/v1/realms/" + rid, auth=seen)[0] == 403
              and call("POST", "/v1/realms/%s/join" % rid, {"steam_id": S[6], "player_name": "Lu"}, headers=ip("198.51.100.53"))[0] == 404)
        p = call("PUT", "/v1/realms/%s/public" % rid, {"public": True}, auth=O, headers=ip("198.51.100.1"))
        check("delist: the owner can't put it back", p[0] == 403 and j(p).get("error") == "delisted", p)
        check("delist: ...but keeps the Realm and its invited members", call("GET", "/v1/realms/" + rid, auth=O)[0] == 200)
        u = call("POST", "/v1/admin/delist", {"realm_id": rid, "undo": True}, headers=adm)
        check("delist: undo lets the owner list it again", u[0] == 200
              and call("PUT", "/v1/realms/%s/public" % rid, {"public": True}, auth=O, headers=ip("198.51.100.1"))[0] == 200, u)
        check("delist: an unknown Realm", call("POST", "/v1/admin/delist", {"realm_id": "0000000000"}, headers=adm)[0] == 404)
        codes = [call("POST", "/v1/admin/delist", {"realm_id": "0000000000"}, headers=adm)[0] for _ in range(35)]
        check("admin: its own calls never hit the cap (35 in a row)", codes == [404] * 35, codes)
        bad = {"authorization": "Admin " + "y" * 40, "cf-connecting-ip": "198.51.100.77"}
        codes = [call("POST", "/v1/admin/delist", {"realm_id": rid}, headers=bad)[0] for _ in range(32)]
        check("admin: wrong tokens are capped per address", codes[:30] == [403] * 30 and codes[30:] == [429, 429], codes)

    # a listed Realm nobody hosts drops off after LIST_STALE_SECONDS and comes back when hosted
    x = many[1]
    check("stale: a newly listed Realm shows", listed(x["realm_id"])[1] is not None)
    time.sleep(max(0.0, listed_at + 32 - time.time()))
    check("stale: unhosted past the window, it drops off the list", listed(x["realm_id"])[1] is None)
    check("stale: ...but stays public", j(call("GET", "/v1/realms/" + x["realm_id"], auth=x)).get("public") is True)
    call("POST", "/v1/realms/%s/lease" % x["realm_id"], {"steam_id": S[5], "name": "Own"}, auth=x)
    check("stale: hosting it brings it back", (listed(x["realm_id"])[1] or {}).get("live") is True)


def report_checks():
    """Full bug reports: anyone stores a zip (limited); only the admin (REALMS_ADMIN_TOKEN = the server's MOTD_TOKEN)
    lists, reads and deletes them."""
    zipb = b"PK\x03\x04" + os.urandom(200_000) + b"PK\x05\x06" + b"\0" * 18
    ip = {"cf-connecting-ip": "198.51.100.%d" % (int(time.time()) % 200 + 20)}

    def put(data, level="CRITICAL", extra=None):
        h = dict(ip, **{"x-report-level": level})
        h.update(extra or {})
        return call("POST", "/v1/reports", raw=data, headers=h)

    # security review R12: refused uploads give their share of the day's budget back (else a few that declare 90 MB
    # and send junk used it up). Meaningful with a small budget: run the server with --var REPORT_MB_PER_DAY:50 and
    # set REALMS_REPORT_BUDGET=50 here.
    if os.environ.get("REALMS_REPORT_BUDGET") == "50":
        junk = b"MZ" + bytes(30 * 1024 * 1024)
        tries = [call("POST", "/v1/reports", raw=junk, headers={"cf-connecting-ip": "198.51.100.%d" % (210 + i), "x-report-level": "INFO"})[0]
                 for i in range(2)]
        ok = call("POST", "/v1/reports", raw=zipb, headers={"cf-connecting-ip": "198.51.100.230", "x-report-level": "INFO"})
        # (wrangler dev's proxy turns a body the worker stops reading into a 500: either way it's refused)
        check("refused junk doesn't use up the day's report budget", all(t in (400, 500) for t in tries) and ok[0] == 200, (tries, ok[0]))
        if ok[0] == 200 and os.environ.get("REALMS_ADMIN_TOKEN"):
            call("DELETE", "/v1/admin/reports/" + j(ok).get("name", "x"), headers={"authorization": "Admin " + os.environ["REALMS_ADMIN_TOKEN"]})
    s = put(zipb)
    name = j(s).get("name", "")
    check("a report zip is stored", s[0] == 200 and name.endswith(".zip") and "-CRITICAL-" in name and j(s).get("size") == len(zipb), s)
    check("not a zip: refused", put(b"MZ" + b"\0" * 100)[0] == 400)
    check("no level: refused", call("POST", "/v1/reports", raw=zipb, headers=ip)[0] == 400)
    check("a made-up level: refused", put(zipb, "HACKED")[0] == 400)
    # (wrangler dev reads the whole body before the worker runs, so this sends a real one)
    try:
        big = put(b"PK\x03\x04" + bytes(91 * 1024 * 1024), "INFO")[0]
    except OSError as e:
        big = str(e)
    check("over 90 MB: refused", big == 413, big)
    check("nobody lists reports without the token", call("GET", "/v1/admin/reports")[0] in (403, 404))
    check("nobody reads one without the token", call("GET", "/v1/admin/reports/" + (name or "x"))[0] in (403, 404))
    token = os.environ.get("REALMS_ADMIN_TOKEN", "")
    if token:
        adm = dict(ip, authorization="Admin " + token)
        ls = call("GET", "/v1/admin/reports", headers=adm)
        names = [r["name"] for r in j(ls).get("reports", [])]
        check("the admin lists the stored report", ls[0] == 200 and name in names, ls)
        g = call("GET", "/v1/admin/reports/" + name, headers=adm)
        check("...and downloads it byte for byte", g[0] == 200 and g[1] == zipb, (g[0], len(g[1])))
        check("a path in the name is refused", call("GET", "/v1/admin/reports/..%2Frealms%2Fx", headers=adm)[0] in (400, 404))
        d = call("DELETE", "/v1/admin/reports/" + name, headers=adm)
        check("...and deletes it", d[0] == 200 and call("GET", "/v1/admin/reports/" + name, headers=adm)[0] == 404, d)
    codes = [put(zipb, "INFO")[0] for _ in range(6)]
    check("one address stores at most 6 a day", 429 in codes, codes)


def main():
    s = call("GET", "/v1")
    check("service answers", s[0] == 200, s)

    # create + auth
    c = call("POST", "/v1/realms", {"name": "Test Realm", "steam_id": STEAM_A, "player_name": "Alice",
                                    "format": 1, "protocol": 55, "mod_version": "0.14.0", "game_build": "123"})
    check("create realm", c[0] == 201, c)
    A = j(c)
    rid = A["realm_id"]
    check("code format", A["code"] == "R-%s-%s" % (rid[:5], rid[5:]), A)
    check("bad create input rejected", call("POST", "/v1/realms", {"name": "", "steam_id": "x"})[0] == 400)
    check("status needs a key", call("GET", "/v1/realms/" + rid)[0] == 401)
    check("wrong key refused", call("GET", "/v1/realms/" + rid, auth={"member_id": A["member_id"], "key": "A" * 43})[0] == 403)
    st = call("GET", "/v1/realms/" + A["code"].lower(), auth=A)
    check("status by code (any case)", st[0] == 200 and j(st)["you"]["role"] == "owner", st)
    check("no world yet", j(st)["head"] is None and j(st)["host"] is None, st)

    # invites
    inv = j(call("POST", "/v1/realms/%s/invites" % rid, auth=A))["invite"]
    r = call("POST", "/v1/invites/redeem", {"invite": inv.lower(), "steam_id": STEAM_B, "player_name": "Bob"})
    check("redeem invite", r[0] == 201 and j(r)["realm_id"] == rid, r)
    B = j(r)
    check("invite is one-time", call("POST", "/v1/invites/redeem", {"invite": inv, "steam_id": STEAM_C, "player_name": "Eve"})[0] == 404)
    check("member sees realm", j(call("GET", "/v1/realms/" + rid, auth=B))["you"]["role"] == "member")
    inv2 = j(call("POST", "/v1/realms/%s/invites" % rid, auth=A))["invite"]
    r2 = call("POST", "/v1/invites/redeem", {"invite": inv2, "steam_id": STEAM_B, "player_name": "Bob"})
    check("a member can't redeem a second invite (no duplicate member)", r2[0] == 409 and j(r2).get("error") == "already_member", r2)
    check("other realm's key refused", call("GET", "/v1/realms/0000000000", auth=B)[0] == 403)

    # lease: one winner
    la = call("POST", "/v1/realms/%s/lease" % rid, {"steam_id": STEAM_A, "name": "Alice"}, auth=A)
    check("A claims", la[0] == 200 and j(la)["won"], la)
    tokA = j(la)["lease_token"]
    lb = call("POST", "/v1/realms/%s/lease" % rid, {"steam_id": STEAM_B, "name": "Bob"}, auth=B)
    check("B told A is hosting", lb[0] == 409 and j(lb)["host"]["steam_id"] == STEAM_A, lb)

    # uploads
    w1 = b"world-1" * 1000
    check("non-host upload refused", upload(rid, B, "x" * 32, 1, w1)[0] == 409)
    check("skipped generation refused", upload(rid, A, tokA, 2, w1)[0] == 409)
    check("bad hash refused", upload(rid, A, tokA, 1, w1, "0" * 64)[0] == 400)
    check("oversize refused", upload(rid, A, tokA, 1, b"x" * (16 * 1024 * 1024 + 1))[0] == 413)
    u = upload(rid, A, tokA, 1, w1)
    check("host uploads gen 1", u[0] == 201 and j(u)["gen"] == 1, u)
    check("same gen again refused", upload(rid, A, tokA, 1, w1)[0] == 409)
    d = call("GET", "/v1/realms/%s/world" % rid, auth=B)
    check("member downloads head", d[0] == 200 and d[1] == w1 and d[2].get("X-Sha256", d[2].get("x-sha256")) == sha(w1), d[2])

    # heartbeat, release, hand over
    check("heartbeat", call("POST", "/v1/realms/%s/lease/heartbeat" % rid, auth=A, headers={"x-lease-token": tokA})[0] == 200)
    rel = call("DELETE", "/v1/realms/%s/lease" % rid, auth=A, headers={"x-lease-token": tokA})
    check("release", j(rel).get("released") is True, rel)
    lb = call("POST", "/v1/realms/%s/lease" % rid, {"steam_id": STEAM_B, "name": "Bob"}, auth=B)
    check("B claims after release", lb[0] == 200 and j(lb)["head_gen"] == 1, lb)
    tokB = j(lb)["lease_token"]
    check("old host's heartbeat refused", call("POST", "/v1/realms/%s/lease/heartbeat" % rid, auth=A, headers={"x-lease-token": tokA})[0] == 409)
    check("old host's upload refused", upload(rid, A, tokA, 2, b"stale")[0] == 409)

    # expiry (server started with LEASE_SECONDS=3)
    time.sleep(4.5)
    la = call("POST", "/v1/realms/%s/lease" % rid, {"steam_id": STEAM_A, "name": "Alice"}, auth=A)
    check("expired lease can be taken over", la[0] == 200 and j(la)["won"], la)
    tokA = j(la)["lease_token"]
    check("crashed host can't upload after takeover", upload(rid, B, tokB, 2, b"late")[0] == 409)
    call("DELETE", "/v1/realms/%s/lease" % rid, auth=A, headers={"x-lease-token": tokA})

    # race: many claims at once, exactly one winner
    results = []
    def grab(who, steam):
        results.append((who["member_id"], call("POST", "/v1/realms/%s/lease" % rid, {"steam_id": steam, "name": "x"}, auth=who)[0]))
    threads = [threading.Thread(target=grab, args=((A, STEAM_A) if i % 2 else (B, STEAM_B))) for i in range(10)]
    for t in threads: t.start()
    for t in threads: t.join()
    # the same member may re-claim (its own restart), so all wins must belong to ONE member
    winners = {mid for mid, code in results if code == 200}
    holder = j(call("GET", "/v1/realms/" + rid, auth=A))["host"]["member_id"]
    check("race: exactly one member wins", len(winners) == 1 and winners == {holder}, results)
    check("race: every other claim told who hosts", all(code in (200, 409) for _, code in results), results)
    host = A if holder == A["member_id"] else B
    tok = j(call("POST", "/v1/realms/%s/lease" % rid, {"steam_id": STEAM_A, "name": "x"}, auth=host))["lease_token"]

    # generations kept
    for g in range(2, 14):
        upload(rid, host, tok, g, b"world-%d" % g)
    gens = [x["gen"] for x in j(call("GET", "/v1/realms/%s/generations" % rid, auth=A))["generations"]]
    check("last 10 generations kept", gens == list(range(13, 3, -1)), gens)
    check("pruned generation gone", call("GET", "/v1/realms/%s/world/1" % rid, auth=A)[0] == 404)
    check("kept generation readable", call("GET", "/v1/realms/%s/world/4" % rid, auth=A)[1] == b"world-4")

    # no character store: characters live on each player's PC (the unused routes wrote the database before storage)
    ch = b"character-A"
    check("character upload is gone", call("PUT", "/v1/realms/%s/character" % rid, auth=A, raw=ch,
                                           headers={"x-base-gen": "0", "x-sha256": sha(ch)})[0] == 404)
    check("character download is gone", call("GET", "/v1/realms/%s/character" % rid, auth=A)[0] == 404)

    # members
    check("member can't remove others", call("DELETE", "/v1/realms/%s/members/%s" % (rid, A["member_id"]), auth=B)[0] == 403)
    check("member can't delete the realm", call("DELETE", "/v1/realms/" + rid, auth=B)[0] == 403)
    check("member can't rename", call("PATCH", "/v1/realms/" + rid, {"name": "Mine"}, auth=B)[0] == 403)
    check("owner renames", j(call("PATCH", "/v1/realms/" + rid, {"name": "Renamed"}, auth=A)).get("name") == "Renamed")
    check("owner can't just leave", call("DELETE", "/v1/realms/%s/members/%s" % (rid, A["member_id"]), auth=A)[0] == 409)
    k = call("POST", "/v1/realms/%s/key" % rid, auth=B)
    oldB, B = B, dict(B, key=j(k)["key"])
    check("rotated key works, old one doesn't", call("GET", "/v1/realms/" + rid, auth=B)[0] == 200
          and call("GET", "/v1/realms/" + rid, auth=oldB)[0] == 403)
    t = call("POST", "/v1/realms/%s/members/%s/owner" % (rid, B["member_id"]), auth=A)
    check("transfer ownership", t[0] == 200 and j(call("GET", "/v1/realms/" + rid, auth=B))["you"]["role"] == "owner", t)
    check("new owner removes old owner", call("DELETE", "/v1/realms/%s/members/%s" % (rid, A["member_id"]), auth=B)[0] == 200)
    check("removed member locked out", call("GET", "/v1/realms/" + rid, auth=A)[0] == 403)

    public_server_list()
    security_checks()
    report_checks()

    # rate limit on invite guessing (20 an hour per IP)
    codes = [call("POST", "/v1/invites/redeem", {"invite": "0000-0000-0000-0000", "steam_id": STEAM_C, "player_name": "Eve"})[0]
             for _ in range(22)]
    check("invite guessing is rate limited", 429 in codes, codes)

    # delete
    dl = call("DELETE", "/v1/realms/" + rid, auth=B)
    check("owner deletes realm", dl[0] == 200, dl)
    check("deleted realm gone", call("GET", "/v1/realms/" + rid, auth=B)[0] in (403, 404))

    # message of the day: public to read; on a server without the MOTD_TOKEN secret nobody can set it
    g = call("GET", "/v1/motd")
    check("motd readable without auth", g[0] == 200 and "id" in j(g), g)
    # (with MOTD_TOKEN set on the server - REALMS_ADMIN_TOKEN here - a wrong token is 403 instead)
    secret = bool(os.environ.get("REALMS_ADMIN_TOKEN"))
    for token in ("", "x" * 40):
        p = call("PUT", "/v1/motd", {"text": "hi"}, headers={"authorization": "Admin " + token} if token else None)
        want = 403 if secret else 404
        check("motd can't be set without the server's secret (%s)" % ("no token" if not token else "a token"), p[0] == want, p)

    print("\n%d failure(s)" % len(failures) if failures else "\nALL PASSED")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
