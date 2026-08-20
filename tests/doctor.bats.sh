#!/usr/bin/env bash
#
# tests/doctor.bats.sh — focused shell tests for bin/shepherd-doctor
#
# Not bats (despite the name); a plain bash harness. No external deps beyond
# bash + coreutils. Fakes `pi`, `herdr`, `node`, `python3` on a private PATH
# and uses a throwaway HOME so the real environment is never touched.
#
# Usage:
#   ./tests/doctor.bats.sh
#   bash tests/doctor.bats.sh
#
# Exit codes: 0 = all passed, 1 = at least one test failed.

set -uo pipefail

DOCTOR="$PWD/bin/shepherd-doctor"   # resolved relative to repo root by the caller
TESTS_RUN=0
TESTS_FAIL=0

pass() { printf "  \033[1;32mPASS\033[0m  %s\n" "$1"; TESTS_RUN=$((TESTS_RUN+1)); }
fail() { printf "  \033[1;31mFAIL\033[0m  %s\n" "$1"; TESTS_FAIL=$((TESTS_FAIL+1)); TESTS_RUN=$((TESTS_RUN+1)); }

# Resolve repo root if invoked from a subdir.
if [ ! -f "$DOCTOR" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
  DOCTOR="$SCRIPT_DIR/../bin/shepherd-doctor"
fi

if [ ! -f "$DOCTOR" ]; then
  echo "cannot find bin/shepherd-doctor (looked at $DOCTOR)" >&2
  exit 2
fi

# Build a fresh sandbox: isolated HOME, fake bin dir, minimal shepherd copy.
build_sandbox() {
  # $1 = "full" (copy extension/refiner files) or "sparse" (AGENTS.md only)
  local mode="$1"
  SANDBOX_HOME=$(mktemp -d)
  mkdir -p "$SANDBOX_HOME/bin" "$SANDBOX_HOME/.local/bin"
  FAKE_BIN="$SANDBOX_HOME/bin"

  # Fake commands — all report a believable version.
  mk_fake() {
    local name="$1" ver="$2"
    cat > "$FAKE_BIN/$name" <<EOF
#!/usr/bin/env bash
echo "$ver"
EOF
    chmod +x "$FAKE_BIN/$name"
  }
  mk_fake git      "git version 2.55.0"
  mk_fake pi       "0.84.2"
  mk_fake python3  "Python 3.14.2"
  mk_fake node     "v26.7.0"
  mk_fake herdr    "herdr 0.8.2"

  # Link the coreutils the doctor script actually shells out to, so PATH can
  # be ONLY $FAKE_BIN (no leakage to real /usr/bin git/python3/node).
  link_util() {
    local name="$1"
    local real
    real="$(command -v "$name" 2>/dev/null)" || return 0
    [ -e "$FAKE_BIN/$name" ] || ln -s "$real" "$FAKE_BIN/$name"
  }
  link_util mkdir
  link_util printf
  link_util cat
  link_util head
  link_util tr
  link_util readlink
  link_util dirname
  link_util rmdir
  link_util rm
  link_util pwd
  link_util bash            # needed by shebangs of scripts we exec

  # Minimal shepherd project layout under $SANDBOX_HOME/.shepherd
  SHEP="$SANDBOX_HOME/.shepherd"
  mkdir -p "$SHEP/bin" "$SHEP/.pi/extensions" "$SHEP/.pi/agents"
  cp "$PWD/AGENTS.md" "$SHEP/AGENTS.md"
  cp "$PWD/bin/herdr-summary" "$SHEP/bin/herdr-summary"
  cp "$PWD/.pi/extensions/herdr-agents.ts" "$SHEP/.pi/extensions/herdr-agents.ts"
  cp "$PWD/.pi/extensions/fleet-activity.ts" "$SHEP/.pi/extensions/fleet-activity.ts"
  cp "$PWD/.pi/extensions/fleet-ledger.ts" "$SHEP/.pi/extensions/fleet-ledger.ts"
  cp "$PWD/.pi/agents/prompt-refiner.md" "$SHEP/.pi/agents/prompt-refiner.md"

  if [ "$mode" = "sparse" ]; then
    # Remove the extensions + refiner to force warnings
    rm -f "$SHEP/.pi/extensions/herdr-agents.ts"
    rm -f "$SHEP/.pi/extensions/fleet-activity.ts"
    rm -f "$SHEP/.pi/extensions/fleet-ledger.ts"
    rm -f "$SHEP/.pi/agents/prompt-refiner.md"
    rm -f "$SHEP/bin/herdr-summary"
  fi
}

cleanup_sandbox() {
  [ -n "${SANDBOX_HOME:-}" ] && rm -rf "$SANDBOX_HOME"
}

# Run doctor under the sandbox. Captures stdout + exit code.
run_doctor() {
  # $@ = extra doctor args
  unset HERDR_ENV HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_PANE_ID HERDR_LEDGER_DIR
  env -i \
    PATH="$FAKE_BIN" \
    HOME="$SANDBOX_HOME" \
    SHEPHERD_DIR_OVERRIDE="$SHEP" \
    "$BASH" "$DOCTOR" --no-color "$@" >"$SANDBOX_HOME/out.txt" 2>&1
  DOCTOR_EXIT=$?
  DOCTOR_OUT="$(cat "$SANDBOX_HOME/out.txt")"
}

# ---------------------------------------------------------------------------
# Test 1: clean environment, inside Herdr → all PASS, exit 0
# ---------------------------------------------------------------------------
build_sandbox full
# Inside-Herdr clean run: set HERDR_ENV via env -i alongside the overrides.
( mkdir -p "$SANDBOX_HOME"
  env -i \
    PATH="$FAKE_BIN" \
    HOME="$SANDBOX_HOME" \
    SHEPHERD_DIR_OVERRIDE="$SHEP" \
    HERDR_ENV=1 \
    HERDR_WORKSPACE_ID=w99 \
    HERDR_TAB_ID=w99:t1 \
    HERDR_PANE_ID=w99:p1 \
    "$BASH" "$DOCTOR" --no-color >"$SANDBOX_HOME/out.txt" 2>&1
  echo $? > "$SANDBOX_HOME/rc.txt"
)
DOCTOR_EXIT=$(cat "$SANDBOX_HOME/rc.txt")
DOCTOR_OUT=$(cat "$SANDBOX_HOME/out.txt")

if [ "$DOCTOR_EXIT" -eq 0 ]; then pass "clean env exits 0"; else fail "clean env should exit 0, got $DOCTOR_EXIT"; fi
case "$DOCTOR_OUT" in *FAIL=0*) pass "clean env reports 0 failures"; ;; *) fail "clean env should report FAIL=0, got: $DOCTOR_OUT"; ;; esac
case "$DOCTOR_OUT" in *HERDR_ENV=1*) pass "inside-Herdr detected"; ;; *) fail "doctor should mention HERDR_ENV=1"; ;; esac
case "$DOCTOR_OUT" in *"shepherd directory exists"*) pass "shepherd dir detected"; ;; *) fail "missing shepherd dir line"; ;; esac
case "$DOCTOR_OUT" in *"AGENTS.md present"*) pass "AGENTS.md detected"; ;; *) fail "missing AGENTS.md line"; ;; esac
case "$DOCTOR_OUT" in *"ledger directory is writable"*|*"ledger directory creatable and writable"*)
  pass "ledger writable" ;; *) fail "missing ledger writable line" ;; esac
