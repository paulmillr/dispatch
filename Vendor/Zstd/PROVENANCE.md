# Zstandard

Zstandard 1.5.7 library sources (`lib/common`, `lib/compress`, `lib/decompress`, `lib/zstd.h`,
`lib/zstd_errors.h`), BSD license (`LICENSE`). Taken from the `zstd-sys-2.0.16+zstd.1.5.7` crate's bundled
`zstd/` tree (crate archive SHA-256 `91e19ebc2adc8f83e43039e79776e3fda8ca919132d68a1fed6a5faca2683748`), which
carries upstream's release unchanged. Left out: legacy formats, the dictionary builder, deprecated code and the
x86-64 assembly (`huf_decompress_amd64.S`).

Modified to hold no assembly, no multithreading, one compression strategy, one decoder variant and no code macOS
never builds; everything else is upstream's code, so the compressed and decompressed bytes are upstream's:

- `common/xxhash.h`: XXH3 (zstd builds it with `XXH_NO_XXH3`) and the `XXH_COMPILER_GUARD` fences removed
  (`unifdef -DXXH_NO_XXH3`, `unifdef -DXXH_ENABLE_AUTOVECTORIZE`).
- `decompress/huf_decompress.c`: the `.S` decoder's hooks removed (`unifdef -DZSTD_ENABLE_ASM_X86_64_BMI2=0`).
- `common/cpu.h`: no `cpuid` (inline assembly, MSVC intrinsics): every CPU feature reads as absent. So runtime
  BMI2 dispatch is removed everywhere (`unifdef -DDYNAMIC_BMI2=0`), and `common/portability_macros.h` loses
  the assembly-only macros (`ZSTD_ASM_SUPPORTED`, `ZSTD_ENABLE_ASM_X86_64_BMI2`, `ZSTD_HIDE_ASM_FUNCTION`,
  Intel CET).
- The x86-64 `.p2align` loop-alignment hints (`compress/zstd_lazy.c`, `decompress/zstd_decompress_block.c`),
  the `cmova` in `ZSTD_selectAddr` (`compress/zstd_compress_internal.h`), the empty `__asm__("")` ordering
  fence (`compress/zstd_fast.c`) and the aarch64 `prfm` prefetch fallback (`common/compiler.h`) removed:
  each had a C equivalent, which stays.
- `ZSTD_d_disableHuffmanAssembly` stays (public API) and has no effect.
- No multithreading (zstd builds it only with `ZSTD_MULTITHREAD`): `compress/zstdmt_compress.[ch]`,
  `common/pool.[ch]`, `common/threading.[ch]` and `common/debug.c` (only `DEBUGLEVEL>=2` reads it) deleted, the
  `ZSTD_MULTITHREAD` paths removed (`unifdef -UZSTD_MULTITHREAD`), and `zstd.h` loses `ZSTD_createThreadPool`
  and `ZSTD_freeThreadPool`, whose definitions were in `pool.c`.
- One block compressor besides `fast`: `lazy2`, what level 9 streams with (the helper never gives zstd a size, so
  the small-input tables, whose level 9 is `btlazy2`, are never used). Upstream's switches for the others compiled
  out (`unifdef` with every `ZSTD_EXCLUDE_*_BLOCK_COMPRESSOR` defined but `LAZY2`, continued `#if` lines joined
  first), and the files left with only includes deleted (`compress/zstd_double_fast.c`, `compress/zstd_opt.c`);
  their headers stay for the `NULL` entries of the dispatch table. Any other level cascades down to `lazy2` (or
  to `fast`, below it) rather than failing.
- One decoder variant, as upstream's size-reduced builds: the single-symbol Huffman decoder and the short-offset
  sequence decoder, which read every zstd frame (`unifdef -DHUF_FORCE_DECOMPRESS_X1
  -DZSTD_FORCE_DECOMPRESS_SEQUENCES_SHORT`). Decoding the corpus costs the same CPU time.
- Code no macOS build compiles removed with `unifdef`: tracing (`ZSTD_TRACE=0`, so `common/zstd_trace.h` is
  deleted), debug levels (`DEBUGLEVEL=0`, `XXH_DEBUGLEVEL=0`), fuzzing modes, legacy formats
  (`ZSTD_LEGACY_SUPPORT=0`) and MSVC, Windows, IAR, ARM CC, Intel C, MinGW, Cygwin and AIX branches. A
  conditional that also names an unknown macro stays as it was (`unifdef` leaves partial expressions). Also the
  two `#if 0` blocks (`unifdef -k`, which unwraps the one `#if 1`), and the no-op `DEBUGLOG`/`RAWLOG` statements
  except inside `common/error_private.h`'s macros; `common/debug.h` keeps their definitions. Each object's
  machine code is unchanged by these.

Captures are zstd. The replay corpus (`replays/`) is level 9 with long-distance matching (`--long=27`), whose 128 MiB
window finds the same large payload recorded again and again (a helper binary uploaded many times). Live captures are
level 1 (the `fast` strategy): quick, in a small window; `capture store` compresses them again for the corpus. The
files plugin's copy archives are level 1 too, so the helper links it in every build, Release included:

- The helper (`helper/core/build.rs`, FFI in `helper/core/src/system/zstd.rs`) compiles all three parts into every
  helper, macOS and Linux: copied files travel as zstd archives; with the `capture` feature, live captures and the
  capture tool write it and every replay reads it. Linux helpers are built on macOS with the
  same clang, for `*-unknown-linux-musl` and freestanding (macOS has no Linux libc headers): `freestanding/`, ours and
  not upstream's, declares the libc functions zstd calls (`memcpy`, `memmove`, `memset`, `memcmp`, `malloc`, `calloc`,
  `free`), which the static musl libc of Rust's musl targets supplies.
- The app (target `Zstd`, module `CZstd`) compiles all three parts: Debug app journals are written (level 1, as live
  captures) and read with it.
