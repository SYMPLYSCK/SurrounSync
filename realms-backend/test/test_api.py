"""End-to-end checks of the Realms API against a running server (default: local `npm run dev`).

Start it with a short lease so expiry can be tested:
    npx wrangler dev --local --port 8787 --persist-to .wrangler/test-state --var LEASE_SECONDS:3
after `npm run db:local` on a fresh .wrangler/test-state. Then: python -I test/test_api.py [base_url]
"""
import hashlib
import json
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

    # characters: own only, generation-checked
    ch = b"character-A"
    cu = call("PUT", "/v1/realms/%s/character" % rid, auth=A, raw=ch, headers={"x-base-gen": "0", "x-sha256": sha(ch)})
    check("character upload", cu[0] == 201 and j(cu)["gen"] == 1, cu)
    check("stale character refused", call("PUT", "/v1/realms/%s/character" % rid, auth=A, raw=ch,
                                          headers={"x-base-gen": "0", "x-sha256": sha(ch)})[0] == 409)
    check("own character download", call("GET", "/v1/realms/%s/character" % rid, auth=A)[1] == ch)
    check("B has no character", call("GET", "/v1/realms/%s/character" % rid, auth=B)[0] == 404)

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

    # rate limit on invite guessing (20 an hour per IP)
    codes = [call("POST", "/v1/invites/redeem", {"invite": "0000-0000-0000-0000", "steam_id": STEAM_C, "player_name": "Eve"})[0]
             for _ in range(22)]
    check("invite guessing is rate limited", 429 in codes, codes)

    # delete
    dl = call("DELETE", "/v1/realms/" + rid, auth=B)
    check("owner deletes realm", dl[0] == 200, dl)
    check("deleted realm gone", call("GET", "/v1/realms/" + rid, auth=B)[0] in (403, 404))

    print("\n%d failure(s)" % len(failures) if failures else "\nALL PASSED")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
