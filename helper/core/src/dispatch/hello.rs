use super::*;

impl Request<'_> {
    /// Protocol result: Hello JSON object encoded by this handler
    pub(super) fn hello(&mut self, _p: Value<'_>) -> Result<(), Error> {
        if !self.helper.answerable() {
            if self.helper.identity.is_none() && self.helper.identity_job.is_none() {
                let job = self.io.submit(Job::Native {
                    name: "host.identity",
                    input: b"{}".to_vec(),
                });
                self.helper.identity_job = Some(job.map_err(|error| Error {
                    code: "io_failure",
                    message: error.to_string(),
                })?);
            }
            self.helper
                .hellos
                .push((self.fd, self.id, self.document.clone()));
            return Ok(());
        }
        let plugins: Vec<_> = self
            .helper
            .plugins
            .iter()
            .map(|p| p.borrow().name().to_owned())
            .collect();
        let mut out = Vec::new();
        let (uid, home) = crate::system::System::account().map_err(|error| Error {
            code: "io_failure",
            message: error.to_string(),
        })?;
        let home = home.to_string_lossy();
        let account = crate::json::Data::Object(vec![
            ("uid", crate::json::Data::Unsigned(uid.into())),
            ("home", crate::json::Data::String(&home)),
        ]);
        let (terminal, process) = self
            .helper
            .login
            .as_ref()
            .map(|login| {
                let login = login.borrow();
                (login.terminal, login.process.clone())
            })
            .unwrap_or_default();
        let process = process.as_ref().map(|process| {
            crate::json::Data::Object(vec![
                ("pid", crate::json::Data::Unsigned(process.pid.into())),
                (
                    "start",
                    crate::json::Data::Array(
                        process
                            .start
                            .iter()
                            .map(|value| crate::json::Data::Unsigned(*value))
                            .collect(),
                    ),
                ),
            ])
        });
        let identity = self
            .helper
            .identity
            .as_ref()
            .map(|json| crate::json::Data::Value(json.root()));
        crate::encode::object(
            &mut out,
            &[
                ("version", &wire::VERSION),
                ("frame_limit", &wire::LIMIT),
                ("chunk_kind", &(wire::Kind::Chunk as u64)),
                ("chunk_limit", &(wire::CHUNK as u64)),
                ("os", &std::env::consts::OS),
                ("arch", &std::env::consts::ARCH),
                ("account", &account),
                ("terminal", &terminal),
                ("process", &process),
                ("identity", &identity),
                ("plugins", &plugins),
                ("unavailable_harnesses", &self.helper.unavailable),
                (
                    "ops",
                    &OPERATIONS
                        .iter()
                        .filter(|method| self.helper.allowed(method) && self.registered(method))
                        .map(|s| s.to_string())
                        .collect::<Vec<_>>(),
                ),
            ],
        );
        self.replies.borrow_mut().push_back((
            self.fd,
            wire::Kind::Response,
            self.id,
            [b"{\"result\":".as_slice(), &out, b"}"].concat(),
        ));
        Ok(())
    }
}
