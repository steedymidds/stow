// End-to-end smoke test: start the server over stdio against throwaway folders and exercise every tool.
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import fs from "node:fs"; import os from "node:os"; import path from "node:path";
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "organiser-test-"));
const A = path.join(tmp, "A"), B = path.join(tmp, "B"), INBOX = path.join(tmp, "Inbox"), BINDIR = path.join(tmp, "Bin"), HOME = path.join(tmp, "home");
const NOT_MOUNTED = "/Volumes/__organiser_test_not_mounted__";
for (const d of [A, B, INBOX, BINDIR, HOME]) fs.mkdirSync(d, { recursive: true });
fs.writeFileSync(path.join(A, "invoice.txt"), "Invoice 42 from Acme Ltd, total £120.00, dated 2026-10-01");
fs.mkdirSync(path.join(A, "_Automations — do not move")); fs.writeFileSync(path.join(A, "_Automations — do not move", "keep.txt"), "x");
fs.writeFileSync(path.join(A, "exp.txt"), "first version");
fs.writeFileSync(path.join(INBOX, "note.txt"), "a loose note");
fs.mkdirSync(path.join(INBOX, "Filed"));
fs.writeFileSync(path.join(HOME, "config.json"), JSON.stringify({ version: 1, sources: [
  { id: "A", label: "Store A", kind: "local", via: "mac", root: A, role: "maintain", enabled: true, protect: ["_Automations — do not move"] },
  { id: "B", label: "Store B", kind: "local", via: "mac", root: B, role: "file-into", enabled: true },
  { id: "R", label: "Read only", kind: "local", via: "mac", root: B, role: "index", enabled: true },
  { id: "IN", label: "Inbox", kind: "local", via: "mac", root: INBOX, role: "inbox", enabled: true, trash: "mac-bin" },
  { id: "IN2", label: "Filed", kind: "local", via: "mac", root: path.join(INBOX, "Filed"), role: "file-into", enabled: true },
  { id: "D", label: "Offline drive", kind: "external-drive", via: "mac", root: NOT_MOUNTED, role: "maintain", enabled: true, removable: true, require_mounted: true, trash: "source" } ] }));
