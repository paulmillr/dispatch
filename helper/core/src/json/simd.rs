//! Byte classification one chunk at a time. Every implementation gives the same answers;
//! wider ones only take bigger steps. Masks are per-lane booleans (top bit of each lane).

pub(super) trait Lanes {
    const WIDTH: usize;
    type V: Copy;
    /// SAFETY: `WIDTH` bytes readable at `at`.
    unsafe fn load(at: *const u8) -> Self::V;
    /// SAFETY: `WIDTH` bytes writable at `at`.
    unsafe fn store(at: *mut u8, v: Self::V);
    fn eq(v: Self::V, byte: u8) -> Self::V;
    /// Unsigned `v < byte`, for `1 <= byte <= 0x80`.
    fn below(v: Self::V, byte: u8) -> Self::V;
    /// `v >= 0x80`.
    fn high(v: Self::V) -> Self::V;
    fn or(a: Self::V, b: Self::V) -> Self::V;
    fn not(m: Self::V) -> Self::V;
    /// Index of the first true lane, `WIDTH` when none.
    fn first(m: Self::V) -> usize;
    /// Has a wide UTF-8 validator (`utf8` is meaningful).
    const UTF8: bool;
    /// Lanes before `n` from `a`, the rest from `b` (n <= WIDTH).
    fn merge(a: Self::V, b: Self::V, n: usize) -> Self::V;
    /// Whole chunk is valid UTF-8 when it starts at a sequence boundary; a sequence cut off
    /// by the chunk end counts as valid.
    fn utf8(v: Self::V) -> bool;
}

/// Lane indices 0..32, for "lanes before n" masks.
const LANES: [u8; 32] = {
    let mut lanes = [0; 32];
    let mut i = 0;
    loop {
        if i == 32 {
            break lanes;
        }
        lanes[i] = i as u8;
        i += 1;
    }
};

/// Eight lanes in a u64; any target. Masks keep 0x80 per true lane, computed exactly.
#[derive(Clone, Copy)]
pub(super) struct Swar;
const ONES: u64 = u64::MAX / 255;
const HIGH: u64 = ONES * 0x80;
impl Lanes for Swar {
    const WIDTH: usize = 8;
    type V = u64;
    #[inline(always)]
    unsafe fn load(at: *const u8) -> u64 {
        // SAFETY: caller guarantees 8 readable bytes.
        u64::from_le(unsafe { at.cast::<u64>().read_unaligned() })
    }
    #[inline(always)]
    unsafe fn store(at: *mut u8, v: u64) {
        // SAFETY: caller guarantees 8 writable bytes.
        unsafe { at.cast::<u64>().write_unaligned(v.to_le()) }
    }
    #[inline(always)]
    fn eq(v: u64, byte: u8) -> u64 {
        Self::below(v ^ (ONES * byte as u64), 1)
    }
    #[inline(always)]
    fn below(v: u64, byte: u8) -> u64 {
        // Low 7 bits plus (0x80 - byte) reach 0x80 exactly when the lane is >= byte; no carries.
        !(((v & !HIGH) + ONES * (0x80 - byte as u64)) | v) & HIGH
    }
    #[inline(always)]
    fn high(v: u64) -> u64 {
        v & HIGH
    }
    #[inline(always)]
    fn or(a: u64, b: u64) -> u64 {
        a | b
    }
    #[inline(always)]
    fn not(m: u64) -> u64 {
        !m & HIGH
    }
    #[inline(always)]
    fn first(m: u64) -> usize {
        (m.trailing_zeros() / 8) as usize
    }
    const UTF8: bool = false;
    fn utf8(_: u64) -> bool {
        unreachable!()
    }
    #[inline(always)]
    fn merge(a: u64, b: u64, n: usize) -> u64 {
        let low = if n >= 8 {
            u64::MAX
        } else {
            (1u64 << (8 * n)) - 1
        };
        a & low | b & !low
    }
}

