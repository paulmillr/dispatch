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
