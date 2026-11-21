#!/bin/bash
# SPDX-License-Identifier: MIT
# Builds the riscv32-esp-elf (ESP32-C3) cc1, cc1plus, as, ar and ld for wasm32-wasip1,
# the WebAssembly tools of the xiaozhi / AI Passport firmware builder pack.
#
# Inputs (same as the ESP32-S3 pack's xtensa tools):
#   WASI_SDK   wasi-sdk 29 (x86_64-linux)
#   COMPAT     directory with compat.h and libcompat.a (WASI stubs, a lexical realpath that
#              honours $PWD, and a stable qsort), built with that wasi-sdk
#   GCC_SRC    Espressif gcc esp-15.2.0_20251204 source tree
#   BU_SRC     Espressif binutils-gdb esp-2.45.0_20251204 source tree, with the WASI patch in
#              binutils/rename.c (smart_rename reopens `from` by name when dup() gave -1)
#   FAKEINC    directory with a setjmp.h stub (WASI has no setjmp without exception handling)
#   NATIVE     the native riscv32-esp-elf toolchain of the same release (configure probes only)
#   OUT        build directory; the stripped tools land in $OUT/wasm
#
# Every choice below is there because the tools must produce the native toolchain's bytes:
#   * configure options mirror `riscv32-esp-elf-gcc -v` (rv32gc / ilp32, c and c++);
#   * ac_cv_func_realpath=yes: without HAVE_REALPATH libiberty's lrealpath returns a constant and
#     cc1 reports "input file is the same as output file";
#   * physmem-wasi.o: WASI reports 0 bytes of RAM, so GCC would size its garbage collector for a
#     tiny host; GC timing changes var-tracking output (.debug_loc). 4 GiB gives the native values
#     (ggc-min-expand 100, ggc-min-heapsize 128 MiB) on any build computer with >= 1 GiB;
#   * GAS decides whether to fold a symbol difference (e.g. a CFI advance) into a constant or emit
#     SET/SUB relocations by whether both labels sit in one frag, and frags split where an obstack
#     chunk runs out, which depends on the host's struct sizes. The copy of $BU_SRC is patched so
#     that, on WASI only, the frag header and the obstack chunk header have their x86-64 sizes
#     (120 and 16 bytes);
#   * BFD's string hash is `unsigned long`: 64-bit on the build computer, 32-bit on wasm32, so
#     buckets differ and ld writes global symbols in another order. The same copy computes it in
#     64 bits on WASI (bfd_hash_value);
#   * libcpp and libcody are built directly: the in-tree gettext does not build for WASI and is
#     not needed with --disable-nls.
set -euo pipefail
: "${WASI_SDK:?}" "${COMPAT:?}" "${GCC_SRC:?}" "${BU_SRC:?}" "${FAKEINC:?}" "${NATIVE:?}" "${OUT:?}"
mkdir -p "$OUT/wasm"
WF="--target=wasm32-wasip1 --sysroot=$WASI_SDK/share/wasi-sysroot"
EM="-D_WASI_EMULATED_MMAN -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS -D_WASI_EMULATED_GETPID"
LIBS="-L$COMPAT -lcompat -lwasi-emulated-mman -lwasi-emulated-signal -lwasi-emulated-process-clocks -lwasi-emulated-getpid"
export CC="$WASI_SDK/bin/clang $WF" CXX="$WASI_SDK/bin/clang++ $WF" AR=$WASI_SDK/bin/llvm-ar RANLIB=$WASI_SDK/bin/llvm-ranlib NM=$WASI_SDK/bin/llvm-nm
export CC_FOR_BUILD=gcc CXX_FOR_BUILD=g++ ac_cv_func_realpath=yes ac_cv_func_psignal=yes ac_cv_func_strsignal=yes

# ---- binutils: as, ar, ld ----------------------------------------------------------------
if [ ! -d "$OUT/bu-src" ]; then
  cp -a "$BU_SRC" "$OUT/bu-src"
  python3 - "$OUT/bu-src" <<'PY'
import sys
root = sys.argv[1]
def patch(rel, anchor, before):
    p = f"{root}/{rel}"; s = open(p).read()
    assert s.count(anchor) == 1, (rel, anchor)
    open(p, "w").write(s.replace(anchor, before + anchor))
patch("gas/frags.h", "  char fr_literal[1];",
      "#ifdef __wasi__\n  /* phoneDSH: x86-64 frag header size (120 bytes), see build-wasm-toolchain-riscv.sh. */\n"
      "  char pdsh_host64_pad[120 - 84];\n#endif\n")
for rel, old, new in [
    ("bfd/bfd-in2.h", "     table.  */\n  unsigned long hash;\n};", "     table.  */\n  bfd_hash_value hash;\n};"),
    ("bfd/bfd-in2.h", "    const char *,\n    unsigned long /*hash*/);", "    const char *,\n    bfd_hash_value /*hash*/);"),
    ("bfd/hash.c", "static inline unsigned long\nbfd_hash_hash", "static inline bfd_hash_value\nbfd_hash_hash"),
    ("bfd/hash.c", "  const unsigned char *s;\n  unsigned long hash;", "  const unsigned char *s;\n  bfd_hash_value hash;"),
    ("bfd/hash.c", "{\n  unsigned long hash;\n  struct bfd_hash_entry *hashp;", "{\n  bfd_hash_value hash;\n  struct bfd_hash_entry *hashp;"),
    ("bfd/hash.c", "\t\t const char *string,\n\t\t unsigned long hash)", "\t\t const char *string,\n\t\t bfd_hash_value hash)")]:
    p = f"{root}/{rel}"; t = open(p).read(); assert t.count(old) == 1, (rel, old); open(p, "w").write(t.replace(old, new))
