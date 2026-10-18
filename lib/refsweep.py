#!/usr/bin/env python3
"""refsweep.py — which platform classes AND members that DevStyle references
disappeared between two Eclipse releases?

usage:
  python3 -I lib/refsweep.py <devstyle-root> <old plugins/> <new plugins/>
        [--old <dir|jar>]... [--new <dir|jar>]... [--os win32|linux|macosx]
        [--classes-only] [--single] [--baseline <file>] [--write-baseline <file>] [--fail]

<devstyle-root> holds the DevStyle bundles' content, one subdir per bundle
(unzip -qo plugins/com.genuitec*.jar -d <root>/<bundle>, class files and
plugin.xml). Take it from a WINDOWS install when you can: the win32-only
bundles (theming.base.win, scrollbar.win, elevation.win32) never exist on a
Linux install, and the win32 weavers in theming.core only matter there.

Two passes over every class file's constant pool and bytecode:

1. classes (the original sweep): org.eclipse / org.w3c / org.apache / com.ibm
   names in Class entries, descriptors and String constants (ASM weavers name
   their targets as strings), checked against both plugin sets. Reported:
   present in <old>, missing in <new>.
2. members: every Fieldref/Methodref the class links against directly, plus
   every (owner, name, desc) an ASM weaver EMITS — the bytecode is walked and
   the string constants feeding visitMethodInsn/visitFieldInsn/visitTypeInsn
   are recovered — resolved against <new> with JVM semantics (superclasses and
   interfaces). Reported: resolves in <old>, fails in <new>, while the owner
   class still exists (a removed owner is already in pass 1). This is what
   catches a weaver re-emitting a 2024 copy of an SWT method that calls a
   native SWT since deleted (4.41 win32: OS.IsAppThemed, revstyle#7).

Each finding carries the weaver gate from the bundle's plugin.xml
(class-weaver / class-replacement os + bundle-version), evaluated against the
<new> install, so a weaver that only runs on older SWT or another OS is listed
as inactive instead of raising an alarm. Extra --old/--new entries add jars or
directories to a side and take precedence over the plugins/ dir for classes
present in both — so from Linux, pass the previous release's win32 SWT
fragment (Maven Central ships it) as --old and its Image/Tree/... resolve
against win32, not GTK. Classes of another OS's window system than the
target are ignored. A weaver whose woven class no longer exists is reported
as inactive (it is silently inert at runtime — lost behaviour, no exception). --single is the one-install
mode for CI (pass the same plugins/ as old and new): members are judged
against <new> alone — minus the ones DevStyle itself weaves in — and --fail
exits 1 on an ACTIVE member finding; the class pass needs a real previous
release and is informational there. Without --single, --fail counts both.
A static pass cannot see runtime guards (reflection probes, version branches
inside a weaver), so a few members are unresolved on EVERY release; --baseline
<file> lists such known member keys (one per line, # comments) and they are
reported but not counted; --write-baseline <file> records this run's active
member keys to seed that file from a release known to work (ci/refsweep-baseline.txt). Diagnostic only — no Genuitec bytes leave the
machine. Pure stdlib.
"""
import sys, os, re, struct, zipfile, collections
import xml.etree.ElementTree as ET

PLAT = ('org/eclipse/', 'org/w3c/', 'org/apache/', 'com/ibm/')
SKIP_OWNER = ('java/', 'javax/', 'jdk/', 'sun/')
OBJECT_METHODS = {'<init>', 'equals', 'hashCode', 'toString', 'getClass', 'clone', 'finalize', 'notify', 'notifyAll', 'wait'}

