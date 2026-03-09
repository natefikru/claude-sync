#!/usr/bin/env bash
#
# ssh.sh: SSH sync transport for claude-sync.
# Sourced by the main entrypoint. Requires common.sh.
#

# ── SSH Helpers ───────────────────────────────────────────────────

ssh_cmd() {
  ssh $SSH_OPTS "$REMOTE_HOST" "$@"
}

ssh_with_node() {
  ssh $SSH_OPTS "$REMOTE_HOST" "source ~/.nvm/nvm.sh 2>/dev/null; $*"
}

rsync_push() {
  local src="$1" dst="$2"
  local excludes=()
  for pattern in "${RSYNC_EXCLUDES[@]}"; do
    excludes+=(--exclude "$pattern")
  done
  rsync -avz --delete \
    -e "ssh $SSH_OPTS" \
    "${excludes[@]}" \
    "$src" "$REMOTE_HOST:$dst"
}

rsync_pull() {
  local src="$1" dst="$2"
  local excludes=()
  for pattern in "${RSYNC_EXCLUDES[@]}"; do
    excludes+=(--exclude "$pattern")
  done
  rsync -avz --delete \
    -e "ssh $SSH_OPTS" \
    "${excludes[@]}" \
    "$REMOTE_HOST:$src" "$dst"
}

rsync_dry() {
  local src="$1" dst="$2"
  local excludes=()
  for pattern in "${RSYNC_EXCLUDES[@]}"; do
    excludes+=(--exclude "$pattern")
  done
  rsync -avzn --delete \
    -e "ssh $SSH_OPTS" \
    "${excludes[@]}" \
    "$src" "$REMOTE_HOST:$dst"
}

require_ssh() {
  if ! ssh_cmd "echo ok" >/dev/null 2>&1; then
    err "Cannot connect to remote. Check that din-ssh works."
    exit 1
  fi
}

# ── Push ──────────────────────────────────────────────────────────

