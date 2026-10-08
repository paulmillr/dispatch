use crate::native::error;
use dispatch_helper4_core::api::Error;

const BASE64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
pub fn encode(bytes: &[u8]) -> String {
    let mut output = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let word =
            chunk.iter().fold(0u32, |v, b| (v << 8) | u32::from(*b)) << ((3 - chunk.len()) * 8);
        for i in 0..4 {
            output.push(if i > chunk.len() {
                '='
            } else {
                BASE64[((word >> (18 - i * 6)) & 63) as usize] as char
            });
        }
    }
    output
}
pub fn decode(text: &str) -> Result<Vec<u8>, Error> {
    let bytes = text.as_bytes();
    if !bytes.len().is_multiple_of(4) {
        return Err(error("Invalid herdr terminal frame."));
    }
    let mut output = Vec::with_capacity(bytes.len() / 4 * 3);
    for (index, chunk) in bytes.chunks(4).enumerate() {
        let mut word = 0u32;
        let mut padding = 0;
        for (i, b) in chunk.iter().enumerate() {
            let value = if *b == b'=' && i >= 2 && index + 1 == bytes.len() / 4 {
                padding += 1;
                0
            } else {
                if padding != 0 {
                    return Err(error("Invalid herdr terminal frame."));
                }
                BASE64
                    .iter()
                    .position(|v| v == b)
                    .ok_or_else(|| error("Invalid herdr terminal frame."))? as u32
            };
            word = (word << 6) | value;
        }
        for i in 0..3 - padding {
            output.push((word >> (16 - i * 8)) as u8);
        }
    }
    Ok(output)
}
