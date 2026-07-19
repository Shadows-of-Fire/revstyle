#!/usr/bin/env bash
# ci/e2e.sh — end-to-end guard: does revstyle still repair a fresh DevStyle
# install on a stock Eclipse?
#
# Builds a throwaway Eclipse in a scratch dir, installs pristine DevStyle from
# the vendor's PUBLIC p2 site, proves the harness can detect the known 4.40
# tab-renderer bug (negative control), runs the revstyle pipeline + deploy,
# and boots headless under xvfb to verify the patched install logs clean.
#
# Legal/invariant note (do not weaken): DevStyle is fetched from Genuitec's
# own public update site onto an ephemeral machine and discarded with it.
# No Genuitec bytes enter git, CI caches, or uploaded artifacts — the logs
# directory is the only output. See CLAUDE.md "Hard invariants".
#
# Local use (run from a scratch worktree — the pipeline writes work/ build/
# backups/ tools/ into the repo dir):
#   ECLIPSE_RELEASE=2026-06 EXPECT_TAB_NPE=1 ci/e2e.sh
#
# Env knobs:
#   ECLIPSE_RELEASE      required, e.g. 2026-06
#   EXPECT_TAB_NPE       1 = run the pristine-DevStyle negative control (4.40)
#   REVSTYLE_CI_SCRATCH  scratch root (default: $RUNNER_TEMP or mktemp -d)
#   EPP_CACHE_DIR        where the Eclipse tarball is kept (CI caches this dir)
#   DEVSTYLE_REPO        p2 repo URL (override to fault-inject a dead site)
#   SETTLE_SECONDS       soak time after the workspace log appears (100)
#   BOOT_TIMEOUT         max seconds to wait for the workspace log (180)
#
# Every failure exits via die "[stage-tag] ..." — the tags are documented in
# docs/ci.md so a red run is diagnosable from the job summary alone.

set -euo pipefail
cd "$(dirname "$0")/.."

# Never inherit a pointer to a real install; this script must only ever touch
# the scratch Eclipse it builds itself.
unset ECLIPSE_HOME

# shellcheck source=lib/common.sh
. lib/common.sh

# ------------------------------------------------------------ configuration
[ -n "${ECLIPSE_RELEASE:-}" ] || die "ECLIPSE_RELEASE is required (e.g. 2026-06)"
EXPECT_TAB_NPE="${EXPECT_TAB_NPE:-0}"
REVSTYLE_CI_SCRATCH="${REVSTYLE_CI_SCRATCH:-${RUNNER_TEMP:-$(mktemp -d)}/revstyle-e2e}"
EPP_CACHE_DIR="${EPP_CACHE_DIR:-$REVSTYLE_CI_SCRATCH/downloads}"
DEVSTYLE_REPO="${DEVSTYLE_REPO:-https://www.genuitec.com/updates/devstyle/ci/}"
SETTLE_SECONDS="${SETTLE_SECONDS:-100}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-180}"

RELEASE_REPO="https://download.eclipse.org/releases/${ECLIPSE_RELEASE}"
EPP_NAME="eclipse-java-${ECLIPSE_RELEASE}-R-linux-gtk-x86_64.tar.gz"
EPP_URL="https://download.eclipse.org/technology/epp/downloads/release/${ECLIPSE_RELEASE}/R/${EPP_NAME}"
# IU name read from a real install's p2 profile registry (pulls every
# com.genuitec.eclipse.theming.* bundle revstyle targets)
DEVSTYLE_IU="com.genuitec.eclipse.theming.core.feature.feature.group"

ECLIPSE_HOME="$REVSTYLE_CI_SCRATCH/eclipse"
LOGS_DIR="$REVSTYLE_CI_SCRATCH/logs"
WS_PRISTINE="$REVSTYLE_CI_SCRATCH/ws-pristine"
WS_PATCHED="$REVSTYLE_CI_SCRATCH/ws-patched"

# The exact 4.40 bug signature (docs/tab-renderer-npe.md)
NPE_SIG='Cannot invoke "java.lang.reflect.Field.setAccessible(boolean)" because "this.lastTabHeight" is null'

summary() {
  log "$*"
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf -- '- %s\n' "$*" >> "$GITHUB_STEP_SUMMARY" || true
}

