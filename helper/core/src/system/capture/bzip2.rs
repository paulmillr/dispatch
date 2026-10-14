//! Standalone streaming BZip2 codec. Uses only `std`; no direct OS calls or unsafe code.
//!
//! `Encoder::new(writer, 1..=9)` matches bzip2 1.0.8's default encoder.
//! `Decoder::new(reader, limit)` verifies checksums and decodes all
//! concatenated members, rejecting trailing garbage and expansion beyond `limit`.
//! Buffers are reused between blocks; memory does not grow with capture length.
//! Errors can leave a prefix in the sink; only successful completion and flush
//! indicate a complete capture. Underlying IO errors are forwarded unchanged.
//!
//! This is a new Rust implementation, not the original bzip2 software.
//! Sorting, Huffman tie decisions, and the randomization table follow bzip2 1.0.8.
//! Altered: incremental Encoder/Decoder APIs replace stream-local state; a checkpoint ends a member.
/*
Copyright (C) 1996-2019 Julian R Seward. All rights reserved.
Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.
2. The origin of this software must not be misrepresented; you must not claim
   that you wrote the original software. If you use this software in a product,
   an acknowledgment in the product documentation would be appreciated but
   is not required.
3. Altered source versions must be plainly marked as such, and must not be
   misrepresented as being the original software.
4. The name of the author may not be used to endorse or promote products
   derived from this software without specific prior written permission.
THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR IMPLIED
WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

use std::io::{self, BufRead, BufReader, BufWriter, Read, Write};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error {
    Level,
    Header,
    Truncated,
    Data,
    Checksum,
    Limit,
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Level => "bzip2 level must be 1..=9",
            Self::Header => "invalid BZip2 header",
            Self::Truncated => "truncated BZip2 stream",
            Self::Data => "invalid BZip2 data",
            Self::Checksum => "BZip2 checksum mismatch",
            Self::Limit => "BZip2 output limit exceeded",
        })
    }
}
impl std::error::Error for Error {}
impl From<Error> for io::Error {
    fn from(error: Error) -> Self {
        let kind = match error {
            Error::Level => io::ErrorKind::InvalidInput,
            Error::Truncated => io::ErrorKind::UnexpectedEof,
            _ => io::ErrorKind::InvalidData,
        };
        Self::new(kind, error)
    }
}

const BLOCK: u64 = 0x314159265359;
const END: u64 = 0x177245385090;
const CRC: [u32; 256] = {
    let mut table = [0; 256];
    let mut i = 0;
    loop {
        let mut sum = (i as u32) << 24;
        let mut bit = 0;
        loop {
            sum = (sum << 1) ^ if sum & 0x80000000 != 0 { 0x04c11db7 } else { 0 };
            bit += 1;
            if bit == 8 {
                break;
            }
        }
        table[i] = sum;
        i += 1;
        if i == table.len() {
            break;
        }
    }
    table
};
fn crc(mut sum: u32, data: impl IntoIterator<Item = u8>) -> u32 {
    for byte in data {
        sum = (sum << 8) ^ CRC[((sum >> 24) as u8 ^ byte) as usize];
    }
    sum
}
fn mtf(list: &mut [u8], pos: usize) -> u8 {
    let byte = list[pos];
    list.copy_within(..pos, 1);
    list[0] = byte;
    byte
}
struct Writer<W: Write> {
    data: BufWriter<W>,
    bits: u64,
    live: usize,
}
impl<W: Write> Writer<W> {
    fn put(&mut self, n: usize, value: u32) -> io::Result<()> {
        self.bits = (self.bits << n) | value as u64;
        self.live += n;
        for _ in 0..self.live / 8 {
            self.live -= 8;
            self.data.write_all(&[(self.bits >> self.live) as u8])?;
        }
        Ok(())
    }
    fn marker(&mut self, value: u64) -> io::Result<()> {
        self.put(24, (value >> 24) as u32)?;
        self.put(24, (value & 0xffffff) as u32)
    }
}
struct Reader<R: Read> {
    data: BufReader<R>,
    bits: u64,
    live: usize,
}
impl<R: Read> Reader<R> {
    fn get(&mut self, n: usize) -> io::Result<u32> {
        for _ in (self.live..n).step_by(8) {
            let mut byte = [0];
            self.data.read_exact(&mut byte)?;
            self.bits = (self.bits << 8) | byte[0] as u64;
            self.live += 8;
        }
        self.live -= n;
        Ok(((self.bits >> self.live) & ((1u64 << n) - 1)) as u32)
    }
}

#[derive(Clone, Copy)]
struct Huffman {
    lens: [u8; 258],
    codes: [u32; 258],
    count: [u32; 21],
    first: [u32; 21],
    base: [usize; 21],
    order: [usize; 258],
    alpha: usize,
    min: usize,
    max: usize,
}
impl Default for Huffman {
    fn default() -> Self {
        Self {
            lens: [0; 258],
            codes: [0; 258],
            count: [0; 21],
            first: [0; 21],
            base: [0; 21],
            order: [0; 258],
            alpha: 0,
            min: 0,
            max: 0,
        }
    }
}
impl Huffman {
    fn new(lens: &[u8]) -> Result<Self, Error> {
        let mut count = [0; 21];
        for &len in lens {
            if !(1..=20).contains(&len) {
                return Err(Error::Data);
            }
            count[len as usize] += 1;
        }
        let min = *lens.iter().min().ok_or(Error::Data)? as usize;
        let max = *lens.iter().max().unwrap() as usize;
        let mut first = [0; 21];
        let mut base = [0; 21];
        let mut codes = [0; 258];
        let mut order = [0; 258];
        let mut size = 0;
        let mut code = 0;
        for len in 1..=max {
            first[len] = code;
            base[len] = size;
            if code + count[len] > 1 << len {
                return Err(Error::Data);
            }
            for (sym, &n) in lens.iter().enumerate() {
                if n as usize == len {
                    codes[sym] = code;
                    code += 1;
                    order[size] = sym;
                    size += 1;
                }
            }
            code <<= 1;
        }
        let mut lengths = [0; 258];
        lengths[..lens.len()].copy_from_slice(lens);
        Ok(Self {
            lens: lengths,
            codes,
            count,
            first,
            base,
            order,
            alpha: lens.len(),
            min,
            max,
        })
    }
}

struct Heap {
    nodes: [usize; 260],
    weight: [u32; 516],
    len: usize,
}
impl Heap {
    fn push(&mut self, node: usize) {
        self.len += 1;
        let mut pos = self.len;
        for _ in 0..usize::BITS {
            if self.weight[node] >= self.weight[self.nodes[pos / 2]] {
                break;
            }
            self.nodes[pos] = self.nodes[pos / 2];
            pos /= 2;
        }
        self.nodes[pos] = node;
    }
    fn pop(&mut self) -> usize {
        let root = self.nodes[1];
        let node = self.nodes[self.len];
        self.len -= 1;
        let mut pos = 1;
        for _ in 0..usize::BITS {
            let mut child = pos * 2;
            if child > self.len {
                break;
            }
            if child < self.len
                && self.weight[self.nodes[child + 1]] < self.weight[self.nodes[child]]
            {
                child += 1;
            }
            if self.weight[node] < self.weight[self.nodes[child]] {
                break;
            }
            self.nodes[pos] = self.nodes[child];
            pos = child;
        }
        self.nodes[pos] = node;
        root
    }
}
// Bentley's equal-key partition, shared by both reference sorting paths.
fn partition(
    order: &mut [u32],
    lo: i32,
    hi: i32,
    pivot: u32,
    key: impl Fn(u32) -> u32,
) -> Option<(i32, i32)> {
    let (mut a, mut b, mut c, mut d) = (lo, hi, lo, hi);
    loop {
        loop {
            if a > b {
                break;
            }
            let value = key(order[a as usize]);
            if value == pivot {
                order.swap(a as usize, c as usize);
                c += 1;
                a += 1;
            } else if value > pivot {
                break;
            } else {
                a += 1;
            }
        }
        loop {
            if a > b {
                break;
            }
            let value = key(order[b as usize]);
            if value == pivot {
                order.swap(b as usize, d as usize);
                d -= 1;
                b -= 1;
            } else if value < pivot {
                break;
            } else {
                b -= 1;
            }
        }
        if a > b {
            break;
        }
        order.swap(a as usize, b as usize);
        a += 1;
        b -= 1;
    }
    if d < c {
        return None;
    }
    let n = (c - lo).min(a - c);
    for i in 0..n {
        order.swap((lo + i) as usize, (a - n + i) as usize);
    }
    let m = (hi - d).min(d - b);
    for i in 0..m {
        order.swap((a + i) as usize, (hi - m + 1 + i) as usize);
    }
    Some((lo + a - c - 1, hi - (d - b) + 1))
}
pub(crate) struct Sort {
    order: Vec<u32>,
    rank: Vec<u32>,
    heads: Vec<bool>,
    table: Vec<u32>,
    quad: Vec<u16>,
    stack: Vec<(i32, i32, usize)>,
}
impl Sort {
    pub(crate) fn new(cap: usize) -> Self {
        Self {
            order: Vec::with_capacity(cap),
            rank: Vec::with_capacity(cap),
            heads: Vec::with_capacity(cap + 1),
            table: vec![0; 65537],
            quad: Vec::with_capacity(cap + 34),
            stack: Vec::with_capacity(100),
        }
    }
    pub(crate) fn run(&mut self, block: &mut Vec<u8>) -> &[u32] {
        let n = block.len();
        self.order.resize(n, 0);
        self.rank.resize(n, 0);
        self.heads.resize(n + 1, false);
        self.quad.resize(n + 34, 0);
        let (order, rank, heads, table, quad, stack) = (
            &mut self.order,
            &mut self.rank,
            &mut self.heads,
            &mut self.table,
            &mut self.quad,
            &mut self.stack,
        );
        let mut budget = if n < 10000 {
            -1
        } else {
            (n * ((30 - 1) / 3)) as i32
        };
        const FLAG: u32 = 1 << 21;
        if n >= 10000 {
            block.extend_from_within(..34);
            table.fill(0);
            quad.fill(0);
            for i in (0..n).rev() {
                table[((block[i] as usize) << 8) | block[i + 1] as usize] += 1;
            }
            for i in 1..table.len() {
                table[i] += table[i - 1];
            }
            for i in (0..n).rev() {
                let key = ((block[i] as usize) << 8) | block[i + 1] as usize;
                table[key] -= 1;
                order[table[key] as usize] = i as u32;
            }
            let mut running: [usize; 256] = std::array::from_fn(|i| i);
            let mut done = [false; 256];
            let mut gap = 1;
            loop {
                gap = 3 * gap + 1;
                if gap > running.len() {
                    break;
                }
            }
            loop {
                gap /= 3;
                for i in gap..running.len() {
                    let value = running[i];
                    let mut j = i;
                    for _ in 0..i / gap {
                        let a = running[j - gap];
                        if table[(a + 1) << 8] - table[a << 8]
                            <= table[(value + 1) << 8] - table[value << 8]
                        {
                            break;
                        }
                        running[j] = a;
                        j -= gap;
                        if j < gap {
                            break;
                        }
                    }
                    running[j] = value;
                }
                if gap == 1 {
                    break;
                }
            }
            'main: for (iteration, &ss) in running.iter().enumerate() {
                for j in 0..256 {
                    if j == ss {
                        continue;
                    }
                    let bucket = (ss << 8) + j;
                    if table[bucket] & FLAG == 0 {
                        let lo = (table[bucket] & !FLAG) as i32;
                        let hi = (table[bucket + 1] & !FLAG) as i32 - 1;
                        if hi > lo {
                            stack.clear();
                            stack.push((lo, hi, 2));
                            for _ in 0..usize::MAX {
                                let Some((lo, hi, depth)) = stack.pop() else {
                                    break;
                                };
                                if hi - lo < 20 || depth > 14 {
                                    let width = hi - lo + 1;
                                    if width < 2 {
                                        continue;
                                    }
                                    let mut gap = 1;
                                    for _ in 0..usize::BITS {
                                        if gap >= width {
                                            break;
                                        }
                                        gap = 3 * gap + 1;
                                    }
                                    for _ in 0..usize::BITS {
                                        gap /= 3;
                                        if gap == 0 {
                                            break;
                                        }
                                        for start in (lo + gap..=hi).step_by(3) {
                                            for i in start..=hi.min(start + 2) {
                                                let value = order[i as usize];
                                                let mut j = i;
                                                loop {
                                                    let greater = 'compare: {
                                                        let mut a = order[(j - gap) as usize]
                                                            as usize
                                                            + depth;
                                                        let mut b = value as usize + depth;
                                                        for _ in 0..12 {
                                                            if block[a] != block[b] {
                                                                break 'compare block[a] > block[b];
                                                            }
                                                            a += 1;
                                                            b += 1;
                                                        }
                                                        for _ in 0..n / 8 + 2 {
                                                            for _ in 0..8 {
                                                                if block[a] != block[b] {
                                                                    break 'compare block[a]
                                                                        > block[b];
                                                                }
                                                                if quad[a] != quad[b] {
                                                                    break 'compare quad[a]
                                                                        > quad[b];
                                                                }
                                                                a += 1;
                                                                b += 1;
                                                            }
                                                            if a >= n {
                                                                a -= n;
                                                            }
                                                            if b >= n {
                                                                b -= n;
                                                            }
                                                            budget -= 1;
                                                        }
                                                        false
                                                    };
                                                    if !greater {
                                                        break;
                                                    }
                                                    order[j as usize] = order[(j - gap) as usize];
                                                    j -= gap;
                                                    if j < lo + gap {
                                                        break;
                                                    }
                                                }
                                                order[j as usize] = value;
                                            }
                                            if budget < 0 {
                                                break 'main;
                                            }
                                        }
                                    }
                                    if budget < 0 {
                                        break 'main;
                                    }
                                    continue;
                                }
                                let a = block[order[lo as usize] as usize + depth];
                                let b = block[order[hi as usize] as usize + depth];
                                let c = block[order[((lo + hi) / 2) as usize] as usize + depth];
                                let pivot = a.min(b).max(a.max(b).min(c)) as u32;
                                let Some((left, right)) = partition(order, lo, hi, pivot, |i| {
                                    block[i as usize + depth] as u32
                                }) else {
                                    stack.push((lo, hi, depth + 1));
                                    continue;
                                };
                                let mut next = [
                                    (lo, left, depth),
                                    (right, hi, depth),
                                    (left + 1, right - 1, depth + 1),
                                ];
                                for (a, b) in [(0, 1), (1, 2), (0, 1)] {
                                    if next[a].1 - next[a].0 < next[b].1 - next[b].0 {
                                        next.swap(a, b);
                                    }
                                }
                                stack.extend(next);
                            }
                        }
                    }
                    table[bucket] |= FLAG;
                }
                let mut starts = [0i32; 256];
                let mut ends = [0i32; 256];
                for j in 0..256 {
                    starts[j] = (table[(j << 8) + ss] & !FLAG) as i32;
                    ends[j] = (table[(j << 8) + ss + 1] & !FLAG) as i32 - 1;
                }
                for j in (table[ss << 8] & !FLAG) as i32..n as i32 {
                    if j >= starts[ss] {
                        break;
                    }
                    let index = (order[j as usize] as usize + n - 1) % n;
                    let byte = block[index] as usize;
                    if !done[byte] {
                        order[starts[byte] as usize] = index as u32;
                        starts[byte] += 1;
                    }
                }
                for j in (0..=(table[(ss + 1) << 8] & !FLAG) as i32 - 1).rev() {
                    if j <= ends[ss] {
                        break;
                    }
                    let index = (order[j as usize] as usize + n - 1) % n;
                    let byte = block[index] as usize;
                    if !done[byte] {
                        order[ends[byte] as usize] = index as u32;
                        ends[byte] -= 1;
                    }
                }
                for j in 0..256 {
                    table[(j << 8) + ss] |= FLAG;
                }
                done[ss] = true;
                if iteration < 255 {
                    let start = (table[ss << 8] & !FLAG) as usize;
                    let size = (table[(ss + 1) << 8] & !FLAG) as usize - start;
                    let shift = (0..usize::BITS).find(|&s| size >> s <= 65534).unwrap();
                    for j in (0..size).rev() {
                        let index = order[start + j] as usize;
                        let value = (j >> shift) as u16;
                        quad[index] = value;
                        if index < 34 {
                            quad[n + index] = value;
                        }
                    }
                }
            }
        }
        if budget < 0 {
            table[..257].fill(0);
            heads.fill(false);
            for &b in &block[..n] {
                table[b as usize] += 1;
            }
            for i in 1..257 {
                table[i] += table[i - 1];
            }
            for (i, &b) in block[..n].iter().enumerate() {
                table[b as usize] -= 1;
                order[table[b as usize] as usize] = i as u32;
            }
            for &pos in &table[..256] {
                heads[pos as usize] = true;
            }
            heads[n] = true;
            for depth in (0..usize::BITS).map(|s| 1usize << s) {
                if depth > n {
                    break;
                }
                let mut class = 0;
                for i in 0..n {
                    if heads[i] {
                        class = i as u32;
                    }
                    rank[(order[i] as usize + n - depth) % n] = class;
                }
                let mut lo = 0;
                let mut remaining = 0;
                for _ in 0..n {
                    if lo == n {
                        break;
                    }
                    let end = (lo + 1..=n).find(|&i| heads[i]).unwrap();
                    if end - lo > 1 {
                        remaining += end - lo;
                        stack.clear();
                        stack.push((lo as i32, end as i32 - 1, 0));
                        let mut random = 0u32;
                        for _ in 0..usize::MAX {
                            let Some((lo, hi, _)) = stack.pop() else {
                                break;
                            };
                            if hi - lo < 10 {
                                for gap in [4, 1] {
                                    if gap == 4 && hi - lo <= 3 {
                                        continue;
                                    }
                                    for i in (lo..=hi - gap).rev() {
                                        let value = order[i as usize];
                                        let key = rank[value as usize];
                                        let mut j = i + gap;
                                        for _ in 0..n {
                                            if j > hi || key <= rank[order[j as usize] as usize] {
                                                break;
                                            }
                                            order[(j - gap) as usize] = order[j as usize];
                                            j += gap;
                                        }
                                        order[(j - gap) as usize] = value;
                                    }
                                }
                                continue;
                            }
                            random = (random * 7621 + 1) % 32768;
                            let index = match random % 3 {
                                0 => lo,
                                1 => (lo + hi) / 2,
                                _ => hi,
                            };
                            let pivot = rank[order[index as usize] as usize];
                            if let Some((left, right)) =
                                partition(order, lo, hi, pivot, |i| rank[i as usize])
                            {
                                if left - lo > hi - right {
                                    stack.push((lo, left, 0));
                                    stack.push((right, hi, 0));
                                } else {
                                    stack.push((right, hi, 0));
                                    stack.push((lo, left, 0));
                                }
                            }
                        }
                        let mut previous = u32::MAX;
                        for i in lo..end {
                            let value = rank[order[i] as usize];
                            if previous != value {
                                heads[i] = true;
                                previous = value;
                            }
                        }
                    }
                    lo = end;
                }
                if remaining == 0 {
                    break;
                }
            }
        }
        block.truncate(n);
        order
    }
}

/// Incremental member encoder. `finish` writes the trailer and flushes the sink.
pub struct Encoder<W: Write> {
    bits: Writer<W>,
    cap: usize,
    combined: u32,
    sum: u32,
    last: u8,
    run: usize,
    block: Vec<u8>,
    sorting: Sort,
    symbols: Vec<u16>,
    selectors: Vec<u8>,
    failed: bool,
    active: bool,
}
impl<W: Write> Encoder<W> {
    pub fn new(output: W, level: u8) -> io::Result<Self> {
        if !(1..=9).contains(&level) {
            return Err(Error::Level.into());
        }
        let cap = level as usize * 100000;
        let mut bits = Writer {
            data: BufWriter::new(output),
            bits: 0,
            live: 0,
        };
        bits.put(24, 0x425a68)?;
        bits.put(8, (b'0' + level) as u32)?;
        Ok(Self {
            bits,
            cap,
            combined: 0,
            sum: !0,
            last: 0,
            run: 0,
            block: Vec::with_capacity(cap + 34),
            sorting: Sort::new(cap),
            symbols: Vec::with_capacity(cap + 1),
            selectors: Vec::with_capacity((cap + 1).div_ceil(50)),
            failed: false,
            active: true,
        })
    }
    fn run(&mut self) {
        if self.run != 0 {
            self.block
                .extend(std::iter::repeat_n(self.last, self.run.min(4)));
            if self.run >= 4 {
                self.block.push((self.run - 4) as u8);
            }
            self.sum = crc(self.sum, std::iter::repeat_n(self.last, self.run));
            self.run = 0;
        }
    }
    fn block(&mut self) -> io::Result<()> {
        if self.block.is_empty() {
            return Ok(());
        }
        let sum = !std::mem::replace(&mut self.sum, !0);
        self.combined = self.combined.rotate_left(1) ^ sum;
        let Self {
            bits,
            block,
            sorting,
            symbols,
            selectors,
            ..
        } = self;
        let n = block.len();
        let order = sorting.run(block);
        let origin = order.iter().position(|&i| i == 0).unwrap();
        let mut used = [false; 256];
        for &b in block.iter() {
            used[b as usize] = true;
        }
        let mut list = [0u8; 256];
        let mut size = 0;
        for byte in 0..=255 {
            if used[byte as usize] {
                list[size] = byte;
                size += 1;
            }
        }
        let alpha = size + 2;
        let list = &mut list[..size];
        symbols.clear();
        let mut run = 0usize;
        for i in 0..=n {
            let index = if i == n {
                1
            } else {
                let b = block[(order[i] as usize + n - 1) % n];
                list.iter().position(|&v| v == b).unwrap()
            };
            if index == 0 {
                run += 1;
                continue;
            }
            for _ in 0..usize::BITS {
                if run == 0 {
                    break;
                }
                run -= 1;
                symbols.push((run & 1) as u16);
                run >>= 1;
            }
            if i == n {
                symbols.push((alpha - 1) as u16);
            } else {
                mtf(list, index);
                symbols.push((index + 1) as u16);
            }
        }
        // These table counts, partitions, and four passes follow libbzip2's encoder.
        let groups = 2 + [200, 600, 1200, 2400]
            .iter()
            .filter(|&&v| symbols.len() >= v)
            .count();
        let mut freq = [0usize; 258];
        for &s in symbols.iter() {
            freq[s as usize] += 1;
        }
        let mut lens = [[15u8; 258]; 6];
        let mut remaining = symbols.len();
        let mut start = 0;
        for parts in (1..=groups).rev() {
            let target = remaining / parts;
            let mut end = start;
            let mut total = 0;
            for &f in &freq[start..alpha] {
                if total >= target {
                    break;
                }
                total += f;
                end += 1;
            }
            if end > start + 1 && parts != groups && parts != 1 && (groups - parts) % 2 == 1 {
                end -= 1;
                total -= freq[end];
            }
            lens[parts - 1][start..end].fill(0);
            start = end;
            remaining -= total;
        }
        for _ in 0..4 {
            let mut freq = [[0u32; 258]; 6];
            selectors.clear();
            for chunk in symbols.chunks(50) {
                let group = (0..groups)
                    .min_by_key(|&g| {
                        chunk
                            .iter()
                            .map(|&s| lens[g][s as usize] as u32)
                            .sum::<u32>()
                    })
                    .unwrap();
                selectors.push(group as u8);
                for &s in chunk {
                    freq[group][s as usize] += 1;
                }
            }
            for (g, freq) in freq[..groups].iter_mut().enumerate() {
                let mut heap = Heap {
                    nodes: [0; 260],
                    weight: [0; 516],
                    len: 0,
                };
                for (i, &f) in freq[..alpha].iter().enumerate() {
                    heap.weight[i + 1] = f.max(1) << 8;
                }
                loop {
                    heap.len = 0;
                    let mut parent = [usize::MAX; 516];
                    for i in 1..=alpha {
                        heap.push(i);
                    }
                    for i in alpha + 1..2 * alpha {
                        let a = heap.pop();
                        let b = heap.pop();
                        parent[a] = i;
                        parent[b] = i;
                        let (a, b) = (heap.weight[a], heap.weight[b]);
                        heap.weight[i] = ((a & !255) + (b & !255)) | (1 + (a & 255).max(b & 255));
                        heap.push(i);
                    }
                    for (i, len) in lens[g][..alpha].iter_mut().enumerate() {
                        let mut pos = i + 1;
                        *len = 0;
                        for _ in 0..alpha {
                            if parent[pos] == usize::MAX {
                                break;
                            }
                            *len += 1;
                            pos = parent[pos];
                        }
                    }
                    if lens[g][..alpha].iter().all(|&v| v <= 17) {
                        break;
                    }
                    for f in &mut heap.weight[1..=alpha] {
                        *f = (1 + (*f >> 8) / 2) << 8;
                    }
                }
            }
        }
        let mut tables = [Huffman::default(); 6];
        for g in 0..groups {
            tables[g] = Huffman::new(&lens[g][..alpha])?;
        }
        bits.marker(BLOCK)?;
        bits.put(32, sum)?;
        bits.put(1, 0)?;
        bits.put(24, origin as u32)?;
        for chunk in used.chunks(16) {
            bits.put(1, chunk.iter().any(|&v| v) as u32)?;
        }
        for chunk in used.chunks(16) {
            if chunk.iter().any(|&v| v) {
                for &v in chunk {
                    bits.put(1, v as u32)?;
                }
            }
        }
        bits.put(3, groups as u32)?;
        bits.put(15, selectors.len() as u32)?;
        let mut list: [u8; 6] = std::array::from_fn(|i| i as u8);
        let list = &mut list[..groups];
        for &g in selectors.iter() {
            let pos = list.iter().position(|&v| v == g).unwrap();
            mtf(list, pos);
            for _ in 0..pos {
                bits.put(1, 1)?;
            }
            bits.put(1, 0)?;
        }
        for table in &tables[..groups] {
            let mut current = table.lens[0];
            bits.put(5, current as u32)?;
            for &len in &table.lens[..table.alpha] {
                for _ in 0..current.abs_diff(len) {
                    bits.put(2, if current < len { 2 } else { 3 })?;
                    if current < len {
                        current += 1;
                    } else {
                        current -= 1;
                    }
                }
                bits.put(1, 0)?;
            }
        }
        for (chunk, &g) in symbols.chunks(50).zip(selectors.iter()) {
            let table = &tables[g as usize];
            for &s in chunk {
                bits.put(table.lens[s as usize] as usize, table.codes[s as usize])?;
            }
        }
        block.clear();
        Ok(())
    }
    pub fn checkpoint(&mut self) -> io::Result<()> {
        if self.failed {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "bzip2 encoder previously failed",
            ));
        }
        let result = (|| {
            if self.active {
                self.run();
                self.block()?;
                self.bits.marker(END)?;
                self.bits.put(32, self.combined)?;
                if self.bits.live != 0 {
                    self.bits.put(8 - self.bits.live, 0)?;
                }
                self.active = false;
                self.combined = 0;
            }
            self.bits.data.flush()
        })();
        if result.is_err() {
            self.failed = true;
        }
        result
    }
    pub fn finish(mut self) -> io::Result<W> {
        self.checkpoint()?;
        self.bits
            .data
            .into_inner()
            .map_err(|error| error.into_error())
    }
}
impl<W: Write> Write for Encoder<W> {
    fn write(&mut self, mut bytes: &[u8]) -> io::Result<usize> {
        if self.failed {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "bzip2 encoder previously failed",
            ));
        }
        let count = bytes.len();
        let result = (|| {
            if !self.active && !bytes.is_empty() {
                self.bits.put(24, 0x425a68)?;
                self.bits
                    .put(8, (b'0' + (self.cap / 100000) as u8) as u32)?;
                self.active = true;
            }
            for _ in 0.. {
                if self.block.len() >= self.cap - 19 {
                    self.block()?;
                }
                if bytes.is_empty() {
                    return Ok(count);
                }
                if self.run < 255 && (self.run == 0 || bytes[0] == self.last) {
                    self.last = bytes[0];
                    let n = bytes[..bytes.len().min(255 - self.run)]
                        .iter()
                        .take_while(|&&b| b == self.last)
                        .count();
                    self.run += n;
                    bytes = &bytes[n..];
                } else {
                    self.run();
                }
            }
            unreachable!()
        })();
        if result.is_err() {
            self.failed = true;
        }
        result
    }
    fn flush(&mut self) -> io::Result<()> {
        if self.failed {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "bzip2 encoder previously failed",
            ));
        }
        let result = self.bits.data.flush();
        if result.is_err() {
            self.failed = true;
        }
        result
    }
}
/// Incremental decoder. EOF certifies all members/checksums and the expansion bound.
pub struct Decoder<R: Read> {
    bits: Reader<R>,
    block: Vec<u8>,
    next: Vec<u32>,
    selectors: Vec<u8>,
    cap: usize,
    combined: u32,
    limit: usize,
    total: usize,
    expected: u32,
    sum: u32,
    pos: usize,
    used: usize,
    last: u8,
    repeats: usize,
    pending: usize,
    randomized: bool,
    remaining: u16,
    random: usize,
    active: bool,
    finished: bool,
    failed: bool,
}
impl<R: Read> Decoder<R> {
    pub fn new(input: R, limit: usize) -> io::Result<Self> {
        Ok(Self {
            bits: Reader {
                data: BufReader::new(input),
                bits: 0,
                live: 0,
            },
            block: Vec::with_capacity(900000),
            next: Vec::with_capacity(900000),
            selectors: Vec::with_capacity(32767),
            cap: 0,
            combined: 0,
            limit,
            total: 0,
            expected: 0,
            sum: !0,
            pos: 0,
            used: 0,
            last: 0,
            repeats: 0,
            pending: 0,
            randomized: false,
            remaining: 0,
            random: 0,
            active: false,
            finished: false,
            failed: false,
        })
    }
    fn block(&mut self) -> io::Result<()> {
        let bits = &mut self.bits;
        let block = &mut self.block;
        let next = &mut self.next;
        let selectors = &mut self.selectors;
        for _ in 0.. {
            if self.cap == 0 {
                let header = bits.get(32)?;
                let level = header & 255;
                if header >> 8 != 0x425a68 || !(b'1' as u32..=b'9' as u32).contains(&level) {
                    return Err(Error::Header.into());
                }
                self.cap = (level - b'0' as u32) as usize * 100000;
                self.combined = 0;
            }
            let cap = self.cap;
            let marker = ((bits.get(24)? as u64) << 24) | bits.get(24)? as u64;
            if marker == END {
                if bits.get(32)? != self.combined {
                    return Err(Error::Checksum.into());
                }
                bits.live = 0;
                if bits.data.fill_buf()?.is_empty() {
                    self.finished = true;
                    return Ok(());
                }
                self.cap = 0;
                continue;
            }
            if marker != BLOCK {
                return Err(Error::Data.into());
            }
            let expected = bits.get(32)?;
            let randomized = bits.get(1)? != 0;
            let origin = bits.get(24)? as usize;
            if origin >= cap {
                return Err(Error::Data.into());
            }
            let mask = bits.get(16)?;
            let mut alphabet = [0u8; 256];
            let mut size = 0;
            for g in 0..16 {
                if mask & (1 << (15 - g)) == 0 {
                    continue;
                }
                let mask = bits.get(16)?;
                for b in 0..16 {
                    if mask & (1 << (15 - b)) != 0 {
                        alphabet[size] = (g * 16 + b) as u8;
                        size += 1;
                    }
                }
            }
            if size == 0 {
                return Err(Error::Data.into());
            }
            let alpha = size + 2;
            let groups = bits.get(3)? as usize;
            let count = bits.get(15)? as usize;
            if !(2..=6).contains(&groups) || count == 0 {
                return Err(Error::Data.into());
            }
            let mut list: [u8; 6] = std::array::from_fn(|i| i as u8);
            selectors.clear();
            for _ in 0..count {
                let mut pos = 0;
                for _ in 0..groups {
                    if bits.get(1)? == 0 {
                        break;
                    }
                    pos += 1;
                }
                if pos >= groups {
                    return Err(Error::Data.into());
                }
                selectors.push(mtf(&mut list[..groups], pos));
            }
            let mut tables = [Huffman::default(); 6];
            for table in &mut tables[..groups] {
                let mut current = bits.get(5)? as i32;
                let mut lens = [0u8; 258];
                for len in &mut lens[..alpha] {
                    loop {
                        if !(1..=20).contains(&current) {
                            return Err(Error::Data.into());
                        }
                        if bits.get(1)? == 0 {
                            break;
                        }
                        current += if bits.get(1)? == 0 { 1 } else { -1 };
                    }
                    *len = current as u8;
                }
                *table = Huffman::new(&lens[..alpha])?;
            }
            block.clear();
            let mut run = 0usize;
            let mut power = 1usize;
            let mut ended = false;
            'symbols: for &g in selectors.iter() {
                for _ in 0..50 {
                    let table = &tables[g as usize];
                    let s = 'code: {
                        let mut code = bits.get(table.min)?;
                        for len in table.min..=table.max {
                            if code >= table.first[len]
                                && code - table.first[len] < table.count[len]
                            {
                                break 'code table.order
                                    [table.base[len] + (code - table.first[len]) as usize];
                            }
                            if len != table.max {
                                code = (code << 1) | bits.get(1)?;
                            }
                        }
                        return Err(Error::Data.into());
                    };
                    if s < 2 {
                        let add = power * (s + 1);
                        if add > cap - block.len() - run {
                            return Err(Error::Data.into());
                        }
                        run += add;
                        power *= 2;
                        continue;
                    }
                    if run != 0 {
                        block.resize(block.len() + run, alphabet[0]);
                        run = 0;
                        power = 1;
                    }
                    if s == alpha - 1 {
                        ended = true;
                        break 'symbols;
                    }
                    if s - 1 >= size || block.len() == cap {
                        return Err(Error::Data.into());
                    }
                    block.push(mtf(&mut alphabet[..size], s - 1));
                }
            }
            if !ended || origin >= block.len() {
                return Err(Error::Data.into());
            }
            let mut count = [0usize; 256];
            for &b in block.iter() {
                count[b as usize] += 1;
            }
            let mut start = 0;
            for n in &mut count {
                let old = *n;
                *n = start;
                start += old;
            }
            next.resize(block.len(), 0u32);
            for (i, &b) in block.iter().enumerate() {
                next[count[b as usize]] = i as u32;
                count[b as usize] += 1;
            }
            self.expected = expected;
            self.sum = !0;
            self.pos = next[origin] as usize;
            self.used = block.len();
            self.repeats = 0;
            self.last = 0;
            self.remaining = 0;
            self.random = 0;
            self.pending = 0;
            self.randomized = randomized;
            self.active = true;
            return Ok(());
        }
        unreachable!()
    }
}
impl<R: Read> Read for Decoder<R> {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        if self.failed {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "bzip2 decoder previously failed",
            ));
        }
        if bytes.is_empty() {
            return Ok(0);
        }
        let result = (|| {
            let mut written = 0;
            for _ in 0.. {
                if self.pending != 0 {
                    let count = self.pending.min(bytes.len() - written);
                    bytes[written..written + count].fill(self.last);
                    self.sum = crc(self.sum, bytes[written..written + count].iter().copied());
                    self.total += count;
                    self.pending -= count;
                    written += count;
                }
                if written == bytes.len() {
                    return Ok(written);
                }
                if self.used != 0 {
                    let mut byte = self.block[self.pos];
                    self.pos = self.next[self.pos] as usize;
                    self.used -= 1;
                    if self.randomized {
                        if self.remaining == 0 {
                            self.remaining = RANDOM[self.random];
                            self.random = (self.random + 1) % RANDOM.len();
                        }
                        self.remaining -= 1;
                        byte ^= (self.remaining == 1) as u8;
                    }
                    let count = if self.repeats == 4 {
                        self.repeats = 0;
                        byte as usize
                    } else {
                        if byte == self.last {
                            self.repeats += 1;
                        } else {
                            self.last = byte;
                            self.repeats = 1;
                        }
                        1
                    };
                    if count > self.limit - self.total {
                        return Err(Error::Limit.into());
                    }
                    self.pending = count;
                    continue;
                }
                if self.active {
                    if self.repeats == 4 {
                        return Err(Error::Data.into());
                    }
                    if !self.sum != self.expected {
                        return Err(Error::Checksum.into());
                    }
                    self.combined = self.combined.rotate_left(1) ^ !self.sum;
                    self.active = false;
                    if written != 0 {
                        return Ok(written);
                    }
                }
                if self.finished {
                    return Ok(written);
                }
                self.block()?;
            }
            unreachable!()
        })();
        if result.is_err() {
            self.failed = true;
        }
        result
    }
}
/// Decode all BZip2 members, with a caller-specified maximum expanded length.
#[cfg(test)]
pub fn decompress<R: Read, W: Write>(input: R, output: W, limit: usize) -> io::Result<()> {
    let mut decoder = Decoder::new(input, limit)?;
    let mut output = BufWriter::new(output);
    io::copy(&mut decoder, &mut output)?;
    output.flush()
}

// Format-mandated historical table: bzip2 1.0.6 randtable.c, Julian Seward.
const RANDOM: [u16; 512] = [
    619, 720, 127, 481, 931, 816, 813, 233, 566, 247, 985, 724, 205, 454, 863, 491, 741, 242, 949,
    214, 733, 859, 335, 708, 621, 574, 73, 654, 730, 472, 419, 436, 278, 496, 867, 210, 399, 680,
    480, 51, 878, 465, 811, 169, 869, 675, 611, 697, 867, 561, 862, 687, 507, 283, 482, 129, 807,
    591, 733, 623, 150, 238, 59, 379, 684, 877, 625, 169, 643, 105, 170, 607, 520, 932, 727, 476,
    693, 425, 174, 647, 73, 122, 335, 530, 442, 853, 695, 249, 445, 515, 909, 545, 703, 919, 874,
    474, 882, 500, 594, 612, 641, 801, 220, 162, 819, 984, 589, 513, 495, 799, 161, 604, 958, 533,
    221, 400, 386, 867, 600, 782, 382, 596, 414, 171, 516, 375, 682, 485, 911, 276, 98, 553, 163,
    354, 666, 933, 424, 341, 533, 870, 227, 730, 475, 186, 263, 647, 537, 686, 600, 224, 469, 68,
    770, 919, 190, 373, 294, 822, 808, 206, 184, 943, 795, 384, 383, 461, 404, 758, 839, 887, 715,
    67, 618, 276, 204, 918, 873, 777, 604, 560, 951, 160, 578, 722, 79, 804, 96, 409, 713, 940,
    652, 934, 970, 447, 318, 353, 859, 672, 112, 785, 645, 863, 803, 350, 139, 93, 354, 99, 820,
    908, 609, 772, 154, 274, 580, 184, 79, 626, 630, 742, 653, 282, 762, 623, 680, 81, 927, 626,
    789, 125, 411, 521, 938, 300, 821, 78, 343, 175, 128, 250, 170, 774, 972, 275, 999, 639, 495,
    78, 352, 126, 857, 956, 358, 619, 580, 124, 737, 594, 701, 612, 669, 112, 134, 694, 363, 992,
    809, 743, 168, 974, 944, 375, 748, 52, 600, 747, 642, 182, 862, 81, 344, 805, 988, 739, 511,
    655, 814, 334, 249, 515, 897, 955, 664, 981, 649, 113, 974, 459, 893, 228, 433, 837, 553, 268,
    926, 240, 102, 654, 459, 51, 686, 754, 806, 760, 493, 403, 415, 394, 687, 700, 946, 670, 656,
    610, 738, 392, 760, 799, 887, 653, 978, 321, 576, 617, 626, 502, 894, 679, 243, 440, 680, 879,
    194, 572, 640, 724, 926, 56, 204, 700, 707, 151, 457, 449, 797, 195, 791, 558, 945, 679, 297,
    59, 87, 824, 713, 663, 412, 693, 342, 606, 134, 108, 571, 364, 631, 212, 174, 643, 304, 329,
    343, 97, 430, 751, 497, 314, 983, 374, 822, 928, 140, 206, 73, 263, 980, 736, 876, 478, 430,
    305, 170, 514, 364, 692, 829, 82, 855, 953, 676, 246, 369, 970, 294, 750, 807, 827, 150, 790,
    288, 923, 804, 378, 215, 828, 592, 281, 565, 555, 710, 82, 896, 831, 547, 261, 524, 462, 293,
    465, 502, 56, 661, 821, 976, 991, 658, 869, 905, 758, 745, 193, 768, 550, 608, 933, 378, 286,
    215, 979, 792, 961, 61, 688, 793, 644, 986, 403, 106, 366, 905, 644, 372, 567, 466, 434, 645,
    210, 389, 550, 919, 135, 780, 773, 635, 389, 707, 100, 626, 958, 165, 504, 920, 176, 193, 713,
    857, 265, 203, 50, 668, 108, 645, 990, 626, 197, 510, 357, 358, 850, 858, 364, 936, 638,
];

#[cfg(test)]
#[path = "bzip2.test.rs"]
mod tests;