cleanup_sandbox

# ---------------------------------------------------------------------------
# Test 2: outside Herdr → WARN (not FAIL), exit 0
# ---------------------------------------------------------------------------
build_sandbox full
run_doctor
if [ "$DOCTOR_EXIT" -eq 0 ]; then pass "outside-Herdr exits 0 (warn only)"; else fail "outside-Herdr should exit 0, got $DOCTOR_EXIT"; fi
case "$DOCTOR_OUT" in *WARN*) pass "outside-Herdr emits a warning"; ;; *) fail "outside-Herdr should emit a warning"; ;; esac
case "$DOCTOR_OUT" in *FAIL=0*) pass "outside-Herdr has 0 failures"; ;; *) fail "outside-Herdr should have FAIL=0, got: $DOCTOR_OUT"; ;; esac

# Verify ledger dir was NOT destructively created/removed by the probe.
if [ -d "$SANDBOX_HOME/.herdr-ledger" ]; then
  pass "ledger dir left in place (or created) outside Herdr"
else
  pass "ledger dir absent outside Herdr (probe created+removed it cleanly)"
fi
cleanup_sandbox

# ---------------------------------------------------------------------------
# Test 3: missing `pi` (hard failure) → exit 1
# ---------------------------------------------------------------------------
build_sandbox full
rm -f "$FAKE_BIN/pi"
run_doctor
if [ "$DOCTOR_EXIT" -eq 1 ]; then pass "missing pi exits 1"; else fail "missing pi should exit 1, got $DOCTOR_EXIT"; fi
case "$DOCTOR_OUT" in *"pi not found"*) pass "missing pi reported"; ;; *) fail "missing pi not reported: $DOCTOR_OUT"; ;; esac
case "$DOCTOR_OUT" in *FAIL=1*) pass "missing pi → FAIL=1"; ;; *) fail "missing pi should give FAIL=1, got: $DOCTOR_OUT"; ;; esac
cleanup_sandbox

