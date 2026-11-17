#!/usr/bin/env python3
"""Test for catalogue.py using throwaway folders. Run: python3 test_catalogue.py   (macOS)"""
import os, sys, json, shutil, tempfile, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
tmp = tempfile.mkdtemp(prefix="catalogue-test-")
home = os.path.join(tmp, "home"); os.makedirs(home)
files = os.path.join(tmp, "files"); secret = os.path.join(tmp, "secret"); inbox = os.path.join(tmp, "inbox")
for d in (files, secret, inbox): os.makedirs(d)
def touch(p, text="x"):
    os.makedirs(os.path.dirname(p), exist_ok=True); open(p, "w").write(text)
touch(os.path.join(files, "Finance", "report.pdf"), "pdf bytes")
touch(os.path.join(files, "skipme", "hidden-by-exclude.txt"))
touch(os.path.join(files, ".DS_Store")); touch(os.path.join(files, ".hidden.txt"))
for i in range(25): touch(os.path.join(files, "Shoot 1", f"IMG_{i:03}.jpg"))          # 25 media files: one bundle
touch(os.path.join(files, "Photos", "A", "B", "C", "one.jpg")); touch(os.path.join(files, "Photos", "A", "B", "C", "two.jpg"))
touch(os.path.join(secret, "secret.txt"), "private")
touch(os.path.join(inbox, "loose.txt"))
cfg = {"version": 1, "owner": {"name": "Test Owner"},
       "areas": [{"id": "x", "label": "Studio"}, {"id": "p", "label": "Personal"}],
       "sources": [
         {"id": "S1", "label": "Files", "kind": "local", "via": "mac", "root": files, "role": "file-into", "area": "Studio", "enabled": True, "private": False, "exclude": ["skipme"]},
         {"id": "S2", "label": "Secret", "kind": "local", "via": "mac", "root": secret, "role": "file-into", "area": "Personal", "enabled": True, "private": True},
         {"id": "IN", "label": "Inbox", "kind": "local", "via": "mac", "root": inbox, "role": "inbox", "enabled": True},
         {"id": "D", "label": "Offline drive", "kind": "external-drive", "via": "mac", "root": "/Volumes/__catalogue_test_not_mounted__", "role": "maintain", "enabled": True, "private": True, "removable": True, "require_mounted": True},
         {"id": "OFF", "label": "Off", "kind": "local", "via": "mac", "root": files, "role": "index", "enabled": False}],
       "structure": {"levels": ["business", "project", "type", "date"], "keep_bundles_whole": True, "bundle_detection": {"min_files": 20, "min_media_share": 0.7}, "bundle_roots": [{"prefix": "Photos", "depth_below": 3}]},
       "schedule": {"enabled": True, "frequency": "daily", "time": "07:15"}, "review": {"answers": "answers-file"},
       "catalogue": {"page": {"examples": ["Where is my latest invoice?"]}}}
json.dump(cfg, open(os.path.join(home, "config.json"), "w"))
# a previous run: a summary to keep, and last-seen rows for the drive that is unplugged now
json.dump({"rows": [{"k": "f", "d": "S1", "p": "Finance/report.pdf", "b": 1, "m": "2026-01-01", "s": "Kept summary"}]}, open(os.path.join(home, "catalogue.json"), "w"))
json.dump({"rows": [{"k": "f", "d": "D", "p": "old/file.txt", "b": 1, "m": "2026-10-01", "s": "Last-seen row"}]}, open(os.path.join(home, "catalogue-private.json"), "w"))

res = []
def check(label, cond, extra=""): res.append(("PASS" if cond else "FAIL") + "  " + label + (("  — " + str(extra)) if extra else ""))
def run(*args):
    p = subprocess.run([sys.executable, os.path.join(HERE, "catalogue.py"), "--home", home, *args], capture_output=True, text=True)
    return p
p = run("--merge"); check("runs", p.returncode == 0, (p.stderr or p.stdout)[-200:])
pub = json.load(open(os.path.join(home, "catalogue.json"))); prv = json.load(open(os.path.join(home, "catalogue-private.json"))); page = json.load(open(os.path.join(home, "page.json")))
paths = {r["p"] for r in pub["rows"]}
check("ordinary file indexed", "Finance/report.pdf" in paths)
check("summary kept with --merge", any(r["p"] == "Finance/report.pdf" and r.get("s") == "Kept summary" for r in pub["rows"]))
check("excluded folder skipped", not any("skipme" in x for x in paths))
check("hidden files skipped", not any(x.startswith(".") or "/." in x for x in paths))
check("25-image folder is one bundle", any(r["k"] == "s" and r["p"] == "Shoot 1" and r["n"] == 25 for r in pub["rows"]), [r["p"] for r in pub["rows"] if r["k"] == "s"])
check("bundle_roots folder is one bundle", any(r["k"] == "s" and r["p"].startswith("Photos") for r in pub["rows"]))
check("private source not in the published catalogue", not any(r["d"] == "S2" for r in pub["rows"]))
check("private source in the private catalogue", any(r["d"] == "S2" and r["p"] == "secret.txt" for r in prv["rows"]))
check("published source list hides private details", all("root" not in m for m in pub["sources"] if m["private"]))
st = {m["id"]: m for m in prv["sources"]}
check("inbox is not indexed", st["IN"]["status"] == "tidied, not indexed" and st["IN"]["entries"] == 0)
check("disabled source is off", st["OFF"]["status"] == "off")
check("unplugged drive: status offline, last-seen rows kept", st["D"]["status"] == "offline" and any(r["p"] == "old/file.txt" and r.get("s") == "Last-seen row" for r in prv["rows"]))
check("page.json from config", page["owner"] == "Test Owner" and page["schedule_text"] == "Daily at 07:15" and page["structure_note"] == "business / project / type / date" and page["areas"] == ["Studio", "Personal"] and page["examples"] == ["Where is my latest invoice?"] and "answers file" in page["answers_hint"], page)
labels = " ".join(d["label"] for d in pub["detected"])
check("detection never offers Dropbox", "dropbox" not in labels.lower(), labels[:200])
check("detection never offers the startup disk or Recovery", not any(("Recovery" in d["label"]) for d in pub["detected"]))
p = run()  # without --merge: nothing kept
prv2 = json.load(open(os.path.join(home, "catalogue-private.json"))); pub2 = json.load(open(os.path.join(home, "catalogue.json")))
check("without --merge, summaries and last-seen rows are not carried", not any(r.get("s") for r in pub2["rows"]) and not any(r["d"] == "D" for r in prv2["rows"]))
shutil.rmtree(tmp, ignore_errors=True)
print("\n".join(res)); sys.exit(1 if any(x.startswith("FAIL") for x in res) else 0)
