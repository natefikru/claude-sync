#!/usr/bin/env bash
#
# common.sh: Shared infrastructure for claude-sync.
# Sourced by the main entrypoint. Never run directly.
#

# ── Logging ────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[sync]${NC} $*"; }
ok()    { echo -e "${GREEN}[ok]${NC} $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC} $*"; }
err()   { echo -e "${RED}[error]${NC} $*" >&2; }

# ── Unified Allowlists ────────────────────────────────────────────

# Core files/dirs from ~/.claude/ (all modes)
CORE_SYNC_FILES=(
  "CLAUDE.md"
  "settings.json"
  "settings.local.json"
  "mcp_settings.json"
  "ccstatusline.sh"
)

CORE_SYNC_DIRS=(
  "hooks/"
  "commands/"
  "skills/"
  "bin/"
)

# Plugin items from ~/.claude/plugins/
PLUGIN_SYNC_ITEMS=(
  "plugins/blocklist.json"
  "plugins/known_marketplaces.json"
  "plugins/config.json"
  "plugins/marketplaces/"
)

# Additional plugin items for export mode
PLUGIN_EXPORT_EXTRAS=(
  "plugins/cache/"
  "plugins/installed_plugins.json"
  "plugins/install-counts-cache.json"
)

# Files needing path rewriting (relative to claude dir in staging area)
PATH_TRANSFORM_TARGETS=(
  "settings.json"
  "settings.local.json"
  "ccstatusline.sh"
  "mcp_settings.json"
  "plugins/known_marketplaces.json"
  "plugins/installed_plugins.json"
)

# Directories whose contents need path rewriting
PATH_TRANSFORM_DIRS=(
  "hooks/"
  "bin/"
)

# Secret paths in JSON config (dot-notation keys)
SECRET_PATHS=(
  "mcpServers.github.env.GITHUB_PERSONAL_ACCESS_TOKEN"
  "mcpServers.slack.env.SLACK_MCP_XOXP_TOKEN"
)

# Keys to sync from ~/.claude.json via smart merge
CLAUDE_JSON_SYNC_KEYS=("mcpServers" "theme" "teammateMode")

# ── Path Rewriting ────────────────────────────────────────────────

rewrite_paths() {
  # Replace all occurrences of <from> with <to> in a file.
  # JSON-aware (python3 deep replace) for .json files, plain sed otherwise.
  local file="$1" from="$2" to="$3"
  [ -f "$file" ] || return 0

  if [[ "$file" == *.json ]]; then
    python3 -c "
import json, sys

src = '$from'
dst = '$to'
with open('$file') as f:
    content = f.read()
if src not in content:
    sys.exit(0)
try:
    data = json.loads(content)
except json.JSONDecodeError:
    content = content.replace(src, dst)
    with open('$file', 'w') as f:
        f.write(content)
    sys.exit(0)

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
"
  else
    if grep -q "$from" "$file" 2>/dev/null; then
      sed -i.bak "s|${from}|${to}|g" "$file" && rm -f "${file}.bak"
    fi
  fi
}

rewrite_all_paths() {
  # Walk all PATH_TRANSFORM_TARGETS and PATH_TRANSFORM_DIRS in a staged
  # directory and rewrite paths. The claude dir within the staging area
  # is passed as $1.
  local claude_dir="$1" from="$2" to="$3"

  for target in "${PATH_TRANSFORM_TARGETS[@]}"; do
    rewrite_paths "$claude_dir/$target" "$from" "$to"
  done

  for dir_target in "${PATH_TRANSFORM_DIRS[@]}"; do
    local dir_path="$claude_dir/$dir_target"
    [ -d "$dir_path" ] || continue
    for f in "$dir_path"*; do
      [ -f "$f" ] && rewrite_paths "$f" "$from" "$to"
    done
  done
}

# ── Secret Handling ───────────────────────────────────────────────

