// Mac folders: iCloud Drive, Documents, and every provider's synced folder under
// ~/Library/CloudStorage (Google Drive, Dropbox, Box, OneDrive). Read and write.
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { expand, tilde } from "../config.js";
import { extractText } from "../extract.js";
const run = promisify(execFile);

const ALWAYS_SKIP = new Set([".Trash", ".tmp.drivedownload", ".tmp.driveupload", ".dropbox.cache", ".DS_Store", "Icon\r"]);
const today = () => new Date().toISOString().slice(0, 10);

export class LocalProvider {
  constructor(src) {
    this.src = src;
    this.root = path.resolve(expand(src.root));
    this.exclude = new Set(src.exclude || []);
    this.protect = new Set(src.protect || []);
    this.trashDir = src.trash_dir ? path.resolve(expand(src.trash_dir)) : path.join(this.root, "_To Delete");
  }
  // Resolve a path inside the source; refuse anything that escapes the root.
  abs(rel = "") {
    const clean = String(rel || "").replace(/^\/+/, "");
    const p = path.resolve(this.root, clean);
    if (p !== this.root && !p.startsWith(this.root + path.sep)) throw new Error(`Path "${rel}" is outside ${this.src.label}.`);
    return p;
  }
  rel(abs) { return path.relative(this.root, abs).split(path.sep).join("/"); }
  guardWrite(rel) {
    const parts = String(rel).split("/");
    for (const p of this.protect) if (rel === p || rel.startsWith(p + "/") || parts[0] === p) throw new Error(`"${p}" is protected in ${this.src.label}; Stow won't change anything inside it.`);
    if (this.src.role !== "file-into" && this.src.role !== "maintain") throw new Error(`${this.src.label} is search-only. Change its role to write here.`);
  }
  skip(name, rel) { return name.startsWith(".") || ALWAYS_SKIP.has(name) || this.exclude.has(name) || this.exclude.has(rel); }

  entry(abs, st) {
    st = st || fs.statSync(abs);
    return { path: this.rel(abs), name: path.basename(abs), type: st.isDirectory() ? "folder" : "file", size: st.isDirectory() ? undefined : st.size, modified: st.mtime.toISOString() };
  }
  async list(rel = "", { recursive = false, limit = 500, cursor = 0 } = {}) {
    const start = this.abs(rel); const out = []; let seen = 0; const offset = Number(cursor) || 0;
    const walk = (dir) => {
      let names; try { names = fs.readdirSync(dir).sort(); } catch { return; }
      for (const n of names) {
        const a = path.join(dir, n); const r = this.rel(a);
        if (this.skip(n, r)) continue;
        let st; try { st = fs.statSync(a); } catch { continue; }
        if (seen++ >= offset && out.length < limit) out.push(this.entry(a, st));
        if (out.length >= limit) return;
        if (recursive && st.isDirectory()) walk(a);
        if (out.length >= limit) return;
      }
    };
    walk(start);
    return { entries: out, next_cursor: out.length >= limit ? String(offset + out.length) : null };
  }
  async stat(rel) { const a = this.abs(rel); const e = this.entry(a); e.link = await this.link(rel); return e; }
  async read(rel, opts) { return extractText(this.abs(rel), opts); }
  async localFile(rel) { return this.abs(rel); } // already on disk
  async md5(rel) { return new Promise((res, rej) => { const h = crypto.createHash("md5"); fs.createReadStream(this.abs(rel)).on("data", (d) => h.update(d)).on("end", () => res(h.digest("hex"))).on("error", rej); }); }

