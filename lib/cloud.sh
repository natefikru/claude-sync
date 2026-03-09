#!/usr/bin/env bash
#
# cloud.sh: Git-backed cloud sync for claude-sync.
# Sourced by the main entrypoint. Requires common.sh.
#

# ── Cloud Config ──────────────────────────────────────────────────

CLOUD_SYNC_DIR="$HOME/.claude-sync"
CLOUD_SECRETS_FILE="$HOME/.claude-sync-secrets.json"
CLOUD_BACKUPS_DIR="$HOME/.claude-sync-backups"

# ── Cloud Init ────────────────────────────────────────────────────

cmd_cloud_init() {
  local repo_name="claude-config"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo_name="$2"; shift 2 ;;
      *) err "Unknown option: $1"; exit 1 ;;
    esac
  done

  if ! command -v gh >/dev/null 2>&1; then
    err "GitHub CLI (gh) is required for cloud-init."
    info "Install: https://cli.github.com/"
    exit 1
  fi

  if ! gh auth status >/dev/null 2>&1; then
    err "GitHub CLI not authenticated. Run: gh auth login"
    exit 1
  fi

  if [ -d "$CLOUD_SYNC_DIR/.git" ]; then
    err "Cloud sync already initialized at $CLOUD_SYNC_DIR"
    info "Use 'cloud-push' to sync changes, or remove $CLOUD_SYNC_DIR to reinitialize."
    exit 1
  fi

  local gh_user
  gh_user=$(gh api user --jq '.login' 2>/dev/null) || true
  if [ -z "$gh_user" ]; then
    err "Could not determine GitHub username."
    exit 1
  fi

  info "Initializing cloud sync..."
  info "  GitHub user: $gh_user"
  info "  Repository: $repo_name"
  echo ""

  local repo_existed=false
  if gh repo create "$repo_name" --private --description "Claude Code config (synced by claude-sync)" 2>/dev/null; then
    ok "Created private repo: $gh_user/$repo_name"
  else
    repo_existed=true
    info "Repository $gh_user/$repo_name already exists"
  fi

  local remote_url="git@github.com:$gh_user/$repo_name.git"

  mkdir -p "$CLOUD_SYNC_DIR"
  cd "$CLOUD_SYNC_DIR"

  if [ "$repo_existed" = true ]; then
    info "Cloning existing repo..."
    git clone "$remote_url" . 2>/dev/null || {
      git init -b main
      git remote add origin "$remote_url"
    }
  else
    git init -b main
    git remote add origin "$remote_url"
  fi

  git config user.email "$(git config --global user.email 2>/dev/null || echo 'claude-sync@local')"
  git config user.name "$(git config --global user.name 2>/dev/null || echo 'claude-sync')"

  cat > .gitattributes << 'EOF'
* text=auto eol=lf
*.json text eol=lf
*.md text eol=lf
*.js text eol=lf
*.sh text eol=lf
EOF

  _cloud_write_meta "$CLOUD_SYNC_DIR"

  git add .gitattributes .cloud-sync-meta.json
  git commit -m "chore: initialize cloud sync repo" 2>/dev/null || true

  # Copy config to repo
  info "Copying config to sync repo..."
  local file_count
  file_count=$(copy_claude_config "$LOCAL_CLAUDE_DIR" "$CLOUD_SYNC_DIR")

  # Apply path rewriting (HOME -> {{HOME}})
  rewrite_all_paths "$CLOUD_SYNC_DIR/claude" "$HOME" "{{HOME}}"
  _cloud_rewrite_extra_paths "$CLOUD_SYNC_DIR" "$HOME" "{{HOME}}"

  # Redact secrets
  if [ -f "$CLOUD_SYNC_DIR/claude/mcp_settings.json" ]; then
    redact_secrets "$CLOUD_SYNC_DIR/claude/mcp_settings.json" "$CLOUD_SECRETS_FILE"
    info "  Secrets extracted to $CLOUD_SECRETS_FILE"
  fi

  git add -A
  git commit -m "feat: initial sync of claude config" 2>/dev/null || true
  git push -u origin main 2>/dev/null || git push --set-upstream origin main

  echo ""
  ok "Cloud sync initialized!"
  info "  Sync repo: $CLOUD_SYNC_DIR"
  info "  Remote: $remote_url"
  info "  Files synced: $file_count"
  if [ -f "$CLOUD_SECRETS_FILE" ]; then
    info "  Secrets file: $CLOUD_SECRETS_FILE (local only, never committed)"
  fi
  echo ""
  info "Next steps:"
  info "  cloud-push    Push config changes"
  info "  cloud-pull    Pull config from remote"
  info "  cloud-status  Check sync state"
}

