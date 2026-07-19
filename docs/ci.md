# CI: the end-to-end guard (`.github/workflows/e2e.yml`)

A scheduled workflow that answers one question: **does revstyle still repair a
fresh DevStyle install on a stock Eclipse?** It reproduces the entire user
journey on an ephemeral runner:

1. Download the Eclipse EPP package (sha512-verified, cached between runs).
2. Install pristine DevStyle from Genuitec's **live public p2 site**
   (`https://www.genuitec.com/updates/devstyle/ci/`) via the headless p2
   director.
3. **Negative control** (Eclipse 2026-06 only): boot the pristine install
   against a fresh workspace under xvfb and assert the known tab-renderer
   NPE *does* appear in the workspace log. If the harness can't see the bug,
   a green run would be meaningless — so this failure is loud and distinct.
4. Run `./revstyle.sh all` + `deploy`, assert `status` reports every target
   bundle as "patched by revstyle".
5. **Positive test**: boot the patched install against another fresh
   workspace and assert the log carries no failure signatures (reflection
   NPEs, `NoSuchField`/`NoSuchMethod`, `LinkageError`, severity-4 Genuitec
   entries), with an allowlist for noise that is benign on a browserless
   runner (Oomph's missing-WebKitGTK errors and friends).

All logic lives in `ci/e2e.sh`; the workflow is a thin matrix/cache/artifact
shell around it.

## Why scheduled and non-blocking

The workflow depends on a third party's **abandoned-but-still-alive** update
site. It runs weekly, on manual dispatch, and on pushes to `main` that touch
what it actually validates (`revstyle.sh`, `lib/`, `patches/`, `ci/`, the
workflow itself — doc-only pushes skip it). It must **never** become a
required PR check — a dead vendor site would block unrelated work. Its job is
early warning: catch a new Eclipse release breaking DevStyle (or the vendor
site disappearing) before users file issues.

Note: GitHub auto-disables cron schedules in public repos after ~60 days
without repository activity — expect to re-enable it from the Actions tab
after quiet stretches (GitHub emails a warning first).

## Matrix

| Release | Negative control | Why |
|---|---|---|
| 2026-06 (4.40) | yes | the tab-renderer NPE reproduces headlessly in a fresh workspace |
| 2026-03 (4.39) | no | its known bug is silent geometry ([scrollbar autoscaling](scrollbar-autoscaling.md)) — invisible in logs, so only pipeline + clean boot are assertable |

## Invariants (mirrors CLAUDE.md)

DevStyle is fetched from the vendor's own public site onto the runner and
discarded with it. **No Genuitec bytes enter git, the Actions cache, or
uploaded artifacts.** The cache holds only the stock EPP tarball and the
VineFlower jar; artifacts are logs only.

## Failure modes

Every failure exits with a bracketed stage tag in the job summary:

| Tag | Meaning | Action |
|---|---|---|
| `[external-dependency-gone]` | Genuitec's p2 site serves no metadata | Not a revstyle bug. If permanent, fresh DevStyle installs are no longer possible — note it in the README and retire this workflow |
| `[download-failed]` | eclipse.org tarball/checksum problems | Usually transient; re-run. Persistent → EPP layout changed, update `EPP_URL` in `ci/e2e.sh` |
| `[director-failed]` | p2 director couldn't install DevStyle | Read `p2-director.log` in the artifacts; may be the vendor-site family in disguise |
| `[version-mismatch]` | Installed DevStyle isn't `DEVSTYLE_VERSION` | The vendor site's content changed — investigate before trusting anything |
| `[boot-crashed]` / `[boot-timeout]` | Eclipse died or hung before writing a workspace log | Read the `*-launcher.log` artifact; likely runner/environment trouble |
| `[negative-control-failed]` | Pristine DevStyle no longer exhibits the known bug | **Fix the harness first** — green positives are untrustworthy until it detects the bug again |
| `[pipeline-failed]` | `revstyle.sh all`/`deploy` failed | A real revstyle regression; reproduce locally |
| `[deploy-not-patched]` | `status` doesn't report the bundles as patched | Marker/deploy logic regression; see `status.txt` artifact |
| `[positive-test-failed]` | Patched install logs failure signatures | Likely a **new Eclipse/DevStyle breakage** — start at the CLAUDE.md diagnosis playbook; evidence is in `patched-workspace.log` and `positive-failures.txt` |

## Running locally

Run from a scratch worktree (the pipeline writes `work/ build/ backups/
tools/` into the repo dir it runs from), with no Eclipse of your own running
(the script `pkill`s stray `eclipse` processes between sessions):

```sh
git worktree add /tmp/revstyle-ci-wt HEAD
cd /tmp/revstyle-ci-wt
ECLIPSE_RELEASE=2026-06 EXPECT_TAB_NPE=1 ci/e2e.sh
git worktree remove --force /tmp/revstyle-ci-wt
```

Without `xvfb-run` installed the script falls back to your real display
(e.g. WSLg) — Eclipse windows will flash up during the two boot sessions.
Fault injection: `DEVSTYLE_REPO=https://example.invalid/` exercises the
dead-vendor-site path; `ECLIPSE_RELEASE=2026-03 EXPECT_TAB_NPE=1` exercises
the negative-control failure path.

Optional hardening: installing `libwebkit2gtk-4.1-0` on the runner would
eliminate the Oomph browser noise at the source instead of allowlisting it.