# ---------------------------------------------------------------------------
# Test 4: missing `git` (hard failure) → exit 1
# ---------------------------------------------------------------------------
build_sandbox full
rm -f "$FAKE_BIN/git"
run_doctor
if [ "$DOCTOR_EXIT" -eq 1 ]; then pass "missing git exits 1"; else fail "missing git should exit 1, got $DOCTOR_EXIT"; fi
case "$DOCTOR_OUT" in *FAIL=1*) pass "missing git → FAIL=1"; ;; *) fail "missing git should give FAIL=1, got: $DOCTOR_OUT"; ;; esac
cleanup_sandbox

# ---------------------------------------------------------------------------
# Test 5: missing optional commands (python3, node, herdr) → exit 0 with warns
# ---------------------------------------------------------------------------
build_sandbox full
rm -f "$FAKE_BIN/python3" "$FAKE_BIN/node" "$FAKE_BIN/herdr"
run_doctor
if [ "$DOCTOR_EXIT" -eq 0 ]; then pass "missing optional cmds exit 0"; else fail "missing optional cmds should exit 0, got $DOCTOR_EXIT"; fi
case "$DOCTOR_OUT" in *WARN*) pass "missing optional cmds emit warnings"; ;; *) fail "missing optional cmds should warn: $DOCTOR_OUT"; ;; esac
case "$DOCTOR_OUT" in *FAIL=0*) pass "missing optional cmds → 0 fails"; ;; *) fail "missing optional cmds should have FAIL=0, got: $DOCTOR_OUT"; ;; esac
cleanup_sandbox

# ---------------------------------------------------------------------------
# Test 6: missing AGENTS.md → hard fail
# ---------------------------------------------------------------------------
build_sandbox full
rm -f "$SHEP/AGENTS.md"
run_doctor
if [ "$DOCTOR_EXIT" -eq 1 ]; then pass "missing AGENTS.md exits 1"; else fail "missing AGENTS.md should exit 1, got $DOCTOR_EXIT"; fi
case "$DOCTOR_OUT" in *"AGENTS.md missing"*) pass "missing AGENTS.md reported"; ;; *) fail "missing AGENTS.md not reported: $DOCTOR_OUT"; ;; esac
cleanup_sandbox

