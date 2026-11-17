// The source registry: sources.json in the Stow home. One entry per account.
import { SOURCES_FILE, readJSON, writeJSON } from "./config.js";

const DEFAULT = { version: 1, sources: [] };

export function loadRegistry() { return readJSON(SOURCES_FILE, DEFAULT); }
export function saveRegistry(reg) { writeJSON(SOURCES_FILE, reg); }
export function listSources() { return loadRegistry().sources; }
export function getSource(id) {
  const s = listSources().find((x) => x.id === id);
  if (!s) throw new Error(`Unknown source "${id}". Call stow_sources to see the ids.`);
  return s;
}
export function upsertSource(src) {
  const reg = loadRegistry();
  const i = reg.sources.findIndex((x) => x.id === src.id);
  if (i >= 0) reg.sources[i] = { ...reg.sources[i], ...src };
  else reg.sources.push(src);
  saveRegistry(reg);
  return reg.sources.find((x) => x.id === src.id);
}
export function newId(prefix) {
  const ids = new Set(listSources().map((s) => s.id));
  let n = 1; while (ids.has(`${prefix}${n}`)) n++;
  return `${prefix}${n}`;
}
