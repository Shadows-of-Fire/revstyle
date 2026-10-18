# DevStyle on Eclipse 2026-09, Windows: any workspace with a project aborts at startup

**Symptom.** On Windows, Eclipse 2026-09 (4.41) with DevStyle starts fine
into an *empty* workspace, but as soon as a tree with items has to be
painted things go wrong, and in two different ways depending on when that
happens:

- **Workspace already holds a project** (every real workspace): the window
  appears, closes again a moment later, and `eclipse.exe` stays alive in
  Task Manager. The workspace log has one entry:

  ```
  !ENTRY org.eclipse.osgi 4 0 2026-10-18 18:09:40.521
  !MESSAGE Application error
  !STACK 1
  java.lang.NoSuchMethodError: 'boolean org.eclipse.swt.internal.win32.OS.IsAppThemed()'
  	at org.eclipse.swt.widgets.Tree.CDDS_ITEMPOSTPAINT(Tree.java:440)
  	at org.eclipse.swt.widgets.Tree.wmNotifyChild(Tree.java:7517)
  	at org.eclipse.swt.widgets.Control.wmNotify(Control.java:6015)
  	at org.eclipse.swt.widgets.Composite.wmNotify(Composite.java:1958)
  	at org.eclipse.swt.widgets.Control.WM_NOTIFY(Control.java:5584)
  	at org.eclipse.swt.widgets.Control.windowProc(Control.java:5020)
  	at org.eclipse.swt.widgets.Display.windowProc(Display.java:5131)
  	at org.eclipse.swt.internal.win32.OS.CallWindowProc(Native Method)
  	at org.eclipse.swt.widgets.Tree.callWindowProc(Tree.java:1563)
  	...
  	at org.eclipse.e4.ui.internal.workbench.swt.PartRenderingEngine$5.run(PartRenderingEngine.java:1160)
  	at org.eclipse.e4.ui.internal.workbench.E4Workbench.createAndRunUI(E4Workbench.java:153)
  ```

  The Package Explorer paints its first item while the workbench is still
  being restored, before the event loop's exception handler exists, so the
  error escapes `createAndRunUI`, Equinox logs "Application error" and tears
  the workbench down ("Device is disposed" follows in the log). The JVM then
  hangs in shutdown, which is the lingering process.

- **Empty workspace**: startup succeeds (the Package Explorer shows its
  "create a project" links, no tree item is painted). The first wizard or
  view that shows a populated tree — the New Project wizard, for instance —
  throws the same `NoSuchMethodError` on every item paint, now caught by the
  running event loop as "Unhandled event loop exception". The log floods
  (3000+ entries, 11 MB of rotated `.bak_N.log` files in one minute), the
  tree is drawn wrong, and on exit the half-broken dialogs add a few disposed
  widget errors. From then on the workspace has a project, and the next start
  is the first case.