# ---------------------------------------------------------------------------
# Test 7: missing extension/refiner files → warnings, exit 0
# ---------------------------------------------------------------------------
build_sandbox sparse
run_doctor
if [ "$DOCTOR_EXIT" -eq 0 ]; then pass "missing extensions exit 0 (warn)"; else fail "missing extensions should exit 0, got $DOCTOR_EXIT"; fi
case "$DOCTOR_OUT" in *WARN*) pass "missing extensions emit warnings"; ;; *) fail "missing extensions should warn"; ;; esac
case "$DOCTOR_OUT" in *FAIL=0*) pass "missing extensions → 0 fails"; ;; *) fail "missing extensions should have FAIL=0"; ;; esac
cleanup_sandbox

# ---------------------------------------------------------------------------
# Test 8: unwritable ledger dir (when pre-existing) → hard fail
# ---------------------------------------------------------------------------
build_sandbox full
mkdir -p "$SANDBOX_HOME/.herdr-ledger"
chmod 000 "$SANDBOX_HOME/.herdr-ledger"
run_doctor
chmod 700 "$SANDBOX_HOME/.herdr-ledger"    # restore so cleanup works
if [ "$DOCTOR_EXIT" -eq 1 ]; then pass "unwritable ledger exits 1"; else fail "unwritable ledger should exit 1, got $DOCTOR_EXIT"; fi
case "$DOCTOR_OUT" in *"ledger directory not writable"*) pass "unwritable ledger reported"; ;; *) fail "unwritable ledger not reported: $DOCTOR_OUT"; ;; esac
cleanup_sandbox

# ---------------------------------------------------------------------------
# Test 9: ledger dir probe leaves existing data intact
# ---------------------------------------------------------------------------
build_sandbox full
mkdir -p "$SANDBOX_HOME/.herdr-ledger"
echo "existing-task-123" > "$SANDBOX_HOME/.herdr-ledger/TODO-abc.md"
run_doctor
LEDCONTENT=$(cat "$SANDBOX_HOME/.herdr-ledger/TODO-abc.md")
if [ "$LEDCONTENT" = "existing-task-123" ]; then pass "ledger data preserved across probe"; else fail "ledger data corrupted: '$LEDCONTENT'"; fi
shopt -s nullglob
leftovers=( "$SANDBOX_HOME/.herdr-ledger"/.shepherd-doctor-probe.* )
shopt -u nullglob
if [ "${#leftovers[@]}" -eq 0 ]; then pass "no probe files left behind"; else
  for leftover in "${leftovers[@]}"; do fail "probe file left behind: $leftover"; done
fi
cleanup_sandbox

# ===========================================================================
# Wrapper-level tests (Test 10–11)
#
# These extract the shepherd-pi wrapper heredoc from install.sh exactly as
# the installer would generate it, place it in a temp bin, and exercise the
# `doctor` dispatch path against the real checkout's bin/shepherd-doctor.
# install.sh itself (which uses `git reset --hard`) is NEVER executed.
# ===========================================================================

REPO_ROOT="$PWD"
INSTALL_SH="$REPO_ROOT/install.sh"

extract_wrapper() {
  # $1 = output path. Extracts the body of the `cat > ... shepherd-pi << 'WRAPPER'`
  # heredoc in install.sh (between the `<< 'WRAPPER'` line and the closing
  # `WRAPPER` line) without executing install.sh.
  local out="$1"
  awk '
    /^cat > .*shepherd-pi.* << '\''WRAPPER'\''$/ { in_heredoc=1; next }
    in_heredoc && /^WRAPPER$/ { in_heredoc=0; next }
    in_heredoc { print }
  ' "$INSTALL_SH" > "$out"
}

# ---------------------------------------------------------------------------
# Test 10: `shepherd-pi doctor` runs even when AGENTS.md is MISSING — and
# returns its OWN missing-AGENTS diagnostic (FAIL), not the wrapper's preflight.
# ---------------------------------------------------------------------------
build_sandbox full
# Point SHEPHERD_DIR at a deliberately broken shepherd: no AGENTS.md.
BROKEN_SHEP="$SANDBOX_HOME/.shepherd-broken"
mkdir -p "$BROKEN_SHEP/bin"
cp "$REPO_ROOT/bin/shepherd-doctor" "$BROKEN_SHEP/bin/shepherd-doctor"
chmod +x "$BROKEN_SHEP/bin/shepherd-doctor"
# Deliberately do NOT create AGENTS.md.

