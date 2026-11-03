use super::*;
use crate::system::System;

/// Records releases and holds their completions, so a test decides when each ends.
#[derive(Default)]
struct Fake {
    released: Rc<RefCell<Vec<(String, bool)>>>,
    held: Rc<RefCell<Vec<Done<()>>>>,
    /// The client serial each release named.
    owners: Rc<RefCell<Vec<u64>>>,
}
impl Plugin for Fake {
    fn name(&self) -> &str {
        "files"
    }
    fn event(&mut self, _: &mut dyn Io, _: &mut dyn Ui, _: Event) {}
    fn release(&mut self, _: &mut dyn Io, client: u64, transfer: &str, unpack: bool, done: Done<()>) {
        self.owners.borrow_mut().push(client);
        self.released.borrow_mut().push((transfer.to_owned(), unpack));
        self.held.borrow_mut().push(done);
    }
}

struct Run {
    system: System,
    transfers: Transfers,
    plugins: Vec<Shared<dyn Plugin>>,
    released: Rc<RefCell<Vec<(String, bool)>>>,
    held: Rc<RefCell<Vec<Done<()>>>>,
    owners: Rc<RefCell<Vec<u64>>>,
}

impl Run {
    fn new() -> Self {
        let fake = Fake::default();
        let (released, held, owners) = (fake.released.clone(), fake.held.clone(), fake.owners.clone());
        let plugin: Shared<dyn Plugin> = Rc::new(RefCell::new(fake));
        let transfers = Transfers::default();
        Self { system: System::new(2, 64).unwrap(), transfers, plugins: vec![plugin], released, held, owners }
    }

    /// Request `method` for `transfer` from `fd`: its observed completion.
    fn request<T: 'static>(&mut self, fd: RawFd, method: &str, transfer: &str, commit: bool) -> Done<T> {
        let params = Data::Object(vec![("transfer", Data::String(transfer)), ("commit", Data::Bool(commit))]);
        self.transfers.observe(fd, &self.plugins[0], method, &params, Box::new(|_, _| {}))
    }

    fn complete<T>(&mut self, done: Done<T>, result: Result<T, Error>) {
        done(&mut self.system, result);
        self.system.callbacks();
    }

    fn end(&mut self, fd: RawFd) {
        self.transfers.end(fd, &mut self.system, &self.plugins);
        self.system.callbacks();
    }

    fn released(&self) -> Vec<(String, bool)> {
        self.released.borrow().clone()
    }

    /// Every held release completes.
    fn finish(&mut self) {
        let held: Vec<_> = self.held.borrow_mut().drain(..).collect();
        for done in held {
            done(&mut self.system, Ok(()));
        }
        self.system.callbacks();
    }
}

fn refused(code: &'static str) -> Error {
    Error { code, message: String::new() }
}

#[test]
fn an_open_transfer_is_released_when_its_client_leaves_and_waited_for() {
    let mut run = Run::new();
    let open = run.request(3, "unpack_open", "a", false);
    run.complete(open, Ok(Transfer::default()));
    assert!(run.transfers.may_exit(false), "nothing runs while the client is there");
    run.end(3);
    assert_eq!(run.released(), [("a".to_owned(), true)]);
    assert!(!run.transfers.may_exit(false));
    assert!(run.transfers.may_exit(true), "past the deadline");
    run.finish();
    assert!(run.transfers.may_exit(false));
}

#[test]
fn a_closed_transfer_is_forgotten_only_once_its_close_completes() {
    let mut run = Run::new();
    let open = run.request(3, "unpack_open", "a", false);
    run.complete(open, Ok(Transfer::default()));
    // A close still running when the client leaves: the transfer is released all the same.
    let close = run.request::<Unpacked>(3, "unpack_close", "a", false);
    run.end(3);
    assert_eq!(run.released(), [("a".to_owned(), true)]);
    run.complete(close, Ok(Unpacked::default()));
    run.finish();
    assert!(run.transfers.may_exit(false));
    // A completed close leaves nothing to release.
    let open = run.request(4, "unpack_open", "b", false);
    run.complete(open, Ok(Transfer::default()));
    let close = run.request(4, "unpack_close", "b", false);
    run.complete(close, Ok(Unpacked::default()));
    run.end(4);
    assert_eq!(run.released().len(), 1);
}