cmd_push() {
  info "Pushing local config to remote..."

  # Ensure remote directories exist
  ssh_cmd "mkdir -p $REMOTE_CLAUDE_DIR/hooks $REMOTE_CLAUDE_DIR/commands $REMOTE_CLAUDE_DIR/bin $REMOTE_CLAUDE_DIR/skills"

  # Sync individual files from ~/.claude/
  for item in "${CORE_SYNC_FILES[@]}"; do
    local src="$LOCAL_CLAUDE_DIR/$item"
    if [ ! -e "$src" ]; then
      warn "Skipping $item (not found locally)"
      continue
    fi
    info "Syncing $item (with path transform)"
    local tmp
    tmp=$(mktemp)
    cp "$src" "$tmp"
    rewrite_paths "$tmp" "$LOCAL_HOME" "$REMOTE_HOME"
    scp $SSH_OPTS "$tmp" "$REMOTE_HOST:$REMOTE_CLAUDE_DIR/$item"
    rm -f "$tmp"
  done

  # Sync core directories
  for item in "${CORE_SYNC_DIRS[@]}"; do
    local src="$LOCAL_CLAUDE_DIR/$item"
    [ -d "$src" ] || continue

    # hooks need individual path transform
    if [ "$item" = "hooks/" ]; then
      for hook_file in "$src"*; do
        [ -f "$hook_file" ] || continue
        local fname
        fname=$(basename "$hook_file")
        info "Syncing hooks/$fname (with path transform)"
        local tmp
        tmp=$(mktemp)
        cp "$hook_file" "$tmp"
        rewrite_paths "$tmp" "$LOCAL_HOME" "$REMOTE_HOME"
        scp $SSH_OPTS "$tmp" "$REMOTE_HOST:$REMOTE_CLAUDE_DIR/hooks/$fname"
        rm -f "$tmp"
        ssh_cmd "chmod +x $REMOTE_CLAUDE_DIR/hooks/$fname"
      done
    else
      info "Syncing $item"
      rsync_push "$src" "$REMOTE_CLAUDE_DIR/$item"
    fi
  done

  ssh_cmd "chmod +x $REMOTE_CLAUDE_DIR/ccstatusline.sh 2>/dev/null || true"
  ssh_cmd "chmod +x $REMOTE_CLAUDE_DIR/bin/* 2>/dev/null || true"

  # Sync plugin marketplaces
  if [ -d "$LOCAL_CLAUDE_DIR/plugins/marketplaces" ]; then
    info "Syncing plugin marketplaces/"
    ssh_cmd "mkdir -p $REMOTE_CLAUDE_DIR/plugins/marketplaces"
    rsync -avz --delete \
      -e "ssh $SSH_OPTS" \
      --exclude ".DS_Store" \
      --exclude ".git/" \
      "$LOCAL_CLAUDE_DIR/plugins/marketplaces/" "$REMOTE_HOST:$REMOTE_CLAUDE_DIR/plugins/marketplaces/" 2>&1 | tail -3
    ok "Plugin marketplaces synced"
  fi

  # Sync plugin cache
  if [ -d "$LOCAL_CLAUDE_DIR/plugins/cache" ]; then
    info "Syncing plugin cache/"
    ssh_cmd "mkdir -p $REMOTE_CLAUDE_DIR/plugins/cache"
    rsync -avz --delete \
      -e "ssh $SSH_OPTS" \
      --exclude ".DS_Store" \
      --exclude ".orphaned_at" \
      "$LOCAL_CLAUDE_DIR/plugins/cache/" "$REMOTE_HOST:$REMOTE_CLAUDE_DIR/plugins/cache/" 2>&1 | tail -3
    ok "Plugin cache synced"
  fi

  # Sync plugin JSON files (some need path transform, some are plain copies)
  for pfile in blocklist.json config.json; do
    if [ -f "$LOCAL_CLAUDE_DIR/plugins/$pfile" ]; then
      info "Syncing plugins/$pfile"
      scp $SSH_OPTS "$LOCAL_CLAUDE_DIR/plugins/$pfile" "$REMOTE_HOST:$REMOTE_CLAUDE_DIR/plugins/$pfile"
    fi
  done

  for pfile in installed_plugins.json known_marketplaces.json; do
    if [ -f "$LOCAL_CLAUDE_DIR/plugins/$pfile" ]; then
      info "Syncing $pfile (with path transform)"
      local tmp
      tmp=$(mktemp)
      cp "$LOCAL_CLAUDE_DIR/plugins/$pfile" "$tmp"
      rewrite_paths "$tmp" "$LOCAL_HOME" "$REMOTE_HOME"
      scp $SSH_OPTS "$tmp" "$REMOTE_HOST:$REMOTE_CLAUDE_DIR/plugins/$pfile"
      rm -f "$tmp"
    fi
  done

  # Sync ~/.claude.json with smart merge
  if [ -f "$LOCAL_CLAUDE_JSON" ]; then
    info "Syncing .claude.json (MCP config, with path transform)"
    local tmp_local tmp_remote tmp_merged
    tmp_local=$(mktemp)
    tmp_remote=$(mktemp)

    cp "$LOCAL_CLAUDE_JSON" "$tmp_local"
    rewrite_paths "$tmp_local" "$LOCAL_HOME" "$REMOTE_HOME"
    scp $SSH_OPTS "$REMOTE_HOST:$REMOTE_CLAUDE_JSON" "$tmp_remote" 2>/dev/null || echo '{}' > "$tmp_remote"

    smart_merge_claude_json "$tmp_local" "$tmp_remote"

    if [ -s "$tmp_remote" ]; then
      scp $SSH_OPTS "$tmp_remote" "$REMOTE_HOST:$REMOTE_CLAUDE_JSON"
      ok ".claude.json merged successfully"
    else
      warn "Failed to merge .claude.json, skipping"
    fi
    rm -f "$tmp_local" "$tmp_remote"
  fi

  # Sync project memory directories
  if [ "$SYNC_PROJECTS" = true ] && [ -d "$LOCAL_CLAUDE_DIR/projects" ]; then
    info "Syncing project memory directories..."
    rsync_push "$LOCAL_CLAUDE_DIR/projects/" "$REMOTE_CLAUDE_DIR/projects/"
    ok "Project directories synced"
  fi

  # Sync extra dotfile directories
  for dir in "${EXTRA_SYNC_DIRS[@]}"; do
    local src="$HOME/$dir"
    local dst="$REMOTE_HOME/$dir"

    if [ ! -d "$src" ]; then
      warn "Skipping ~/$dir (not found locally)"
      continue
    fi

    ssh_cmd "mkdir -p $dst"

    if [ "$dir" = ".claude-mem" ]; then
      info "Syncing ~/$dir/ (settings only, skipping DB)"
      local mem_excludes=()
      for pattern in "${CLAUDE_MEM_EXCLUDES[@]}"; do
        mem_excludes+=(--exclude "$pattern")
      done
      rsync -avz \
        -e "ssh $SSH_OPTS" \
        "${mem_excludes[@]}" \
        "$src/" "$REMOTE_HOST:$dst/"
      if [ -f "$src/settings.json" ]; then
        local tmp
        tmp=$(mktemp)
        cp "$src/settings.json" "$tmp"
        rewrite_paths "$tmp" "$LOCAL_HOME" "$REMOTE_HOME"
        scp $SSH_OPTS "$tmp" "$REMOTE_HOST:$dst/settings.json"
        rm -f "$tmp"
      fi
    else
      info "Syncing ~/$dir/"
      rsync_push "$src/" "$dst/"
    fi
  done

  # Sync ~/.config/ items
  for item in "${CONFIG_SYNC_ITEMS[@]}"; do
    local src="$HOME/.config/$item"
    local dst="$REMOTE_HOME/.config/$item"

    if [ ! -e "$src" ]; then
      warn "Skipping ~/.config/$item (not found locally)"
      continue
    fi

    ssh_cmd "mkdir -p $REMOTE_HOME/.config"

    if [ -d "$src" ]; then
      info "Syncing ~/.config/$item/"
      ssh_cmd "mkdir -p $dst"
      rsync_push "$src/" "$dst/"
    else
      info "Syncing ~/.config/$item"
      scp $SSH_OPTS "$src" "$REMOTE_HOST:$dst"
    fi
  done

  # Sync gws client secret
  local gws_secret="$HOME/Downloads/client_secret_1036819617271-egha8mutka5bdfi1eggs3gqsiuh2airm.apps.googleusercontent.com.json"
  if [ -f "$gws_secret" ]; then
    info "Syncing gws client secret"
    ssh_cmd "mkdir -p $REMOTE_HOME/.config/gws"
    scp $SSH_OPTS "$gws_secret" "$REMOTE_HOST:$REMOTE_HOME/.config/gws/client_secret.json"
    ok "gws client secret synced"
  fi

  # Sync project CLAUDE.md files
  info "Syncing project CLAUDE.md files..."
  for project in ${PROJECT_CLAUDE_MDS[@]+"${PROJECT_CLAUDE_MDS[@]}"}; do
    local src="$HOME/$project/CLAUDE.md"
    local dst="$REMOTE_HOME/$project/CLAUDE.md"

    if [ ! -f "$src" ]; then continue; fi

    if ssh_cmd "test -d $REMOTE_HOME/$project" 2>/dev/null; then
      info "  $project/CLAUDE.md"
      scp $SSH_OPTS "$src" "$REMOTE_HOST:$dst"
    else
      warn "  $project/ does not exist on remote, skipping CLAUDE.md"
    fi
  done

  # Sync MCP server source code
  if [ -d "$HOME/mcp-servers" ]; then
    info "Syncing ~/mcp-servers/"
    ssh_cmd "mkdir -p $REMOTE_HOME/mcp-servers"
    rsync -avz --delete \
      -e "ssh $SSH_OPTS" \
      --exclude ".DS_Store" \
      --exclude "node_modules/" \
      "$HOME/mcp-servers/" "$REMOTE_HOST:$REMOTE_HOME/mcp-servers/"
    ok "MCP server source synced (node_modules excluded, run bootstrap to install)"
  fi

  ok "Push complete!"
  echo ""
  info "Run 'claude-sync bootstrap' to install runtime deps and npm packages on remote."
  info "Run 'claude-sync verify' to confirm MCP servers and plugins work."
}