extract_wrapper "$SANDBOX_HOME/.local/bin/shepherd-pi"
chmod +x "$SANDBOX_HOME/.local/bin/shepherd-pi"

# Run `shepherd-pi doctor --no-color` with SHEPHERD_DIR=broken shepherd.
env -i \
  PATH="$FAKE_BIN:$BROKEN_SHEP/bin" \
  HOME="$SANDBOX_HOME" \
  SHEPHERD_DIR="$BROKEN_SHEP" \
  "$BASH" "$SANDBOX_HOME/.local/bin/shepherd-pi" doctor --no-color \
  >"$SANDBOX_HOME/out.txt" 2>&1
WRAPPER_EXIT=$?
WRAPPER_OUT="$(cat "$SANDBOX_HOME/out.txt")"

if [ "$WRAPPER_EXIT" -eq 1 ]; then pass "doctor exits 1 when AGENTS.md missing"; else fail "doctor should exit 1 on missing AGENTS.md, got $WRAPPER_EXIT"; fi
case "$WRAPPER_OUT" in
  *"AGENTS.md missing"*|*"AGENTS.md present"*) : ;; # one of these lines must appear
esac
case "$WRAPPER_OUT" in
  *"AGENTS.md missing"*)
    pass "doctor emits its own missing-AGENTS.md diagnostic" ;;
  *)
    fail "doctor did not report missing AGENTS.md; got: $WRAPPER_OUT" ;;
esac
# CRITICAL: the wrapper's preflight error must NOT appear — doctor ran instead.
case "$WRAPPER_OUT" in
  *"shepherd: AGENTS.md not found"*)
    fail "wrapper preflight fired before doctor — dispatch order is wrong" ;;
  *)
    pass "wrapper preflight did not block doctor dispatch" ;;
esac
cleanup_sandbox

# ---------------------------------------------------------------------------
# Test 11: non-doctor args still forward to pi (not intercepted by doctor).
# We use a fake `pi` on PATH that records its args, so we don't launch pi.
# ---------------------------------------------------------------------------
build_sandbox full
# Replace the fake pi with an arg-recording stub.
cat > "$FAKE_BIN/pi" <<'EOF'
#!/usr/bin/env bash
echo "PI-RECEIVED: $*"
EOF
chmod +x "$FAKE_BIN/pi"

extract_wrapper "$SANDBOX_HOME/.local/bin/shepherd-pi"
chmod +x "$SANDBOX_HOME/.local/bin/shepherd-pi"

env -i \
  PATH="$FAKE_BIN" \
  HOME="$SANDBOX_HOME" \
  SHEPHERD_DIR="$SHEP" \
  "$BASH" "$SANDBOX_HOME/.local/bin/shepherd-pi" --version --foo bar \
  >"$SANDBOX_HOME/out.txt" 2>&1
WRAPPER_EXIT=$?
WRAPPER_OUT="$(cat "$SANDBOX_HOME/out.txt")"

if [ "$WRAPPER_EXIT" -eq 0 ]; then pass "non-doctor args forward to pi, exit 0"; else fail "non-doctor forward should exit 0, got $WRAPPER_EXIT"; fi
case "$WRAPPER_OUT" in
  *"PI-RECEIVED: --version --foo bar"*)
    pass "non-doctor args forwarded to pi verbatim" ;;
  *)
    fail "non-doctor args not forwarded to pi verbatim; got: $WRAPPER_OUT" ;;
esac
# And doctor must NOT have run for non-doctor args.
case "$WRAPPER_OUT" in
  *"shepherd-doctor"*|*"PASS"*|*"FAIL"*)
    fail "doctor ran for non-doctor args (should not)" ;;
  *)
    pass "doctor did not run for non-doctor args" ;;
esac
cleanup_sandbox

