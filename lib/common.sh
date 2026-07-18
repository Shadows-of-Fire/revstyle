# revstyle shared helpers. Sourced by revstyle.sh — not executable on its own.
# shellcheck shell=bash

set -euo pipefail

# ---------------------------------------------------------------- constants
DEVSTYLE_VERSION="2025.2.0.202509301431"   # the last DevStyle release ever shipped
UI_BSN="com.genuitec.eclipse.theming.ui"
SB_BSN="com.genuitec.eclipse.theming.scrollbar"
TARGET_BSNS=("$UI_BSN" "$SB_BSN")

VF_VERSION="1.12.0"
VF_URL="https://github.com/Vineflower/vineflower/releases/download/${VF_VERSION}/vineflower-${VF_VERSION}.jar"
VF_SHA256="1dfcfe974395734fa467ce620661c7623d05ba83670de0529b1fbd63ff548b9d"
# Decompiler flags are part of the patch contract: the theming.ui patch applies
# to VineFlower ${VF_VERSION} output produced with exactly these flags.
VF_FLAGS=(--folder --use-lvt-names=1)

# Class files each compile unit must produce (used to catch decompiler drift).
UI_SRC_DIR="com/genuitec/eclipse/theming/ui/rendering"
UI_SOURCES=(SquareTabRenderer.java DashboardSquareTabRenderer.java)
UI_EXPECTED_CLASSES=8
SB_SRC_DIR="com/codeaffine/eclipse/swt/widget/scrollable"
SB_SOURCES=(ScrollableAdapterFactory.java)
SB_EXPECTED_CLASSES=2

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$REPO_DIR/tools"
WORK_DIR="$REPO_DIR/work"
BUILD_DIR="$REPO_DIR/build"
BACKUPS_DIR="$REPO_DIR/backups"
PATCHES_DIR="$REPO_DIR/patches"

# ---------------------------------------------------------------- utilities
log()  { printf '[revstyle] %s\n' "$*"; }
warn() { printf '[revstyle] WARNING: %s\n' "$*" >&2; }
die()  { printf '[revstyle] ERROR: %s\n' "$*" >&2; exit 1; }

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command '$c' not found on PATH"
  done
}

# ---------------------------------------------------------------- eclipse install
# resolve_eclipse [path] — sets ECLIPSE_HOME and BUNDLES_INFO
resolve_eclipse() {
  local candidate="${1:-${ECLIPSE_HOME:-}}"
  [ -n "$candidate" ] || die "no Eclipse install given. Pass --eclipse <path> or set ECLIPSE_HOME.
  Example: ./revstyle.sh --eclipse /mnt/c/eclipse setup"
  ECLIPSE_HOME="${candidate%/}"
  BUNDLES_INFO="$ECLIPSE_HOME/configuration/org.eclipse.equinox.simpleconfigurator/bundles.info"
  [ -f "$BUNDLES_INFO" ] || die "'$ECLIPSE_HOME' does not look like an Eclipse install (missing $BUNDLES_INFO)"
}

# bundle_info_line <bsn> — echoes the bundles.info CSV line for a symbolic name
bundle_info_line() {
  grep -m1 "^$1," "$BUNDLES_INFO" || return 1
}

# bundle_version <bsn>
bundle_version() {
  bundle_info_line "$1" | cut -d, -f2
}