patch("bfd/bfd-in2.h", "struct bfd_hash_entry\n{",
      "/* phoneDSH: 64-bit BFD string hash on WASI too, see build-wasm-toolchain-riscv.sh. */\n"
      "#ifdef __wasi__\ntypedef unsigned long long bfd_hash_value;\n#else\ntypedef unsigned long bfd_hash_value;\n#endif\n\n")
patch("include/obstack.h", "  char contents[4];             /* objects begin here */",
      "#ifdef __wasi__\n  char *pdsh_host64_pad[2];     /* phoneDSH: x86-64 chunk header size (16 bytes) */\n#endif\n")
PY
fi
mkdir -p "$OUT/bu" && cd "$OUT/bu"
[ -f Makefile ] || CFLAGS="-Os -I$FAKEINC -include $COMPAT/compat.h $EM -Wno-implicit-function-declaration" \
  LDFLAGS="$LIBS -Wl,-z,stack-size=8388608" \
  "$OUT/bu-src/configure" --host=wasm32-wasi --build=x86_64-linux-gnu --target=riscv32-esp-elf \
  --disable-nls --disable-gdb --disable-gdbserver --disable-sim --disable-gprof --disable-gprofng \
  --disable-plugins --disable-shared --disable-werror --without-zstd --enable-threads=no > configure.log 2>&1
make -j"$(nproc)" all-gas all-ld all-binutils > make.log 2>&1

# ---- gcc: cc1, cc1plus -------------------------------------------------------------------
cat > "$OUT/physmem-wasi.c" <<'EOF'
/* See build-wasm-toolchain-riscv.sh: report 4 GiB so GCC's GC heuristics match a build computer. */
double physmem_total (void) { return 4294967296.0; }
double physmem_available (void) { return 4294967296.0; }
EOF
$CC -O2 -c "$OUT/physmem-wasi.c" -o "$OUT/physmem-wasi.o"
T=$NATIVE/riscv32-esp-elf
export gcc_cv_objdump=$T/bin/riscv32-esp-elf-objdump gcc_cv_readelf=$T/bin/riscv32-esp-elf-readelf gcc_cv_nm=$T/bin/riscv32-esp-elf-nm
GLD="$OUT/physmem-wasi.o $LIBS -Wl,-z,stack-size=67108864"
mkdir -p "$OUT/gcc" && cd "$OUT/gcc"
[ -f Makefile ] || CFLAGS="-O2 -include $COMPAT/compat.h $EM -Wno-implicit-function-declaration" CXXFLAGS="-O2 -include $COMPAT/compat.h $EM" \
  LDFLAGS="$GLD" \
  "$GCC_SRC/configure" --build=x86_64-linux-gnu --host=wasm32-wasi --target=riscv32-esp-elf \
  --with-as=$T/bin/riscv32-esp-elf-as --with-ld=$T/bin/riscv32-esp-elf-ld \
  --enable-languages=c,c++ --with-arch=rv32gc --with-abi=ilp32 --with-native-system-header-dir=/include \
  --disable-bootstrap --disable-nls --disable-plugin --disable-lto --disable-shared --disable-werror \
  --disable-libssp --disable-libgomp --disable-libquadmath --disable-libquadmath-support --disable-libmudflap --disable-libmpx \
  --with-newlib --enable-threads=posix --disable-__cxa_atexit --enable-target-optspace --without-long-double-128 --enable-multiarch \
  --disable-libstdcxx-verbose --with-pkgversion='crosstool-NG esp-15.2.0_20251204' --without-isl --without-zstd --with-system-zlib=no \
  > configure.log 2>&1
make -j"$(nproc)" all-gmp all-mpfr all-mpc all-libiberty all-libdecnumber all-libbacktrace all-zlib all-build-libiberty all-build-libcpp > deps.log 2>&1
make configure-libcpp configure-libcody configure-gcc >> deps.log 2>&1
make -C libcpp -j"$(nproc)" >> deps.log 2>&1
make -C libcody -j"$(nproc)" >> deps.log 2>&1
make -C gcc -j"$(nproc)" cc1 cc1plus LDFLAGS="$GLD" CFLAGS_FOR_BUILD=-O1 CXXFLAGS_FOR_BUILD=-O1 > make.log 2>&1

for p in gcc/gcc/cc1:cc1 gcc/gcc/cc1plus:cc1plus bu/gas/as-new:as bu/binutils/ar:ar bu/ld/ld-new:ld; do
  "$WASI_SDK/bin/llvm-strip" -o "$OUT/wasm/${p##*:}.wasm" "$OUT/${p%%:*}"
done
ls -l "$OUT/wasm"
