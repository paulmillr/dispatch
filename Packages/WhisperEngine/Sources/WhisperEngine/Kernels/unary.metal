// Adapted from ggml (whisper.cpp 1.9.5), ggml/src/ggml-metal/kernels/unary.metal.
// MIT License, Copyright (c) 2023-2026 The ggml authors. See PROVENANCE.md for the full notice and the
// list of changes.

#include "common.h"

constant short FC_unary_op [[function_constant(FC_UNARY + 0)]];
constant bool  FC_unary_cnt[[function_constant(FC_UNARY + 1)]];

template <typename T0, typename T, typename TC>
kernel void kernel_unary_impl(
        constant ggml_metal_kargs_unary & args,
        device const char * src0,
        device       char * dst,
        uint3   tgpig[[threadgroup_position_in_grid]],
        ushort3 tpitg[[thread_position_in_threadgroup]],
        ushort3   ntg[[threads_per_threadgroup]]) {
#define FC_OP  FC_unary_op
#define FC_CNT FC_unary_cnt

    device const T0 * src0_ptr;
    device       T  * dst_ptr;

    int i0;

    if (FC_CNT) {
        i0 = tgpig.x;

        src0_ptr = (device const T0 *) (src0);
        dst_ptr  = (device       T  *) (dst);
    } else {
        const int i03 = tgpig.z;
        const int i02 = tgpig.y;
        const int k0  = tgpig.x/args.ne01;
        const int i01 = tgpig.x - k0*args.ne01;

        i0 = k0*ntg.x + tpitg.x;

        src0_ptr = (device const T0 *) (src0 + i03*args.nb03 + i02*args.nb02 + i01*args.nb01);
        dst_ptr  = (device       T  *) (dst  + i03*args.nb3  + i02*args.nb2  + i01*args.nb1 );
    }

    {
        //threadgroup_barrier(mem_flags::mem_none);

        if (!FC_CNT) {
            if (i0 >= args.ne0) {
                return;
            }
        }

        const TC x = (TC) src0_ptr[i0];

        if (FC_OP == OP_UNARY_NUM_GELU) {
            dst_ptr[i0] = (T) (0.5*x*(1 + precise::tanh(SQRT_2_OVER_PI*x*(1 + GELU_COEF_A*x*x))));
        }
    }

#undef FC_OP
#undef FC_CNT
}

typedef decltype(kernel_unary_impl<float, float, float>) kernel_unary_t;

template [[host_name("kernel_unary_f32_f32")]]   kernel kernel_unary_t kernel_unary_impl<float,  float,  float>;
template [[host_name("kernel_unary_f32_f32_4")]] kernel kernel_unary_t kernel_unary_impl<float4, float4, float4>;