# ── Pull ──────────────────────────────────────────────────────────

cmd_pull() {
  warn "Pull syncs FROM remote TO local. Local is usually the source of truth."
  read -p "Are you sure? [y/N] " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    info "Aborted."
    return
  fi

  info "Pulling remote config to local..."

  # Core files with path transform
  for item in "${CORE_SYNC_FILES[@]}"; do
    local src="$REMOTE_CLAUDE_DIR/$item"
    local dst="$LOCAL_CLAUDE_DIR/$item"

    if ssh_cmd "test -f $src" 2>/dev/null; then
      info "Pulling $item (with path transform)"
      local tmp
      tmp=$(mktemp)
      scp $SSH_OPTS "$REMOTE_HOST:$src" "$tmp"
      rewrite_paths "$tmp" "$REMOTE_HOME" "$LOCAL_HOME"
      cp "$tmp" "$dst"
      rm -f "$tmp"
    else
      warn "Skipping $item (not found on remote)"
    fi
  done

  # Core dirs
  for item in "${CORE_SYNC_DIRS[@]}"; do
    local src="$REMOTE_CLAUDE_DIR/$item"
    local dst="$LOCAL_CLAUDE_DIR/$item"

    if ssh_cmd "test -d $src" 2>/dev/null; then
      info "Pulling $item"
      rsync_pull "$src" "$dst"
    else
      warn "Skipping $item (not found on remote)"
    fi
  done

  # Extra dotfile directories
  for dir in "${EXTRA_SYNC_DIRS[@]}"; do
    local src="$REMOTE_HOME/$dir"
    local dst="$HOME/$dir"

    if ! ssh_cmd "test -d $src" 2>/dev/null; then
      warn "Skipping ~/$dir (not found on remote)"
      continue
    fi

    mkdir -p "$dst"

    if [ "$dir" = ".claude-mem" ]; then
      info "Pulling ~/$dir/ (settings only)"
      local mem_excludes=()
      for pattern in "${CLAUDE_MEM_EXCLUDES[@]}"; do
        mem_excludes+=(--exclude "$pattern")
      done
      rsync -avz \
        -e "ssh $SSH_OPTS" \
        "${mem_excludes[@]}" \
        "$REMOTE_HOST:$src/" "$dst/"
      if ssh_cmd "test -f $src/settings.json" 2>/dev/null; then
        local tmp
        tmp=$(mktemp)
        scp $SSH_OPTS "$REMOTE_HOST:$src/settings.json" "$tmp"
        rewrite_paths "$tmp" "$REMOTE_HOME" "$LOCAL_HOME"
        cp "$tmp" "$dst/settings.json"
        rm -f "$tmp"
      fi
    else
      info "Pulling ~/$dir/"
      rsync_pull "$src/" "$dst/"
    fi
  done

  # ~/.config/ items
  for item in "${CONFIG_SYNC_ITEMS[@]}"; do
    local src="$REMOTE_HOME/.config/$item"
    local dst="$HOME/.config/$item"

    if ssh_cmd "test -d $src" 2>/dev/null; then
      info "Pulling ~/.config/$item/"
      mkdir -p "$dst"
      rsync_pull "$src/" "$dst/"
    elif ssh_cmd "test -f $src" 2>/dev/null; then
      info "Pulling ~/.config/$item"
      scp $SSH_OPTS "$REMOTE_HOST:$src" "$dst"
    else
      warn "Skipping ~/.config/$item (not found on remote)"
    fi
  done

  ok "Pull complete!"
}

