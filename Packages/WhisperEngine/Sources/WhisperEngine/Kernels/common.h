// Adapted from ggml (whisper.cpp 1.9.5), ggml/src/ggml-metal/kernels/common.h.
// MIT License, Copyright (c) 2023-2026 The ggml authors. See PROVENANCE.md for the full notice and the
// list of changes.

#pragma once

#include "ggml-metal-impl.h"

#include <metal_stdlib>

#ifdef GGML_METAL_HAS_TENSOR
#include <metal_tensor>

#include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>
#endif

using namespace metal;

#define MAX(x, y) ((x) > (y) ? (x) : (y))
#define MIN(x, y) ((x) < (y) ? (x) : (y))
#define SWAP(x, y) { auto tmp = (x); (x) = (y); (y) = tmp; }

#define PAD2(x, n) (((x) + (n) - 1) & ~((n) - 1))

#define FOR_UNROLL(x) _Pragma("clang loop unroll(full)") for (x)

#define N_SIMDWIDTH 32 // assuming SIMD group size is 32

static inline float dot(float x, float y) {
    return x*y;
}

static inline float sum(float x) {
    return x;
}

static inline float sum(float4 x) {
    return x[0] + x[1] + x[2] + x[3];
}

constant float GELU_COEF_A     = 0.044715f;
constant float GELU_QUICK_COEF = -1.702f;
constant float SQRT_2_OVER_PI  = 0.79788456080286535587989211986876f;
constant float SQRT_2_INV      = 0.70710678118654752440084436210484f;
