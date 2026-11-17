#!/usr/bin/env node
// MCP server (stdio). Registered in Claude desktop so every Claude session linked to this Mac,
// including the scheduled organiser run, can read, write, summarise and maintain the connected folders.
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import fs from "node:fs";
import path from "node:path";
import { listSources, upsertSource, newId, validateSources, ROLES } from "./registry.js";
import { provider, copyAcross, moveAcross, annotate, getAnnotations } from "./stow.js";
import { volumeState } from "./providers/local.js";
import { expand, logOp, readJSON, writeJSON, STATE_DIR } from "./config.js";

const server = new McpServer({ name: "stow", version: "0.2.0" });
const ok = (data) => ({ content: [{ type: "text", text: JSON.stringify(data, null, 2) }] });
const fail = (e) => ({ isError: true, content: [{ type: "text", text: String(e && e.message ? e.message : e) }] });
const wrap = (fn) => async (args) => { try { return ok(await fn(args)); } catch (e) { return fail(e); } };

const SOURCE = z.string().describe("Source id from stow_sources");
const PATH = z.string().default("").describe("Path inside the source, relative to its root; empty for the root");
const EXPECT = {
  expect_size: z.number().int().optional().describe("Refuse if the file's size is no longer this (use the size from the plan)"),
  expect_modified: z.string().optional().describe("Refuse if the file's modified time is no longer this ISO time (use the value from stow_list)"),
};
async function checkExpect(source, p, a) {
  if (a.expect_size === undefined && !a.expect_modified) return;
  const e = await provider(source).stat(p);
  if (a.expect_size !== undefined && e.size !== a.expect_size) throw new Error(`"${p}" has changed since the plan was made (size is ${e.size}, expected ${a.expect_size}). Nothing was moved.`);
  if (a.expect_modified && e.modified !== a.expect_modified) throw new Error(`"${p}" has changed since the plan was made (modified ${e.modified}, expected ${a.expect_modified}). Nothing was moved.`);
}

server.tool("stow_sources",
  "List every connected folder (source) with its id, kind, account, area, role (index / inbox / file-into / maintain), privacy, trash policy and state (including whether an external drive is connected). Call this first.",
  {}, wrap(async () => listSources().map((s) => {
    const vs = volumeState(s);
    const state = vs === "n/a"
      ? (s.root && fs.existsSync(expand(s.root)) ? "folder present" : "folder missing")
      : { ok: "drive connected", "not-mounted": "drive not connected", "startup-disk": "points at the startup disk", "folder-missing": "folder missing on the drive" }[vs];
    return { id: s.id, label: s.label, kind: s.kind, account: s.account, area: s.area ?? s.business ?? null, role: s.role, private: !!s.private, enabled: s.enabled !== false, state, root: s.root || "", exclude: s.exclude || [], protect: s.protect || [], trash: s.trash || (s.role === "inbox" ? "mac-bin" : "source"), removable: !!s.removable, temporary: !!s.temporary };
  })));

