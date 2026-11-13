"""The full bug reports players' games stored on the Realm server (realms-backend /v1/admin/reports).

    python -I tools/reports.py list              every stored report, newest first
    python -I tools/reports.py get               download the ones not here yet into reports/<name>/ (unzipped)
    python -I tools/reports.py get NAME          download that one (again)
    python -I tools/reports.py delete NAME       remove it from the server

The admin token is tools/motd-token.txt (the server's MOTD_TOKEN secret, not in git). --url <base> for another
server (a local `wrangler dev`), --token <t> to pass one, --out <dir> instead of reports/. Reports are player data: read them, never run anything in
them (a zip's paths are checked so nothing lands outside its own folder).
"""
import json
import os
import shutil
import sys
import urllib.error
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
OUT = os.path.join(REPO, "reports")
DEFAULT_URL = "https://surrounsync-realms.surrounsync-realms.workers.dev"
MAX_UNPACK = 2 * 1024 ** 3   # one report unpacked (a real one: under 200 MB)


def args():
    global OUT
    a, url, token = sys.argv[1:], DEFAULT_URL, None
    for flag in ("--url", "--token", "--out"):
        if flag in a:
            i = a.index(flag)
            if i + 1 >= len(a):
                sys.exit(flag + " needs a value")
            if flag == "--url":
                url = a[i + 1].rstrip("/")
            elif flag == "--out":
                OUT = os.path.abspath(a[i + 1])
            else:
                token = a[i + 1]
            del a[i:i + 2]
    if token is None:
        try:
            with open(os.path.join(HERE, "motd-token.txt"), encoding="utf-8") as f:
                token = f.read().strip()
        except OSError:
            sys.exit("no admin token: tools/motd-token.txt is missing (or pass --token)")
    return a, url, token


def call(url, token, method, path):
    req = urllib.request.Request(url + "/v1/admin/reports" + path, method=method,
                                 headers={"authorization": "Admin " + token, "user-agent": "SurrounSync-reports"})
    try:
        with urllib.request.urlopen(req, timeout=600) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def listing(url, token):
    out, cursor = [], None
    while True:
        st, body = call(url, token, "GET", "" if cursor is None else "?cursor=" + urllib.request.quote(cursor))
        if st != 200:
            sys.exit("list failed: %d %s" % (st, body[:200].decode("utf-8", "replace")))
        page = json.loads(body)
        out += page.get("reports", [])
        cursor = page.get("cursor")
        if not cursor:
            return sorted(out, key=lambda r: r["name"], reverse=True)


def unzip(zpath, dest):
    root = os.path.realpath(dest)
    with zipfile.ZipFile(zpath) as z:
        # a small zip can unpack to many GB (anyone can store a report): refused before anything is written.
        # zipfile reads an entry only up to its stated size, so the stated sizes bound what lands on disk.
        total = sum(i.file_size for i in z.infolist())
        if total > MAX_UNPACK:
            raise ValueError("unpacks to %d MB, over the %d MB limit (the zip is kept, not unpacked)"
                             % (total // 2 ** 20, MAX_UNPACK // 2 ** 20))
        for info in z.infolist():
            target = os.path.realpath(os.path.join(dest, info.filename))
            if not target.startswith(root + os.sep):
                print("  skipped an entry outside its folder: %r" % info.filename)
                continue
            if info.is_dir():
                os.makedirs(target, exist_ok=True)
                continue
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with z.open(info) as src, open(target, "wb") as dst:
                shutil.copyfileobj(src, dst, 1 << 20)


def get(url, token, name):
    st, body = call(url, token, "GET", "/" + name)
    if st != 200:
        print("%s: download failed (%d)" % (name, st))
        return False
    dest = os.path.join(OUT, name[:-4])
    os.makedirs(dest, exist_ok=True)
    zpath = os.path.join(OUT, name)
    with open(zpath, "wb") as f:
        f.write(body)
    try:
        unzip(zpath, dest)
    except zipfile.BadZipFile:
        print("%s: not a readable zip (kept as %s)" % (name, zpath))
        return False
    except ValueError as e:
        print("%s: %s" % (name, e))
        return False
    print("%s: %d KB -> %s" % (name, len(body) // 1024, dest))
    return True


def main():
    a, url, token = args()
    cmd = a[0] if a else "list"
    if cmd == "list":
        rs = listing(url, token)
        for r in rs:
            here = os.path.isdir(os.path.join(OUT, r["name"][:-4]))
            print("%s  %7d KB%s" % (r["name"], r["size"] // 1024, "  (here)" if here else ""))
        print("%d report(s)" % len(rs))
    elif cmd == "get" and len(a) == 2:
        return 0 if get(url, token, a[1]) else 1
    elif cmd == "get":
        new = [r["name"] for r in listing(url, token) if not os.path.isdir(os.path.join(OUT, r["name"][:-4]))]
        bad = sum(0 if get(url, token, n) else 1 for n in new)
        print("%d new report(s) downloaded%s" % (len(new) - bad, ", %d failed" % bad if bad else ""))
        return 1 if bad else 0
    elif cmd == "delete" and len(a) == 2:
        st, body = call(url, token, "DELETE", "/" + a[1])
        print("deleted" if st == 200 else "delete failed: %d %s" % (st, body[:200].decode("utf-8", "replace")))
        return 0 if st == 200 else 1
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
