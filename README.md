# Stow

Find, file and tidy the files spread across your Mac and your cloud folders. Stow is a native Mac app
backed by an MCP server, so Claude can search, read, summarise and organise the same files you see in the app.

This repository holds three parts:

| Folder | What it is |
| --- | --- |
| `app/` | The native macOS app (SwiftUI): Find, Review, Sources and Runs. Needs macOS 14 or later. |
| `engine/` | The MCP server the app and Claude both talk to. Mac folders plus the Dropbox API, with any number of accounts per service. Node 20 or later. |
| `skill/` | A lighter, installable organiser: a catalogue script and a trimmed server (`skill/server`) for people who only want folder tidying. |

## Download

Grab `Stow-macos.zip` from the [latest release](https://github.com/steedymidds/stow/releases/latest), unzip it and move
`Stow.app` to Applications. The build is not notarised, so the first time you open it, right-click the app and choose
Open. You also need the engine: see below.

## Build from source

```sh
# 1. The engine
git clone https://github.com/steedymidds/stow.git ~/.stow-src
mkdir -p ~/.stow && cp -R ~/.stow-src/engine ~/.stow/engine
(cd ~/.stow/engine && npm ci)

# 2. The app (Xcode command line tools required)
cd ~/.stow-src/app && ./build.sh
```

The app starts the engine from `~/.stow/engine/src/index.js`. Set `STOW_ENGINE` to use another location.

## Use it with Claude

Register the engine as an MCP server in Claude desktop's config:

```json
{ "mcpServers": { "stow": { "command": "node", "args": ["/Users/YOU/.stow/engine/src/index.js"] } } }
```

See `engine/README.md` for the tools and the safety rules (no permanent deletes, verified copies, protected paths)
and `engine/SETUP.md` for connecting Dropbox.

## Privacy

Everything runs on your Mac. Tokens live in your macOS Keychain. Nothing is sent anywhere except to the services you connect
and, if you use Organise or Ask, to Claude through your own Claude Code sign-in.

## Licence

MIT. See `LICENSE`.