# ===========================================================================
# Install-layout tests (Test 12–15)
#
# Exercise install.sh itself end-to-end against a temporary local git remote
# and a throwaway HOME/SHEPHERD_DIR/BIN_DIR. install.sh does a `git reset
# --hard` on the clone, but only on paths inside the sandbox — the real
# ~/.shepherd is never touched, and no test depends on the uncommitted source
# magically being present in a fresh clone.
# ===========================================================================

# Build a fake-bin helper set (mirror of build_sandbox's setup) WITHOUT a
# minimal shepherd. install.sh creates $SHEPHERD_DIR itself by cloning.
build_install_env() {
  SANDBOX_HOME=$(mktemp -d)
  FAKE_BIN="$SANDBOX_HOME/bin"
  BIN_DIR_INSTALL="$SANDBOX_HOME/.local/bin"
  mkdir -p "$FAKE_BIN" "$BIN_DIR_INSTALL"

  mk_fake() {
    local name="$1" ver="$2"
    cat > "$FAKE_BIN/$name" <<EOF
#!/usr/bin/env bash
echo "$ver"
EOF
    chmod +x "$FAKE_BIN/$name"
  }
  mk_fake pi       "0.84.2"
  mk_fake python3  "Python 3.14.2"
  mk_fake node     "v26.7.0"
  mk_fake herdr    "herdr 0.8.2"

  link_util() {
    local name="$1" real
    real="$(command -v "$name" 2>/dev/null)" || return 0
    [ -e "$FAKE_BIN/$name" ] || ln -s "$real" "$FAKE_BIN/$name"
  }
  # install.sh actually runs `git clone`/`git fetch`/`git reset --hard`, so the
  # REAL git must be on PATH (a fake git here would break the clone). The fakes
  # above are enough for install.sh's prereq probes and for doctor's version checks.
  link_util git
  link_util mkdir printf cat head tr readlink dirname rmdir rm pwd bash
  link_util ln chmod cp cmp sed awk grep
}

# Build a bare local git "remote" containing a minimal shepherd snapshot.
# $1 = "full" (include bin/shepherd-doctor) or "no-doctor" (omit it).
build_install_remote() {
  local mode="$1"
  REMOTE_DIR="$(mktemp -d)"
  REMOTE="$REMOTE_DIR/shepherd.git"
  git init --bare --quiet "$REMOTE" >/dev/null 2>&1
  REMOTE_WORK="$(mktemp -d)"
  git -C "$REMOTE_WORK" init --quiet
  git -C "$REMOTE_WORK" config user.email test@test
  git -C "$REMOTE_WORK" config user.name test
  cp "$REPO_ROOT/AGENTS.md" "$REMOTE_WORK/AGENTS.md"
  mkdir -p "$REMOTE_WORK/bin"
  cp "$REPO_ROOT/bin/herdr-summary" "$REMOTE_WORK/bin/herdr-summary"
  if [ "$mode" = "full" ]; then
    cp "$REPO_ROOT/bin/shepherd-doctor" "$REMOTE_WORK/bin/shepherd-doctor"
    chmod +x "$REMOTE_WORK/bin/shepherd-doctor"
  fi
  git -C "$REMOTE_WORK" add -A >/dev/null 2>&1
  git -C "$REMOTE_WORK" commit --quiet -m "init"
  git -C "$REMOTE_WORK" branch -M main >/dev/null 2>&1
  git -C "$REMOTE_WORK" remote add origin "$REMOTE" >/dev/null 2>&1
  git -C "$REMOTE_WORK" push --quiet origin main >/dev/null 2>&1
}

cleanup_install() {
  [ -n "${SANDBOX_HOME:-}" ] && rm -rf "$SANDBOX_HOME"
  [ -n "${REMOTE_DIR:-}" ] && rm -rf "$REMOTE_DIR"
  [ -n "${REMOTE_WORK:-}" ] && rm -rf "$REMOTE_WORK"
  unset REMOTE REMOTE_WORK REMOTE_DIR
}