/// Keiser-Lemire UTF-8 check ("Validating UTF-8 In Less Than One Instruction Per Byte",
/// 2021): each byte pair is looked up by high nibble of the first byte, low nibble of the
/// first byte and high nibble of the second; any common error bit is an error. Third and
/// fourth bytes of long sequences must be continuations exactly where two-byte checks
/// cannot tell.
mod utf8 {
    const TOO_SHORT: u8 = 1 << 0;
    const TOO_LONG: u8 = 1 << 1;
    const OVERLONG_3: u8 = 1 << 2;
    const TOO_LARGE: u8 = 1 << 3;
    const SURROGATE: u8 = 1 << 4;
    const OVERLONG_2: u8 = 1 << 5;
    const TOO_LARGE_1000: u8 = 1 << 6;
    const OVERLONG_4: u8 = 1 << 6;
    const TWO_CONTS: u8 = 1 << 7;
    const CARRY: u8 = TOO_SHORT | TOO_LONG | TWO_CONTS;
    const LARGE: u8 = CARRY | TOO_LARGE | TOO_LARGE_1000;
    pub const FIRST_HIGH: [u8; 16] = [
        TOO_LONG,
        TOO_LONG,
        TOO_LONG,
        TOO_LONG,
        TOO_LONG,
        TOO_LONG,
        TOO_LONG,
        TOO_LONG,
        TWO_CONTS,
        TWO_CONTS,
        TWO_CONTS,
        TWO_CONTS,
        TOO_SHORT | OVERLONG_2,
        TOO_SHORT,
        TOO_SHORT | OVERLONG_3 | SURROGATE,
        TOO_SHORT | TOO_LARGE | TOO_LARGE_1000 | OVERLONG_4,
    ];
    pub const FIRST_LOW: [u8; 16] = [
        CARRY | OVERLONG_3 | OVERLONG_2 | OVERLONG_4,
        CARRY | OVERLONG_2,
        CARRY,
        CARRY,
        CARRY | TOO_LARGE,
        LARGE,
        LARGE,
        LARGE,
        LARGE,
        LARGE,
        LARGE,
        LARGE,
        LARGE,
        LARGE | SURROGATE,
        LARGE,
        LARGE,
    ];
    const CONT: u8 = TOO_LONG | OVERLONG_2 | TWO_CONTS;
    pub const SECOND_HIGH: [u8; 16] = [
        TOO_SHORT,
        TOO_SHORT,
        TOO_SHORT,
        TOO_SHORT,
        TOO_SHORT,
        TOO_SHORT,
        TOO_SHORT,
        TOO_SHORT,
        CONT | OVERLONG_3 | TOO_LARGE_1000 | OVERLONG_4,
        CONT | OVERLONG_3 | TOO_LARGE,
        CONT | SURROGATE | TOO_LARGE,
        CONT | SURROGATE | TOO_LARGE,
        TOO_SHORT,
        TOO_SHORT,
        TOO_SHORT,
        TOO_SHORT,
    ];
    /// Lanes holding a third (prev2 >= 0xE0) or fourth (prev3 >= 0xF0) byte position.
    pub const THIRD: u8 = 0xE0 - 0x80;
    pub const FOURTH: u8 = 0xF0 - 0x80;
}

#[cfg(target_arch = "x86_64")]
mod x86 {
    use super::{LANES, Lanes, utf8};
    use std::arch::x86_64::*;

