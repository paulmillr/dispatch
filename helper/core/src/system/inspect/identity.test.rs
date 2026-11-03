use super::*;

#[test]
fn os_release_gives_a_short_label_with_the_version() {
    let ubuntu = parse(
        "PRETTY_NAME=\"Ubuntu 24.04.3 LTS\"\nNAME=\"Ubuntu\"\nVERSION_ID=\"24.04\"\nVERSION=\"24.04.3 LTS (Noble Numbat)\"\nID=ubuntu\n",
    );
    assert_eq!(ubuntu.distribution.as_deref(), Some("ubuntu"));
    assert_eq!(ubuntu.name.as_deref(), Some("Ubuntu 24.04.3 LTS"));
    assert_eq!(ubuntu.version.as_deref(), Some("24.04"));
    assert_eq!(ubuntu.label.as_deref(), Some("Ubuntu 24.04"));
    let debian = parse("NAME=\"Debian GNU/Linux\"\nVERSION_ID=\"13\"\nID=debian\n");
    assert_eq!(debian.label.as_deref(), Some("Debian GNU/Linux 13"));
}

#[test]
fn os_release_without_a_version_keeps_the_name_and_rejects_odd_versions() {
    let arch = parse("NAME=\"Arch Linux\"\nPRETTY_NAME=\"Arch Linux\"\nID=arch\nBUILD_ID=rolling\n");
    assert_eq!(arch.version, None);
    assert_eq!(arch.label.as_deref(), Some("Arch Linux"));
    let odd = parse("NAME=Linux\nVERSION_ID=\"1 2\"\n");
    assert_eq!(odd.version, None);
    assert_eq!(odd.label.as_deref(), Some("Linux"));
    assert_eq!(parse(""), Release::default());
}

#[test]
#[cfg(target_os = "macos")]
fn macos_reports_its_product_version() {
    let release = release();
    let version = release.version.expect("kern.osproductversion");
    assert!(version.split('.').next().unwrap().parse::<u32>().unwrap() >= 14, "{version}");
    assert_eq!(release.label, Some(format!("macOS {version}")));
    assert_eq!(release.name, None);
}

#[test]
fn a_uuid_is_written_as_lowercase_hex_groups() {
    let bytes = [
        0xd9, 0x64, 0xe8, 0x27, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0xfe, 0xdc, 0xba, 0x98,
    ];
    assert_eq!(format_uuid(&bytes), "d964e827-0123-4567-89ab-cdeffedcba98");
}

#[cfg(target_os = "macos")]
#[test]
fn the_mac_identity_is_the_platform_uuid_not_the_kernels() {
    let host = platform_uuid().unwrap();
    assert_eq!(host.len(), 36);
    assert!(host.chars().all(|c| c == '-' || c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
    let kernel = crate::system::stats::macos::sysctl(c"kern.uuid", 256).unwrap();
    assert_ne!(host, String::from_utf8_lossy(&kernel).trim_end_matches('\0').to_ascii_lowercase());
}
