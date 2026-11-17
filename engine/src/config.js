// Paths and small helpers shared by the whole server.
import os from "node:os";
import path from "node:path";
import fs from "node:fs";

export const HOME = os.homedir();
export const STOW_HOME = process.env.STOW_HOME || path.join(HOME, "Documents", ".file-organiser");
export const SOURCES_FILE = path.join(STOW_HOME, "sources.json");
export const CONFIG_FILE = path.join(STOW_HOME, "stow-config.json");
export const ANNOTATIONS_FILE = path.join(STOW_HOME, "annotations.json");
export const STATE_DIR = path.join(STOW_HOME, "state");
export const LOG_DIR = path.join(STOW_HOME, "log");
export const TMP_DIR = path.join(os.tmpdir(), "stow");

for (const d of [STOW_HOME, STATE_DIR, LOG_DIR, TMP_DIR]) fs.mkdirSync(d, { recursive: true });

export const expand = (p) => (p && p.startsWith("~") ? path.join(HOME, p.slice(1)) : p);
export const tilde = (p) => (p && p.startsWith(HOME) ? "~" + p.slice(HOME.length) : p);

export function readJSON(file, fallback) {
  try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch { return fallback; }
}
export function writeJSON(file, obj) {
  const tmp = file + ".tmp-" + process.pid;
  fs.writeFileSync(tmp, JSON.stringify(obj, null, 2));
  fs.renameSync(tmp, file);
}
export function config() { return readJSON(CONFIG_FILE, {}); }

// Every write Stow makes is appended here, one JSON line per operation.
export function logOp(op) {
  const line = JSON.stringify({ at: new Date().toISOString(), ...op }) + "\n";
  fs.appendFileSync(path.join(LOG_DIR, "stow-ops.log"), line);
}