# ------------------------------------------------------------ cleanup
cleanup() {
  local i
  if pgrep -x eclipse >/dev/null 2>&1; then
    pkill -x eclipse || true
    for i in $(seq 1 20); do
      pgrep -x eclipse >/dev/null 2>&1 || break
      sleep 1
    done
    pkill -9 -x eclipse 2>/dev/null || true
  fi
  # Evidence must survive early death. Logs only — never plugin bytes.
  mkdir -p "$LOGS_DIR"
  [ -f "$WS_PRISTINE/.metadata/.log" ] && cp "$WS_PRISTINE/.metadata/.log" "$LOGS_DIR/pristine-workspace.log" || true
  [ -f "$WS_PATCHED/.metadata/.log" ]  && cp "$WS_PATCHED/.metadata/.log"  "$LOGS_DIR/patched-workspace.log"  || true
}
trap cleanup EXIT

# ------------------------------------------------------------ stages
probe_update_site() {
  # GET a concrete p2 metadata file: the bare directory URL 403s (no listing),
  # and the server rejects HEAD — only real file GETs succeed.
  local f
  for f in compositeContent.xml compositeContent.jar content.xml content.jar; do
    if curl -fsSL --retry 3 --connect-timeout 20 --max-time 60 -o /dev/null "${DEVSTYLE_REPO%/}/$f"; then
      log "vendor update site reachable: $DEVSTYLE_REPO ($f)"
      return 0
    fi
  done
  die "[external-dependency-gone] Genuitec update site $DEVSTYLE_REPO serves no p2
  metadata (compositeContent/content .xml/.jar all failed). The vendor's
  abandoned-but-live p2 site may finally be gone. This is NOT a revstyle
  regression; see docs/ci.md for what to do."
}

fetch_epp() {
  local tarball="$EPP_CACHE_DIR/$EPP_NAME" sha="$EPP_CACHE_DIR/$EPP_NAME.sha512" want got attempt
  mkdir -p "$EPP_CACHE_DIR"
  # sha512 sibling is fetched fresh every run: verifies cached tarballs and
  # doubles as an eclipse.org reachability probe
  curl -fsSL --retry 3 --connect-timeout 20 -o "$sha" "$EPP_URL.sha512" \
    || die "[download-failed] cannot fetch $EPP_URL.sha512 — eclipse.org unreachable or the EPP layout changed"
  want=$(awk '{print $1}' "$sha")
  for attempt in 1 2; do
    if [ ! -f "$tarball" ]; then
      log "downloading $EPP_NAME (~350MB)..."
      curl -fsSL --retry 5 --retry-all-errors --connect-timeout 20 -o "$tarball" "$EPP_URL" \
        || die "[download-failed] could not download $EPP_URL"
    fi
    got=$(sha512sum "$tarball" | awk '{print $1}')
    [ "$got" = "$want" ] && break
    log "checksum mismatch on $EPP_NAME (attempt $attempt) — discarding and retrying"
    rm -f "$tarball"
    [ "$attempt" = 2 ] && die "[download-failed] EPP tarball fails sha512 verification after re-download"
  done
  log "EPP tarball verified"
}

extract_eclipse() {
  rm -rf "$ECLIPSE_HOME"
  tar -xzf "$EPP_CACHE_DIR/$EPP_NAME" -C "$REVSTYLE_CI_SCRATCH"
  [ -x "$ECLIPSE_HOME/eclipse" ] || die "[download-failed] tarball did not unpack to eclipse/eclipse"
}

install_devstyle() {
  log "installing DevStyle via p2 director (headless)..."
  timeout 900 "$ECLIPSE_HOME/eclipse" -nosplash -consolelog \
    -application org.eclipse.equinox.p2.director \
    -repository "${DEVSTYLE_REPO},${RELEASE_REPO}" \
    -installIU "$DEVSTYLE_IU" \
    > "$LOGS_DIR/p2-director.log" 2>&1 \
    || die "[director-failed] p2 director could not install DevStyle — see p2-director.log
  in the artifacts. If the repository failed to load, the vendor site's content
  may have changed or died (same family as [external-dependency-gone])."
  # Reuse the repo's own conventions to assert the install: both target BSNs
  # present in bundles.info at exactly DEVSTYLE_VERSION. The director writes
  # bundles.info itself — no reconciliation launch needed.
  resolve_eclipse "$ECLIPSE_HOME"
  check_devstyle_version
  log "DevStyle $DEVSTYLE_VERSION installed into scratch Eclipse"
}

