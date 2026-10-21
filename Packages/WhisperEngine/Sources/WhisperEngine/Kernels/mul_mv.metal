// Adapted from ggml (whisper.cpp 1.9.5), ggml/src/ggml-metal/kernels/mul_mv.metal.
// MIT License, Copyright (c) 2023-2026 The ggml authors. See PROVENANCE.md for the full notice and the
// list of changes.

#include "common.h"
#include "dequantize.h"
// Q1_0 dot product: dot = d * (2 * Σ(yl[i] where bit=1) - sumy)
template<short NR0>
static inline void helper_mv_reduce_and_write(
        device float * dst_f32,
        float sumf[NR0],
        const int r0,
        const int ne01,
        ushort tiisg,
        ushort sgitg,
        threadgroup char * shmem) {
    constexpr short NW = N_SIMDWIDTH;

    threadgroup float * shmem_f32[NR0];

    for (short row = 0; row < NR0; ++row) {
        shmem_f32[row] = (threadgroup float *) shmem + NW*row;

        if (sgitg == 0) {
            shmem_f32[row][tiisg] = 0.0f;
        }

        sumf[row] = simd_sum(sumf[row]);
    }

    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (short row = 0; row < NR0; ++row) {
        if (tiisg == 0) {
            shmem_f32[row][sgitg] = sumf[row];
        }
    }

    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (short row = 0; row < NR0 && r0 + row < ne01; ++row) {
        float tot = simd_sum(shmem_f32[row][tiisg]);

        if (tiisg == 0 && sgitg == 0) {
            dst_f32[r0 + row] = tot;
        }
    }
}

constant short FC_mul_mv_nsg   [[function_constant(FC_MUL_MV + 0)]];
constant short FC_mul_mv_nxpsg [[function_constant(FC_MUL_MV + 1)]];
constant short FC_mul_mv_ne12  [[function_constant(FC_MUL_MV + 2)]];
constant short FC_mul_mv_r2    [[function_constant(FC_MUL_MV + 3)]];
constant short FC_mul_mv_r3    [[function_constant(FC_MUL_MV + 4)]];
constant bool  FC_mul_mv_split [[function_constant(FC_MUL_MV + 5)]];

template<short NR0, typename args_t>
void kernel_mul_mv_q8_0_f32_impl(
        args_t args,
        device const char * src0,
        device const char * src1,
        device       char * dst,
        threadgroup  char * shmem,
        uint3  tgpig,
        ushort tiisg,
        ushort sgitg) {
    const short NSG = FC_mul_mv_nsg;

    constexpr short NW = N_SIMDWIDTH;
    constexpr short NQ = 8;

    const int nb = args.ne00/QK8_0;

    const int r0 = tgpig.x*NR0;
    const int r1 = tgpig.y;
    const int im = tgpig.z;

    const uint i12 = im%FC_mul_mv_ne12;
    const uint i13 = im/FC_mul_mv_ne12;

  //const uint64_t offset0 = r0*args.nb01 + (i12/FC_mul_mv_r2)*args.nb02 + (i13/FC_mul_mv_r3)*args.nb03;
    const uint64_t offset1 = r1*args.nb11 + (i12        )*args.nb12 + (i13        )*args.nb13;

  //device const block_q8_0 * x = (device const block_q8_0 *) (src0 + offset0);
    device const float      * y = (device const float      *) (src1 + offset1);

    // pointers to src0 rows
    device const block_q8_0 * ax[NR0];
    FOR_UNROLL (short row = 0; row < NR0; ++row) {
        const uint64_t offset0 = (r0 + row)*args.nb01 + (i12/FC_mul_mv_r2)*args.nb02 + (i13/FC_mul_mv_r3)*args.nb03;

        ax[row] = (device const block_q8_0 *) ((device char *) src0 + offset0);
    }

    float sumf[NR0] = { 0.f };

    const short ix = tiisg/(NW/NQ);
    const short il = tiisg%(NW/NQ);

    const int ib0 = sgitg*NQ + ix;

    float yl[NQ];

    device const float * yb = y + ib0*QK8_0 + il*NQ;

    // each thread in a SIMD group deals with NQ quants at a time
    for (int ib = ib0; ib < nb; ib += NSG*NQ) {
        for (short i = 0; i < NQ; ++i) {
            yl[i] = yb[i];
        }

        for (short row = 0; row < NR0; row++) {
            device const int8_t * qs = ax[row][ib].qs + il*NQ;

            float sumq = 0.f;
            FOR_UNROLL (short i = 0; i < NQ; ++i) {
                sumq += qs[i] * yl[i];
            }

            sumf[row] += sumq*ax[row][ib].d;
        }

        yb += NSG*NQ*QK8_0;
    }

    device float * dst_f32 = (device float *) dst + (uint64_t)im*args.ne0*args.ne1 + (uint64_t)r1*args.ne0;

    helper_mv_reduce_and_write<NR0>(dst_f32, sumf, r0, args.ne01, tiisg, sgitg, shmem);
}