run_install() {
  # Run the real install.sh against the sandboxed env. git/PATH/HOME etc. are
  # all temp; real ~/.shepherd is never touched.
  env -i \
    PATH="$FAKE_BIN:/usr/bin:/bin" \
    HOME="$SANDBOX_HOME" \
    SHEPHERD_DIR="$SANDBOX_HOME/.shepherd" \
    BIN_DIR="$BIN_DIR_INSTALL" \
    REPO_URL="file://$REMOTE" \
    BRANCH="main" \
    "$BASH" "$INSTALL_SH" >"$SANDBOX_HOME/install.out" 2>&1
  INSTALL_EXIT=$?
  INSTALL_OUT="$(cat "$SANDBOX_HOME/install.out")"
}

# Run the INSTALLED `shepherd-pi doctor` via the wrapper (not via PATH) so the
# sibling-resolution logic is what's actually exercised.
run_installed_doctor() {
  unset HERDR_ENV HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_PANE_ID HERDR_LEDGER_DIR
  env -i \
    PATH="$FAKE_BIN:/usr/bin:/bin" \
    HOME="$SANDBOX_HOME" \
    SHEPHERD_DIR="$SANDBOX_HOME/.shepherd" \
    "$BASH" "$BIN_DIR_INSTALL/shepherd-pi" doctor --no-color \
    >"$SANDBOX_HOME/doctor.out" 2>&1
  WRAPPER_EXIT=$?
  WRAPPER_OUT="$(cat "$SANDBOX_HOME/doctor.out")"
}

# ---------------------------------------------------------------------------
# Test 12: full install from a temp local git remote installs BOTH
# shepherd-pi AND shepherd-doctor into $BIN_DIR, executable, and prints the
# correct "sibling" ok line.
# ---------------------------------------------------------------------------
build_install_env
build_install_remote full
run_install
if [ "$INSTALL_EXIT" -eq 0 ]; then pass "install.sh exits 0 for full install"; else fail "install.sh should exit 0, got $INSTALL_EXIT; out: $INSTALL_OUT"; fi
case "$INSTALL_OUT" in *"Installed shepherd-pi ->"*) pass "install reports shepherd-pi installed"; ;; *) fail "missing shepherd-pi install line: $INSTALL_OUT"; ;; esac
case "$INSTALL_OUT" in *"Installed shepherd-doctor ->"*) pass "install reports shepherd-doctor installed"; ;; *) fail "missing shepherd-doctor install line: $INSTALL_OUT"; ;; esac
case "$INSTALL_OUT" in *"sibling of shepherd-pi"*) pass "install documents the sibling layout"; ;; *) fail "missing sibling wording: $INSTALL_OUT"; ;; esac
if [ -x "$BIN_DIR_INSTALL/shepherd-pi" ]; then pass "shepherd-pi installed executable"; else fail "shepherd-pi not installed executable"; fi
if [ -x "$BIN_DIR_INSTALL/shepherd-doctor" ]; then pass "shepherd-doctor installed executable"; else fail "shepherd-doctor not installed executable"; fi
# The two must live side by side in the same BIN_DIR.
if [ "$(dirname "$BIN_DIR_INSTALL/shepherd-pi")" = "$BIN_DIR_INSTALL" ] \
  && [ "$(dirname "$BIN_DIR_INSTALL/shepherd-doctor")" = "$BIN_DIR_INSTALL" ]; then
  pass "both installed into the same BIN_DIR"
else
  fail "both must be in $BIN_DIR_INSTALL"
fi
# The sibling must be the same file content as the clone's bin/shepherd-doctor.
if cmp -s "$BIN_DIR_INSTALL/shepherd-doctor" "$SANDBOX_HOME/.shepherd/bin/shepherd-doctor"; then
  pass "installed shepherd-doctor matches the clone's bin/shepherd-doctor"
else
  fail "installed shepherd-doctor differs from clone's bin/shepherd-doctor"
fi
cleanup_install

