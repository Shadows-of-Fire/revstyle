# Agent instructions — maintaining revstyle when DevStyle breaks again

This repo repairs the abandoned DevStyle plugin (final release
2025.2.0.202509301431 — there will never be another) on modern Eclipse by
patching the user's own installed jars. Eclipse ships quarterly (2026-12/4.42
is next); DevStyle reflects into SWT/Equinox internals and weaves bytecode
into e4, so expect a new break roughly every release. This file is the
playbook for that event.

## Hard invariants

- **VineFlower only** for all decompilation (project mandate — no CFR, Procyon,
  Fernflower, or javap-based source reconstruction; `javap -p` for *signature
  listing* is fine). Pinned in `lib/common.sh` (`VF_VERSION`/`VF_SHA256`).
  If you bump VineFlower, **regenerate every patch** whose context comes from
  decompiled output and update the SHA-256.
- **No Genuitec bytes in git.** Never commit jars, `.class` files, `work/`,
  `backups/`, or bulk decompiled source. Patches may contain only the few
  context lines `patch(1)` needs. Audit before committing:
  `git ls-files | grep -iE '\.(jar|class)$|^work/|^backups/|^tools/'` must be empty.
- `DEVSTYLE_VERSION` never changes. New breakage means a new *Eclipse*, not a
  new DevStyle.

## Diagnosis playbook (in order of likelihood)

1. **Read the workspace log** (`<workspace>/.metadata/.log`), not
   `configuration/*.log` (those only hold launcher banners). Grep for
   `genuitec|NullPointerException|NoSuchField|NoSuchMethod|LinkageError|Unhandled event loop`.
   A loud repeated stack trace = reflection into a removed/renamed SWT member.
   **A silent log does not mean no bug** — geometry/DPI bugs log nothing and
   need a human's eyes (ask which dialog/widget misbehaves and at what display
   scale).
2. **Diff the SWT (or other platform bundle) versions.** After an in-place
   Eclipse upgrade the previous bundle jars usually survive in `plugins/` —
   `configuration/org.eclipse.equinox.simpleconfigurator/bundles.info` is the
   authority on which are active. On **read-only installs** (distro packages)
   that authority lives in the per-user area
   `~/.eclipse/<product>_<ver>_<hash>_<os_ws_arch>/configuration/` — the hash
   is Java `String.hashCode` of the absolute install path (`java_str_hash` in
   `lib/common.sh`); user-installed bundles sit in that area's `plugins/` and
   are referenced by `../..`-style paths that resolve against the install
   root. `resolve_eclipse` handles all of this; `--config` overrides. Compare members with `javap -p` first, then
   VineFlower-decompile the specific classes from both jars and diff
   (pre-create package dirs; VineFlower's `--only` saver doesn't mkdir).
   **Sweep first, then dig**: `python3 -I lib/refsweep.py <extracted DevStyle
   bundles> <old plugins/> <new plugins/> [--old <prev win32 SWT jar>]` lists
   (a) every platform class DevStyle's constant pools reference (direct refs,
   descriptors, *and* string constants — the ASM weavers name their targets
   in strings) that exists in the old release and not the new one, and
   (b) every platform **member** DevStyle links against directly *or emits
   from a weaver* (the bytecode is walked and the strings fed to
   `visitMethodInsn`/`visitFieldInsn` recovered) that resolves in the old
   release and not the new one. Each hit carries the weaver's gate from
   `plugin.xml` (os, SWT version range, woven class still present), so
   inactive weavers are labelled, not alarmed. On 4.41 pass (a) found the
   four Linux-visible breaks and pass (b) the Windows one (issue #7, both
   rounds). **Feed it a Windows install's bundle set**: three DevStyle
   bundles (`theming.base.win`, `theming.scrollbar.win`,
   `theming.elevation.win32`) and every `os="win32"` weaver never exist on
   a Linux install, and from Linux pass the previous release's win32 SWT
   fragment (Maven Central) as `--old` so win32 classes resolve against
   win32. Members reached by *reflection* are the one thing it cannot see —
   those still need `javap -p` diffs.