redact_secrets() {
  # Replace secret values with {{SECRET:key}} placeholders.
  # If store_file is provided, extract actual values there first.
  local file="$1"
  local store_file="${2:-}"
  [ -f "$file" ] || return 0

  python3 -c "
import json, os

SECRET_PATHS = [
$(printf "    '%s',\n" "${SECRET_PATHS[@]}")
]

store_file = '$store_file'

# Load or create secrets store
secrets = {}
if store_file and os.path.exists(store_file):
    with open(store_file) as f:
        secrets = json.load(f)

with open('$file') as f:
    data = json.load(f)

for path in SECRET_PATHS:
    parts = path.split('.')
    obj = data
    for part in parts[:-1]:
        if isinstance(obj, dict) and part in obj:
            obj = obj[part]
        else:
            obj = None
            break
    if obj is not None and isinstance(obj, dict) and parts[-1] in obj:
        val = obj[parts[-1]]
        if store_file and val and not str(val).startswith('{{SECRET:'):
            secrets[path] = val
        obj[parts[-1]] = '{{SECRET:' + path + '}}'

with open('$file', 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')

if store_file:
    with open(store_file, 'w') as f:
        json.dump(secrets, f, indent=2)
        f.write('\n')
    os.chmod(store_file, 0o600)
"
}

restore_secrets() {
  # Replace {{SECRET:key}} placeholders with actual values from store_file.
  local file="$1" store_file="$2"
  [ -f "$file" ] || return 0
  [ -f "$store_file" ] || return 0

  python3 -c "
import json

with open('$store_file') as f:
    secrets = json.load(f)

with open('$file') as f:
    data = json.load(f)

SECRET_PATHS = [
$(printf "    '%s',\n" "${SECRET_PATHS[@]}")
]

for path in SECRET_PATHS:
    parts = path.split('.')
    obj = data
    for part in parts[:-1]:
        if isinstance(obj, dict) and part in obj:
            obj = obj[part]
        else:
            obj = None
            break
    if obj is not None and isinstance(obj, dict) and parts[-1] in obj:
        placeholder = obj[parts[-1]]
        if isinstance(placeholder, str) and placeholder.startswith('{{SECRET:'):
            key = placeholder[9:-2]
            if key in secrets:
                obj[parts[-1]] = secrets[key]

with open('$file', 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
"
}

# ── Smart Merge for .claude.json ──────────────────────────────────

smart_merge_claude_json() {
  # Merge only CLAUDE_JSON_SYNC_KEYS from src into dst.
  # Creates dst if it doesn't exist.
  local src="$1" dst="$2"

  if [ ! -f "$dst" ]; then
    cp "$src" "$dst"
    return
  fi

  local keys_json
  keys_json=$(printf '%s\n' "${CLAUDE_JSON_SYNC_KEYS[@]}" | python3 -c "import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))")

  python3 -c "
import json

with open('$src') as f:
    source = json.load(f)
with open('$dst') as f:
    target = json.load(f)

SYNC_KEYS = json.loads('$keys_json')
for key in SYNC_KEYS:
    if key in source:
        target[key] = source[key]
    elif key in target:
        del target[key]

with open('$dst', 'w') as f:
    json.dump(target, f, indent=2)
    f.write('\n')
"
}

extract_claude_json_keys() {
  # Extract only CLAUDE_JSON_SYNC_KEYS from source .claude.json to dst file.
  local src="$1" dst="$2"

  local keys_json
  keys_json=$(printf '%s\n' "${CLAUDE_JSON_SYNC_KEYS[@]}" | python3 -c "import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))")

  python3 -c "
import json

with open('$src') as f:
    source = json.load(f)

SYNC_KEYS = json.loads('$keys_json')
extracted = {k: source[k] for k in SYNC_KEYS if k in source}

with open('$dst', 'w') as f:
    json.dump(extracted, f, indent=2)
    f.write('\n')
"
}

# ── File Copying ──────────────────────────────────────────────────

_copy_item() {
  # Copy a single file or directory, creating parent dirs as needed.
  # Excludes .DS_Store and .git/ from directory copies.
  local src="$1" dst="$2"
  if [ -d "$src" ]; then
    mkdir -p "$dst"
    rsync -a --delete --exclude '.DS_Store' --exclude '.git/' "$src" "$dst" 2>/dev/null || \
      cp -R "$src" "$dst" 2>/dev/null
  else
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
  fi
}

copy_claude_config() {
  # Copy allowlisted files from ~/.claude/ (and related locations) to a staging dir.
  #
  # Flags:
  #   --with-projects     Include projects/ directory
  #   --with-extras       Include extra dotfiles, config dirs, project CLAUDE.mds, mcp-servers
  #   --with-export-plugins  Include plugin cache and installed_plugins.json
  #
  # Layout in dst_dir:
  #   claude/         Core files from ~/.claude/
  #   claude-json/    Extracted keys from ~/.claude.json
  #   claude-mem/     settings.json from ~/.claude-mem/
  #   config/         Items from ~/.config/
  #   extra-dotfiles/ Extra dotfile dirs
  #   mcp-servers/    MCP server source
  #   project-claude-mds/  Project CLAUDE.md files

  local src_claude_dir="$1" dst_dir="$2"
  shift 2

  local with_projects=false
  local with_extras=false
  local with_export_plugins=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --with-projects) with_projects=true; shift ;;
      --with-extras) with_extras=true; shift ;;
      --with-export-plugins) with_export_plugins=true; shift ;;
      *) shift ;;
    esac
  done

  local count=0
  local claude_dst="$dst_dir/claude"
  mkdir -p "$claude_dst"

  # Core files
  for item in "${CORE_SYNC_FILES[@]}"; do
    local src="$src_claude_dir/$item"
    [ -e "$src" ] || continue
    cp "$src" "$claude_dst/$item"
    count=$((count + 1))
  done

  # Core dirs
  for item in "${CORE_SYNC_DIRS[@]}"; do
    local src="$src_claude_dir/$item"
    [ -d "$src" ] || continue
    local dst="$claude_dst/$item"
    mkdir -p "$dst"
    rsync -a --delete --exclude '.DS_Store' --exclude '.git/' "$src" "$dst" 2>/dev/null || \
      cp -R "$src" "$dst" 2>/dev/null
    count=$((count + 1))
  done

  # Plugin items
  for item in "${PLUGIN_SYNC_ITEMS[@]}"; do
    local src="$src_claude_dir/$item"
    [ -e "$src" ] || continue
    _copy_item "$src" "$claude_dst/$item"
    count=$((count + 1))
  done

  # Export-only plugin extras
  if [ "$with_export_plugins" = true ]; then
    for item in "${PLUGIN_EXPORT_EXTRAS[@]}"; do
      local src="$src_claude_dir/$item"
      [ -e "$src" ] || continue
      _copy_item "$src" "$claude_dst/$item"
      count=$((count + 1))
    done
  fi

  # Projects
  if [ "$with_projects" = true ] && [ -d "$src_claude_dir/projects" ]; then
    cp -R "$src_claude_dir/projects" "$claude_dst/projects"
    count=$((count + 1))
  fi

  # ~/.claude.json (extract sync keys only for cloud; full copy for export)
  if [ -f "$LOCAL_CLAUDE_JSON" ]; then
    mkdir -p "$dst_dir/claude-json"
    if [ "$with_extras" = true ]; then
      cp "$LOCAL_CLAUDE_JSON" "$dst_dir/claude-json/.claude.json"
    else
      extract_claude_json_keys "$LOCAL_CLAUDE_JSON" "$dst_dir/claude-json/claude.json"
    fi
    count=$((count + 1))
  fi

  # ~/.claude-mem/settings.json
  if [ -f "$HOME/.claude-mem/settings.json" ]; then
    mkdir -p "$dst_dir/claude-mem"
    cp "$HOME/.claude-mem/settings.json" "$dst_dir/claude-mem/settings.json"
    count=$((count + 1))
  fi

  # ~/.config/ccstatusline/
  if [ -d "$HOME/.config/ccstatusline" ]; then
    mkdir -p "$dst_dir/config/ccstatusline"
    rsync -a --delete --exclude '.DS_Store' \
      "$HOME/.config/ccstatusline/" "$dst_dir/config/ccstatusline/" 2>/dev/null || \
      cp -R "$HOME/.config/ccstatusline/"* "$dst_dir/config/ccstatusline/" 2>/dev/null
    count=$((count + 1))
  fi

  # Extra items (export/SSH only)
  if [ "$with_extras" = true ]; then
    # Extra dotfile directories
    for dir in "${EXTRA_SYNC_DIRS[@]}"; do
      local src="$HOME/$dir"
      [ -d "$src" ] || continue
      [ "$dir" = ".claude-mem" ] && continue  # handled above
      mkdir -p "$dst_dir/extra-dotfiles"
      cp -R "$src" "$dst_dir/extra-dotfiles/$dir"
      count=$((count + 1))
    done

    # ~/.config/ items (excluding gws for export)
    for item in "${CONFIG_SYNC_ITEMS[@]}"; do
      [ "$item" = "gws" ] && continue
      local src="$HOME/.config/$item"
      [ -e "$src" ] || continue
      mkdir -p "$dst_dir/config"
      _copy_item "$src" "$dst_dir/config/$item"
      count=$((count + 1))
    done

    # MCP server source
    if [ -d "$HOME/mcp-servers" ]; then
      mkdir -p "$dst_dir/mcp-servers"
      rsync -a --exclude node_modules --exclude dist --exclude .DS_Store \
        "$HOME/mcp-servers/" "$dst_dir/mcp-servers/"
      count=$((count + 1))
    fi

    # Project CLAUDE.md files
    for project in "${PROJECT_CLAUDE_MDS[@]}"; do
      local src="$HOME/$project/CLAUDE.md"
      [ -f "$src" ] || continue
      mkdir -p "$dst_dir/project-claude-mds/$project"
      cp "$src" "$dst_dir/project-claude-mds/$project/CLAUDE.md"
      count=$((count + 1))
    done
  fi

  echo "$count"
}

