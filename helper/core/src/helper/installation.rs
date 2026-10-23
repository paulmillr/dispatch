//! Re-plan a setup conflict from fresh process and file snapshots. Never retry a partial
//! installation, a process-identity failure, or an arbitrary IO error.
use crate::api::*;
use std::rc::Rc;

type Attempt = Rc<dyn Fn(&mut dyn Io, Done<Install>)>;

pub(crate) fn run(
    io: &mut dyn Io,
    allowed: Rc<dyn Fn() -> bool>,
    attempt: Attempt,
    done: Done<Install>,
) {
    retry(io, allowed, attempt, done, 2);
}
fn retry(
    io: &mut dyn Io,
    allowed: Rc<dyn Fn() -> bool>,
    attempt: Attempt,
    done: Done<Install>,
    remaining: u8,
) {
    if !allowed() {
        return done(io, Err(super::client::cancelled()));
    }
    let again = attempt.clone();
    attempt(
        io,
        Box::new(move |io, result| {
            if remaining > 0 && result.as_ref().is_err_and(|error| error.code == "changed") {
                // Yield before calling the harness again, even if it completed synchronously.
                // Its entire read/plan/check transaction must run again; never reuse an edit.
                io.defer(Box::new(move |io| {
                    retry(io, allowed, again, done, remaining - 1)
                }));
            } else {
                done(io, result);
            }
        }),
    );
}

#[cfg(test)]
#[path = "installation.test.rs"]
mod tests;
