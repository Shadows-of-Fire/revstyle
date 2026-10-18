# revstyle shared helpers. Sourced by revstyle.sh — not executable on its own.
# shellcheck shell=bash

set -euo pipefail

# ---------------------------------------------------------------- constants
DEVSTYLE_VERSION="2025.2.0.202509301431"   # the last DevStyle release ever shipped

# Manifest main-attribute stamped into every revstyle-repacked jar (pack_bundle);
# its presence is the sole discriminator of patched vs pristine jars.
REVSTYLE_MARKER='Revstyle-Patched'

# Timestamp pinned onto the entries pack_bundle rewrites (the DevStyle release
# stamp, 202509301431 UTC) — keeps repacks free of wall-clock so rebuilds
# stay byte-identical.
PACK_MTIME='2025-09-30T14:31:00Z'

VF_VERSION="1.12.0"
VF_URL="https://github.com/Vineflower/vineflower/releases/download/${VF_VERSION}/vineflower-${VF_VERSION}.jar"
VF_SHA256="1dfcfe974395734fa467ce620661c7623d05ba83670de0529b1fbd63ff548b9d"
# Decompiler flags are part of the patch contract: the theming.ui patch applies
# to VineFlower ${VF_VERSION} output produced with exactly these flags.
VF_FLAGS=(--folder --use-lvt-names=1)

# Patch targets — one entry per bundle revstyle rewrites, in the form
#   <bsn>|<package dir of the patched sources>|<expected .class count>|<source files>|<resource files>
# Sources are compiled; resources (jar-relative, e.g. plugin.xml) are taken
# verbatim from the patched work/<bsn>/ tree — for fixes that live in a
# bundle's metadata rather than its classes. Either list may be empty.
# The class count is the jar's full Outer*.class set for those sources: javac
# regenerates every nested class of a recompiled outer class and pack replaces
# the whole set, so a count mismatch means decompiler or source drift. Adding
# a bundle here is all the wiring a new fix needs (plus its patches/<bsn>/).
PATCH_TARGETS=(
  "com.genuitec.eclipse.theming.ui|com/genuitec/eclipse/theming/ui/rendering|8|SquareTabRenderer.java DashboardSquareTabRenderer.java|"
  "com.genuitec.eclipse.theming.scrollbar|com/codeaffine/eclipse/swt/widget/scrollable|2|ScrollableAdapterFactory.java|"
  "com.genuitec.eclipse.startup|com/genuitec/eclipse/startup/patches|1|IgnoreCSSClassPatch.java|"
  "com.genuitec.eclipse.core.common.platform|com/genuitec/eclipse/core/util|1|PlatformUtil.java|"
  "com.genuitec.eclipse.theming.css||||plugin.xml css/include/globalstyle.css"
  "com.genuitec.eclipse.theming.core|com/genuitec/eclipse/theming/core/internal/extensions|2|FixTree202609.java FixTable202609.java|plugin.xml"
)
TARGET_BSNS=()
for _t in "${PATCH_TARGETS[@]}"; do TARGET_BSNS+=("${_t%%|*}"); done
unset _t

# with_target <entry> <fn> — split a PATCH_TARGETS entry and call
# fn <bsn> <src-subdir> <expected-count> "<sources>" "<resources>"
# (the two lists stay single space-separated words; callers split them)
with_target() {
  local entry=$1 fn=$2 bsn subdir expected sources resources
  IFS='|' read -r bsn subdir expected sources resources <<< "$entry"
  "$fn" "$bsn" "$subdir" "${expected:-0}" "$sources" "$resources"
}

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

# ---------------------------------------------------------------- platform shim
# Git Bash (MSYS) drives a *native Windows* JDK: MSYS auto-converts POSIX paths
# on the argv of native executables, but NOT inside javac @argfiles (issue #3),
# and drive colons in classpath lists suppress list conversion entirely. So we
# never rely on auto-conversion: bash-side tools (unzip, patch, cp, find) keep
# MSYS paths, and every path handed to a native JVM tool goes through
# native_path. cygpath -m yields C:/mixed form — never contains backslashes, so
# it is safe on argv and double-quoted inside argfiles alike.
case "${OSTYPE:-}" in
  msys|cygwin) IS_MSYS=1; CP_SEP=';' ;;
  *)           IS_MSYS=0; CP_SEP=':' ;;
