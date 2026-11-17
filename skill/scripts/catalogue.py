#!/usr/bin/env python3
"""Catalogue builder (multi-source). Run natively on macOS.
Reads config.json from its own folder (or --home PATH). Writes:
  catalogue.json          rows for non-private sources (published to the file-finder page)
  catalogue-private.json  rows for private sources (chat only, never published)
  page.json               the page's text, taken from the config
Usage: python3 catalogue.py [--merge] [--home PATH]
  --merge keeps summaries from the previous catalogues and, for a drive that is unplugged, its last-seen rows."""
import os, re, sys, json, time, ctypes, ctypes.util, subprocess, plistlib

def arg(name, default=None):
    if name in sys.argv:
        i = sys.argv.index(name)
        return sys.argv[i + 1] if i + 1 < len(sys.argv) else default
    return default

HERE = os.path.abspath(os.path.expanduser(arg("--home") or os.path.dirname(os.path.abspath(__file__))))
try:
    CFG = json.load(open(os.path.join(HERE, "config.json")))
except Exception as e:
    sys.exit(f"Can't read config.json in {HERE}: {e}")

DEFAULT_MEDIA = [".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".tif", ".tiff", ".psd", ".ai", ".svg", ".eps", ".indd", ".idml", ".mov", ".mp4", ".m4v", ".cr2", ".cr3", ".raf", ".dng", ".nef", ".arw", ".otf", ".ttf", ".woff", ".woff2", ".xmp", ".cos", ".cop", ".cof", ".cot", ".comask", ".pdf"]
STRUCT, CAT = CFG.get("structure", {}), CFG.get("catalogue", {})
KEEP_BUNDLES = STRUCT.get("keep_bundles_whole", True)
BD = STRUCT.get("bundle_detection", {})
MIN_FILES, MIN_MEDIA = BD.get("min_files", 20), BD.get("min_media_share", 0.7)
BUNDLE_ROOTS = STRUCT.get("bundle_roots", [])   # [{"prefix": "Photos", "depth_below": 4}]: folders that deep below it are one entry each
MEDIA = set(CAT.get("media_extensions", DEFAULT_MEDIA))
GOOGLE = {".gdoc": "Google Doc", ".gsheet": "Google Sheet", ".gslides": "Google Slides", ".gform": "Google Form", ".gdraw": "Google Drawing", ".gscript": "Apps Script", ".gsite": "Google Site"}
ALWAYS_SKIP = {".Trash", ".Trashes", ".tmp.drivedownload", ".tmp.driveupload", "Icon\r", "System Volume Information", "$RECYCLE.BIN"}

libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
libc.getxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
libc.getxattr.restype = ctypes.c_ssize_t

def gid(path):
    buf = ctypes.create_string_buffer(256)
    n = libc.getxattr(path.encode(), b"com.google.drivefs.item-id#S", buf, 256, 0, 0)
    return buf.raw[:n].decode() if n > 0 else ""

def mt(t): return time.strftime("%Y-%m-%d", time.localtime(t))

def volume_state(src):
    """'n/a' for ordinary folders; for drives: ok | not-mounted | startup-disk | folder-missing."""
    if not (src.get("removable") or src.get("require_mounted") or src.get("kind") == "external-drive"): return "n/a"
    root = os.path.abspath(os.path.expanduser(src.get("root", "")))
    m = re.match(r"^/Volumes/[^/]+", root)
    vol = m.group(0) if m else root
    parent = "/Volumes" if m else os.path.dirname(vol)
    try:
        if os.path.realpath(vol) == "/": return "startup-disk"
        if os.stat(vol).st_dev == os.stat(parent).st_dev: return "not-mounted"
        return "ok" if os.path.exists(root) else "folder-missing"
    except OSError:
        return "not-mounted"

def link_for(src, abs_path, rel, is_dir):
    if src.get("kind") == "google-drive":
        i = gid(abs_path)
        return {"i": i} if i else {"pi": gid(os.path.dirname(abs_path))}
    return {}   # other kinds: no reliable per-file web link; the page shows the Mac path

def is_set(d, files, subdirs, rel):
    if not KEEP_BUNDLES: return False
    parts = rel.split("/")
    for br in BUNDLE_ROOTS:
        pre = br["prefix"].split("/")
        if parts[:len(pre)] == pre and len(parts) - len(pre) >= br.get("depth_below", 4): return True
    if len(files) + subdirs < MIN_FILES: return False
    allf = [f for r, ds, fs in os.walk(d) for f in fs if not f.startswith(".")]
    if len(allf) < MIN_FILES: return False
    return sum(1 for f in allf if os.path.splitext(f)[1].lower() in MEDIA) / len(allf) >= MIN_MEDIA

def index(src):
    root = os.path.expanduser(src["root"]); rows = []; skip = set(src.get("exclude", [])) | ALWAYS_SKIP
    if not os.path.isdir(root): return rows, "missing"
    for r, ds, fs in os.walk(root):
        rel = os.path.relpath(r, root)
        ds[:] = sorted(d for d in ds if not d.startswith(".") and d not in skip and (rel == "." or os.path.join(rel, d) not in skip))
        if rel != "." and is_set(r, [f for f in fs if not f.startswith(".")], len(ds), rel):
            n = b = 0; last = 0
            for rr, dd, ff in os.walk(r):
                for f in ff:
                    if f.startswith("."): continue
                    try: st = os.stat(os.path.join(rr, f)); n += 1; b += st.st_size; last = max(last, st.st_mtime)
                    except OSError: pass
            row = {"k": "s", "d": src["id"], "p": rel, "n": n, "b": b, "m": mt(last) if last else ""}; row.update(link_for(src, r, rel, True)); rows.append(row)
            ds[:] = []; continue
        for f in sorted(fs):
            if f.startswith(".") or f in ALWAYS_SKIP: continue
            p = os.path.join(r, f)
            try: st = os.stat(p)
            except OSError: continue
            relf = os.path.normpath(os.path.join(rel, f)); ext = os.path.splitext(f)[1].lower()
            row = {"k": "f", "d": src["id"], "p": relf, "b": st.st_size, "m": mt(st.st_mtime)}
            if ext in GOOGLE: row["g"] = GOOGLE[ext]; row["b"] = 0
            row.update(link_for(src, p, relf, False)); rows.append(row)
    return rows, "ok"

def external_volumes():
    """Mounted external drives (not the startup disk, not system volumes, not links)."""
    out = []
    if not os.path.isdir("/Volumes"): return out
    for name in sorted(os.listdir("/Volumes")):
        p = os.path.join("/Volumes", name)
        try:
            if os.path.islink(p) or not os.path.ismount(p): continue
            info = plistlib.loads(subprocess.run(["diskutil", "info", "-plist", p], capture_output=True, timeout=15).stdout)
            if info.get("Internal") is False: out.append({"label": "Drive · " + name, "path": p, "kind": "external-drive"})
        except Exception:
            continue
    return out

def detect(cfg):
    """Places on this Mac that could be sources but aren't registered yet."""
    known = {os.path.realpath(os.path.expanduser(s["root"])) for s in cfg["sources"] if s.get("root")}
    found = []
    cs = os.path.expanduser("~/Library/CloudStorage")
    for d in sorted(os.listdir(cs)) if os.path.isdir(cs) else []:
        p = os.path.join(cs, d)
        if not os.path.isdir(p): continue
        if d.startswith("GoogleDrive-"):
            acct = d.replace("GoogleDrive-", "")
            q = os.path.join(p, "My Drive")
            if os.path.isdir(q) and os.path.realpath(q) not in known: found.append({"label": f"Google Drive · {acct} / My Drive", "path": q, "kind": "google-drive"})
            sd = os.path.join(p, "Shared drives")
            if os.path.isdir(sd):
                for x in sorted(os.listdir(sd)):
                    q = os.path.join(sd, x)
                    if os.path.isdir(q) and os.path.realpath(q) not in known: found.append({"label": f"Google Drive · {acct} / {x}", "path": q, "kind": "google-drive"})
        elif d.startswith("Box") or d.startswith("OneDrive"):
            if os.path.realpath(p) not in known:
                clean = "".join(ch for ch in d if ch.isprintable())
                found.append({"label": ("Box · " if d.startswith("Box") else "OneDrive · ") + clean, "path": p, "kind": "box" if d.startswith("Box") else "onedrive"})
    ic = os.path.expanduser("~/Library/Mobile Documents/com~apple~CloudDocs")
    if os.path.isdir(ic) and os.path.realpath(ic) not in known: found.append({"label": "iCloud Drive", "path": ic, "kind": "icloud"})
    for v in external_volumes():
        if os.path.realpath(v["path"]) not in known: found.append(v)
    home = os.path.expanduser("~")
    return [dict(f, path=f["path"].replace(home, "~")) for f in found]

def load_prev():
    summaries, rows_by_src = {}, {}
    for fn in ("catalogue.json", "catalogue-private.json"):
        try:
            for r in json.load(open(os.path.join(HERE, fn)))["rows"]:
                rows_by_src.setdefault(r["d"], []).append(r)
                if r.get("s"): summaries[(r["d"], r["p"])] = r["s"]
        except Exception: pass
    return summaries, rows_by_src

def page_text():
    sc = CFG.get("schedule", {})
    if not sc.get("enabled"): sched = "Runs when asked"
    else:
        days = sc.get("weekdays")
        sched = (sc.get("frequency", "daily").capitalize() + (" (" + ", ".join(days) + ")" if days else "") + (" at " + sc["time"] if sc.get("time") else ""))
    ans = CFG.get("review", {}).get("answers", "chat")
    hint = {"slack-thread": "Reply in the Slack thread with the number", "answers-file": "Answer in your answers file, or tell Claude in chat"}.get(ans, "Tell Claude the number and where it goes")
    return {"owner": CFG.get("owner", {}).get("name", ""), "schedule_text": sched, "structure_note": " / ".join(STRUCT.get("levels", [])), "areas": [a.get("label", a.get("id")) for a in CFG.get("areas", [])], "answers_hint": hint, "examples": CAT.get("page", {}).get("examples")}

MERGE = "--merge" in sys.argv
prev_sum, prev_rows = load_prev() if MERGE else ({}, {})
pub, priv, meta = [], [], []
for s in CFG["sources"]:
    rows, status = [], "off"
    role = s.get("role", "index")
    if s.get("enabled", True) is False: status = "off"
    elif role == "inbox": status = "tidied, not indexed"
    elif s.get("via", "mac") != "mac": status = "unsupported"
    else:
        vs = volume_state(s)
        if vs == "not-mounted": rows, status = list(prev_rows.get(s["id"], [])), "offline"   # keep what we last saw, so it stays searchable
        elif vs in ("startup-disk", "folder-missing"): status = "missing"
        else: rows, status = index(s)
    for r in rows:
        if (r["d"], r["p"]) in prev_sum: r["s"] = prev_sum[(r["d"], r["p"])]
    (priv if s.get("private") else pub).extend(rows)
    meta.append({"id": s["id"], "root": s.get("root", ""), "label": s.get("label", s["id"]), "kind": s.get("kind", "local"), "account": s.get("account", ""), "business": s.get("area") or s.get("business") or "", "via": s.get("via", "mac"), "role": role, "enabled": s.get("enabled", True) is not False, "private": bool(s.get("private")), "status": status, "entries": len(rows), "files": sum(r.get("n", 1) for r in rows)})
built = time.strftime("%Y-%m-%dT%H:%M:%S%z")
pub_meta = [m if not m["private"] else {k: m[k] for k in ("id", "label", "kind", "business", "enabled", "private", "status", "via", "role")} for m in meta]

def save(name, obj):
    tmp = os.path.join(HERE, name + ".tmp")
    json.dump(obj, open(tmp, "w"), ensure_ascii=False, separators=(",", ":"))
    os.replace(tmp, os.path.join(HERE, name))

save("catalogue.json", {"built": built, "sources": pub_meta, "detected": detect(CFG), "rows": pub})
save("catalogue-private.json", {"built": built, "sources": meta, "rows": priv})
save("page.json", page_text())
for m in meta: print(f"{m['id']:10} {m['status']:20} {m['entries']:6} entries {m['files']:7} files  {m['label']}{'  (private)' if m['private'] else ''}")
print("published rows:", len(pub), " private rows:", len(priv))