[[host_name("kernel_mul_mv_q8_0_f32")]]
kernel void kernel_mul_mv_q8_0_f32(
        constant ggml_metal_kargs_mul_mv & args,
        device const char * src0,
        device const char * src1,
        device       char * dst,
        threadgroup  char * shmem [[threadgroup(0)]],
        uint3  tgpig[[threadgroup_position_in_grid]],
        ushort tiisg[[thread_index_in_simdgroup]],
        ushort sgitg[[simdgroup_index_in_threadgroup]]) {
    kernel_mul_mv_q8_0_f32_impl<N_R0_Q8_0, constant ggml_metal_kargs_mul_mv &>(args, src0, src1, dst, shmem, tgpig, tiisg, sgitg);
}

template<typename T0, typename T1, short NR0, typename args_t>
void kernel_mul_mv_t_t_impl(
        args_t args,
        device const char * src0,
        device const char * src1,
        device       char * dst,
        threadgroup  char * shmem,
        uint3  tgpig,
        ushort tiisg,
        ushort sgitg) {
    const short NSG = FC_mul_mv_nsg;

    constexpr short NW = N_SIMDWIDTH;
    constexpr short NB = 32;
    constexpr short NF = 8;

    const int nb = args.ne00/NB;

    const int r0 = tgpig.x*NR0;
    const int r1 = tgpig.y;
    const int im = tgpig.z;

    const uint i12 = im%FC_mul_mv_ne12;
    const uint i13 = im/FC_mul_mv_ne12;

  //const uint64_t offset0 = r0*args.nb01 + (i12/FC_mul_mv_r2)*args.nb02 + (i13/FC_mul_mv_r3)*args.nb03;
    const uint64_t offset1 = r1*args.nb11 + (i12        )*args.nb12 + (i13        )*args.nb13;

  //device const T0 * x = (device const T0 *) (src0 + offset0);
    device const T1 * y = (device const T1 *) (src1 + offset1);

    // pointers to src0 rows
    device const T0 * ax [NR0];
    FOR_UNROLL (short row = 0; row < NR0; ++row) {
        const uint64_t offset0 = (r0 + row)*args.nb01 + (i12/FC_mul_mv_r2)*args.nb02 + (i13/FC_mul_mv_r3)*args.nb03;

        ax[row] = (device const T0 *) ((device char *) src0 + offset0);
    }

    float sumf[NR0] = { 0.f };

    const short ix = tiisg/(NW/NF);
    const short il = tiisg%(NW/NF);

    const int ib0 = sgitg*NF + ix;

    T1 yl[NF];

    device const T1 * yb = y + (ib0*NB + il*NF);

    for (int ib = ib0; ib < nb; ib += NSG*NF) {
        for (short i = 0; i < NF; ++i) {
            yl[i] = yb[i];
        }

        for (short row = 0; row < NR0; row++) {
            device const T0 * xb = ax[row] + (ib*NB + il*NF);

            float sumq = 0.f;
            FOR_UNROLL (short i = 0; i < NF; ++i) {
                sumq += xb[i] * yl[i];
            }

            sumf[row] += sumq;
        }

        yb += NSG*NF*NW;
    }

    for (int i = nb*NB + sgitg*NW + tiisg; i < args.ne00; i += NW*NSG) {
        for (short row = 0; row < NR0; row++) {
            sumf[row] += ax[row][i] * y[i];
        }
    }

    device float * dst_f32 = (device float *) dst + (uint64_t)im*args.ne0*args.ne1 + (uint64_t)r1*args.ne0;

    helper_mv_reduce_and_write<NR0>(dst_f32, sumf, r0, args.ne01, tiisg, sgitg, shmem);
}