# ── Apply Config to Local ─────────────────────────────────────────

apply_config_to_local() {
  # Apply staged config back to ~/.claude/ and related locations.
  # Handles: core files, plugin files, secrets restoration,
  # executable permissions, project dir renaming, smart merge, claude-mem.
  local src_dir="$1" claude_dir="$2"
  local secrets_file="${3:-}"
  local source_home="${4:-}"
  local count=0

  # Core files and dirs from staged claude/ -> ~/.claude/
  if [ -d "$src_dir/claude" ]; then
    for item in "$src_dir/claude/"*; do
      [ -e "$item" ] || continue
      local name
      name=$(basename "$item")
      local target="$claude_dir/$name"

      if [ -d "$item" ]; then
        mkdir -p "$target"
        rsync -a --delete "$item/" "$target/" 2>/dev/null || \
          cp -R "$item/"* "$target/" 2>/dev/null
      else
        cp "$item" "$target"
      fi
      count=$((count + 1))
    done
  fi

  # Restore secrets in mcp_settings.json
  if [ -n "$secrets_file" ] && [ -f "$claude_dir/mcp_settings.json" ]; then
    restore_secrets "$claude_dir/mcp_settings.json" "$secrets_file"
  fi

  # Make scripts executable
  chmod +x "$claude_dir/bin/"* 2>/dev/null || true
  chmod +x "$claude_dir/hooks/"* 2>/dev/null || true
  chmod +x "$claude_dir/ccstatusline.sh" 2>/dev/null || true

  # Rename projects/ directories (path encoding: /Users/foo -> -Users-foo)
  if [ -d "$claude_dir/projects" ] && [ -n "$source_home" ]; then
    local src_prefix dst_prefix
    src_prefix=$(echo "$source_home" | sed 's|/|-|g')
    dst_prefix=$(echo "$HOME" | sed 's|/|-|g')
    if [ "$src_prefix" != "$dst_prefix" ]; then
      for proj_dir in "$claude_dir/projects/"*; do
        [ -d "$proj_dir" ] || continue
        local dir_name new_name
        dir_name=$(basename "$proj_dir")
        new_name="${dir_name/$src_prefix/$dst_prefix}"
        if [ "$dir_name" != "$new_name" ]; then
          mv "$proj_dir" "$claude_dir/projects/$new_name"
        fi
      done
    fi
  fi

  # ~/.claude.json (smart merge)
  local claude_json_file=""
  if [ -f "$src_dir/claude-json/claude.json" ]; then
    claude_json_file="$src_dir/claude-json/claude.json"
  elif [ -f "$src_dir/claude-json/.claude.json" ]; then
    claude_json_file="$src_dir/claude-json/.claude.json"
  fi

  if [ -n "$claude_json_file" ]; then
    local tmp_src
    tmp_src=$(mktemp)
    cp "$claude_json_file" "$tmp_src"
    smart_merge_claude_json "$tmp_src" "$LOCAL_CLAUDE_JSON"
    rm -f "$tmp_src"
    count=$((count + 1))
  fi

  # ~/.claude-mem/settings.json
  if [ -f "$src_dir/claude-mem/settings.json" ]; then
    mkdir -p "$HOME/.claude-mem"
    cp "$src_dir/claude-mem/settings.json" "$HOME/.claude-mem/settings.json"
    count=$((count + 1))
  fi

  # ~/.config/ccstatusline/
  if [ -d "$src_dir/config/ccstatusline" ]; then
    mkdir -p "$HOME/.config/ccstatusline"
    rsync -a --delete "$src_dir/config/ccstatusline/" "$HOME/.config/ccstatusline/" 2>/dev/null || \
      cp -R "$src_dir/config/ccstatusline/"* "$HOME/.config/ccstatusline/" 2>/dev/null
    count=$((count + 1))
  fi

  echo "$count"
}

# ── Backup ────────────────────────────────────────────────────────

create_backup() {
  # Create timestamped backup of current allowlisted config.
  local backup_base_dir="$1"
  local timestamp
  timestamp=$(date +%Y-%m-%dT%H-%M-%S)
  local backup_dir="$backup_base_dir/$timestamp"
  mkdir -p "$backup_dir"

  copy_claude_config "$LOCAL_CLAUDE_DIR" "$backup_dir" >/dev/null 2>&1

  echo "$backup_dir"
}
