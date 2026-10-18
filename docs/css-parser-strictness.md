# DevStyle on Eclipse 2026-09: the strict CSS parser rejects a served stylesheet

**Symptom.** With the import fix from
[css-import-locator.md](css-import-locator.md) in place, Eclipse 2026-09
(4.41) fails to start again, now with a parser error in the workspace log:

```
!ENTRY org.eclipse.osgi 4 0 2026-10-18 03:25:33.285
!MESSAGE Application error
!STACK 1
org.eclipse.e4.ui.css.core.impl.parser.CssParseException: Expected IDENT but found WS( ) (line 414, column 19)
	at org.eclipse.e4.ui.css.core.impl.parser.CssParser.error(CssParser.java:497)
	at org.eclipse.e4.ui.css.core.impl.parser.CssParser.expect(CssParser.java:490)
	at org.eclipse.e4.ui.css.core.impl.parser.CssParser.compound(CssParser.java:414)
	at org.eclipse.e4.ui.css.core.impl.parser.CssParser.complex(CssParser.java:358)
	at org.eclipse.e4.ui.css.core.impl.parser.CssParser.selectorList(CssParser.java:346)
	at org.eclipse.e4.ui.css.core.impl.parser.CssParser.styleRule(CssParser.java:168)
	at org.eclipse.e4.ui.css.core.impl.parser.CssParser.styleSheet(CssParser.java:114)
	at org.eclipse.e4.ui.css.core.impl.parser.CssParser.parseStyleSheet(CssParser.java:77)
	at org.eclipse.e4.ui.css.core.impl.engine.CSSEngineImpl.parseStyleSheet(CSSEngineImpl.java:166)
	at org.eclipse.e4.ui.css.core.impl.engine.CSSEngineImpl.parseStyleSheet(CSSEngineImpl.java:199)
	at org.eclipse.e4.ui.css.core.impl.engine.CSSEngineImpl.parseStyleSheet(CSSEngineImpl.java:162)
	at org.eclipse.e4.ui.css.swt.internal.theme.ThemeEngine.setTheme(ThemeEngine.java:490)
	at org.eclipse.e4.ui.css.swt.internal.theme.ThemeEngine.setTheme(ThemeEngine.java:454)
	at org.eclipse.e4.ui.css.swt.internal.theme.ThemeEngine.restore(ThemeEngine.java:630)
	at org.eclipse.e4.ui.internal.workbench.swt.PartRenderingEngine.setCSSTheme(PartRenderingEngine.java:1416)
	...
```

Before the import fix this never surfaced: the base stylesheet died earlier,
at its first `@import`, with an `IOException` the theme engine catches. A
`CssParseException` is a runtime exception, the engine does not catch those,
and because it happens inside the startup theme restore the whole
application aborts. Upstream report:
[revstyle#7](https://github.com/Shadows-of-Fire/revstyle/issues/7).

**Root cause, platform side.** 4.41 replaced the lenient SAC/Batik-based CSS
parser with a strict in-house one (`org.eclipse.e4.ui.css.core.impl.parser.CssParser`).
Malformed input that the old parser skipped over now throws.

**Root cause, DevStyle side.** The files in the jars are fine: the 4.41
parser accepts all 13 of DevStyle's stylesheets as shipped. What the engine
sees is different, because DevStyle serves them through its `devstyle:` URL
handler, whose generator (`ConvertCSS.getConvertedLine` in `theming.core`)
*drops whole lines* carrying a marker comment that does not fit the active
theme or OS (`/*LIGHTONLY*/`, `/*DARKONLY*/`, `/*MACONLY*/`,
`/*EXCLUDEMAC*/`, `/*DARKMOJAVE*/`, `/*EXCLUDE_DARKMOJAVE*/`) and substitutes
colors in the rest. In `css/include/globalstyle.css` one block carries the
marker on its opening line only:

```css
#myeclipse-dashboard-body Composite{ /*LIGHTONLY*/
	background-color: #202425; /*DARKONLY*/
    background-color: #010101; /*LIGHTONLY*/
}
```

Every dark theme is therefore served a stray declaration followed by a lone
`}` at top level. The old parser recovered silently (and most likely
swallowed the next rule with it); the new one, still expecting a selector,
reads `background-color:` as an identifier plus a pseudo-class and stops at
the following space, exactly the message above. Emulating the generator's
line dropping for every dark/light × linux/win32/macosx (+ Mojave)
combination and feeding the results to the real 4.41 parser shows this is
the only rejected construct in all of DevStyle's CSS. The tool for that is
`lib/CssParseProbe.java`.

**Fix** (`patches/com.genuitec.eclipse.theming.css/0002-dashboard-block-consistently-light-only.patch`).
Make the block light-only on every line and drop the dark declaration:

```css
#myeclipse-dashboard-body Composite{ /*LIGHTONLY*/
    background-color: #010101; /*LIGHTONLY*/
} /*LIGHTONLY*/
```

Light themes are served exactly the text they always were. Dark themes are
served nothing here instead of junk, which is also what the old parser
effectively made of it, so the change is behaviour-preserving on 4.40. The
alternative, removing the marker from the selector line so dark themes get
the `#202425` background the block seems to have intended for the MyEclipse
dashboard, would be a behaviour change for a widget plain Eclipse does not
have. Resource patch: the file is edited in `work/` and repacked.

**How to re-check after any CSS change.** From the repo, with an install's
plugins directory in `P`:

```sh
for combo in "--dark --os linux" "--light --os linux" "--dark --os win32" \
             "--light --os win32" "--dark --os macosx" "--light --os macosx" \
             "--dark --os macosx --mojave"; do
  java -cp "$P/org.eclipse.e4.ui.css.core_*.jar:$P/org.eclipse.equinox.common_*.jar" \
       lib/CssParseProbe.java $combo work/com.genuitec.eclipse.theming.css/css/*.css \
       work/com.genuitec.eclipse.theming.css/css/include/*.css \
       work/com.genuitec.eclipse.theming.ui/css/*.css
done
```

(Glob the two jar names first if your shell does not expand them inside
`-cp`.) The probe maps a rejection back to the original line number.

**Verification.** On the scratch 2026-09 install with all theming.css
patches deployed, the startup restore succeeds and the parser error is gone
from the workspace log.