# bundle_jar <bsn> — absolute path of the ACTIVE jar for a bundle. bundles.info
# is the source of truth: installs updated in place keep stale older jars on disk.
bundle_jar() {
  local rel
  rel=$(bundle_info_line "$1" | cut -d, -f3) || return 1
  case "$rel" in
    /*)        printf '%s\n' "$rel" ;;
    file:*)    die "unsupported bundle location '$rel' in bundles.info" ;;
    *)         printf '%s/%s\n' "$ECLIPSE_HOME" "$rel" ;;
  esac
}

check_devstyle_version() {
  local bsn ver
  for bsn in "${TARGET_BSNS[@]}"; do
    ver=$(bundle_version "$bsn") || die "DevStyle bundle '$bsn' not found in bundles.info — is DevStyle installed?"
    [ "$ver" = "$DEVSTYLE_VERSION" ] || die "found $bsn $ver but the patches target $DEVSTYLE_VERSION exactly.
  Patches are version-specific; a different DevStyle build will not match."
  done
}

# is_pristine <jar> — a jar unmodified by us still carries the vendor signature
is_pristine() {
  unzip -l "$1" 2>/dev/null | grep 'META-INF/CODETOGE\.SF' >/dev/null
}

# ensure_backup <bsn> — guarantee backups/ holds a pristine copy of the bundle jar
ensure_backup() {
  local bsn=$1 jar base
  jar=$(bundle_jar "$bsn")
  base=$(basename "$jar")
  mkdir -p "$BACKUPS_DIR"
  if [ -f "$BACKUPS_DIR/$base" ]; then
    is_pristine "$BACKUPS_DIR/$base" || die "backup '$BACKUPS_DIR/$base' is not pristine (signature missing). Remove it and restore a pristine jar first."
    return 0
  fi
  if is_pristine "$jar"; then
    cp "$jar" "$BACKUPS_DIR/$base"
    log "backed up pristine $base"
  else
    die "$base in plugins/ is already modified (signature stripped) and no pristine backup exists in $BACKUPS_DIR.
  Reinstall DevStyle or place a pristine copy of the jar in $BACKUPS_DIR, then retry."
  fi
}

backup_jar_path() {
  local jar
  jar=$(bundle_jar "$1")
  printf '%s/%s\n' "$BACKUPS_DIR" "$(basename "$jar")"
}

# ---------------------------------------------------------------- vineflower
ensure_vineflower() {
  local jar="$TOOLS_DIR/vineflower-${VF_VERSION}.jar" sum
  mkdir -p "$TOOLS_DIR"
  if [ ! -f "$jar" ]; then
    log "downloading VineFlower ${VF_VERSION}..."
    curl -fsSL -o "$jar" "$VF_URL" || die "failed to download $VF_URL"
  fi
  sum=$(sha256sum "$jar" | cut -d' ' -f1)
  [ "$sum" = "$VF_SHA256" ] || die "VineFlower checksum mismatch for $jar
  expected $VF_SHA256
  got      $sum
  Delete the file and retry, or update VF_SHA256 if you intentionally changed versions
  (note: the theming.ui patch is generated against ${VF_VERSION} output and may not apply to other versions)."
  VF_JAR="$jar"
}

# decompile_jar <jar> <outdir> — VineFlower with the pinned flags; .java only
decompile_jar() {
  local jar=$1 out=$2
  mkdir -p "$out"
  java -jar "$VF_JAR" "${VF_FLAGS[@]}" "$jar" "$out/" > /dev/null 2>&1 \
    || die "VineFlower failed on $jar"
  find "$out" -type f ! -name '*.java' -delete
  find "$out" -type d -empty -delete 2>/dev/null || true
}

# extract_bundle_project <bsn> — build work/<bsn>/ per the layout contract:
#   <bsn>/            non-class jar entries (resources, META-INF, embedded src/)
#   <bsn>/src/        patch/build source tree: the jar's embedded sources if it
#                     ships them, otherwise VineFlower output
#   <bsn>/src-vf/     VineFlower output kept separately when embedded sources
#                     exist (reference only — never overwrite real sources)
extract_bundle_project() {
  local bsn=$1 jar proj
  jar=$(backup_jar_path "$bsn")
  [ -f "$jar" ] || jar=$(bundle_jar "$bsn")
  proj="$WORK_DIR/$bsn"
  rm -rf "$proj"
  mkdir -p "$proj"
  unzip -qo "$jar" -x '*.class' -d "$proj" 2>/dev/null || true
  if [ -d "$proj/src" ]; then
    decompile_jar "$jar" "$proj/src-vf"
    # VineFlower copies jar resources including the embedded src/** — drop the copy
    rm -rf "$proj/src-vf/src"
  else
    decompile_jar "$jar" "$proj/src"
    rm -rf "$proj/src/src" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------- build & pack
# classpath_for <pristine-jar> — pristine target jar first (unpatched classes
# resolve from it), then every active bundle jar from bundles.info
classpath_for() {
  local first=$1
  {
    printf '%s' "$first"
    awk -F, -v ecl="$ECLIPSE_HOME" '!/^#/ && $3 ~ /\.jar$/ {printf ":%s/%s", ecl, $3}' "$BUNDLES_INFO"
  }
}

# compile_unit <bsn> <src-subdir> <expected-count> <sources...>
compile_unit() {
  local bsn=$1 subdir=$2 expected=$3; shift 3
  local srcroot="$WORK_DIR/$bsn/src" out="$BUILD_DIR/classes/$bsn" cp produced s
  [ -d "$srcroot/$subdir" ] || die "missing sources for $bsn — run 'setup' (and 'apply') first"
  local files=()
  for s in "$@"; do files+=("$srcroot/$subdir/$s"); done
  rm -rf "$out"
  mkdir -p "$out"
  cp=$(classpath_for "$(backup_jar_path "$bsn")")
  javac --release 8 -nowarn -encoding UTF-8 -cp "$cp" -d "$out" "${files[@]}" \
    || die "compilation failed for $bsn (did 'apply' succeed? is the Eclipse install the version the patches target?)"
  produced=$(find "$out" -name '*.class' | wc -l)
  [ "$produced" -eq "$expected" ] || die "$bsn produced $produced class files, expected $expected — decompiler or source drift"
  log "compiled $bsn: $produced class files"
}

# pack_bundle <bsn> <class-subdir> — repack pristine jar with patched classes.
# The vendor signature must be stripped (edited entries would fail verification)
# and MANIFEST.MF reduced to its main section, because per-entry digest sections
# would reference the old bytes. NB: 'jar --update --manifest' MERGES with an
# existing in-jar manifest, so the old manifest is deleted from the zip first.
pack_bundle() {
  local bsn=$1 subdir=$2
  local pristine out manifest classes entry
  pristine=$(backup_jar_path "$bsn")
  [ -f "$pristine" ] || die "no pristine backup for $bsn — run 'setup' first"
  out="$BUILD_DIR/$bsn.jar"
  manifest="$BUILD_DIR/$bsn.MF"
  classes="$BUILD_DIR/classes/$bsn"
  [ -d "$classes" ] || die "no compiled classes for $bsn — run 'build' first"
  mkdir -p "$BUILD_DIR"
  cp "$pristine" "$out"
  unzip -p "$out" META-INF/MANIFEST.MF | sed '/^\r*$/q' > "$manifest"
  zip -q -d "$out" 'META-INF/CODETOGE.SF' 'META-INF/CODETOGE.RSA' 'META-INF/MANIFEST.MF'
  jar --update --file "$out" --manifest "$manifest"
  (cd "$classes" && jar --update --file "$out" "$subdir"/*.class)
  # sanity
  # NB: no `grep -q` after a pipe anywhere here — with pipefail, -q's early
  # exit SIGPIPEs the producer and corrupts the pipeline's status.
  if unzip -l "$out" | grep -E 'META-INF/.*\.(SF|RSA|DSA)' >/dev/null; then die "signature files survived repack of $bsn"; fi
  if unzip -p "$out" META-INF/MANIFEST.MF | grep 'SHA-256-Digest' >/dev/null; then die "per-entry digests survived repack of $bsn"; fi
  for entry in Bundle-SymbolicName Bundle-Version; do
    unzip -p "$out" META-INF/MANIFEST.MF | grep "^$entry" >/dev/null || die "$entry missing from repacked manifest of $bsn"
  done
  log "packed $out"
}

# ---------------------------------------------------------------- misc state
eclipse_running() {
  # Best-effort. WSL: ask Windows; native: pgrep.
  if command -v tasklist.exe >/dev/null 2>&1; then
    tasklist.exe /FI "IMAGENAME eq eclipse.exe" /NH 2>/dev/null | grep eclipse.exe >/dev/null && return 0
  fi
  # exact process name only — a -f substring match would hit our own command line
  pgrep -x eclipse >/dev/null 2>&1 && return 0
  return 1
}

eclipse_ini_path() {
  local f
  for f in "$ECLIPSE_HOME/eclipse.ini" "$ECLIPSE_HOME"/*.ini; do
    [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
  done
  return 1
}

SCROLLBAR_WORKAROUND='-Ddevstyle.enable.themedScrollbar=false'
