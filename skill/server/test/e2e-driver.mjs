// Stage 5 driver: acts as the skill's engine over the stow-mcp tools, against the throwaway sandbox.
// usage: node test/e2e-driver.mjs dry | apply
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import fs from "node:fs"; import path from "node:path"; import crypto from "node:crypto";
const HOME = path.resolve("../_test/home");
const t = new StdioClientTransport({ command: process.execPath, args: [path.resolve("src/index.js")], env: { ...process.env, STOW_HOME: HOME } });
const c = new Client({ name: "e2e", version: "1" }); await c.connect(t);
const call = async (name, args = {}) => { const r = await c.callTool({ name, arguments: args }); const txt = r.content[0].text; let json; try { json = JSON.parse(txt); } catch {} return { err: !!r.isError, txt, json }; };
const SRCS = ["desk", "dl", "filed", "holding"];
async function listing() {
  const out = [];
  for (const s of SRCS) { const r = await call("stow_list", { source: s, recursive: true }); for (const e of r.json?.entries || []) out.push(`${s}|${e.path}|${e.type}|${e.size ?? ""}|${e.modified ?? ""}`); }
  out.sort(); return { n: out.length, hash: crypto.createHash("sha256").update(out.join("\n")).digest("hex").slice(0, 16) };
}
const day = new Date().toISOString().slice(0, 10);
// the agent's decisions for the fixture (made from reading the files)
const D = (source, p, action, to_source, to_path, reason, question) => ({ source, path: p, action, to_source, to_path, reason, question });
const decisions = [
  D("dl", "inv_scan.txt", "file", "filed", "Work/Invoices/2026/10 - October/2026-10-14 Acme Ltd 1042.txt", "Invoice: supplier, number and date all found in the text"),
  D("dl", "trip-letter.txt", "file", "filed", "Family/Docs/2025/trip-letter.txt", "School letter; no letter date in text (3 Dec is the trip date), so file modified year"),
  D("desk", "harbour-notes.md", "file", "filed", "Work/Docs/2025/harbour-notes.md", "Meeting notes for the Harbour project (Work hint)"),
  D("desk", "data.csv", "review", "holding", `Review/${day}/data.csv`, "Two numbers only; can't tell which area", "Is this Work or Family?"),
  D("dl", "unknown.bin", "review", "holding", `Review/${day}/unknown.bin`, "Binary, unreadable", "What is this?"),
  D("desk", "Shoot", "review", "holding", `Review/${day}/Shoot`, "22 images, no area stated (bundle kept whole)", "Which area is this shoot for?"),
  D("dl", "dup-a.txt", "review", "holding", `Review/${day}/dup-a.txt`, "Kept copy of an exact duplicate; content gives no area", "Which area?"),
  D("dl", "empty.txt", "junk", "holding", `Junk/${day}/empty.txt`, "Zero bytes"),
  D("dl", "old-installer.dmg", "junk", "holding", `Junk/${day}/old-installer.dmg`, "Installer older than 3 days"),
  D("desk", "dup-b.txt", "junk", "holding", `Junk/${day}/dup-b.txt`, "Exact duplicate of dup-a.txt (md5 equal)"),
  D("desk", "just-saved.txt", "skip", null, null, "Modified within 24 hours"),
  D("dl", "film.mov.crdownload", "skip", null, null, "Partial download younger than 2 days"),
];
const ONLY = process.env.ONLY ? process.env.ONLY.split(",") : null; if (ONLY) for (let k = decisions.length - 1; k >= 0; k--) if (!ONLY.includes(decisions[k].path)) decisions.splice(k, 1);
const mode = process.argv[2];
if (mode === "dry") {
  const before = await listing();
  const items = [];
  for (const d of decisions) { const r = await call("stow_stat", { source: d.source, path: d.path }); items.push({ ...d, size: r.json?.size ?? null, modified: r.json?.modified ?? null }); }
  const counts = items.reduce((a, i) => (a[i.action] = (a[i.action] || 0) + 1, a), {});
  fs.writeFileSync(path.join(HOME, "plan.json"), JSON.stringify({ made: new Date().toISOString(), items, new_folders: [], counts }, null, 1));
  fs.mkdirSync(path.join(HOME, "reports"), { recursive: true });
  fs.writeFileSync(path.join(HOME, "reports", `dry-run-${day}.md`), `# Dry run ${day}\n\n${JSON.stringify(counts)}\n\n` + items.map((i) => `- ${i.action}: ${i.source}/${i.path}${i.to_path ? " -> " + i.to_source + "/" + i.to_path : ""} (${i.reason})`).join("\n") + "\n");
  const after = await listing();
  console.log("counts", JSON.stringify(counts));
  console.log("before", JSON.stringify(before), "after", JSON.stringify(after), before.hash === after.hash ? "UNCHANGED" : "CHANGED!!");
} else if (mode === "apply") {
  const plan = JSON.parse(fs.readFileSync(path.join(HOME, "plan.json")));
  for (const i of plan.items) {
    if (i.action === "skip") { console.log("SKIP   ", i.path); continue; }
    const dir = i.to_path.split("/").slice(0, -1).join("/");
    const mk = await call("stow_mkdir", { source: i.to_source, path: dir });
    const args = { from_source: i.source, from_path: i.path, to_source: i.to_source, to_path: i.to_path };
    if (i.size != null) args.expect_size = i.size; if (i.modified) args.expect_modified = i.modified;
    const r = await call("stow_move", args);
    console.log(r.err ? "FAILED " : "MOVED  ", i.action.padEnd(6), i.path, "->", i.to_path, r.err ? "\n         " + r.txt.slice(0, 200) : "");
  }
  console.log("after", JSON.stringify(await listing()));
} else console.log("mode: dry | apply");
await c.close();
