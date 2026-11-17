// The source registry: the "sources" list inside config.json (or the older sources.json) in the home folder.
import path from "node:path";
import fs from "node:fs";
import { CONFIG_JSON, SOURCES_FILE, STOW_HOME, readJSON, writeJSON, expand } from "./config.js";
import { volumeState } from "./providers/local.js";

export const ROLES = ["index", "inbox", "file-into", "maintain"];

function load() {
  const cfg = readJSON(CONFIG_JSON, null);
  if (cfg && Array.isArray(cfg.sources)) return { file: CONFIG_JSON, data: cfg };
  const old = readJSON(SOURCES_FILE, null);
  if (old && Array.isArray(old.sources)) return { file: SOURCES_FILE, data: old };
  return { file: CONFIG_JSON, data: cfg && typeof cfg === "object" ? { ...cfg, sources: [] } : { version: 1, sources: [] } };
}

export function loadRegistry() { return load().data; }
export function saveRegistry(reg) { writeJSON(load().file, reg); }
export function listSources() { return load().data.sources; }
export function getSource(id) {
  const s = listSources().find((x) => x.id === id);
  if (!s) throw new Error(`Unknown source "${id}". Call stow_sources to see the ids.`);
  return s;
}
export function upsertSource(src) {
  const { file, data } = load();
  const i = data.sources.findIndex((x) => x.id === src.id);
  if (i >= 0) data.sources[i] = { ...data.sources[i], ...src };
  else data.sources.push(src);
  writeJSON(file, data);
  return data.sources.find((x) => x.id === src.id);
}
export function newId(prefix) {
  const ids = new Set(listSources().map((s) => s.id));
  let n = 1; while (ids.has(`${prefix}${n}`)) n++;
  return `${prefix}${n}`;
}

const inside = (child, parent) => child !== parent && (child + path.sep).startsWith(parent + path.sep);

// Plain-language problems (must be fixed) and warnings (worth knowing) with the current source list.
export function validateSources(sources = listSources()) {
  const problems = [], warnings = [];
  const name = (s) => s.label || s.id;
  const seen = new Set();
  for (const s of sources) {
    if (seen.has(s.id)) problems.push(`Two sources share the id "${s.id}".`);
    seen.add(s.id);
    if (!ROLES.includes(s.role)) problems.push(`${name(s)}: role "${s.role}" isn't one of ${ROLES.join(", ")}.`);
    if ((s.via || "mac") !== "mac") problems.push(`${name(s)}: only folders on this Mac are supported in this version.`);
    if (s.removable && s.trash === "mac-bin") problems.push(`${name(s)}: a removable drive can't use the Mac Bin, because files can't be moved to it across volumes. Set its trash to "source".`);
  }
  const on = sources.filter((s) => s.enabled !== false && s.root);
  for (const s of on) {
    const vs = volumeState(s);
    if (vs === "n/a") { if (!fs.existsSync(path.resolve(expand(s.root)))) problems.push(`${name(s)}: the folder ${s.root} wasn't found.`); }
    else if (vs === "not-mounted") warnings.push(`${name(s)} isn't connected right now. It will be skipped until it is.`);
    else if (vs === "startup-disk") problems.push(`${name(s)} points at the startup disk, not a drive.`);
    else if (vs === "folder-missing") problems.push(`${name(s)}: the folder ${s.root} isn't on the drive.`);
  }
  const roots = on.map((s) => ({ s, root: path.resolve(expand(s.root)) }));
  const home = path.resolve(STOW_HOME);
  for (const a of roots.filter((x) => x.s.role === "inbox")) {
    const ex = new Set(a.s.exclude || []);
    for (const b of roots) {
      if (b === a) continue;
      if (inside(b.root, a.root)) {
        const rel = path.relative(a.root, b.root).split(path.sep).join("/");
        const first = rel.split("/")[0];
        if (!ex.has(rel) && !ex.has(first)) problems.push(`${name(a.s)} would be tidied including ${name(b.s)}, which sits inside it. Exclude "${first}" from ${name(a.s)}.`);
      } else if (inside(a.root, b.root) && b.s.role !== "index") {
        problems.push(`${name(a.s)} sits inside ${name(b.s)}. Choose one of them as the folder to tidy.`);
      }
    }
    if (inside(home, a.root)) {
      const first = path.relative(a.root, home).split(path.sep)[0];
      if (!first.startsWith(".") && !ex.has(first)) problems.push(`The organiser's own folder sits inside ${name(a.s)}. Exclude "${first}".`);
    }
  }
  return { problems, warnings };
}
