use super::*;
use crate::system::System;

/// Records releases and holds their completions, so a test decides when each ends.
#[derive(Default)]
struct Fake {
    released: Rc<RefCell<Vec<(String, bool)>>>,
    held: Rc<RefCell<Vec<Done<()>>>>,
}
impl Plugin for Fake {
    fn name(&self) -> &str {
        "files"
    }
    fn event(&mut self, _: &mut dyn Io, _: &mut dyn Ui, _: Event) {}
    fn release(&mut self, _: &mut dyn Io, transfer: &str, unpack: bool, done: Done<()>) {
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
}

impl Run {
    fn new() -> Self {
        let fake = Fake::default();
        let (released, held) = (fake.released.clone(), fake.held.clone());
        let plugin: Shared<dyn Plugin> = Rc::new(RefCell::new(fake));
        Self { system: System::new(2, 64).unwrap(), transfers: Transfers::default(), plugins: vec![plugin], released, held }
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
    registered.release(&mut system, "a", true, Box::new(|_, _| {}));
    system.callbacks();
    assert_eq!(denied.get(), Some("permission_denied"));
    assert_eq!(released.borrow().as_slice(), [("a".to_owned(), true)]);
}