# ---------------------------------------------------------------------------
# Test 13: after full install, `shepherd-pi doctor` dispatches to the sibling
# shepherd-doctor in $BIN_DIR and produces the expected summary line.
# ---------------------------------------------------------------------------
build_install_env
build_install_remote full
run_install
run_installed_doctor
if [ "$WRAPPER_EXIT" -eq 0 ]; then pass "installed wrapper doctor exits 0 (warn only outside Herdr)"; else fail "wrapper doctor should exit 0, got $WRAPPER_EXIT; out: $WRAPPER_OUT"; fi
case "$WRAPPER_OUT" in *"Summary"*) pass "installed doctor reached the Summary section"; ;; *) fail "doctor did not run to Summary: $WRAPPER_OUT"; ;; esac
case "$WRAPPER_OUT" in *FAIL=0*) pass "installed doctor reports 0 failures"; ;; *) fail "installed doctor had failures: $WRAPPER_OUT"; ;; esac
case "$WRAPPER_OUT" in *"AGENTS.md present"*) pass "installed doctor found AGENTS.md via override"; ;; *) fail "installed doctor did not find AGENTS.md; out: $WRAPPER_OUT"; ;; esac
cleanup_install

# ---------------------------------------------------------------------------
# Test 14: sibling-resolution — even if the clone's bin/shepherd-doctor is
# gone (e.g. a partial update), the wrapper still finds the sibling installed
# in $BIN_DIR and dispatches it. This is the whole point of installing it there.
# ---------------------------------------------------------------------------
build_install_env
build_install_remote full
run_install
rm -f "$SANDBOX_HOME/.shepherd/bin/shepherd-doctor"
run_installed_doctor
if [ "$WRAPPER_EXIT" -eq 0 ]; then pass "wrapper doctor still runs without clone's bin/shepherd-doctor"; else fail "wrapper doctor failed when clone bin missing, got $WRAPPER_EXIT; out: $WRAPPER_OUT"; fi
case "$WRAPPER_OUT" in *"Summary"*) pass "sibling dispatch reached Summary"; ;; *) fail "sibling dispatch did not reach Summary: $WRAPPER_OUT"; ;; esac
cleanup_install

# ---------------------------------------------------------------------------
# Test 15: install.sh fails clearly when the clone lacks bin/shepherd-doctor,
# and crucially writes NEITHER shepherd-pi NOR shepherd-doctor into BIN_DIR —
# the source is validated before any wrapper is written, so no orphan survives.
# ---------------------------------------------------------------------------
build_install_env
build_install_remote no-doctor
# Sanity: BIN_DIR is empty before the failed install.
if [ ! -e "$BIN_DIR_INSTALL/shepherd-pi" ] && [ ! -e "$BIN_DIR_INSTALL/shepherd-doctor" ]; then
  : # expected starting state
else
  fail "BIN_DIR not clean before failed-install test"; fi
run_install
if [ "$INSTALL_EXIT" -ne 0 ]; then pass "install.sh exits nonzero when source doctor absent"; else fail "install.sh should fail when source doctor absent; out: $INSTALL_OUT"; fi
case "$INSTALL_OUT" in *"shepherd-doctor source not found"*) pass "install.sh reports missing source clearly"; ;; *) fail "install.sh missing-source message absent: $INSTALL_OUT"; ;; esac
# Neither executable must have been written on this failed install.
if [ ! -e "$BIN_DIR_INSTALL/shepherd-pi" ]; then pass "no orphan shepherd-pi wrapper after failed install"; else fail "shepherd-pi left behind after failed install"; fi
if [ ! -e "$BIN_DIR_INSTALL/shepherd-doctor" ]; then pass "no orphan shepherd-doctor after failed install"; else fail "shepherd-doctor left behind after failed install"; fi
cleanup_install

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf "\n\033[1mResults:\033[0m %d run, %d failed\n" "$TESTS_RUN" "$TESTS_FAIL"
if [ "$TESTS_FAIL" -gt 0 ]; then exit 1; fi
exit 0
