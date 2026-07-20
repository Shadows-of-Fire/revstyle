# revstyle shared helpers. Sourced by revstyle.sh — not executable on its own.
# shellcheck shell=bash

set -euo pipefail

# ---------------------------------------------------------------- constants
DEVSTYLE_VERSION="2025.2.0.202509301431"   # the last DevStyle release ever shipped
UI_BSN="com.genuitec.eclipse.theming.ui"
SB_BSN="com.genuitec.eclipse.theming.scrollbar"
TARGET_BSNS=("$UI_BSN" "$SB_BSN")

# Manifest main-attribute stamped into every revstyle-repacked jar (pack_bundle);
# its presence is the sole discriminator of patched vs pristine jars.
REVSTYLE_MARKER='Revstyle-Patched'

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
# java_str_hash <s> — Java String.hashCode, made non-negative. Equinox names
# per-user configuration areas ~/.eclipse/<product>_<ver>_<hash>_<os_ws_arch>
# using this hash of the absolute install path.
java_str_hash() {
  printf '%s' "$1" | od -An -tu1 -v | tr ' ' '\n' \
    | awk 'NF{h=(h*31+$1)%4294967296} END{if(h>2147483647)h-=4294967296; if(h<0)h=-h; print h}'
}

# find_user_config_area — echoes the ~/.eclipse configuration dir belonging to
# $ECLIPSE_HOME, or nothing. Matches by install-path hash first; falls back to
# a behavioral probe (an area whose platform-bundle entries resolve under this
# install) in case Equinox hashed a differently-normalized path.
find_user_config_area() {
  local hash area rel
  for hash in $(java_str_hash "$ECLIPSE_HOME") $(java_str_hash "$(realpath "$ECLIPSE_HOME" 2>/dev/null || echo "$ECLIPSE_HOME")"); do
    for area in "$HOME/.eclipse/"*"_${hash}_"*/configuration; do
      [ -f "$area/org.eclipse.equinox.simpleconfigurator/bundles.info" ] && { printf '%s\n' "$area"; return 0; }
    done
  done
  for area in "$HOME/.eclipse/"*/configuration; do
    [ -f "$area/org.eclipse.equinox.simpleconfigurator/bundles.info" ] || continue
    rel=$(awk -F, '!/^#/ && $3 ~ /^plugins\// {print $3; exit}' "$area/org.eclipse.equinox.simpleconfigurator/bundles.info")
    [ -n "$rel" ] && [ -f "$ECLIPSE_HOME/$rel" ] && { printf '%s\n' "$area"; return 0; }
  done
  return 1
}