esac
is_msys() { [ "$IS_MSYS" = 1 ]; }
native_path() { if is_msys; then cygpath -m -- "$1"; else printf '%s\n' "$1"; fi; }

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
  # under Git Bash accept C:/eclipse, C:\eclipse or /c/eclipse — normalize to
  # the MSYS form so all bash-side logic sees exactly one shape
  if is_msys; then candidate=$(cygpath -u -- "$candidate"); fi
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

# percent_decode <s> — undo URI percent-encoding (%20 -> space, %C3%A9 -> é).
# bundles.info stores file: locations as URIs, so a pool under "Program Files"
# arrives as Program%20Files. Only %XX escapes are decoded (no '+' handling —
# that is form encoding, not path encoding).
percent_decode() {
  local s=$1 out="" byte
  # Strict: only %XX with two hex digits is an escape; anything else stays
  # verbatim (no printf warnings on a stray '%'). Consumed from the right so
  # multi-byte sequences (%C3%A9) come out in order; printf's \xHH yields the
  # raw byte, so UTF-8 survives untouched regardless of locale.
  while [[ $s =~ ^(.*)%([0-9A-Fa-f][0-9A-Fa-f])(.*)$ ]]; do
    printf -v byte '%b' "\\x${BASH_REMATCH[2]}"
    out="$byte${BASH_REMATCH[3]}$out"
    s=${BASH_REMATCH[1]}
  done
  printf '%s\n' "$s$out"
}

