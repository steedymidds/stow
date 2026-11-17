// OAuth 2 with PKCE and a one-shot localhost callback. The browser opens on the Mac, the person
// approves, the provider redirects to localhost, and the code is exchanged here. No secret or
// token ever passes through a chat.
import http from "node:http";
import crypto from "node:crypto";
import { execFile } from "node:child_process";

export const CALLBACK_PORT = 53682;
export const REDIRECT_URI = `http://localhost:${CALLBACK_PORT}/callback`;

const b64url = (buf) => buf.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
export function pkce() {
  const verifier = b64url(crypto.randomBytes(48));
  const challenge = b64url(crypto.createHash("sha256").update(verifier).digest());
  const state = b64url(crypto.randomBytes(16));
  return { verifier, challenge, state };
}

let busy = null; // one sign-in at a time
export function waitForCode(state, { timeoutMs = 10 * 60 * 1000 } = {}) {
  if (busy) throw new Error("Another sign-in is already waiting. Finish or let it time out (10 minutes) first.");
  return (busy = new Promise((resolve, reject) => {
    const server = http.createServer((req, res) => {
      const url = new URL(req.url, REDIRECT_URI);
      if (url.pathname !== "/callback") { res.writeHead(404); return res.end(); }
      const ok = url.searchParams.get("state") === state && url.searchParams.get("code");
      res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      res.end(`<!doctype html><meta charset="utf-8"><title>Stow</title><body style="background:#0b0d0a;color:#f6f0e6;font:16px -apple-system,sans-serif;padding:48px"><b style="font-size:28px">stow<span style="color:#aff005">.</span></b><p>${ok ? "Connected. You can close this tab and go back to Claude." : "That sign-in didn't match. Start it again from Claude."}</p>`);
      server.close(); clearTimeout(timer); busy = null;
      ok ? resolve(url.searchParams.get("code")) : reject(new Error(url.searchParams.get("error_description") || url.searchParams.get("error") || "State mismatch"));
    });
    const timer = setTimeout(() => { server.close(); busy = null; reject(new Error("Sign-in timed out after 10 minutes.")); }, timeoutMs);
    server.on("error", (e) => { busy = null; reject(e); });
    server.listen(CALLBACK_PORT, "127.0.0.1");
  }));
}
export const openInBrowser = (url) => execFile("/usr/bin/open", [url]);
