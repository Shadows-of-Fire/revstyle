#!/usr/bin/env python3
"""refsweep.py — which platform classes that DevStyle references disappeared
between two Eclipse releases?

usage: python3 -I lib/refsweep.py <devstyle-classes-root> <old plugins/> <new plugins/>

<devstyle-classes-root> holds the DevStyle bundles' class files, one subdir
per bundle (unzip -qo plugins/com.genuitec*.jar '*.class' -d <root>/<bundle>).
Every class file's constant pool is scanned for org.eclipse / org.w3c /
org.apache / com.ibm names in three places — Class entries (direct
references), descriptors/signatures, and String constants (the ASM weavers
name their targets and INVOKE owners as strings) — and each name is checked
against the class index of both plugins/ dirs (jars and exploded bundles).
Output: names present in <old> and missing in <new>, with the DevStyle class
that references them and how; then the most-referenced names absent from
both (pre-existing optional dependencies such as win32/cocoa internals).
Diagnostic only — no Genuitec bytes leave the machine. Pure stdlib.
"""
import sys, os, re, struct, zipfile, collections
root, old_dir, new_dir = sys.argv[1:4]
def index(plugins):
    idx=set()
    for name in os.listdir(plugins):
        p=os.path.join(plugins,name)
        if name.endswith('.jar'):
            try:
                with zipfile.ZipFile(p) as z:
                    for n in z.namelist():
                        if n.endswith('.class'): idx.add(n[:-6])
            except zipfile.BadZipFile: pass
        elif os.path.isdir(p):
            for dp,_,fs in os.walk(p):
                for f in fs:
                    if f.endswith('.class'):
                        idx.add(os.path.relpath(os.path.join(dp,f),p)[:-6].replace(os.sep,'/'))
    return idx
def cp_entries(data):
    n=struct.unpack('>H',data[8:10])[0]; i=10; k=1; ents={}
    while k<n:
        t=data[i]
        if t==1:
            l=struct.unpack('>H',data[i+1:i+3])[0]; ents[k]=('u',data[i+3:i+3+l].decode('utf-8','replace')); i+=3+l
        elif t in (3,4): i+=5
        elif t in (5,6): i+=9; k+=1
        elif t==7: ents[k]=('c',struct.unpack('>H',data[i+1:i+3])[0]); i+=3
        elif t==8: ents[k]=('s',struct.unpack('>H',data[i+1:i+3])[0]); i+=3
        elif t in (9,10,11,12,17,18): i+=5
        elif t==15: i+=4
        elif t in (16,19,20): i+=3
        else: raise ValueError('tag %d'%t)
        k+=1
    return ents
CLS=re.compile(r"^((?:org/eclipse|org/w3c|org/apache|com/ibm)/[A-Za-z0-9_/$]+)$"); DESC=re.compile(r"L((?:org/eclipse|org/w3c|org/apache|com/ibm)/[A-Za-z0-9_/$]+);"); DOT=re.compile(r"^((?:org\.eclipse|org\.w3c|org\.apache|com\.ibm)\.[A-Za-z0-9_.$]+)$")
old=index(old_dir); new=index(new_dir)
# DevStyle's own classes count as present in both (the new install has no DevStyle yet)
own=set()
for dp,_,fs in os.walk(root):
    for f in fs:
        if f.endswith('.class'): own.add(os.path.relpath(os.path.join(dp,f),root).split('/',1)[1][:-6])
old|=own; new|=own
removed=collections.defaultdict(set); never=collections.Counter()
for dp,_,fs in os.walk(root):
    for f in fs:
        if not f.endswith('.class'): continue
        path=os.path.join(dp,f); rel=os.path.relpath(path,root)
        data=open(path,'rb').read(); ents=cp_entries(data)
        refs=set()
        for k,(t,v) in ents.items():
            if t=='c':
                s=ents[v][1].lstrip('[')
                if s.startswith('L') and s.endswith(';'): s=s[1:-1]
                if CLS.match(s): refs.add((s,'class'))
            elif t=='s':
                s=ents[v][1]
                if CLS.match(s): refs.add((s,'string'))
                elif DOT.match(s): refs.add((s.replace('.','/'),'string'))
            elif t=='u':
                for m in DESC.findall(v): refs.add((m,'desc'))
        for s,kind in refs:
            if s in new: continue
            if s in old: removed[s].add((rel,kind))
            else: never[s]+=1
print("== referenced by DevStyle, present in %s, MISSING in %s =="%(old_dir.split('/')[-2],new_dir.split('/')[-2]))
for s in sorted(removed):
    print(s)
    for rel,kind in sorted(removed[s]): print("    %-6s %s"%(kind,rel))
print("\n== referenced but absent from BOTH (pre-existing optional deps, by class; top 15) ==")
for s,c in never.most_common(15): print("  %4d  %s"%(c,s))