    #[derive(Clone, Copy)]
    pub struct Sse2;
    impl Lanes for Sse2 {
        const WIDTH: usize = 16;
        type V = __m128i;
        #[inline(always)]
        unsafe fn load(at: *const u8) -> __m128i {
            // SAFETY: caller guarantees 16 readable bytes; unaligned load.
            unsafe { _mm_loadu_si128(at.cast()) }
        }
        #[inline(always)]
        unsafe fn store(at: *mut u8, v: __m128i) {
            // SAFETY: caller guarantees 16 writable bytes; unaligned store.
            unsafe { _mm_storeu_si128(at.cast(), v) }
        }
        #[inline(always)]
        fn eq(v: __m128i, byte: u8) -> __m128i {
            // SAFETY: SSE2 is part of the x86_64 baseline.
            unsafe { _mm_cmpeq_epi8(v, _mm_set1_epi8(byte as i8)) }
        }
        #[inline(always)]
        fn below(v: __m128i, byte: u8) -> __m128i {
            // SAFETY: SSE2 baseline. v < byte <=> min(v, byte - 1) == v.
            unsafe { _mm_cmpeq_epi8(_mm_min_epu8(v, _mm_set1_epi8((byte - 1) as i8)), v) }
        }
        #[inline(always)]
        fn high(v: __m128i) -> __m128i {
            v
        }
        #[inline(always)]
        fn or(a: __m128i, b: __m128i) -> __m128i {
            // SAFETY: SSE2 baseline.
            unsafe { _mm_or_si128(a, b) }
        }
        #[inline(always)]
        fn not(m: __m128i) -> __m128i {
            // SAFETY: SSE2 baseline.
            unsafe { _mm_xor_si128(m, _mm_set1_epi8(-1)) }
        }
        #[inline(always)]
        fn first(m: __m128i) -> usize {
            // SAFETY: SSE2 baseline.
            (unsafe { _mm_movemask_epi8(m) } as u32 | 1 << 16).trailing_zeros() as usize
        }
        const UTF8: bool = false;
        fn utf8(_: __m128i) -> bool {
            unreachable!()
        }
        #[inline(always)]
        fn merge(a: __m128i, b: __m128i, n: usize) -> __m128i {
            // SAFETY: SSE2 baseline; n <= 16 fits a signed byte compare.
            unsafe {
                let first = _mm_cmpgt_epi8(
                    _mm_set1_epi8(n as i8),
                    _mm_loadu_si128(LANES.as_ptr().cast()),
                );
                _mm_or_si128(_mm_and_si128(first, a), _mm_andnot_si128(first, b))
            }
        }
    }

    /// Only reached through `avx2` (target_feature entry), which inlines these.
    #[derive(Clone, Copy)]
    pub struct Avx2;
    impl Lanes for Avx2 {
        const WIDTH: usize = 32;
        type V = __m256i;
        #[inline(always)]
        unsafe fn load(at: *const u8) -> __m256i {
            // SAFETY: caller guarantees 32 readable bytes; AVX2 checked at dispatch.
            unsafe { _mm256_loadu_si256(at.cast()) }
        }
        #[inline(always)]
        unsafe fn store(at: *mut u8, v: __m256i) {
            // SAFETY: caller guarantees 32 writable bytes; AVX2 checked at dispatch.
            unsafe { _mm256_storeu_si256(at.cast(), v) }
        }
        #[inline(always)]
        fn eq(v: __m256i, byte: u8) -> __m256i {
            // SAFETY: AVX2 checked at dispatch.
            unsafe { _mm256_cmpeq_epi8(v, _mm256_set1_epi8(byte as i8)) }
        }
        #[inline(always)]
        fn below(v: __m256i, byte: u8) -> __m256i {
            // SAFETY: AVX2 checked at dispatch.
            unsafe { _mm256_cmpeq_epi8(_mm256_min_epu8(v, _mm256_set1_epi8((byte - 1) as i8)), v) }
        }
        #[inline(always)]
        fn high(v: __m256i) -> __m256i {
            v
        }
        #[inline(always)]
        fn or(a: __m256i, b: __m256i) -> __m256i {
            // SAFETY: AVX2 checked at dispatch.
            unsafe { _mm256_or_si256(a, b) }
        }
        #[inline(always)]
        fn not(m: __m256i) -> __m256i {
            // SAFETY: AVX2 checked at dispatch.
            unsafe { _mm256_xor_si256(m, _mm256_set1_epi8(-1)) }
        }
        #[inline(always)]
        fn first(m: __m256i) -> usize {
            // SAFETY: AVX2 checked at dispatch.
            (unsafe { _mm256_movemask_epi8(m) } as u32 as u64 | 1 << 32).trailing_zeros() as usize
        }
        const UTF8: bool = true;
        #[inline(always)]
        fn merge(a: __m256i, b: __m256i, n: usize) -> __m256i {
            // SAFETY: AVX2 checked at dispatch; n <= 32 fits a signed byte compare.
            unsafe {
                let lanes = _mm256_loadu_si256(LANES.as_ptr().cast());
                let first = _mm256_cmpgt_epi8(_mm256_set1_epi8(n as i8), lanes);
                _mm256_blendv_epi8(b, a, first)
            }
        }
        #[inline(always)]
        fn utf8(v: __m256i) -> bool {
            // SAFETY: AVX2 checked at dispatch.
            unsafe {
                let table =
                    |t: [u8; 16]| _mm256_broadcastsi128_si256(_mm_loadu_si128(t.as_ptr().cast()));
                let nibble = _mm256_set1_epi8(0x0F);
                // Lanes shifted toward the end by N, zeros shifted in (chunk starts a sequence).
                let low = _mm256_permute2x128_si256(v, v, 0x08);
                let prev1 = _mm256_alignr_epi8(v, low, 15);
                let prev2 = _mm256_alignr_epi8(v, low, 14);
                let prev3 = _mm256_alignr_epi8(v, low, 13);
                let high = |x| _mm256_and_si256(_mm256_srli_epi16(x, 4), nibble);
                let special = _mm256_and_si256(
                    _mm256_and_si256(
                        _mm256_shuffle_epi8(table(utf8::FIRST_HIGH), high(prev1)),
                        _mm256_shuffle_epi8(
                            table(utf8::FIRST_LOW),
                            _mm256_and_si256(prev1, nibble),
                        ),
                    ),
                    _mm256_shuffle_epi8(table(utf8::SECOND_HIGH), high(v)),
                );
                let must = _mm256_or_si256(
                    _mm256_subs_epu8(prev2, _mm256_set1_epi8(utf8::THIRD as i8)),
                    _mm256_subs_epu8(prev3, _mm256_set1_epi8(utf8::FOURTH as i8)),
                );
                let must = _mm256_and_si256(must, _mm256_set1_epi8(0x80u8 as i8));
                let error = _mm256_xor_si256(must, special);
                _mm256_testz_si256(error, error) == 1
            }
        }
    }
}
#[cfg(target_arch = "x86_64")]
pub(super) use x86::{Avx2, Sse2};