template<typename T0, typename T1, typename args_t>
void kernel_mul_mv_t_t_disp(
        args_t args,
        device const char * src0,
        device const char * src1,
        device       char * dst,
        threadgroup  char * shmem,
        uint3  tgpig,
        ushort tiisg,
        ushort sgitg) {
    switch (args.nr0) {
      //case 1: kernel_mul_mv_t_t_impl<T0, T1, 1, args_t>(args, src0, src1, dst, shmem, tgpig, tiisg, sgitg); break;
        case 2: kernel_mul_mv_t_t_impl<T0, T1, 2, args_t>(args, src0, src1, dst, shmem, tgpig, tiisg, sgitg); break;
      //case 3: kernel_mul_mv_t_t_impl<T0, T1, 3, args_t>(args, src0, src1, dst, shmem, tgpig, tiisg, sgitg); break;
      //case 4: kernel_mul_mv_t_t_impl<T0, T1, 4, args_t>(args, src0, src1, dst, shmem, tgpig, tiisg, sgitg); break;
    }
}

template<typename T0, typename T1>
kernel void kernel_mul_mv_t_t(
        constant ggml_metal_kargs_mul_mv & args,
        device const char * src0,
        device const char * src1,
        device       char * dst,
        threadgroup  char * shmem [[threadgroup(0)]],
        uint3  tgpig[[threadgroup_position_in_grid]],
        ushort tiisg[[thread_index_in_simdgroup]],
        ushort sgitg[[simdgroup_index_in_threadgroup]]) {
    kernel_mul_mv_t_t_disp<T0, T1, constant ggml_metal_kargs_mul_mv &>(args, src0, src1, dst, shmem, tgpig, tiisg, sgitg);
}

typedef decltype(kernel_mul_mv_t_t<half, half>) mul_mv_t_t;

template [[host_name("kernel_mul_mv_f32_f32")]]   kernel mul_mv_t_t kernel_mul_mv_t_t<float, float>;
template [[host_name("kernel_mul_mv_f16_f32")]]   kernel mul_mv_t_t kernel_mul_mv_t_t<half,  float>;
template [[host_name("kernel_mul_mv_f16_f16")]]   kernel mul_mv_t_t kernel_mul_mv_t_t<half,  half>;
#if defined(GGML_METAL_HAS_BF16)
template [[host_name("kernel_mul_mv_bf16_f32")]]  kernel mul_mv_t_t kernel_mul_mv_t_t<bfloat, float>;
template [[host_name("kernel_mul_mv_bf16_bf16")]] kernel mul_mv_t_t kernel_mul_mv_t_t<bfloat, bfloat>;
template [[host_name("kernel_mul_mv_f32_bf16")]]  kernel mul_mv_t_t kernel_mul_mv_t_t<float,  bfloat>;
#endif