#[test]
fn a_commit_in_flight_keeps_the_helper_past_its_deadline() {
    let mut run = Run::new();
    let open = run.request(3, "unpack_open", "a", false);
    run.complete(open, Ok(Transfer::default()));
    let commit = run.request(3, "unpack_close", "a", true);
    run.end(3);
    run.finish();
    assert!(!run.transfers.may_exit(true), "never during a commit's moves");
    run.complete(commit, Ok(Unpacked::default()));
    assert!(run.transfers.may_exit(false));
}

#[test]
fn a_pack_in_flight_when_its_client_leaves_is_released_when_it_completes() {
    let mut run = Run::new();
    let pack = run.request(3, "pack", "p", false);
    run.end(3);
    assert!(run.released().is_empty());
    assert!(!run.transfers.may_exit(false), "the pack is waited for");
    run.complete(pack, Ok(Packed::default()));
    assert_eq!(run.released(), [("p".to_owned(), false)]);
    run.finish();
    assert!(run.transfers.may_exit(false));
    // One that fails opened nothing; one whose completion is dropped unrun no longer counts.
    let pack = run.request::<Packed>(4, "pack", "q", false);
    let lost = run.request::<Packed>(4, "pack", "r", false);
    run.end(4);
    run.complete(pack, Err(refused("limit")));
    drop(lost);
    assert_eq!(run.released().len(), 1);
    assert!(run.transfers.may_exit(false));
}

#[test]
fn a_refused_duplicate_id_does_not_end_the_other_clients_transfer() {
    let mut run = Run::new();
    let first = run.request(3, "pack", "x", false);
    run.complete(first, Ok(Packed::default()));
    let second = run.request::<Packed>(4, "pack", "x", false);
    run.complete(second, Err(refused("invalid_request")));
    run.end(4);
    assert!(run.released().is_empty());
    run.end(3);
    assert_eq!(run.released(), [("x".to_owned(), false)]);
}

#[test]
fn a_release_needs_no_capability_the_client_lost() {
    let fake = Fake::default();
    let released = fake.released.clone();
    let mut registered = crate::registered::Registered {
        part: fake,
        section: "plugin/0".into(),
        muted: None,
        permitted: Rc::new(|_: &str| false),
    };
    let mut system = System::new(2, 64).unwrap();
    let denied = Rc::new(Cell::new(None));
    let code = denied.clone();
    registered.unpack_close(&mut system, "a", false, Box::new(move |_, result| code.set(result.err().map(|e| e.code))));
    registered.release(&mut system, 1, "a", true, Box::new(|_, _| {}));
    system.callbacks();
    assert_eq!(denied.get(), Some("permission_denied"));
    assert_eq!(released.borrow().as_slice(), [("a".to_owned(), true)]);
}

#[test]
fn a_client_never_dropping_its_packs_is_remembered_for_its_newest_only() {
    let mut run = Run::new();
    for index in 0..40 {
        let pack = run.request::<Packed>(3, "pack", &format!("p{index}"), false);
        run.complete(pack, Ok(Packed::default()));
    }
    let open = run.request::<Transfer>(3, "unpack_open", "u", false);
    run.complete(open, Ok(Transfer::default()));
    run.end(3);
    run.finish();
    let released = run.released();
    assert_eq!(released.len(), PACKS + 1, "{released:?}");
    assert!(released.contains(&("u".to_owned(), true)), "an open unpack is never forgotten");
    assert!(released.contains(&("p39".to_owned(), false)) && !released.contains(&("p0".to_owned(), false)), "{released:?}");
}

#[test]
fn a_refused_repeat_of_an_open_id_keeps_it_and_a_reused_fd_is_another_client() {
    let mut run = Run::new();
    let first = run.transfers.client(3);
    let pack = run.request::<Packed>(3, "pack", "x", false);
    run.complete(pack, Ok(Packed::default()));
    // The same id again, refused because it is held: still released when the client leaves.
    let again = run.request::<Packed>(3, "pack", "x", false);
    run.complete(again, Err(refused("invalid_request")));
    run.end(3);
    run.finish();
    assert_eq!(run.released(), [("x".to_owned(), false)]);
    assert_eq!(*run.owners.borrow(), [first], "released as the client that packed it");
    // The next connection on fd 3 is a client of its own.
    let second = run.transfers.client(3);
    assert_ne!(second, first);
    let pack = run.request::<Packed>(3, "pack", "y", false);
    run.complete(pack, Ok(Packed::default()));
    run.end(3);
    run.finish();
    assert_eq!(*run.owners.borrow(), [first, second]);
}