# ── Diff ──────────────────────────────────────────────────────────

cmd_diff() {
  info "Dry-run: showing what would change on push..."
  echo ""

  for item in "${CORE_SYNC_DIRS[@]}"; do
    local src="$LOCAL_CLAUDE_DIR/$item"
    [ -d "$src" ] || continue
    echo "--- $item ---"
    rsync_dry "$src" "$REMOTE_CLAUDE_DIR/$item" 2>/dev/null || true
    echo ""
  done

  # settings.json diff
  info "settings.json diff:"
  local tmp_local tmp_remote
  tmp_local=$(mktemp)
  tmp_remote=$(mktemp)
  cp "$LOCAL_CLAUDE_DIR/settings.json" "$tmp_local"
  rewrite_paths "$tmp_local" "$LOCAL_HOME" "$REMOTE_HOME"
  scp $SSH_OPTS "$REMOTE_HOST:$REMOTE_CLAUDE_DIR/settings.json" "$tmp_remote" 2>/dev/null || echo '{}' > "$tmp_remote"
  diff --color=auto -u "$tmp_remote" "$tmp_local" || true
  rm -f "$tmp_local" "$tmp_remote"

  echo ""
  info "CLAUDE.md diff:"
  local tmp_remote_md
  tmp_remote_md=$(mktemp)
  scp $SSH_OPTS "$REMOTE_HOST:$REMOTE_CLAUDE_DIR/CLAUDE.md" "$tmp_remote_md" 2>/dev/null || echo '' > "$tmp_remote_md"
  diff --color=auto -u "$tmp_remote_md" "$LOCAL_CLAUDE_DIR/CLAUDE.md" || true
  rm -f "$tmp_remote_md"

  # Project CLAUDE.md status
  echo ""
  info "Project CLAUDE.md files:"
  for project in ${PROJECT_CLAUDE_MDS[@]+"${PROJECT_CLAUDE_MDS[@]}"}; do
    local src="$HOME/$project/CLAUDE.md"
    if [ ! -f "$src" ]; then continue; fi
    if ssh_cmd "test -f $REMOTE_HOME/$project/CLAUDE.md" 2>/dev/null; then
      echo "  [exists] $project/CLAUDE.md"
    else
      echo "  [MISSING] $project/CLAUDE.md"
    fi
  done
}

