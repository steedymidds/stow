// Mac folders: Documents, iCloud Drive, every synced cloud folder under ~/Library/CloudStorage
// (Google Drive, Box, OneDrive) and external drives. Read and write.
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { expand, tilde, BIN } from "../config.js";
import { extractText } from "../extract.js";
const run = promisify(execFile);

const ALWAYS_SKIP = new Set([".Trash", ".Trashes", ".tmp.drivedownload", ".tmp.driveupload", ".DS_Store", "Icon\r", "System Volume Information", "$RECYCLE.BIN"]);
const today = () => new Date().toISOString().slice(0, 10);

// Roles. index: search only. inbox: a folder being tidied (items may be moved out of it; nothing is filed into it).
// file-into: the organiser may file here. maintain: file into it and tidy it in place.
const ROLE_INTO = new Set(["file-into", "maintain"]);
const ROLE_FROM = new Set(["inbox", "file-into", "maintain"]);

// For drives that can be unplugged. "n/a" for ordinary folders; otherwise
// "ok" | "not-mounted" | "startup-disk" | "folder-missing".
export function volumeState(src) {
  if (!(src.removable || src.require_mounted || src.kind === "external-drive")) return "n/a";
  const root = path.resolve(expand(src.root || ""));
  const m = root.match(/^\/Volumes\/[^/]+/);
  const vol = m ? m[0] : root;
  const parent = m ? "/Volumes" : path.dirname(vol);
  try {
    if (fs.realpathSync(vol) === "/") return "startup-disk"; // e.g. /Volumes/<name of the startup disk> is a link to /
    if (fs.statSync(vol).dev === fs.statSync(parent).dev) return "not-mounted";
    return fs.existsSync(root) ? "ok" : "folder-missing";
  } catch { return "not-mounted"; }
}

export class LocalProvider {
  constructor(src) {
    this.src = src;
    this.root = path.resolve(expand(src.root));
    this.exclude = new Set(src.exclude || []);
    this.protect = new Set(src.protect || []);
    this.trashPolicy = src.trash || (src.role === "inbox" ? "mac-bin" : "source");
    this.trashDir = src.trash_dir ? path.resolve(expand(src.trash_dir)) : path.join(this.root, "_To Delete");
  }
  // Refuse to touch a drive that isn't there. Without this, a write to an unplugged drive's path
  // would try to create folders on the startup disk instead.
  ready() {
    const st = volumeState(this.src);
    if (st === "startup-disk") throw new Error(`${this.src.label} points at the startup disk, not a drive.`);
    if (st === "not-mounted") throw new Error(`${this.src.label} isn't connected. Plug it in, then try again.`);
    if (st === "folder-missing") throw new Error(`${this.src.label}: the folder isn't on the drive.`);
  }
  // Resolve a path inside the source; refuse anything that escapes the root.
  abs(rel = "") {
    this.ready();
    const clean = String(rel || "").replace(/^\/+/, "");
    const p = path.resolve(this.root, clean);
    if (p !== this.root && !p.startsWith(this.root + path.sep)) throw new Error(`Path "${rel}" is outside ${this.src.label}.`);
    return p;
  }
  rel(abs) { return path.relative(this.root, abs).split(path.sep).join("/"); }
  // mode "into": something is created or placed here. mode "from": something is moved or trashed out of here.
  guard(rel, mode) {
    const parts = String(rel).split("/");
    for (const p of this.protect) if (rel === p || rel.startsWith(p + "/") || parts[0] === p) throw new Error(`"${p}" is protected in ${this.src.label}; nothing inside it will be changed.`);
    if (mode === "from") {
      if (!ROLE_FROM.has(this.src.role)) throw new Error(`${this.src.label} is search-only. Change its role to move things out of it.`);
    } else if (!ROLE_INTO.has(this.src.role)) {
      throw new Error(`${this.src.label} can't be filed into (its role is "${this.src.role}"). Change its role to write here.`);
    }
  }
  guardWrite(rel) { this.guard(rel, "into"); }
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

  async mkdir(rel) { this.guard(rel, "into"); fs.mkdirSync(this.abs(rel), { recursive: true }); return { path: rel }; }
  async write(rel, { buffer, fromFile, overwrite = false }) {
    this.guard(rel, "into");
    const dst = this.abs(rel);
    if (fs.existsSync(dst) && !overwrite) throw new Error(`"${rel}" already exists. Pass overwrite: true or choose another name.`);
    fs.mkdirSync(path.dirname(dst), { recursive: true });
    if (fromFile) await run("/bin/cp", ["-p", fromFile, dst]); else fs.writeFileSync(dst, buffer);
    return this.entry(dst);
  }
  async move(from, to) {
    this.guard(from, "from"); this.guard(to, "into");
    const a = this.abs(from), b = this.abs(to);
    if (fs.existsSync(b)) throw new Error(`"${to}" already exists.`);
    fs.mkdirSync(path.dirname(b), { recursive: true });
    fs.renameSync(a, b);
    return this.entry(b);
  }
  async copyWithin(from, to) { return this.write(to, { fromFile: this.abs(from) }); }
  // Never a permanent delete. Policy "mac-bin": the Mac Bin (recoverable). Policy "source": this source's
  // own _To Delete folder (required for drives, because a move to the Mac Bin can't cross volumes).
  async trash(rel) {
    this.guard(rel, "from");
    const a = this.abs(rel);
    if (this.trashPolicy === "mac-bin") {
      fs.mkdirSync(BIN, { recursive: true });
      let dst = path.join(BIN, path.basename(a));
      if (fs.existsSync(dst)) dst = path.join(BIN, `${path.basename(a)} (${Date.now()})`);
      try { fs.renameSync(a, dst); }
      catch (e) {
        if (e.code === "EXDEV") throw new Error(`${this.src.label}: this can't be moved to the Mac Bin because it is on a different volume. Set this source's trash to "source".`);
        throw e;
      }
      return { trashed: rel, to: tilde(dst) };
    }
    const dst = path.join(this.trashDir, "Trashed by organiser", today(), rel);
    fs.mkdirSync(path.dirname(dst), { recursive: true });
    const final = fs.existsSync(dst) ? dst + ` (${Date.now()})` : dst;
    fs.renameSync(a, final);
    return { trashed: rel, to: tilde(final) };
  }
  // Files changed since an ISO timestamp cursor (first call: everything from the last 24 hours).
  async changes(cursor) {
    this.ready();
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
    this.ready();
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
    return null;
  }
}