  async mkdir(rel) { this.guardWrite(rel); fs.mkdirSync(this.abs(rel), { recursive: true }); return { path: rel }; }
  async write(rel, { buffer, fromFile, overwrite = false }) {
    this.guardWrite(rel);
    const dst = this.abs(rel);
    if (fs.existsSync(dst) && !overwrite) throw new Error(`"${rel}" already exists. Pass overwrite: true or choose another name.`);
    fs.mkdirSync(path.dirname(dst), { recursive: true });
    if (fromFile) await run("/bin/cp", ["-p", fromFile, dst]); else fs.writeFileSync(dst, buffer);
    return this.entry(dst);
  }
  async move(from, to) {
    this.guardWrite(from); this.guardWrite(to);
    const a = this.abs(from), b = this.abs(to);
    if (fs.existsSync(b)) throw new Error(`"${to}" already exists.`);
    fs.mkdirSync(path.dirname(b), { recursive: true });
    fs.renameSync(a, b);
    return this.entry(b);
  }
  async copyWithin(from, to) { return this.write(to, { fromFile: this.abs(from) }); }
  // Never a permanent delete: items go to this source's _To Delete (or its configured trash folder).
  async trash(rel) {
    this.guardWrite(rel);
    const a = this.abs(rel);
    const dst = path.join(this.trashDir, "Trashed by Stow", today(), rel);
    fs.mkdirSync(path.dirname(dst), { recursive: true });
    fs.renameSync(a, fs.existsSync(dst) ? dst + ` (${Date.now()})` : dst);
    return { trashed: rel, to: tilde(dst) };
  }
  // Files changed since an ISO timestamp cursor (first call: everything from the last 24 hours).
  async changes(cursor) {
    const since = cursor ? Date.parse(cursor) : Date.now() - 86400000;
    const now = new Date().toISOString(); const out = [];
    const walk = (dir) => {
      let names; try { names = fs.readdirSync(dir); } catch { return; }
      for (const n of names) {
        const a = path.join(dir, n); const r = this.rel(a);
        if (this.skip(n, r) || n === "_To Delete") continue;
        let st; try { st = fs.statSync(a); } catch { continue; }
        if (st.isDirectory()) walk(a); else if (st.mtimeMs > since && out.length < 5000) out.push(this.entry(a, st));
      }
    };
    walk(this.root);
    return { changes: out, cursor: now };
  }
  async search(query, { limit = 50, timeBudgetMs = 8000 } = {}) {
    const words = query.toLowerCase().split(/\s+/).filter(Boolean); const out = []; const t0 = Date.now();
    const walk = (dir) => {
      if (out.length >= limit || Date.now() - t0 > timeBudgetMs) return;
      let names; try { names = fs.readdirSync(dir); } catch { return; }
      for (const n of names) {
        const a = path.join(dir, n); const r = this.rel(a);
        if (this.skip(n, r)) continue;
        if (words.every((w) => r.toLowerCase().includes(w))) { try { out.push(this.entry(a)); } catch {} }
        if (out.length >= limit) return;
        let st; try { st = fs.statSync(a); } catch { continue; }
        if (st.isDirectory()) walk(a);
      }
    };
    walk(this.root);
    return { results: out, complete: Date.now() - t0 <= timeBudgetMs };
  }
  async link(rel) {
    const a = this.abs(rel);
    if (this.src.kind === "google-drive") {
      try {
        const { stdout } = await run("/usr/bin/xattr", ["-p", "com.google.drivefs.item-id#S", a]);
        const id = stdout.trim(); if (!id) return null;
        if (fs.statSync(a).isDirectory()) return `https://drive.google.com/drive/folders/${id}`;
        const ext = path.extname(a).toLowerCase();
        const doc = { ".gdoc": "document", ".gsheet": "spreadsheets", ".gslides": "presentation", ".gform": "forms" }[ext];
        return doc ? `https://docs.google.com/${doc}/d/${id}/edit` : `https://drive.google.com/file/d/${id}/view`;
      } catch { return null; }
    }
    if (this.src.kind === "dropbox") {
      const r = this.rel(a); const isDir = fs.statSync(a).isDirectory();
      const dir = isDir ? r : path.posix.dirname(r);
      return "https://www.dropbox.com/home/" + encodeURI(dir === "." ? "" : dir) + (isDir ? "" : "?preview=" + encodeURIComponent(path.basename(a)));
    }
    return null;
  }
}
