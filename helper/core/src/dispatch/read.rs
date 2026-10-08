use super::*;
use std::cell::Cell;

fn stamp(p: Value<'_>, name: &str) -> Result<i128, Error> {
    let value = p.get(name).ok_or_else(|| invalid(name))?;
    value
        .string()
        .and_then(|s| s.parse().ok())
        .or_else(|| value.signed().map(i128::from))
        .or_else(|| value.unsigned().map(i128::from))
        .ok_or_else(|| invalid(name))
}

/// files.read `revision`: each present field is checked, absent ones are not.
fn guard(p: Value<'_>) -> Result<Guard, Error> {
    let present = |name| p.get(name).is_some();
    Ok(Guard {
        kind: present("kind")
            .then(|| match text(p, "kind")? {
                "file" => Ok(FileKind::File),
                "directory" => Ok(FileKind::Directory),
                "symlink" => Ok(FileKind::Symlink),
                "other" => Ok(FileKind::Other),
                _ => Err(invalid("kind")),
            })
            .transpose()?,
        size: present("size").then(|| number(p, "size")).transpose()?,
        device: present("device").then(|| number(p, "device")).transpose()?,
        inode: present("inode").then(|| number(p, "inode")).transpose()?,
        modified_ns: present("modified_ns")
            .then(|| stamp(p, "modified_ns"))
            .transpose()?,
        changed_ns: present("changed_ns")
            .then(|| stamp(p, "changed_ns"))
            .transpose()?,
    })
}

impl Request<'_> {
    /// Protocol result: binary chunks followed by Metadata
    pub(super) fn read(&mut self, p: Value<'_>) -> Result<(), Error> {
        let name = p
            .get("plugin")
            .and_then(Value::string)
            .unwrap_or(plugin("read"));
        let plugin = self
            .helper
            .plugins
            .iter()
            .find(|v| v.borrow().name() == name)
            .cloned()
            .ok_or_else(|| Error {
                code: "unsupported",
                message: format!("Plugin {name} unavailable"),
            })?;
        let read = Read {
            path: text(p, "path")?.into(),
            offset: p
                .get("offset")
                .map(|_| number(p, "offset"))
                .transpose()?
                .unwrap_or(0),
            length: p.get("length").map(|_| number(p, "length")).transpose()?,
            revision: p
                .get("revision")
                .filter(|v| v.kind() != crate::json::Kind::Null)
                .map(guard)
                .transpose()?
                .unwrap_or_default(),
        };
        let progress = Rc::new(RefCell::new(wire::Progress::default()));
        let active = Rc::new(Cell::new(true));
        let outstanding = Rc::new(Cell::new(false));
        let (fd, id) = (self.fd, self.id);
        let replies = self.replies.clone();
        let drains = self.helper.drains.clone();
        let counters = progress.clone();
        let alive = active.clone();
        let chunk: Chunk = Box::new(move |io, bytes, done| {
            let body = if !alive.get() {
                Err(Error {
                    code: "cancelled",
                    message: String::new(),
                })
            } else if outstanding.get() {
                Err(Error {
                    code: "busy",
                    message: "Response chunk is still pending".into(),
                })
            } else {
                counters
                    .borrow_mut()
                    .chunk(&bytes)
                    .map_err(|_| invalid("chunk"))
            };
            match body {
                Ok(body) => {
                    outstanding.set(true);
                    replies
                        .borrow_mut()
                        .push_back((fd, wire::Kind::Chunk, id, body));
                    let alive = alive.clone();
                    let outstanding = outstanding.clone();
                    drains.borrow_mut().push_back((
                        fd,
                        id,
                        Box::new(move |io, result| {
                            outstanding.set(false);
                            if result.is_err() {
                                alive.set(false);
                            }
                            done(io, result);
                        }),
                    ));
                }
                Err(error) => deferred(done)(io, Err(error)),
            }
        });
        let replies = self.replies.clone();
        let done: Done<Metadata> = Box::new(move |_, result| {
            if !active.get() {
                return;
            }
            let mut value = Vec::new();
            let result = match &result {
                Ok(metadata) => {
                    metadata.encode(&mut value);
                    Ok(Some(value.as_slice()))
                }
                Err(error) => Err(error),
            };
            let body = progress.borrow().finish("binary", result);
            replies
                .borrow_mut()
                .push_back((fd, wire::Kind::Response, id, body));
        });
        plugin
            .borrow_mut()
            .read(self.io, &read, wire::CHUNK, chunk, done);
        Ok(())
    }
}
