//! Numbers both ways, matching yyjson 0.12: literal classification, correctly rounded reals,
//! and yyjson's shortest-digit real layout.

use super::read::byte;

/// Number subtype bits in a node tag (shifted by `super::SUBTYPE`).
pub(super) const UNSIGNED: u64 = 0;
pub(super) const SIGNED: u64 = 1;
pub(super) const REAL: u64 = 2;
const INVALID: u32 = 9;

/// Top 128 bits (floor) of 10^e for e in -343..=324, as (high, low).
pub(super) const POW10: [(u64, u64); 668] = pow10();
const POW10_MIN: i32 = -343;
/// Exponent of `pow10_sig_table` range ends in yyjson, used for its fast reader path.
const DEC_MAX: i32 = 308;

/// Fixed-width big integer for exact table generation: 2^1280 / 10^343 still has > 128 bits.
const LIMBS: usize = 21;
const fn top(a: &[u64; LIMBS]) -> (u64, u64) {
    let mut h = LIMBS - 1;
    loop {
        if a[h] != 0 || h == 0 {
            break;
        }
        h -= 1;
    }
    let word = (a[h] as u128) << 64 | if h >= 1 { a[h - 1] as u128 } else { 0 };
    let next = if h >= 2 { a[h - 2] as u128 } else { 0 };
    let shift = a[h].leading_zeros();
    let bits = if shift == 0 {
        word
    } else {
        word << shift | next >> (64 - shift)
    };
    ((bits >> 64) as u64, bits as u64)
}
const fn pow10() -> [(u64, u64); 668] {
    let mut table = [(0, 0); 668];
    let mut up = [0u64; LIMBS];
    up[0] = 1;
    let mut down = [0u64; LIMBS];
    down[LIMBS - 1] = 1;
    let mut e = 0;
    loop {
        if e <= 324 {
            table[(e - POW10_MIN) as usize] = top(&up);
            let (mut carry, mut i) = (0u128, 0);
            loop {
                if i == LIMBS {
                    break;
                }
                let t = up[i] as u128 * 10 + carry;
                up[i] = t as u64;
                carry = t >> 64;
                i += 1;
            }
        }
        if e >= 1 && e <= -POW10_MIN {
            let (mut rem, mut i) = (0u128, LIMBS);
            loop {
                if i == 0 {
                    break;
                }
                i -= 1;
                let t = rem << 64 | down[i] as u128;
                down[i] = (t / 10) as u64;
                rem = t % 10;
            }
            table[(-e - POW10_MIN) as usize] = top(&down);
        }
        if e == 343 {
            break;
        }
        e += 1;
    }
    table
}
/// 10^0..=10^22, the powers exact in f64.
const EXACT: [f64; 23] = {
    let mut table = [1.0; 23];
    let mut i = 1;
    loop {
        if i == 23 {
            break;
        }
        table[i] = table[i - 1] * 10.0;
        i += 1;
    }
    table
};
/// "00".."99".
const PAIRS: [u8; 200] = {
    let mut table = [0; 200];
    let mut i = 0;
    loop {
        if i == 100 {
            break;
        }
        table[i * 2] = b'0' + (i / 10) as u8;
        table[i * 2 + 1] = b'0' + (i % 10) as u8;
        i += 1;
    }
    table
};

fn mul(a: u64, b: u64) -> (u64, u64) {
    let m = a as u128 * b as u128;
    ((m >> 64) as u64, m as u64)
}

/// Length of the digit run at `at`; the zero padding ends every run.
#[inline(always)]
fn run(text: &[u8], at: usize) -> usize {
    text[at..]
        .iter()
        .position(|b| !b.is_ascii_digit())
        .unwrap_or(0)
}