template<typename T0, typename T04, typename T1, typename T14, short NR0, typename args_t>
void kernel_mul_mv_t_t_4_impl(
        args_t args,
        device const char * src0,
        device const char * src1,
        device       char * dst,
        threadgroup  char * shmem,
        uint3  tgpig,
        ushort tiisg,
        ushort sgitg) {
    const short NSG = FC_mul_mv_nsg;

    constexpr short NW = N_SIMDWIDTH;
    constexpr short NB  = 32;
    constexpr short NF  = 16;
    constexpr short NF4 = NF/4;

    const int nb = args.ne00/NB;

    const int r0 = tgpig.x*NR0;
    const int r1 = tgpig.y;
    const int im = tgpig.z;

    const uint i12 = im%FC_mul_mv_ne12;
    const uint i13 = im/FC_mul_mv_ne12;

  //const uint64_t offset0 = r0*args.nb01 + (i12/FC_mul_mv_r2)*args.nb02 + (i13/FC_mul_mv_r3)*args.nb03;
    const uint64_t offset1 = r1*args.nb11 + (i12        )*args.nb12 + (i13        )*args.nb13;

    device const T1  * y  = (device const T1  *) (src1 + offset1);
    device const T14 * y4 = (device const T14 *) (src1 + offset1);

    // pointers to src0 rows
    device const T0  * ax [NR0];
    device const T04 * ax4[NR0];
    FOR_UNROLL (short row = 0; row < NR0; ++row) {
        const uint64_t offset0 = (r0 + row)*args.nb01 + (i12/FC_mul_mv_r2)*args.nb02 + (i13/FC_mul_mv_r3)*args.nb03;

        ax [row] = (device const T0  *) ((device char *) src0 + offset0);
        ax4[row] = (device const T04 *) ((device char *) src0 + offset0);
    }

    float sumf[NR0] = { 0.f };

    const short ix = tiisg/(NW/NF);
    const short il = tiisg%(NW/NF);

    const int ib0 = sgitg*NF + ix;

    T14 yl4[NF4];

    device const T14 * yb4 = y4 + (ib0*NB + il*NF)/4;

    for (int ib = ib0; ib < nb; ib += NSG*NF) {
        for (short i = 0; i < NF4; ++i) {
            yl4[i] = yb4[i];
        }

        for (short row = 0; row < NR0; row++) {
            device const T04 * xb4 = ax4[row] + (ib*NB + il*NF)/4;

            float sumq = 0.f;
            FOR_UNROLL (short i = 0; i < NF4; ++i) {
                sumq += dot(float4(xb4[i]), float4(yl4[i]));
            }

            sumf[row] += sumq;
        }

        yb4 += NSG*NF*NW/4;
    }

    for (int i = nb*NB + sgitg*NW + tiisg; i < args.ne00; i += NW*NSG) {
        for (short row = 0; row < NR0; row++) {
            sumf[row] += ax[row][i] * y[i];
        }
    }

    device float * dst_f32 = (device float *) dst + (uint64_t)im*args.ne0*args.ne1 + (uint64_t)r1*args.ne0;

    helper_mv_reduce_and_write<NR0>(dst_f32, sumf, r0, args.ne01, tiisg, sgitg, shmem);
}

template<typename T0, typename T04, typename T1, typename T14, typename args_t>
void kernel_mul_mv_t_t_4_disp(
        args_t args,
        device const char * src0,
        device const char * src1,
        device       char * dst,
        threadgroup  char * shmem,
        uint3  tgpig,
        ushort tiisg,
        ushort sgitg) {
    switch (args.nr0) {
      //case 1: kernel_mul_mv_t_t_4_impl<T0, T04, T1, T14, 1, args_t>(args, src0, src1, dst, shmem, tgpig, tiisg, sgitg); break;
        case 2: kernel_mul_mv_t_t_4_impl<T0, T04, T1, T14, 2, args_t>(args, src0, src1, dst, shmem, tgpig, tiisg, sgitg); break;
      //case 3: kernel_mul_mv_t_t_4_impl<T0, T04, T1, T14, 3, args_t>(args, src0, src1, dst, shmem, tgpig, tiisg, sgitg); break;
      //case 4: kernel_mul_mv_t_t_4_impl<T0, T04, T1, T14, 4, args_t>(args, src0, src1, dst, shmem, tgpig, tiisg, sgitg); break;
    };
}

template<typename T0, typename T04, typename T1, typename T14>
kernel void kernel_mul_mv_t_t_4(
        constant ggml_metal_kargs_mul_mv & args,
        device const char * src0,
        device const char * src1,
        device       char * dst,
        threadgroup  char * shmem [[threadgroup(0)]],
        uint3  tgpig[[threadgroup_position_in_grid]],
        ushort tiisg[[thread_index_in_simdgroup]],
        ushort sgitg[[simdgroup_index_in_threadgroup]]) {
    kernel_mul_mv_t_t_4_disp<T0, T04, T1, T14, constant ggml_metal_kargs_mul_mv &>(args, src0, src1, dst, shmem, tgpig, tiisg, sgitg);
}

typedef decltype(kernel_mul_mv_t_t_4<half, half4, half, half4>) mul_mv_t_t_4;

