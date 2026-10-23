# Metal kernel provenance

The `.metal` and `.h` files in this directory are Metal Shading Language sources compiled at run time by
`MetalKernelLibrary` (Xcode 27 ships no Metal toolchain, so nothing here is built ahead of time). Except for
`whisper.metal`, they come from ggml as vendored in whisper.cpp 1.9.5 (`ggml/src/ggml-metal/kernels/` and
`ggml/src/ggml-metal/ggml-metal-impl.h`, `ggml/src/ggml-common.h`), under the MIT license reproduced below. The
upstream files carry no per-file license header; each copy here starts with a banner naming its source file.

## Files

| File | Upstream | Status | Changes |
| --- | --- | --- | --- |
| `ggml-metal-impl.h` | `ggml-metal-impl.h` | adapted | Kept the mat-mat/mat-vec threadgroup parameters for q8_0, the `FC_*` offsets and `OP_UNARY_NUM_GELU`, and only the `ggml_metal_kargs_*` structs the backend uses (`unary`, `bin`, `cpy`, `mul_mm`, `mul_mv`, `norm`, `im2col`, `soft_max`, `get_rows`), unchanged. |
| `common.h` | `kernels/common.h` | adapted | Dropped the tensor-API/`MetalPerformancePrimitives` include, bf16 typedefs, iq4/mxfp4 lookup tables, `best_index_int8`, `e8m0_to_fp32`, `ggml_sort_order`, `erf_approx`, `elu_approx`. Kept the macros, `dot`/`sum` helpers and the GELU constants. |
| `ggml-common.h` | `ggml-common.h` | adapted | Only the Metal `ggml_half` typedefs and `block_q8_0` (`QK8_0`). |
| `dequantize.h` | `kernels/dequantize.h` | adapted | Only `dequantize_f32`, `dequantize_f16`, `dequantize_q8_0` and their `_t4` variants, plus `QK_NL`. |
| `mul_mm.metal` | `kernels/mul_mm.metal` | adapted | Both `kernel_mul_mm` variants verbatim (the Metal 4 tensor-API one under `GGML_METAL_HAS_TENSOR`, the simdgroup-matrix one otherwise), with four instantiations: `kernel_mul_mm_f32_f32`, `_f16_f32`, `_q8_0_f32`, `_f16_f16`. `mul_mm_id` and the amax kernels are dropped; `FC_mul_mm_id_amax` is not declared. |
| `mul_mv.metal` | `kernels/mul_mv.metal` | adapted | `helper_mv_reduce_and_write`, the `FC_mul_mv_*` constants, `kernel_mul_mv_q8_0_f32`, and the `kernel_mul_mv_t_t`, `_t_t_4`, `_t_t_short` row kernels (f32/f16 instantiations; the bf16 ones stay behind `GGML_METAL_HAS_BF16`, which is not defined). All other quantization types and the `mul_mv_ext` few-row kernels are dropped. |
| `norm.metal` | `kernels/norm.metal` | adapted | `kernel_norm_fuse_impl` and its six instantiations; `rms_norm` dropped. |
| `binbcast.metal` | `kernels/binbcast.metal` | adapted | `kernel_bin_fuse_impl` and its four instantiations; `kernel_add_id` and `kernel_repeat` dropped. |
| `unary.metal` | `kernels/unary.metal` | adapted | `kernel_unary_impl` with only the `OP_UNARY_NUM_GELU` branch (the other ops' branches and the `glu` kernels are dropped); `kernel_unary_f32_f32` and `_4` instantiations. |
| `softmax.metal` | `kernels/softmax.metal` | verbatim | None. |
| `fa_common.metal` | `kernels/fa_common.metal` | verbatim | None (the simdgroup flash-attention kernel template). |
| `fa_f32.metal` | `kernels/fa_f32.metal` | adapted | Only the `FA_TYPES` and `FA_TYPES_F32` macros and the `kernel_flash_attn_ext_f32_dk64_dv64` instantiation (whisper's head size); the bf16 types and the other head sizes dropped. |
| `cpy_get_rows.metal` | `kernels/quantize.metal` | adapted | `kernel_cpy_t_t` (`f32_f32`, `f32_f16`, `f16_f32`), `kernel_get_rows_q` and `kernel_get_rows_f` (`f32`, `f16`, `q8_0`); the `get_rows_q_t` typedef names `block_q8_0` instead of `block_q4_0`. Quantizing copies, `concat` and the other types dropped. |
| `whisper.metal` | (none) | original | `whisper_causal_mask_f32` (the additive causal mask `kernel_soft_max` consumes), `whisper_attn_decode_f32` + `whisper_attn_decode_reduce_f32` (split-K attention for the decoder's few queries), `whisper_im2col_f16`, `whisper_fill_zero_f32`, `whisper_copy_f32x4`. |

Kernels not taken from upstream, and why: the flash-attention side kernels (`fa_aux.metal`: kv padding, mask block
maps, the f16 KV conversion) are unnecessary because `WhisperModel` pads keys to a multiple of 256 and the
mask-free cases are the only ones routed to flash attention; the vec flash-attention kernels (`fa_vec_*.metal`,
nq < 20) are replaced by `whisper_attn_decode_f32`, a far smaller split-K kernel that also applies whisper's causal
rule without a mask; masked attention with more than 8 queries uses whisper.cpp's non-flash composition
(`mul_mm`/`mul_mv` + `soft_max` + `mul_mm`/`mul_mv` + `cpy`); `mul_mv_ext` and `mul_mv_mma` (2 ... 16 row matmuls)
are optimisations the classic mat-vec kernel covers for now; `kernel_im2col` dispatches three-thread threadgroups
for whisper's kernel width, so a one-thread-per-element im2col of our own is used instead.

Preprocessor macros: `GGML_METAL_HAS_TENSOR` is defined (with Metal language version 4.0) when the device supports
the Metal 4 GPU family, as ggml does on M5-class GPUs; it selects the tensor-API `kernel_mul_mm`. `GGML_METAL_HAS_BF16`
is never defined (the bf16 kernels are not included). Compile options otherwise match `ggml-metal-device.m`: a default
`MTLCompileOptions` (fast math).

## License

```
MIT License

Copyright (c) 2023-2026 The ggml authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Swift host code derived from ggml

Outside this directory, two parts of the Swift backend follow ggml's MIT-licensed C code closely enough to count as
derived work (same license and copyright as the kernels above):

- `MetalKernels.swift`, `MetalHalf.toFloat`/`fromFloat`: ggml-impl.h's `ggml_compute_fp16_to_fp32` and
  `ggml_compute_fp32_to_fp16`, constant for constant. ggml took them from the FP16 library (Copyright (c) 2017
  Facebook Inc., Marat Dukhan; MIT).
- `MetalBackend.swift`: the dispatch decisions (kernel variant per shape, function constants, threadgroup sizes and
  threadgroup memory) ported from ggml-metal-ops.cpp and ggml-metal-device.cpp.
