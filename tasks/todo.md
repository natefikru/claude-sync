# claude-sync Refactor Plan

## Goal

Unify the 3 feature sets (SSH sync, export/import, cloud sync) in `~/.claude/bin/claude-sync` (2600 lines, 91% duplicated) into a single tool with shared infrastructure, maintained in `natefikru/claude-sync` on GitHub.

## Status: COMPLETE

All phases implemented. Code written, syntax-checked, and cloud-status/export tested.

## Final Structure

```
~/go/src/natefikru/claude-sync/
  claude-sync        145 lines  Main entrypoint (config vars, module sourcing, dispatch)
  lib/
    common.sh        567 lines  Shared: logging, allowlists, rewrite_paths, secrets, smart_merge,
                                  copy_claude_config, apply_config_to_local, create_backup
    ssh.sh           802 lines  SSH transport: push, pull, diff, status, bootstrap, verify
    export.sh        535 lines  Export/import: cmd_export, _generate_install_sh, cmd_import
    cloud.sh         516 lines  Cloud sync: cloud-init, cloud-push, cloud-pull, cloud-status, cloud-bootstrap
  install.sh          36 lines  Installer: symlinks to ~/.claude/bin/claude-sync
  tasks/
    todo.md                     This file
```

Total: ~2600 lines across 6 files (vs 2600 in 1 file).

Line count stayed similar because:
- The embedded install.sh in export.sh must be fully self-contained (~200 lines, unavoidable)
- SSH module has lots of SSH-specific logic (bootstrap, verify) that was never duplicated

What was deduplicated:
- 5 path rewriters -> 1 (`rewrite_paths` + `rewrite_all_paths`)
- 3 smart merge implementations -> 1 (`smart_merge_claude_json`)
- 2 secret handlers -> 1 (`redact_secrets` + `restore_secrets`)
- 3 file copy loops -> 1 (`copy_claude_config`)
- 3 apply-to-local implementations -> 1 (`apply_config_to_local`)
- 2 allowlists -> 1 set of arrays with mode flags

## Phases

### Phase 1: Shared library (lib/common.sh) - DONE

- [x] 1.1 Unified allowlist arrays
- [x] 1.2 `rewrite_paths <file> <from> <to>`
- [x] 1.3 `rewrite_all_paths <dir> <from> <to>`
- [x] 1.4 `redact_secrets <file> [store_file]`
- [x] 1.5 `restore_secrets <file> <store_file>`
- [x] 1.6 `smart_merge_claude_json <src> <dst>`
- [x] 1.7 `copy_claude_config` with --with-projects, --with-extras, --with-export-plugins flags
- [x] 1.8 `apply_config_to_local` with secrets restoration and project dir renaming
- [x] 1.9 `create_backup`
- [x] 1.10 Logging helpers

### Phase 2: SSH module (lib/ssh.sh) - DONE

- [x] 2.1 SSH helpers (ssh_cmd, ssh_with_node, rsync_push, rsync_pull, rsync_dry, require_ssh)
- [x] 2.2 cmd_push (uses rewrite_paths, smart_merge_claude_json)
- [x] 2.3 cmd_pull (uses rewrite_paths)
- [x] 2.4 cmd_diff, cmd_status, cmd_bootstrap, cmd_verify

### Phase 3: Export module (lib/export.sh) - DONE

- [x] 3.1 cmd_export (uses copy_claude_config, redact_secrets)
- [x] 3.2 _generate_install_sh (self-contained, must work without common.sh)
- [x] 3.3 cmd_import

### Phase 4: Cloud module (lib/cloud.sh) - DONE

- [x] 4.1 Cloud-specific config (CLOUD_SYNC_DIR, CLOUD_SECRETS_FILE, CLOUD_BACKUPS_DIR)
- [x] 4.2 cmd_cloud_init (uses copy_claude_config, rewrite_all_paths, redact_secrets)
- [x] 4.3 cmd_cloud_push (same shared functions)
- [x] 4.4 cmd_cloud_pull (uses create_backup, apply_config_to_local, restore_secrets)
- [x] 4.5 cmd_cloud_status (uses copy_claude_config for temp comparison)
- [x] 4.6 cmd_cloud_bootstrap (uses apply_config_to_local, restore_secrets)

### Phase 5: Main entrypoint + installer - DONE

- [x] 5.1 Main claude-sync script (145 lines): config vars, source lib/*.sh, case dispatch
- [x] 5.2 install.sh: symlink claude-sync to ~/.claude/bin/
- [x] 5.3 Verify help works end-to-end
- [ ] 5.4 Initial commit + push to natefikru/claude-sync

### Phase 6: Bug fixes - PARTIALLY DONE

- [x] 6.1 Fix cloud-status synced file count (was 24901, now 93, excludes deep marketplace trees)
- [x] 6.2 Fix embedded git repo warning (exclude .git/ during copy via _copy_item and rsync)
- [ ] 6.3 Fix cloud secrets extraction (secrets file empty when source already uses placeholders)
- [ ] 6.4 Verify cloud-push, cloud-pull, cloud-status work after refactor
- [ ] 6.5 Verify SSH push/pull/diff/status work after refactor
- [ ] 6.6 Verify export/import work after refactor

## Remaining Work

- Run install.sh to symlink new version
- Test cloud-push with the refactored code
- Test SSH commands (requires remote connection)
- Test export/import round-trip
- Initial commit and push to natefikru/claude-sync
