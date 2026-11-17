// The provider-agnostic core: pick the right backend for a source, copy between stores with
// verification, and keep Claude's summaries and interpretations of files.
import fs from "node:fs";
import crypto from "node:crypto";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { getSource } from "./registry.js";
import { ANNOTATIONS_FILE, readJSON, writeJSON, logOp } from "./config.js";
import { LocalProvider } from "./providers/local.js";
import { DropboxProvider, dropboxContentHash } from "./providers/dropbox.js";
const run = promisify(execFile);

const cache = new Map();
export function provider(sourceId) {
  const src = getSource(sourceId);
  const key = JSON.stringify(src);
  if (cache.has(key)) return cache.get(key);
  let p;
  if ((src.via || "mac") === "mac") p = new LocalProvider(src);
  else if (src.via === "api" && src.kind === "dropbox") p = new DropboxProvider(src);
  else throw new Error(`${src.label}: "${src.kind}" via "${src.via}" isn't supported yet.`);
  if (src.enabled === false) throw new Error(`${src.label} is switched off. Enable it in the source list first.`);
  cache.set(key, p);
  return p;
}

export const md5File = (f) => new Promise((res, rej) => { const h = crypto.createHash("md5"); fs.createReadStream(f).on("data", (d) => h.update(d)).on("end", () => res(h.digest("hex"))).on("error", rej); });

// Copy a file from any source to any source, then prove the copy matches the original.
export async function copyAcross(fromId, fromPath, toId, toPath, { overwrite = false } = {}) {
  const from = provider(fromId), to = provider(toId);
  if (fromId === toId) { const e = await from.copyWithin(fromPath, toPath); logOp({ op: "copy", from: [fromId, fromPath], to: [toId, toPath] }); return { ...e, verified: "same-store copy" }; }
  const local = await from.localFile(fromPath);
  const isTemp = !(from instanceof LocalProvider);
  try {
    const written = await to.write(toPath, { fromFile: local, overwrite });
    let verified;
    if (to instanceof DropboxProvider) {
      const want = dropboxContentHash(local);
      verified = written.content_hash === want ? "dropbox content hash matches" : null;
    } else {
      const a = await md5File(local), b = await md5File(to.abs(toPath));
      verified = a === b && a.length === 32 ? "md5 matches" : null;
    }
    if (!verified) throw new Error("Copy written but verification failed; the original is untouched. Check the destination.");
    logOp({ op: "copy", from: [fromId, fromPath], to: [toId, toPath], verified });
    return { ...written, verified };
  } finally { if (isTemp) fs.rm(local, () => {}); }
}

// Move = verified copy, then the original goes to its own store's trash (never a hard delete).
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
