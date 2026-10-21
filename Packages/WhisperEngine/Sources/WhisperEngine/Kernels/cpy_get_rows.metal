// Adapted from ggml (whisper.cpp 1.9.5), ggml/src/ggml-metal/kernels/quantize.metal.
// MIT License, Copyright (c) 2023-2026 The ggml authors. See PROVENANCE.md for the full notice and the
// list of changes.

#include "common.h"
#include "dequantize.h"

template<typename T0, typename T1>
kernel void kernel_cpy_t_t(
        constant ggml_metal_kargs_cpy & args,
        device  const char * src0,
        device        char * dst,
        uint3   tgpig[[threadgroup_position_in_grid]],
        ushort3 tpitg[[thread_position_in_threadgroup]],
        ushort3   ntg[[threads_per_threadgroup]]) {
    const int32_t i03 = tgpig[2];
    const int32_t i02 = tgpig[1];
    const int32_t i01 = ntg[1] == 1 ? tgpig[0]%args.ne01 : tgpig[0]*ntg[1] + tpitg.y;
    const int32_t iw0 = ntg[1] == 1 ? tgpig[0]/args.ne01 : 0;

    if (i01 >= args.ne01) {
        return;
    }

    const int64_t n = i03*args.ne02*args.ne01*args.ne00 + i02*args.ne01*args.ne00 + i01*args.ne00;

    const int32_t i3 = n/(args.ne2*args.ne1*args.ne0);
    const int32_t i2 = (n - i3*args.ne2*args.ne1*args.ne0)/(args.ne1*args.ne0);
    const int32_t i1 = (n - i3*args.ne2*args.ne1*args.ne0 - i2*args.ne1*args.ne0)/args.ne0;
    const int32_t i0 = (n - i3*args.ne2*args.ne1*args.ne0 - i2*args.ne1*args.ne0 - i1*args.ne0);

    device T1 * dst_data = (device T1 *) (dst + i3*args.nb3 + i2*args.nb2 + i1*args.nb1 + i0*args.nb0);

    for (int32_t i00 = iw0*ntg[0] + tpitg.x; i00 < args.ne00;) {
        device const T0 * src = (device T0 *)(src0 + i03*args.nb03 + i02*args.nb02 + i01*args.nb01 + i00*args.nb00);
        dst_data[i00] = (T1) src[0];
        break;
    }
}

typedef decltype(kernel_cpy_t_t<float, float>) kernel_cpy_t;

template [[host_name("kernel_cpy_f32_f32")]]   kernel kernel_cpy_t kernel_cpy_t_t<float,   float>;
template [[host_name("kernel_cpy_f32_f16")]]   kernel kernel_cpy_t kernel_cpy_t_t<float,   half>;
template [[host_name("kernel_cpy_f16_f32")]]   kernel kernel_cpy_t kernel_cpy_t_t<half,    float>;

template<typename block_q, short nl, void (*dequantize_func)(device const block_q *, short, thread float4x4 &)>
kernel void kernel_get_rows_q(
        constant ggml_metal_kargs_get_rows & args,
        device const void * src0,
        device const void * src1,
        device       void * dst,
        uint3               tgpig[[threadgroup_position_in_grid]],
        ushort              tiitg[[thread_index_in_threadgroup]],
        ushort3             ntg  [[threads_per_threadgroup]]) {
    const int32_t iw0 = tgpig.x/args.ne10;
    const int32_t i10 = tgpig.x%args.ne10;
    const int32_t i11 = tgpig.y;
    const int32_t i12 = tgpig.z;

    const int32_t r = ((const device int32_t *) ((const device char *) src1 + i12*args.nb12 + i11*args.nb11 + i10*args.nb10))[0];

    const int32_t i02 = i11;
    const int32_t i03 = i12;

    auto psrc = (device const block_q *) ((const device char *) src0 + i03*args.nb03 + i02*args.nb02 +   r*args.nb01);
    auto pdst = (device      float4x4 *) ((      device char *) dst  + i12*args.nb3  + i11*args.nb2  + i10*args.nb1);

    for (int ind = iw0*ntg.x + tiitg; ind < args.ne00t;) {
        float4x4 temp;
        dequantize_func(psrc + ind/nl, ind%nl, temp);
        pdst[ind] = temp;

        break;
    }
}

template<typename T0, typename T>
kernel void kernel_get_rows_f(
        constant ggml_metal_kargs_get_rows & args,
        device const void * src0,
        device const void * src1,
        device       void * dst,
        uint3               tgpig[[threadgroup_position_in_grid]],
        ushort              tiitg[[thread_index_in_threadgroup]],
        ushort3             ntg [[threads_per_threadgroup]]) {
    const int32_t iw0 = tgpig.x/args.ne10;
    const int32_t i10 = tgpig.x%args.ne10;
    const int32_t i11 = tgpig.y;
    const int32_t i12 = tgpig.z;

    const int32_t r = ((const device int32_t *) ((const device char *) src1 + i12*args.nb12 + i11*args.nb11 + i10*args.nb10))[0];

    const int32_t i02 = i11;
    const int32_t i03 = i12;

    auto psrc = (const device T0 *) ((const device char *) src0 + i03*args.nb03 + i02*args.nb02 +   r*args.nb01);
    auto pdst = (      device T  *) ((      device char *)  dst + i12*args.nb3  + i11*args.nb2  + i10*args.nb1);

    for (int ind = iw0*ntg.x + tiitg; ind < args.ne00t;) {
        pdst[ind] = psrc[ind];

        break;
    }
}

typedef decltype(kernel_get_rows_f<float, float>) get_rows_f_t;

template [[host_name("kernel_get_rows_f32")]]  kernel get_rows_f_t kernel_get_rows_f<float, float>;
template [[host_name("kernel_get_rows_f16")]]  kernel get_rows_f_t kernel_get_rows_f<half,  float>;

typedef decltype(kernel_get_rows_q<block_q8_0, 2, dequantize_q8_0>) get_rows_q_t;

template [[host_name("kernel_get_rows_q8_0")]]    kernel get_rows_q_t kernel_get_rows_q<block_q8_0,    2, dequantize_q8_0>;
