//! Transcript read completions: page caching, generation, growth checks and publication.
use super::*;

impl Claude {
    pub(super) fn loaded(
        &mut self,
        io: &mut dyn Io,
        ui: &mut dyn Ui,
        mut request: Read,
        result: std::io::Result<Output>,
    ) {
        let missing = result
            .as_ref()
            .is_err_and(|e| e.kind() == std::io::ErrorKind::NotFound);
        let result = result.map_err(|e| error("io", e)).and_then(|output| {
            let cache = self.cache.get(&request.source);
            if request.checking {
                let Output::Read {
                    before,
                    after,
                    bytes,
                } = output
                else {
                    return Err(error("io", "Expected transcript guard"));
                };
                if !cache.is_some_and(|c| {
                    c.grown.check(
                        &request.reader.metadata.unwrap(),
                        &Output::Read {
                            before,
                            after,
                            bytes,
                        },
                    )
                }) {
                    if request.earlier || request.selected {
                        return Err(error("changed", "Claude transcript changed"));
                    }
                    self.cache.remove(&request.source);
                    request.reader = Reader::new(
                        request.path.clone(),
                        Parser::new(request.source.session()),
                        None,
                    );
                    request.checking = false;
                    return Ok(None);
                }
                request.checking = false;
                return Ok(request.reader.idle());
            }
            let first = request.reader.metadata.is_none();
            let result = request.reader.complete(output)?;
            if first && let Some(cache) = cache {
                let current = request.reader.metadata.unwrap();
                if !cache.grown.same_file(&current, &request.reader.prefix) {
                    if request.earlier || request.selected {
                        return Err(error("changed", "Claude transcript changed"));
                    }
                    self.cache.remove(&request.source);
                    request.reader = Reader::new(
                        request.path.clone(),
                        Parser::new(request.source.session()),
                        None,
                    );
                    return Ok(None);
                }
                request.checking = !cache.grown.tail.is_empty();
                if !request.checking && result.is_none() {
                    return Ok(request.reader.idle());
                }
            }
            Ok(result)
        });
        match result {
            // A cursor beyond the file (shortened) starts over as a fresh page.
            Err(e) if request.resume.is_some() && !missing && e.code == "changed" => {
                request.resume = None;
                request.reader = Reader::new(
                    request.path.clone(),
                    Parser::new(request.source.session()),
                    None,
                );
                let job = request.reader.job();
                self.submit(io, request, job)
            }
            Err(e) if !request.selected && (missing || e.code == "changed") => {
                self.stalled(io, ui, request, missing);
            }
            Err(e) => {
                finish(io, request.done, Err(e));
                self.pending(io, ui, request.binding, request.path);
            }
            Ok(_)
                if !request.selected
                    && !self.cache.contains_key(&request.source)
                    && request.reader.metadata.is_some_and(|m| m.size == 0) =>
            {
                self.stalled(io, ui, request, true);
            }
            Ok(None) => {
                let job = if request.checking {
                    let cache = &self.cache[&request.source];
                    Job::Read {
                        path: request.path.clone(),
                        offset: cache.offset - cache.grown.tail.len() as u64,
                        length: cache.grown.tail.len() as u64,
                    }
                } else {
                    request.reader.job()
                };
                self.submit(io, request, job)
            }
            Ok(Some((page, parser))) if request.resume.is_some() => {
                // Rebuilt context for a cursor: same file -> continue from its offset with the
                // cursor's tail as the guard (the normal check), else a fresh page.
                let cursor = request.resume.take().unwrap();
                let metadata = request.reader.metadata.unwrap();
                request.reader =
                    if (metadata.device, metadata.inode) == (cursor.device, cursor.inode) {
                        self.cache.insert(
                            request.source.clone(),
                            Cache {
                                grown: Grown {
                                    metadata,
                                    prefix: request.reader.prefix.clone(),
                                    tail: cursor.tail.clone(),
                                },
                                offset: cursor.offset,
                                parser: parser.clone(),
                                empty: false,
                                generation: cursor.generation.clone(),
                                earlier: page.earlier.map(|p| format!("{}:{p}", cursor.generation)),
                            },
                        );
                        Reader::live(request.path.clone(), parser, cursor.offset)
                    } else {
                        Reader::new(
                            request.path.clone(),
                            Parser::new(request.source.session()),
                            None,
                        )
                    };
                let job = request.reader.job();
                self.submit(io, request, job)
            }
            Ok(Some((mut page, parser))) => {
                let metadata = request.reader.metadata.unwrap();
                let previous = self.cache.get(&request.source);
                let initial = previous.is_none();
                let generation = if let Some(previous) = previous {
                    previous.generation.clone()
                } else {
                    let mut bytes = [0; 16];
                    if let Err(e) = io.random(&mut bytes) {
                        finish(io, request.done, Err(error("io", e)));
                        return;
                    }
                    let hex = bytes.iter().map(|b| format!("{b:02x}")).collect::<String>();
                    format!(
                        "{}-{}-{}-{}-{}",
                        &hex[..8],
                        &hex[8..12],
                        &hex[12..16],
                        &hex[16..20],
                        &hex[20..]
                    )
                };
                let mut tail = previous.map(|c| c.grown.tail.clone()).unwrap_or_default();
                tail.extend_from_slice(&request.reader.tail);
                let tail = tail[tail.len().saturating_sub(256)..].to_vec();
                page.earlier = if previous.is_some() && !request.earlier && !request.selected {
                    previous.unwrap().earlier.clone()
                } else {
                    page.earlier
                        .map(|position| format!("{generation}:{position}"))
                };
                let empty = previous.is_none_or(|c| c.empty) && page.records.is_empty();
                if request.earlier
                    && let Some(cache) = self.cache.get_mut(&request.source)
                {
                    cache.earlier = page.earlier.clone();
                }
                let state = parser.state.clone();
                let held = parser.held() as usize;
                let later = if matches!(request.source, Source::File(..))
                    && !request.earlier
                    && !request.selected
                {
                    Cursor {
                        generation: generation.clone(),
                        offset: request.reader.position - held as u64,
                        device: metadata.device,
                        inode: metadata.inode,
                        tail: tail[..tail.len().saturating_sub(held)].to_vec(),
                    }
                    .write()
                } else {
                    String::new()
                };
                let snapshot = Snapshot {
                    later,
                    session: parser.observed.clone(),
                    version: parser.version.clone(),
                    generation: generation.clone(),
                    initial,
                    caught_up: request.reader.position >= metadata.size,
                    invalidated: false,
                    awaiting_creation: initial && metadata.size == 0,
                    file: Some(FileIdentity {
                        device: metadata.device,
                        inode: metadata.inode,
                    }),
                };
                if !request.earlier && !request.selected {
                    self.cache.insert(
                        request.source,
                        Cache {
                            grown: Grown {
                                metadata,
                                prefix: request.reader.prefix,
                                tail,
                            },
                            offset: request.reader.position,
                            parser,
                            empty,
                            generation,
                            earlier: page.earlier.clone(),
                        },
                    );
                    if let Some(binding) = &request.binding
                        && ui.terminal(binding).is_some()
                    {
                        // Configuration from this read must precede records that can complete a turn.
                        ui.update(Update::State {
                            binding: binding.clone(),
                            state: self.current(binding).unwrap(),
                        });
                        if ui.watching(binding) {
                            self.watch(io, binding, &request.path);
                            if request.notify {
                                if initial {
                                    ui.update(Update::History {
                                        binding: binding.clone(),
                                        page: page.clone(),
                                    });
                                } else if !page.records.is_empty() {
                                    ui.update(Update::Records {
                                        binding: binding.clone(),
                                        records: page.records.clone(),
                                    });
                                }
                            }
                        }
                    }
                }
                finish(
                    io,
                    request.done,
                    Ok(Archive {
                        page,
                        snapshot,
                        state,
                    }),
                );
                self.pending(io, ui, request.binding, request.path);
            }
        }
    }
}

