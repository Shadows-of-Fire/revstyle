#!/usr/bin/env bash
# revstyle — repair the abandoned DevStyle plugin on modern Eclipse (2026-03+)
# using your own installation's jars. Ships no Genuitec code; see README.md.
#
# Usage: ./revstyle.sh [--eclipse <path>] <command>
#
# Commands:
#   setup [--all]  fetch jars from the install, back up pristine copies,
#                  decompile/extract sources into work/ (--all: every DevStyle
#                  bundle, for exploration; default: only the patched bundles)
#   apply          apply the patches/ *.patch files to work/ (idempotent)
#   build          compile the patched sources against the install's bundles
#   pack           repack patched jars into build/ (signature stripped)
#   deploy         install build/ jars into the Eclipse plugins/ folder
#   restore        put the pristine backed-up jars back
#   status         show install, versions, and patch state
#   all            setup + apply + build + pack

set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib/common.sh
. lib/common.sh

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# ------------------------------------------------------------ arg parsing
ECLIPSE_ARG=""
CMD=""
SETUP_ALL=0
DEPLOY_FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --eclipse) shift; [ $# -gt 0 ] || die "--eclipse needs a path"; ECLIPSE_ARG=$1 ;;
    --eclipse=*) ECLIPSE_ARG=${1#--eclipse=} ;;
    --all) SETUP_ALL=1 ;;
    --force) DEPLOY_FORCE=1 ;;
    -h|--help) usage 0 ;;
    setup|apply|build|pack|deploy|restore|status|all) CMD=$1 ;;
    *) die "unknown argument '$1' (try --help)" ;;
  esac
  shift
done
[ -n "$CMD" ] || usage 1

require_cmd java javac jar unzip zip patch curl sha256sum awk sed
resolve_eclipse "$ECLIPSE_ARG"

# ------------------------------------------------------------ commands
cmd_setup() {
  check_devstyle_version
  log "Eclipse install: $ECLIPSE_HOME (DevStyle $DEVSTYLE_VERSION found)"
  ensure_vineflower
  local bsn
  for bsn in "${TARGET_BSNS[@]}"; do
    ensure_backup "$bsn"
  done
  if [ "$SETUP_ALL" = 1 ]; then
    log "setting up full workspace (--all)..."
    local line
    grep -E '^com\.genuitec\.' "$BUNDLES_INFO" | while IFS=, read -r bsn _ver rel _rest; do
      case "$rel" in *.jar) ;; *) log "skipping exploded bundle $bsn"; continue ;; esac
      log "  $bsn"
      extract_bundle_project "$bsn"
    done
  else
    for bsn in "${TARGET_BSNS[@]}"; do
      log "extracting $bsn"
      extract_bundle_project "$bsn"
    done
  fi
  log "setup complete. Next: ./revstyle.sh apply"
}

cmd_apply() {
  [ -d "$WORK_DIR" ] || die "no work/ tree — run 'setup' first"
  local p applied=0 skipped=0
  while IFS= read -r p; do
    if patch -R -p1 -d "$WORK_DIR" --dry-run -s < "$p" >/dev/null 2>&1; then
      log "already applied: $(basename "$p")"
      skipped=$((skipped+1))
      continue
    fi
    if ! patch -p1 -d "$WORK_DIR" -N --dry-run -s < "$p" >/dev/null 2>&1; then
      die "patch does not apply cleanly: $p
  This usually means the DevStyle jars or the pinned VineFlower version differ
  from what the patch was generated against. Run 'status' and check versions."
    fi
    patch -p1 -d "$WORK_DIR" -N -s < "$p"
    log "applied: $(basename "$p")"
    applied=$((applied+1))
  done < <(find "$PATCHES_DIR" -name '*.patch' | sort)
  [ $((applied+skipped)) -gt 0 ] || die "no patches found under $PATCHES_DIR"
  log "patches: $applied applied, $skipped already present. Next: ./revstyle.sh build"
}

