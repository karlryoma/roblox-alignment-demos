# sandbox

A scratch Roblox place for trying things out. Rojo syncs code from `src/`;
the `.rbxlx` place file owns everything physical (baseplate, parts, lighting).

## One-time setup

1. `rokit install` — installs the pinned rojo / selene / luau-lsp.
2. `rojo plugin install` — puts the Rojo plugin in Studio (once per machine).
3. Studio: **File → New → Baseplate**, then **Save As** → `sandbox.rbxlx`
   in this folder. It's gitignored; untrack it if you build something worth
   keeping.

## Daily loop

```
rojo serve              # serves on port 34873; Studio: Rojo plugin -> Connect
bash scripts/check.sh   # sourcemap + luau-lsp type check + selene lint
```

Expected output on Play: `[server] sandbox up`, `[client] hello, world`.

## Layout

| Path                | Becomes                                     |
| ------------------- | ------------------------------------------- |
| `src/shared/*.luau` | `ReplicatedStorage.Shared`                  |
| `src/server/*.luau` | `ServerScriptService.Server`                |
| `src/client/*.luau` | `StarterPlayer.StarterPlayerScripts.Client` |

File suffix picks the instance class: `*.server.luau` → Script,
`*.client.luau` → LocalScript, plain `*.luau` → ModuleScript. A folder with an
`init.luau` becomes a ModuleScript with the siblings as children.

To throw code away, just delete the file — Rojo removes the instance on sync.

## WSL note

This lives on `/mnt/c`, where Rojo's file watcher never fires. A `rojo serve`
started from WSL will keep serving your source as it was when the process
launched, no matter how many times Studio reconnects. Run `rojo serve` from
Windows PowerShell, or restart it after each edit. Editing
`default.project.json` always requires a restart.
