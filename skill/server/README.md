# Stow (lite) server for the organiser skill

One MCP server that runs on the user's Mac. It reads, writes, summarises and maintains the folders the
user connects, and enforces the safety rules the organiser skill relies on.

## Shape

```
Claude (desktop chats, the scheduled run)
        │  MCP over stdio (registered in Claude desktop)
        ▼
   this server ── config.json (the "sources" list) in the home folder
        │
        └── Mac folders: Documents, Desktop, Downloads, iCloud Drive, synced Google Drive / Box / OneDrive
            folders, and external drives
```

## Roles (per source)

| Role | Meaning |
| --- | --- |
| `index` | Search only. Nothing may be written or moved. |
| `inbox` | A folder being tidied. Items may be moved out of it; nothing is filed into it. |
| `file-into` | The organiser may file here. |
| `maintain` | File into it and tidy it in place (e.g. an external drive being reorganised). |

## Rules it enforces

- Writes are refused unless the source's role allows them. Paths can't escape a source's root.
- `protect` paths per source can't be changed.
- No overwrite unless asked. No permanent deletes, ever.
- Originals go to a recoverable place: the Mac Bin (`trash: "mac-bin"`) or the source's own
  `_To Delete` folder (`trash: "source"`). Drives must use `source`, because a move to the Mac Bin can't
  cross volumes.
- An external drive that isn't connected is refused with a plain message. Nothing is created at its path.
- `stow_move` / `stow_copy` accept `expect_size` and `expect_modified` so an approved plan is only applied to
  files that haven't changed since.
- Every write is logged to `<home>/log/ops.log`.

## Tools

`stow_sources`, `stow_connect`, `stow_validate`, `stow_list`, `stow_search`, `stow_stat`, `stow_link`,
`stow_read`, `stow_write`, `stow_mkdir`, `stow_copy`, `stow_move`, `stow_trash`, `stow_changes`,
`stow_annotate`, `stow_annotations`.

## Files

- Home folder: `~/Documents/.tidy/` (override with `STOW_HOME`): `config.json`, `annotations.json`, `state/`, `log/`.
- `STOW_BIN` overrides the Mac Bin location (used by the tests).

## Test

`npm test` runs the smoke test against throwaway folders.
