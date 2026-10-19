//! The c1654cc os::identity/hostname facts used by host grouping and reconnect.
use crate::json::Data;
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
    let release = release();
    fn text(value: &Option<String>) -> Data<'_> {
        value.as_deref().map_or(Data::Null, Data::String)
    }
    crate::wire::body::encode_plain(&Data::Object(vec![
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
        ("distribution", text(&release.distribution)),
        ("os_name", text(&release.name)),
        // Additions for clients that show "macOS 26.1" or "Ubuntu 24.04" (the iPhone app);
        // older clients ignore unknown identity fields.
        ("os_version", text(&release.version)),
        ("os_label", text(&release.label)),
    ]))
    .map_err(|_| super::invalid())
}

/// Optional presentation facts of the operating system; never an identity.
#[derive(Debug, Default, PartialEq, Eq)]
pub(super) struct Release {
    /// os-release ID (Linux), e.g. "ubuntu".
    pub distribution: Option<String>,
    /// os-release PRETTY_NAME, else NAME (Linux); None on macOS, where the app says "macOS".
    pub name: Option<String>,
    /// os-release VERSION_ID, or the macOS product version (kern.osproductversion), e.g. "26.1".
    pub version: Option<String>,
    /// Short display name with version: "macOS 26.1", "Ubuntu 24.04" (NAME and VERSION_ID),
    /// else the name alone.
    pub label: Option<String>,
}

/// macOS: the product version from sysctl. Linux: os-release, never sourced as shell code,
/// administrator file first, vendor file only when it is absent; c1654cc
/// Helpers/ssh-helper/src/host_metadata.rs:17-130 (value unchanged).
fn release() -> Release {
    #[cfg(target_os = "macos")]
    {
        let version = crate::system::stats::macos::sysctl(c"kern.osproductversion", 64)
            .ok()
            .map(|bytes| String::from_utf8_lossy(&bytes).trim_end_matches('\0').trim().to_owned())
            .filter(|version| valid_version(version));
        return Release {
            label: Some(version.as_ref().map_or("macOS".into(), |version| format!("macOS {version}"))),
            version,
            ..Release::default()
        };
    }
    #[allow(unreachable_code)]
    if !cfg!(target_os = "linux") {
        return Release::default();
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

pub(super) fn parse(text: &str) -> Release {
    if text.len() > FILE_LIMIT {
        return Release::default();
    }
    let (mut distribution, mut pretty, mut name, mut version) = (None, None, None, None);
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
            "VERSION_ID" => version = value(raw).filter(|value| valid_version(value)),
            _ => {}
        }
    }
    let label = match (&name, &version) {
        (Some(name), Some(version)) => Some(format!("{name} {version}")),
        _ => pretty.clone().or_else(|| name.clone()),
    };
    Release { distribution, name: pretty.or(name), version, label }
}

/// A short dotted version ("24.04", "26.0.1", "13", "rolling"): no spaces or punctuation that
/// could pass for other text.
fn valid_version(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"._-~+".contains(&byte))
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

#[cfg(test)]
#[path = "identity.test.rs"]
mod tests;
