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
# Requires: git, pi, python3, node

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
# git is mandatory for the install itself. pi/python3/node are reported as
# warnings (the installer still succeeds without them, but `shepherd-pi doctor`
# will flag them later).

command -v git >/dev/null 2>&1 || die "git is required but not found on PATH."
command -v pi       >/dev/null 2>&1 || warn "pi not found on PATH — shepherd-pi will fail until pi is installed."
command -v python3  >/dev/null 2>&1 || warn "python3 not found on PATH — herdr-summary will not work."
command -v node     >/dev/null 2>&1 || warn "node not found on PATH — pi extensions (.ts) cannot be transpiled."

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

# Before writing anything into BIN_DIR, validate that the doctor source is
# present in the freshly cloned/updated shepherd. A missing source must fail
# the install *cleanly* — we never want to leave an orphan `shepherd-pi`
# wrapper that has no sibling `shepherd-doctor` to dispatch to.
DOCTOR_SRC="$SHEPHERD_DIR/bin/shepherd-doctor"
if [ ! -f "$DOCTOR_SRC" ]; then
  die "shepherd-doctor source not found at $DOCTOR_SRC — clone is incomplete or out of date."
fi

cat > "$BIN_DIR/shepherd-pi" << 'WRAPPER'
#!/usr/bin/env bash
# shepherd-pi — start pi as a Herdr orchestrator using the Shepherd project
#
# Special subcommand:
#   shepherd-pi doctor [--no-color]   # run environment diagnostics, then exit
#
# Anything else is forwarded to pi unchanged.
set -euo pipefail

# Resolve the directory this wrapper lives in, following symlinks, so we can
# locate the sibling `shepherd-doctor` regardless of how PATH/HOME were set
# when the wrapper actually runs. The installer copies both into the same
# BIN_DIR; we must not depend on SHEPHERD_DIR or PATH alone at runtime.
_self="${BASH_SOURCE[0]:-$0}"
while [ -L "$_self" ]; do
  _dir="$(cd "$(dirname "$_self")" >/dev/null 2>&1 && pwd)"
  _self="$(readlink "$_self")" || break
  case "$_self" in
    /*) ;;
    *) _self="$_dir/$_self" ;;
  esac
done
WRAPPER_DIR="$(cd "$(dirname "$_self")" >/dev/null 2>&1 && pwd)"

# Intercept the doctor subcommand BEFORE the AGENTS.md preflight so that
# `shepherd-pi doctor` can itself diagnose a missing AGENTS.md rather than
# being blocked by the wrapper's early-exit check.
if [ "$#" -gt 0 ] && [ "$1" = "doctor" ]; then
  shift
  SHEPHERD_DIR="${SHEPHERD_DIR:-$HOME/.shepherd}"
  # Tell the doctor where the shepherd project lives, since the sibling
  # `shepherd-doctor` is now installed in BIN_DIR (not $SHEPHERD_DIR/bin), so
  # its own dirname-based SHEPHERD_DIR derivation would point at the wrong dir.
  export SHEPHERD_DIR_OVERRIDE="$SHEPHERD_DIR"
  DOCTOR_BIN=""
  # Prefer the sibling installed alongside this wrapper (robust to PATH/HOME
  # rewrites after install); fall back to the clone's bin and finally PATH.
  if [ -x "$WRAPPER_DIR/shepherd-doctor" ]; then
    DOCTOR_BIN="$WRAPPER_DIR/shepherd-doctor"
  elif [ -x "$SHEPHERD_DIR/bin/shepherd-doctor" ]; then
    DOCTOR_BIN="$SHEPHERD_DIR/bin/shepherd-doctor"
  elif command -v shepherd-doctor >/dev/null 2>&1; then
    DOCTOR_BIN="$(command -v shepherd-doctor)"
  else
    echo "shepherd: shepherd-doctor not found (looked in $WRAPPER_DIR, $SHEPHERD_DIR/bin, and PATH)" >&2
    exit 1
  fi
  exec "$DOCTOR_BIN" "$@"
fi

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

# --- shepherd-doctor sibling -------------------------------------------------
# Copy the doctor script into the same BIN_DIR as the shepherd-pi wrapper so
# `shepherd-pi doctor` can dispatch to a sibling that does not depend on the
# clone being present at runtime (and so a clean install from a public clone
# still has the doctor available even before the wrapper starts).
# The source was validated above (before writing the wrapper); this cp cannot
# fail on a missing source because we already die'd earlier.
cp "$DOCTOR_SRC" "$BIN_DIR/shepherd-doctor"
chmod +x "$BIN_DIR/shepherd-doctor"
ok "Installed shepherd-doctor -> $BIN_DIR/shepherd-doctor"
ok "  doctor subcommand -> $BIN_DIR/shepherd-doctor (sibling of shepherd-pi)"

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