# ------------------------------------------------------------------ args
args = sys.argv[1:]
pos, old_paths, new_paths, target_os, classes_only, fail, single, baseline, write_baseline = [], [], [], None, False, False, False, None, None
i = 0
while i < len(args):
    a = args[i]
    if a == '--old': old_paths.append(args[i+1]); i += 2
    elif a == '--new': new_paths.append(args[i+1]); i += 2
    elif a == '--os': target_os = args[i+1]; i += 2
    elif a == '--classes-only': classes_only = True; i += 1
    elif a == '--fail': fail = True; i += 1
    elif a == '--single': single = True; i += 1
    elif a == '--baseline': baseline = args[i+1]; i += 2
    elif a == '--write-baseline': write_baseline = args[i+1]; i += 2
    elif a in ('-h', '--help'): print(__doc__); sys.exit(0)
    else: pos.append(a); i += 1
if len(pos) != 3:
    print(__doc__); sys.exit(2)
root = pos[0]; old_paths.append(pos[1]); new_paths.append(pos[2])   # explicit extras first: they win for classes present in both

# ------------------------------------------------------------------ class files
def u2(d, i): return struct.unpack_from('>H', d, i)[0]
def u4(d, i): return struct.unpack_from('>I', d, i)[0]

class ClassInfo:
    __slots__ = ('name', 'sup', 'ifaces', 'fields', 'methods', 'cp', 'codes')

def parse_class(data, want_code=False):
    if data[:4] != b'\xca\xfe\xba\xbe': return None
    n = u2(data, 8); i = 10; k = 1; cp = [None] * n
    while k < n:
        t = data[i]
        if t == 1:
            l = u2(data, i+1); cp[k] = ('u', data[i+3:i+3+l].decode('utf-8', 'replace')); i += 3 + l
        elif t in (3, 4): cp[k] = ('i',); i += 5
        elif t in (5, 6): cp[k] = ('l',); i += 9; k += 1
        elif t == 7: cp[k] = ('c', u2(data, i+1)); i += 3
        elif t == 8: cp[k] = ('s', u2(data, i+1)); i += 3
        elif t in (9, 10, 11): cp[k] = ({9: 'F', 10: 'M', 11: 'I'}[t], u2(data, i+1), u2(data, i+3)); i += 5
        elif t == 12: cp[k] = ('nt', u2(data, i+1), u2(data, i+3)); i += 5
        elif t in (17, 18): cp[k] = ('dyn',); i += 5
        elif t == 15: cp[k] = ('mh',); i += 4
        elif t in (16, 19, 20): cp[k] = ('x',); i += 3
        else: raise ValueError('constant pool tag %d' % t)
        k += 1
    ci = ClassInfo(); ci.cp = cp
    this = u2(data, i+2); sup = u2(data, i+4); icount = u2(data, i+6); i += 8
    ci.name = cp[cp[this][1]][1]
    ci.sup = cp[cp[sup][1]][1] if sup else None
    ci.ifaces = [cp[cp[u2(data, i+2*j)][1]][1] for j in range(icount)]; i += 2 * icount
    def members(i, want):
        cnt = u2(data, i); i += 2; out = set(); codes = []
        for _ in range(cnt):
            nm = cp[u2(data, i+2)][1]; ds = cp[u2(data, i+4)][1]; ac = u2(data, i+6); i += 8
            out.add((nm, ds))
            for _a in range(ac):
                an = cp[u2(data, i)][1]; al = u4(data, i+2)
                if want and an == 'Code':
                    cl = u4(data, i+10); codes.append((nm, ds, data[i+14:i+14+cl]))
                i += 6 + al
        return i, out, codes
    i, ci.fields, _ = members(i, False)
    i, ci.methods, ci.codes = members(i, want_code)
    return ci

def cp_class(cp, idx):
    e = cp[idx]
    return cp[e[1]][1] if e and e[0] == 'c' else None