# ── Cloud Push ────────────────────────────────────────────────────

cmd_cloud_push() {
  if [ ! -d "$CLOUD_SYNC_DIR/.git" ]; then
    err "Cloud sync not initialized. Run: claude-sync cloud-init"
    exit 1
  fi

  cd "$CLOUD_SYNC_DIR"

  git fetch origin 2>/dev/null || true
  local behind
  behind=$(git rev-list --count HEAD..origin/main 2>/dev/null || echo "0")
  if [ "$behind" -gt 0 ]; then
    err "Remote is $behind commit(s) ahead. Run 'claude-sync cloud-pull' first."
    exit 1
  fi

  info "Scanning config..."

  local file_count
  file_count=$(copy_claude_config "$LOCAL_CLAUDE_DIR" "$CLOUD_SYNC_DIR")

  rewrite_all_paths "$CLOUD_SYNC_DIR/claude" "$HOME" "{{HOME}}"
  _cloud_rewrite_extra_paths "$CLOUD_SYNC_DIR" "$HOME" "{{HOME}}"

  if [ -f "$CLOUD_SYNC_DIR/claude/mcp_settings.json" ]; then
    redact_secrets "$CLOUD_SYNC_DIR/claude/mcp_settings.json" "$CLOUD_SECRETS_FILE"
  fi

  _cloud_write_meta "$CLOUD_SYNC_DIR"

  git add -A

  if git diff --cached --quiet; then
    ok "No changes to push (already up to date)"
    return 0
  fi

  local changed_files
  changed_files=$(git diff --cached --name-only | wc -l | tr -d ' ')

  git commit -m "sync: update claude config"
  git push origin main

  echo ""
  ok "Pushed $changed_files file(s) to remote"
}

# ── Cloud Pull ────────────────────────────────────────────────────

