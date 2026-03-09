#!/usr/bin/env bash
#
# export.sh: Portable export/import for claude-sync.
# Sourced by the main entrypoint. Requires common.sh.
#

# ── Export ────────────────────────────────────────────────────────

cmd_export() {
  local redact_secrets_flag=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --redact-secrets) redact_secrets_flag=true; shift ;;
      *) err "Unknown option: $1"; exit 1 ;;
    esac
  done

  local date_stamp
  date_stamp=$(date +%Y-%m-%d)
  local export_name="claude-config-export-${date_stamp}"
  local tarball="${PWD}/${export_name}.tar.gz"
  if [ -f "$tarball" ]; then
    local suffix
    suffix=$(date +%H%M%S)
    export_name="claude-config-export-${date_stamp}-${suffix}"
    tarball="${PWD}/${export_name}.tar.gz"
  fi
  local tmp_base
  tmp_base=$(mktemp -d)
  trap "rm -rf '$tmp_base'" EXIT
  local export_dir="$tmp_base/$export_name"
  mkdir -p "$export_dir"

  info "Creating export: $export_name"
  if [ "$redact_secrets_flag" = true ]; then
    warn "Secrets will be REDACTED (replaced with placeholders)"
  else
    info "Secrets will be INCLUDED (use --redact-secrets to redact)"
  fi
  echo ""

  # Use shared copy function with all extras enabled
  local file_count
  file_count=$(copy_claude_config "$LOCAL_CLAUDE_DIR" "$export_dir" \
    --with-projects --with-extras --with-export-plugins)

  # Log what was added
  for d in claude-dir claude-json claude-mem extra-dotfiles config mcp-servers project-claude-mds; do
    # Map export layout: copy_claude_config uses "claude/" not "claude-dir/"
    local check_dir="$export_dir"
    case "$d" in
      claude-dir) check_dir="$export_dir/claude" ;;
      *) check_dir="$export_dir/$d" ;;
    esac
    if [ -d "$check_dir" ] || [ -f "$check_dir" ]; then
      info "  Added $d/"
    fi
  done

  # Rename claude/ to claude-dir/ for export layout compatibility
  if [ -d "$export_dir/claude" ]; then
    mv "$export_dir/claude" "$export_dir/claude-dir"
  fi

  # Rename claude-json/.claude.json for export compatibility (already correct from copy_claude_config)

  # Also copy mcp_settings.json separately for backward compat
  if [ -f "$export_dir/claude-dir/mcp_settings.json" ]; then
    mkdir -p "$export_dir/mcp-settings"
    cp "$export_dir/claude-dir/mcp_settings.json" "$export_dir/mcp-settings/mcp_settings.json"
  fi

  # Secrets redaction
  if [ "$redact_secrets_flag" = true ]; then
    info "Redacting secrets..."
    redact_secrets "$export_dir/mcp-settings/mcp_settings.json" 2>/dev/null || true
    redact_secrets "$export_dir/claude-dir/mcp_settings.json" 2>/dev/null || true
  fi

  # Generate manifest.json
  echo ""
  info "Generating manifest.json..."
  local secrets_redacted="False"
  [ "$redact_secrets_flag" = true ] && secrets_redacted="True"

  local secret_keys_json npm_pkgs_json
  secret_keys_json=$(printf '%s\n' "${SECRET_PATHS[@]}" | python3 -c "import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))")
  npm_pkgs_json=$(printf '%s\n' "${NPM_GLOBAL_PACKAGES[@]}" | python3 -c "import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))")

  python3 -c "
import json

manifest = {
    'exportDate': '${date_stamp}',
    'sourceHome': '$HOME',
    'sourceUser': '$(whoami)',
    'sourceHost': '$(hostname -s)',
    'sourcePlatform': '$(uname -s)',
    'sourceArch': '$(uname -m)',
    'secretsRedacted': ${secrets_redacted},
    'secretLocations': [
        'mcp-settings/mcp_settings.json',
        'claude-dir/mcp_settings.json'
    ],
    'secretKeys': json.loads('${secret_keys_json}'),
    'npmGlobalPackages': json.loads('${npm_pkgs_json}'),
    'manualSetupRequired': [
        'gws OAuth re-authentication (gws auth login)',
        'npm install in ~/mcp-servers/* directories',
        'Turnkey wallet re-authentication',
        'Claude Code login (claude login)'
    ]
}

with open('$export_dir/manifest.json', 'w') as f:
    json.dump(manifest, f, indent=2)
    f.write('\n')