/// Number literal at `at` (starts with one of `.-+0-9`; only `-` and digits can be valid).
/// yyjson's (code, position).
#[inline(always)]
pub(super) fn read(text: &[u8], at: usize) -> Result<(u64, u64, usize), (u32, usize)> {
    let negative = byte(text, at) == b'-';
    let int = at + negative as usize;
    let mut p = int;
    // Integer part, accumulated in the same pass (exact up to 19 digits).
    let mut value = 0u64;
    if byte(text, p) == b'0' {
        p += 1;
        if byte(text, p).is_ascii_digit() {
            return Err((INVALID, p - 1));
        }
    } else if byte(text, p).is_ascii_digit() {
        loop {
            let d = byte(text, p).wrapping_sub(b'0');
            if d > 9 {
                break;
            }
            value = value.wrapping_mul(10).wrapping_add(d as u64);
            p += 1;
        }
    } else {
        return Err((INVALID, p));
    }
    let digits = p - int;
    let next = byte(text, p);
    if next != b'.' && next | 0x20 != b'e' && digits < 20 {
        // The common case: an integer that fits u64 exactly.
        return Ok(match (negative, value <= 1 << 63) {
            (false, _) => (UNSIGNED, value, p),
            (true, true) => (SIGNED, value.wrapping_neg(), p),
            (true, false) => (REAL, (-(value as f64)).to_bits(), p),
        });
    }
    let fraction = next == b'.';
    if fraction {
        p += 1;
        let n = run(text, p);
        if n == 0 {
            return Err((INVALID, p));
        }
        p += n;
    }
    let exponent = byte(text, p) | 0x20 == b'e';
    if exponent {
        p += 1;
        p += matches!(byte(text, p), b'+' | b'-') as usize;
        let n = run(text, p);
        if n == 0 {
            return Err((INVALID, p));
        }
        p += n;
    }
    if !fraction && !exponent && digits == 20 {
        // Twenty digits may still fit u64.
        let value = text[int..p].iter().try_fold(0u64, |v, &d| {
            v.checked_mul(10)?.checked_add((d - b'0') as u64)
        });
        if let Some(v) = value {
            return Ok(match (negative, v <= 1 << 63) {
                (false, _) => (UNSIGNED, v, p),
                (true, true) => (SIGNED, v.wrapping_neg(), p),
                (true, false) => (REAL, (-(v as f64)).to_bits(), p),
            });
        }
    }
    let real = fast(&text[int..p]).unwrap_or_else(|| {
        // SAFETY: the literal was checked to be ASCII number grammar above.
        unsafe { std::str::from_utf8_unchecked(&text[int..p]) }
            .parse::<f64>()
            .unwrap()
    });
    if real.is_infinite() {
        return Err((INVALID, at));
    }
    Ok((REAL, (if negative { -real } else { real }).to_bits(), p))
}

