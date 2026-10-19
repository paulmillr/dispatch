use super::*;

#[test]
fn the_default_socket_is_herdrs_own_for_the_session() {
    let home = Path::new("/home/u");
    assert_eq!(Config::default_socket("default", home, None), Path::new("/home/u/.config/herdr/herdr.sock"));
    assert_eq!(
        Config::default_socket("work", home, Some(Path::new("/x"))),
        Path::new("/x/herdr/sessions/work/herdr.sock")
    );
    assert_eq!(
        Config::default_socket("default", home, Some(Path::new("relative"))),
        Path::new("/home/u/.config/herdr/herdr.sock"),
        "only an absolute XDG_CONFIG_HOME"
    );
}
