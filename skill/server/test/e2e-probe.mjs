import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import path from "node:path";
const HOME = path.resolve("../_test/home");
const t = new StdioClientTransport({ command: process.execPath, args: [path.resolve("src/index.js")], env: { ...process.env, STOW_HOME: HOME } });
const c = new Client({ name: "probe", version: "1" }); await c.connect(t);
for (const [n,a] of [["stow_validate",{}],["stow_list",{source:"dl"}],["stow_list",{source:"desk"}]]) { const r = await c.callTool({ name: n, arguments: a }); console.log(n, r.isError?"ERR":"", r.content[0].text.slice(0,900)); }
await c.close();