# resolve_bundle_location <loc> — bundles.info column 3 to an absolute path in
# bash-side form (MSYS /c/... under Git Bash, POSIX elsewhere). Three shapes
# occur in the wild (issue #5/#6 PRs):
#   plugins/foo.jar                            relative to the install area
#   /opt/eclipse/plugins/foo.jar               absolute POSIX path
#   file:/C:/Users/x/.p2/pool/plugins/foo.jar  file: URI — installs made by the
#   file:/home/x/.p2/pool/plugins/foo.jar      Eclipse Installer (Oomph) keep
#                                              bundles in a shared p2 pool
#                                              outside the install area
# The URI form is percent-encoded and may carry a Windows drive letter behind
# the URI's leading slash (/C:/...) — strip that slash and convert to the MSYS
# form so bash-side tools (cp, unzip, patch) can use the path. classpath_for
# has an awk twin of this logic; keep the two in step.
resolve_bundle_location() {
  local loc=$1
  case "$loc" in
    file:*)
      loc=${loc#file:}
      loc=$(percent_decode "$loc")
      case "$loc" in ///*) loc=${loc#//} ;; esac        # file:///C:/x -> /C:/x (keep //host/share)
      case "$loc" in /[A-Za-z]:*) loc=${loc#/} ;; esac  # /C:/x -> C:/x
      if is_msys; then loc=$(cygpath -u -- "$loc"); fi
      printf '%s\n' "$loc" ;;
    /*) printf '%s\n' "$loc" ;;
    *)  printf '%s/%s\n' "$ECLIPSE_HOME" "$loc" ;;
  esac
}

# bundle_jar <bsn> — absolute path of the ACTIVE jar for a bundle. bundles.info
# is the source of truth: installs updated in place keep stale older jars on disk.
bundle_jar() {
  local rel
  rel=$(bundle_info_line "$1" | cut -d, -f3) || return 1
  resolve_bundle_location "$rel"
}

# bundle_in_pool <bsn> — true when the active jar lives outside the install
# area (shared p2 pool): patching it affects every install that shares the pool
bundle_in_pool() {
  local jar
  jar=$(bundle_jar "$1") || return 1
  case "$jar" in "$ECLIPSE_HOME"/*) return 1 ;; *) return 0 ;; esac
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
  java -jar "$(native_path "$VF_JAR")" "${VF_FLAGS[@]}" \
    "$(native_path "$jar")" "$(native_path "$out")/" > /dev/null 2>&1 \
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
  # Entries in native form with the platform separator — this string is consumed
  # by javac (a native tool under Git Bash). One awk pass over the 500-1000
  # entries, deliberately with no per-entry subprocess (a cygpath per entry
  # costs tens of seconds on Windows). Same three location shapes as
  # resolve_bundle_location, reaching native form without cygpath:
  #   relative          -> native install prefix + "/" + entry
  #   file:/C:/...      -> C:/... (native once the URI's extra slash goes)
  #   /abs or file:/abs -> only produced by POSIX p2, where native == POSIX
  # LC_ALL=C so sprintf("%c") emits raw bytes while percent-decoding — UTF-8
  # sequences (%C3%A9) must come out as the original bytes, not re-encoded.
  local first ecl
  first=$(native_path "$1")
  ecl=$(native_path "$ECLIPSE_HOME")
  {
    printf '%s' "$first"
    LC_ALL=C awk -F, -v ecl="$ecl" -v sep="$CP_SEP" '
      BEGIN { for (i = 0; i < 16; i++) { hex[sprintf("%x", i)] = i; hex[sprintf("%X", i)] = i } }
      function decode(s,    out, i, h1, h2) {
        out = ""
        while ((i = index(s, "%")) > 0) {
          h1 = substr(s, i + 1, 1); h2 = substr(s, i + 2, 1)
          if ((h1 in hex) && (h2 in hex)) {
            out = out substr(s, 1, i - 1) sprintf("%c", hex[h1] * 16 + hex[h2])
            s = substr(s, i + 3)
          } else {
            out = out substr(s, 1, i)
            s = substr(s, i + 1)
          }
        }
        return out s
      }
      !/^#/ && $3 ~ /\.jar$/ {
        p = $3
        if (p ~ /^file:/) {
          sub(/^file:/, "", p)
          p = decode(p)
          sub(/^\/\/\//, "/", p)
          if (p ~ /^\/[A-Za-z]:/) p = substr(p, 2)
        } else if (p !~ /^\//) {
          p = ecl "/" p
        }
        printf "%s%s", sep, p
      }' "$BUNDLES_INFO"
  }
}

# compile_unit <bsn> <src-subdir> <expected-count> "<sources>" ["<resources>"]
compile_unit() {
  local bsn=$1 subdir=$2 expected=$3 sources=$4
  local srcroot="$WORK_DIR/$bsn/src" out="$BUILD_DIR/classes/$bsn" cp produced s
  local names=()
  # (read -ra on an empty string yields no elements, but guard anyway so a
  # whitespace-only field can never masquerade as a source file)
  [ -n "${sources// /}" ] && read -ra names <<< "$sources"
  if [ ${#names[@]} -eq 0 ]; then
    log "nothing to compile for $bsn (resource-only target)"
    return 0
  fi
  [ -d "$srcroot/$subdir" ] || die "missing sources for $bsn — run 'setup' (and 'apply') first"
  local files=()
  for s in "${names[@]}"; do files+=("$srcroot/$subdir/$s"); done
  rm -rf "$out"
  mkdir -p "$out"
  cp=$(classpath_for "$(backup_jar_path "$bsn")")
  # The classpath spans ~1000 active bundle jars (~128 KiB), which exceeds the
  # OS single-argument limit (Linux MAX_ARG_STRLEN, 128 KiB) once ECLIPSE_HOME's
  # absolute prefix is applied to each entry — so javac dies with "Argument list
  # too long". Feed it via an @argfile instead. Paths are double-quoted to
  # tolerate spaces; they use forward slashes, so backslash-escaping never bites.
  # Everything written INTO the argfile must be native form: MSYS converts argv
  # of native executables but never argfile contents (issue #3).
  local argfile="$BUILD_DIR/$bsn.javac.args"
  {
    printf -- '--release 8 -nowarn -encoding UTF-8\n'
    printf -- '-classpath "%s"\n' "$cp"
    printf -- '-d "%s"\n' "$(native_path "$out")"
    for s in "${files[@]}"; do printf -- '"%s"\n' "$(native_path "$s")"; done
  } > "$argfile"
  if ! javac "@$(native_path "$argfile")"; then
    rm -rf "$out"   # never leave a half-built class dir for pack to trip over
    die "compilation failed for $bsn (did 'apply' succeed? is the Eclipse install the version the patches target?)"
  fi
  produced=$(find "$out" -name '*.class' | wc -l)
  [ "$produced" -eq "$expected" ] || die "$bsn produced $produced class files, expected $expected — decompiler or source drift"
  log "compiled $bsn: $produced class files"
}

# pack_bundle <bsn> <class-subdir> <expected> "<sources>" "<resources>" —
# repack the pristine jar with the patched classes (when the target has
# sources) and/or the patched resource files from work/<bsn>/.
# The vendor signature must be stripped (edited entries would fail verification)
# and MANIFEST.MF reduced to its main section, because per-entry digest sections
# would reference the old bytes. NB: 'jar --update --manifest' MERGES with an
# existing in-jar manifest, so the old manifest is deleted from the zip first.
pack_bundle() {
  local bsn=$1 subdir=$2 sources=$4 resources=$5
  local pristine out manifest classes entry r
  local names=() res=()
  [ -n "${sources// /}" ] && read -ra names <<< "$sources"
  [ -n "${resources// /}" ] && read -ra res <<< "$resources"
  pristine=$(backup_jar_path "$bsn")
  [ -f "$pristine" ] || die "no pristine backup for $bsn — run 'setup' first"
  out="$BUILD_DIR/$bsn.jar"
  manifest="$BUILD_DIR/$bsn.MF"
  classes="$BUILD_DIR/classes/$bsn"
  if [ ${#names[@]} -gt 0 ]; then
    # an empty class dir would hand jar an unexpanded glob and errexit the
    # script half-way through the repack — demand real class files
    compgen -G "$classes/$subdir/*.class" >/dev/null || die "no compiled classes for $bsn — run 'build' first"
  fi
  for r in "${res[@]}"; do
    [ -f "$WORK_DIR/$bsn/$r" ] || die "missing resource $r in work/$bsn — run 'setup' and 'apply' first"
  done
  mkdir -p "$BUILD_DIR"
  cp "$pristine" "$out"
  # main section only, minus its terminating blank line, so the appended marker
  # stays inside the main section; no timestamps — repacks must be deterministic
  unzip -p "$out" META-INF/MANIFEST.MF | sed -n '/^\r*$/q;p' > "$manifest"
  printf '%s: true\r\n' "$REVSTYLE_MARKER" >> "$manifest"
  # suffix matches, not the CODETOGE literals: unsigned pristine jars have no
  # signature entries (fine), but MANIFEST.MF must exist — the helper dies when
  # it doesn't (a corrupt jar). Java helper, not zip -d: stock Git Bash has no
  # zip(1), and the JDK is already a hard requirement.
  java "$(native_path "$REPO_DIR/lib/StripSignatures.java")" "$(native_path "$out")" \
    || die "signature strip failed for $bsn"
  jar --update --file "$(native_path "$out")" --manifest "$(native_path "$manifest")"
  local pin=(META-INF/MANIFEST.MF) f
  if [ ${#names[@]} -gt 0 ]; then
    (cd "$classes" && jar --update --file "$(native_path "$out")" "$subdir"/*.class)
    for f in "$classes/$subdir"/*.class; do pin+=("$subdir/$(basename "$f")"); done
  fi
  if [ ${#res[@]} -gt 0 ]; then
    (cd "$WORK_DIR/$bsn" && jar --update --file "$(native_path "$out")" "${res[@]}")
    pin+=("${res[@]}")
  fi
  # jar stamps the manifest entry with "now" and class/resource entries with
  # file mtimes — pin exactly the entries we rewrote so repacks carry no
  # wall-clock (see PACK_MTIME); untouched pristine entries keep their headers
  java -Duser.timezone=UTC "$(native_path "$REPO_DIR/lib/PinEntryTimes.java")" \
    "$(native_path "$out")" "$PACK_MTIME" "${pin[@]}" \
    || die "timestamp pinning failed for $bsn"
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
  # Best-effort. Git Bash: the install is always a Windows one and stock Git
  # Bash has no pgrep, so tasklist is authoritative. MSYS mangles /FI-style
  # args into paths — suppress conversion for this one call.
  if is_msys; then
    MSYS2_ARG_CONV_EXCL='*' tasklist.exe /FI "IMAGENAME eq eclipse.exe" /NH 2>/dev/null \
      | grep -i eclipse.exe >/dev/null && return 0
    return 1
  fi
  # WSL: ask Windows, but only when the target install is a
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
