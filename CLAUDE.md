# sandbox

Personal scratch Roblox project — throwaway experiments, no production code and
no shared conventions to uphold. Rojo (`default.project.json`) syncs `src/` into
Studio; the place file owns all geometry.

- `bash scripts/check.sh` after changes — sourcemap + `luau-lsp analyze` + `selene`.
- `rojo serve` runs on port 34873. The file watcher does not fire on `/mnt/c`:
  restart the server after edits, or run it from Windows.
- Prefer small, self-contained scripts. Don't build up frameworks here.