3. **Known DevStyle failure modes**, ranked by past incidents:
   - Reflection into private SWT fields/methods that got removed
     (4.37 `DPIUtil.autoScaleDown`, 4.40 `CTabFolderRenderer` curve fields).
     Fix pattern: null-guard, resolve-once, no-op when absent.
   - `sun.misc.Unsafe.allocateInstance` skipping **constructors and field
     initializers** on adapter widgets (`ScrollableAdapterFactory`,
     `TreeAdapter`/`TableAdapter`/`StyledTextAdapter`). Any new
     initializer-set field in `Widget`/`Control`/`Scrollable` silently
     defaults to 0/null. Diff field initializers between SWT versions when an
     adapter misbehaves with no exception. Fix pattern: copy the field from
     the adapted widget in `createAdapter` before `createWidget` (see the
     `autoscalingMode` patch).
   - **ASM weavers that hardcode platform class names in the bytecode they
     emit** (`com.genuitec.eclipse.patches.extensions` class-weavers in
     `startup`, `theming.core`; class-replacements in `theming.epl`). A removed
     superclass surfaces as `NoClassDefFoundError` at the *woven* class's first
     use, deep inside e4 and nowhere near DevStyle code (4.41
     `IgnoreCSSClassPatch` → `ThemeEngineManager.getCSSSWTEngine`). Fix
     pattern: derive names from the `ClassNode` (`cw.superName`). A weaver whose
     `woven-class` itself vanished (4.41 `CSSEngineFixer` on
     `AbstractCSSEngine`) is silently inert — lost behavior, no exception.
   - **e4 CSS engine internals** — the 4.41 rewrite replaced the SAC DOM with
     an in-house parser. DevStyle serves its CSS through its own `devstyle:`
     URL scheme (color substitution) and relied on a weaver to null-guard
     relative `@import` resolution; the stock fallback asks the
     `IResourceLocator`s and does `new URL(null)` when none answers. Fixed
     declaratively with an `osgiresourcelocator` in `theming.css`
     (docs/css-import-locator.md). Any future "theme half applied" with
     `MalformedURLException ... "spec" is null` is this family.
     The 4.41 parser is also **strict**, and the `devstyle:` generator
     **drops whole marker lines** (`/*LIGHTONLY*/` etc.) before parsing — a
     marker on a line with a brace unbalances the served text and a
     `CssParseException` from the startup restore kills Eclipse. Never judge
     DevStyle CSS by the jar files: run `lib/CssParseProbe.java` (emulates the
     dropping per theme/OS combo, parses with the install's real engine) over
     `work/**/css` for all seven combos before shipping a CSS resource patch
     (docs/css-parser-strictness.md).
   - **Weavers that re-emit whole SWT methods** (`FixTree202409`,
     `FixTable202409`, win32, SWT ≥ 3.127): not patches but complete
     ASM-ified copies of `Tree.CDDS_ITEMPOSTPAINT`/`Table.sendEraseItemEvent`
     from the 2024-09 SWT. Any member that copy calls and a later SWT
     removes (4.41: `OS.IsAppThemed()`) surfaces as `NoSuchMethodError`
     *from inside SWT's own class* on the first tree item paint — "Application
     error" and a hung `eclipse.exe` when the workspace already shows a
     project, an "Unhandled event loop" flood when it does not. Looks like
     workspace corruption; isn't. Fix pattern: do NOT decompile the weaver
     (its `weave` method needs a 24 GB heap in VineFlower; `setup` writes a
     stub and moves on). Subclass it, call `super.weave(cw)`, post-process
     the `MethodNode` it left in `cw.methods` (swap the dead call for the
     constant the new SWT assumes), and re-point the `class-weaver` entry in
     `plugin.xml` at the subclass — two new sources plus a resource in one
     target (docs/win32-tree-weaver.md). Gate the rewrite on a reflective
     probe of the running SWT so older releases are woven unchanged.
   - **Crashes that depend on workspace content** are rendering-path breaks:
     the code runs when a widget paints, so an empty workspace, a headless
     boot or a Welcome page covering the perspective never reaches it. The
     e2e seeds a project into both boot workspaces (`ci/seed/`) for that
     reason; reproduce locally with a workspace that has one project and the
     Package Explorer visible, on **Windows** for win32 weavers.
   - **Static initializers touching removed platform classes** (4.41
     `PlatformUtil` → `PluginVersionIdentifier`): the whole class fails to
     load for every caller, however unrelated the method they wanted. Fix
     pattern: drop the member; check for callers with a constant-pool grep
     across all bundles first.
   - `com.genuitec.eclipse.patches` (start-level 2 weaving engine): couples to
     Equinox internals (`HookRegistry`, `ModuleClassLoader`, `ClasspathManager`)
     and ASM 5 — suspect it for *startup* failures rather than rendering ones.
   - e4 CSS internals (`org.eclipse.e4.ui.css.swt.internal.theme`) — theming
     registration failures.
4. **Reproduce outside the IDE when the bug is geometric/silent** — write a
   standalone SWT probe harness. Pattern: harness on the real plugin jar +
   both SWT versions, print bounds/zoom/scrollbar numbers, bisect hypotheses
   by replicating `createAdapter` steps manually. Gotchas that cost time:
   unsigned copies of signed platform jars (package sealing), extract
   `replacements/ScrollBarAdapter.class` to the classpath, run at >100%
   display scale, `FlatScrollBar.notifyListeners(int)` (1-arg) to simulate
   drags.

## Making a new fix

0. Before touching code, run the member-level sweep (step 2 above) against the
   new install — once on the pristine bundles to enumerate the breakage, and
   again on the patched install when you think you are done (expect
   `0 active finding(s)`). CI runs the one-install form on every leg
   (`--single --baseline ci/refsweep-baseline.txt --fail`, tag
   `[sweep-failed]`); add to the baseline only members proven unresolved on
   the last *good* release too, never to quiet the release that just broke.

1. `./revstyle.sh setup` (add `--all` when the broken bundle isn't already a
   target) → sources in `work/<bundle>/src/`. Bundles that embed real sources
   (the codeaffine ones: `theming.scrollbar`, `theming.base`) get them in
   `src/` with VineFlower output in `src-vf/` — always patch the embedded
   sources, never the decompiled twin.
2. Edit `work/` sources minimally (match existing style; guard, don't
   restructure). Keep fixes tolerant of older SWT (best-effort reflection).
3. If a new bundle joins the pipeline: add one line to `PATCH_TARGETS` in
   `lib/common.sh` (`<bsn>|<package dir>|<expected class count>|<sources>|<resources>`);
   `setup`/`apply`/`build`/`pack`/`deploy`/`restore`/`status` and the CI
   assertions all iterate it. Remember: recompiling an outer class
   regenerates ALL its nested classes — the expected count is the jar's full
   `Outer*.class` entry set, and pack replaces them together. A fix that
   lives in bundle metadata rather than code (4.41 `theming.css` plugin.xml)
   is a **resource target**: leave sources empty, list the jar-relative
   files; `apply` patches them in `work/<bsn>/` and `pack` copies them in.
   Users with an older `work/` must re-run `setup` (`apply` tells them).
4. Regenerate patches from a **fresh pristine** work tree:
   re-run `setup` into a clean `work/`, then
   `diff -u --label a/<rel> --label b/<rel> <pristine> <patched>` per file,
   concatenated under a prose header (what/why/target/context-source/docs
   link). Patches apply with `patch -p1 -d work/`. Number them `000N-…`.
5. `apply → build → pack → deploy`, launch Eclipse once with `-clean`
   against a **throwaway workspace first**, grep its log, then the real one.
   Iterate — fixing the first crash often unmasks the next missing member.
6. Add `docs/<bug>.md` (symptom, verbatim stack trace, root cause with the
   SWT diff evidence, fix rationale) and a README table row. If a probe
   harness was needed, document it in the bug's docs page.

## Pipeline gotchas (all learned the hard way)

- `jar --update --manifest` **merges** with an in-jar manifest — `zip -d` the
  old `META-INF/MANIFEST.MF` (and any signature files `META-INF/*.SF/.RSA/.DSA`)
  first; keep only the manifest main section (file is CRLF). Delete via globs
  anchored by the always-present `MANIFEST.MF` — literal signature names make
  `zip -d` exit 12 on unsigned jars.
- Scripts run under `set -euo pipefail`: never `| grep -q` (early exit
  SIGPIPEs the producer → bogus pipeline status). `grep pat >/dev/null`.
- Pristine vs patched jars are told apart by the `Revstyle-Patched: true`
  manifest marker `pack` stamps in — **never** by signature presence: fresh
  installs can legitimately ship these jars unsigned (issue #1). `pack` must
  always start from the pristine backup, never from `plugins/`.
- Same filename + `Bundle-Version` on deploy keeps `bundles.info`/p2 happy;
  `artifacts.xml` stores no checksums for these artifacts.
- **`bundles.info` column 3 has three shapes**: install-relative
  `plugins/x.jar` (classic), absolute POSIX, and percent-encoded `file:` URIs
  into a shared p2 pool (Eclipse Installer/Oomph layouts —
  `file:/C:/Users/…/.p2/pool/plugins/x.jar` on Windows; PRs #5/#6).
  `resolve_bundle_location` is the single bash-side resolver (drive-letter
  slash stripped, `cygpath -u` on MSYS); `classpath_for` carries a
  deliberately **subprocess-free awk twin** of the same rules — one `cygpath`
  per entry would cost tens of seconds on Windows, and `C:/…` is already the
  native form javac wants. Change both together and run
  `ci/test-bundle-locations.sh` (also the first stage of `ci/e2e.sh`).
- Always `-clean` after swapping a jar so Equinox drops cached bundle
  *metadata*. It does not cache class bytes and DevStyle's weaving engine
  (`com.genuitec.eclipse.patches`) keeps no on-disk cache: a launch without
  `-clean` still ran the patched classes on 4.41. So a symptom that
  survives `deploy` is a bug, not a stale cache — read the log.
- A failed `Application error` start on Windows leaves `eclipse.exe` hung in
  shutdown holding the workspace lock (`.metadata/.lock_info` has its PID).
  `deploy` refuses while it lives; kill that PID (`taskkill /PID n /F`),
  not every Eclipse, and never delete `.metadata` to "repair" the workspace.
- The e2e boots run against workspaces seeded with one project by a
  headless `IApplication` built from `ci/seed/` into `dropins/` on the
  stock Eclipse before DevStyle is installed (`-application
  revstyle.ci.seed.seed`; the id is plugin id + extension id). Keep
  `showIntro=false` in the seeded prefs or the maximized Welcome hides the
  Package Explorer and no tree is painted.
- `eclipse_running` uses `pgrep -x`; a `-f` substring match catches your own
  command line. It asks Windows (`tasklist.exe`) only when `ECLIPSE_HOME` is
  under `/mnt/*` — a Windows Eclipse can't hold a Linux install's files.
- **Never put the bundle classpath on javac's command line.** A modern Eclipse
  has ~1000 active bundles, so `classpath_for` builds a single `-cp` string of
  ~128 KiB — past Linux's per-argument cap (`MAX_ARG_STRLEN`, 131072 bytes),
  and the `/mnt/c/...` prefix under WSL2 tips it over even when the `C:/...`
  measurement looks safe. Symptom: `javac: Argument list too long`, unrelated
  to the (tiny) source-file list. `compile_unit` writes an `@argfile` instead;
  keep it that way. Quote paths in the argfile (spaces in `ECLIPSE_HOME`) and
  keep them forward-slashed so backslash-escaping never bites.
- **Git Bash (MSYS) rules** (issue #3): MSYS auto-converts POSIX paths on the
  *argv* of native executables but never inside `@argfile` contents, and a
  drive colon anywhere in a `:`-joined classpath suppresses list conversion
  entirely. So never rely on auto-conversion — every path handed to a native
  JVM tool goes through `native_path` (`cygpath -m` → `C:/mixed`, the one form
  Windows JVM tools accept on argv *and* in argfiles), and the classpath joins
  with `$CP_SEP` (`;` on MSYS). Stock Git Bash has no `zip`/`pgrep`:
  signature stripping is `lib/StripSignatures.java` (the MANIFEST.MF-always-
  present invariant still anchors its no-op error check) and process probes go
  through `tasklist.exe`/`taskkill.exe` — with `MSYS2_ARG_CONV_EXCL='*'`, or
  MSYS mangles `/FI`-style flags into paths. `.gitattributes` pins LF: without
  it an `autocrlf=true` checkout CRLF-breaks both the scripts and patch
  context matching.
- **Repacks are wall-clock-free**: `jar --update` stamps the manifest entry
  with "now" and class entries with build mtimes, so `pack_bundle` pins the
  rewritten entries to `PACK_MTIME` via `lib/PinEntryTimes.java`
  (`-Duser.timezone=UTC` — zip DOS times are local-time encoded). CI asserts
  pack-twice determinism on every leg; don't reintroduce timestamps.

## Verification bar

A fix is done when: throwaway-workspace log is clean over a full session,
the real workspace log is clean, the user confirms visuals (theme, tabs,
scrollbars — geometry bugs are invisible in logs), `apply` is idempotent,
a clean-room `setup→apply→build→pack` reproduces the deployed jars
(byte-identical when the same JDK built both), and the git-tracked tree still
audits clean of third-party bytes.

## Environment notes

Point `ECLIPSE_HOME` (or `--eclipse`) at the install directory — the folder
holding `eclipse.ini` and `configuration/`. Useful patterns by setup:

- **WSL2 driving a Windows Eclipse** (install under `/mnt/...`): launch via
  interop from the install dir (`./eclipse.exe -data '<ws>' -clean` — the
  process detaches), kill between rounds with
  `cmd.exe /c "taskkill /IM eclipse.exe /F"`.
- **Native Linux** (incl. WSLg): `./eclipse -data <ws> -clean` from the
  install dir, kill with `pkill -x eclipse`. Wayland sessions log a benign
  DevStyle advisory suggesting `WEBKIT_DISABLE_COMPOSITING_MODE=1`.
- **Git Bash on Windows**: needs a Windows JDK on `PATH`
  (`export PATH="/c/Program Files/Eclipse Adoptium/<jdk>/bin:$PATH"`);
  `ECLIPSE_HOME` accepts `C:/…`, `C:\…`, or `/c/…`. Use `eclipsec.exe` when
  the process must stay attached to the shell (`eclipse.exe` detaches);
  kill via `taskkill.exe`. See docs/windows-git-bash.md.
- Verify on both toolkits — win32 and GTK diverge in SWT internals, DevStyle
  gates dozens of weavers on `os="win32"`, and three of its bundles exist
  only on Windows installs. "4.41 works" on Linux said nothing about Windows
  (issue #7, second round). The shared DevStyle jars (signed, byte-identical)
  ship on both platforms; the win32-only ones do not reach a Linux install.
- WSL2 can drive the Windows test install for a boot check: deploy with
  `ECLIPSE_HOME=/mnt/c/...`, launch `./eclipse.exe -data 'C:\\...' -clean`
  from the install dir, read the workspace log, kill by the PID in
  `.lock_info`. Headless `-application` runs work the same way with
  `eclipsec.exe`.
- Reproducing DPI bugs requires a display scale above 100%; at 100% the
  geometry bugs don't manifest.
- Any modern JDK works for the pipeline (`javac --release 8` is still
  supported through at least JDK 25).