/// Unsigned real from a valid literal without sign, when the fast paths decide it exactly.
fn fast(literal: &[u8]) -> Option<f64> {
    let (mut sig, mut kept, mut exp, mut cut, mut fraction) = (0u64, 0, 0i64, false, false);
    let mut end = literal.len();
    for (i, &c) in literal.iter().enumerate() {
        match c {
            b'.' => fraction = true,
            b'e' | b'E' => {
                end = i;
                break;
            }
            _ if sig == 0 && c == b'0' => exp -= fraction as i64,
            _ if kept < 19 => {
                sig = sig * 10 + (c - b'0') as u64;
                kept += 1;
                exp -= fraction as i64;
            }
            _ => {
                cut |= c != b'0';
                exp += !fraction as i64;
            }
        }
    }
    if end < literal.len() {
        let (negative, digits) = match literal[end + 1] {
            b'-' => (true, &literal[end + 2..]),
            b'+' => (false, &literal[end + 2..]),
            _ => (false, &literal[end + 1..]),
        };
        // Clamped far beyond any reachable exponent; only over/underflow is decided by it.
        let value = digits
            .iter()
            .fold(0i64, |v, &d| (v * 10 + (d - b'0') as i64).min(1 << 50));
        exp += if negative { -value } else { value };
    }
    if sig == 0 {
        return Some(0.0);
    }
    if cut {
        return None;
    }
    if sig < 1 << 53 && exp.abs() <= 22 {
        let v = sig as f64;
        return Some(if exp < 0 {
            v / EXACT[-exp as usize]
        } else {
            v * EXACT[exp as usize]
        });
    }
    if exp <= (1 - DEC_MAX) as i64 || exp >= (DEC_MAX - 20) as i64 {
        return None;
    }
    // yyjson's 128-bit path: sig * 10^exp, accepted when the dropped bits cannot change rounding.
    let exp = exp as i32;
    let (p_hi, p_lo) = POW10[(exp - POW10_MIN) as usize];
    let shift = sig.leading_zeros();
    let sig = sig << shift;
    let mut exp2 = ((exp * 217706 - 4128768) >> 16) - shift as i32;
    let (mut hi, lo) = mul(sig, p_hi);
    let bits = hi & ((1 << 9) - 1);
    if bits.wrapping_sub(1) >= (1 << 9) - 2 {
        let (hi2, _) = mul(sig, p_lo);
        let add = lo.wrapping_add(hi2);
        if add.wrapping_add(1) <= 1 {
            return None;
        }
        hi += (add < lo || add < hi2) as u64;
    }
    let shift = (hi < 1 << 63) as u32;
    hi <<= shift;
    exp2 += 64 - shift as i32;
    hi = hi.wrapping_add(hi & (1 << 10));
    if hi < 1 << 10 {
        hi = 1 << 63;
        exp2 += 1;
    }
    let raw = ((exp2 + 63 + 1023) as u64) << 52 | (hi >> 11) & ((1 << 52) - 1);
    Some(f64::from_bits(raw))
}

fn count(v: u64) -> usize {
    v.checked_ilog10().map_or(1, |log| log as usize + 1)
}
/// Writes the `n` decimal digits of `v` at `dst`, two at a time from the end.
/// SAFETY: `n == count(v)` bytes writable at `dst`.
unsafe fn digits(mut v: u64, n: usize, dst: *mut u8) {
    let mut at = n;
    loop {
        if v < 10 {
            // SAFETY: one digit left at index 0.
            unsafe { *dst = b'0' + v as u8 };
            return;
        }
        let pair = (v % 100) as usize * 2;
        at -= 2;
        // SAFETY: at + 2 <= n.
        unsafe {
            dst.add(at)
                .copy_from_nonoverlapping(PAIRS.as_ptr().add(pair), 2)
        };
        v /= 100;
        if v == 0 {
            return;
        }
    }
}

/// Text of one number: `bytes[..len]`. 40 bytes fit any i64, u64 or yyjson real layout.
pub(super) struct Text {
    pub bytes: [u8; 40],
    pub len: usize,
}
impl Text {
    fn push(&mut self, bytes: &[u8]) {
        self.bytes[self.len..self.len + bytes.len()].copy_from_slice(bytes);
        self.len += bytes.len();
    }
    fn zeros(&mut self, n: usize) {
        self.bytes[self.len..self.len + n].fill(b'0');
        self.len += n;
    }
}

