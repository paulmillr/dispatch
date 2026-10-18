use super::*;
use std::cell::Cell;

/// A clock that only the sleeps move.
fn run(answers: &[(usize, bool)], settle: Duration) -> (io::Result<Vec<usize>>, usize, Duration) {
    let start = Instant::now();
    let (elapsed, asked) = (Cell::new(Duration::ZERO), Cell::new(0));
    let result = asking(
        || {
            let (owners, named) = answers[asked.get().min(answers.len() - 1)];
            asked.set(asked.get() + 1);
            Ok(((0..owners).collect(), named))
        },
        start + settle,
        || start + elapsed.get(),
        |pause| elapsed.set(elapsed.get() + pause),
    );
    (result, asked.get(), elapsed.get())
}

#[test]
fn a_live_named_helper_is_asked_again_until_it_claims_its_new_terminal() {
    // herdr reports the pane's tty after the launcher first asks.
    let (owners, asked, waited) = run(&[(0, true), (0, true), (1, true)], SETTLE);
    assert_eq!(owners.unwrap(), [0]);
    assert_eq!(asked, 3);
    assert_eq!(waited, RETRY * 2);
}

#[test]
fn without_a_live_named_helper_or_once_settled_the_first_answer_stands() {
    let (owners, asked, _) = run(&[(0, false)], SETTLE);
    assert!(owners.unwrap().is_empty());
    assert_eq!(asked, 1, "no named helper: nobody to wait for");
    let (owners, asked, waited) = run(&[(0, true)], SETTLE);
    assert!(owners.unwrap().is_empty());
    assert!(waited < SETTLE && asked as u32 == SETTLE.as_millis() as u32 / RETRY.as_millis() as u32);
    let (_, asked, _) = run(&[(0, true)], Duration::ZERO);
    assert_eq!(asked, 1, "hooks never wait");
}
