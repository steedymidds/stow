// Turn a local file into text Claude can read and summarise. Uses only tools that ship with
// macOS (textutil, unzip, JXA + PDFKit), falling back to pdftotext when Homebrew poppler exists.
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import fs from "node:fs";
import path from "node:path";
const run = promisify(execFile);
const MAX_BUF = 64 * 1024 * 1024;

const TEXT = new Set([".txt", ".md", ".csv", ".tsv", ".json", ".xml", ".html", ".htm", ".yaml", ".yml", ".log", ".js", ".ts", ".py", ".css", ".svg"]);
const TEXTUTIL = new Set([".doc", ".docx", ".rtf", ".rtfd", ".odt", ".webarchive", ".wordml"]);
const IMAGE = new Set([".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".tif", ".tiff", ".bmp"]);
const VIDEO = new Set([".mov", ".mp4", ".m4v", ".avi"]);

const stripXml = (s) => s.replace(/<a:br\/>|<\/a:p>|<\/w:p>|<\/text:p>/g, "\n").replace(/<[^>]+>/g, " ").replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/[ \t]+/g, " ").replace(/\n\s*\n+/g, "\n").trim();

async function pdfText(file) {
  for (const bin of ["/opt/homebrew/bin/pdftotext", "/usr/local/bin/pdftotext"]) {
    if (fs.existsSync(bin)) {
      const { stdout } = await run(bin, ["-layout", "-l", "40", file, "-"], { maxBuffer: MAX_BUF });
      return { text: stdout, method: "pdftotext" };
    }
  }
  const jxa = `ObjC.import('PDFKit'); function run(argv){ var d=$.PDFDocument.alloc.initWithURL($.NSURL.fileURLWithPath(argv[0])); if(!d) return ''; var n=Math.min(d.pageCount,40), out=[]; for(var i=0;i<n;i++){ var p=d.pageAtIndex(i); out.push(ObjC.unwrap(p.string)||''); } return out.join('\\n\\f'); }`;
  const { stdout } = await run("/usr/bin/osascript", ["-l", "JavaScript", "-e", jxa, file], { maxBuffer: MAX_BUF });
  return { text: stdout, method: "pdfkit" };
}

async function zipText(file, ext) {
  const { stdout: list } = await run("/usr/bin/unzip", ["-Z1", file], { maxBuffer: MAX_BUF });
  const names = list.split("\n");
  let wanted;
  if (ext === ".xlsx") wanted = names.filter((n) => n === "xl/sharedStrings.xml" || /^xl\/worksheets\/sheet\d+\.xml$/.test(n));
  else if (ext === ".pptx") wanted = names.filter((n) => /^ppt\/slides\/slide\d+\.xml$/.test(n)).sort((a, b) => parseInt(a.match(/\d+/)) - parseInt(b.match(/\d+/)));
  else if (ext === ".pages" || ext === ".numbers" || ext === ".key") wanted = names.filter((n) => n.endsWith("preview.pdf") || n.endsWith(".xml"));
  else wanted = names.filter((n) => n.endsWith(".xml"));
  let out = "";
  for (const n of wanted.slice(0, 80)) {
    const { stdout } = await run("/usr/bin/unzip", ["-p", file, n], { maxBuffer: MAX_BUF });
    out += stripXml(stdout) + "\n";
  }
  return { text: out, method: "unzip" };
}

export async function extractText(file, { maxChars = 20000 } = {}) {
  const ext = path.extname(file).toLowerCase();
  const st = fs.statSync(file);
  let res = { text: "", method: "none" };
  try {
    if (ext === ".pdf") res = await pdfText(file);
    else if (TEXTUTIL.has(ext)) { const { stdout } = await run("/usr/bin/textutil", ["-convert", "txt", "-stdout", file], { maxBuffer: MAX_BUF }); res = { text: stdout, method: "textutil" }; }
    else if ([".xlsx", ".pptx", ".odp", ".ods"].includes(ext)) res = await zipText(file, ext);
    else if (TEXT.has(ext) || st.size < 200000 && !IMAGE.has(ext) && !VIDEO.has(ext) && isProbablyText(file)) res = { text: fs.readFileSync(file, "utf8"), method: "plain" };
    else if (IMAGE.has(ext)) res = { text: "", method: "image", note: "Image: no text layer. Stage it and look at it to describe it." };
    else if (VIDEO.has(ext)) res = { text: "", method: "video", note: "Video: grab a frame with ffmpeg to see it." };
  } catch (e) { res = { text: "", method: "error", note: String(e.message || e).slice(0, 300) }; }
  const text = (res.text || "").replace(/\u0000/g, "");
  return { ...res, chars: text.length, truncated: text.length > maxChars, text: text.slice(0, maxChars), bytes: st.size, ext };
}

function isProbablyText(file) {
  const fd = fs.openSync(file, "r"); const buf = Buffer.alloc(4096); const n = fs.readSync(fd, buf, 0, 4096, 0); fs.closeSync(fd);
  let bad = 0; for (let i = 0; i < n; i++) { const c = buf[i]; if (c === 0) return false; if (c < 9 || (c > 13 && c < 32)) bad++; }
  return bad / Math.max(1, n) < 0.05;
}
