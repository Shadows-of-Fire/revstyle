# revstyle

Community repair kit for the **DevStyle / Darkest Dark** Eclipse theme plugin
on modern Eclipse releases (2026-03, 2026-06 and 2026-09), where the plugin is
broken and no longer maintained by its vendor.

This repository contains **no DevStyle code or binaries**. Instead it ships
automation that works on *your own* installation: it retrieves the plugin jars
from your Eclipse install, reconstructs sources (VineFlower decompilation, or
the sources some bundles embed), applies small `.patch` files, recompiles just
the touched classes against your install's own bundles, and injects the result
back into the plugin jars.

## What it fixes

| Eclipse | Symptom | Root cause | Details |
|---|---|---|---|
| 2026-09 (4.41) | Eclipse does not start at all: only the generic "An error has occurred. See the log file" dialog; the log shows `NoClassDefFoundError: org/eclipse/e4/ui/css/swt/engine/AbstractCSSSWTEngineImpl` | 4.41 collapsed the e4 CSS engine hierarchy; DevStyle's startup bundle weaves an `applyStyles` override into `CSSSWTEngineImpl` whose `super` call names the removed class | [docs/css-weaver-superclass.md](docs/css-weaver-superclass.md) |
| 2026-09 (4.41) | Inline search (Find/Replace bar), the DevStyle preference page and other dialogs die with `NoClassDefFoundError: org/eclipse/core/runtime/PluginVersionIdentifier` | Equinox 4.41 deleted `PluginVersionIdentifier`; DevStyle's `PlatformUtil` initializes a static field with it, so the whole class fails to load for every caller | [docs/platformutil-class-init.md](docs/platformutil-class-init.md) |
| 2026-09 (4.41) | Theme only half applied: thin light borders, trees with the system background; the log repeats `MalformedURLException: ... "spec" is null` from `ThemeEngine.setTheme` | 4.41 rewrote the e4 CSS core; DevStyle's weaver that used to null-guard relative `@import` resolution no longer finds anything to weave, so the base stylesheets fail to load | [docs/css-import-locator.md](docs/css-import-locator.md) |
| 2026-09 (4.41) | Once imports resolve: startup aborts with `CssParseException: Expected IDENT but found WS` from `ThemeEngine.restore` | 4.41's new CSS parser is strict; DevStyle's `devstyle:` generator drops marker lines and one block in `globalstyle.css` loses its opening line for dark themes, leaving a stray declaration the old parser silently skipped | [docs/css-parser-strictness.md](docs/css-parser-strictness.md) |
| 2026-06 (4.40) | IDE effectively unusable: rendering breaks with repeated `NullPointerException … "this.lastTabHeight" is null` in the log | SWT 3.134 removed curved-tab support from `CTabFolderRenderer`; DevStyle's tab renderers reflect into the removed fields | [docs/tab-renderer-npe.md](docs/tab-renderer-npe.md) |
| 2026-03+ (4.39/4.40), display scale ≠ 100% | Popup dialogs with themed scrollbars (e.g. *Debug Configurations*) cut off at the bottom; can't scroll to the last items | SWT 3.133's new `AutoscalingMode` field initializer is skipped by the `Unsafe.allocateInstance` trick DevStyle uses to create scrollbar adapters | [docs/scrollbar-autoscaling.md](docs/scrollbar-autoscaling.md) |