template [[host_name("kernel_mul_mv_f32_f32_4")]]   kernel mul_mv_t_t_4 kernel_mul_mv_t_t_4<float, float4, float, float4>;
template [[host_name("kernel_mul_mv_f16_f32_4")]]   kernel mul_mv_t_t_4 kernel_mul_mv_t_t_4<half,  half4,  float, float4>;
template [[host_name("kernel_mul_mv_f16_f16_4")]]   kernel mul_mv_t_t_4 kernel_mul_mv_t_t_4<half,  half4,  half,  half4>;
#if defined(GGML_METAL_HAS_BF16)
template [[host_name("kernel_mul_mv_bf16_f32_4")]]  kernel mul_mv_t_t_4 kernel_mul_mv_t_t_4<bfloat, bfloat4, float,  float4>;
template [[host_name("kernel_mul_mv_bf16_bf16_4")]] kernel mul_mv_t_t_4 kernel_mul_mv_t_t_4<bfloat, bfloat4, bfloat, bfloat4>;
template [[host_name("kernel_mul_mv_f32_bf16_4")]]  kernel mul_mv_t_t_4 kernel_mul_mv_t_t_4<float,  float4,  bfloat, bfloat4>;
#endif

template<typename T0, typename T1, typename args_t>
void kernel_mul_mv_t_t_short_impl(
        args_t args,
        device const char * src0,
        device const char * src1,
        device       char * dst,
        uint3  tgpig,
        ushort tiisg) {
    const int r0 = tgpig.x*32 + tiisg;
    const int r1 = tgpig.y;
    const int im = tgpig.z;

    if (r0 >= args.ne01) {
        return;
    }

    const uint i12 = im%FC_mul_mv_ne12;
    const uint i13 = im/FC_mul_mv_ne12;

    const uint64_t offset0 = r0*args.nb01 + (i12/FC_mul_mv_r2)*args.nb02 + (i13/FC_mul_mv_r3)*args.nb03;

    device const T0 * x = (device const T0 *) (src0 + offset0);

    device float * dst_f32 = (device float *) dst + (uint64_t)im*args.ne0*args.ne1;

    const uint64_t offset1 = r1*args.nb11 + (i12   )*args.nb12 + (i13   )*args.nb13;

    device const T1 * y = (device const T1 *) (src1 + offset1);

    float res = 0.0f;

    for (int i = 0; i < args.ne00; ++i) {
        res += (float) x[i] * (float) y[i];
    }

    dst_f32[(uint64_t)r1*args.ne0 + r0] = res;
}

template<typename T0, typename T1>
kernel void kernel_mul_mv_t_t_short(
        constant ggml_metal_kargs_mul_mv & args,
        device const char * src0,
        device const char * src1,
        device       char * dst,
        uint3  tgpig[[threadgroup_position_in_grid]],
        ushort tiisg[[thread_index_in_simdgroup]]) {
    kernel_mul_mv_t_t_short_impl<T0, T1, constant ggml_metal_kargs_mul_mv &>(
        args,
        src0,
        src1,
        dst,
        tgpig,
        tiisg);
}

typedef decltype(kernel_mul_mv_t_t_short<half, half>) mul_mv_t_t_short_t;

template [[host_name("kernel_mul_mv_f32_f32_short")]]  kernel mul_mv_t_t_short_t kernel_mul_mv_t_t_short<float, float>;
template [[host_name("kernel_mul_mv_f16_f32_short")]]  kernel mul_mv_t_t_short_t kernel_mul_mv_t_t_short<half,  float>;
template [[host_name("kernel_mul_mv_f16_f16_short")]]  kernel mul_mv_t_t_short_t kernel_mul_mv_t_t_short<half,  half>;
#if defined(GGML_METAL_HAS_BF16)
template [[host_name("kernel_mul_mv_bf16_f32_short")]]  kernel mul_mv_t_t_short_t kernel_mul_mv_t_t_short<bfloat, float>;
template [[host_name("kernel_mul_mv_bf16_bf16_short")]] kernel mul_mv_t_t_short_t kernel_mul_mv_t_t_short<bfloat, bfloat>;
template [[host_name("kernel_mul_mv_f32_bf16_short")]]  kernel mul_mv_t_t_short_t kernel_mul_mv_t_t_short<float,  bfloat>;
#endif
