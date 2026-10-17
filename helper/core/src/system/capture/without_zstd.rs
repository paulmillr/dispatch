//! capture/zstd.rs in a helper without the capture feature (Release), which links no zstd: it never opens a capture
//! (capture::control ignores DISPATCH_CAPTURE and DISPATCH_REPLAY), and one opened anyway fails.
use std::convert::Infallible;
use std::io::{self, Read, Write};
use std::marker::PhantomData;

fn unsupported<T>() -> io::Result<T> {
    Err(io::Error::new(io::ErrorKind::Unsupported, "captures need a helper built with the capture feature"))
}

pub struct Encoder<W: Write>(Infallible, PhantomData<W>);
impl<W: Write> Encoder<W> {
    pub fn live(_: W) -> io::Result<Self> {
        unsupported()
    }
    pub fn corpus(_: W) -> io::Result<Self> {
        unsupported()
    }
    pub fn checkpoint(&mut self) -> io::Result<()> {
        match self.0 {}
    }
    pub fn finish(self) -> io::Result<W> {
        match self.0 {}
    }
}
impl<W: Write> Write for Encoder<W> {
    fn write(&mut self, _: &[u8]) -> io::Result<usize> {
        match self.0 {}
    }
    fn flush(&mut self) -> io::Result<()> {
        match self.0 {}
    }
}

pub struct Decoder<R: Read>(Infallible, PhantomData<R>);
impl<R: Read> Decoder<R> {
    pub fn new(_: R, _: usize) -> io::Result<Self> {
        unsupported()
    }
}
impl<R: Read> Read for Decoder<R> {
    fn read(&mut self, _: &mut [u8]) -> io::Result<usize> {
        match self.0 {}
    }
}