const t = new StdioClientTransport({ command: process.execPath, args: [path.resolve("src/index.js")], env: { ...process.env, STOW_HOME: HOME, STOW_BIN: BINDIR } });
const c = new Client({ name: "smoke", version: "1" }); await c.connect(t);
const call = async (name, args = {}) => { const r = await c.callTool({ name, arguments: args }); const txt = r.content[0].text; return { err: !!r.isError, txt, json: (() => { try { return JSON.parse(txt); } catch { return null; } })() }; };
const results = []; const check = (label, cond, extra = "") => results.push(`${cond ? "PASS" : "FAIL"}  ${label}${extra ? "  — " + extra : ""}`);
const tools = (await c.listTools()).tools.map((x) => x.name); check("tools registered", tools.length === 16, tools.join(", "));
check("no Dropbox tools or text in tool list", !/dropbox/i.test(JSON.stringify((await c.listTools()).tools)));
let r = await call("stow_sources"); check("sources", r.json?.length === 6);
check("offline drive reported as not connected", r.json?.find((s) => s.id === "D")?.state === "drive not connected");
r = await call("stow_list", { source: "A" }); check("list", r.json?.entries?.some((e) => e.name === "invoice.txt"));
r = await call("stow_read", { source: "A", path: "invoice.txt" }); check("read", r.json?.text?.includes("Acme"));
r = await call("stow_mkdir", { source: "B", path: "2026/10" }); check("mkdir", !r.err, r.txt.slice(0, 80));
r = await call("stow_copy", { from_source: "A", from_path: "invoice.txt", to_source: "B", to_path: "2026/10/invoice.txt" }); check("copy across + verify", r.json?.verified === "md5 matches", r.txt.slice(0, 120));
r = await call("stow_copy", { from_source: "A", from_path: "invoice.txt", to_source: "B", to_path: "2026/10/invoice.txt" }); check("refuses overwrite", r.err);
r = await call("stow_write", { source: "R", path: "x.txt", text: "no" }); check("search-only source refuses writes", r.err);
r = await call("stow_trash", { source: "A", path: "_Automations — do not move/keep.txt" }); check("protected folder refuses changes", r.err);
r = await call("stow_write", { source: "A", path: "../escape.txt", text: "no" }); check("path escape refused", r.err);
r = await call("stow_move", { from_source: "A", from_path: "invoice.txt", to_source: "B", to_path: "moved/invoice.txt" }); check("move across = copy + trash original", !r.err && r.json?.original?.trashed === "invoice.txt", r.txt.slice(0, 160));
check("original went to A/_To Delete (source policy)", fs.existsSync(path.join(A, "_To Delete", "Trashed by organiser")));
// inbox role
r = await call("stow_write", { source: "IN", path: "x.txt", text: "no" }); check("inbox refuses filing into it", r.err);
r = await call("stow_move", { from_source: "IN", from_path: "note.txt", to_source: "B", to_path: "notes/note.txt" }); check("inbox item moved out, verified", !r.err && r.json?.verified === "md5 matches", r.txt.slice(0, 160));
check("inbox original went to the Mac Bin (mac-bin policy)", fs.existsSync(path.join(BINDIR, "note.txt")) && !fs.existsSync(path.join(INBOX, "note.txt")));
// external drive that isn't plugged in
r = await call("stow_list", { source: "D" }); check("unplugged drive: list refused", r.err && /isn't connected/.test(r.txt), r.txt.slice(0, 100));
r = await call("stow_mkdir", { source: "D", path: "x" }); check("unplugged drive: write refused", r.err && /isn't connected/.test(r.txt));
check("nothing was created at the unplugged drive's path", !fs.existsSync(NOT_MOUNTED));
r = await call("stow_connect", { id: "D2", kind: "external-drive", root: NOT_MOUNTED, role: "maintain" }); check("connect refuses an unplugged drive", r.err && /isn't connected/.test(r.txt));
r = await call("stow_connect", { id: "D2", kind: "external-drive", root: "/", role: "maintain" }); check("connect refuses the startup disk", r.err);
// validation
r = await call("stow_validate"); check("validate: inbox containing another source is a problem", r.json?.problems?.some((p) => /Exclude "Filed"/.test(p)), JSON.stringify(r.json?.problems));
check("validate: unplugged drive is a warning", r.json?.warnings?.some((p) => /isn't connected/.test(p)));
r = await call("stow_connect", { id: "IN", root: INBOX, role: "inbox", exclude: ["Filed"] }); check("connect updates a source", !r.err && r.json?.connected?.exclude?.[0] === "Filed");
r = await call("stow_validate"); check("validate: clean after excluding it", r.json?.problems?.length === 0, JSON.stringify(r.json?.problems));
// frozen-plan checks
r = await call("stow_stat", { source: "A", path: "exp.txt" }); const planned = { size: r.json?.size, modified: r.json?.modified };
fs.appendFileSync(path.join(A, "exp.txt"), " + a late edit");
r = await call("stow_move", { from_source: "A", from_path: "exp.txt", to_source: "B", to_path: "late/exp.txt", expect_size: planned.size, expect_modified: planned.modified }); check("changed file refused when it no longer matches the plan", r.err && /changed since the plan/.test(r.txt), r.txt.slice(0, 120));
check("changed file stayed where it was", fs.existsSync(path.join(A, "exp.txt")));
r = await call("stow_stat", { source: "A", path: "exp.txt" });
r = await call("stow_move", { from_source: "A", from_path: "exp.txt", to_source: "B", to_path: "late/exp.txt", expect_size: r.json.size, expect_modified: r.json.modified }); check("unchanged file moves when it matches", !r.err);
// the rest
r = await call("stow_search", { query: "invoice", sources: ["B"] }); check("search", r.json?.B?.results?.length >= 2);
r = await call("stow_changes", { source: "B" }); check("changes (first call)", r.json?.count >= 1);
r = await call("stow_changes", { source: "B" }); check("changes (second call, nothing new)", r.json?.count === 0);
r = await call("stow_annotate", { source: "B", path: "moved/invoice.txt", summary: "Acme invoice 42", amount: "£120.00", date: "2026-10-01", doc_type: "invoice" }); check("annotate", r.json?.amount === "£120.00");
r = await call("stow_annotations", { source: "B" }); check("annotations read back", !!r.json?.["B:moved/invoice.txt"]);
// folders (bundles) move whole across sources
fs.mkdirSync(path.join(INBOX, "Bundle", "sub"), { recursive: true });
for (let i = 0; i < 5; i++) fs.writeFileSync(path.join(INBOX, "Bundle", i % 2 ? "sub" : "", `f${i}.jpg`), "data" + i);
r = await call("stow_move", { from_source: "IN", from_path: "Bundle", to_source: "B", to_path: "bundles/Bundle" });
check("folder moves whole across sources, all files verified", !r.err && r.json?.files === 5 && /md5 matches/.test(r.json?.verified || ""), r.txt.slice(0, 160));
check("folder arrived with its subfolder and the original left the inbox", fs.existsSync(path.join(B, "bundles", "Bundle", "sub", "f1.jpg")) && !fs.existsSync(path.join(INBOX, "Bundle")));
fs.mkdirSync(path.join(INBOX, "Bundle")); fs.writeFileSync(path.join(INBOX, "Bundle", "x.jpg"), "x");
r = await call("stow_move", { from_source: "IN", from_path: "Bundle", to_source: "B", to_path: "bundles/Bundle" });
check("folder move refuses an existing destination and leaves the original", r.err && fs.existsSync(path.join(INBOX, "Bundle", "x.jpg")), r.txt.slice(0, 120));
check("ops logged", fs.readFileSync(path.join(HOME, "log", "ops.log"), "utf8").split("\n").filter(Boolean).length >= 4);
await c.close(); console.log(results.join("\n")); process.exit(results.some((x) => x.startsWith("FAIL")) ? 1 : 0);
