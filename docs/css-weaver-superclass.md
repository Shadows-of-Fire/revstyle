# DevStyle on Eclipse 2026-09: startup aborts in the CSS engine (weaver names a removed superclass)

**Symptom.** On Eclipse 2026-09 (4.41) with DevStyle 2025.2.0 installed, the
workbench never appears. Eclipse shows only the generic *"An error has
occurred. See the log file"* dialog and the workspace `.metadata/.log` holds
one entry:

```
!ENTRY org.eclipse.osgi 4 0 2026-10-18 02:58:08.123
!MESSAGE Application error
!STACK 1
java.lang.NoClassDefFoundError: org/eclipse/e4/ui/css/swt/engine/AbstractCSSSWTEngineImpl
	at org.eclipse.e4.ui.css.swt.internal.theme.ThemeEngineManager.getCSSSWTEngine(ThemeEngineManager.java:51)
	at org.eclipse.e4.ui.css.swt.internal.theme.ThemeEngineManager.getEngineForDisplay(ThemeEngineManager.java:40)
	at org.eclipse.e4.ui.internal.workbench.swt.PartRenderingEngine.createThemeEngine(PartRenderingEngine.java:1406)
	at org.eclipse.e4.ui.internal.workbench.swt.PartRenderingEngine.initializeStyling(PartRenderingEngine.java:1283)
	...
Caused by: java.lang.ClassNotFoundException: org.eclipse.e4.ui.css.swt.engine.AbstractCSSSWTEngineImpl cannot be found by org.eclipse.e4.ui.css.swt_0.17.100.v20260730-1116
```

It fires in `initializeStyling`, before any window exists, which is why
there is nothing to look at. Upstream report:
[revstyle#7](https://github.com/Shadows-of-Fire/revstyle/issues/7).

**Root cause, platform side.** 4.41 collapsed the e4 CSS/SWT engine
hierarchy. `javap -p` of `org.eclipse.e4.ui.css.swt`:

| | 4.40 (`0.17.0.v20260516-1214`) | 4.41 (`0.17.100.v20260730-1116`) |
|---|---|---|
| `CSSSWTEngineImpl extends` | `AbstractCSSSWTEngineImpl` | `org.eclipse.e4.ui.css.core.impl.engine.CSSEngineImpl` |
| `AbstractCSSSWTEngineImpl` | present | **gone** |

The CSS core got the same treatment (`AbstractCSSEngine` folded into
`CSSEngineImpl`, the SAC-based DOM replaced by a new in-house parser); that
part matters for [css-import-locator.md](css-import-locator.md).

**Root cause, DevStyle side.** The `com.genuitec.eclipse.startup` bundle
registers an ASM class weaver through DevStyle's own weaving engine
(`com.genuitec.eclipse.patches.extensions`, `plugin.xml`):

```xml
<class-weaver id="ignore-css-for-shell" name="Ignore CSS for shell"
      weaver="com.genuitec.eclipse.startup.patches.IgnoreCSSClassPatch">
   <woven-class name="org.eclipse.e4.ui.css.swt.engine.CSSSWTEngineImpl"/>
</class-weaver>
```

`IgnoreCSSClassPatch.weave()` injects an `applyStyles(Object, boolean)`
override that skips CSS for shells flagged `org.eclipse.e4.ui.css.disabled`
and otherwise delegates to `super`. The delegation is emitted as

```java
mv.visitMethodInsn(INVOKESPECIAL, "org/eclipse/e4/ui/css/swt/engine/AbstractCSSSWTEngineImpl",
                   "applyStyles", "(Ljava/lang/Object;Z)V", false);
```

with the owner spelled out as the 4.40 superclass. The weaver still runs on
4.41 (its target class exists), so the rewritten `CSSSWTEngineImpl` carries
a constant-pool reference to a class the framework cannot find, and the JVM
reports it the first time the class is used. This confirms the issue
reporter's hypothesis of a retained `INVOKESPECIAL` reference; the constant
pool of the pristine `IgnoreCSSClassPatch.class` contains the string, and a
binary grep across all 19 DevStyle bundles shows it is the only one.

**Fix** (`patches/com.genuitec.eclipse.startup/0001-css-weaver-invoke-actual-superclass.patch`).
Emit the invoke against the woven class's own superclass instead of a name:

```java
mv.visitMethodInsn(INVOKESPECIAL, cw.superName, "applyStyles", "(Ljava/lang/Object;Z)V", false);
```

`INVOKESPECIAL` resolves the inherited method through whichever superclass
is current, so the same bytes are right on 4.40 (`AbstractCSSSWTEngineImpl`)
and 4.41 (`CSSEngineImpl`). The issue thread's hand patch hardcodes
`CSSEngineImpl`, which also works on both because that class is an ancestor
in both hierarchies; deriving the name is simply more durable.

**Verification.** Pristine DevStyle on a scratch 2026-09 install
(`eclipse.buildId=4.41.0.20260903-0719`, installed with the headless p2
director from the vendor's update site) reproduces the entry above and
nothing else. With the patched startup bundle deployed, the workbench starts,
DevStyle logs `A DevStyle Theme is being activated on this workspace`, and
the only remaining DevStyle-related failures are the two covered by
[platformutil-class-init.md](platformutil-class-init.md) and
[css-import-locator.md](css-import-locator.md). The CI harness uses the
`NoClassDefFoundError` line above as the 4.41 negative-control signature
(`NEGATIVE_CONTROL=css-ncdfe`, see [ci.md](ci.md)).

**Method note.** This release broke four DevStyle bundles at once; the
complete list came from one pass of `lib/refsweep.py`, which scans every
DevStyle class's constant pool (direct references, descriptors, *and* string
constants, which is where ASM weavers keep their targets) for platform
classes present in the old plugins/ and absent from the new one. Run it first
on the next release.
