//! The capture files' compression: Zstandard (Vendor/Zstd, compiled by build.rs into every helper with the capture
//! tool). A live capture is level 1 (zstd's fast strategy: recording never waits on it); the replay corpus is level 9
//! with long-distance matching over a 128 MiB window, so a payload recorded again and again (a helper binary uploaded
//! many times) is stored once. Each frame ends with a checksum of its content, which refuses a damaged file. A
//! checkpoint ends a frame and later records continue in the next; the decoder reads frames one after another.
use std::ffi::{CStr, c_char, c_int, c_uint, c_void};
use std::io::{self, Read, Write};

// Vendor/Zstd builds only these two levels' search strategies (fast and lazy2, PROVENANCE.md): another level would
// quietly cascade to one of them instead of failing.
const LIVE: c_int = 1;
const CORPUS: c_int = 9;
const WINDOW_LOG: c_int = 27;
// zstd.h's parameter and directive values.
const COMPRESSION_LEVEL: c_int = 100;
const WINDOW: c_int = 101;
const LONG_DISTANCE: c_int = 160;
const CHECKSUM: c_int = 201;
const WINDOW_MAX: c_int = 100;
const CONTINUE: c_int = 0;
const FLUSH: c_int = 1;
const END: c_int = 2;

#[repr(C)]
struct InBuffer {
    src: *const c_void,
    size: usize,
    pos: usize,
}
#[repr(C)]
struct OutBuffer {
    dst: *mut c_void,
    size: usize,
    pos: usize,
}

unsafe extern "C" {
    fn ZSTD_createCStream() -> *mut c_void;
    fn ZSTD_freeCStream(stream: *mut c_void) -> usize;
    fn ZSTD_CCtx_setParameter(stream: *mut c_void, parameter: c_int, value: c_int) -> usize;
    fn ZSTD_compressStream2(stream: *mut c_void, output: *mut OutBuffer, input: *mut InBuffer, directive: c_int) -> usize;
    fn ZSTD_createDStream() -> *mut c_void;
    fn ZSTD_freeDStream(stream: *mut c_void) -> usize;
    fn ZSTD_DCtx_setParameter(stream: *mut c_void, parameter: c_int, value: c_int) -> usize;
    fn ZSTD_decompressStream(stream: *mut c_void, output: *mut OutBuffer, input: *mut InBuffer) -> usize;
    fn ZSTD_isError(code: usize) -> c_uint;
    fn ZSTD_getErrorName(code: usize) -> *const c_char;
}

/// A zstd result: its count, or its error as InvalidData (a damaged, cut or foreign file).
fn check(code: usize) -> io::Result<usize> {
    // SAFETY: both only read their integer argument; the name is a static string zstd owns.
    if unsafe { ZSTD_isError(code) } == 0 {
        return Ok(code);
    }
    let name = unsafe { CStr::from_ptr(ZSTD_getErrorName(code)) };
    Err(io::Error::new(io::ErrorKind::InvalidData, format!("zstd: {}", name.to_string_lossy())))
}