# ------------------------------------------------------------------ bytecode walk (ASM emission recovery)
# operand byte counts per opcode (-1: variable)
OPLEN = [0]*256
for o in range(0x10, 0x12): OPLEN[o] = 1
OPLEN[0x10] = 1; OPLEN[0x11] = 2; OPLEN[0x12] = 1; OPLEN[0x13] = 2; OPLEN[0x14] = 2
for o in range(0x15, 0x1a): OPLEN[o] = 1
for o in range(0x36, 0x3b): OPLEN[o] = 1
OPLEN[0x84] = 2
for o in range(0x99, 0xa9): OPLEN[o] = 2
OPLEN[0xa9] = 1; OPLEN[0xaa] = -1; OPLEN[0xab] = -1
for o in range(0xb2, 0xb9): OPLEN[o] = 2
OPLEN[0xb9] = 4; OPLEN[0xba] = 4; OPLEN[0xbb] = 2; OPLEN[0xbc] = 1; OPLEN[0xbd] = 2
OPLEN[0xc0] = 2; OPLEN[0xc1] = 2; OPLEN[0xc4] = -1; OPLEN[0xc5] = 3; OPLEN[0xc6] = 2; OPLEN[0xc7] = 2
OPLEN[0xc8] = 4; OPLEN[0xc9] = 4

def desc_argc(desc):
    n = 0; i = 1
    while desc[i] != ')':
        c = desc[i]
        while c == '[': i += 1; c = desc[i]
        if c == 'L': i = desc.index(';', i) + 1
        else: i += 1
        n += 1
    return n, desc[desc.index(')')+1:]

ASM_VISITS = {'visitMethodInsn': 'method', 'visitFieldInsn': 'field', 'visitTypeInsn': 'type'}
ASM_DECLS = {'visitField': 'decl-field', 'visitMethod': 'decl-method'}