/// Writes `v` at `dst`, returns its length.
/// SAFETY: 20 bytes writable at `dst`.
#[inline(always)]
pub(super) unsafe fn unsigned(v: u64, dst: *mut u8) -> usize {
    // Small values (the common case) without counting digits.
    if v < 100 {
        let small = (v < 10) as usize;
        // SAFETY: two bytes writable; a one-digit value keeps the second of its pair.
        unsafe { dst.copy_from_nonoverlapping(PAIRS.as_ptr().add(v as usize * 2 + small), 2) };
        return 2 - small;
    }
    if v < 10_000 {
        // Both pairs in one little-endian word; a three-digit value drops its leading '0'.
        let pair =
            |p: u64| u16::from_le_bytes([PAIRS[p as usize * 2], PAIRS[p as usize * 2 + 1]]) as u32;
        let small = (v < 1000) as u32;
        let word = (pair(v / 100) | pair(v % 100) << 16) >> (8 * small);
        // SAFETY: four bytes writable; the byte past a three-digit value is scratch.
        unsafe { dst.cast::<u32>().write_unaligned(word.to_le()) };
        return 4 - small as usize;
    }
    let n = count(v);
    // SAFETY: n <= 20.
    unsafe { digits(v, n, dst) };
    n
}
/// Writes `v` at `dst`, returns its length.
/// SAFETY: 21 bytes writable at `dst`.
#[inline(always)]
pub(super) unsafe fn signed(v: i64, dst: *mut u8) -> usize {
    let sign = (v < 0) as usize;
    // SAFETY: as documented; the sign takes one byte when present.
    unsafe {
        *dst = b'-';
        sign + unsigned(v.unsigned_abs(), dst.add(sign))
    }
}

/// yyjson layout: fixed when the decimal point falls in (-6, 21], else d.ddde[-]x; always a
/// '.' or 'e' so the value reads back as real. None for NaN and infinity.
/// The old Foundation writer's text for a real (Darwin NSJSONSerialization = C "%.17g"):
/// 17 significant digits, trailing zeros dropped, exponent form below 1e-4 or from 1e17 with a
/// sign and at least two exponent digits (C-JSON-NUMBER, tests/fixtures/json/foundation-numbers).
pub(super) fn foundation(v: f64) -> Option<Text> {
    if !v.is_finite() {
        return None;
    }
    let mut out = Text {
        bytes: [0; 40],
        len: 0,
    };
    // Correctly rounded 17 significant digits, like printf.
    let scientific = format!("{v:.16e}");
    let (mantissa, exponent) = scientific.split_once('e')?;
    let exponent: i32 = exponent.parse().ok()?;
    if mantissa.starts_with('-') {
        out.push(b"-");
    }
    let digits: Vec<u8> = mantissa.bytes().filter(u8::is_ascii_digit).collect();
    let kept = &digits[..digits.iter().rposition(|&d| d != b'0').map_or(1, |i| i + 1)];
    if !(-4..17).contains(&exponent) {
        out.push(&kept[..1]);
        if kept.len() > 1 {
            out.push(b".");
            out.push(&kept[1..]);
        }
        out.push(if exponent < 0 { b"e-" } else { b"e+" });
        out.push(format!("{:02}", exponent.unsigned_abs()).as_bytes());
    } else if exponent < 0 {
        out.push(b"0.");
        out.zeros(-exponent as usize - 1);
        out.push(kept);
    } else {
        let point = exponent as usize + 1;
        out.push(&digits[..point]);
        if kept.len() > point {
            out.push(b".");
            out.push(&kept[point..]);
        }
    }
    Some(out)
}

pub(super) fn real(v: f64) -> Option<Text> {
    if !v.is_finite() {
        return None;
    }
    let mut out = Text {
        bytes: [0; 40],
        len: v.is_sign_negative() as usize,
    };
    out.bytes[0] = b'-';
    if v == 0.0 {
        out.push(b"0.0");
        return Some(out);
    }
    let (sig, exp) = shortest(v.to_bits());
    let mut buf = [0; 20];
    // SAFETY: a u64 has at most 20 digits.
    unsafe { digits(sig, count(sig), buf.as_mut_ptr()) };
    let all = &buf[..count(sig)];
    let kept = &all[..all.iter().rposition(|&d| d != b'0').unwrap() + 1];
    let dot = all.len() as i32 + exp;
    if -6 < dot && dot <= 0 {
        out.push(b"0.");
        out.zeros(-dot as usize);
        out.push(kept);
    } else if 0 < dot && dot <= 21 {
        let dot = dot as usize;
        if kept.len() <= dot {
            out.push(kept);
            out.zeros(dot - kept.len());
            out.push(b".0");
        } else {
            out.push(&kept[..dot]);
            out.push(b".");
            out.push(&kept[dot..]);
        }
    } else {
        out.push(&kept[..1]);
        if kept.len() > 1 {
            out.push(b".");
            out.push(&kept[1..]);
        }
        out.push(b"e");
        // SAFETY: 40 bytes hold the layout above (at most 1 + 17 + 1 + 1) plus 21.
        out.len += unsafe { signed((dot - 1) as i64, out.bytes.as_mut_ptr().add(out.len)) };
    }
    Some(out)
}