pub struct Encoder<W: Write> {
    output: Option<W>,
    stream: *mut c_void,
    buffer: Vec<u8>,
    /// Bytes given since the last frame ended: a checkpoint with none writes no empty frame.
    pending: bool,
}
impl<W: Write> Encoder<W> {
    /// A live capture: fast, in level 1's own small window (a helper process holds one while it runs).
    pub fn live(output: W) -> io::Result<Self> {
        Self::new(output, &[(COMPRESSION_LEVEL, LIVE), (CHECKSUM, 1)])
    }
    /// A corpus file: level 9 over the long window.
    pub fn corpus(output: W) -> io::Result<Self> {
        Self::new(output, &[(COMPRESSION_LEVEL, CORPUS), (WINDOW, WINDOW_LOG), (LONG_DISTANCE, 1), (CHECKSUM, 1)])
    }
    fn new(output: W, parameters: &[(c_int, c_int)]) -> io::Result<Self> {
        // SAFETY: allocates a context, freed once in Drop.
        let stream = unsafe { ZSTD_createCStream() };
        if stream.is_null() {
            return Err(io::Error::other("zstd encoder"));
        }
        let encoder = Self { output: Some(output), stream, buffer: vec![0; 1 << 17], pending: false };
        for &(parameter, value) in parameters {
            // SAFETY: the context is live.
            check(unsafe { ZSTD_CCtx_setParameter(encoder.stream, parameter, value) })?;
        }
        Ok(encoder)
    }
    /// `input` through the encoder with `directive`, every byte it makes written on: until the input is consumed
    /// (continue), or until nothing is left to flush (flush, end).
    fn run(&mut self, input: &[u8], directive: c_int) -> io::Result<()> {
        let mut source = InBuffer { src: input.as_ptr().cast(), size: input.len(), pos: 0 };
        for _ in 0.. {
            let mut target = OutBuffer { dst: self.buffer.as_mut_ptr().cast(), size: self.buffer.len(), pos: 0 };
            // SAFETY: the context is live; each buffer points at memory valid for its size for the call.
            let left = check(unsafe { ZSTD_compressStream2(self.stream, &mut target, &mut source, directive) })?;
            self.output.as_mut().unwrap().write_all(&self.buffer[..target.pos])?;
            if if directive == CONTINUE { source.pos == source.size } else { left == 0 } {
                break;
            }
        }
        Ok(())
    }
    /// Everything given so far becomes whole frames: a reader can stop here.
    pub fn checkpoint(&mut self) -> io::Result<()> {
        if self.pending {
            self.run(&[], END)?;
            self.pending = false;
        }
        self.output.as_mut().unwrap().flush()
    }
    pub fn finish(mut self) -> io::Result<W> {
        self.checkpoint()?;
        Ok(self.output.take().unwrap())
    }
}
impl<W: Write> Write for Encoder<W> {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.run(bytes, CONTINUE)?;
        self.pending |= !bytes.is_empty();
        Ok(bytes.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        self.run(&[], FLUSH)?;
        self.output.as_mut().unwrap().flush()
    }
}
impl<W: Write> Drop for Encoder<W> {
    fn drop(&mut self) {
        // SAFETY: created in new, freed once here.
        unsafe { ZSTD_freeCStream(self.stream) };
    }
}

pub struct Decoder<R: Read> {
    input: R,
    stream: *mut c_void,
    buffer: Vec<u8>,
    start: usize,
    end: usize,
    /// The input ended; `ended`: every frame begun is whole and flushed.
    exhausted: bool,
    ended: bool,
    limit: usize,
    produced: usize,
}
impl<R: Read> Decoder<R> {
    /// `limit` bounds the expanded bytes.
    pub fn new(input: R, limit: usize) -> io::Result<Self> {
        // SAFETY: allocates a context, freed once in Drop.
        let stream = unsafe { ZSTD_createDStream() };
        if stream.is_null() {
            return Err(io::Error::other("zstd decoder"));
        }
        let decoder = Self { input, stream, buffer: vec![0; 1 << 17], start: 0, end: 0, exhausted: false, ended: true, limit, produced: 0 };
        // SAFETY: the context is live. The corpus encoder's window: a larger one is refused rather than allocated.
        check(unsafe { ZSTD_DCtx_setParameter(decoder.stream, WINDOW_MAX, WINDOW_LOG) })?;
        Ok(decoder)
    }
}
impl<R: Read> Read for Decoder<R> {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        if out.is_empty() {
            return Ok(0);
        }
        for _ in 0.. {
            if self.start == self.end && !self.exhausted {
                match self.input.read(&mut self.buffer)? {
                    0 => self.exhausted = true,
                    count => (self.start, self.end) = (0, count),
                }
            }
            // A finished frame and no more input: the end. Asking zstd again would start an empty next frame.
            if self.start == self.end && self.exhausted && self.ended {
                return Ok(0);
            }
            let mut source = InBuffer { src: self.buffer[self.start..].as_ptr().cast(), size: self.end - self.start, pos: 0 };
            let mut target = OutBuffer { dst: out.as_mut_ptr().cast(), size: out.len(), pos: 0 };
            // SAFETY: the context is live; each buffer points at memory valid for its size for the call.
            let hint = check(unsafe { ZSTD_decompressStream(self.stream, &mut target, &mut source) })?;
            self.start += source.pos;
            self.ended = hint == 0;
            if target.pos > 0 {
                self.produced += target.pos;
                if self.produced > self.limit {
                    return Err(io::Error::new(io::ErrorKind::InvalidData, "zstd capture exceeds its expansion limit"));
                }
                return Ok(target.pos);
            }
            if self.start == self.end && self.exhausted && !self.ended {
                return Err(io::Error::new(io::ErrorKind::InvalidData, "zstd capture is cut"));
            }
        }
        unreachable!()
    }
}
impl<R: Read> Drop for Decoder<R> {
    fn drop(&mut self) {
        // SAFETY: created in new, freed once here.
        unsafe { ZSTD_freeDStream(self.stream) };
    }
}