/// Where an archive read continues (Snapshot.later, opaque to core): the generation, the end of
/// the last complete line, the file identity and up to 256 bytes before that end as the guard.
#[derive(Clone)]
pub(super) struct Cursor {
    pub(super) generation: String,
    pub(super) offset: u64,
    pub(super) device: u64,
    pub(super) inode: u64,
    pub(super) tail: Vec<u8>,
}
impl Cursor {
    pub(super) fn write(&self) -> String {
        use dispatch_helper4_core::json::{self, Data};
        let tail = self
            .tail
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>();
        let data = Data::Object(vec![
            ("generation", Data::String(&self.generation)),
            ("offset", Data::Unsigned(self.offset)),
            ("device", Data::Unsigned(self.device)),
            ("inode", Data::Unsigned(self.inode)),
            ("tail", Data::String(&tail)),
        ]);
        String::from_utf8(json::write(&data).unwrap()).unwrap()
    }
    pub(super) fn read(text: &str) -> Option<Self> {
        let doc = dispatch_helper4_core::json::Json::parse(text.as_bytes()).ok()?;
        let root = doc.root();
        let number = |name| root.get(name)?.unsigned();
        let tail = root.get("tail")?.string()?;
        Some(Self {
            generation: root.get("generation")?.string()?.to_owned(),
            offset: number("offset")?,
            device: number("device")?,
            inode: number("inode")?,
            tail: (0..tail.len())
                .step_by(2)
                .map(|i| u8::from_str_radix(tail.get(i..i + 2)?, 16).ok())
                .collect::<Option<_>>()?,
        })
    }
    /// The cache was left exactly at this cursor (fast path).
    pub(super) fn continues(&self, cache: &Cache) -> bool {
        cache.generation == self.generation
            && cache.offset - cache.parser.held() == self.offset
            && (cache.grown.metadata.device, cache.grown.metadata.inode)
                == (self.device, self.inode)
    }
}