#[cfg(target_arch = "aarch64")]
mod arm {
    use super::{LANES, Lanes, utf8};
    use std::arch::aarch64::*;

    #[derive(Clone, Copy)]
    pub struct Neon;
    impl Lanes for Neon {
        const WIDTH: usize = 16;
        type V = uint8x16_t;
        #[inline(always)]
        unsafe fn load(at: *const u8) -> uint8x16_t {
            // SAFETY: caller guarantees 16 readable bytes.
            unsafe { vld1q_u8(at) }
        }
        #[inline(always)]
        unsafe fn store(at: *mut u8, v: uint8x16_t) {
            // SAFETY: caller guarantees 16 writable bytes.
            unsafe { vst1q_u8(at, v) }
        }
        #[inline(always)]
        fn eq(v: uint8x16_t, byte: u8) -> uint8x16_t {
            // SAFETY: NEON is part of the aarch64 baseline.
            unsafe { vceqq_u8(v, vdupq_n_u8(byte)) }
        }
        #[inline(always)]
        fn below(v: uint8x16_t, byte: u8) -> uint8x16_t {
            // SAFETY: NEON baseline.
            unsafe { vcltq_u8(v, vdupq_n_u8(byte)) }
        }
        #[inline(always)]
        fn high(v: uint8x16_t) -> uint8x16_t {
            // SAFETY: NEON baseline.
            unsafe { vcltzq_s8(vreinterpretq_s8_u8(v)) }
        }
        #[inline(always)]
        fn or(a: uint8x16_t, b: uint8x16_t) -> uint8x16_t {
            // SAFETY: NEON baseline.
            unsafe { vorrq_u8(a, b) }
        }
        #[inline(always)]
        fn not(m: uint8x16_t) -> uint8x16_t {
            // SAFETY: NEON baseline.
            unsafe { vmvnq_u8(m) }
        }
        #[inline(always)]
        fn first(m: uint8x16_t) -> usize {
            // SAFETY: NEON baseline. Narrowing shift packs each lane mask into 4 bits.
            let bits = unsafe {
                vget_lane_u64(
                    vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(m), 4)),
                    0,
                )
            };
            if bits == 0 {
                16
            } else {
                (bits.trailing_zeros() / 4) as usize
            }
        }
        const UTF8: bool = true;
        #[inline(always)]
        fn merge(a: uint8x16_t, b: uint8x16_t, n: usize) -> uint8x16_t {
            // SAFETY: NEON baseline.
            unsafe {
                vbslq_u8(
                    vcltq_u8(vld1q_u8(LANES.as_ptr()), vdupq_n_u8(n as u8)),
                    a,
                    b,
                )
            }
        }
        #[inline(always)]
        fn utf8(v: uint8x16_t) -> bool {
            // SAFETY: NEON baseline.
            unsafe {
                let zero = vdupq_n_u8(0);
                let prev1 = vextq_u8(zero, v, 15);
                let prev2 = vextq_u8(zero, v, 14);
                let prev3 = vextq_u8(zero, v, 13);
                let table = |t: [u8; 16]| vld1q_u8(t.as_ptr());
                let special = vandq_u8(
                    vandq_u8(
                        vqtbl1q_u8(table(utf8::FIRST_HIGH), vshrq_n_u8(prev1, 4)),
                        vqtbl1q_u8(table(utf8::FIRST_LOW), vandq_u8(prev1, vdupq_n_u8(0x0F))),
                    ),
                    vqtbl1q_u8(table(utf8::SECOND_HIGH), vshrq_n_u8(v, 4)),
                );
                let must = vorrq_u8(
                    vqsubq_u8(prev2, vdupq_n_u8(utf8::THIRD)),
                    vqsubq_u8(prev3, vdupq_n_u8(utf8::FOURTH)),
                );
                let error = veorq_u8(vandq_u8(must, vdupq_n_u8(0x80)), special);
                vmaxvq_u8(error) == 0
            }
        }
    }
}
#[cfg(target_arch = "aarch64")]
pub(super) use arm::Neon;

