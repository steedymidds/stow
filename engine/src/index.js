#!/usr/bin/env node
// Stow MCP server (stdio). Registered in Claude desktop so every Claude session linked to this Mac,
// including the daily organiser, can read, write, summarise and maintain every connected store.
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import fs from "node:fs";
import { listSources, upsertSource, newId, getSource } from "./registry.js";
import { provider, copyAcross, moveAcross, annotate, getAnnotations } from "./stow.js";
import { connectDropbox } from "./providers/dropbox.js";
import { getSecret } from "./keychain.js";
import { expand, logOp, readJSON, writeJSON, STATE_DIR } from "./config.js";
import path from "node:path";

const server = new McpServer({ name: "stow", version: "0.1.0" });
const ok = (data) => ({ content: [{ type: "text", text: JSON.stringify(data, null, 2) }] });
const fail = (e) => ({ isError: true, content: [{ type: "text", text: String(e && e.message ? e.message : e) }] });
const wrap = (fn) => async (args) => { try { return ok(await fn(args)); } catch (e) { return fail(e); } };
const pending = {}; // sign-ins in progress, by source id

const SOURCE = z.string().describe("Source id from stow_sources, e.g. ST, LU, STDBX, DBX");
const PATH = z.string().default("").describe("Path inside the source, relative to its root; empty for the root");

server.tool("stow_sources",
  "List every connected file store (source) with its id, service, account, business, role (file-into / maintain / index), privacy, and whether it's signed in. Call this first.",
  {}, wrap(async () => {
    const out = [];
    for (const s of listSources()) {
      let auth = "n/a";
      if (s.via === "api") auth = (await getSecret(`${s.kind}:${s.id}`)) ? "signed in" : pending[s.id] ? "waiting for approval in the browser" : "not signed in";
      if ((s.via || "mac") === "mac") auth = s.root && fs.existsSync(expand(s.root)) ? "folder present" : "folder missing";
      out.push({ id: s.id, label: s.label, service: s.kind, via: s.via || "mac", account: s.account, business: s.business, role: s.role, private: !!s.private, enabled: s.enabled !== false, auth, root: s.root || "" , protect: s.protect || [] });
    }
    return out;
  }));

server.tool("stow_connect",
  "Connect a new account or re-sign-in an existing one. service 'dropbox' opens Dropbox's approval page in the browser on the Mac (the person approves; no password or token passes through Claude) and registers the account once approved. service 'folder' registers a folder on the Mac (iCloud Drive, a synced Google Drive / Box / OneDrive account, any local folder).",
  {
    service: z.enum(["dropbox", "folder"]),
    id: z.string().optional().describe("Existing source id to re-sign-in, or a new short id"),
    label: z.string().optional().describe("Display name, e.g. 'Dropbox · personal'"),
    business: z.string().optional().describe("Work, Personal or Unassigned"),
    role: z.enum(["index", "file-into", "maintain"]).optional().describe("index = search only; file-into = organiser may file here; maintain = file into and tidy"),
    private: z.boolean().optional().describe("true keeps it off the hosted Stow page (chat only)"),
    root: z.string().optional().describe("folder: the Mac path (~ allowed). dropbox: optional sub-folder of the account to limit Stow to"),
    kind: z.string().optional().describe("folder only: google-drive, dropbox, box, onedrive, icloud or local (sets link style)"),
  },
  wrap(async (a) => {
    if (a.service === "folder") {
      if (!a.root || !fs.existsSync(expand(a.root))) throw new Error(`Folder not found: ${a.root}`);
      const id = a.id || newId("SRC");
      const src = upsertSource({ id, label: a.label || path.basename(expand(a.root)), kind: a.kind || "local", via: "mac", root: a.root, business: a.business || "Unassigned", role: a.role || "index", private: a.private ?? true, enabled: true, exclude: [] });
      logOp({ op: "connect", source: id, service: "folder" });
      return { connected: src };
    }
    const id = a.id || newId("DBX");
    let existing = null; try { existing = getSource(id); } catch {}
    upsertSource({ id, label: a.label || existing?.label || `Dropbox ${id}`, kind: "dropbox", via: "api", business: a.business || existing?.business || "Unassigned", role: a.role || existing?.role || "index", private: a.private ?? existing?.private ?? true, enabled: true, root: a.root ?? existing?.root ?? "", exclude: existing?.exclude || [], account: existing?.account || "signing in…" });
    pending[id] = true;
    const url = await connectDropbox(id, (err, acct) => {
      delete pending[id];
      if (err) { upsertSource({ id, account: `sign-in failed: ${err.message}` }); return; }
      upsertSource({ id, account: `${acct.email}${acct.team ? " · " + acct.team : ""} (${acct.account_type})` });
      logOp({ op: "connect", source: id, service: "dropbox", account: acct.email });
    });
    return { source: id, status: "Dropbox's approval page is open in the browser on the Mac. Approve it while signed into the account you want, then call stow_sources to confirm.", url };
  }));