# resolve_eclipse [path] — sets ECLIPSE_HOME, CONFIG_AREA and BUNDLES_INFO.
# ECLIPSE_HOME is the install area (eclipse.ini, platform plugins/). The
# active configuration is the install's own configuration/ when writable
# (classic layout); on read-only installs (distro-packaged Eclipse, issue #1)
# Equinox shadows it into a per-user area under ~/.eclipse, whose bundles.info
# is then the authority — user-installed bundles live in that area's plugins/,
# referenced by paths that resolve relative to the install area.
resolve_eclipse() {
  local candidate="${1:-${ECLIPSE_HOME:-}}"
  [ -n "$candidate" ] || die "no Eclipse install given. Pass --eclipse <path> or set ECLIPSE_HOME.
  Example: ./revstyle.sh --eclipse /mnt/c/eclipse setup"
  ECLIPSE_HOME="${candidate%/}"
  [ -d "$ECLIPSE_HOME/plugins" ] || die "'$ECLIPSE_HOME' does not look like an Eclipse install (no plugins/ directory)"
  if [ -n "${ECLIPSE_CONFIG:-}" ]; then
    CONFIG_AREA="${ECLIPSE_CONFIG%/}"
  elif [ -w "$ECLIPSE_HOME/configuration" ]; then
    CONFIG_AREA="$ECLIPSE_HOME/configuration"
  else
    CONFIG_AREA=$(find_user_config_area) || die "install at $ECLIPSE_HOME is not writable and no matching
  per-user configuration area exists under ~/.eclipse.
  Launch Eclipse once as this user (that creates the area), or pass the area
  explicitly with --config <dir>, then retry."
    log "read-only install: using per-user configuration area ${CONFIG_AREA%/configuration}"
  fi
  BUNDLES_INFO="$CONFIG_AREA/org.eclipse.equinox.simpleconfigurator/bundles.info"
  [ -f "$BUNDLES_INFO" ] || die "missing $BUNDLES_INFO — not a simpleconfigurator-managed Eclipse?"
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

# bundle_on_disk <bsn> — a matching jar exists under the install's or the
# user area's plugins/, whether or not bundles.info knows about it yet
# (p2 reconciles a new install on next launch)
bundle_on_disk() {
  compgen -G "$ECLIPSE_HOME/plugins/${1}_*.jar" >/dev/null && return 0
  compgen -G "${CONFIG_AREA%/configuration}/plugins/${1}_*.jar" >/dev/null
}

check_devstyle_version() {
  local bsn ver
  for bsn in "${TARGET_BSNS[@]}"; do
    if ! ver=$(bundle_version "$bsn"); then
      if bundle_on_disk "$bsn"; then
        die "$bsn is present in plugins/ but absent from bundles.info.
  Launch Eclipse once so p2 reconciles the install, then retry."
      fi
      die "DevStyle bundle '$bsn' not found in bundles.info — is DevStyle installed?"
    fi
    [ "$ver" = "$DEVSTYLE_VERSION" ] || die "found $bsn $ver but the patches target $DEVSTYLE_VERSION exactly.
  Patches are version-specific; a different DevStyle build will not match."
  done
}

# is_revstyle_patched <jar> — repacked jars carry a manifest marker (see pack_bundle)
is_revstyle_patched() {
  unzip -p "$1" META-INF/MANIFEST.MF 2>/dev/null | grep "^$REVSTYLE_MARKER:" >/dev/null
}

# has_signature <jar> — any JAR signature present (the vendor signs as CODETOGE,
# but fresh installs can legitimately ship unsigned or differently-aliased jars)
has_signature() {
  unzip -l "$1" 2>/dev/null | grep -E 'META-INF/[^/]*\.SF' >/dev/null
}

# ensure_backup <bsn> — guarantee backups/ holds a pristine copy of the bundle jar
ensure_backup() {
  local bsn=$1 jar base
  jar=$(bundle_jar "$bsn")
  base=$(basename "$jar")
  mkdir -p "$BACKUPS_DIR"
  if [ -f "$BACKUPS_DIR/$base" ]; then
    if is_revstyle_patched "$BACKUPS_DIR/$base"; then
      die "backup '$BACKUPS_DIR/$base' is a revstyle-patched jar, not pristine.
  Remove it and place a pristine copy there (or reinstall DevStyle and re-run setup)."
    fi
    return 0
  fi
  if is_revstyle_patched "$jar"; then
    die "$base in plugins/ was already patched by revstyle and no pristine backup exists in $BACKUPS_DIR.
  Reinstall DevStyle or place a pristine copy of the jar in $BACKUPS_DIR, then retry."
  fi
  if ! has_signature "$jar"; then
    warn "$base has no vendor signature (no META-INF/*.SF) — treating it as a fresh
  unsigned install and backing it up as pristine. If this jar was patched by an
  older revstyle (before the manifest marker), do NOT trust this backup: restore
  a pristine copy into $BACKUPS_DIR instead."
  fi
  cp "$jar" "$BACKUPS_DIR/$base"
  log "backed up pristine $base"
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
  # The classpath spans ~1000 active bundle jars (~128 KiB), which exceeds the
  # OS single-argument limit (Linux MAX_ARG_STRLEN, 128 KiB) once ECLIPSE_HOME's
  # absolute prefix is applied to each entry — so javac dies with "Argument list
  # too long". Feed it via an @argfile instead. Paths are double-quoted to
  # tolerate spaces; they use forward slashes, so backslash-escaping never bites.
  local argfile="$BUILD_DIR/$bsn.javac.args"
  {
    printf -- '--release 8 -nowarn -encoding UTF-8\n'
    printf -- '-classpath "%s"\n' "$cp"
    printf -- '-d "%s"\n' "$out"
    for s in "${files[@]}"; do printf -- '"%s"\n' "$s"; done
  } > "$argfile"
  javac "@$argfile" \
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
  # main section only, minus its terminating blank line, so the appended marker
  # stays inside the main section; no timestamps — repacks must be deterministic
  unzip -p "$out" META-INF/MANIFEST.MF | sed -n '/^\r*$/q;p' > "$manifest"
  printf '%s: true\r\n' "$REVSTYLE_MARKER" >> "$manifest"
  # globs, not the CODETOGE literals: unsigned pristine jars have no signature
  # entries, and MANIFEST.MF always matching keeps zip -d from exiting 12
  zip -q -d "$out" 'META-INF/*.SF' 'META-INF/*.RSA' 'META-INF/*.DSA' 'META-INF/MANIFEST.MF'
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
  unzip -p "$out" META-INF/MANIFEST.MF | grep "^$REVSTYLE_MARKER: true" >/dev/null \
    || die "revstyle marker missing from repacked manifest of $bsn"
  log "packed $out"
}

# ---------------------------------------------------------------- misc state
eclipse_running() {
  # Best-effort. WSL: ask Windows, but only when the target install is a
  # Windows one (/mnt/*) — a Windows Eclipse can't hold a Linux install's files
  case "$ECLIPSE_HOME" in
    /mnt/*)
      if command -v tasklist.exe >/dev/null 2>&1; then
        tasklist.exe /FI "IMAGENAME eq eclipse.exe" /NH 2>/dev/null | grep eclipse.exe >/dev/null && return 0
      fi ;;
  esac
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