def scan_emitted(code, cp):
    """Walk one method's bytecode with a tiny operand-stack model and return the
    (kind, owner, name, desc) tuples passed as constants to ASM visit calls, plus
    the number of such calls whose owner/name/desc were not constants."""
    out = []; dynamic = 0; st = []
    def push(x):
        st.append(x)
        if len(st) > 64: del st[0]
    def pop(n=1):
        for _ in range(n):
            if st: st.pop()
    i = 0; L = len(code)
    while i < L:
        op = code[i]; ln = OPLEN[op]; nxt = None
        if op == 0xaa:   # tableswitch
            p = (i + 4) & ~3; lo = struct.unpack_from('>i', code, p+4)[0]; hi = struct.unpack_from('>i', code, p+8)[0]
            nxt = p + 12 + 4 * (hi - lo + 1); pop()
        elif op == 0xab: # lookupswitch
            p = (i + 4) & ~3; np_ = struct.unpack_from('>i', code, p+4)[0]
            nxt = p + 8 + 8 * np_; pop()
        elif op == 0xc4: # wide
            w = code[i+1]; nxt = i + (6 if w == 0x84 else 4)
            if 0x15 <= w <= 0x19: push(('?',))
            elif 0x36 <= w <= 0x3a: pop()
        else:
            nxt = i + 1 + ln
        if op == 0x01: push(('?',))
        elif 0x02 <= op <= 0x08: push(('I', op - 3))
        elif op == 0x10: push(('I', struct.unpack_from('>b', code, i+1)[0]))
        elif op == 0x11: push(('I', struct.unpack_from('>h', code, i+1)[0]))
        elif op in (0x12, 0x13):
            idx = code[i+1] if op == 0x12 else u2(code, i+1); e = cp[idx]
            if e and e[0] == 's': push(('S', cp[e[1]][1]))
            elif e and e[0] == 'i': push(('I', None))
            else: push(('?',))
        elif op == 0x14: push(('?',))
        elif 0x15 <= op <= 0x2d: push(('?',))
        elif 0x2e <= op <= 0x35: pop(2); push(('?',))
        elif 0x36 <= op <= 0x4e: pop()
        elif 0x4f <= op <= 0x56: pop(3)
        elif op == 0x57: pop()
        elif op == 0x58: pop(2)
        elif op == 0x59:
            if st: push(st[-1])
        elif op in (0x5a, 0x5b):
            if st: st.insert(max(0, len(st) - (2 if op == 0x5a else 3)), st[-1])
        elif op == 0x5c:
            if len(st) >= 2: a, b = st[-2], st[-1]; push(a); push(b)
        elif op in (0x5d, 0x5e): push(('?',))
        elif op == 0x5f:
            if len(st) >= 2: st[-1], st[-2] = st[-2], st[-1]
        elif 0x60 <= op <= 0x73 or 0x78 <= op <= 0x83: pop(2); push(('?',))
        elif 0x94 <= op <= 0x98: pop(2); push(('?',))
        elif 0x99 <= op <= 0x9e: pop()
        elif 0x9f <= op <= 0xa6: pop(2)
        elif op == 0xa8: push(('?',))
        elif 0xac <= op <= 0xb0: pop()
        elif op == 0xb2: push(('?',))
        elif op == 0xb3: pop()
        elif op == 0xb4: pop(); push(('?',))
        elif op == 0xb5: pop(2)
        elif 0xb6 <= op <= 0xb9:
            e = cp[u2(code, i+1)]
            if e and e[0] in ('M', 'I'):
                owner = cp_class(cp, e[1]); nm, ds = cp[cp[e[2]][1]][1], cp[cp[e[2]][2]][1]
                argc, ret = desc_argc(ds)
                if nm in ASM_DECLS and owner and owner.startswith('org/objectweb/asm/') and argc >= 3:
                    a = st[-argc:] if len(st) >= argc else None
                    if a and a[1][0] == 'S' and a[2][0] == 'S': out.append((ASM_DECLS[nm], None, a[1][1], a[2][1]))
                    else: dynamic += 1
                elif nm in ASM_VISITS and owner and owner.startswith('org/objectweb/asm/') and argc >= 2:
                    a = st[-argc:] if len(st) >= argc else None
                    kind = ASM_VISITS[nm]
                    if a is None: dynamic += 1
                    elif kind == 'type':
                        if a[1][0] == 'S': out.append(('type', a[1][1], None, None))
                        else: dynamic += 1
                    else:
                        if argc >= 4 and a[1][0] == 'S' and a[2][0] == 'S' and a[3][0] == 'S':
                            out.append((kind, a[1][1], a[2][1], a[3][1]))
                        else: dynamic += 1
                pop(argc + (0 if op == 0xb8 else 1))
                if ret != 'V': push(('?',))
            else:
                pop(1)
        elif op == 0xba:
            e = cp[u2(code, i+1)]
            # invokedynamic: NameAndType is at index 2 of the cp entry; we did not keep it — approximate
            push(('?',))
        elif op == 0xbb: push(('?',))
        elif op in (0xbc, 0xbd): pop(); push(('?',))
        elif op == 0xbe: pop(); push(('?',))
        elif op == 0xbf: st.clear()
        elif op == 0xc1: pop(); push(('?',))
        elif op in (0xc2, 0xc3): pop()
        elif op == 0xc5: pop(code[i+3]); push(('?',))
        elif op in (0xc6, 0xc7): pop()
        elif op == 0xc9: push(('?',))
        i = nxt
    return out, dynamic