# DevStyle's theme choice is INSTALL-scoped (configuration/.settings), not
# workspace-scoped. A virgin install has no theme chosen — it shows a welcome
# dialog and activates nothing, so neither the bug nor the fix would ever be
# exercised. Seed the prefs a real user's choice writes (verified against an
# install where the tab NPE reproduces). These are our own preference keys,
# not vendor bytes.
seed_theme_prefs() {
  local d="$ECLIPSE_HOME/configuration/.settings"
  mkdir -p "$d"
  printf 'eclipse.preferences.version=1\nworkbench.theme=Dark Gray\nshowWelcomeDialog=false\nwayland.never=true\n' \
    > "$d/com.genuitec.eclipse.theming.ui.prefs"
  printf 'eclipse.preferences.version=1\ncolorTheme=Darkest Dark\ncolorThemeExplicit=false\n' \
    > "$d/com.github.eclipsecolortheme.prefs"
  # DevStyle's startup bundle gates theme activation behind a first-launch
  # welcome flow — mark it as already completed or nothing ever activates
  printf 'eclipse.preferences.version=1\nfeatures=[]\nlaunchCount=4\nwelcomeFlowVersionShown=3\n' \
    > "$d/com.genuitec.eclipse.startup.prefs"
  log "seeded install-scoped DevStyle theme prefs (workbench.theme=Dark Gray, welcome flow done)"
}

# boot_eclipse <workspace> <label> — one headless workbench session.
# xvfb-run --auto-servernum over a hand-managed Xvfb: it owns display
# allocation and teardown across our two sequential sessions. Local fallback:
# without xvfb-run but with a real display (e.g. WSLg), run on that display.
# No window manager needed: theme activation and the tab NPE fire during the
# initial workbench render without one.
boot_eclipse() {
  local ws=$1 label=$2 boot_pid deadline
  local runner=(xvfb-run --auto-servernum)
  if ! command -v xvfb-run >/dev/null 2>&1; then
    [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] \
      || die "xvfb-run not installed and no display available — install xvfb"
    log "xvfb-run not installed; using the real display for the $label session"
    runner=(env)
  fi
  rm -rf "$ws"
  mkdir -p "$ws"
  GDK_BACKEND=x11 "${runner[@]}" \
    "$ECLIPSE_HOME/eclipse" -nosplash -consolelog -data "$ws" -clean \
    > "$LOGS_DIR/$label-launcher.log" 2>&1 &
  boot_pid=$!
  deadline=$((SECONDS + BOOT_TIMEOUT))
  until [ -f "$ws/.metadata/.log" ]; do
    kill -0 "$boot_pid" 2>/dev/null \
      || die "[boot-crashed] Eclipse ($label) exited before writing a workspace log — see $label-launcher.log"
    [ "$SECONDS" -lt "$deadline" ] \
      || die "[boot-timeout] Eclipse ($label) produced no workspace log within ${BOOT_TIMEOUT}s"
    sleep 2
  done
  log "$label workbench log appeared; soaking ${SETTLE_SECONDS}s"
  sleep "$SETTLE_SECONDS"
  pkill -x eclipse || true
  wait "$boot_pid" 2>/dev/null || true   # xvfb-run exits nonzero after the kill; expected
  local i
  for i in $(seq 1 20); do
    pgrep -x eclipse >/dev/null 2>&1 || break
    sleep 1
  done
  pgrep -x eclipse >/dev/null 2>&1 && pkill -9 -x eclipse || true
}

assert_negative_control() {
  local n activated
  n=$(grep -cF "$NPE_SIG" "$WS_PRISTINE/.metadata/.log" || true)
  if [ "$n" -ge 1 ]; then
    summary "negative control OK: $n tab-renderer NPEs on pristine DevStyle (Eclipse $ECLIPSE_RELEASE)"
    return 0
  fi
  activated=$(grep -cF 'A DevStyle Theme is being activated' "$WS_PRISTINE/.metadata/.log" || true)
  if [ "$activated" -eq 0 ]; then
    die "[negative-control-failed] DevStyle never activated its theme in the pristine
  session (no activation INFO entry) — the harness is broken, not the plugin.
  A green positive test from this workflow is NOT trustworthy until this is fixed."
  fi
  die "[negative-control-failed] pristine DevStyle no longer exhibits the tab-renderer
  NPE headlessly on Eclipse $ECLIPSE_RELEASE (theme did activate). The harness can no
  longer detect the bug it exists to guard — a green positive test is NOT
  trustworthy until this is fixed."
}