This looked like workspace corruption: the first session "worked", every
later launch of that workspace died, a fresh workspace opened fine. The
workspace is intact — `workbench.xmi` well-formed, the resource tree saved,
the project complete. What differs is only that it now contains a project.
Upstream report: [revstyle#7](https://github.com/Shadows-of-Fire/revstyle/issues/7).

**Root cause.** DevStyle's `theming.core` bundle registers two win32-only
bytecode weavers, `FixTree202409` and `FixTable202409`, for SWT 3.127 and
later (its `plugin.xml`: `os="win32" bundle="org.eclipse.swt"
bundle-version="3.127.0"`). They do not *patch* SWT's `Tree` and `Table`:
they delete `Tree.CDDS_ITEMPOSTPAINT` and `Table.sendEraseItemEvent` and
re-emit complete copies of those methods, one ASM instruction per source
instruction, as compiled against the 2024-09 SWT (hence the stack trace's
`Tree.java:440`: the line table is the weaver's, not 4.41's). Both copies
call `OS.IsAppThemed()`. SWT 3.135 (Eclipse 2026-09) removed that native,
together with 20 other `OS` members (`DrawFrameControl`,
`ImageList_AddMasked`, `SetProcessDPIAware`, old `DFCS_*` constants);
visual styles are always on, and 3.135's own `Tree` evaluates the condition
as plain `true`:

```
3.134 Tree.CDDS_ITEMPOSTPAINT:  279: invokestatic OS.IsAppThemed:()Z   286: getfield sortColumn ...
3.135 Tree.CDDS_ITEMPOSTPAINT:                                          280: getfield sortColumn ...
```

The woven method links lazily, so nothing fails until the first custom-draw
notification for a tree item.

Why none of the earlier 4.41 work saw it: the sweep and the scratch boots in
[css-weaver-superclass.md](css-weaver-superclass.md) ran on Linux. These
weavers are `os="win32"`, three DevStyle bundles exist only on Windows
installs (`theming.base.win`, `theming.scrollbar.win`,
`theming.elevation.win32`), and the class-level sweep could not see a
removed *method* on a class that still exists. The Windows CI leg ran 4.40,
and its workspace was empty, which — see above — never paints a tree item.

**Fix** (`patches/com.genuitec.eclipse.theming.core/0001-win32-tree-table-weavers-without-isappthemed.patch`).
`FixTree202409.weave` is a 4,400-line generated method that VineFlower cannot
decompile on an ordinary heap (it needed 24 GB here), so it is not edited.
Instead two small subclasses, `FixTree202609` and `FixTable202609`, run the
vendor weaver unchanged and then walk the method it just emitted (the ASM
tree API keeps it as a `MethodNode`), replacing every
`INVOKESTATIC OS.IsAppThemed()Z` with `ICONST_1`, the value 3.135 assumes.
The two `class-weaver` extensions in `plugin.xml` are pointed at the
subclasses. The replacement happens only when the running SWT really lacks
the method (a reflective probe), so 4.37-4.40 are woven byte for byte as
before. In the pipeline this is one target with two new sources and one
resource (`PATCH_TARGETS` in `lib/common.sh`): javac compiles the subclasses
against the install's own `theming.core` jar and ASM bundle, `pack` adds the
two classes and the edited `plugin.xml` to the repacked jar; the vendor
classes stay untouched.

Verified three ways: (1) `lib/refsweep.py` (member-level, see below) over
all 22 Windows DevStyle bundles finds exactly these two `IsAppThemed`
emissions as the active breakage against 4.41, and nothing after the patch;
(2) an offline harness ran the shim weavers over the real 3.135 `Tree` and
`Table` classes — no `IsAppThemed` left, ASM's verifier accepts the result,
every member the woven methods reference resolves (the `DPIUtil.autoScale*`
calls through the members DevStyle's own `FixDPIUtil202509` weaver re-adds,
which still applies cleanly on 3.135) — and over 3.134, where the call is
left in place; (3) the very workspace that failed opened cleanly on the
patched install and shut down normally.

**Repairing a workspace that "went bad".** Nothing to repair: deploy the
patched bundles (`./revstyle.sh all && ./revstyle.sh deploy`) and the
workspace opens as it was. Two things to clean up first:

1. The hung `eclipse.exe` from the failed start still owns the workspace
   lock. Kill it (Task Manager, or `taskkill /IM eclipse.exe /F` — make sure
   no other Eclipse is running) before `deploy` (which refuses while
   Eclipse runs) and before the next launch. Without that the next launch
   reports "Workspace ... is in use or cannot be created".
2. The first session's log flood left ten 1 MB `.metadata/.bak_*.log` files
   next to `.metadata/.log`; delete them if the space matters.

Launch with `-clean` once after deploying. Do not delete `.metadata` — it
holds your perspective layout and project list and is not the problem.

**How to tell this family apart next time.** A crash that only happens for
workspaces with content, or only after the first project is created, is a
*rendering-path* break, not a startup break: the code runs when a widget is
painted, so an empty workspace, a headless CI boot or a Welcome page over
the perspective never reaches it. Static analysis does:

```sh
# every platform CLASS and MEMBER DevStyle links against or weaves in,
# resolved against the new install; weaver gates (os, SWT version range,
# woven class still present) are applied so inactive weavers don't alarm
python3 -I lib/refsweep.py <extracted DevStyle bundles> <old plugins/> <new plugins/> \
        --old <previous release's win32 SWT fragment.jar>
```

Take the DevStyle bundles from a **Windows** install (or a Windows p2
layout) so the win32-only bundles and weavers are in the set. From Linux,
Maven Central has the previous release's `org.eclipse.swt.win32.win32.x86_64`
jar; passed as `--old` it takes precedence over the Linux plugins dir, so
`Tree`/`Image`/`OS` resolve against win32. CI runs the one-install form
(`--single --baseline ci/refsweep-baseline.txt --fail`) on the patched
install of every leg, and both e2e boots now use a workspace that already
holds a project (`ci/seed/`), so the Windows 2026-09 leg paints the tree
the way a user's workspace does.