/// Define `fn $name` that runs `$body` with `$L` bound to the best implementation for this
/// CPU, chosen per call. The body is inlined into one function per ISA; the AVX2 one is a
/// `target_feature` function, so its intrinsics inline too.
macro_rules! dispatch {
    ($vis:vis fn $name:ident<$L:ident>($($arg:ident: $ty:ty),*) -> $ret:ty $body:block) => {
        $vis fn $name($($arg: $ty),*) -> $ret {
            use $crate::json::simd::{Isa, Lanes, isa};
            #[inline(always)]
            fn generic<$L: Lanes>($($arg: $ty),*) -> $ret $body
            match isa() {
                #[cfg(target_arch = "x86_64")]
                Isa::Avx2 => {
                    #[target_feature(enable = "avx2")]
                    unsafe fn avx2($($arg: $ty),*) -> $ret {
                        generic::<$crate::json::simd::Avx2>($($arg),*)
                    }
                    // SAFETY: isa() reports AVX2 only when the CPU has it.
                    unsafe { avx2($($arg),*) }
                }
                #[cfg(target_arch = "x86_64")]
                Isa::Sse2 => generic::<$crate::json::simd::Sse2>($($arg),*),
                #[cfg(target_arch = "aarch64")]
                Isa::Neon => generic::<$crate::json::simd::Neon>($($arg),*),
                Isa::Swar => generic::<$crate::json::simd::Swar>($($arg),*),
            }
        }
    };
}
pub(super) use dispatch;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Isa {
    Swar,
    #[cfg(target_arch = "x86_64")]
    Sse2,
    #[cfg(target_arch = "x86_64")]
    Avx2,
    #[cfg(target_arch = "aarch64")]
    Neon,
}

#[inline(always)]
pub(super) fn isa() -> Isa {
    #[cfg(target_arch = "x86_64")]
    return if std::arch::is_x86_feature_detected!("avx2") {
        Isa::Avx2
    } else {
        Isa::Sse2
    };
    #[cfg(target_arch = "aarch64")]
    return Isa::Neon;
    #[allow(unreachable_code)]
    Isa::Swar
}
