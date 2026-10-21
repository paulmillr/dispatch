// Adapted from ggml (whisper.cpp 1.9.5), ggml/src/ggml-common.h.
// MIT License, Copyright (c) 2023-2026 The ggml authors. See PROVENANCE.md for the full notice and the
// list of changes.

#pragma once

#include <metal_stdlib>

typedef half  ggml_half;
typedef half2 ggml_half2;

#define QK8_0 32
typedef struct {
    ggml_half d;       // delta
    int8_t  qs[QK8_0]; // quants
} block_q8_0;
static_assert(sizeof(block_q8_0) == sizeof(ggml_half) + QK8_0, "wrong q8_0 block size/padding");
