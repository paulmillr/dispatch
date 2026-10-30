use super::*;

const MAC: RawFd = 5;
const PHONE: RawFd = 6;
const T: Id = 1 << 48 | 7;

fn attached(pairs: &[(RawFd, Id)]) -> BTreeSet<(RawFd, Id)> {
    pairs.iter().copied().collect()
}

#[test]
fn a_screens_host_attach_hosts_and_a_publication_wins_until_its_client_leaves() {
    let hosts = |fd| fd == MAC;
    let mut publishers = BTreeMap::new();
    let mut last = BTreeMap::new();
    let mut step = |open: &[(RawFd, Id)], publishers: &mut BTreeMap<(RawFd, Id), bool>| {
        let now = sources(&attached(open), hosts, publishers);
        let changed = changes(&last, &now);
        last = now;
        changed
    };
    // The Mac (screens.host) attaches: host reads on.
    assert_eq!(step(&[(MAC, T)], &mut publishers), [(T, (true, false))]);
    // The phone attaches and publishes: its screens win.
    publishers.insert((PHONE, T), false);
    assert_eq!(step(&[(MAC, T), (PHONE, T)], &mut publishers), [(T, (true, true))]);
    assert_eq!(step(&[(MAC, T), (PHONE, T)], &mut publishers), []);
    // The phone's attach ends: host reads resume.
    assert_eq!(step(&[(MAC, T)], &mut publishers), [(T, (true, false))]);
    assert!(publishers.is_empty());
    // The Mac leaves too: nothing left to say after this.
    assert_eq!(step(&[], &mut publishers), [(T, (false, false))]);
    assert_eq!(step(&[], &mut publishers), []);
}

#[test]
fn a_client_without_the_feature_never_hosts() {
    let mut publishers = BTreeMap::from([((PHONE, T), false)]);
    let now = sources(&attached(&[(PHONE, T)]), |_| false, &mut publishers);
    assert_eq!(now, BTreeMap::from([(T, (false, true))]));
    let now = sources(&attached(&[(MAC, T)]), |_| false, &mut BTreeMap::new());
    assert!(now.is_empty());
}

#[test]
fn a_publication_without_an_attach_stays_while_its_client_does() {
    let mut publishers = BTreeMap::from([((PHONE, T), false)]);
    let open = attached(&[(MAC, T)]);
    for _ in 0..3 {
        assert_eq!(sources(&open, |fd| fd == MAC, &mut publishers), BTreeMap::from([(T, (true, true))]));
    }
    // (The client's close removes its publications, helper.rs.)
    publishers.retain(|(fd, _), _| *fd != PHONE);
    assert_eq!(sources(&open, |fd| fd == MAC, &mut publishers), BTreeMap::from([(T, (true, false))]));
}
