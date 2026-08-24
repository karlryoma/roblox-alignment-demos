# sandbox — personal Roblox testing project

Same shape as `muscle`: Rojo syncs CODE ONLY; the place file owns the world.

## One-time setup

1. `rokit install` (from this folder) — pins rojo / selene / luau-lsp.
2. Studio: install the Rojo plugin once — `rojo plugin install`.
3. Studio: **File → New → Baseplate**, then **File → Save As** →
   `sandbox.rbxlx` in this folder. (It's gitignored; drop it from
   `.gitignore` if you start hand-building geometry worth tracking.)

## Daily loop

```
rojo serve            # then in Studio: Rojo plugin → Connect
bash scripts/check.sh # sourcemap + luau-lsp + selene
```

## Layout

| Path                        | Lands in                                     |
| --------------------------- | -------------------------------------------- |
| `src/shared/*.luau`         | `ReplicatedStorage.Shared`                    |
| `src/server/*.luau`         | `ServerScriptService.Server`                  |
| `src/client/*.luau`         | `StarterPlayer.StarterPlayerScripts.Client`   |

`*.server.luau` → Script, `*.client.luau` → LocalScript, plain `*.luau` → ModuleScript.

## WSL gotcha

Rojo's file watcher does **not** fire on `/mnt/c` (drvfs). If you run
`rojo serve` from WSL, it keeps serving the source as it was when the process
started. Either run `rojo serve` from **Windows PowerShell**, or restart the
server after every edit. Editing `default.project.json` always needs a restart.
