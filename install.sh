#!/usr/bin/env bash
#
# install.sh — install Shepherd (Herdr orchestrator for pi)
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/jhsu/shepherd-pi/main/install.sh | bash
#   # or:
#   bash install.sh
#
# What it does:
#   1. Clones shepherd into ~/.shepherd (or updates if already present)
#   2. Creates ~/.local/bin/shepherd-pi  — launches pi in the shepherd project

#   3. (Optional) installs the /agents pi extension globally
#
# Requires: git, pi, python3

set -euo pipefail

SHEPHERD_DIR="${SHEPHERD_DIR:-$HOME/.shepherd}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
REPO_URL="${REPO_URL:-https://github.com/jhsu/shepherd-pi.git}"
BRANCH="${BRANCH:-main}"

info()  { printf "\033[1;34m[shepherd]\033[0m %s\n" "$*"; }
ok()    { printf "\033[1;32m[shepherd]\033[0m %s\n" "$*"; }
warn()  { printf "\033[1;33m[shepherd]\033[0m %s\n" "$*"; }
die()   { printf "\033[1;31m[shepherd]\033[0m %s\n" "$*" >&2; exit 1; }

# --- prerequisites -----------------------------------------------------------

command -v git >/dev/null 2>&1 || die "git is required but not found on PATH."
command -v pi  >/dev/null 2>&1 || warn "pi not found on PATH — shepherd-pi will fail until pi is installed."

# --- ensure ~/.local/bin exists ----------------------------------------------

mkdir -p "$BIN_DIR"

# --- clone or update ---------------------------------------------------------

if [ -d "$SHEPHERD_DIR/.git" ]; then
  info "Updating existing shepherd at $SHEPHERD_DIR ..."
  git -C "$SHEPHERD_DIR" fetch --quiet origin "$BRANCH"
  git -C "$SHEPHERD_DIR" reset --hard --quiet "origin/$BRANCH"
  ok "Updated."
else
  if [ -d "$SHEPHERD_DIR" ]; then
    warn "$SHEPHERD_DIR exists but is not a git repo — backing up to ${SHEPHERD_DIR}.bak"
    mv "$SHEPHERD_DIR" "${SHEPHERD_DIR}.bak"
  fi
  info "Cloning shepherd into $SHEPHERD_DIR ..."
  git clone --branch "$BRANCH" --depth 1 --quiet "$REPO_URL" "$SHEPHERD_DIR"
  ok "Cloned."
fi

# --- shepherd-pi wrapper -----------------------------------------------------

cat > "$BIN_DIR/shepherd-pi" << 'WRAPPER'
#!/usr/bin/env bash
# shepherd-pi — start pi as a Herdr orchestrator using the Shepherd project
set -euo pipefail
SHEPHERD_DIR="${SHEPHERD_DIR:-$HOME/.shepherd}"
if [ ! -f "$SHEPHERD_DIR/AGENTS.md" ]; then
  echo "shepherd: AGENTS.md not found in $SHEPHERD_DIR — did you run the installer?" >&2
  exit 1
fi
cd "$SHEPHERD_DIR"
export PATH="$SHEPHERD_DIR/bin:$PATH"
exec pi "$@"
WRAPPER
chmod +x "$BIN_DIR/shepherd-pi"
ok "Installed shepherd-pi -> $BIN_DIR/shepherd-pi"

# --- optional: global pi extension -------------------------------------------

PI_GLOBAL_EXT="${HOME}/.pi/agent/extensions"
if [ -d "$PI_GLOBAL_EXT" ] || [ -d "${HOME}/.pi" ]; then
  mkdir -p "$PI_GLOBAL_EXT"
  ln -sf "$SHEPHERD_DIR/.pi/extensions/herdr-agents.ts" "$PI_GLOBAL_EXT/herdr-agents.ts"
  ok "Installed /agents pi extension globally -> $PI_GLOBAL_EXT/herdr-agents.ts"
else
  info "Skipped global pi extension (no ~/.pi directory). Run pi once first, then re-run this installer."
fi

# --- PATH check --------------------------------------------------------------

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) warn "$BIN_DIR is not on PATH. Add this to your shell profile:
       export PATH=\"\$PATH:$BIN_DIR\"" ;;
esac

# --- done --------------------------------------------------------------------

echo ""
ok "Shepherd is installed. Run 'shepherd-pi' to start the orchestrator."
