# DevStyle on Eclipse 2026-09: `PlatformUtil` cannot initialize (removed `PluginVersionIdentifier`)

**Symptom.** On Eclipse 2026-09 (4.41), once DevStyle starts at all (see
[css-weaver-superclass.md](css-weaver-superclass.md)), assorted DevStyle
features die with `NoClassDefFoundError`. The first report was inline
search's Find/Replace bar
([revstyle#7](https://github.com/Shadows-of-Fire/revstyle/issues/7)); in a
fresh workspace the workbench's own startup jobs already hit it twice:

```
!ENTRY org.eclipse.ui 4 4 2026-10-18 03:07:29.602
!MESSAGE An internal error has occurred.
!STACK 0
java.lang.NoClassDefFoundError: org/eclipse/core/runtime/PluginVersionIdentifier
	at com.genuitec.eclipse.core.util.PlatformUtil.<clinit>(PlatformUtil.java:77)
	at com.genuitec.eclipse.core.ui.util.SafeUIJob.isShellShowingMenu(SafeUIJob.java:124)
	at com.genuitec.eclipse.core.ui.util.SafeUIJob.runInUIThread(SafeUIJob.java:110)
	...
!ENTRY org.eclipse.ui 4 4 2026-10-18 03:07:29.647
!MESSAGE An internal error has occurred.
!STACK 0
java.lang.NoClassDefFoundError: Could not initialize class com.genuitec.eclipse.core.util.PlatformUtil
	at com.genuitec.eclipse.core.ui.util.SafeUIJob.isShellShowingMenu(SafeUIJob.java:124)
	...
Caused by: java.lang.ExceptionInInitializerError: Exception java.lang.NoClassDefFoundError: org/eclipse/core/runtime/PluginVersionIdentifier [in thread "main"]
	at com.genuitec.eclipse.core.util.PlatformUtil.<clinit>(PlatformUtil.java:77)
```

After the first failure the JVM marks the class as erroneous, so every later
use fails with the shorter "Could not initialize class" form.

**Root cause, platform side.** `org.eclipse.core.runtime.PluginVersionIdentifier`,
deprecated for two decades, was deleted from `org.eclipse.equinox.common`
3.21 (Eclipse 4.41; the issue thread points at eclipse-equinox/equinox
PR 1308). `unzip -l` of the bundle: present in `3.20.400.v20260512-1534`
(4.40), absent in `3.21.0.v20260604-1221` (4.41); it is the only class
removed from `org/eclipse/core/runtime/` between the two.

**Root cause, DevStyle side.** `com.genuitec.eclipse.core.common.platform`'s
`PlatformUtil`, a grab-bag of static helpers, keeps

```java
private static PluginVersionIdentifier UNDEFINED_PRODUCT_VERSION = new PluginVersionIdentifier(0, 0, 0, "");
```

as a static field, used only by `getProductVersion()`. A static field
initializer runs in `<clinit>`, so the missing class takes the whole class
down for *every* caller, however unrelated the helper they wanted. A
constant-pool scan of all 19 DevStyle bundles finds these callers outside the
bundle itself: `SafeUIJob`, `DesktopUtil`, `GenuitecPlugin`,
`PlatformEditorUtil`, `PlatformUIUtil`, `PreferencesUtils`, `ComboDialogField`
(ui.common.platform), `FindReplaceBar` and `EnhancedImageHyperlink` (inline
search), `WorkbenchProgressDialog` (startup), `DevStylePreferencesPage` and
`FinalTweaksDialog` (theming.ui). All of them call trivial helpers
(`isMacPlatform`, `isWindowsPlatform`, `isNullOrEmpty`, `getOKStatus`,
`urlEncodeForSpaces`, `getPluginOSPath`). Nothing calls `getProductVersion()`.

Reproducible without Eclipse: `Class.forName("com.genuitec.eclipse.core.util.PlatformUtil")`
with the bundle and the 4.41 `org.eclipse.{core,equinox,osgi}*` jars on the
classpath throws the same `NoClassDefFoundError` from `PlatformUtil.<clinit>`;
with the 4.40 jars it initializes.

**Fix** (`patches/com.genuitec.eclipse.core.common.platform/0001-drop-removed-pluginversionidentifier.patch`).
Remove the import, the field and `getProductVersion()`. The issue thread's
hand patch does the same. The patch also casts one `toArray` result, which
only repairs a VineFlower artifact (the decompiler drops the element type of
a raw collection, and javac then refuses `Object[]` to `String[]`); the
compiled behaviour is unchanged. The class compiles identically against 4.40,
where `PluginVersionIdentifier` still exists.

**Future risk.** `javac` warns that `PlatformUtil` also calls
`Platform.asLocalURL(URL)`, which is deprecated *for removal*. When that goes
in a later Equinox, this class will break the same way; the sweep in
`lib/refsweep.py` will flag it.

**Verification.** On a scratch 2026-09 install with the patched bundle
deployed, the two startup entries above are gone from a fresh workspace log
and no `PlatformUtil` or `PluginVersionIdentifier` reference remains in it.
