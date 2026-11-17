// Dropbox through its HTTP API. One source per account; each account's refresh token lives in the
// Keychain as "dropbox:<source id>". Read and write; "trash" uses Dropbox's own recoverable delete.
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { config, TMP_DIR } from "../config.js";
import { getSecret, setSecret } from "../keychain.js";
import { extractText } from "../extract.js";
import { pkce, waitForCode, openInBrowser, REDIRECT_URI } from "../oauth.js";

const RPC = "https://api.dropboxapi.com/2/";
const CONTENT = "https://content.dropboxapi.com/2/";
const TOKEN_URL = "https://api.dropboxapi.com/oauth2/token";
const CHUNK = 64 * 1024 * 1024; // upload sessions for anything over this
// Dropbox-API-Arg must be ASCII: escape everything else as \uXXXX.
const apiArg = (o) => JSON.stringify(o).replace(/[\u007f-￿]/g, (c) => "\\u" + c.charCodeAt(0).toString(16).padStart(4, "0"));

export function appKey() {
  const k = config().dropbox_app_key;
  if (!k) throw new Error("No Dropbox app key yet. Add \"dropbox_app_key\" to stow-config.json in the Stow home (see SETUP.md).");
  return k;
}

// Start sign-in for a new or existing Dropbox source. Resolves when the person approves.
export async function connectDropbox(sourceId, onDone) {
  const { verifier, challenge, state } = pkce();
  const params = new URLSearchParams({ client_id: appKey(), response_type: "code", token_access_type: "offline", code_challenge: challenge, code_challenge_method: "S256", redirect_uri: REDIRECT_URI, state, force_reapprove: "true" });
  const url = "https://www.dropbox.com/oauth2/authorize?" + params;
  const codeP = waitForCode(state);
  openInBrowser(url);
  codeP.then(async (code) => {
    const body = new URLSearchParams({ code, grant_type: "authorization_code", client_id: appKey(), code_verifier: verifier, redirect_uri: REDIRECT_URI });
    const r = await fetch(TOKEN_URL, { method: "POST", body });
    const j = await r.json();
    if (!r.ok || !j.refresh_token) throw new Error(j.error_description || j.error || `Token exchange failed (${r.status})`);
    await setSecret(`dropbox:${sourceId}`, j.refresh_token);
    const p = new DropboxProvider({ id: sourceId, kind: "dropbox", via: "api" });
    const acct = await p.account();
    onDone && onDone(null, acct);
  }).catch((e) => onDone && onDone(e));
  return url;
}

