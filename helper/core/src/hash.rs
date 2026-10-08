//! Incremental SHA-256, following FIPS 180-4, sections 5 and 6.2.

pub struct Sha256 {
    state: [u32; 8],
    block: [u8; 64],
    used: usize,
    length: u64,
}

impl Default for Sha256 {
    fn default() -> Self {
        Self::new()
    }
}

impl Sha256 {
    pub fn new() -> Self {
        Self {
            state: [
                0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
                0x5be0cd19,
            ],
            block: [0; 64],
            used: 0,
            length: 0,
        }
    }

    /// Inputs must be shorter than 2^64 bits, as required by SHA-256.
    pub fn update(&mut self, mut bytes: &[u8]) {
        self.length = self
            .length
            .checked_add(bytes.len() as u64)
            .filter(|length| *length <= u64::MAX / 8)
            .expect("SHA-256 input is too long");
        if self.used != 0 {
            let count = bytes.len().min(self.block.len() - self.used);
            self.block[self.used..self.used + count].copy_from_slice(&bytes[..count]);
            self.used += count;
            bytes = &bytes[count..];
            if self.used < self.block.len() {
                return;
            }
            compress(&mut self.state, &self.block);
            self.used = 0;
        }
        let (blocks, tail) = bytes.as_chunks::<64>();
        for block in blocks {
            compress(&mut self.state, block);
        }
        self.block[..tail.len()].copy_from_slice(tail);
        self.used = tail.len();
    }

    pub fn finish(mut self) -> [u8; 32] {
        let bits = (self.length * 8).to_be_bytes();
        self.block[self.used] = 0x80;
        self.block[self.used + 1..].fill(0);
        if self.used >= 56 {
            compress(&mut self.state, &self.block);
            self.block.fill(0);
        }
        self.block[56..].copy_from_slice(&bits);
        compress(&mut self.state, &self.block);
        let mut digest = [0; 32];
        for (word, bytes) in self.state.iter().zip(digest.as_chunks_mut::<4>().0) {
            bytes.copy_from_slice(&word.to_be_bytes());
        }
        digest
    }
}

fn compress(state: &mut [u32; 8], block: &[u8; 64]) {
    // FIPS 180-4 section 4.2.2: fractional cube roots of the first 64 primes.
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
        0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
        0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
        0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
        0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
        0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
        0xc67178f2,
    ];
    let mut words = [0u32; 64];
    for (word, bytes) in words.iter_mut().zip(block.as_chunks::<4>().0) {
        *word = u32::from_be_bytes(*bytes);
    }
    for i in 16..64 {
        let x = words[i - 15];
        let y = words[i - 2];
        let a = x.rotate_right(7) ^ x.rotate_right(18) ^ (x >> 3);
        let b = y.rotate_right(17) ^ y.rotate_right(19) ^ (y >> 10);
        words[i] = words[i - 16]
            .wrapping_add(a)
            .wrapping_add(words[i - 7])
            .wrapping_add(b);
    }
    let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut h] = *state;
    for (word, k) in words.into_iter().zip(K) {
        let s = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
        let t = h
            .wrapping_add(s)
            .wrapping_add((e & f) ^ (!e & g))
            .wrapping_add(k)
            .wrapping_add(word);
        let s = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
        let u = s.wrapping_add((a & b) ^ (a & c) ^ (b & c));
        [a, b, c, d, e, f, g, h] = [t.wrapping_add(u), a, b, c, d.wrapping_add(t), e, f, g];
    }
    for (state, word) in state.iter_mut().zip([a, b, c, d, e, f, g, h]) {
        *state = state.wrapping_add(word);
    }
}
