# DevStyle on Eclipse 2026-03+: themed-scrollbar geometry inflation at scaled DPI

**Symptom.** Starting with Eclipse 2026-03 (4.39), on displays scaled above
100%, popup dialogs whose trees/tables get DevStyle's themed flat scrollbar —
*Debug Configurations* is a reliable reproducer — are cut off at the bottom,
and the scrollbar cannot reach the last items. Nothing is logged: it is a pure
geometry miscalculation. The historical workaround was
`-Ddevstyle.enable.themedScrollbar=false` in `eclipse.ini` (which simply
disables the feature).

Upstream report: [CodeTogether-Inc/CodeTogether issue #444](https://github.com/CodeTogether-Inc/CodeTogether/issues/444).

**Background.** DevStyle vendors the codeaffine SWT FlatScrollBar (EPL-1.0)
in `com.genuitec.eclipse.theming.scrollbar`. To theme an existing `Tree` or
`Table`, `ScrollableAdapterFactory.createAdapter` conjures an adapter widget
(`TreeAdapter extends Tree`, etc.) **without running any constructor**:
`sun.misc.Unsafe.allocateInstance`, then reflectively sets `display`,
`parent`, `style`, and finally invokes SWT's internal `createWidget`.

**Root cause.** SWT 3.132 (Eclipse 2025-12) tracked "autoscaling disabled"
per control as:

```java
boolean autoScaleDisabled = false;
```

A skipped constructor leaves a `boolean` at `false` — accidentally the
correct default, so the trick worked. SWT 3.133 (2026-03) refactored this
into an enum whose default is assigned by a **field initializer**:

```java
AutoscalingMode autoscalingMode = AutoscalingMode.ENABLED;
```

`allocateInstance` skips field initializers, so DevStyle's adapters get
`autoscalingMode == null`, and SWT's check

```java
private boolean isAutoscalingDisabled() {
    return this.autoscalingMode != AutoscalingMode.ENABLED;   // null -> true
}
```

classifies them as autoscaling-disabled. That splits the adapter's coordinate
handling in two (from SWT 3.134's `Control`):

```java
int getAutoscalingZoom() { return isAutoscalingDisabled() ? 100 : super.getAutoscalingZoom(); }
int computeGetBoundsZoom() { // READ path: falls to this.getAutoscalingZoom() == 100
    return parent != null && !isAutoscalingDisabled() ? parent.getAutoscalingZoom() : getAutoscalingZoom(); }
int computeBoundsZoom() {    // WRITE path: parent's real zoom, e.g. 150
    return parent != null ? parent.getAutoscalingZoom() : getAutoscalingZoom(); }
```

Bounds are **written** ×(zoom/100) but **read back** ×1.0 — at 150% display
scale every layout pass inflates the adapted widget by 1.5×. Measured with a
standalone probe harness driving the real DevStyle adapter code on a
150% display:

| | SWT 3.132 (4.38) | SWT 3.134 (4.40) | SWT 3.134 + fix |
|---|---|---|---|
| adapter bounds after adapt | `{5, 5, 379, 281}` | `{8, 8, 568, 423}` (×1.5) | `{5, 5, 379, 282}` |
| scrollbar thumb | 1400 | 2200 | 1400 |
| drag-to-max reaches | last page (item 35/50) | item 28/50 | last page (item 35/50) |

The oversized widget extends past the dialog's shell — hence "bottom cut
off" — and the scrollbar range is computed for the partly-invisible inflated
client area — hence "can't scroll to the end". At 100% scale both zoom paths
agree on 100, which is why unscaled displays never showed the bug.

**Fix** (`patches/com.genuitec.eclipse.theming.scrollbar/0001-copy-autoscaling-mode-to-adapters.patch`).
In `ScrollableAdapterFactory.createAdapter`, after allocating the adapter and
before invoking `createWidget`, reflectively copy `autoscalingMode` from the
widget being adapted onto the adapter. Best-effort: on pre-2026-03 SWT the
field doesn't exist and the copy is a silent no-op. This repairs all adapter
types (`TreeAdapter`, `TableAdapter`, `StyledTextAdapter`,
`FigureCanvasAdapter`) at their single creation choke point, and makes the
old `eclipse.ini` workaround unnecessary.
