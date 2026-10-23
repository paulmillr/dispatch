// Adapted from ggml (whisper.cpp 1.9.5), ggml/src/ggml-metal/kernels/fa_f32.metal.
// MIT License, Copyright (c) 2023-2026 The ggml authors. See PROVENANCE.md for the full notice and the
// list of changes.

#include "common.h"
#include "dequantize.h"
#include "fa_common.metal"

#define FA_TYPES \
    half,   half4,     simdgroup_half8x8,  \
    half,   half4x4,   simdgroup_half8x8,  \
    half,   half4x4,   simdgroup_half8x8,  \
    float,             simdgroup_float8x8, \
    float,  float2,    simdgroup_float8x8, \
    float,  float4,    simdgroup_float8x8

#define FA_TYPES_F32 \
    half,   half4,     simdgroup_half8x8,  \
    float,  float4x4,  simdgroup_float8x8, \
    float,  float4x4,  simdgroup_float8x8, \
    float,             simdgroup_float8x8, \
    float,  float2,    simdgroup_float8x8, \
    float,  float4,    simdgroup_float8x8

typedef decltype(kernel_flash_attn_ext<FA_TYPES, half4x4, 1, dequantize_f16, half4x4, 1, dequantize_f16, 64, 64>) flash_attn_ext_t;

template [[host_name("kernel_flash_attn_ext_f32_dk64_dv64"  )]]  kernel flash_attn_ext_t kernel_flash_attn_ext<FA_TYPES_F32, float4x4,   1, dequantize_f32,  float4x4,   1, dequantize_f32,  64,  64>;

#undef FA_TYPES
#undef FA_TYPES_F32