run_pipeline() {
  export ECLIPSE_HOME
  ./revstyle.sh all    || die "[pipeline-failed] setup/apply/build/pack failed — see job log"
  ./revstyle.sh deploy || die "[pipeline-failed] deploy failed — see job log"
  ./revstyle.sh status > "$LOGS_DIR/status.txt" 2>&1 || true
  local n
  n=$(grep -c 'patched by revstyle' "$LOGS_DIR/status.txt" || true)
  [ "$n" -ge "${#TARGET_BSNS[@]}" ] \
    || die "[deploy-not-patched] status reports only $n of ${#TARGET_BSNS[@]} bundles as 'patched by revstyle' — see status.txt"
  summary "pipeline + deploy OK (Eclipse $ECLIPSE_RELEASE)"
}

assert_positive_clean() {
  # Block-aware scan: whitelisted noise (the Oomph no-browser SWTError and its
  # follow-up ClassCastException) spans multi-line !ENTRY blocks, sometimes
  # under a generic "Unhandled event loop exception" header — line-level
  # grep -v filtering would misfire. A block fails when it matches a failure
  # pattern and nothing in it matches the allowlist.
  # Failure patterns: the reflection-breakage exception families + the 4.40
  # signature field, plus severity-4 (ERROR) genuitec !ENTRY stacks — NOT the
  # bare word "genuitec" (INFO entries mention it legitimately).
  # Allowlist (verified benign on runners without WebKitGTK):
  #   - Oomph "No more handles ... no underlying browser" + NotificationViewPart cast
  #   - jface "Cannot bind to an undefined command" warning
  #   - DevStyle Wayland advisory (absent under X11; belt-and-braces)
  awk '
    function flush() { if (bad && !ok) printf "%s", blk; blk=""; bad=0; ok=0 }
    /^!(SESSION|ENTRY)/ { flush() }
    {
      blk = blk $0 "\n"
      if ($0 ~ /NullPointerException|NoSuchField|NoSuchMethod|LinkageError|Unhandled event loop|lastTabHeight/) bad=1
      if ($0 ~ /^!ENTRY com\.genuitec\.[^ ]+ 4 /) bad=1
      if ($0 ~ /No more handles because there is no underlying browser available|Cannot bind to an undefined command|WEBKIT_DISABLE_COMPOSITING_MODE|NotificationViewPart/) ok=1
    }
    END { flush() }
  ' "$WS_PATCHED/.metadata/.log" > "$LOGS_DIR/positive-failures.txt"
  if [ -s "$LOGS_DIR/positive-failures.txt" ]; then
    cat "$LOGS_DIR/positive-failures.txt"
    die "[positive-test-failed] failure signatures in the patched workspace log
  (Eclipse $ECLIPSE_RELEASE) — likely a new Eclipse/DevStyle breakage. Full log and
  positive-failures.txt are in the artifacts; start at the CLAUDE.md diagnosis playbook."
  fi
  summary "positive test OK: patched workspace log clean (Eclipse $ECLIPSE_RELEASE)"
}

# ------------------------------------------------------------ main
# xvfb-run is checked lazily in boot_eclipse (local runs may use a real display)
require_cmd curl tar awk grep sha512sum pgrep pkill timeout java javac jar unzip zip patch sha256sum sed
mkdir -p "$REVSTYLE_CI_SCRATCH" "$LOGS_DIR"
log "scratch: $REVSTYLE_CI_SCRATCH (Eclipse $ECLIPSE_RELEASE, negative control: $EXPECT_TAB_NPE)"

probe_update_site
fetch_epp
extract_eclipse
install_devstyle
seed_theme_prefs

if [ "$EXPECT_TAB_NPE" = 1 ]; then
  boot_eclipse "$WS_PRISTINE" pristine
  assert_negative_control
else
  # 4.39's known bug is silent geometry (docs/scrollbar-autoscaling.md) —
  # nothing to assert from logs, so no negative control on this release.
  log "negative control skipped for Eclipse $ECLIPSE_RELEASE"
fi

run_pipeline
boot_eclipse "$WS_PATCHED" patched
assert_positive_clean

summary "e2e PASS (Eclipse $ECLIPSE_RELEASE)"
