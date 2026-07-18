# DevStyle on Eclipse 2026-06: the tab-renderer NPE

**Symptom.** On Eclipse 2026-06 (4.40) with DevStyle 2025.2.0 installed, the
workbench fails to render properly and the workspace `.metadata/.log` fills
with dozens of entries per session:

```
java.lang.NullPointerException: Cannot invoke "java.lang.reflect.Field.setAccessible(boolean)"
        because "this.lastTabHeight" is null
    at com.genuitec.eclipse.theming.ui.rendering.SquareTabRenderer$CTabFolderRendererWrapper.resetCurves(SquareTabRenderer.java:669)
    at com.genuitec.eclipse.theming.ui.rendering.SquareTabRenderer.computeSize(SquareTabRenderer.java:159)
    at org.eclipse.swt.custom.CTabFolderRenderer.computeSize(CTabFolderRenderer.java:206)
    ...
    at org.eclipse.e4.ui.workbench.renderers.swt.WBWRenderer.postProcess(WBWRenderer.java:731)
```

Upstream report: [Genuitec/community discussion #21](https://github.com/Genuitec/community/discussions/21).

**Root cause.** Eclipse 2026-06 removed curved-tab support from SWT
(`CTabFolder.setSimple()` is deprecated for removal — "Curved tabs are no
longer supported"). With it, SWT 3.134 deleted the whole curve apparatus from
`CTabFolderRenderer`: the fields `curve`, `topCurveHighlightStart`,
`topCurveHighlightEnd`, `curveWidth`, `curveIndent`, `lastTabHeight` and the
method `updateCurves()`. Verified by comparing `javap -p` of
`org.eclipse.swt.win32.win32.x86_64` 3.132 (4.38, has all of them) with 3.134
(4.40, has none).

DevStyle's `SquareTabRenderer` and its near-duplicate
`DashboardSquareTabRenderer` each contain a `CTabFolderRendererWrapper` that
reflects into three of those fields to force flat (square) tabs. Their
`ReflectionSupport.getField()` helper swallows lookup failures and returns
`null`, and `resetCurves()` then calls `setAccessible(true)` on the null
`Field` — an NPE on **every** `CTabFolder` size computation, which is why the
whole workbench layout degrades rather than a single widget.

Everything else those wrappers touch still exists in SWT 3.134 (the 11-arg
`drawBackground(...)`, and `CTabFolder`'s `tabHeight`, `priority`,
`selectionGradientVertical`, `gradientVertical`, `gradientColors`,
`gradientPercents`), and the other reflective paths
(`getFieldValue`/`executeMethod`) were already null-tolerant — the blast
radius is exactly the two `resetCurves()` methods.

**Fix** (`patches/com.genuitec.eclipse.theming.ui/0001-null-guard-removed-swt-curve-fields.patch`).
Null-guard each of the three reflective fields, resolving them once. On an SWT
without curved tabs, "reset the curves" is semantically a no-op, so skipping
the writes is the correct behavior — flat tabs are what DevStyle wanted
anyway. The patch is behavior-neutral on older SWT where the fields exist.
