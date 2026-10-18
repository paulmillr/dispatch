use super::modern;

#[test]
fn servers_from_0_9_2_on_are_modern() {
    for version in ["0.9.2", "0.9.3", "0.9.5", "0.10.0", "1.0", "0.9.5-rc1"] {
        assert!(modern(version), "{version}");
    }
    for version in ["0.9.1", "0.8.9", "0.9", "", "dev"] {
        assert!(!modern(version), "{version}");
    }
}
