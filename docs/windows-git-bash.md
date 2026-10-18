# Git Bash (MSYS) support

Issue [#3](https://github.com/Shadows-of-Fire/revstyle/issues/3): on Windows
11 + Git Bash + a native Windows JDK, `build` died with

```
Fehler: Datei nicht gefunden: \d\revstyle\work\...\SquareTabRenderer.java
```

even though the file existed at `D:\revstyle\work\...`. The README had always
promised Git Bash support; in truth no stage past `apply` had ever worked
there. This page records the empirically verified platform rules the port is
built on, so the next person doesn't have to rediscover them.

## The MSYS path-conversion rules that matter

Verified against Git for Windows (MSYS2 runtime) and Adoptium JDKs:

1. **MSYS converts POSIX paths on the argv of native executables only.**
   `javac /d/foo/Bar.java` works — bash rewrites the argument to
   `D:\foo\Bar.java` before `javac.exe` sees it. But paths written *inside* a
   javac `@argfile` are file contents, get no conversion, and a Windows JVM
   normalizes `/d/foo` to the meaningless `\d\foo` → *file not found*. Since
   `compile_unit` must use an argfile (Linux `MAX_ARG_STRLEN` — see
   CLAUDE.md), argfile contents must be written in native form.
2. **A drive colon anywhere suppresses classpath-list conversion.** MSYS can
   convert `:`-joined POSIX path lists to `;`-joined Windows lists, but any
   `C:/…` entry makes the heuristic bail on the whole argument. And Windows
   `javac` splits path lists on `;` regardless — so the pre-argfile pipeline
   never resolved a classpath under Git Bash either (symptom: a wall of
   `package … does not exist`).
3. **`cygpath -m` output (`C:/mixed` form) is the one shape Windows JVM tools
   accept everywhere** — argv, argfile contents, `-classpath` entries — and it
   never contains backslashes, so double-quoting in argfiles stays trivial
   even for `C:/Program Files/...` paths.
4. **MSYS mangles Windows-style flags too**: `tasklist /FI "..."` turns `/FI`
   into a path. Prefix such calls with `MSYS2_ARG_CONV_EXCL='*'`.

Hence the shim in `lib/common.sh`: `is_msys`, `native_path()` (`cygpath -m`
on MSYS, identity elsewhere), `CP_SEP` (`;` on MSYS, `:` elsewhere) —
applied *only* at the native-tool boundaries (VineFlower's `java -jar`,
`javac`, `jar`); bash-side tools (`unzip`, `patch`, `cp`, `find`) keep MSYS
paths. `resolve_eclipse` normalizes `ECLIPSE_HOME` early with `cygpath -u`,
so `C:/eclipse`, `C:\eclipse`, and `/c/eclipse` are all accepted.

## Tooling gaps in stock Git for Windows

`zip` and `pgrep`/`pkill` do not ship with Git for Windows (and there is no
package manager to add them). Consequences:

- `pack_bundle`'s signature strip is `lib/StripSignatures.java` (single-file
  source launch — the JDK is already a hard requirement) on **all** platforms,
  not `zip -d`. Same semantics: deletes `META-INF/*.SF/.RSA/.DSA` and
  `MANIFEST.MF`, and treats a missing `MANIFEST.MF` as the error (the
  always-present manifest is what anchored the old `zip -d` glob trick, too).
- `eclipse_running` (and the CI harness's process probes) use
  `tasklist.exe`/`taskkill.exe` on MSYS.

Present and relied upon: `unzip`, `curl`, `sha256sum`, `sha512sum`, `awk`,
`sed`, `od`, `realpath`, `mktemp`, `timeout`, `tar`, `cygpath`.

## Deterministic repacks

While porting, the pack stage turned out to be wall-clock-stamped:
`jar --update` writes the manifest entry with the current time and class
entries with their build mtimes, so no two packs were ever byte-identical —
quietly contradicting the repo's reproducibility bar. `pack_bundle` now
pins every entry it rewrites to `PACK_MTIME` (the DevStyle release stamp)
via `lib/PinEntryTimes.java`, run with `-Duser.timezone=UTC` because zip DOS
times are local-time encoded. Verified: pack-twice AND rebuild-then-pack
produce byte-identical jars; CI asserts the former on every leg.

## Line endings

`.gitattributes` pins the repo to LF (`* text=auto eol=lf`, `*.patch -text`).
Windows checkouts default to `core.autocrlf=true`; without the pin, the shell
scripts break on `\r` and `patch -p1` context lines stop matching the
LF work-tree files. VineFlower 1.12.0 emits LF on all platforms
(`--new-line-separator` defaults to true), so decompiled sources and patch
context stay consistent — verified, no flag change needed.

## Out of scope

`find_user_config_area` hash-matching under Git Bash: Equinox hashes the
native `C:\…` install path, while bash holds the MSYS form, so the
`~/.eclipse` split-install detection would miss. Native Windows installs
almost always have a writable `configuration/` (the split layout is a distro-
package thing), so this path is rarely taken; pass `--config <dir>` if you
ever hit it. Cheap future improvement: also try
`java_str_hash "$(cygpath -w "$ECLIPSE_HOME")"` as a candidate.

## Shared p2 pool installs

Installs created by the Eclipse Installer keep their bundles in a shared pool
and reference them in `bundles.info` as percent-encoded URIs such as
`file:/C:/Users/<you>/.p2/pool/plugins/….jar` (the regression from the
original PR #5/#6 reports). `resolve_bundle_location` strips the URI's extra
leading slash, percent-decodes (`Program%20Files`), and runs the result
through `cygpath -u` so bash-side tools see `/c/Users/…`. `classpath_for`
needs no `cygpath` at all: `C:/…` after the strip is already the mixed form
javac accepts, which keeps the 500–1000-entry classpath build free of
per-entry processes. `ci/test-bundle-locations.sh` checks all shapes, and the
windows-latest CI leg runs it under real Git Bash.

## Troubleshooting

- **`deploy` fails copying jars** → Eclipse is running and Windows holds the
  jar locks. `eclipse_running` should have refused; close Eclipse (all
  instances — check `tasklist | grep -i eclipse`).
- **`javac`/`java` not found** → put a Windows JDK on PATH:
  `export PATH="/c/Program Files/Eclipse Adoptium/<jdk>/bin:$PATH"`.
- **Everything fails weirdly on a fresh clone** → check the clone wasn't made
  by a git that ignores `.gitattributes` overrides (`git config core.eol`,
  stray `core.autocrlf=input` overrides); `file revstyle.sh` should NOT say
  CRLF.