cmd_cloud_pull() {
  if [ ! -d "$CLOUD_SYNC_DIR/.git" ]; then
    err "Cloud sync not initialized. Run: claude-sync cloud-init"
    exit 1
  fi

  cd "$CLOUD_SYNC_DIR"

  info "Creating backup..."
  local backup_dir
  backup_dir=$(create_backup "$CLOUD_BACKUPS_DIR")
  info "  Backup: $backup_dir"

  info "Pulling from remote..."
  git pull origin main 2>/dev/null || {
    err "Git pull failed. Check your network connection and remote configuration."
    exit 1
  }

  # Expand paths ({{HOME}} -> actual home)
  rewrite_all_paths "$CLOUD_SYNC_DIR/claude" "{{HOME}}" "$HOME"
  _cloud_rewrite_extra_paths "$CLOUD_SYNC_DIR" "{{HOME}}" "$HOME"

  # Read source home from metadata for project dir renaming
  local source_home=""
  if [ -f "$CLOUD_SYNC_DIR/.cloud-sync-meta.json" ]; then
    source_home=$(python3 -c "
import json
with open('$CLOUD_SYNC_DIR/.cloud-sync-meta.json') as f:
    meta = json.load(f)
print(meta.get('sourceHome', ''))
" 2>/dev/null || echo "")
  fi

  info "Applying config..."
  local file_count
  file_count=$(apply_config_to_local "$CLOUD_SYNC_DIR" "$LOCAL_CLAUDE_DIR" "$CLOUD_SECRETS_FILE" "$source_home")

  # Re-apply path rewriting back to repo format
  rewrite_all_paths "$CLOUD_SYNC_DIR/claude" "$HOME" "{{HOME}}"
  _cloud_rewrite_extra_paths "$CLOUD_SYNC_DIR" "$HOME" "{{HOME}}"

  if [ -f "$CLOUD_SYNC_DIR/claude/mcp_settings.json" ]; then
    redact_secrets "$CLOUD_SYNC_DIR/claude/mcp_settings.json" "$CLOUD_SECRETS_FILE"
  fi

  echo ""
  ok "Pulled and applied config ($file_count items)"
  info "  Backup at: $backup_dir"
}

# ── Cloud Status ──────────────────────────────────────────────────

cmd_cloud_status() {
  if [ ! -d "$CLOUD_SYNC_DIR/.git" ]; then
    err "Cloud sync not initialized. Run: claude-sync cloud-init"
    exit 1
  fi

  cd "$CLOUD_SYNC_DIR"

  git fetch origin 2>/dev/null || warn "Could not fetch remote"

  local ahead behind
  ahead=$(git rev-list --count origin/main..HEAD 2>/dev/null || echo "0")
  behind=$(git rev-list --count HEAD..origin/main 2>/dev/null || echo "0")

  # Copy current config to temp area for comparison
  local tmp_dir
  tmp_dir=$(mktemp -d)
  trap "rm -rf '$tmp_dir'" RETURN

  copy_claude_config "$LOCAL_CLAUDE_DIR" "$tmp_dir" >/dev/null 2>&1

  rewrite_all_paths "$tmp_dir/claude" "$HOME" "{{HOME}}"
  _cloud_rewrite_extra_paths "$tmp_dir" "$HOME" "{{HOME}}"

  if [ -f "$tmp_dir/claude/mcp_settings.json" ]; then
    redact_secrets "$tmp_dir/claude/mcp_settings.json" 2>/dev/null
  fi

  # Compare against repo
  local has_changes=false
  local modified=()
  local added=()
  local deleted=()

  while IFS= read -r file; do
    [ -f "$file" ] || continue
    local rel_path="${file#$tmp_dir/}"
    local repo_file="$CLOUD_SYNC_DIR/$rel_path"

    if [ ! -f "$repo_file" ]; then
      added+=("$rel_path")
      has_changes=true
    elif ! diff -q "$file" "$repo_file" >/dev/null 2>&1; then
      modified+=("$rel_path")
      has_changes=true
    fi
  done < <(find "$tmp_dir" -type f -not -name '.DS_Store' -not -path '*/plugins/marketplaces/*/*')

  # Check for deleted files (in repo but not in temp)
  while IFS= read -r file; do
    [ -f "$file" ] || continue
    local rel_path="${file#$CLOUD_SYNC_DIR/}"
    [[ "$rel_path" == .git* ]] && continue
    [[ "$rel_path" == .gitattributes ]] && continue
    [[ "$rel_path" == .cloud-sync-meta.json ]] && continue

    if [ ! -f "$tmp_dir/$rel_path" ]; then
      deleted+=("$rel_path")
      has_changes=true
    fi
  done < <(find "$CLOUD_SYNC_DIR" -type f -not -path '*/.git/*' -not -name '.DS_Store' -not -path '*/plugins/marketplaces/*/*')

  # Display results
  if [ "$has_changes" = false ] && [ "$ahead" = "0" ] && [ "$behind" = "0" ]; then
    ok "Everything is in sync"
  else
    if [ ${#modified[@]} -gt 0 ]; then
      echo "Local changes:"
      for f in "${modified[@]}"; do
        echo "  M $f"
      done
    fi

    if [ ${#added[@]} -gt 0 ]; then
      for f in "${added[@]}"; do
        echo "  A $f"
      done
    fi

    if [ ${#deleted[@]} -gt 0 ]; then
      for f in "${deleted[@]}"; do
        echo "  D $f"
      done
    fi

    if [ "$behind" -gt 0 ]; then
      warn "Remote is $behind commit(s) ahead. Run 'claude-sync cloud-pull'"
    fi

    if [ "$ahead" -gt 0 ]; then
      info "Local is $ahead commit(s) ahead. Run 'claude-sync cloud-push'"
    fi
  fi

  # Show meta info (count allowlisted files, skip deep marketplace trees)
  local synced_count
  synced_count=$(find "$CLOUD_SYNC_DIR" -type f \
    -not -path '*/.git/*' \
    -not -path '*/plugins/marketplaces/*/*' \
    -not -name '.gitattributes' \
    -not -name '.cloud-sync-meta.json' \
    -not -name '.DS_Store' \
    | wc -l | tr -d ' ')
  # Add marketplace count as directory entries, not individual files
  local mp_count=0
  if [ -d "$CLOUD_SYNC_DIR/claude/plugins/marketplaces" ]; then
    mp_count=$(find "$CLOUD_SYNC_DIR/claude/plugins/marketplaces" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  fi
  synced_count=$((synced_count + mp_count))
  echo ""
  info "Synced files: $synced_count"
  if [ -f "$CLOUD_SECRETS_FILE" ]; then
    local secret_count
    secret_count=$(python3 -c "import json; print(len(json.load(open('$CLOUD_SECRETS_FILE'))))" 2>/dev/null || echo "0")
    info "Secrets managed: $secret_count (stored locally)"
  fi
}

# ── Cloud Bootstrap ───────────────────────────────────────────────

cmd_cloud_bootstrap() {
  local repo_url=""
  local secrets_file=""
  local force=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --secrets-file) secrets_file="$2"; shift 2 ;;
      --force) force=true; shift ;;
      -*) err "Unknown option: $1"; exit 1 ;;
      *) repo_url="$1"; shift ;;
    esac
  done

  if [ -z "$repo_url" ]; then
    err "Usage: claude-sync cloud-bootstrap <repo-url> [--secrets-file <path>] [--force]"
    exit 1
  fi

  if [ -d "$CLOUD_SYNC_DIR/.git" ] && [ "$force" != true ]; then
    err "Cloud sync repo already exists at $CLOUD_SYNC_DIR"
    info "Use --force to re-clone, or 'cloud-pull' to update."
    exit 1
  fi

  info "Bootstrapping from: $repo_url"

  if [ "$force" = true ] && [ -d "$CLOUD_SYNC_DIR" ]; then
    rm -rf "$CLOUD_SYNC_DIR"
  fi

  git clone "$repo_url" "$CLOUD_SYNC_DIR" || {
    err "Clone failed. Check your repository URL and authentication."
    exit 1
  }

  cd "$CLOUD_SYNC_DIR"
  git config user.email "$(git config --global user.email 2>/dev/null || echo 'claude-sync@local')"
  git config user.name "$(git config --global user.name 2>/dev/null || echo 'claude-sync')"

  # Backup existing config
  if [ -d "$LOCAL_CLAUDE_DIR" ]; then
    info "Backing up existing config..."
    local backup_dir
    backup_dir=$(create_backup "$CLOUD_BACKUPS_DIR")
    info "  Backup: $backup_dir"
  fi

  # Handle secrets
  if [ -n "$secrets_file" ] && [ -f "$secrets_file" ]; then
    cp "$secrets_file" "$CLOUD_SECRETS_FILE"
    chmod 600 "$CLOUD_SECRETS_FILE"
    info "Secrets loaded from: $secrets_file"
  elif [ ! -f "$CLOUD_SECRETS_FILE" ]; then
    if [ -f "$CLOUD_SYNC_DIR/claude/mcp_settings.json" ]; then
      local has_placeholders
      has_placeholders=$(grep -c '{{SECRET:' "$CLOUD_SYNC_DIR/claude/mcp_settings.json" 2>/dev/null || echo "0")
      if [ "$has_placeholders" -gt 0 ]; then
        warn "Config contains $has_placeholders secret placeholder(s)."
        warn "You need to create $CLOUD_SECRETS_FILE with your secret values."
        echo ""
        info "Required secrets:"
        for secret_path in "${SECRET_PATHS[@]}"; do
          echo "  - $secret_path"
        done
        echo ""
        info "Create the file manually:"
        echo "  cat > $CLOUD_SECRETS_FILE << 'EOF'"
        echo "  {"
        local first=true
        for secret_path in "${SECRET_PATHS[@]}"; do
          if [ "$first" = true ]; then
            echo "    \"$secret_path\": \"YOUR_VALUE_HERE\""
            first=false
          else
            echo "    ,\"$secret_path\": \"YOUR_VALUE_HERE\""
          fi
        done
        echo "  }"
        echo "  EOF"
        echo "  chmod 600 $CLOUD_SECRETS_FILE"
      fi
    fi
  fi

  # Read source home from metadata
  local source_home=""
  if [ -f "$CLOUD_SYNC_DIR/.cloud-sync-meta.json" ]; then
    source_home=$(python3 -c "
import json
with open('$CLOUD_SYNC_DIR/.cloud-sync-meta.json') as f:
    meta = json.load(f)
print(meta.get('sourceHome', ''))
" 2>/dev/null || echo "")
  fi

  # Expand paths
  rewrite_all_paths "$CLOUD_SYNC_DIR/claude" "{{HOME}}" "$HOME"
  _cloud_rewrite_extra_paths "$CLOUD_SYNC_DIR" "{{HOME}}" "$HOME"

  # Apply to local
  info "Applying config..."
  mkdir -p "$LOCAL_CLAUDE_DIR"
  local file_count
  file_count=$(apply_config_to_local "$CLOUD_SYNC_DIR" "$LOCAL_CLAUDE_DIR" "$CLOUD_SECRETS_FILE" "$source_home")

  # Re-apply repo format
  rewrite_all_paths "$CLOUD_SYNC_DIR/claude" "$HOME" "{{HOME}}"
  _cloud_rewrite_extra_paths "$CLOUD_SYNC_DIR" "$HOME" "{{HOME}}"

  if [ -f "$CLOUD_SYNC_DIR/claude/mcp_settings.json" ]; then
    redact_secrets "$CLOUD_SYNC_DIR/claude/mcp_settings.json" "$CLOUD_SECRETS_FILE" 2>/dev/null
  fi

  echo ""
  ok "Bootstrap complete! ($file_count items applied)"
  info "  Sync repo: $CLOUD_SYNC_DIR"
  if [ -d "$LOCAL_CLAUDE_DIR" ]; then
    info "  Config: $LOCAL_CLAUDE_DIR"
  fi
  echo ""
  info "Next steps:"
  info "  cloud-push    Push config changes"
  info "  cloud-pull    Pull config from remote"
  info "  cloud-status  Check sync state"
  if [ ! -f "$CLOUD_SECRETS_FILE" ]; then
    warn "  Create $CLOUD_SECRETS_FILE with your API tokens"
  fi
}

# ── Cloud Helpers ─────────────────────────────────────────────────

_cloud_write_meta() {
  local repo_dir="$1"
  python3 -c "
import json
meta = {
    'sourceHome': '$HOME',
    'sourceUser': '$(whoami)',
    'sourceHost': '$(hostname -s)',
    'sourcePlatform': '$(uname -s)',
    'sourceArch': '$(uname -m)',
    'version': '1.0'
}
with open('$repo_dir/.cloud-sync-meta.json', 'w') as f:
    json.dump(meta, f, indent=2)
    f.write('\n')
"
}

_cloud_rewrite_extra_paths() {
  # Rewrite paths in files outside the claude/ subdirectory
  local repo_dir="$1" from="$2" to="$3"

  # claude-json
  if [ -f "$repo_dir/claude-json/claude.json" ]; then
    rewrite_paths "$repo_dir/claude-json/claude.json" "$from" "$to"
  fi

  # claude-mem settings
  if [ -f "$repo_dir/claude-mem/settings.json" ]; then
    rewrite_paths "$repo_dir/claude-mem/settings.json" "$from" "$to"
  fi
}
