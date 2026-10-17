use super::*;

#[test]
fn a_codex_home_that_is_not_utf8_is_refused_not_replaced_by_home() {
    let named = |variables: Vec<(&'static str, &'static [u8])>| {
        home(&Data::Object(variables.into_iter().map(|(name, value)| (name, Data::Bytes(value))).collect()))
    };
    let unavailable = Err(failure("endpoint", "Codex home unavailable"));
    assert_eq!(vec![
        named(vec![("CODEX_HOME", b"/srv/c1"), ("HOME", b"/home/u1")]),
        named(vec![("HOME", b"/home/u1")]),
        named(vec![]),
        named(vec![("CODEX_HOME", b"/srv/c\xff"), ("HOME", b"/home/u1")]),
        named(vec![("HOME", b"/home/u\xff")]),
        // HOME counts only without CODEX_HOME.
        named(vec![("CODEX_HOME", b"/srv/c1"), ("HOME", b"/home/u\xff")]),
    ], vec![
        Ok("/srv/c1".into()),
        Ok("/home/u1/.codex".into()),
        unavailable.clone(),
        unavailable.clone(),
        unavailable,
        Ok("/srv/c1".into()),
    ]);
}