server.tool("stow_connect",
  "Register a folder on this Mac as a source, or update one by id. kind: google-drive, icloud, box, onedrive, local or external-drive (an external drive must be plugged in; its trash is always its own _To Delete folder). role: index = search only; inbox = a folder being tidied, items are moved out of it; file-into = the organiser may file here; maintain = file into it and tidy it in place. Returns the source plus any problems found with the whole source list.",
  {
    id: z.string().optional().describe("Existing source id to update, or a new short id"),
    label: z.string().optional().describe("Display name, e.g. 'Work Drive'"),
    area: z.string().optional().describe("The area this source belongs to (a business, a client, 'Personal'); omit if it spans several"),
    role: z.enum(ROLES).optional(),
    private: z.boolean().optional().describe("true keeps it off the published page (chat only)"),
    root: z.string().optional().describe("The folder's path on the Mac (~ allowed)"),
    kind: z.string().optional(),
    trash: z.enum(["mac-bin", "source"]).optional().describe("Where originals go when removed: the Mac Bin, or this source's own _To Delete folder"),
    exclude: z.array(z.string()).optional().describe("Folder names or relative paths to leave out"),
    protect: z.array(z.string()).optional().describe("Relative paths nothing may change inside"),
    temporary: z.boolean().optional().describe("true: a one-off source to remove again after this run"),
    allow_offline: z.boolean().optional().describe("external-drive only: save it even though it isn't plugged in right now"),
  },
  wrap(async (a) => {
    if (!a.root && !a.id) throw new Error("Give the folder's path.");
    let existing = null; try { existing = listSources().find((s) => s.id === a.id) || null; } catch {}
    const root = a.root ?? existing?.root;
    if (!root) throw new Error("Give the folder's path.");
    const kind = a.kind ?? existing?.kind ?? "local";
    const external = kind === "external-drive";
    const vs = volumeState({ root, kind });
    if (external && vs !== "ok" && !a.allow_offline) throw new Error(vs === "startup-disk" ? "That path is the startup disk, not a drive." : "That drive isn't connected. Plug it in first.");
    if (!external && !fs.existsSync(expand(root))) throw new Error(`Folder not found: ${root}`);
    const role = a.role ?? existing?.role ?? "index";
    const id = a.id || newId("SRC");
    const src = upsertSource({
      id, label: a.label ?? existing?.label ?? path.basename(expand(root)), kind, via: "mac", root,
      area: a.area ?? existing?.area ?? null, role, private: a.private ?? existing?.private ?? true, enabled: true,
      exclude: a.exclude ?? existing?.exclude ?? [], protect: a.protect ?? existing?.protect ?? [],
      trash: a.trash ?? existing?.trash ?? (external ? "source" : role === "inbox" ? "mac-bin" : "source"),
      ...(external ? { removable: true, require_mounted: true, on_unmounted: "skip-and-report" } : {}),
      ...(a.temporary ? { temporary: true } : {}),
    });
    logOp({ op: "connect", source: id, kind });
    return { connected: src, ...validateSources() };
  }));

server.tool("stow_validate",
  "Check the whole source list for problems (must fix) and warnings (worth knowing): missing folders, a tidied folder that contains another source, a drive that isn't connected, a drive set to use the Mac Bin. Call it after any change to sources and before the first run.",
  {}, wrap(async () => validateSources()));

server.tool("stow_list", "List a folder in a source. recursive walks everything below it; page with next_cursor.",
  { source: SOURCE, path: PATH, recursive: z.boolean().default(false), limit: z.number().int().min(1).max(2000).default(500), cursor: z.string().optional() },
  wrap(async (a) => provider(a.source).list(a.path, a)));

server.tool("stow_search", "Search file and folder names across one or more sources.",
  { query: z.string(), sources: z.array(z.string()).optional().describe("Source ids; default all enabled"), limit: z.number().int().min(1).max(200).default(30) },
  wrap(async (a) => {
    const ids = a.sources?.length ? a.sources : listSources().filter((s) => s.enabled !== false).map((s) => s.id);
    const out = {};
    for (const id of ids) { try { out[id] = await provider(id).search(a.query, { limit: a.limit }); } catch (e) { out[id] = { error: e.message }; } }
    return out;
  }));

server.tool("stow_stat", "Details and web link for one file or folder.", { source: SOURCE, path: z.string() }, wrap(async (a) => provider(a.source).stat(a.path)));

server.tool("stow_read",
  "Read a file's text so you can summarise or interpret it: PDFs, Word, Excel, PowerPoint, text, CSV, JSON, HTML. Images and video return a note instead (stage them to look).",
  { source: SOURCE, path: z.string(), max_chars: z.number().int().min(500).max(200000).default(20000) },
  wrap(async (a) => provider(a.source).read(a.path, { maxChars: a.max_chars })));