# ── Status ────────────────────────────────────────────────────────

cmd_status() {
  info "Comparing local vs remote config..."
  echo ""

  # settings.json
  local local_hash remote_hash
  local tmp_settings
  tmp_settings=$(mktemp)
  cp "$LOCAL_CLAUDE_DIR/settings.json" "$tmp_settings"
  rewrite_paths "$tmp_settings" "$LOCAL_HOME" "$REMOTE_HOME"
  local_hash=$(shasum -a 256 "$tmp_settings" | cut -d' ' -f1)
  rm -f "$tmp_settings"
  remote_hash=$(ssh_cmd "sha256sum $REMOTE_CLAUDE_DIR/settings.json 2>/dev/null | cut -d' ' -f1" || echo "missing")
  if [ "$local_hash" = "$remote_hash" ]; then
    ok "settings.json: in sync"
  else
    warn "settings.json: OUT OF SYNC"
  fi

  # CLAUDE.md
  local_hash=$(shasum -a 256 "$LOCAL_CLAUDE_DIR/CLAUDE.md" | cut -d' ' -f1)
  remote_hash=$(ssh_cmd "sha256sum $REMOTE_CLAUDE_DIR/CLAUDE.md 2>/dev/null | cut -d' ' -f1" || echo "missing")
  if [ "$local_hash" = "$remote_hash" ]; then
    ok "CLAUDE.md: in sync"
  else
    warn "CLAUDE.md: OUT OF SYNC"
  fi

  # hooks
  local local_hooks remote_hooks
  local_hooks=$(ls "$LOCAL_CLAUDE_DIR/hooks/" 2>/dev/null | sort || true)
  remote_hooks=$(ssh_cmd "ls $REMOTE_CLAUDE_DIR/hooks/ 2>/dev/null || true" | sort || true)
  if [ "$local_hooks" = "$remote_hooks" ]; then
    ok "hooks/: in sync ($(echo "$local_hooks" | wc -w | tr -d ' ') files)"
  else
    warn "hooks/: OUT OF SYNC"
    echo "  Local:  $local_hooks"
    echo "  Remote: $remote_hooks"
  fi

  # ccstatusline
  if ssh_cmd "test -f $REMOTE_CLAUDE_DIR/ccstatusline.sh" 2>/dev/null; then
    ok "ccstatusline.sh: present on remote"
  else
    warn "ccstatusline.sh: MISSING on remote"
  fi

  # Skills
  local local_skills remote_skills
  local_skills=$(ls "$LOCAL_CLAUDE_DIR/skills/" 2>/dev/null | wc -l | tr -d ' ')
  remote_skills=$(ssh_cmd "ls $REMOTE_CLAUDE_DIR/skills/ 2>/dev/null | wc -l" | tr -d ' ' || echo "0")
  if [ "$local_skills" = "$remote_skills" ]; then
    ok "skills/: in sync ($local_skills items)"
  else
    warn "skills/: OUT OF SYNC (local: $local_skills, remote: $remote_skills)"
  fi

  # MCP servers config
  local local_mcps remote_mcps
  local_mcps=$(python3 -c "import sys,json; d=json.load(open('$LOCAL_CLAUDE_JSON')); print(','.join(sorted(d.get('mcpServers',{}).keys())))" 2>/dev/null || echo "none")
  remote_mcps=$(ssh_cmd "cat $REMOTE_CLAUDE_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(','.join(sorted(d.get('mcpServers',{}).keys())))" 2>/dev/null || echo "none")
  if [ "$local_mcps" = "$remote_mcps" ]; then
    ok ".claude.json mcpServers: in sync ($local_mcps)"
  else
    warn ".claude.json mcpServers: OUT OF SYNC"
    echo "  Local:  $local_mcps"
    echo "  Remote: $remote_mcps"
  fi

  # MCP server source
  if ssh_cmd "test -d $REMOTE_HOME/mcp-servers/din-health-mcp/dist" 2>/dev/null; then
    ok "~/mcp-servers/din-health-mcp: built on remote"
  elif ssh_cmd "test -d $REMOTE_HOME/mcp-servers/din-health-mcp" 2>/dev/null; then
    warn "~/mcp-servers/din-health-mcp: source present, needs 'npm install && npm run build'"
  else
    warn "~/mcp-servers/din-health-mcp: MISSING on remote"
  fi

  # Project CLAUDE.md files
  local proj_ok=0 proj_miss=0
  for project in ${PROJECT_CLAUDE_MDS[@]+"${PROJECT_CLAUDE_MDS[@]}"}; do
    if [ ! -f "$HOME/$project/CLAUDE.md" ]; then continue; fi
    if ssh_cmd "test -f $REMOTE_HOME/$project/CLAUDE.md" 2>/dev/null; then
      proj_ok=$((proj_ok + 1))
    else
      proj_miss=$((proj_miss + 1))
    fi
  done
  if [ "$proj_miss" -eq 0 ]; then
    ok "Project CLAUDE.md files: all synced ($proj_ok)"
  else
    warn "Project CLAUDE.md files: $proj_miss missing on remote ($proj_ok synced)"
  fi

  # Extra dotfile directories
  for dir in "${EXTRA_SYNC_DIRS[@]}"; do
    if [ -d "$HOME/$dir" ]; then
      if ssh_cmd "test -d $REMOTE_HOME/$dir" 2>/dev/null; then
        ok "~/$dir: present on both"
      else
        warn "~/$dir: MISSING on remote"
      fi
    fi
  done

  # Config items
  for item in "${CONFIG_SYNC_ITEMS[@]}"; do
    if [ -e "$HOME/.config/$item" ]; then
      if ssh_cmd "test -e $REMOTE_HOME/.config/$item" 2>/dev/null; then
        ok "~/.config/$item: present on both"
      else
        warn "~/.config/$item: MISSING on remote"
      fi
    fi
  done

  # Runtime tools on remote
  echo ""
  info "Runtime tools on remote:"
  ssh_with_node "
    export PATH=\$HOME/.local/bin:\$HOME/.bun/bin:/usr/local/go/bin:\$HOME/go/bin:\$PATH
    check() { command -v \$1 >/dev/null 2>&1 && echo \"  [ok] \$1: \$(\$1 --version 2>/dev/null || echo 'installed')\" || echo \"  [MISSING] \$1\"; }
    check node
    check npm
    check bun
    check go
    check claude
    check vercel
    check ccstatusline
    check agent-browser
    check gws
  " || warn "Could not check remote tools"

  echo ""
  info "Run 'claude-sync diff' for detailed differences."
  info "Run 'claude-sync push' to sync config files."
  info "Run 'claude-sync bootstrap' to install missing runtime tools."
}

# ── Bootstrap ─────────────────────────────────────────────────────

cmd_bootstrap() {
  info "Bootstrapping runtime dependencies on remote..."
  echo ""

  # Ensure nvm is sourced in .bashrc
  info "Ensuring nvm is in shell profile..."
  ssh_cmd 'grep -q "NVM_DIR" ~/.bashrc 2>/dev/null || cat >> ~/.bashrc << '\''NVMEOF'\''
# nvm
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
NVMEOF'
  ok "nvm configured in .bashrc"

  # Ensure PATH includes all tools
  local WANTED_PATH='export PATH="$HOME/.claude/bin:$HOME/.local/bin:$HOME/.bun/bin:/usr/local/go/bin:$HOME/go/bin:$PATH"'
  ssh_cmd "grep -q '/usr/local/go/bin' ~/.bashrc 2>/dev/null || (sed -i '/\.claude\/bin.*PATH/d' ~/.bashrc && echo '$WANTED_PATH' >> ~/.bashrc)"
  ok "Remote PATH configured (claude, bun, go, claude-sync)"

  # Install bun if missing
  info "Checking bun..."
  if ssh_cmd "command -v bun" >/dev/null 2>&1; then
    ok "bun already installed"
  else
    info "Installing bun..."
    ssh_cmd "curl -fsSL https://bun.sh/install | bash" 2>&1 | tail -3
    ok "bun installed"
  fi

  # Install global npm packages
  info "Installing global npm packages..."
  for pkg in "${NPM_GLOBAL_PACKAGES[@]}"; do
    info "  Installing $pkg..."
    ssh_with_node "npm install -g $pkg 2>&1" | tail -1
  done
  ok "Global npm packages installed"

  # Install gopls
  info "Installing gopls..."
  ssh_with_node "export PATH=/usr/local/go/bin:\$HOME/go/bin:\$PATH; go install golang.org/x/tools/gopls@latest 2>&1" | tail -2
  ok "gopls installed"

  # Fix stale /Users/ paths in installed_plugins.json
  ssh_cmd "sed -i 's|/Users/natefikru|/home/natefikru|g' $REMOTE_CLAUDE_DIR/plugins/installed_plugins.json 2>/dev/null || true"

  # Build MCP servers
  if ssh_cmd "test -d $REMOTE_HOME/mcp-servers/din-health-mcp/src" 2>/dev/null; then
    info "Building din-health-mcp..."
    ssh_with_node "cd $REMOTE_HOME/mcp-servers/din-health-mcp && npm install && npm run build 2>&1" | tail -5
    ok "din-health-mcp built"
  else
    warn "din-health-mcp source not found. Run 'claude-sync push' first."
  fi

  # Setup gws auth
  if ssh_cmd "test -f $REMOTE_HOME/.config/gws/client_secret.json" 2>/dev/null; then
    info "gws client secret is present on remote."
    info "To complete gws auth, SSH in and run: gws auth login"
  fi

  echo ""
  ok "Bootstrap complete!"
  info "Run 'claude-sync verify' to confirm everything works."
}

# ── Verify ────────────────────────────────────────────────────────

cmd_verify() {
  info "Verifying MCP servers and plugins on remote..."
  echo ""
  local failures=0

  # Check node
  info "Checking node..."
  local node_ver
  node_ver=$(ssh_with_node "node --version 2>/dev/null" || true)
  if [ -n "$node_ver" ]; then
    ok "node: $node_ver"
  else
    err "node not available (nvm not loading?)"
    failures=$((failures + 1))
  fi

  # Check bun
  info "Checking bun..."
  local bun_ver
  bun_ver=$(ssh_with_node "export PATH=\$HOME/.bun/bin:\$PATH; bun --version 2>/dev/null" || true)
  if [ -n "$bun_ver" ]; then
    ok "bun: $bun_ver"
  else
    err "bun not available"
    failures=$((failures + 1))
  fi

  # Check go
  info "Checking go..."
  local go_ver
  go_ver=$(ssh_with_node "export PATH=/usr/local/go/bin:\$PATH; go version 2>/dev/null" || true)
  if [ -n "$go_ver" ]; then
    ok "go: $go_ver"
  else
    err "go not available"
    failures=$((failures + 1))
  fi

  # Check claude
  info "Checking claude..."
  local claude_ver
  claude_ver=$(ssh_with_node "export PATH=\$HOME/.local/bin:\$PATH; claude --version 2>/dev/null" || true)
  if [ -n "$claude_ver" ]; then
    ok "claude: $claude_ver"
  else
    err "claude not available"
    failures=$((failures + 1))
  fi

  # Check CLI tools
  for tool in agent-browser gws vercel; do
    info "Checking $tool..."
    local tool_ver
    tool_ver=$(ssh_with_node "export PATH=\$HOME/.bun/bin:\$PATH; $tool --version 2>/dev/null" || true)
    if [ -n "$tool_ver" ]; then
      ok "$tool: $tool_ver"
    else
      err "$tool not found"
      failures=$((failures + 1))
    fi
  done

  # ccstatusline
  info "Checking ccstatusline..."
  if ssh_with_node "command -v ccstatusline >/dev/null 2>&1"; then
    local ccs_path
    ccs_path=$(ssh_with_node "which ccstatusline")
    ok "ccstatusline: installed ($ccs_path)"
  else
    err "ccstatusline not found"
    failures=$((failures + 1))
  fi

  # LSP servers
  info "Checking LSP servers..."
  for lsp in typescript-language-server pyright vtsls; do
    local lsp_ver
    lsp_ver=$(ssh_with_node "$lsp --version 2>/dev/null" || true)
    if [ -n "$lsp_ver" ]; then
      ok "LSP: $lsp $lsp_ver"
    else
      err "LSP: $lsp not found"
      failures=$((failures + 1))
    fi
  done

  local gopls_ver
  gopls_ver=$(ssh_with_node "export PATH=/usr/local/go/bin:\$HOME/go/bin:\$PATH; gopls version 2>/dev/null" || true)
  if [ -n "$gopls_ver" ]; then
    ok "LSP: gopls $(echo "$gopls_ver" | head -1)"
  else
    err "LSP: gopls not found"
    failures=$((failures + 1))
  fi

  # din-health MCP server
  info "Testing din-health MCP server..."
  if ssh_cmd "test -f $REMOTE_HOME/mcp-servers/din-health-mcp/dist/index.js" 2>/dev/null; then
    local mcp_test
    mcp_test=$(ssh_with_node "timeout 5 node $REMOTE_HOME/mcp-servers/din-health-mcp/dist/index.js --help 2>&1 || true" | head -3)
    if [ -n "$mcp_test" ]; then
      ok "din-health-mcp: binary runs"
    else
      ok "din-health-mcp: binary exists and is executable"
    fi
  else
    err "din-health-mcp: dist/index.js not found. Run 'claude-sync bootstrap'"
    failures=$((failures + 1))
  fi

  # playwright MCP
  info "Testing playwright MCP..."
  local pw_ver
  pw_ver=$(ssh_with_node "npx @playwright/mcp --version 2>/dev/null" || true)
  if [ -n "$pw_ver" ]; then
    ok "playwright MCP: $pw_ver"
  else
    err "playwright MCP not available"
    failures=$((failures + 1))
  fi

  # Plugins
  info "Checking plugins..."
  local remote_plugins
  remote_plugins=$(ssh_cmd "cat $REMOTE_CLAUDE_DIR/plugins/installed_plugins.json 2>/dev/null" || echo '{}')

  for plugin in "claude-mem@thedotmack" "gopls@claude-code-lsps" "pyright@claude-code-lsps" "vtsls@claude-code-lsps"; do
    if echo "$remote_plugins" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if '$plugin' in d.get('plugins',{}) else 1)" 2>/dev/null; then
      ok "plugin: $plugin installed"
    else
      warn "plugin: $plugin NOT installed (Claude will auto-install on next launch if enabled in settings)"
    fi
  done

  # settings.json structure
  info "Checking settings.json structure..."
  local settings_ok
  settings_ok=$(ssh_cmd "cat $REMOTE_CLAUDE_DIR/settings.json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
checks = []
checks.append(('hooks', 'hooks' in d))
checks.append(('statusLine', 'statusLine' in d))
checks.append(('enabledPlugins', 'enabledPlugins' in d))
checks.append(('model', 'model' in d))
for name, passed in checks:
    print(f'  {\"ok\" if passed else \"FAIL\"}: {name}')
if all(c[1] for c in checks):
    sys.exit(0)
else:
    sys.exit(1)
" 2>/dev/null || true)
  if [ -n "$settings_ok" ]; then
    echo "$settings_ok"
  else
    err "Could not validate settings.json"
    failures=$((failures + 1))
  fi

  echo ""
  if [ "$failures" -eq 0 ]; then
    ok "All checks passed!"
  else
    err "$failures check(s) failed. Review above and run 'claude-sync bootstrap' to fix."
  fi
}
