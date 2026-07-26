import java.nio.file.DirectoryStream;
import java.nio.file.FileSystem;
import java.nio.file.FileSystems;
import java.nio.file.Files;
import java.nio.file.Path;

/**
 * Deletes META-INF/*.SF, *.RSA, *.DSA and META-INF/MANIFEST.MF from a jar,
 * in place — the portable replacement for `zip -d` (absent on stock Git Bash).
 * Run via single-file source launch: java lib/StripSignatures.java <jar>.
 *
 * MANIFEST.MF is always present in these jars, so deleting nothing at all
 * means the jar is corrupt — that is the error case (mirrors the old
 * always-matching zip -d glob that kept unsigned pristine jars from failing).
 * jdk.zipfs copies untouched entries' raw compressed bytes on rewrite, so
 * repacks stay deterministic for a given JDK.
 */
public final class StripSignatures {
    public static void main(String[] args) throws Exception {
        if (args.length != 1) {
            System.err.println("usage: StripSignatures <jar>");
            System.exit(2);
        }
        boolean manifestSeen = false;
        try (FileSystem fs = FileSystems.newFileSystem(Path.of(args[0]))) {
            Path metaInf = fs.getPath("/META-INF");
            if (Files.isDirectory(metaInf)) {
                try (DirectoryStream<Path> entries = Files.newDirectoryStream(metaInf)) {
                    for (Path entry : entries) {
                        String name = entry.getFileName().toString();
                        if (name.equals("MANIFEST.MF")) {
                            manifestSeen = true;
                            Files.delete(entry);
                        } else if (name.endsWith(".SF") || name.endsWith(".RSA") || name.endsWith(".DSA")) {
                            Files.delete(entry);
                        }
                    }
                }
            }
        }
        if (!manifestSeen) {
            System.err.println("StripSignatures: no META-INF/MANIFEST.MF in " + args[0] + " — corrupt jar?");
            System.exit(1);
        }
    }
}