"
  ok "manifest.json created"

  # Generate install.sh
  info "Generating install.sh..."
  _generate_install_sh "$export_dir"
  chmod +x "$export_dir/install.sh"
  ok "install.sh created"

  # Create tarball
  echo ""
  tar -czf "$tarball" -C "$tmp_base" "$export_name"

  local size
  size=$(du -sh "$tarball" | cut -f1)
  echo ""
  ok "Export created: $tarball ($size)"
  echo ""
  info "To install on a new machine:"
  info "  1. Copy the tarball to the new machine"
  info "  2. Run: claude-sync import $export_name.tar.gz"
  info "  Or manually: tar xzf $export_name.tar.gz && cd $export_name && ./install.sh"
}

_generate_install_sh() {
  local export_dir="$1"
  cat > "$export_dir/install.sh" << 'INSTALL_EOF'
#!/usr/bin/env bash
#
# install.sh: Install Claude Code configuration from export tarball.
#
# Usage:
#   ./install.sh [--force]

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[install]${NC} $*"; }
ok()    { echo -e "${GREEN}[ok]${NC} $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC} $*"; }
err()   { echo -e "${RED}[error]${NC} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=true; shift ;;
    *) err "Unknown option: $1"; exit 1 ;;
  esac
done

if [ ! -f "$SCRIPT_DIR/manifest.json" ]; then
  err "manifest.json not found. Are you running from inside the export directory?"
  exit 1
fi

SOURCE_HOME=$(python3 -c "import json; print(json.load(open('$SCRIPT_DIR/manifest.json'))['sourceHome'])")
TARGET_HOME="$HOME"

info "Source home: $SOURCE_HOME"
info "Target home: $TARGET_HOME"

if python3 -c "import json; d=json.load(open('$SCRIPT_DIR/manifest.json')); exit(0 if d.get('secretsRedacted') else 1)" 2>/dev/null; then
  warn "Secrets were REDACTED in this export."
  warn "You will need to manually fill in API tokens after installation."
  warn "Check: ~/.claude/mcp_settings.json"
fi
echo ""

transform_paths() {
  local file="$1"
  [ -f "$file" ] || return 0
  python3 -c "
import os, json, sys

src = '$SOURCE_HOME'
dst = '$TARGET_HOME'
with open('$file', 'r') as f:
    content = f.read()
if src == dst or src not in content:
    sys.exit(0)

if '$file'.endswith('.json'):
    try:
        data = json.loads(content)
        def deep_replace(obj):
            if isinstance(obj, str):
                return obj.replace(src, dst)
            elif isinstance(obj, dict):
                return {k: deep_replace(v) for k, v in obj.items()}
            elif isinstance(obj, list):
                return [deep_replace(v) for v in obj]
            return obj
        data = deep_replace(data)
        with open('$file', 'w') as f:
            json.dump(data, f, indent=2)
            f.write('\n')
        print(f'  Transformed paths in {os.path.basename(\"$file\")}')
        sys.exit(0)
    except json.JSONDecodeError:
        pass

content = content.replace(src, dst)
with open('$file', 'w') as f:
    f.write(content)
print(f'  Transformed paths in {os.path.basename(\"$file\")}')
" 2>/dev/null
}

confirm_overwrite() {
  local target="$1"
  if [ "$FORCE" = true ]; then return 0; fi
  if [ -e "$target" ]; then
    read -p "  Overwrite $target? [y/N] " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]] && return 0 || return 1
  fi
  return 0
}

smart_merge_claude_json() {
  local src="$1" dst="$2"
  if [ ! -f "$dst" ]; then
    cp "$src" "$dst"
    return
  fi
  python3 -c "
import json

with open('$src') as f:
    source = json.load(f)
with open('$dst') as f:
    target = json.load(f)

SYNC_KEYS = ['mcpServers', 'theme', 'teammateMode']
for key in SYNC_KEYS:
    if key in source:
        target[key] = source[key]

with open('$dst', 'w') as f:
    json.dump(target, f, indent=2)
    f.write('\n')
"
}