server.tool("stow_list", "List a folder in a source. recursive walks everything below it; page with next_cursor.",
  { source: SOURCE, path: PATH, recursive: z.boolean().default(false), limit: z.number().int().min(1).max(2000).default(500), cursor: z.string().optional() },
  wrap(async (a) => provider(a.source).list(a.path, a)));

server.tool("stow_search", "Search file and folder names (Dropbox: names and contents) across one or more sources.",
  { query: z.string(), sources: z.array(z.string()).optional().describe("Source ids; default all enabled"), limit: z.number().int().min(1).max(200).default(30) },
  wrap(async (a) => {
    const ids = a.sources?.length ? a.sources : listSources().filter((s) => s.enabled !== false).map((s) => s.id);
    const out = {};
    for (const id of ids) { try { out[id] = await provider(id).search(a.query, { limit: a.limit }); } catch (e) { out[id] = { error: e.message }; } }
    return out;
  }));

server.tool("stow_stat", "Details and web link for one file or folder.", { source: SOURCE, path: z.string() }, wrap(async (a) => provider(a.source).stat(a.path)));

server.tool("stow_read",
  "Read a file's text so you can summarise or interpret it: PDFs, Word, Pages-free docs, Excel, PowerPoint, text, CSV, JSON, HTML. Images and video return a note instead (stage them to look).",
  { source: SOURCE, path: z.string(), max_chars: z.number().int().min(500).max(200000).default(20000) },
  wrap(async (a) => provider(a.source).read(a.path, { maxChars: a.max_chars })));

server.tool("stow_write",
  "Create or replace a file. Give text, base64 content, or from_mac_path (a file already on this Mac). Refuses to overwrite unless overwrite is true. Only works on sources whose role allows writing.",
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
  "Move or rename. Within one source it's a native move. Across sources it's a verified copy (md5 or Dropbox content hash) and then the original goes to its own store's trash.",
  { from_source: SOURCE, from_path: z.string(), to_source: SOURCE, to_path: z.string(), overwrite: z.boolean().default(false) },
  wrap(async (a) => moveAcross(a.from_source, a.from_path, a.to_source, a.to_path, { overwrite: a.overwrite })));

server.tool("stow_copy", "Copy a file within or across sources, verified byte-for-byte.",
  { from_source: SOURCE, from_path: z.string(), to_source: SOURCE, to_path: z.string(), overwrite: z.boolean().default(false) },
  wrap(async (a) => copyAcross(a.from_source, a.from_path, a.to_source, a.to_path, { overwrite: a.overwrite })));

server.tool("stow_trash",
  "Send a file or folder to its store's trash: Mac/Drive folders go to that source's _To Delete, Dropbox uses its recoverable delete. Never a permanent delete.",
  { source: SOURCE, path: z.string() },
  wrap(async (a) => { const r = await provider(a.source).trash(a.path); logOp({ op: "trash", source: a.source, path: a.path, result: r }); return r; }));

server.tool("stow_changes",
  "What changed in a source since the last call. Stow remembers the cursor per source, so the daily run just calls this each time. reset: true starts over.",
  { source: SOURCE, reset: z.boolean().default(false) },
  wrap(async (a) => {
    const f = path.join(STATE_DIR, `cursor-${a.source}.json`);
    const prev = a.reset ? null : readJSON(f, {}).cursor;
    const r = await provider(a.source).changes(prev);
    writeJSON(f, { cursor: r.cursor, at: new Date().toISOString() });
    return { ...r, cursor: undefined, count: r.changes.length };
  }));

server.tool("stow_link", "Web link for a file or folder, where the service has one.", { source: SOURCE, path: z.string() },
  wrap(async (a) => ({ link: await provider(a.source).link(a.path, (await provider(a.source).stat(a.path)).type === "folder") })));

server.tool("stow_annotate",
  "Save your summary and interpretation of a file so search and the Stow page can use it: a one-sentence summary plus whatever you can read from it (document type, date, parties, amount, tags).",
  { source: SOURCE, path: z.string(), summary: z.string().optional(), doc_type: z.string().optional(), date: z.string().optional().describe("The document's own date, YYYY-MM-DD"), parties: z.array(z.string()).optional(), amount: z.string().optional().describe("e.g. '£5,000.00'"), business: z.string().optional(), tags: z.array(z.string()).optional(), notes: z.string().optional() },
  wrap(async (a) => { const { source, path: p, ...f } = a; return annotate(source, p, f); }));

server.tool("stow_annotations", "Read saved summaries and interpretations: one file, one source, or everything.",
  { source: z.string().optional(), path: z.string().optional() }, wrap(async (a) => getAnnotations(a)));

await server.connect(new StdioServerTransport());
