import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Does the e4 CSS parser of a given Eclipse accept DevStyle's stylesheets?
 *
 * Eclipse 2026-09 (4.41) replaced the lenient SAC/Batik parser with a strict
 * in-house one, and DevStyle's devstyle: URL handler does not serve its CSS
 * files verbatim: ConvertCSS.getConvertedLine() drops every line carrying a
 * marker that does not match the active theme/OS (LIGHTONLY, DARKONLY, MACONLY,
 * EXCLUDEMAC, DARKMOJAVE, EXCLUDE_DARKMOJAVE) and substitutes colors. A marker
 * on a line that also holds a brace unbalances the served text — invisible with
 * the old parser, fatal with the new one (docs/css-parser-strictness.md).
 *
 * This probe emulates the line dropping for one (dark, os, mojave) combination
 * (colors never change syntax, so they are left alone) and feeds the result to
 * the real parser from the install's org.eclipse.e4.ui.css.core bundle, mapping
 * any rejection back to the original line. Run it for every combination before
 * shipping a CSS resource patch:
 *
 *   java -cp "<plugins>/org.eclipse.e4.ui.css.core_*.jar:<plugins>/org.eclipse.equinox.common_*.jar" \
 *        lib/CssParseProbe.java [--dark|--light] [--os linux|win32|macosx] [--mojave] <file.css>...
 *
 * Exit status 1 when any file is rejected. Diagnostic only; reads the user's own
 * extracted jar content (work/<bundle>/css/**), nothing leaves the machine.
 */
public final class CssParseProbe {
    public static void main(String[] args) throws Exception {
        boolean dark = true, mojave = false;
        String os = "linux";
        List<Path> files = new ArrayList<>();
        for (int i = 0; i < args.length; i++) {
            switch (args[i]) {
                case "--dark": dark = true; break;
                case "--light": dark = false; break;
                case "--mojave": mojave = true; break;
                case "--os": os = args[++i]; break;
                default: files.add(Path.of(args[i]));
            }
        }
        if (files.isEmpty()) {
            System.err.println("usage: CssParseProbe [--dark|--light] [--os linux|win32|macosx] [--mojave] <file.css>...");
            System.exit(2);
        }
        Class<?> parser = Class.forName("org.eclipse.e4.ui.css.core.impl.parser.CssParser");
        java.lang.reflect.Method parse = parser.getMethod("parseStyleSheet", String.class);
        Pattern pos = Pattern.compile("line (\\d+), column (\\d+)");
        boolean mac = "macosx".equals(os);
        int rejected = 0;
        for (Path file : files) {
            List<String> original = Files.readAllLines(file);
            List<String> served = new ArrayList<>();
            List<Integer> origLine = new ArrayList<>();
            for (int i = 0; i < original.size(); i++) {
                String t = original.get(i).trim();
                if (t.contains("/*DARKONLY*/") && !dark) continue;
                if (t.contains("/*EXCLUDE_DARKMOJAVE*/") && mojave) continue;
                if (t.contains("/*DARKMOJAVE*/") && !mojave) continue;
                if (t.contains("/*LIGHTONLY*/") && dark) continue;
                if (t.contains("/*MACONLY*/") && !mac) continue;
                if (t.contains("/*EXCLUDEMAC*/") && mac) continue;
                served.add(original.get(i));
                origLine.add(i + 1);
            }
            String css = String.join("\n", served) + "\n";
            try {
                parse.invoke(null, css);
                System.out.printf("ok    %s (%d of %d lines served)%n", file, served.size(), original.size());
            } catch (java.lang.reflect.InvocationTargetException e) {
                rejected++;
                Throwable cause = e.getCause();
                System.out.printf("FAIL  %s: %s%n", file, cause);
                Matcher m = pos.matcher(String.valueOf(cause.getMessage()));
                if (m.find()) {
                    int servedLine = Integer.parseInt(m.group(1));
                    if (servedLine >= 1 && servedLine <= origLine.size()) {
                        int o = origLine.get(servedLine - 1);
                        System.out.printf("      served line %d = original line %d:%n", servedLine, o);
                        for (int i = Math.max(1, o - 3); i <= Math.min(original.size(), o + 1); i++)
                            System.out.printf("      %5d%s %s%n", i, i == o ? ">" : " ", original.get(i - 1));
                    }
                }
            }
        }
        System.out.printf("%d file(s) rejected (dark=%b os=%s mojave=%b)%n", rejected, dark, os, mojave);
        if (rejected > 0) System.exit(1);
    }
}
