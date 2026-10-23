// WhisperEngine's own kernels (not from ggml): small ops the upstream kernels do not provide as standalone
// dispatches, written for whisper's shapes (head size a multiple of 64).

#include <metal_stdlib>

using namespace metal;

typedef struct {
    int32_t nq;
    int32_t nk;
} whisper_kargs_causal_mask;

// The additive mask whisper's decoder self-attention feeds to soft_max: query i may attend keys 0 ... i + nk - nq
// (the last query sees every key), the rest get -inf. Row-major [nq, nk].
kernel void whisper_causal_mask_f32(
        constant whisper_kargs_causal_mask & args,
        device float * dst,
        uint2 tpig [[thread_position_in_grid]]) {
    const int j = tpig.x;
    const int i = tpig.y;

    if (j >= args.nk || i >= args.nq) {
        return;
    }

    dst[i*args.nk + j] = (j <= i + args.nk - args.nq) ? 0.0f : -INFINITY;
}

typedef struct {
    int32_t  nq;
    int32_t  nk;
    int32_t  hd;      // head size, a multiple of 64
    int32_t  ldq;     // row strides in floats
    int32_t  ldk;
    int32_t  ldv;
    int32_t  ldd;
    float    scale;
    int32_t  causal;
    int32_t  chunk;   // keys per partition
    int32_t  nparts;  // partitions (threadgroups) per (query, head)
} whisper_kargs_attn_decode;

