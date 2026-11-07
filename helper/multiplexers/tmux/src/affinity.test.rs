//! A space's name (`display`): Dispatch's own name, a chosen session name, the folder, the stored name.
use super::*;

fn value(directory: Option<bool>) -> Affinity {
    Affinity { group: "0F0F0F0F-0000-4000-8000-000000000001".into(), name: "stored".into(), order: 0, directory, creation: None }
}

#[test]
fn a_chosen_session_name_names_its_own_space_before_the_folder() {
    let folder = Some(Path::new("/work/proj dir"));
    assert_eq!(display(&value(Some(true)), folder, Some("api")), "api");
    assert_eq!(display(&value(Some(true)), None, Some("api")), "api");
    // tmux's default names are numbers: the folder, as for a plain space.
    assert_eq!(display(&value(Some(true)), folder, Some("12")), "proj dir");
    // Another space of the session follows its folder.
    assert_eq!(display(&value(Some(true)), folder, None), "proj dir");
    assert_eq!(display(&value(Some(true)), Some(Path::new("/")), None), "/");
    // No folder known (or a relative one): the stored name.
    assert_eq!(display(&value(Some(true)), Some(Path::new("relative")), Some("0")), "stored");
}

#[test]
fn a_name_given_in_dispatch_stays_whatever_the_session_is_called() {
    for directory in [Some(false), None] {
        assert_eq!(display(&value(directory), Some(Path::new("/work/proj")), Some("api")), "stored");
    }
}

#[test]
fn only_a_number_counts_as_tmuxs_own_name() {
    for name in ["0", "17", ""] {
        assert!(!chosen(name), "{name:?}");
    }
    for name in ["api", "0a", "1.5", " 1", "é", "-1"] {
        assert!(chosen(name), "{name:?}");
    }
}