# ------------------------------------------------------------------ platform index (lazy)
class Index:
    def __init__(self):
        self.loc = {}          # internal name -> (zip path or None, entry or file path)
        self.info = {}         # internal name -> ClassInfo or None
        self.versions = {}     # bundle symbolic name -> version string
        self.zips = {}
    def add_path(self, p):
        if os.path.isdir(p):
            kids = os.listdir(p)
            if 'META-INF' in kids and not any(k.endswith('.jar') for k in kids):
                self._add_dir_bundle(p)
            else:
                for name in kids:
                    q = os.path.join(p, name)
                    if name.endswith('.jar'): self._add_jar(q)
                    elif os.path.isdir(q): self._add_dir_bundle(q)
        elif p.endswith('.jar'): self._add_jar(p)
    def _manifest(self, text):
        text = text.replace('\r\n', '\n').replace('\n ', '')
        m = {}
        for line in text.split('\n'):
            if ':' in line:
                k, v = line.split(':', 1); m[k.strip()] = v.strip()
        bsn = m.get('Bundle-SymbolicName', '').split(';')[0].strip()
        if bsn: self.versions[bsn] = m.get('Bundle-Version', '0')
    def _add_jar(self, p):
        try: z = zipfile.ZipFile(p)
        except zipfile.BadZipFile: return
        self.zips[p] = z
        for n in z.namelist():
            if n.endswith('.class'): self.loc.setdefault(n[:-6], (p, n))
        try: self._manifest(z.read('META-INF/MANIFEST.MF').decode('utf-8', 'replace'))
        except KeyError: pass
    def _add_dir_bundle(self, p):
        for dp, _, fs in os.walk(p):
            for f in fs:
                if f.endswith('.class'):
                    q = os.path.join(dp, f)
                    self.loc.setdefault(os.path.relpath(q, p)[:-6].replace(os.sep, '/'), (None, q))
        mf = os.path.join(p, 'META-INF', 'MANIFEST.MF')
        if os.path.isfile(mf):
            self._manifest(open(mf, encoding='utf-8', errors='replace').read())
    def has(self, name): return name in self.loc
    def get(self, name):
        if name in self.info: return self.info[name]
        ci = None
        if name in self.loc:
            zp, ent = self.loc[name]
            data = self.zips[zp].read(ent) if zp else open(ent, 'rb').read()
            try: ci = parse_class(data)
            except Exception: ci = None
        self.info[name] = ci
        return ci
    def resolve(self, owner, name, desc, field, provided=frozenset()):
        """'found' | 'missing' | 'unknown' (hierarchy leaves the index)"""
        seen = set(); todo = [owner]; unknown = False
        while todo:
            c = todo.pop(0)
            if c in seen: continue
            seen.add(c)
            if (c, name, desc, field) in provided: return 'found'
            if c == 'java/lang/Object':
                # every chain ends here; only Object's own members can come from it
                if not field and name in OBJECT_METHODS: return 'found'
                continue
            ci = self.get(c)
            if ci is None:
                unknown = True   # other JDK or unindexed superclass: the member may live there
                continue
            if (name, desc) in (ci.fields if field else ci.methods): return 'found'
            if name == '<init>': break
            if ci.sup: todo.append(ci.sup)
            todo.extend(ci.ifaces)
        return 'unknown' if unknown else 'missing'

OS_PKGS = {'win32': ('org/eclipse/swt/internal/win32/', 'org/eclipse/swt/internal/ole/'),
           'linux': ('org/eclipse/swt/internal/gtk/', 'org/eclipse/swt/internal/gtk3/', 'org/eclipse/swt/internal/gtk4/', 'org/eclipse/e4/ui/swt/gtk/'),
           'macosx': ('org/eclipse/swt/internal/cocoa/',)}
def other_os(name):
    """True when the class belongs to the window system of a different OS than the target"""
    if not target_os: return False
    return any(name.startswith(pfx) for osn, pfxs in OS_PKGS.items() if osn != target_os for pfx in pfxs)

old = Index(); new = Index()
for p in old_paths: old.add_path(p)
for p in new_paths: new.add_path(p)
if target_os is None:
    for probe, osn in (('org/eclipse/swt/internal/win32/OS', 'win32'), ('org/eclipse/swt/internal/gtk/GTK', 'linux'), ('org/eclipse/swt/internal/cocoa/OS', 'macosx')):
        if new.has(probe): target_os = osn; break

# ------------------------------------------------------------------ DevStyle side
CLS = re.compile(r"^((?:org/eclipse|org/w3c|org/apache|com/ibm)/[A-Za-z0-9_/$]+)$")
DESC = re.compile(r"L((?:org/eclipse|org/w3c|org/apache|com/ibm)/[A-Za-z0-9_/$]+);")
DOT = re.compile(r"^((?:org\.eclipse|org\.w3c|org\.apache|com\.ibm)\.[A-Za-z0-9_.$]+)$")

# weaver gates from plugin.xml: (bundle dir, path-without-.class) -> gate dict
class Ver:
    def __init__(self, s):
        parts = (s or '0').strip().split('.', 3)
        nums = []
        for p in parts[:3]:
            try: nums.append(int(p))
            except ValueError: nums.append(0)
        while len(nums) < 3: nums.append(0)
        self.k = (nums[0], nums[1], nums[2], parts[3] if len(parts) > 3 else '')
    def __lt__(self, o): return self.k < o.k
    def __le__(self, o): return self.k <= o.k
