package revstyle.ci.seed;

import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;

import org.eclipse.core.resources.IFile;
import org.eclipse.core.resources.IFolder;
import org.eclipse.core.resources.IProject;
import org.eclipse.core.resources.IWorkspace;
import org.eclipse.core.resources.ResourcesPlugin;
import org.eclipse.equinox.app.IApplication;
import org.eclipse.equinox.app.IApplicationContext;

/**
 * CI helper: put one plain project into a workspace, headlessly.
 *
 * An empty workspace never paints a tree item (the Package Explorer shows
 * its "create a project" links instead), and DevStyle's 4.41 win32 crash
 * lives in Tree item custom-draw (docs/win32-tree-weaver.md). Every real
 * user's workspace has projects, so the e2e boots run against one that does.
 * Built by ci/e2e.sh against the scratch install's own bundles, dropped into
 * dropins/ for the two seeding runs, removed again afterwards.
 */
public class SeedWorkspace implements IApplication {
	@Override
	public Object start(IApplicationContext context) throws Exception {
		IWorkspace ws = ResourcesPlugin.getWorkspace();
		IProject project = ws.getRoot().getProject("revstyle-seed");
		if (!project.exists()) {
			project.create(null);
		}
		if (!project.isOpen()) {
			project.open(null);
		}
		IFolder src = project.getFolder("src");
		if (!src.exists()) {
			src.create(true, true, null);
		}
		IFile file = src.getFile("README.txt");
		if (!file.exists()) {
			file.create(new ByteArrayInputStream("seeded by revstyle ci\n".getBytes(StandardCharsets.UTF_8)), true, null);
		}
		ws.save(true, null);
		System.out.println("revstyle-seed: project '" + project.getName() + "' ready in " + ws.getRoot().getLocation());
		return EXIT_OK;
	}

	@Override
	public void stop() {
	}
}
