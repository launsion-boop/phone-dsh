#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Capture a firmware builder pack from one finished ESP-IDF build.

Runs on the build computer, after `idf.py build`, with the same native toolchain.
It recompiles every project source under --sources once through wrap.sh to record
the exact cc1/cc1plus/as arguments and every file they read, relinks once to record
the ld arguments and inputs, and writes:

  project.bin  sources + headers + one compile job per source   (loadBundle in core.js)
  sdk.bin      prebuilt archives, linker scripts, ld arguments   (loadLink in core.js)
  manifest.json

The WebAssembly tools (cc1.wasm, cc1plus.wasm when a job needs it, as.wasm, ar.wasm,
ld.wasm) are copied from --wasm and listed in the manifest. The pack fixes the target,
the source list and every flag; the phone only recompiles those sources.
"""
import argparse, hashlib, json, os, re, shlex, shutil, struct, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.realpath(__file__))
SKIP_PREFIXES = ("/proc/", "/dev/", "/sys/", "/etc/", "/lib/", "/lib64/", "/usr/lib/", "/usr/share/locale", "/tmp/")
OPEN_RE = re.compile(r'^\d+\s+open(?:at)?\((?:AT_FDCWD|-?\d+), "((?:[^"\\]|\\.)*)", ([A-Z_|]+)(?:, \d+)?\) = (\d+)')


def sha(b): return hashlib.sha256(b).hexdigest()


def read_args(prefix):
    return [l for l in open(prefix + ".args").read().split("\n") if l != ""]


def opened(prefix, cwd):
    """Regular files the traced process opened read-only and successfully."""
    out = []
    for line in open(prefix + ".strace"):
        m = OPEN_RE.match(line)
        if not m or "O_WRONLY" in m.group(2) or "O_RDWR" in m.group(2) or "O_CREAT" in m.group(2): continue
        p = m.group(1).encode().decode("unicode_escape")
        full = p if os.path.isabs(p) else os.path.normpath(os.path.join(cwd, p))
        if full.startswith(SKIP_PREFIXES) or not os.path.isfile(full): continue
        out.append(p if os.path.isabs(p) else full)
    return out


def is_tool_file(p, _=None):
    """The native toolchain's own executables and shared libraries (host ELF, x86-64) are not inputs."""
    with open(p, "rb") as f: h = f.read(20)
    return h[:4] == b"\x7fELF" and h[18] == 62


def ar_members(data):
    assert data[:8] == b"!<arch>\n", "not an ar archive"
    p, longnames, out = 8, b"", []
    while p < len(data):
        h = data[p:p + 60]; name = h[:16].decode().rstrip(); size = int(h[48:58]); body = data[p + 60:p + 60 + size]; p += 60 + size + (size & 1)
        if name in ("/", "/SYM64/"): continue
        if name == "//": longnames = body; continue
        if name.startswith("/"): o = int(name[1:]); name = longnames[o:longnames.index(b"/\n", o)].decode()
        else: name = name.rstrip("/")
        out.append((name, body))
    return out


