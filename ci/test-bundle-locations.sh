#!/usr/bin/env bash
# ci/test-bundle-locations.sh — unit test for the bundles.info location shapes
# lib/common.sh must resolve (bundle_jar / classpath_for): install-relative,
# absolute, and the file: URIs that Eclipse-Installer (Oomph) shared-pool
# installs write, with and without a Windows drive letter, percent-encoded.
#
# Needs no Eclipse: builds a synthetic install under a temp dir. Runs on both
# CI legs — on windows-latest (Git Bash) with real cygpath, so the MSYS
# conversions are exercised for real, and on POSIX where native == POSIX.
#
#   bash ci/test-bundle-locations.sh        exit 0 = all shapes resolve as expected

set -euo pipefail
cd "$(dirname "$0")/.."
unset ECLIPSE_HOME
# shellcheck source=lib/common.sh
. lib/common.sh

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
ECLIPSE_HOME="$T/eclipse"
CONFIG_AREA="$ECLIPSE_HOME/configuration"
BUNDLES_INFO="$CONFIG_AREA/org.eclipse.equinox.simpleconfigurator/bundles.info"
mkdir -p "$ECLIPSE_HOME/plugins" "$(dirname "$BUNDLES_INFO")"
cat > "$BUNDLES_INFO" <<'INFO'
#encoding=UTF-8
#version=1
a.relative,1.0.0,plugins/a.relative_1.0.0.jar,4,false
b.absolute,1.0.0,/opt/pool/plugins/b.absolute_1.0.0.jar,4,false
c.fileposix,1.0.0,file:/home/u/.p2/pool/plugins/c.fileposix_1.0.0.jar,4,false
d.filewin,1.0.0,file:/C:/Users/u/.p2/pool/plugins/d.filewin_1.0.0.jar,4,false
e.exploded,1.0.0,plugins/e.exploded_1.0.0/,4,false
f.space,1.0.0,file:/C:/Program%20Files/pool/plugins/f.space_1.0.0.jar,4,false
g.utf8,1.0.0,file:/home/u/caf%C3%A9/plugins/g.utf8_1.0.0.jar,4,false
h.tripleslash,1.0.0,file:///C:/pool/plugins/h.tripleslash_1.0.0.jar,4,false
INFO

fail=0
check() {  # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then
    printf 'ok   %-28s %s\n' "$1" "$3"
  else
    printf 'FAIL %-28s expected [%s]\n%-33s got      [%s]\n' "$1" "$2" "" "$3"
    fail=1
  fi
}
# bash-side expectations: MSYS form under Git Bash (what cygpath -u yields),
# plain POSIX elsewhere
bashside() { if is_msys; then cygpath -u -- "$1"; else printf '%s\n' "$1"; fi; }
ecl_native=$(native_path "$ECLIPSE_HOME")

echo "== bundle_jar =="
check "relative"        "$ECLIPSE_HOME/plugins/a.relative_1.0.0.jar"                 "$(bundle_jar a.relative)"
check "absolute"        "/opt/pool/plugins/b.absolute_1.0.0.jar"                     "$(bundle_jar b.absolute)"
check "file: posix"     "/home/u/.p2/pool/plugins/c.fileposix_1.0.0.jar"             "$(bundle_jar c.fileposix)"
check "file: drive"     "$(bashside 'C:/Users/u/.p2/pool/plugins/d.filewin_1.0.0.jar')" "$(bundle_jar d.filewin)"
check "file: %20"       "$(bashside 'C:/Program Files/pool/plugins/f.space_1.0.0.jar')" "$(bundle_jar f.space)"
check "file: utf-8"     "/home/u/café/plugins/g.utf8_1.0.0.jar"                      "$(bundle_jar g.utf8)"
check "file: ///drive"  "$(bashside 'C:/pool/plugins/h.tripleslash_1.0.0.jar')"      "$(bundle_jar h.tripleslash)"
check "missing bsn rc"  "1" "$(bundle_jar nope.missing >/dev/null 2>&1; echo $?)"

echo "== bundle_in_pool =="
check "relative not pool" "1" "$(bundle_in_pool a.relative; echo $?)"
check "file: is pool"     "0" "$(bundle_in_pool d.filewin; echo $?)"

echo "== classpath_for (native form, joined with '$CP_SEP') =="
# Compare the whole string: entries may legitimately contain ':' (C:/...), so
# splitting on the POSIX separator would mangle them. Pristine jar first, the
# exploded bundle absent, every jar in bundles.info order.
expected_cp=$(native_path /pristine/x.jar)
for e in "$ecl_native/plugins/a.relative_1.0.0.jar" \
         "/opt/pool/plugins/b.absolute_1.0.0.jar" \
         "/home/u/.p2/pool/plugins/c.fileposix_1.0.0.jar" \
         "C:/Users/u/.p2/pool/plugins/d.filewin_1.0.0.jar" \
         "C:/Program Files/pool/plugins/f.space_1.0.0.jar" \
         "/home/u/café/plugins/g.utf8_1.0.0.jar" \
         "C:/pool/plugins/h.tripleslash_1.0.0.jar"; do
  expected_cp="$expected_cp$CP_SEP$e"
done
check "full classpath"  "$expected_cp" "$(classpath_for /pristine/x.jar)"

echo "== percent_decode =="
check "no escapes"      "plain/path.jar"   "$(percent_decode plain/path.jar)"
check "space"           "a b"              "$(percent_decode 'a%20b')"
check "backslash kept"  'a\b%zz'           "$(percent_decode 'a\b%zz')"

[ "$fail" = 0 ] && echo "all bundle-location checks passed" || { echo "bundle-location checks FAILED"; exit 1; }