server.tool("stow_write",
  "Create or replace a file. Give text, base64 content, or from_mac_path (a file already on this Mac). Refuses to overwrite unless overwrite is true. Only works on sources whose role allows filing into them (file-into or maintain).",
  { source: SOURCE, path: z.string(), text: z.string().optional(), base64: z.string().optional(), from_mac_path: z.string().optional(), overwrite: z.boolean().default(false) },
  wrap(async (a) => {
    const opts = { overwrite: a.overwrite };
    if (a.from_mac_path) opts.fromFile = expand(a.from_mac_path);
    else if (a.base64) opts.buffer = Buffer.from(a.base64, "base64");
    else if (a.text !== undefined) opts.buffer = Buffer.from(a.text, "utf8");
    else throw new Error("Give text, base64 or from_mac_path.");
    const e = await provider(a.source).write(a.path, opts);
    logOp({ op: "write", source: a.source, path: a.path, overwrite: a.overwrite });
    return e;
  }));

server.tool("stow_mkdir", "Create a folder (and any missing parents).", { source: SOURCE, path: z.string() },
  wrap(async (a) => { const e = await provider(a.source).mkdir(a.path); logOp({ op: "mkdir", source: a.source, path: a.path }); return e; }));

server.tool("stow_move",
  "Move or rename. Within one source it's a native move. Across sources it's a verified copy (md5) and then the original goes to its own source's trash. Pass expect_size / expect_modified from an approved plan to refuse if the file has changed since.",
  { from_source: SOURCE, from_path: z.string(), to_source: SOURCE, to_path: z.string(), overwrite: z.boolean().default(false), ...EXPECT },
  wrap(async (a) => { await checkExpect(a.from_source, a.from_path, a); return moveAcross(a.from_source, a.from_path, a.to_source, a.to_path, { overwrite: a.overwrite }); }));

server.tool("stow_copy", "Copy a file within or across sources, verified byte-for-byte.",
  { from_source: SOURCE, from_path: z.string(), to_source: SOURCE, to_path: z.string(), overwrite: z.boolean().default(false), ...EXPECT },
  wrap(async (a) => { await checkExpect(a.from_source, a.from_path, a); return copyAcross(a.from_source, a.from_path, a.to_source, a.to_path, { overwrite: a.overwrite }); }));

server.tool("stow_trash",
  "Send a file or folder to its source's trash: the Mac Bin for sources set to mac-bin, otherwise that source's own _To Delete folder. Never a permanent delete.",
  { source: SOURCE, path: z.string() },
  wrap(async (a) => { const r = await provider(a.source).trash(a.path); logOp({ op: "trash", source: a.source, path: a.path, result: r }); return r; }));

server.tool("stow_changes",
  "What changed in a source since the last call. The cursor is kept per source, so a daily run just calls this each time. reset: true starts over.",
  { source: SOURCE, reset: z.boolean().default(false) },
  wrap(async (a) => {
    const f = path.join(STATE_DIR, `cursor-${a.source}.json`);
    const prev = a.reset ? null : readJSON(f, {}).cursor;
    const r = await provider(a.source).changes(prev);
    writeJSON(f, { cursor: r.cursor, at: new Date().toISOString() });
    return { ...r, cursor: undefined, count: r.changes.length };
  }));

server.tool("stow_link", "Web link for a file or folder, where the service has one.", { source: SOURCE, path: z.string() },
  wrap(async (a) => ({ link: await provider(a.source).link(a.path) })));

server.tool("stow_annotate",
  "Save your summary and interpretation of a file so search and the file-finder page can use it: a one-sentence summary plus whatever you can read from it (document type, date, parties, amount, tags).",
  { source: SOURCE, path: z.string(), summary: z.string().optional(), doc_type: z.string().optional(), date: z.string().optional().describe("The document's own date, YYYY-MM-DD"), parties: z.array(z.string()).optional(), amount: z.string().optional().describe("As written in the document, e.g. '£5,000.00'"), area: z.string().optional(), tags: z.array(z.string()).optional(), notes: z.string().optional() },
  wrap(async (a) => { const { source, path: p, ...f } = a; return annotate(source, p, f); }));

server.tool("stow_annotations", "Read saved summaries and interpretations: one file, one source, or everything.",
  { source: z.string().optional(), path: z.string().optional() }, wrap(async (a) => getAnnotations(a)));

await server.connect(new StdioServerTransport());
