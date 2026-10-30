//! `login.release {session, path}` (feature `login.release`): the Mac's greeting probe releases the SSH login waiting
//! for its ready file (system/release.rs) once the app verified the probe's greeting, instead of a separate exec
//! channel running the same checks as a script. Only a `--remote --stdio` helper without the login wrapper accepts the
//! feature (helper.rs), and it needs no grant: it runs before any exists, like `hello`, in a probe started with none.
use super::*;

impl Request<'_> {
    /// Protocol result: null once `ready` names `path`; `unavailable` with the script's reason when refused.
    pub(crate) fn login_release(&mut self, params: &Data<'_>) -> Result<(), Error> {
        params::validate(
            params,
            params::Rule::Object(&[("session", params::Rule::Text), ("path", params::Rule::Text)]),
            "params",
        )?;
        let session = text(params, "session")?;
        let path = text(params, "path")?;
        if !crate::system::release::session(session) {
            return Err(invalid("session"));
        }
        if !crate::system::release::published(path) {
            return Err(invalid("path"));
        }
        let value = crate::wire::body::encode_plain(&Data::Object(vec![
            ("session", Data::String(session)),
            ("path", Data::String(path)),
        ]))?;
        let failed = |message: String| Error { code: "io_failure", message };
        let work = self
            .io
            .submit(Job::Native { name: "login.release", value })
            .map_err(|error| failed(error.to_string()))?;
        let done = self.done::<()>(None);
        self.io.then(
            work,
            Box::new(move |io, result| {
                let result = match result {
                    Ok(Output::Value(bytes)) => match crate::wire::body::decode_plain(&bytes) {
                        Ok(value) => match value.get("reason").and_then(Data::string) {
                            Some(reason) => Err(Error { code: "unavailable", message: reason.to_owned() }),
                            None => Ok(()),
                        },
                        Err(error) => Err(failed(error.message)),
                    },
                    Ok(_) => Err(failed("login.release".into())),
                    Err(error) => Err(failed(error.to_string())),
                };
                done(io, result);
            }),
        );
        Ok(())
    }
}