def write_bundle(path, head, files):
    blob = bytearray(); index = []
    for p, data in files:
        index.append([p, len(blob), len(data)]); blob.extend(data)
    head = dict(head, files=index)
    raw = json.dumps(head, separators=(",", ":")).encode()
    with open(path, "wb") as f: f.write(struct.pack("<I", len(raw)) + raw + blob)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--build", required=True, help="ESP-IDF build directory (has compile_commands.json, build.ninja)")
    ap.add_argument("--sources", required=True, help="directory whose sources become phone compile jobs (e.g. <project>/main)")
    ap.add_argument("--elf", required=True, help="ELF name produced by the build, e.g. xiaozhi.elf")
    ap.add_argument("--chip", required=True, choices=["esp32s3", "esp32c3"])
    ap.add_argument("--project", required=True, help="human-readable project name for the manifest")
    ap.add_argument("--toolchain", required=True, help="toolchain description for the manifest")
    ap.add_argument("--idf", required=True, help="ESP-IDF version for the manifest")
    ap.add_argument("--wasm", required=True, help="directory with cc1.wasm, cc1plus.wasm, as.wasm, ar.wasm, ld.wasm")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    build = os.path.realpath(a.build); sources = os.path.realpath(a.sources)
    os.makedirs(a.out, exist_ok=True)
    work = tempfile.mkdtemp(prefix="fwb-capture-")
    env = dict(os.environ, FWB_DIR=work)
    wrap = os.path.join(HERE, "wrap.sh")

    # ---- compile jobs -------------------------------------------------------------
    db = json.load(open(os.path.join(build, "compile_commands.json")))
    entries = sorted((e for e in db if os.path.realpath(e["file"]).startswith(sources + "/")), key=lambda e: e["file"])
    if not entries: sys.exit(f"no compile commands under {sources}")
    jobs, files, dirs, native_obj = [], {}, set(), {}
    for n, e in enumerate(entries):
        cmd = shlex.split(e.get("command") or shlex.join(e["arguments"]))
        i = cmd.index("-o"); gccobj = os.path.normpath(os.path.join(e["directory"], cmd[i + 1]))
        tag = f"{n:03d}"; tmpobj = f"{work}/{tag}.native.o"
        cmd = cmd[:i] + ["-o", tmpobj] + cmd[i + 2:] + ["-wrapper", wrap]
        r = subprocess.run(cmd, cwd=e["directory"], env=dict(env, FWB_TAG=tag), capture_output=True, text=True)
        if r.returncode != 0: sys.exit(f"recompile failed: {e['file']}\n{r.stderr[-2000:]}")
        tool = "cc1plus" if os.path.exists(f"{work}/{tag}.cc1plus.args") else "cc1"
        cargs = read_args(f"{work}/{tag}.{tool}"); aargs = read_args(f"{work}/{tag}.as")
        s, o, d = f"/fwb/{tag}.s", f"/fwb/{tag}.o", f"/fwb/{tag}.d"
        k = cargs.index("-o"); asm_native = cargs[k + 1]; cargs[k + 1] = s
        for flag in ("-MD", "-MMD", "-MF"):
            for j, x in enumerate(cargs[:-1]):
                if x == flag: cargs[j + 1] = d
        k = aargs.index("-o"); aargs[k + 1] = o
        aargs = [s if x == asm_native else x for x in aargs]
        if asm_native in aargs: sys.exit("as input not rewritten")
        for p in opened(f"{work}/{tag}.{tool}", e["directory"]) + opened(f"{work}/{tag}.as", e["directory"]):
            if p.startswith(work) or is_tool_file(p): continue
            files[p] = True
        for j, x in enumerate(cargs):   # include directories must exist even when empty
            if x in ("-I", "-isystem", "-iquote", "-idirafter", "-imultilib", "-iprefix") and j + 1 < len(cargs) and os.path.isdir(cargs[j + 1]): dirs.add(cargs[j + 1])
            elif x.startswith("-I") and len(x) > 2 and os.path.isdir(x[2:]): dirs.add(x[2:])
            elif x == "-dumpdir" and j + 1 < len(cargs): dirs.add(os.path.join(e["directory"], cargs[j + 1]))
        dirs.add(e["directory"])
        native_obj[n] = open(tmpobj, "rb").read()
        if native_obj[n] != open(gccobj, "rb").read(): sys.exit(f"recompiled object differs from the build's: {gccobj}")
        jobs.append({"n": n, "src": e["file"], "cwd": e["directory"], "tool": tool, "cc1": cargs, "as": aargs, "s": s, "o": o})
        print(f"[{n + 1}/{len(entries)}] {tool} {os.path.relpath(e['file'], sources)}", flush=True)
    dirs.add("/fwb")
    proj_files = [(p, open(p, "rb").read()) for p in sorted(files)]
    write_bundle(os.path.join(a.out, "project.bin"), {"dirs": sorted(dirs), "jobs": jobs}, proj_files)

    # ---- link -----------------------------------------------------------------------
    q = subprocess.run(["ninja", "-C", build, "-t", "commands", a.elf], capture_output=True, text=True, check=True).stdout.strip().split("\n")[-1]
    # CMake/ninja wraps the link as `: && [cd DIR && ]<g++ ...> && :`
    lcwd, lcmd = build, None
    for part in (x.strip() for x in q.split(" && ")):
        if part == ":": continue
        if part.startswith("cd "): lcwd = os.path.join(build, shlex.split(part)[1]); continue
        toks = shlex.split(part)
        if "-o" in toks and os.path.basename(toks[toks.index("-o") + 1]) == a.elf: lcmd = toks
    if lcmd is None: sys.exit(f"no link command for {a.elf} in: {q[:300]}")
    i = lcmd.index("-o"); lcmd[i + 1] = f"{work}/link.elf"
    r = subprocess.run(lcmd + ["-wrapper", wrap], cwd=lcwd, env=dict(env, FWB_TAG="link"), capture_output=True, text=True)
    if r.returncode != 0: sys.exit(f"relink failed\n{r.stderr[-2000:]}")
    largs = read_args(f"{work}/link.collect2")
    drop, out_args = 0, []
    for x in largs:   # collect2-only options; the wasm ld is plain GNU ld without the LTO plugin
        if drop: drop -= 1; continue
        if x == "-plugin": drop = 1; continue
        if x.startswith("-plugin-opt=") or x in ("-flto", "-fno-lto") or x.startswith("-flto="): continue
        out_args.append(x)
    elf_out = f"/out/{a.elf}"
    out_args = [elf_out if x == f"{work}/link.elf" else x for x in out_args]
    by_content = {}
    for n, b in native_obj.items(): by_content.setdefault(b, n)
    sdk_files, archives, direct = [], [], {}
    seen = set()
    for p in opened(f"{work}/link.collect2", lcwd):
        if p in seen or p.startswith(work) or is_tool_file(p): continue
        seen.add(p); data = open(p, "rb").read()
        if p.endswith(".a") and data[:8] == b"!<arch>\n":
            ms = ar_members(data)
            if any(b in by_content for _, b in ms):
                spec = []; k = len(archives)
                for idx, (name, body) in enumerate(ms):
                    if body in by_content: spec.append({"name": name, "job": by_content[body]})
                    else:
                        pre = f"/ar/{k}/{idx}/{name}"; sdk_files.append((pre, body)); spec.append({"name": name, "pre": pre})
                archives.append({"path": p, "members": spec}); continue
        if data in by_content: direct[p] = by_content[data]; continue
        sdk_files.append((p, data))
    used = {m["job"] for ar in archives for m in ar["members"] if "job" in m} | set(direct.values())
    unused = sorted(set(native_obj) - used)
    if unused: print("note: jobs not linked:", [jobs[n]["src"] for n in unused])
    write_bundle(os.path.join(a.out, "sdk.bin"), {"archives": archives, "direct": direct, "ldArgs": out_args, "cwd": lcwd, "elf": elf_out, "chip": a.chip}, sdk_files)
    native_elf = open(f"{work}/link.elf", "rb").read()
    if native_elf != open(os.path.join(build, a.elf), "rb").read(): sys.exit("relinked ELF differs from the build's ELF")

    # ---- manifest ---------------------------------------------------------------------
    names = ["cc1.wasm", "as.wasm", "ar.wasm", "ld.wasm"] + (["cc1plus.wasm"] if any(j["tool"] == "cc1plus" for j in jobs) else [])
    if not any(j["tool"] == "cc1" for j in jobs): names.remove("cc1.wasm")
    for nm in names: shutil.copyfile(os.path.join(a.wasm, nm), os.path.join(a.out, nm))
    image = os.path.join(build, os.path.splitext(a.elf)[0] + ".bin")
    manifest = {"format": 1, "target": a.chip, "project": a.project, "toolchain": a.toolchain, "idf": a.idf,
                "image": os.path.basename(image),
                "files": {nm: {"bytes": os.path.getsize(os.path.join(a.out, nm)), "sha256": sha(open(os.path.join(a.out, nm), "rb").read())} for nm in names + ["sdk.bin", "project.bin"]},
                "reference": {"elf_sha256": sha(native_elf), "image_sha256": sha(open(image, "rb").read())}}
    json.dump(manifest, open(os.path.join(a.out, "manifest.json"), "w"), indent=1)
    print(f"{len(jobs)} jobs ({sum(j['tool'] == 'cc1plus' for j in jobs)} C++), {len(proj_files)} project files, "
          f"{len(sdk_files)} sdk files, {len(archives)} rebuilt archives; pack in {a.out}")
    shutil.rmtree(work)


if __name__ == "__main__":
    main()