/// yyjson f64_bin_to_dec: shortest decimal (sig, exp10) for a finite non-zero double,
/// possibly with trailing zeros in sig.
fn shortest(raw: u64) -> (u64, i32) {
    let sig_raw = raw & ((1 << 52) - 1);
    let exp_raw = ((raw >> 52) & 0x7FF) as i32;
    let (sig_bin, exp_bin) = if exp_raw != 0 {
        (sig_raw | 1 << 52, exp_raw - 1075)
    } else {
        (sig_raw, -1074)
    };
    // Fast path: 10^k scaled so one decimal digit stays below the cut; decide from the
    // half-ulp interval whether the last digit can be dropped or rounded.
    if sig_raw != 0 {
        let k = (exp_bin * 315653) >> 20;
        let h = exp_bin + ((-k * 217707) >> 16);
        let (p_hi, p_lo) = POW10[(-k - POW10_MIN) as usize];
        let cb = sig_bin << (h + 1);
        let (s_hi, _) = mul(cb, p_lo);
        let m = cb as u128 * p_hi as u128 + s_hi as u128;
        let (s_hi, s_lo) = ((m >> 64) as u64, m as u64);
        let modulo = s_hi % 10;
        let dec = s_hi - modulo;
        let c = (modulo << 60) | (s_lo >> 4);
        let half = p_hi >> (4 - h);
        let w1 = s_lo >= 1 << 63;
        let u0 = half >= c;
        let t0 = 10u64 << 60;
        let t1 = c.wrapping_add(half);
        let w0 = t1 >= t0;
        if s_lo != 1 << 63 && half != c && t0.wrapping_sub(t1) > 1 {
            let add = if u0 | w0 {
                if w0 { 10 } else { 0 }
            } else {
                modulo + w1 as u64
            };
            return (dec + add, k);
        }
    }
    // Schubfach (Giulietti 2022), as in yyjson.
    let irregular = sig_raw == 0 && exp_raw > 1;
    let even = sig_bin & 1 == 0;
    let (cbl, cb, cbr) = (
        4 * sig_bin - 2 + irregular as u64,
        4 * sig_bin,
        4 * sig_bin + 2,
    );
    let k = (exp_bin * 315653 - if irregular { 131237 } else { 0 }) >> 20;
    let h = exp_bin + ((-k * 217707) >> 16) + 1;
    let (p_hi, p_lo) = POW10[(-k - POW10_MIN) as usize];
    let p_lo = p_lo + 1;
    let odd = |cp: u64| {
        let (x_hi, _) = mul(cp, p_lo);
        let m = cp as u128 * p_hi as u128 + x_hi as u128;
        (m >> 64) as u64 | ((m as u64) > 1) as u64
    };
    let (vbl, vb, vbr) = (odd(cbl << h), odd(cb << h), odd(cbr << h));
    let lower = vbl + !even as u64;
    let upper = vbr - !even as u64;
    let s = vb / 4;
    if s >= 10 {
        let sp = s / 10;
        let u0 = lower <= 40 * sp;
        let w0 = upper >= 40 * sp + 40;
        if u0 != w0 {
            return (sp * 10 + if w0 { 10 } else { 0 }, k);
        }
    }
    let u1 = lower <= 4 * s;
    let w1 = upper >= 4 * s + 4;
    let mid = 4 * s + 2;
    let up = vb > mid || (vb == mid && s & 1 != 0);
    (s + if u1 != w1 { w1 as u64 } else { up as u64 }, k)
}