def in_range(rng, ver):
    rng = rng.strip(); v = Ver(ver)
    if rng[0] in '[(':
        lo, hi = rng[1:-1].split(','); lo_inc = rng[0] == '['; hi_inc = rng[-1] == ']'
        lo, hi = Ver(lo), Ver(hi)
        return (lo <= v if lo_inc else lo < v) and (v <= hi if hi_inc else v < hi)
    return Ver(rng) <= v

gates = {}; woven_of = {}
def gate_eval(os_attr, bundle, rng, enabled):
    why = []
    if enabled is not None and enabled.lower() == 'false': why.append('enabled=false')
    if os_attr and target_os and os_attr != target_os: why.append('os=%s' % os_attr)
    if rng:
        v = new.versions.get(bundle or '')
        if v is None: why.append('%s absent' % bundle)
        elif not in_range(rng, v): why.append('%s %s not in %s' % (bundle, v, rng))
    return (len(why) == 0, ', '.join(why))
for bdir in sorted(os.listdir(root)):
    px = os.path.join(root, bdir, 'plugin.xml')
    if not os.path.isfile(px): continue
    try: tree = ET.parse(px)
    except ET.ParseError: continue
    for el in tree.iter():
        if el.tag == 'class-weaver' and el.get('weaver'):
            key = (bdir, el.get('weaver').replace('.', '/'))
            g = gate_eval(el.get('os'), el.get('bundle'), el.get('bundle-version'), el.get('enabled'))
            woven = [w.get('name').replace('.', '/') for w in el.iter('woven-class') if w.get('name')]
            if g[0] and woven and not any(new.has(w) for w in woven):
                g = (False, 'woven class %s absent' % ', '.join(woven))   # silently inert (4.41 CSSEngineFixer)
            gates[key] = g; woven_of[key] = woven
        elif el.tag == 'class-replacement':
            for ic in el.iter('injected-class'):
                if ic.get('path'):
                    key = (bdir, ic.get('path').lstrip('/').rsplit('.class', 1)[0])
                    g = gate_eval(el.get('os'), ic.get('bundle'), ic.get('bundle-version'), None)
                    if g[0] and ic.get('name') and not new.has(ic.get('name').replace('.', '/')):
                        g = (False, 'replaced class %s absent' % ic.get('name'))
                    gates[key] = g

def gate_for(bdir, inner):
    """gate of a DevStyle class file (nested classes inherit the outer's)"""
    k = (bdir, inner)
    if k in gates: return gates[k]
    if '$' in inner.rsplit('/', 1)[-1]:
        k = (bdir, inner.split('$', 1)[0])
        if k in gates: return gates[k]
    return None

# own classes join both indexes (hierarchies run into the platform)
own_files = []
for dp, _, fs in os.walk(root):
    for f in fs:
        if f.endswith('.class'): own_files.append(os.path.join(dp, f))
own_info = {}; own_names = set()
for path in own_files:
    try: ci = parse_class(open(path, 'rb').read(), want_code=not classes_only)
    except Exception: ci = None
    if ci is None: continue
    own_info[path] = ci
    rel = os.path.relpath(path, root).replace(os.sep, '/')
    if rel.split('/', 1)[1][:-6] != ci.name:
        continue   # class-replacement payload: a DevStyle copy of a PLATFORM class, never "own"
    own_names.add(ci.name)
    for ix in (old, new):
        if ci.name not in ix.loc:
            ix.loc[ci.name] = (None, path); ix.info[ci.name] = ci

removed_classes = collections.defaultdict(set); never_classes = collections.Counter()
removed_members = collections.defaultdict(set); never_members = collections.Counter()
dynamic_total = 0; checked_members = 0