Upstream reports: [Genuitec/community#21](https://github.com/Genuitec/community/discussions/21),
[CodeTogether-Inc/CodeTogether#444](https://github.com/CodeTogether-Inc/CodeTogether/issues/444),
and for 2026-09 [revstyle#7](https://github.com/Shadows-of-Fire/revstyle/issues/7).

The 2026-09 fixes are verified headlessly (clean workspace log on a stock
2026-09 with the patched bundles); whether every widget is coloured exactly
as before needs eyes on a real session, so please report leftovers on
issue #7.

## Requirements

- DevStyle **2025.2.0.202509301431** installed (the final release, Sept 2025).
  The patches are version-specific and the tooling verifies this.
- A JDK 17+ (`java`, `javac`, `jar`) plus `bash`, `unzip`, `patch`,
  `curl`, `sha256sum`. On Windows, run from **WSL** or **Git Bash** — stock
  Git for Windows has everything needed as long as a Windows JDK is on
  `PATH`; under Git Bash `ECLIPSE_HOME` may be written as `C:/eclipse`,
  `C:\eclipse`, or `/c/eclipse`.
- Internet access on first run (downloads VineFlower 1.12.0, SHA-256 pinned).

## Quickstart

```sh
export ECLIPSE_HOME=/path/to/eclipse     # the folder containing eclipse.ini
./revstyle.sh all                        # setup + apply + build + pack
./revstyle.sh deploy                     # close Eclipse first
```

**Distro-packaged Eclipse** (e.g. Arch's `/usr/lib/eclipse`): point
`ECLIPSE_HOME` at the system install as usual. Because it is read-only,
Eclipse keeps your plugins and the active bundle list in a per-user area
under `~/.eclipse/` — revstyle detects and uses it automatically (launch
Eclipse at least once first so the area exists). `--config <dir>` overrides
the detection if ever needed.

**Eclipse Installer (Oomph) installs with a shared bundle pool** (the
installer's default layout, pool under `~/.p2/pool`): also supported. Such
installs list their bundles in `bundles.info` as `file:` URIs pointing into
the pool; revstyle resolves them (`status` reports "in shared p2 pool") and
patches the jars **in the pool** — so every Eclipse install that shares the
pool picks up the patched bundles, and `restore` likewise affects them all.

Then start Eclipse once with `-clean` (e.g. `eclipse -clean`) so the OSGi
cache picks up the modified bundles. Undo at any time with
`./revstyle.sh restore`.

`./revstyle.sh status` shows what state your install is in;
`./revstyle.sh setup --all` additionally decompiles *every* DevStyle bundle
into `work/` as a browsable per-bundle workspace, useful when the next Eclipse
release breaks something new.

## How it works

```
your Eclipse install                     this repo
────────────────────                     ─────────
plugins/com.genuitec…jar ──backup──▶ backups/   (pristine copy)
        │
        ├─ theming.ui, startup,
        │  core.common.platform: VineFlower 1.12.0 ──▶ work/<bundle>/src/
        ├─ theming.scrollbar:    embedded src/**   ──▶ work/<bundle>/src/
        └─ theming.css:          plugin.xml (resource, no compile) ──▶ work/<bundle>/
                                                        │
                              patches/*.patch ──apply──▶│
                                                        ▼
        javac --release 8  (classpath = your install's bundles) ──▶ build/classes/
                                                        │
   backups/ jar + patched classes ──repack (signature stripped)──▶ build/<bundle>.jar
                                                        │
plugins/com.genuitec…jar ◀───────────── deploy ─────────┘
```

Notes on the mechanics:

- **Why strip the signature?** The jars are signed by the vendor; modifying
  any class would fail signature verification, so the repack removes
  `META-INF/CODETOGE.SF/.RSA` and the per-entry digests. Equinox loads
  unsigned bundles normally. The `Bundle-SymbolicName`/`Bundle-Version` and
  file name stay identical, so p2 metadata remains consistent. Some installs
  ship these jars unsigned in the first place — then there is nothing to
  strip. Repacked jars are identified by a `Revstyle-Patched: true` manifest
  attribute, not by the missing signature.
- **Determinism:** the theming.ui patch applies to VineFlower **1.12.0**
  output produced with pinned flags; the tool verifies the decompiler jar by
  SHA-256. The scrollbar patch applies to sources the jar itself embeds.
- **`deploy` also removes** the old `-Ddevstyle.enable.themedScrollbar=false`
  workaround from `eclipse.ini` if present (backing the file up first) — the
  scrollbar patch makes it unnecessary.

## FAQ

**Is this safe?** `setup` refuses to run without securing a pristine backup of
each jar first, `restore` puts them back, and every step is inspectable
(`work/` sources, `build/` outputs). Nothing outside the five plugin jars and
the one `eclipse.ini` line is touched.

**Eclipse still looks broken after deploy.** Launch once with `-clean` —
Equinox caches bundle bytes.

**Antivirus flags the repacked jar.** Some AV heuristics dislike freshly
unsigned jars; the bytes are exactly your original jar plus the recompiled
classes, and you built them locally.

**A different DevStyle/Eclipse version?** The patches target DevStyle
2025.2.0.202509301431 on Eclipse 2026-03 through 2026-09. Other combinations
fail fast with a clear error rather than half-applying. The last revision
that patched only the two 2026-03/2026-06 bundles is kept on the `2026-06`
branch for the record.

**`status` says "pristine (unsigned)" but I deployed patched jars earlier.**
Jars deployed by an older revstyle (before the `Revstyle-Patched` manifest
marker) can't be told apart from an unsigned pristine install. Your existing
`backups/` remain valid and are what `setup` trusts; re-run
`pack` + `deploy` once and `status` will report "patched by revstyle".

## CI

A weekly end-to-end workflow installs pristine DevStyle from the vendor's
live update site onto a stock Eclipse, proves the known bug reproduces, then
proves the revstyle pipeline fixes it — on Linux (GTK) and on a Windows
runner under Git Bash (win32) — see [docs/ci.md](docs/ci.md) for the
failure-mode table. No Genuitec bytes are ever committed, cached, or uploaded.

## Legal

- This repository's automation, documentation, and diagnostic harness are MIT
  licensed (see [LICENSE](LICENSE)).
- It distributes **no** Genuitec/CodeTogether binaries or source. All DevStyle
  code involved is read from, and written back to, the user's own licensed
  installation.
- The `.patch` files necessarily quote a few context lines of third-party
  code (decompiled or vendored) — the minimum required for `patch(1)` to
  locate the fix — for the purpose of interoperability and repair of a
  lawfully installed product. The scrollbar patch touches code that is
  EPL-1.0 (codeaffine FlatScrollBar). See [NOTICE.md](NOTICE.md).
- Not affiliated with or endorsed by Genuitec, CodeTogether Inc., or the
  Eclipse Foundation. Use at your own risk.

## Credits

- [VineFlower](https://vineflower.org/) — the decompiler this project pins.
- [codeaffine SWT FlatScrollBar](https://github.com/fappel/SWT) (EPL-1.0) —
  the open-source scrollbar implementation DevStyle vendors.
- Everyone reporting upstream in Genuitec/community#21 and
  CodeTogether-Inc/CodeTogether#444.
