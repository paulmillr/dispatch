use super::*;

impl Request<'_> {
    /// Protocol result: Hello JSON object encoded by this handler
    pub(super) fn hello(&mut self, _p: &Data<'_>) -> Result<(), Error> {
        if !self.helper.answerable() {
            if self.helper.identity.is_none() && self.helper.identity_job.is_none() {
                let job = self.io.submit(Job::Native {
                    name: "host.identity",
                    value: crate::wire::body::encode_plain(&crate::json::Data::Object(Vec::new()))?,
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
            .map(|value| crate::encode::Raw(value));
        let ops = OPERATIONS
            .iter()
            .filter(|method| self.helper.allowed(method) && self.registered(method))
            .map(|s| s.to_string())
            .collect::<Vec<_>>();
        if features::asked(&self.document) {
            // Only a client that named features gets this reply shape (dispatch/features.rs).
            let login_home = features::login_home(&home, self.helper.login_home.as_deref());
            let mut fields = vec![
                ("uid", crate::json::Data::Unsigned(uid.into())),
                ("home", crate::json::Data::String(&home)),
            ];
            if let Some(login_home) = &login_home {
                fields.push(("login_home", crate::json::Data::String(login_home)));
            }
            let extended = crate::json::Data::Object(fields);
            let accepted: Vec<String> = self
                .helper
                .features
                .borrow()
                .get(&self.fd)
                .map(|set| set.iter().map(|s| s.to_string()).collect())
                .unwrap_or_default();
            if accepted.iter().any(|feature| feature == features::ATTACHMENTS) {
                // History strips path lines under this account's attachments root only.
                attachments::cache(self.io, &self.helper.held);
            }
            let ops: Vec<String> = ops
                .iter()
                .cloned()
                .chain(features::offered(&accepted, |op| self.helper.allowed(op)))
                .collect();
            crate::encode::object(
                &mut out,
                &[
                    ("version", &wire::VERSION),
                    ("frame_limit", &wire::LIMIT),
                    ("chunk_kind", &(wire::Kind::Chunk as u64)),
                    ("chunk_limit", &(wire::CHUNK as u64)),
                    ("os", &self.io.os()),
                    ("arch", &self.io.arch()),
                    ("account", &extended),
                    ("terminal", &terminal),
                    ("process", &process),
                    ("identity", &identity),
                    ("plugins", &plugins),
                    ("unavailable_harnesses", &self.helper.unavailable),
                    ("ops", &ops),
                    ("features", &accepted),
                ],
            );
            self.replies.borrow_mut().push_back((
                self.fd,
                wire::Kind::Response,
                self.id,
                crate::encode::value(&crate::encode::Fields(&[("result", &crate::encode::Raw(&out))])),
            ));
            return Ok(());
        }
        crate::encode::object(
            &mut out,
            &[
                ("version", &wire::VERSION),
                ("frame_limit", &wire::LIMIT),
                ("chunk_kind", &(wire::Kind::Chunk as u64)),
                ("chunk_limit", &(wire::CHUNK as u64)),
                ("os", &self.io.os()),
                ("arch", &self.io.arch()),
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
            crate::encode::value(&crate::encode::Fields(&[("result", &crate::encode::Raw(&out))])),
        ));
        Ok(())
    }
}