# pass 1: read every DevStyle class — references, weaver emissions, declarations
scans = []
for path, ci in own_info.items():
    rel = os.path.relpath(path, root).replace(os.sep, '/')
    bdir, inner = rel.split('/', 1); inner = inner[:-6]
    gate = gate_for(bdir, inner)
    payload = inner != ci.name
    if gate is None and payload:
        # a class file stored under a path that is not its own name is a
        # class-replacement payload; nothing in plugin.xml injects this one
        gate = (False, 'replacement payload not declared in plugin.xml (never loaded)')
    cp = ci.cp
    class_refs = set(); member_refs = set(); decls = set(); emitted_any = False
    for k, e in enumerate(cp):
        if not e: continue
        if e[0] == 'c':
            s_ = cp[e[1]][1].lstrip('[')
            if s_.startswith('L') and s_.endswith(';'): s_ = s_[1:-1]
            if CLS.match(s_): class_refs.add((s_, 'class'))
        elif e[0] == 's':
            s_ = cp[e[1]][1]
            if CLS.match(s_): class_refs.add((s_, 'string'))
            elif DOT.match(s_): class_refs.add((s_.replace('.', '/'), 'string'))
        elif e[0] == 'u':
            for m in DESC.findall(e[1]): class_refs.add((m, 'desc'))
        elif e[0] in ('F', 'M', 'I'):
            owner = cp_class(cp, e[1]); nt = cp[e[2]]
            if owner and not owner.startswith('['):
                member_refs.add(('direct', e[0] == 'F', owner, cp[nt[1]][1], cp[nt[2]][1]))
    if not classes_only:
        for nm, ds, code in ci.codes:
            try: emitted, dyn = scan_emitted(code, cp)
            except Exception: emitted, dyn = [], 0
            dynamic_total += dyn
            for kind, owner, mname, mdesc in emitted:
                if kind.startswith('decl-'):
                    decls.add((kind == 'decl-field', mname, mdesc)); emitted_any = True
                elif kind == 'type':
                    emitted_any = True
                    s_ = owner.lstrip('[')
                    if s_.startswith('L') and s_.endswith(';'): s_ = s_[1:-1]
                    if CLS.match(s_): class_refs.add((s_, 'emitted'))
                else:
                    emitted_any = True
                    member_refs.add(('emitted', kind == 'field', owner, mname, mdesc))
        if emitted_any and gate is None:
            # emits bytecode but no class-weaver names it: it only runs if a
            # declared weaver delegates to it (revstyle's shims subclass the
            # vendor weavers and neutralise what they emit) — check by hand
            gate = (False, 'weaver not declared in plugin.xml; runs only via a declared weaver, check by hand')
    scans.append((rel, bdir, inner, ci, gate, payload, class_refs, member_refs, decls))

# members DevStyle itself adds to platform classes: fields/methods an ACTIVE
# weaver declares on its woven classes, and everything an ACTIVE replacement
# payload defines on the class it replaces
provided = set()
for rel, bdir, inner, ci, gate, payload, class_refs, member_refs, decls in scans:
    if gate is None or not gate[0]: continue
    outer = inner.split('$', 1)[0] if '$' in inner.rsplit('/', 1)[-1] else inner
    for w in woven_of.get((bdir, outer), []):
        for is_field, nm, ds in decls: provided.add((w, nm, ds, is_field))
    if payload:
        for nm, ds in ci.fields: provided.add((ci.name, nm, ds, True))
        for nm, ds in ci.methods: provided.add((ci.name, nm, ds, False))

