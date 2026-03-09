#!/usr/bin/env bash
#
# install.sh: Install claude-sync by symlinking to ~/.claude/bin/
#
# Usage:
#   ./install.sh
#
# This replaces the monolithic ~/.claude/bin/claude-sync with a symlink
# to the repo version.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$HOME/.claude/bin"
TARGET="$TARGET_DIR/claude-sync"

echo "Installing claude-sync..."

mkdir -p "$TARGET_DIR"

# Back up existing non-symlink version
if [ -f "$TARGET" ] && [ ! -L "$TARGET" ]; then
  backup="$TARGET.bak.$(date +%Y%m%d%H%M%S)"
  echo "  Backing up existing script to $backup"
  mv "$TARGET" "$backup"
elif [ -L "$TARGET" ]; then
  rm -f "$TARGET"
fi

chmod +x "$SCRIPT_DIR/claude-sync"
ln -s "$SCRIPT_DIR/claude-sync" "$TARGET"

echo "  Symlinked $TARGET -> $SCRIPT_DIR/claude-sync"
echo ""
echo "Done! claude-sync is now running from the repo."
echo "Verify with: claude-sync help"
