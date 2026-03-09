# claude-sync

Sync Claude Code configuration across machines. Supports three transport modes:

- **Cloud sync** (git-backed, cross-platform): Push/pull config via a private GitHub repo
- **SSH sync** (direct machine-to-machine): Rsync-based sync to a remote server
- **Portable export/import** (no network needed): Create self-installing tarballs

## Install

```bash
git clone git@github.com:natefikru/claude-sync.git ~/go/src/natefikru/claude-sync
cd ~/go/src/natefikru/claude-sync
./install.sh
```

This symlinks `claude-sync` into `~/.claude/bin/`. Make sure `~/.claude/bin` is in your PATH.

## Usage

```bash
# Cloud sync (recommended for cross-platform)
claude-sync cloud-init                    # First time: create private GitHub repo
claude-sync cloud-push                    # Push local config changes
claude-sync cloud-pull                    # Pull remote changes (backs up first)
claude-sync cloud-status                  # Show sync status and drift
claude-sync cloud-bootstrap <url>         # Set up new machine from existing repo

# SSH sync (direct to remote server)
claude-sync push                          # Push local config to remote
claude-sync pull                          # Pull remote config to local
claude-sync diff                          # Dry-run: show what would change
claude-sync status                        # Compare local vs remote
claude-sync bootstrap                     # Install runtime deps on remote
claude-sync verify                        # Verify MCP servers and plugins work

# Portable export/import
claude-sync export [--redact-secrets]     # Create portable config tarball
claude-sync import <tarball> [--force]    # Install config from tarball
```

## What Gets Synced

Core config from `~/.claude/`:

| Item | Description |
|------|-------------|
| `CLAUDE.md` | Global instructions |
| `settings.json` | Claude Code settings |
| `settings.local.json` | Local overrides |
| `mcp_settings.json` | MCP server config |
| `ccstatusline.sh` | Status line script |
| `hooks/` | Pre/post tool use hooks |
| `commands/` | Custom slash commands |
| `skills/` | Custom skills |
| `bin/` | CLI scripts (including claude-sync itself) |
| `plugins/` | Plugin marketplace configs and blocklist |

Additional items (varies by mode):

| Item | Cloud | SSH | Export |
|------|-------|-----|--------|
| `projects/` | No | Yes | Yes |
| `~/.claude.json` (smart merge) | Yes | Yes | Yes |
| `~/.claude-mem/settings.json` | Yes | Yes | Yes |
| `~/.config/ccstatusline/` | Yes | Yes | Yes |
| Extra dotfile dirs | No | Yes | Yes |
| MCP server source | No | Yes | Yes |
| Plugin cache | No | Yes | Yes |

## Path Rewriting

All modes automatically rewrite absolute paths when syncing between machines:

- **SSH**: `/Users/natefikru` to `/home/natefikru` (and vice versa)
- **Cloud**: Concrete paths to `{{HOME}}` tokens (portable across any machine)
- **Export**: Source home to target home (resolved at install time)

JSON files get deep replacement (walks all nested values). Plain text files use sed.

## Secret Handling

MCP settings may contain API tokens. These are handled differently per mode:

- **Cloud**: Secrets are replaced with `{{SECRET:key}}` placeholders before committing. Actual values are stored in `~/.claude-sync-secrets.json` (local only, never committed).
- **Export**: Use `--redact-secrets` to replace tokens with placeholders. Without the flag, secrets are included as-is.
- **SSH**: Secrets are synced directly (encrypted in transit via SSH).

## Smart Merge

`~/.claude.json` is never fully overwritten. Only these keys are synced: `mcpServers`, `theme`, `teammateMode`. All other keys (local-only settings) are preserved.

## Architecture

```
claude-sync              Main entrypoint: config vars, module sourcing, dispatch
lib/
  common.sh              Shared: logging, allowlists, path rewriting, secret handling,
                           smart merge, file copying, config application, backup
  ssh.sh                 SSH transport: push, pull, diff, status, bootstrap, verify
  export.sh              Export/import: tarball creation, self-contained installer
  cloud.sh               Cloud sync: init, push, pull, status, bootstrap
install.sh               Symlinks claude-sync into ~/.claude/bin/
```

## Dependencies

- bash 4+
- python3 (JSON handling)
- rsync (SSH mode)
- gh CLI (cloud mode)
- git (cloud mode)

## License

Private. For personal use only.
