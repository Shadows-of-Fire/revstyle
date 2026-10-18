# Third-party notices

## DevStyle / Darkest Dark (Genuitec, LLC / CodeTogether Inc.)

DevStyle is proprietary software. This repository does **not** contain or
redistribute DevStyle binaries or sources. The automation operates on the
user's own installed copy. The files under `patches/` contain the minimal
fragments of context (a few lines surrounding each change) required by
`patch(1)` to apply the fixes; these fragments originate from:

- `com.genuitec.eclipse.theming.ui`, `com.genuitec.eclipse.startup`,
  `com.genuitec.eclipse.core.common.platform` — decompiled output
  (VineFlower 1.12.0) of the user's installed bundles; quoted solely for
  interoperability/repair.
- `com.genuitec.eclipse.theming.scrollbar` — sources the bundle itself embeds,
  derived from the codeaffine SWT FlatScrollBar project (EPL-1.0, see below)
  with Genuitec modifications.
- `com.genuitec.eclipse.theming.css` — a few lines of the bundle's own
  `plugin.xml` (extension-registry metadata) and of its
  `css/include/globalstyle.css` stylesheet.
- `com.genuitec.eclipse.theming.core` — a few lines of the bundle's own
  `plugin.xml` (two `class-weaver` extension declarations). The two Java
  sources the patch adds next to them are original revstyle code; they
  subclass the vendor's weaver classes by name and quote nothing else.

If you are the rights holder and want any fragment removed or replaced by a
programmatic edit, please open an issue.

## codeaffine SWT FlatScrollBar

Copyright (c) 2014–2016 Frank Appel, licensed under the Eclipse Public
License v1.0 (https://www.eclipse.org/legal/epl-v10.html). The scrollbar
patch modifies files carrying this license header.

## VineFlower

VineFlower (https://vineflower.org/) is downloaded at setup time from its
official GitHub releases and is not redistributed here. It is used solely to
decompile the user's own installed jars.

## Eclipse Platform / SWT

Eclipse and SWT are licensed under the Eclipse Public License v2.0. This
project compiles against the bundles of the user's own installation and
redistributes none of them.
