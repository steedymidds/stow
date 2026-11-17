// Secrets live in the macOS login Keychain under service "stow", never in files.
import { execFile } from "node:child_process";
import { promisify } from "node:util";
const run = promisify(execFile);
const SERVICE = "stow";

export async function getSecret(account) {
  try {
    const { stdout } = await run("/usr/bin/security", ["find-generic-password", "-s", SERVICE, "-a", account, "-w"]);
    return stdout.trim() || null;
  } catch { return null; }
}
export async function setSecret(account, value) {
  await run("/usr/bin/security", ["add-generic-password", "-U", "-s", SERVICE, "-a", account, "-w", value]);
}
export async function deleteSecret(account) {
  try { await run("/usr/bin/security", ["delete-generic-password", "-s", SERVICE, "-a", account]); } catch {}
}