export class DropboxProvider {
  constructor(src) {
    this.src = src;
    this.base = (src.root || "").replace(/\/+$/, ""); // optional sub-folder of the account, e.g. "/Work"
    this.protect = new Set(src.protect || []);
    this.access = null; this.expires = 0;
  }
  async token() {
    if (this.access && Date.now() < this.expires - 60000) return this.access;
    const refresh = await getSecret(`dropbox:${this.src.id}`);
    if (!refresh) throw new Error(`${this.src.label || this.src.id} isn't signed in. Run stow_connect for it.`);
    const r = await fetch(TOKEN_URL, { method: "POST", body: new URLSearchParams({ grant_type: "refresh_token", refresh_token: refresh, client_id: appKey() }) });
    const j = await r.json();
    if (!r.ok) throw new Error(`Dropbox sign-in has expired or was revoked (${j.error_description || j.error}). Run stow_connect again.`);
    this.access = j.access_token; this.expires = Date.now() + (j.expires_in || 14400) * 1000;
    return this.access;
  }
  dbx(rel = "") {
    const clean = String(rel || "").replace(/^\/+|\/+$/g, "");
    if (clean.split("/").includes("..")) throw new Error("Paths can't contain '..'.");
    const p = [this.base, clean].filter(Boolean).join("/");
    return p ? "/" + p.replace(/^\/+/, "") : "";
  }
  rel(dbxPath) {
    const b = this.base ? "/" + this.base.replace(/^\/+/, "") : "";
    let p = dbxPath; if (b && p.toLowerCase().startsWith(b.toLowerCase())) p = p.slice(b.length);
    return p.replace(/^\/+/, "");
  }
  guardWrite(rel) {
    for (const p of this.protect) if (rel === p || rel.startsWith(p + "/")) throw new Error(`"${p}" is protected in ${this.src.label}.`);
    if (this.src.role !== "file-into" && this.src.role !== "maintain") throw new Error(`${this.src.label} is search-only. Change its role to write here.`);
  }
  async rpc(endpoint, body) {
    for (let attempt = 0; attempt < 4; attempt++) {
      const r = await fetch(RPC + endpoint, { method: "POST", headers: { authorization: "Bearer " + (await this.token()), "content-type": "application/json" }, body: body === undefined ? "null" : JSON.stringify(body) });
      if (r.status === 429) { await new Promise((s) => setTimeout(s, (Number(r.headers.get("retry-after")) || 2) * 1000)); continue; }
      const text = await r.text(); let j; try { j = JSON.parse(text); } catch { j = { error_summary: text }; }
      if (!r.ok) { const err = new Error(`Dropbox ${endpoint}: ${j.error_summary || r.status}`); err.dropbox = j; throw err; }
      return j;
    }
    throw new Error(`Dropbox ${endpoint}: rate limited`);
  }
  entry(m) {
    return { path: this.rel(m.path_display || m.path_lower || ""), name: m.name, type: m[".tag"] === "folder" ? "folder" : "file", size: m.size, modified: m.server_modified || m.client_modified, id: m.id, content_hash: m.content_hash };
  }
  async account() {
    const a = await this.rpc("users/get_current_account");
    return { email: a.email, name: a.name && a.name.display_name, account_type: a.account_type && a.account_type[".tag"], team: a.team ? a.team.name : null };
  }
  async list(rel = "", { recursive = false, limit = 500, cursor } = {}) {
    let j = cursor ? await this.rpc("files/list_folder/continue", { cursor }) : await this.rpc("files/list_folder", { path: this.dbx(rel), recursive, include_deleted: false, limit: Math.min(2000, limit) });
    const out = j.entries.filter((e) => e[".tag"] !== "deleted").map((e) => this.entry(e));
    return { entries: out, next_cursor: j.has_more ? j.cursor : null };
  }
  async stat(rel) { const m = await this.rpc("files/get_metadata", { path: this.dbx(rel) }); const e = this.entry(m); e.link = await this.link(rel, e.type === "folder"); return e; }
  async localFile(rel) {
    const dst = path.join(TMP_DIR, crypto.randomBytes(6).toString("hex") + "-" + path.basename(rel));
    const r = await fetch(CONTENT + "files/download", { method: "POST", headers: { authorization: "Bearer " + (await this.token()), "Dropbox-API-Arg": apiArg({ path: this.dbx(rel) }) } });
    if (!r.ok) throw new Error(`Dropbox download failed: ${await r.text()}`);
    const ws = fs.createWriteStream(dst);
    for await (const chunk of r.body) ws.write(chunk);
    await new Promise((res) => ws.end(res));
    return dst;
  }
  async read(rel, opts) { const f = await this.localFile(rel); try { return await extractText(f, opts); } finally { fs.rm(f, () => {}); } }
  async mkdir(rel) { this.guardWrite(rel); const j = await this.rpc("files/create_folder_v2", { path: this.dbx(rel), autorename: false }); return this.entry(j.metadata); }
  async write(rel, { buffer, fromFile, overwrite = false }) {
    this.guardWrite(rel);
    const mode = overwrite ? { ".tag": "overwrite" } : { ".tag": "add" };
    const data = fromFile ? null : buffer; const size = fromFile ? fs.statSync(fromFile).size : buffer.length;
    const auth = async () => ({ authorization: "Bearer " + (await this.token()), "content-type": "application/octet-stream" });
    if (size <= CHUNK) {
      const body = data || fs.readFileSync(fromFile);
      const r = await fetch(CONTENT + "files/upload", { method: "POST", headers: { ...(await auth()), "Dropbox-API-Arg": apiArg({ path: this.dbx(rel), mode, autorename: false, mute: true }) }, body });
      const j = await r.json(); if (!r.ok) throw new Error(`Dropbox upload failed: ${j.error_summary || r.status}`);
      return this.entry(j);
    }
    // Large file: upload session in 64 MB chunks.
    const fd = fs.openSync(fromFile, "r"); let offset = 0, session;
    try {
      while (offset < size) {
        const n = Math.min(CHUNK, size - offset); const buf = Buffer.alloc(n); fs.readSync(fd, buf, 0, n, offset);
        if (!session) {
          const r = await fetch(CONTENT + "files/upload_session/start", { method: "POST", headers: { ...(await auth()), "Dropbox-API-Arg": apiArg({ close: false }) }, body: buf });
          session = (await r.json()).session_id;
        } else if (offset + n < size) {
          await fetch(CONTENT + "files/upload_session/append_v2", { method: "POST", headers: { ...(await auth()), "Dropbox-API-Arg": apiArg({ cursor: { session_id: session, offset }, close: false }) }, body: buf });
        } else {
          const r = await fetch(CONTENT + "files/upload_session/finish", { method: "POST", headers: { ...(await auth()), "Dropbox-API-Arg": apiArg({ cursor: { session_id: session, offset }, commit: { path: this.dbx(rel), mode, autorename: false, mute: true } }) }, body: buf });
          const j = await r.json(); if (!r.ok) throw new Error(`Dropbox upload failed: ${j.error_summary || r.status}`);
          return this.entry(j);
        }
        offset += n;
      }
      // a file that fit exactly in whole chunks: finish with an empty body
      const r = await fetch(CONTENT + "files/upload_session/finish", { method: "POST", headers: { ...(await auth()), "Dropbox-API-Arg": apiArg({ cursor: { session_id: session, offset }, commit: { path: this.dbx(rel), mode, autorename: false, mute: true } }) }, body: Buffer.alloc(0) });
      const j = await r.json(); if (!r.ok) throw new Error(`Dropbox upload failed: ${j.error_summary || r.status}`);
      return this.entry(j);
    } finally { fs.closeSync(fd); }
  }
  async move(from, to) { this.guardWrite(from); this.guardWrite(to); const j = await this.rpc("files/move_v2", { from_path: this.dbx(from), to_path: this.dbx(to), autorename: false }); return this.entry(j.metadata); }
  async copyWithin(from, to) { this.guardWrite(to); const j = await this.rpc("files/copy_v2", { from_path: this.dbx(from), to_path: this.dbx(to), autorename: false }); return this.entry(j.metadata); }
  // Dropbox's delete is recoverable from the web (Deleted files) for the account's retention period.
  async trash(rel) { this.guardWrite(rel); const j = await this.rpc("files/delete_v2", { path: this.dbx(rel) }); return { trashed: rel, recoverable: "Dropbox web → Deleted files" , id: j.metadata && j.metadata.id }; }
  async changes(cursor) {
    if (!cursor) { const j = await this.rpc("files/list_folder/get_latest_cursor", { path: this.dbx(""), recursive: true, include_deleted: true }); return { changes: [], cursor: j.cursor, note: "Baseline set; changes are reported from now on." }; }
    const out = []; let j = await this.rpc("files/list_folder/continue", { cursor });
    for (;;) { for (const e of j.entries) out.push(e[".tag"] === "deleted" ? { path: this.rel(e.path_display), deleted: true } : this.entry(e)); if (!j.has_more || out.length > 20000) break; j = await this.rpc("files/list_folder/continue", { cursor: j.cursor }); }
    return { changes: out, cursor: j.cursor };
  }
  async search(query, { limit = 50 } = {}) {
    const j = await this.rpc("files/search_v2", { query, options: { path: this.dbx("") || undefined, max_results: Math.min(1000, limit), file_status: "active", filename_only: false } });
    return { results: j.matches.map((m) => this.entry(m.metadata.metadata)), complete: !j.has_more };
  }
  async link(rel, isDir) {
    const p = this.dbx(rel); const dir = isDir ? p : path.posix.dirname(p);
    return "https://www.dropbox.com/home" + encodeURI(dir === "/" ? "" : dir) + (isDir ? "" : "?preview=" + encodeURIComponent(path.posix.basename(p)));
  }
  async md5() { return null; }
  async contentHash(rel) { return (await this.stat(rel)).content_hash; }
}

// Dropbox's content hash, computed locally, to verify uploads and downloads byte-for-byte.
export function dropboxContentHash(file) {
  const BLOCK = 4 * 1024 * 1024; const fd = fs.openSync(file, "r"); const outer = crypto.createHash("sha256"); const buf = Buffer.alloc(BLOCK);
  try { for (;;) { const n = fs.readSync(fd, buf, 0, BLOCK, null); if (!n) break; outer.update(crypto.createHash("sha256").update(buf.subarray(0, n)).digest()); } }
  finally { fs.closeSync(fd); }
  return outer.digest("hex");
}
