//! The c1654cc os::identity/hostname facts used by host grouping and reconnect.
use crate::json::{self, Data};
use std::io;

pub(super) fn collect() -> io::Result<Vec<u8>> {
    #[cfg(target_os = "linux")]
    let (host, boot) = {
        use std::{io::Read, path::Path};
        let read = |path: &str| -> io::Result<String> {
            let mut bytes = Vec::new();
            crate::system::file::open(Path::new(path))?
                .take(257)
                .read_to_end(&mut bytes)?;
            if bytes.len() > 256 {
                return Err(super::invalid());
            }
            Ok(String::from_utf8_lossy(&bytes).trim().into())
        };
        (
            read("/etc/machine-id")?,
            read("/proc/sys/kernel/random/boot_id")?,
        )
    };
    #[cfg(target_os = "macos")]
    let (host, boot) = {
        let read = |name: &std::ffi::CStr| -> io::Result<String> {
            let bytes = crate::system::stats::macos::sysctl(name, 256)?;
            Ok(String::from_utf8_lossy(&bytes)
                .trim_end_matches('\0')
                .into())
        };
        (
            read(c"kern.uuid")?.to_ascii_lowercase(),
            read(c"kern.bootsessionuuid")?,
        )
    };
    unsafe extern "C" {
        fn gethostname(bytes: *mut u8, length: usize) -> i32;
    }
    let mut bytes = [0; 256];
    // SAFETY: the native hostname API receives exactly the writable buffer length.
    if unsafe { gethostname(bytes.as_mut_ptr(), bytes.len()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    let end = bytes
        .iter()
        .position(|byte| *byte == 0)
        .unwrap_or(bytes.len());
    let name = String::from_utf8_lossy(&bytes[..end]);
    if host.is_empty() || boot.is_empty() {
        return Err(super::invalid());
    }
    let (distribution, os_name) = release();
    fn text(value: &Option<String>) -> Data<'_> {
        value.as_deref().map_or(Data::Null, Data::String)
    }
    json::write(&Data::Object(vec![
        ("host", Data::String(&host)),
        ("boot", Data::String(&boot)),
        ("hostname", Data::String(&name)),
        (
            "os",
            Data::String(if cfg!(target_os = "macos") {
                "Darwin"
            } else {
                "Linux"
            }),
        ),
        ("distribution", text(&distribution)),
        ("os_name", text(&os_name)),
    ]))
    .map_err(|_| super::invalid())
}

/// Optional presentation facts from os-release: never sourced as shell code, never an identity,
/// administrator file first, vendor file only when it is absent; c1654cc
/// Helpers/ssh-helper/src/host_metadata.rs:17-130 (parse/value unchanged).
fn release() -> (Option<String>, Option<String>) {
    if !cfg!(target_os = "linux") {
        return (None, None);
    }
    let read = |path: &str| -> io::Result<String> {
        use std::io::Read;
        let file = crate::system::file::open(std::path::Path::new(path))?;
        let metadata = file.metadata()?;
        if !metadata.is_file() || metadata.len() > FILE_LIMIT as u64 {
            return Err(super::invalid());
        }
        let mut bytes = Vec::new();
        file.take(FILE_LIMIT as u64 + 1).read_to_end(&mut bytes)?;
        if bytes.len() > FILE_LIMIT {
            return Err(super::invalid());
        }
        String::from_utf8(bytes).map_err(|_| super::invalid())
    };
    let text = match read("/etc/os-release") {
        Err(error) if error.kind() == io::ErrorKind::NotFound => read("/usr/lib/os-release"),
        result => result,
    };
    text.map(|text| parse(&text)).unwrap_or_default()
}

const FILE_LIMIT: usize = 65_536;
const VALUE_LIMIT: usize = 1024;

pub(super) fn parse(text: &str) -> (Option<String>, Option<String>) {
    if text.len() > FILE_LIMIT {
        return (None, None);
    }
    let (mut distribution, mut pretty, mut name) = (None, None, None);
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((key, raw)) = line.split_once('=') else {
            continue;
        };
        // Repeated keys use the last entry, as os-release specifies. Invalid
        // or unavailable values stay unknown instead of guessing a distro.
        match key {
            "ID" => {
                distribution = value(raw).filter(|value| {
                    value.len() <= 256
                        && value.bytes().all(|byte| {
                            byte.is_ascii_lowercase()
                                || byte.is_ascii_digit()
                                || b"._-".contains(&byte)
                        })
                });
            }
            "PRETTY_NAME" => pretty = value(raw),
            "NAME" => name = value(raw),
            _ => {}
        }
    }
    (distribution, pretty.or(name))
}

fn value(raw: &str) -> Option<String> {
    let raw = raw.trim();
    if raw.len() > VALUE_LIMIT * 2 || raw.chars().any(char::is_control) {
        return None;
    }
    let quote = raw
        .chars()
        .next()
        .filter(|value| matches!(value, '\'' | '"'));
    let body = if let Some(quote) = quote {
        raw.strip_prefix(quote)?.strip_suffix(quote)?
    } else {
        raw
    };
    let mut result = String::new();
    let mut characters = body.chars();
    while let Some(character) = characters.next() {
        if character == '\\' && quote != Some('\'') {
            let escaped = characters.next()?;
            if quote == Some('"') && !matches!(escaped, '$' | '`' | '"' | '\\') {
                result.push('\\');
            }
            result.push(escaped);
        } else {
            if Some(character) == quote
                || quote.is_none()
                    && (character.is_whitespace() || matches!(character, '$' | '`' | '\'' | '"'))
            {
                return None;
            }
            result.push(character);
        }
    }
    (!result.is_empty() && result.len() <= VALUE_LIMIT).then_some(result)
}