main_install() {
  local installed=()
  local skipped=()

  # Install claude-dir/ to ~/.claude/
  if [ -d "$SCRIPT_DIR/claude-dir" ]; then
    info "Installing ~/.claude/ config..."
    mkdir -p "$HOME/.claude"
    local item local_name target
    for item in "$SCRIPT_DIR/claude-dir/"*; do
      local_name=$(basename "$item")
      target="$HOME/.claude/$local_name"
      if confirm_overwrite "$target"; then
        if [ -d "$item" ]; then
          mkdir -p "$target"
          cp -R "$item/." "$target/" 2>/dev/null || cp -R "$item/"* "$target/" 2>/dev/null || true
        else
          cp "$item" "$target"
        fi
        installed+=("~/.claude/$local_name")
      else
        skipped+=("~/.claude/$local_name")
      fi
    done

    # Transform paths in known files
    for f in settings.json settings.local.json mcp_settings.json ccstatusline.sh; do
      transform_paths "$HOME/.claude/$f"
    done
    for f in plugins/installed_plugins.json plugins/known_marketplaces.json; do
      [ -f "$HOME/.claude/$f" ] && transform_paths "$HOME/.claude/$f"
    done

    # Transform hook files
    if [ -d "$HOME/.claude/hooks" ]; then
      for hook_file in "$HOME/.claude/hooks/"*; do
        [ -f "$hook_file" ] && transform_paths "$hook_file"
      done
    fi

    # Make scripts executable
    chmod +x "$HOME/.claude/bin/"* 2>/dev/null || true
    chmod +x "$HOME/.claude/hooks/"* 2>/dev/null || true
    chmod +x "$HOME/.claude/ccstatusline.sh" 2>/dev/null || true

    # Rename projects/ directories
    if [ -d "$HOME/.claude/projects" ]; then
      local src_prefix dst_prefix
      src_prefix=$(echo "$SOURCE_HOME" | sed 's|/|-|g')
      dst_prefix=$(echo "$TARGET_HOME" | sed 's|/|-|g')
      if [ "$src_prefix" != "$dst_prefix" ]; then
        info "Renaming project directories..."
        local proj_dir dir_name new_name
        for proj_dir in "$HOME/.claude/projects/"*; do
          [ -d "$proj_dir" ] || continue
          dir_name=$(basename "$proj_dir")
          new_name="${dir_name/$src_prefix/$dst_prefix}"
          if [ "$dir_name" != "$new_name" ]; then
            mv "$proj_dir" "$HOME/.claude/projects/$new_name"
            info "  Renamed $dir_name -> $new_name"
          fi
        done
        # Transform paths inside project memory files
        local f
        for proj_dir in "$HOME/.claude/projects/"*; do
          [ -d "$proj_dir" ] || continue
          find "$proj_dir" -name "*.md" -o -name "*.json" 2>/dev/null | while read -r f; do
            transform_paths "$f"
          done
        done
      fi
    fi
  fi

  # Install claude-json/ to ~/.claude.json
  if [ -f "$SCRIPT_DIR/claude-json/.claude.json" ]; then
    info "Installing ~/.claude.json (smart merge)..."
    local tmp_src
    tmp_src=$(mktemp)
    cp "$SCRIPT_DIR/claude-json/.claude.json" "$tmp_src"
    transform_paths "$tmp_src"
    if confirm_overwrite "$HOME/.claude.json"; then
      smart_merge_claude_json "$tmp_src" "$HOME/.claude.json"
      installed+=("~/.claude.json")
      ok "Merged mcpServers, theme, teammateMode into .claude.json"
    else
      skipped+=("~/.claude.json")
    fi
    rm -f "$tmp_src"
  fi

  # Install mcp-settings/ (only if not already installed via claude-dir/)
  if [ -f "$SCRIPT_DIR/mcp-settings/mcp_settings.json" ] && [ ! -f "$HOME/.claude/mcp_settings.json" ]; then
    info "Installing ~/.claude/mcp_settings.json..."
    mkdir -p "$HOME/.claude"
    cp "$SCRIPT_DIR/mcp-settings/mcp_settings.json" "$HOME/.claude/mcp_settings.json"
    transform_paths "$HOME/.claude/mcp_settings.json"
    installed+=("~/.claude/mcp_settings.json")
  fi

  # Install claude-mem/
  if [ -f "$SCRIPT_DIR/claude-mem/settings.json" ]; then
    info "Installing ~/.claude-mem/settings.json..."
    mkdir -p "$HOME/.claude-mem"
    if confirm_overwrite "$HOME/.claude-mem/settings.json"; then
      cp "$SCRIPT_DIR/claude-mem/settings.json" "$HOME/.claude-mem/settings.json"
      transform_paths "$HOME/.claude-mem/settings.json"
      installed+=("~/.claude-mem/settings.json")
    fi
  fi

  # Install extra-dotfiles/
  if [ -d "$SCRIPT_DIR/extra-dotfiles" ]; then
    local dir dir_name
    for dir in "$SCRIPT_DIR/extra-dotfiles/".*; do
      [ -d "$dir" ] || continue
      dir_name=$(basename "$dir")
      [ "$dir_name" = "." ] || [ "$dir_name" = ".." ] && continue
      info "Installing ~/$dir_name/..."
      if confirm_overwrite "$HOME/$dir_name"; then
        mkdir -p "$HOME/$dir_name"
        cp -R "$dir/." "$HOME/$dir_name/" 2>/dev/null || cp -R "$dir/"* "$HOME/$dir_name/" 2>/dev/null || true
        installed+=("~/$dir_name/")
      else
        skipped+=("~/$dir_name/")
      fi
    done
  fi

  # Install config/ to ~/.config/
  if [ -d "$SCRIPT_DIR/config" ]; then
    local item item_name
    for item in "$SCRIPT_DIR/config/"*; do
      item_name=$(basename "$item")
      info "Installing ~/.config/$item_name/..."
      if confirm_overwrite "$HOME/.config/$item_name"; then
        mkdir -p "$HOME/.config/$item_name"
        if [ -d "$item" ]; then
          cp -R "$item/." "$HOME/.config/$item_name/" 2>/dev/null || cp -R "$item/"* "$HOME/.config/$item_name/" 2>/dev/null || true
        else
          cp "$item" "$HOME/.config/$item_name"
        fi
        installed+=("~/.config/$item_name")
      else
        skipped+=("~/.config/$item_name")
      fi
    done
  fi

  # Install mcp-servers/
  if [ -d "$SCRIPT_DIR/mcp-servers" ]; then
    info "Installing ~/mcp-servers/ (source only)..."
    if confirm_overwrite "$HOME/mcp-servers"; then
      mkdir -p "$HOME/mcp-servers"
      cp -R "$SCRIPT_DIR/mcp-servers/." "$HOME/mcp-servers/" 2>/dev/null || true
      installed+=("~/mcp-servers/")
    else
      skipped+=("~/mcp-servers/")
    fi
  fi

  # Install project-claude-mds/
  if [ -d "$SCRIPT_DIR/project-claude-mds" ]; then
    info "Installing project CLAUDE.md files..."
    local md_file rel_path proj_dir target_dir
    while IFS= read -r md_file; do
      rel_path="${md_file#$SCRIPT_DIR/project-claude-mds/}"
      proj_dir=$(dirname "$rel_path")
      target_dir="$HOME/$proj_dir"
      if [ -d "$target_dir" ]; then
        if confirm_overwrite "$target_dir/CLAUDE.md"; then
          cp "$md_file" "$target_dir/CLAUDE.md"
          info "  Installed $proj_dir/CLAUDE.md"
        fi
      else
        warn "  Skipping $proj_dir/CLAUDE.md (directory does not exist)"
      fi
    done < <(find "$SCRIPT_DIR/project-claude-mds" -name "CLAUDE.md")
  fi

  # Summary
  echo ""
  echo "================================================================"
  ok "Installation complete!"
  echo ""

  if [ ${#installed[@]} -gt 0 ]; then
    info "Installed:"
    local item
    for item in "${installed[@]}"; do
      echo "  + $item"
    done
  fi

  if [ ${#skipped[@]} -gt 0 ]; then
    echo ""
    warn "Skipped (user declined):"
    local item
    for item in "${skipped[@]}"; do
      echo "  - $item"
    done
  fi

  echo ""
  info "Manual steps remaining:"
  python3 -c "
import json
m = json.load(open('$SCRIPT_DIR/manifest.json'))
for step in m.get('manualSetupRequired', []):
    print(f'  * {step}')
pkgs = m.get('npmGlobalPackages', [])
if pkgs:
    print()
    print('  npm global packages to install:')
    print(f\"  npm install -g {' '.join(pkgs)}\")
"
  echo "================================================================"
}

main_install
INSTALL_EOF
}

# ── Import ────────────────────────────────────────────────────────

cmd_import() {
  local tarball=""
  local force_flag=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force_flag="--force"; shift ;;
      -*) err "Unknown option: $1"; exit 1 ;;
      *) tarball="$1"; shift ;;
    esac
  done

  if [ -z "$tarball" ]; then
    err "Usage: claude-sync import <tarball> [--force]"
    exit 1
  fi

  if [ ! -f "$tarball" ]; then
    err "File not found: $tarball"
    exit 1
  fi

  info "Importing from: $tarball"

  local tmp_dir
  tmp_dir=$(mktemp -d)
  trap "rm -rf '$tmp_dir'" EXIT

  tar -xzf "$tarball" -C "$tmp_dir"

  local export_dir
  export_dir=$(find "$tmp_dir" -maxdepth 1 -type d -name "claude-config-export-*" | head -1)

  if [ -z "$export_dir" ] || [ ! -f "$export_dir/install.sh" ]; then
    err "Invalid export tarball. Expected claude-config-export-*/install.sh inside."
    exit 1
  fi

  info "Running installer..."
  echo ""
  bash "$export_dir/install.sh" $force_flag
}
