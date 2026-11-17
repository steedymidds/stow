# Stow

One MCP server, running on your Mac, that reads, writes, summarises and maintains every file store
you connect, with any number of accounts per service. The Stow app and the organiser skill are built on top of it.

## Shape

```
Claude (desktop chats, the daily organiser run)
        │  MCP over stdio (registered in Claude desktop)
        ▼
   stow server ── sources.json (one entry per account) ── Keychain (one token per API account)
        │
        ├── Mac folders: Documents, iCloud Drive, and every synced Google Drive / Dropbox / Box / OneDrive folder
        └── Dropbox API: accounts that aren't synced to this Mac (personal, …)
            (Google Drive API, Box, OneDrive: same interface, next stages)
```

## Tools

| Tool | Does |
| --- | --- |
| `stow_sources` | Every source: id, service, account, business, role, privacy, sign-in state |
| `stow_connect` | Add or re-sign-in an account. Dropbox opens its approval page on the Mac; folders register a path |
| `stow_list`, `stow_search`, `stow_stat`, `stow_link` | Browse, find, inspect, link |
| `stow_read` | The text of a file (PDF, Word, Excel, PowerPoint, text, CSV, JSON, HTML), ready to summarise |
| `stow_write`, `stow_mkdir` | Create files and folders |
| `stow_copy`, `stow_move` | Within or across stores. Across stores the copy is verified (md5 or Dropbox content hash) before the original is trashed |
| `stow_trash` | The store's own recoverable trash. Never a permanent delete |
| `stow_changes` | What changed since last time (cursor kept per source) |
| `stow_annotate`, `stow_annotations` | Claude's summary and interpretation of a file: type, date, parties, amount, tags |

## Rules it enforces

- Roles: `index` (search only), `file-into`, `maintain` (file into and tidy). Writes are refused on `index` sources.
- `protect` paths per source (e.g. `_Automations — do not move`) can't be changed.
- Paths can't escape a source's root.
- No overwrite unless asked. No permanent deletes, ever.
- Every write is logged to `~/Documents/.file-organiser/log/stow-ops.log`.

## Files

- Code: wherever you cloned it; the app looks for `~/.stow/engine` (override with `STOW_ENGINE=/path/to/src/index.js`)
- State: `~/Documents/.file-organiser/` — `sources.json`, `stow-config.json` (the Dropbox app key, which is public), `annotations.json`, `state/` (change cursors), `log/`
- Secrets: macOS Keychain, service `stow`, account `dropbox:<source id>`

## Test

`npm test` runs the smoke test against throwaway folders.