# pass 2: resolve
for rel, bdir, inner, ci, gate, payload, class_refs, member_refs, decls in scans:
    tag = '' if gate is None else (' [weaver active]' if gate[0] else ' [weaver INACTIVE on new: %s]' % gate[1])
    outer = inner.split('$', 1)[0] if '$' in inner.rsplit('/', 1)[-1] else inner
    my_woven = woven_of.get((bdir, outer), [])
    for s_, kind in class_refs:
        if new.has(s_) or other_os(s_): continue
        if old.has(s_): removed_classes[s_].add((rel, kind + tag))
        else: never_classes[s_] += 1
    for how, is_field, owner, mname, mdesc in member_refs:
        if owner.startswith(SKIP_OWNER) or other_os(owner): continue
        if not (owner.startswith(PLAT) or owner in own_names): continue
        if not new.has(owner): continue          # pass 1 territory
        checked_members += 1
        rn = new.resolve(owner, mname, mdesc, is_field, provided)
        if rn != 'missing': continue
        key = '%s.%s %s' % (owner, mname, mdesc)
        if single:
            # a weaver's references INTO the class it weaves are its own business:
            # it renames, adds and version-branches members there in ways a static
            # pass cannot follow (the two-release mode still catches a removed one)
            if how == 'emitted' and any(owner == w or owner.startswith(w + '$') for w in my_woven): continue
            removed_members[key].add((rel, how + tag)); continue
        ro = old.resolve(owner, mname, mdesc, is_field, provided) if old.has(owner) else 'missing'
        if ro == 'found': removed_members[key].add((rel, how + tag))
        else: never_members[key] += 1

def side(paths): return ', '.join(os.path.basename(p.rstrip('/')) or p for p in paths)
print("== target OS for weaver gates: %s; new bundle versions known: %d ==" % (target_os or 'unknown', len(new.versions)))
print("\n== CLASSES referenced by DevStyle, present in OLD (%s), MISSING in NEW (%s) ==" % (side(old_paths), side(new_paths)))
if single: print("   (--single: informational — a removed class only shows when OLD is a real previous release)")
active_findings = 0; class_findings = 0; known = []; active_keys = set()
base = set()
if baseline:
    for line in open(baseline, encoding='utf-8'):
        line = line.strip()
        if line and not line.startswith('#'): base.add(line)
for s in sorted(removed_classes):
    print(s)
    for rel, kind in sorted(removed_classes[s]):
        print("    %-8s %s" % (kind.split(' ')[0], rel + (' ' + kind.split(' ', 1)[1] if ' ' in kind else '')))
        if 'INACTIVE' not in kind: class_findings += 1
if not removed_classes: print("  (none)")
if not classes_only:
    print("\n== MEMBERS referenced by DevStyle (directly or emitted by a weaver) %s ==" % ("MISSING in NEW (owner class present; members DevStyle weaves in excluded)" if single else "that resolve in OLD but NOT in NEW"))
    print("   (%d members DevStyle itself weaves into platform classes are treated as present)" % len(provided))
    print("   (%d platform member references checked; %d weaver visit calls had non-constant operands and were skipped)" % (checked_members, dynamic_total))
    for key in sorted(removed_members):
        if key in base: known.append(key); continue
        print(key)
        for rel, how in sorted(removed_members[key]):
            print("    %-8s %s" % (how.split(' ')[0], rel + (' ' + how.split(' ', 1)[1] if ' ' in how else '')))
            if 'INACTIVE' not in how:
                active_findings += 1; active_keys.add(key)
    if not removed_members: print("  (none)")
    if known:
        print("\n== members unresolved but listed in the baseline %s (known, not counted) ==" % baseline)
        for key in known: print("  " + key)
    if write_baseline:
        with open(write_baseline, 'w') as f:
            for key in sorted(active_keys): f.write(key + '\n')
        print("\nwrote %d active member key(s) to %s" % (len(active_keys), write_baseline))
    print("\n== members unresolved in BOTH (pre-existing: woven-in by DevStyle itself, optional deps; top 10) ==")
    for k, c in never_members.most_common(10): print("  %4d  %s" % (c, k))
print("\n== classes absent from BOTH (pre-existing optional deps, by class; top 10) ==")
for s, c in never_classes.most_common(10): print("  %4d  %s" % (c, s))
if not single: active_findings += class_findings
print("\n%d active finding(s)%s%s" % (active_findings, '' if single else ' (classes + members)', (' (%d known from baseline not counted)' % len(known)) if baseline else ''))
if fail and active_findings: sys.exit(1)
