# Agent instructions — maintaining revstyle when DevStyle breaks again

This repo repairs the abandoned DevStyle plugin (final release
2025.2.0.202509301431 — there will never be another) on modern Eclipse by
patching the user's own installed jars. Eclipse ships quarterly (2026-09/4.41
is next); DevStyle reflects into SWT/Equinox internals, so expect a new break
roughly every release. This file is the playbook for that event.

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

1. `./revstyle.sh setup` (add `--all` when the broken bundle isn't already a
   target) → sources in `work/<bundle>/src/`. Bundles that embed real sources
   (the codeaffine ones: `theming.scrollbar`, `theming.base`) get them in
   `src/` with VineFlower output in `src-vf/` — always patch the embedded
   sources, never the decompiled twin.
2. Edit `work/` sources minimally (match existing style; guard, don't
   restructure). Keep fixes tolerant of older SWT (best-effort reflection).
3. If a new bundle joins the pipeline: add its BSN/sources/expected-class
   count to `lib/common.sh` (`TARGET_BSNS`, `*_SOURCES`, `*_EXPECTED_CLASSES`)
   and wire `cmd_build`/`cmd_pack` in `revstyle.sh`. Remember: recompiling an
   outer class regenerates ALL its nested classes — the expected count is the
   jar's full `Outer*.class` entry set, and pack must replace them together.
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
- Always `-clean` after swapping a jar, or Equinox serves cached bytes.
- `eclipse_running` uses `pgrep -x`; a `-f` substring match catches your own
  command line. It asks Windows (`tasklist.exe`) only when `ECLIPSE_HOME` is
  under `/mnt/*` — a Windows Eclipse can't hold a Linux install's files.

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
- Verify on both toolkits when you can — win32 and GTK diverge in SWT
  internals, and a fix that is silent in one can misbehave in the other.
  The same DevStyle jars (signed, byte-identical) ship on both platforms.
- Reproducing DPI bugs requires a display scale above 100%; at 100% the
  geometry bugs don't manifest.
- Any modern JDK works for the pipeline (`javac --release 8` is still
  supported through at least JDK 25).