// Attention for a few queries (the decoder), split over the keys: threadgroup (query i, head h, partition p) takes
// keys [p * chunk, (p + 1) * chunk) with 256 threads (one simdgroup per key for the scores, lanes across the head;
// softmax in threadgroup memory; threads across the head for the weighted values, four key groups reduced at the
// end). With one partition the normalised result goes straight to `dst`; otherwise the partition's unnormalised
// sum, its max m and its denominator s go to `partial` for `whisper_attn_decode_reduce_f32`. Equivalent to
// soft_max(scale * q k^T + causal mask) v; nothing else is materialised.
// Threadgroup memory layout (floats): q [hd], scores [chunk], reductions [32], partial outputs [256].
kernel void whisper_attn_decode_f32(
        constant whisper_kargs_attn_decode & args,
        device const float * q,
        device const float * k,
        device const float * v,
        device       float * dst,
        device       float * partial,
        threadgroup  float * shmem [[threadgroup(0)]],
        uint3   tgpig [[threadgroup_position_in_grid]],
        uint3   tgpg  [[threadgroups_per_grid]],
        ushort  tpitg [[thread_index_in_threadgroup]],
        ushort  sgitg [[simdgroup_index_in_threadgroup]],
        ushort  tiisg [[thread_index_in_simdgroup]]) {
    constexpr int NT  = 256;
    constexpr int NSG = NT/32;

    const int i  = tgpig.x;  // query
    const int h  = tgpig.y;  // head
    const int p  = tgpig.z;  // key partition
    const int hd = args.hd;

    threadgroup float * qs   = shmem;
    threadgroup float * s    = shmem + hd;
    threadgroup float * red  = s + args.chunk;
    threadgroup float * part = red + 32;

    const int limit = args.causal ? i + args.nk - args.nq + 1 : args.nk;
    const int j0    = p*args.chunk;
    const int j1    = min(j0 + args.chunk, limit);

    device const float * qrow = q + i*args.ldq + h*hd;
    for (int e = tpitg; e < hd; e += NT) {
        qs[e] = qrow[e];
    }

    threadgroup_barrier(mem_flags::mem_threadgroup);

    // Scores: simdgroup sgitg takes keys j0 + sgitg, + NSG, ...; lane l covers head elements 2l, 2l + 1 (+ 64 ...).
    float lmax = -INFINITY;
    for (int j = j0 + sgitg; j < j1; j += NSG) {
        device const float * krow = k + j*args.ldk + h*hd;
        float acc = 0.0f;
        for (int e = 2*tiisg; e < hd; e += 64) {
            acc += qs[e]*krow[e] + qs[e + 1]*krow[e + 1];
        }
        const float score = simd_sum(acc)*args.scale;
        if (tiisg == 0) {
            s[j - j0] = score;
        }
        lmax = max(lmax, score);
    }

    lmax = simd_max(lmax);
    if (tiisg == 0) {
        red[sgitg] = lmax;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    float gmax = red[0];
    for (int g = 1; g < NSG; ++g) {
        gmax = max(gmax, red[g]);
    }

    threadgroup_barrier(mem_flags::mem_threadgroup);

    // An empty partition (causal, short limit) contributes nothing: max -inf, sum 0.
    float lsum = 0.0f;
    for (int j = j0 + tpitg; j < j1; j += NT) {
        const float e = exp(s[j - j0] - gmax);
        s[j - j0] = e;
        lsum += e;
    }
    lsum = simd_sum(lsum);
    if (tiisg == 0) {
        red[sgitg] = lsum;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    float gsum = 0.0f;
    for (int g = 0; g < NSG; ++g) {
        gsum += red[g];
    }

    // Weighted values: thread t handles head element t % hd for the keys of group t / hd.
    const int ngroups = NT/hd;
    const int e       = tpitg % hd;
    const int g       = tpitg / hd;

    float acc = 0.0f;
    for (int j = j0 + g; j < j1; j += ngroups) {
        acc += s[j - j0]*v[j*args.ldv + h*hd + e];
    }
    part[tpitg] = acc;

    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (g == 0) {
        for (int o = 1; o < ngroups; ++o) {
            acc += part[o*hd + e];
        }
        if (args.nparts == 1) {
            dst[i*args.ldd + h*hd + e] = acc/gsum;
        } else {
            device float * out = partial + ((i*tgpg.y + h)*args.nparts + p)*(hd + 2);
            out[e] = acc;
            if (e == 0) {
                out[hd]     = gmax;
                out[hd + 1] = gsum;
            }
        }
    }
}

// Combines the partitions of whisper_attn_decode_f32: one threadgroup of hd threads per (query, head).
kernel void whisper_attn_decode_reduce_f32(
        constant whisper_kargs_attn_decode & args,
        device const float * partial,
        device       float * dst,
        uint3   tgpig [[threadgroup_position_in_grid]],
        uint3   tgpg  [[threadgroups_per_grid]],
        ushort  tpitg [[thread_index_in_threadgroup]]) {
    const int i  = tgpig.x;
    const int h  = tgpig.y;
    const int hd = args.hd;
    const int e  = tpitg;

    device const float * base = partial + (i*tgpg.y + h)*args.nparts*(hd + 2);

    float gmax = -INFINITY;
    for (int p = 0; p < args.nparts; ++p) {
        gmax = max(gmax, base[p*(hd + 2) + hd]);
    }

    float num = 0.0f;
    float den = 0.0f;
    for (int p = 0; p < args.nparts; ++p) {
        const float w = exp(base[p*(hd + 2) + hd] - gmax);
        num += w*base[p*(hd + 2) + e];
        den += w*base[p*(hd + 2) + hd + 1];
    }

    dst[i*args.ldd + h*hd + e] = num/den;
}

typedef struct {
    int32_t count;
} whisper_kargs_count;

// Zero fill (cache creation stays on the GPU, ordered with the ops around it).
kernel void whisper_fill_zero_f32(
        constant whisper_kargs_count & args,
        device float * dst,
        uint tpig [[thread_position_in_grid]]) {
    if (tpig < (uint) args.count) {
        dst[tpig] = 0.0f;
    }
}

// Contiguous copy, four floats per thread (upstream's generic cpy moves one element per thread).
kernel void whisper_copy_f32x4(
        constant whisper_kargs_count & args,
        device const float4 * src,
        device       float4 * dst,
        uint tpig [[thread_position_in_grid]]) {
    if (tpig < (uint) args.count) {
        dst[tpig] = src[tpig];
    }
}

typedef struct {
    int32_t len;      // input width
    int32_t channels;
    int32_t ksize;
    int32_t outLen;
    int32_t stride;
    int32_t padding;
} whisper_kargs_im2col;

// ggml_conv_1d's im2col: dst [outLen, channels * kernel] as half, one thread per output element.
kernel void whisper_im2col_f16(
        constant whisper_kargs_im2col & args,
        device const float * x,
        device       half  * dst,
        uint tpig [[thread_position_in_grid]]) {
    const int chw = args.channels*args.ksize;
    const int t   = tpig / chw;
    const int r   = tpig % chw;
    if (t >= args.outLen) {
        return;
    }
    const int c   = r / args.ksize;
    const int j   = r % args.ksize;
    const int pos = t*args.stride + j - args.padding;

    dst[tpig] = (pos < 0 || pos >= args.len) ? half(0.0f) : half(x[c*args.len + pos]);
}
