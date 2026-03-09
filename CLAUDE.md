# claude-sync

Config sync tool for Claude Code. Three transport modes: cloud (git-backed), SSH (rsync), and portable export/import.

## Commands

```bash
./claude-sync help          # Show all commands
bash -n claude-sync         # Syntax check main entrypoint
bash -n lib/common.sh       # Syntax check any module
```

## Architecture

```
claude-sync        Main entrypoint: config, sources lib/*.sh, case dispatch
lib/common.sh      Shared functions (path rewriting, secrets, smart merge, file copy)
lib/ssh.sh         SSH commands (push, pull, diff, status, bootstrap, verify)
lib/export.sh      Export/import (tarball with self-contained install.sh)
lib/cloud.sh       Cloud sync (git-backed via GitHub)
install.sh         Symlinks into ~/.claude/bin/
```

## Key Design Decisions

- All modules are sourced (not subprocesses). They share variables from the main entrypoint.
- Config arrays (CORE_SYNC_FILES, CORE_SYNC_DIRS, etc.) live in the main entrypoint, shared functions in lib/common.sh.
- The embedded install.sh inside export.sh must be fully self-contained. It cannot source common.sh since it runs from an extracted tarball on a different machine.
- `copy_claude_config` is the single file-gathering function. Mode flags (`--with-projects`, `--with-extras`, `--with-export-plugins`) control what gets included.
- `rewrite_paths` handles both concrete paths (`/Users/X` to `/home/Y`) and token paths (`$HOME` to `{{HOME}}`). JSON files get deep replacement via python3.
- `smart_merge_claude_json` only syncs specific keys (mcpServers, theme, teammateMode), preserving all other local-only keys.
- Cloud mode stores secrets in `~/.claude-sync-secrets.json` (never committed). Config files in the git repo use `{{SECRET:key}}` placeholders.

## Gotchas

- Plugin marketplace directories are full git repos with thousands of files. Always exclude `*/plugins/marketplaces/*/*` from find commands to avoid performance issues.
- SSH mode uses rsync/scp per-item (not a single staging dir) because it needs granular logging and per-file path transforms.
- The `SYNC_ITEMS` array from the original script was split into `CORE_SYNC_FILES` and `CORE_SYNC_DIRS` for cleaner iteration.
- `sed -i` needs `.bak` suffix on macOS (`sed -i.bak`). All sed in-place edits clean up the backup file.

## Testing

No automated tests. Verify manually:
- `bash -n` syntax check all files
- `claude-sync help` via symlink
- `claude-sync export --redact-secrets` produces valid tarball
- `claude-sync cloud-status` shows correct file count
- `claude-sync cloud-push` / `cloud-pull` round-trips correctly

## Claude-Mem Tags

Use tags: `claude-sync` for memories related to this project.
