import java.nio.file.FileSystem;
import java.nio.file.FileSystems;
import java.nio.file.FileVisitResult;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.SimpleFileVisitor;
import java.nio.file.attribute.BasicFileAttributes;
import java.nio.file.attribute.FileTime;
import java.time.Instant;

/**
 * Sets the last-modified time of the named jar entries (exact names or
 * directory prefixes ending in '/') to a fixed instant, so repacks carry no
 * wall-clock: `jar --update` stamps the manifest entry with "now" and class
 * entries with their build mtime, which would make byte-identical
 * rebuilds impossible. Run with -Duser.timezone=UTC — zip DOS times are
 * local-time encoded, and pinning the zone pins the bytes.
 *
 * usage: java -Duser.timezone=UTC lib/PinEntryTimes.java <jar> <iso-instant> <entry>...
 */
public final class PinEntryTimes {
    public static void main(String[] args) throws Exception {
        if (args.length < 3) {
            System.err.println("usage: PinEntryTimes <jar> <iso-instant> <entry-or-prefix/>...");
            System.exit(2);
        }
        FileTime pin = FileTime.from(Instant.parse(args[1]));
        try (FileSystem fs = FileSystems.newFileSystem(Path.of(args[0]))) {
            for (int i = 2; i < args.length; i++) {
                Path p = fs.getPath("/" + args[i]);
                if (args[i].endsWith("/")) {
                    Files.walkFileTree(p, new SimpleFileVisitor<Path>() {
                        @Override
                        public FileVisitResult visitFile(Path f, BasicFileAttributes a) throws java.io.IOException {
                            Files.setLastModifiedTime(f, pin);
                            return FileVisitResult.CONTINUE;
                        }
                    });
                } else if (Files.exists(p)) {
                    Files.setLastModifiedTime(p, pin);
                } else {
                    System.err.println("PinEntryTimes: no such entry " + args[i] + " in " + args[0]);
                    System.exit(1);
                }
            }
        }
    }
}
