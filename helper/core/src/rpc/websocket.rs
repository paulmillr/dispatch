//! Incremental RFC 6455 client framing. The owner supplies entropy and performs IO.
pub use super::Error as FieldError;

const HEADER: usize = 16_384;

#[derive(Debug, PartialEq, Eq)]
pub enum Event<'a> {
    Ready,
    Message { binary: bool, bytes: &'a [u8] },
    Ping(&'a [u8]),
    Pong(&'a [u8]),
    Close(&'a [u8]),
}

struct Frame {
    opcode: u8,
    final_frame: bool,
    remaining: usize,
}

/// Control events belong to the native owner; Stream publishes only message bytes.
#[derive(Debug, PartialEq, Eq)]
pub enum Notice {
    Ready,
    Ping(Vec<u8>),
    Pong(Vec<u8>),
    Close(Vec<u8>),
}

struct State {
    socket: WebSocket,
    notices: Vec<Notice>,
    bytes: usize,
    limit: usize,
}

/// The owner retains a clone to drain control events after Stream::event returns.
#[derive(Clone)]
pub struct Client(std::rc::Rc<std::cell::RefCell<State>>);
impl Client {
    pub fn new(nonce: [u8; 16], limit: usize) -> Self {
        Self(std::rc::Rc::new(std::cell::RefCell::new(State {
            socket: WebSocket::new(nonce, limit),
            notices: Vec::new(),
            bytes: 0,
            limit,
        })))
    }
    pub fn handshake(&self, host: &str, target: &str) -> Result<Vec<u8>, FieldError> {
        self.0.borrow().socket.handshake(host, target)
    }
    pub fn take(&self) -> Vec<Notice> {
        let mut state = self.0.borrow_mut();
        state.bytes = 0;
        std::mem::take(&mut state.notices)
    }
}
impl super::transport::Codec for Client {
    fn feed(
        &mut self,
        bytes: &[u8],
        emit: &mut dyn FnMut(&[u8]) -> Result<(), FieldError>,
    ) -> Result<(), FieldError> {
        let mut state = self.0.borrow_mut();
        let State {
            socket,
            notices,
            bytes: retained,
            limit,
        } = &mut *state;
        socket.feed(bytes, |event| {
            let notice = match event {
                Event::Message { bytes, .. } => return emit(bytes),
                Event::Ready => Notice::Ready,
                Event::Ping(bytes) => Notice::Ping(bytes.to_vec()),
                Event::Pong(bytes) => Notice::Pong(bytes.to_vec()),
                Event::Close(bytes) => Notice::Close(bytes.to_vec()),
            };
            let payload = match &notice {
                Notice::Ready => 0,
                Notice::Ping(bytes) | Notice::Pong(bytes) | Notice::Close(bytes) => bytes.len(),
            };
            let cost = std::mem::size_of::<Notice>() + payload;
            if cost > limit.saturating_sub(*retained) {
                return Err(FieldError::Limit);
            }
            *retained += cost;
            notices.push(notice);
            Ok(())
        })
    }
    fn finish(&self) -> Result<(), FieldError> {
        self.0.borrow().socket.finish()
    }
}

pub struct WebSocket {
    key: String,
    accept: String,
    limit: usize,
    upgrade: Vec<u8>,
    ready: bool,
    header: [u8; 10],
    used: usize,
    frame: Option<Frame>,
    fragment: Option<u8>,
    message: Vec<u8>,
    control: Vec<u8>,
    closed: bool,
    error: Option<FieldError>,
}

impl WebSocket {
    pub fn new(nonce: [u8; 16], limit: usize) -> Self {
        let key = base64(&nonce);
        // RFC 6455 uses SHA-1 only for this public nonce, never for authentication.
        let accept = base64(&sha1(
            format!("{key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11").as_bytes(),
        ));
        Self {
            key,
            accept,
            limit,
            upgrade: vec![],
            ready: false,
            header: [0; 10],
            used: 0,
            frame: None,
            fragment: None,
            message: vec![],
            control: vec![],
            closed: false,
            error: None,
        }
    }

    pub fn handshake(&self, host: &str, target: &str) -> Result<Vec<u8>, FieldError> {
        if host.is_empty()
            || !target.starts_with('/')
            || !host
                .bytes()
                .chain(target.bytes())
                .all(|b| (33..=126).contains(&b))
        {
            return Err(FieldError::Shape);
        }
        if host.len().saturating_add(target.len()) > HEADER {
            return Err(FieldError::Limit);
        }
        let bytes = format!("GET {target} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {}\r\nSec-WebSocket-Version: 13\r\n\r\n", self.key).into_bytes();
        if bytes.len() > HEADER {
            return Err(FieldError::Limit);
        }
        Ok(bytes)
    }

    pub fn feed(
        &mut self,
        mut bytes: &[u8],
        mut emit: impl FnMut(Event<'_>) -> Result<(), FieldError>,
    ) -> Result<(), FieldError> {
        if let Some(error) = self.error {
            return Err(error);
        }
        let result = (|| {
            loop {
                if bytes.is_empty() || self.closed {
                    break;
                }
                if !self.ready {
                    if self.upgrade.len() == HEADER {
                        return Err(FieldError::Limit);
                    }
                    self.upgrade.push(bytes[0]);
                    bytes = &bytes[1..];
                    if self.upgrade.ends_with(b"\r\n\r\n") {
                        upgrade(&self.upgrade[..self.upgrade.len() - 4], &self.accept)?;
                        self.upgrade = vec![];
                        self.ready = true;
                        emit(Event::Ready)?;
                    }
                    continue;
                }
                if self.frame.is_none() {
                    let length = if self.used < 2 {
                        2
                    } else {
                        match self.header[1] & 127 {
                            126 => 4,
                            127 => 10,
                            _ => 2,
                        }
                    };
                    let count = (length - self.used).min(bytes.len());
                    self.header[self.used..self.used + count].copy_from_slice(&bytes[..count]);
                    self.used += count;
                    bytes = &bytes[count..];
                    if self.used < 2
                        || self.used
                            < match self.header[1] & 127 {
                                126 => 4,
                                127 => 10,
                                _ => 2,
                            }
                    {
                        continue;
                    }
                    let opcode = self.header[0] & 15;
                    let final_frame = self.header[0] & 128 != 0;
                    let length = match self.header[1] & 127 {
                        126 => {
                            let value = u16::from_be_bytes(self.header[2..4].try_into().unwrap());
                            if value < 126 {
                                return Err(FieldError::Shape);
                            }
                            u64::from(value)
                        }
                        127 => {
                            let value = u64::from_be_bytes(self.header[2..10].try_into().unwrap());
                            if value <= u16::MAX as u64 || value >> 63 != 0 {
                                return Err(FieldError::Shape);
                            }
                            value
                        }
                        value => u64::from(value),
                    };
                    if self.header[0] & 0x70 != 0
                        || self.header[1] & 128 != 0
                        || ![0, 1, 2, 8, 9, 10].contains(&opcode)
                        || (opcode >= 8 && (!final_frame || length > 125))
                        || (opcode == 0 && self.fragment.is_none())
                        || ([1, 2].contains(&opcode) && self.fragment.is_some())
                    {
                        return Err(FieldError::Shape);
                    }
                    if opcode < 8 && length > self.limit.saturating_sub(self.message.len()) as u64 {
                        return Err(FieldError::Limit);
                    }
                    if opcode == 1 || opcode == 2 {
                        self.fragment = Some(opcode);
                    }
                    self.frame = Some(Frame {
                        opcode,
                        final_frame,
                        remaining: length as usize,
                    });
                    self.used = 0;
                }
                let frame = self.frame.as_mut().unwrap();
                let count = frame.remaining.min(bytes.len());
                let (output, limit) = if frame.opcode >= 8 {
                    (&mut self.control, 125)
                } else {
                    (&mut self.message, self.limit)
                };
                let required = output.len() + frame.remaining;
                if required > output.capacity() {
                    let capacity = required.max(output.capacity().saturating_mul(2)).min(limit);
                    output
                        .try_reserve_exact(capacity - output.len())
                        .map_err(|_| FieldError::Limit)?;
                }
                output.extend_from_slice(&bytes[..count]);
                bytes = &bytes[count..];
                frame.remaining -= count;
                if frame.remaining != 0 {
                    continue;
                }
                let frame = self.frame.take().unwrap();
                match frame.opcode {
                    8..=10 => {
                        payload(frame.opcode, &self.control)?;
                        match frame.opcode {
                            8 => {
                                self.closed = true;
                                self.message.clear();
                                emit(Event::Close(&self.control))?;
                            }
                            9 => emit(Event::Ping(&self.control))?,
                            _ => emit(Event::Pong(&self.control))?,
                        }
                        self.control.clear();
                    }
                    _ if frame.final_frame => {
                        let opcode = self.fragment.take().unwrap();
                        payload(opcode, &self.message)?;
                        emit(Event::Message {
                            binary: opcode == 2,
                            bytes: &self.message,
                        })?;
                        self.message.clear();
                    }
                    _ => {}
                }
            }
            Ok(())
        })();
        if let Err(error) = result {
            self.error = Some(error);
        }
        result
    }

    pub fn finish(&self) -> Result<(), FieldError> {
        if let Some(error) = self.error {
            Err(error)
        } else if self.closed {
            Ok(())
        } else {
            Err(FieldError::Incomplete)
        }
    }
}

fn payload(opcode: u8, bytes: &[u8]) -> Result<(), FieldError> {
    if ![1, 2, 8, 9, 10].contains(&opcode) || (opcode >= 8 && bytes.len() > 125) {
        return Err(FieldError::Shape);
    }
    if opcode == 1 && std::str::from_utf8(bytes).is_err() {
        return Err(FieldError::Shape);
    }
    if opcode == 8 {
        if bytes.len() == 1 {
            return Err(FieldError::Shape);
        }
        if bytes.len() >= 2 {
            let code = u16::from_be_bytes(bytes[..2].try_into().unwrap());
            if (!(3000..=4999).contains(&code)
                && (!(1000..=1014).contains(&code) || [1004, 1005, 1006].contains(&code)))
                || std::str::from_utf8(&bytes[2..]).is_err()
            {
                return Err(FieldError::Shape);
            }
        }
    }
    Ok(())
}

pub fn frame(opcode: u8, bytes: &[u8], mask: [u8; 4], limit: usize) -> Result<Vec<u8>, FieldError> {
    payload(opcode, bytes)?;
    if opcode < 8 && bytes.len() > limit {
        return Err(FieldError::Limit);
    }
    let mut output = Vec::new();
    output
        .try_reserve_exact(bytes.len().checked_add(14).ok_or(FieldError::Limit)?)
        .map_err(|_| FieldError::Limit)?;
    output.push(128 | opcode);
    match bytes.len() {
        0..=125 => output.push(128 | bytes.len() as u8),
        126..=65535 => {
            output.push(254);
            output.extend_from_slice(&(bytes.len() as u16).to_be_bytes());
        }
        _ => {
            output.push(255);
            output.extend_from_slice(&(bytes.len() as u64).to_be_bytes());
        }
    }
    output.extend_from_slice(&mask);
    output.extend(bytes.iter().enumerate().map(|(i, byte)| byte ^ mask[i % 4]));
    Ok(output)
}

fn upgrade(bytes: &[u8], accept: &str) -> Result<(), FieldError> {
    let text = std::str::from_utf8(bytes).map_err(|_| FieldError::Shape)?;
    let mut lines = text.split("\r\n");
    let status = lines.next().ok_or(FieldError::Shape)?;
    if !status.starts_with("HTTP/1.1 101 ") || status.bytes().any(|b| b.is_ascii_control()) {
        return Err(FieldError::Shape);
    }
    let (mut upgraded, mut connection, mut accepted) = (false, false, false);
    for line in lines {
        let (name, value) = line.split_once(':').ok_or(FieldError::Shape)?;
        if name.is_empty()
            || !name
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&b))
            || value.bytes().any(|b| b.is_ascii_control() && b != b'\t')
        {
            return Err(FieldError::Shape);
        }
        let value = value.trim_matches([' ', '\t']);
        if name.eq_ignore_ascii_case("sec-websocket-accept") {
            if accepted || value != accept {
                return Err(FieldError::Shape);
            }
            accepted = true;
        } else if name.eq_ignore_ascii_case("upgrade") {
            upgraded |= value
                .split(',')
                .any(|v| v.trim().eq_ignore_ascii_case("websocket"));
        } else if name.eq_ignore_ascii_case("connection") {
            connection |= value
                .split(',')
                .any(|v| v.trim().eq_ignore_ascii_case("upgrade"));
        } else if name.eq_ignore_ascii_case("sec-websocket-extensions")
            || name.eq_ignore_ascii_case("sec-websocket-protocol")
        {
            return Err(FieldError::Shape);
        }
    }
    if upgraded && connection && accepted {
        Ok(())
    } else {
        Err(FieldError::Shape)
    }
}

fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut output = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for part in bytes.chunks(3) {
        let value = (u32::from(part[0]) << 16)
            | (u32::from(*part.get(1).unwrap_or(&0)) << 8)
            | u32::from(*part.get(2).unwrap_or(&0));
        output.push(ALPHABET[((value >> 18) & 63) as usize] as char);
        output.push(ALPHABET[((value >> 12) & 63) as usize] as char);
        output.push(if part.len() > 1 {
            ALPHABET[((value >> 6) & 63) as usize] as char
        } else {
            '='
        });
        output.push(if part.len() > 2 {
            ALPHABET[(value & 63) as usize] as char
        } else {
            '='
        });
    }
    output
}

fn sha1(bytes: &[u8]) -> [u8; 20] {
    let mut padded = vec![0; (bytes.len() + 9).div_ceil(64) * 64];
    padded[..bytes.len()].copy_from_slice(bytes);
    padded[bytes.len()] = 128;
    let end = padded.len();
    padded[end - 8..].copy_from_slice(&((bytes.len() as u64) * 8).to_be_bytes());
    let mut state = [
        0x67452301u32,
        0xefcdab89,
        0x98badcfe,
        0x10325476,
        0xc3d2e1f0,
    ];
    for block in padded.as_chunks::<64>().0 {
        let mut words = [0u32; 80];
        for (slot, bytes) in words.iter_mut().zip(block.as_chunks::<4>().0) {
            *slot = u32::from_be_bytes(*bytes);
        }
        for i in 16..80 {
            words[i] = (words[i - 3] ^ words[i - 8] ^ words[i - 14] ^ words[i - 16]).rotate_left(1);
        }
        let [mut a, mut b, mut c, mut d, mut e] = state;
        for (i, word) in words.into_iter().enumerate() {
            let (f, k) = match i {
                0..=19 => ((b & c) | (!b & d), 0x5a827999),
                20..=39 => (b ^ c ^ d, 0x6ed9eba1),
                40..=59 => ((b & c) | (b & d) | (c & d), 0x8f1bbcdc),
                _ => (b ^ c ^ d, 0xca62c1d6),
            };
            let next = a
                .rotate_left(5)
                .wrapping_add(f)
                .wrapping_add(e)
                .wrapping_add(k)
                .wrapping_add(word);
            [a, b, c, d, e] = [next, a, b.rotate_left(30), c, d];
        }
        for (slot, value) in state.iter_mut().zip([a, b, c, d, e]) {
            *slot = slot.wrapping_add(value);
        }
    }
    let mut digest = [0; 20];
    for (slot, value) in digest.as_chunks_mut::<4>().0.iter_mut().zip(state) {
        slot.copy_from_slice(&value.to_be_bytes());
    }
    digest
}
