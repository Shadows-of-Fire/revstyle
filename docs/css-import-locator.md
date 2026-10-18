# DevStyle on Eclipse 2026-09: the theme falls apart (base stylesheets fail to load)

**Symptom.** Once Eclipse 2026-09 (4.41) starts with DevStyle (after the fix
in [css-weaver-superclass.md](css-weaver-superclass.md)), the workbench is
only half themed: thin light borders around parts, Project Explorer and
other trees showing the system theme's background, editor chrome mismatched.
The workspace log has the same entry three times per start, once from the
startup theme restore and twice from DevStyle re-applying its theme:

```
!ENTRY org.eclipse.e4.ui.css.swt.theme 4 0 2026-10-18 03:12:27.223
!MESSAGE Cannot invoke "String.length()" because "spec" is null
!STACK 0
java.net.MalformedURLException: Cannot invoke "String.length()" because "spec" is null
	at java.base/java.net.URL.<init>(URL.java:769)
	at java.base/java.net.URL.<init>(URL.java:630)
	at java.base/java.net.URL.<init>(URL.java:566)
	at org.eclipse.e4.ui.css.core.impl.engine.CSSEngineImpl.parseStyleSheet(CSSEngineImpl.java:189)
	at org.eclipse.e4.ui.css.core.impl.engine.CSSEngineImpl.parseStyleSheet(CSSEngineImpl.java:162)
	at org.eclipse.e4.ui.css.swt.internal.theme.ThemeEngine.setTheme(ThemeEngine.java:490)
	at org.eclipse.e4.ui.css.swt.internal.theme.ThemeEngine.setTheme(ThemeEngine.java:454)
	at org.eclipse.e4.ui.css.swt.internal.theme.ThemeEngine.restore(ThemeEngine.java:630)
	at org.eclipse.e4.ui.internal.workbench.swt.PartRenderingEngine.setCSSTheme(PartRenderingEngine.java:1416)
	...
Caused by: java.lang.NullPointerException: Cannot invoke "String.length()" because "spec" is null
	at java.base/java.net.URL.<init>(URL.java:675)
```

`spec` is the parameter name of `java.net.URL(String)`: something called
`new URL(null)` while parsing a stylesheet, the exception escaped
`parseStyleSheet`, and the theme engine dropped that stylesheet. The
stylesheet is DevStyle's base theme. Upstream report: the follow-up comments
in [revstyle#7](https://github.com/Shadows-of-Fire/revstyle/issues/7)
("1px borders around all components, the project explorer's background
color seems to be taken from the system theme now").

**How DevStyle's CSS is loaded.** `com.genuitec.eclipse.theming.css` declares
its theme with `basestylesheeturi="devstyle://css/linux.css"` (`win.css`,
`mac.css` per OS). `devstyle:` is DevStyle's own URL scheme
(`DevStyleCSSURLHandler` in `theming.ui`): it does not serve the file from the
jar but runs it through `ConvertCSS.themeGenerator(currentWorkbenchTheme)`,
substituting the active color theme. Each base stylesheet starts with
relative imports:

```css
@import url("include/basestyle.css");
@import url("include/globalstyle.css");
@import url("include/partstyle.css");
```

**Root cause.** The engine resolves a relative import in three steps, in
both releases: (1) build a URL from the importing stylesheet's directory
plus the href (here `devstyle:/css/include/basestyle.css`), (2) if that is
not an existing plain file, ask the registered `IResourceLocator`s to
`resolve(href)`, (3) `new File(new URL(resolved).getFile())` and, if that
exists, use it. Step 3 has no null check; when no locator knows the href,
`resolve` returns null and `new URL(null)` throws. Up to 4.40 this never ran
for DevStyle because its `CSSEngineFixer` weaver (`theming.core`, registered
on `org.eclipse.e4.ui.css.core.impl.engine.AbstractCSSEngine`) *replaced*
the whole `parseStyleSheet(InputSource)` method with a copy that adds the
null check (an `IFNULL` jump straight to "use the URL from step 1") and
then opens the `devstyle:` URL, so the includes went through the
color-substituting handler. 4.41 rewrote the CSS core: `AbstractCSSEngine`,
the SAC `InputSource` overload and the DOM classes the weaver names are all
gone. The weaver's woven class no longer exists, so it silently never
fires, and the stock, unguarded fallback runs. Confirmed by VineFlower
decompilation of both engines and of `CSSEngineFixer`, and by the bytecode
line table (`ThemeEngine.java:490` is the `parseStyleSheet(stream,
url.toString())` call inside the stylesheet loop).

**Fix** (`patches/com.genuitec.eclipse.theming.css/0001-resource-locator-for-relative-imports.patch`).
Give the engine a locator that knows those hrefs. The theme extension point
accepts `osgiresourcelocator` children on `stylesheet` elements, and the
`ThemeEngine` constructor registers them globally while reading the
extension registry, which is early enough for the startup `restore`.
`theming.css` already contributes a `stylesheet` element, so the patch adds:

```xml
<osgiresourcelocator uri="platform:/plugin/com.genuitec.eclipse.theming.css/css/"/>
```

Now `resolve("include/basestyle.css")` returns the `jar:` URL of the real
file inside the bundle. That is not a plain file, so step 3 keeps the
`devstyle:/css/include/basestyle.css` URL from step 1 and opens it through
DevStyle's handler, exactly the path the old weaver produced. On 4.40 the
extra locator is inert for the same reason. This is a resource patch:
`plugin.xml` is edited in `work/` and repacked into the jar; nothing is
compiled (see the `PATCH_TARGETS` resource column in `lib/common.sh`).

**Alternatives rejected.** Rewriting the imports as absolute
`platform:/plugin/...` URLs would make the engine read the includes raw from
the jar, bypassing the color substitution. Registering the locator from
DevStyle code (the way `SplashScreenFix` registers its `me-custom:` locator
on the theme-changed event) happens after the startup restore has already
failed once. Re-targeting `CSSEngineFixer` at the new engine would mean
writing new ASM against a private method of a freshly rewritten parser.

**Caveat.** If a DevStyle bundle were installed *exploded* (a directory,
not a jar), `resolve` would yield a plain file path, step 3 would find it,
and the include would be read raw instead of color-substituted. p2 installs
these bundles as jars, and the pipeline itself only handles jars.

**What it uncovered next.** With the imports resolving, the base stylesheet
is parsed for the first time on 4.41, and the new strict parser rejected it
on one malformed block the generator produces for dark themes. That is a
separate defect with its own patch: [css-parser-strictness.md](css-parser-strictness.md).

**Verification.** On the scratch 2026-09 install with both theming.css
patches deployed, the three entries above are gone from the patched
workspace log and the CI positive scan is clean; whether every widget is
coloured right needs a human looking at the IDE, so please report back on
issue #7 if something still looks off.
