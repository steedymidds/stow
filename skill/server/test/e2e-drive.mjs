// Stage 5e: drive behaviour against a mounted disk image at /Volumes/TestDrive (ExFAT).
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import fs from "node:fs"; import path from "node:path"; import { execSync } from "node:child_process";
const T = path.resolve("../_test"), HOME = path.join(T, "home2"), V = "/Volumes/TestDrive";
fs.rmSync(HOME, { recursive: true, force: true }); fs.mkdirSync(HOME, { recursive: true });
const FILED = path.join(T, "Filed2"); fs.rmSync(FILED, { recursive: true, force: true }); fs.mkdirSync(FILED, { recursive: true });
for (const p of ["loose.txt", "Pics/a.jpg", "Pics/b.jpg", "Docs/old.txt"]) { fs.mkdirSync(path.dirname(path.join(V, p)), { recursive: true }); fs.writeFileSync(path.join(V, p), "content of " + p); }
const mk = (trash) => ({ version: 1, sources: [
  { id: "drive", label: "Test drive", kind: "external-drive", via: "mac", root: V, role: "inbox", enabled: true, removable: true, require_mounted: true, trash, top_level_only: true },
  { id: "filed", label: "Filed2", kind: "local", via: "mac", root: FILED, role: "file-into", enabled: true } ] });
const results = []; const check = (l, c, x = "") => { results.push(`${c ? "PASS" : "FAIL"}  ${l}${x ? "  — " + x : ""}`); };
const start = async () => { const t = new StdioClientTransport({ command: process.execPath, args: [path.resolve("src/index.js")], env: { ...process.env, STOW_HOME: HOME } }); const c = new Client({ name: "d", version: "1" }); await c.connect(t); return c; };
const call = async (c, name, args = {}) => { const r = await c.callTool({ name, arguments: args }); const txt = r.content[0].text; let json; try { json = JSON.parse(txt); } catch {} return { err: !!r.isError, txt, json }; };

// 1. a drive configured with the Mac Bin must be refused by validation
fs.writeFileSync(path.join(HOME, "config.json"), JSON.stringify(mk("mac-bin")));
let c = await start(); let r = await call(c, "stow_validate");
check("validate flags a drive set to mac-bin", (r.json?.problems || []).some((p) => /bin|trash/i.test(p)), JSON.stringify(r.json?.problems).slice(0, 200)); await c.close();

// 2. correct config
fs.writeFileSync(path.join(HOME, "config.json"), JSON.stringify(mk("source")));
c = await start(); r = await call(c, "stow_validate"); check("validate passes with trash: source", r.json?.problems?.length === 0, JSON.stringify(r.json));
r = await call(c, "stow_sources"); check("drive reported connected", /connected|ok/i.test(JSON.stringify(r.json?.find((s) => s.id === "drive")?.state)) && !/not connected/i.test(JSON.stringify(r.json?.find((s) => s.id === "drive")?.state)), JSON.stringify(r.json?.find((s) => s.id === "drive")?.state));
// 3. cross-volume file move (copy, verify, original to the drive's own _To Delete)
r = await call(c, "stow_move", { from_source: "drive", from_path: "loose.txt", to_source: "filed", to_path: "Docs/loose.txt" });
const movedLoose = r.json;
check("file moved off the drive, verified", !r.err && /md5/.test(r.txt), r.txt.slice(0, 200));
check("original kept on the drive in _To Delete (not the Mac Bin)", fs.existsSync(path.join(V, "_To Delete", "Trashed by organiser")) && !fs.existsSync(path.join(V, "loose.txt")), JSON.stringify(r.json?.original));
// 4. cross-volume folder move
r = await call(c, "stow_move", { from_source: "drive", from_path: "Pics", to_source: "filed", to_path: "Pictures/Pics" });
check("folder moved off the drive whole", !r.err && r.json?.files === 2 && fs.existsSync(path.join(FILED, "Pictures", "Pics", "b.jpg")) && !fs.existsSync(path.join(V, "Pics")), r.txt.slice(0, 200));
// 5. a changed file is refused on the drive too
const st = await call(c, "stow_stat", { source: "drive", path: "Docs/old.txt" }); fs.appendFileSync(path.join(V, "Docs", "old.txt"), "!");
r = await call(c, "stow_move", { from_source: "drive", from_path: "Docs/old.txt", to_source: "filed", to_path: "x/old.txt", expect_size: st.json.size });
check("changed file on the drive refused", r.err && /changed since the plan/.test(r.txt) && fs.existsSync(path.join(V, "Docs", "old.txt")), r.txt.slice(0, 120));
check("exFAT keeps modified time on copy", Math.abs(fs.statSync(path.join(FILED, "Docs", "loose.txt")).mtimeMs - fs.statSync(movedLoose.original.to).mtimeMs) < 2500);
await c.close();
fs.writeFileSync(path.join(T, "drive-test-part1.txt"), results.join("\n"));
console.log(results.join("\n"));
