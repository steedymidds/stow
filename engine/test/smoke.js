// End-to-end smoke test: start the server over stdio against two throwaway folders and exercise every tool.
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import fs from "node:fs"; import os from "node:os"; import path from "node:path";
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "stow-test-"));
const A = path.join(tmp, "A"), B = path.join(tmp, "B"), HOME = path.join(tmp, "home");
for (const d of [A, B, HOME]) fs.mkdirSync(d, { recursive: true });
fs.writeFileSync(path.join(A, "invoice.txt"), "Invoice 42 from Acme Ltd, total £120.00, dated 2026-10-01");
fs.mkdirSync(path.join(A, "_Automations — do not move")); fs.writeFileSync(path.join(A, "_Automations — do not move", "keep.txt"), "x");
fs.writeFileSync(path.join(HOME, "sources.json"), JSON.stringify({ version: 1, sources: [
  { id: "A", label: "Store A", kind: "local", via: "mac", root: A, role: "maintain", enabled: true, protect: ["_Automations — do not move"] },
  { id: "B", label: "Store B", kind: "local", via: "mac", root: B, role: "file-into", enabled: true },
  { id: "R", label: "Read only", kind: "local", via: "mac", root: B, role: "index", enabled: true } ] }));
const t = new StdioClientTransport({ command: process.execPath, args: [path.resolve("src/index.js")], env: { ...process.env, STOW_HOME: HOME } });
const c = new Client({ name: "smoke", version: "1" }); await c.connect(t);
const call = async (name, args = {}) => { const r = await c.callTool({ name, arguments: args }); const txt = r.content[0].text; return { err: !!r.isError, txt, json: (() => { try { return JSON.parse(txt); } catch { return null; } })() }; };
const results = []; const check = (label, cond, extra = "") => results.push(`${cond ? "PASS" : "FAIL"}  ${label}${extra ? "  — " + extra : ""}`);
const tools = (await c.listTools()).tools.map((x) => x.name); check("tools registered", tools.length === 15, tools.join(", "));
let r = await call("stow_sources"); check("sources", r.json?.length === 3);
r = await call("stow_list", { source: "A" }); check("list", r.json?.entries?.some((e) => e.name === "invoice.txt"));
r = await call("stow_read", { source: "A", path: "invoice.txt" }); check("read", r.json?.text?.includes("Acme"));
r = await call("stow_mkdir", { source: "B", path: "2026/10" }); check("mkdir", !r.err, r.txt.slice(0, 80));
r = await call("stow_copy", { from_source: "A", from_path: "invoice.txt", to_source: "B", to_path: "2026/10/invoice.txt" }); check("copy across + verify", r.json?.verified === "md5 matches", r.txt.slice(0, 120));
r = await call("stow_copy", { from_source: "A", from_path: "invoice.txt", to_source: "B", to_path: "2026/10/invoice.txt" }); check("refuses overwrite", r.err);
r = await call("stow_write", { source: "R", path: "x.txt", text: "no" }); check("search-only source refuses writes", r.err);
r = await call("stow_trash", { source: "A", path: "_Automations — do not move/keep.txt" }); check("protected folder refuses changes", r.err);
r = await call("stow_write", { source: "A", path: "../escape.txt", text: "no" }); check("path escape refused", r.err);
r = await call("stow_move", { from_source: "A", from_path: "invoice.txt", to_source: "B", to_path: "moved/invoice.txt" }); check("move across = copy + trash original", !r.err && r.json?.original?.trashed === "invoice.txt", r.txt.slice(0, 160));
check("original went to A/_To Delete", fs.existsSync(path.join(A, "_To Delete", "Trashed by Stow")));
r = await call("stow_search", { query: "invoice", sources: ["B"] }); check("search", r.json?.B?.results?.length >= 2);
r = await call("stow_changes", { source: "B" }); check("changes (first call)", r.json?.count >= 1);
r = await call("stow_changes", { source: "B" }); check("changes (second call, nothing new)", r.json?.count === 0);
r = await call("stow_annotate", { source: "B", path: "moved/invoice.txt", summary: "Acme invoice 42", amount: "£120.00", date: "2026-10-01", doc_type: "invoice" }); check("annotate", r.json?.amount === "£120.00");
r = await call("stow_annotations", { source: "B" }); check("annotations read back", !!r.json?.["B:moved/invoice.txt"]);
check("ops logged", fs.readFileSync(path.join(HOME, "log", "stow-ops.log"), "utf8").split("\n").filter(Boolean).length >= 4);
await c.close(); console.log(results.join("\n")); process.exit(results.some((x) => x.startsWith("FAIL")) ? 1 : 0);