cmd_build() {
  compile_unit "$UI_BSN" "$UI_SRC_DIR" "$UI_EXPECTED_CLASSES" "${UI_SOURCES[@]}"
  compile_unit "$SB_BSN" "$SB_SRC_DIR" "$SB_EXPECTED_CLASSES" "${SB_SOURCES[@]}"
  log "build complete. Next: ./revstyle.sh pack"
}

cmd_pack() {
  pack_bundle "$UI_BSN" "$UI_SRC_DIR"
  pack_bundle "$SB_BSN" "$SB_SRC_DIR"
  log "pack complete. Next: ./revstyle.sh deploy"
}

cmd_deploy() {
  if eclipse_running && [ "$DEPLOY_FORCE" != 1 ]; then
    die "Eclipse appears to be running — close it first (or pass --force)"
  fi
  local bsn jar out ini
  for bsn in "${TARGET_BSNS[@]}"; do
    out="$BUILD_DIR/$bsn.jar"
    [ -f "$out" ] || die "missing $out — run 'pack' first"
    jar=$(bundle_jar "$bsn")
    cp "$out" "$jar"
    log "deployed $(basename "$jar")"
  done
  if ini=$(eclipse_ini_path) && grep -q -- "$SCROLLBAR_WORKAROUND" "$ini"; then
    cp "$ini" "$ini.revstyle.bak"
    sed -i "/${SCROLLBAR_WORKAROUND//\//\\/}/d" "$ini"
    log "removed the old '$SCROLLBAR_WORKAROUND' workaround from $(basename "$ini") (backup: $(basename "$ini").revstyle.bak)"
  fi
  log "done. Launch Eclipse once with -clean so the OSGi cache picks up the new jars."
}

cmd_restore() {
  local bsn jar backup
  for bsn in "${TARGET_BSNS[@]}"; do
    jar=$(bundle_jar "$bsn")
    backup="$BACKUPS_DIR/$(basename "$jar")"
    [ -f "$backup" ] || die "no backup for $bsn in $BACKUPS_DIR"
    cp "$backup" "$jar"
    log "restored pristine $(basename "$jar")"
  done
  log "done. Launch Eclipse once with -clean.
Hint: pristine DevStyle is broken on Eclipse 2026-06; on 2026-03 you may want
to re-add '$SCROLLBAR_WORKAROUND' to eclipse.ini."
}

cmd_status() {
  log "Eclipse install : $ECLIPSE_HOME"
  local bsn ver jar state backup
  for bsn in "${TARGET_BSNS[@]}"; do
    ver=$(bundle_version "$bsn" 2>/dev/null || echo "not installed")
    if [ "$ver" = "not installed" ]; then
      log "$bsn : not installed"
      continue
    fi
    jar=$(bundle_jar "$bsn")
    if is_pristine "$jar"; then state="pristine"; else state="patched (signature stripped)"; fi
    backup="$BACKUPS_DIR/$(basename "$jar")"
    [ -f "$backup" ] && state="$state, backup present"
    log "$bsn : $ver — $state"
  done
  local ini
  if ini=$(eclipse_ini_path); then
    if grep -q -- "$SCROLLBAR_WORKAROUND" "$ini"; then
      log "eclipse.ini     : themedScrollbar workaround PRESENT (deploy will remove it)"
    else
      log "eclipse.ini     : no themedScrollbar workaround"
    fi
  fi
  [ -d "$WORK_DIR" ] && log "work tree       : present" || log "work tree       : absent (run setup)"
  [ -f "$BUILD_DIR/$UI_BSN.jar" ] && log "packed jars     : present" || log "packed jars     : absent"
}

cmd_all() {
  cmd_setup
  cmd_apply
  cmd_build
  cmd_pack
  log "ready — review 'status', then run: ./revstyle.sh deploy"
}

"cmd_$CMD"
