// The provider-agnostic core: pick the backend for a source, copy between stores with
// verification, and keep Claude's summaries and interpretations of files.
import fs from "node:fs";
import crypto from "node:crypto";
import path from "node:path";
import { getSource } from "./registry.js";
import { ANNOTATIONS_FILE, readJSON, writeJSON, logOp } from "./config.js";
import { LocalProvider } from "./providers/local.js";

const cache = new Map();
export function provider(sourceId) {
  const src = getSource(sourceId);
  if (src.enabled === false) throw new Error(`${src.label} is switched off. Enable it in the source list first.`);
  if ((src.via || "mac") !== "mac") throw new Error(`${src.label}: only folders on this Mac are supported in this version.`);
  const key = JSON.stringify(src);
  if (!cache.has(key)) cache.set(key, new LocalProvider(src));
  return cache.get(key);
}

export const md5File = (f) => new Promise((res, rej) => { const h = crypto.createHash("md5"); fs.createReadStream(f).on("data", (d) => h.update(d)).on("end", () => res(h.digest("hex"))).on("error", rej); });

// Copy a file from any source to any source, then prove the copy matches the original.
// A folder (a bundle) is copied whole: every file md5-verified, then file count and bytes compared.
// Nothing is overwritten, links are refused, and a failure leaves the original untouched.
async function copyTree(from, to, fromId, toId, fromPath, toPath, srcAbs) {
  if (fs.existsSync(to.abs(toPath))) throw new Error(`"${toPath}" already exists. Nothing was copied.`);
  let n = 0, bytes = 0;
  const walk = async (dirAbs, rel) => {
    await to.mkdir(rel);
    const names = fs.readdirSync(dirAbs);
    for (const name of names) {
      // macOS litter: .DS_Store, and ._X companions that drives without native metadata keep beside X
      if (name === ".DS_Store" || (name.startsWith("._") && names.includes(name.slice(2)))) continue;
      const a = path.join(dirAbs, name), r = rel + "/" + name, st = fs.lstatSync(a);
      if (st.isSymbolicLink()) throw new Error(`"${name}" is a link, so this folder can't be copied safely.`);
      if (st.isDirectory()) { await walk(a, r); continue; }
      await to.write(r, { fromFile: a });
      const x = await md5File(a), y = await md5File(to.abs(r));
      if (!(x === y && x.length === 32)) throw new Error(`"${name}" did not verify.`);
      n++; bytes += st.size;
    }
  };
  try { await walk(srcAbs, toPath); }
  catch (e) { throw new Error(`Folder copy stopped: ${e.message} The original is untouched; a partial copy may be at "${toPath}" in ${toId}.`); }
  logOp({ op: "copy-folder", from: [fromId, fromPath], to: [toId, toPath], files: n, bytes, verified: "md5 matches" });
  return { path: toPath, files: n, bytes, verified: `md5 matches (${n} files)` };
}

export async function copyAcross(fromId, fromPath, toId, toPath, { overwrite = false } = {}) {
  const from = provider(fromId), to = provider(toId);
  const srcAbs = from.abs(fromPath);
  if (fs.statSync(srcAbs).isDirectory()) return copyTree(from, to, fromId, toId, fromPath, toPath, srcAbs);
  if (fromId === toId) {
    const e = await from.copyWithin(fromPath, toPath);
    const a = await from.md5(fromPath), b = await from.md5(toPath);
    if (!(a === b && a.length === 32)) throw new Error("Copy written but verification failed; the original is untouched. Check the destination.");
    logOp({ op: "copy", from: [fromId, fromPath], to: [toId, toPath], verified: "md5 matches" });
    return { ...e, verified: "md5 matches" };
  }
  const local = await from.localFile(fromPath);
  const written = await to.write(toPath, { fromFile: local, overwrite });
  const a = await md5File(local), b = await md5File(to.abs(toPath));
  const verified = a === b && a.length === 32 ? "md5 matches" : null;
  if (!verified) throw new Error("Copy written but verification failed; the original is untouched. Check the destination.");
  logOp({ op: "copy", from: [fromId, fromPath], to: [toId, toPath], verified });
  return { ...written, verified };
}

// Move = verified copy, then the original goes to its own source's trash (never a hard delete).
export async function moveAcross(fromId, fromPath, toId, toPath, opts) {
  if (fromId === toId) { const e = await provider(fromId).move(fromPath, toPath); logOp({ op: "move", from: [fromId, fromPath], to: [toId, toPath] }); return e; }
  const copied = await copyAcross(fromId, fromPath, toId, toPath, opts);
  const trashed = await provider(fromId).trash(fromPath);
  logOp({ op: "move", from: [fromId, fromPath], to: [toId, toPath], original: trashed });
  return { ...copied, original: trashed };
}

// Annotations: Claude's summary and interpretation of a file, keyed "source:path".
export function getAnnotations({ source, path } = {}) {
  const all = readJSON(ANNOTATIONS_FILE, {});
  if (source && path) return all[`${source}:${path}`] || null;
  if (source) return Object.fromEntries(Object.entries(all).filter(([k]) => k.startsWith(source + ":")));
  return all;
}
export function annotate(source, path, fields) {
  const all = readJSON(ANNOTATIONS_FILE, {});
  const key = `${source}:${path}`;
  const clean = Object.fromEntries(Object.entries(fields).filter(([, v]) => v !== undefined && v !== null && v !== ""));
  all[key] = { ...(all[key] || {}), ...clean, updated: new Date().toISOString() };
  writeJSON(ANNOTATIONS_FILE, all);
  return all[key];
}
export const hashId = (s) => crypto.createHash("sha1").update(s).digest("hex").slice(0, 10);
