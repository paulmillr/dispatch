use super::*;
use std::io;
const LIMIT: usize = 1_048_576; // TUI MAX_FRAME; retained native ledger is16MiB/65536 IDs.
pub(super) struct Call {
    done: Callback<Json>,
    mutation: bool,
}
pub(super) struct Channel {
    pub binding: Binding,
    pub instance: String,
    pub snapshot: Option<Json>,
    pub empty: bool,
    pub conversations: BTreeMap<String, Conversation>,
    pub client: rpc::Client<rpc::Lines, Call>,
    ready: Option<Done<Option<Binding>>>,
    hello: Instant,
    seq: u64,
    changed: bool,
    seeding: bool,
    flush: Option<Instant>,
    watch: Option<u64>,
    pub waits: Vec<side::Wait>,
    confirmations: BTreeMap<rpc::Id, Option<Instant>>,
}
pub(super) struct Conversation {
    pub binding: Binding,
    pub turns: Vec<String>,
    projection: records::Projection,
    usage: records::Usage,
    pub rows: Vec<Record>,
    attached: bool,
}
impl Conversation {
    pub fn new(binding: Binding, side: bool) -> Self {
        Self {
            binding,
            turns: vec![],
            projection: records::Projection::new(side),
            rows: vec![],
            usage: records::Usage::default(),
            attached: false,
        }
    }
}
impl Channel {
    pub fn new(
        io: &mut dyn Io,
        fd: RawFd,
        binding: Binding,
        instance: String,
        done: Done<Option<Binding>>,
        remote: bool,
    ) -> Self {
        let hello = io.now() + Duration::from_secs(if remote { 5 } else { 10 });
        io.timer(hello);
        Self {
            conversations: BTreeMap::from([(
                binding.session.clone(),
                Conversation::new(binding.clone(), false),
            )]),
            binding,
            instance,
            snapshot: None,
            empty: true,
            client: rpc::Client::new(
                rpc::transport::Stream::new(fd, fd, rpc::Lines::new(LIMIT), 16 * LIMIT),
                65536,
                16 * LIMIT,
            ),
            ready: Some(done),
            hello,
            seq: 0,
            changed: false,
            seeding: true,
            flush: None,
            watch: None,
            waits: vec![],
            confirmations: BTreeMap::new(),
        }
    }
    fn snapshot(&mut self, doc: Json) -> Result<(), Error> {
        let s = doc.root();
        if string(s, "instance_id") != self.instance
            || string(s, "active_generation").is_empty()
            || string(s, "seq").parse::<u64>().is_err()
            || string(s, "snapshot_token").is_empty()
            || s.get("state").and_then(Value::object).is_none()
        {
            return Err(error("protocol", "Nanocodex returned invalid state."));
        }
        let seq = string(s, "seq").parse::<u64>().unwrap();
        if seq < self.seq {
            return Ok(());
        }
        self.seq = seq;
        let session = string(s, "active_session_id");
        if self.binding.session.is_empty() && !session.is_empty() {
            self.binding.session = session.into();
            self.binding.transcript = s
                .get("conversations")
                .and_then(|v| v.get(session))
                .filter(|v| string(*v, "session_id") == session)
                .and_then(|v| v.get("rollout_path"))
                .and_then(Value::string)
                .filter(|path| path.starts_with('/'))
                .map(PathBuf::from);
            let mut conversation = self.conversations.remove("").unwrap();
            conversation.binding = self.binding.clone();
            self.conversations.insert(session.into(), conversation);
        }
        self.empty = string(s, "state.composer.text").is_empty()
            && value(s, "state.composer.attachments")
                .and_then(Value::array)
                .is_none_or(|mut a| a.next().is_none());
        for (session, conversation) in &mut self.conversations {
            conversation.turns = s
                .get("active_turns")
                .and_then(|v| v.get(session))
                .and_then(Value::array)
                .map(|a| a.filter_map(Value::string).map(str::to_owned).collect())
                .unwrap_or_default();
        }
        self.snapshot = Some(doc);
        self.changed = true;
        Ok(())
    }

    fn change(&mut self, event: Value<'_>) -> Result<bool, Error> {
        let Some((snapshot, fresh)) = changed(self.snapshot.as_ref().unwrap(), event)? else {
            return Ok(false);
        };
        if string(event, "type") == "state.changed" {
            let data = event.get("data").unwrap();
            self.empty = data.get("composer_empty").and_then(Value::boolean).unwrap();
            if let Some(turns) = data.get("active_turns") {
                for (session, conversation) in &mut self.conversations {
                    conversation.turns = turns
                        .get(session)
                        .and_then(Value::array)
                        .map(|a| a.filter_map(Value::string).map(str::to_owned).collect())
                        .unwrap_or_default();
                }
            }
        }
        self.snapshot = Some(snapshot);
        self.changed = true;
        Ok(fresh)
    }
}
/// Merge a native notification; the boolean says whether the draft is still current.
pub fn changed(snapshot: &Json, event: Value<'_>) -> Result<Option<(Json, bool)>, Error> {
    let snapshot = snapshot.root();
    if string(event, "active_generation") != string(snapshot, "active_generation") {
        return Ok(None);
    }
    let Some(data) = event.get("data") else {
        return Ok(None);
    };
    let old = snapshot.get("state").unwrap();
    let settings = string(event, "type") == "settings.changed";
    let Some(published) = data.get(if settings { "settings" } else { "state" }) else {
        return Ok(None);
    };
    let Some(fields) = published.object() else {
        return Ok(None);
    };
    let mut state = if settings {
        old.object()
            .unwrap()
            .filter(|(key, _)| !["settings", "settings_revision"].contains(key))
            .map(|(key, value)| (key, Data::Value(value)))
            .collect::<Vec<_>>()
    } else {
        fields
            .map(|(key, value)| (key, Data::Value(value)))
            .collect()
    };
    if settings {
        state.push(("settings", Data::Value(published)));
        if let Some(revision) = data.get("settings_revision") {
            state.push(("settings_revision", Data::Value(revision)));
        }
    } else {
        if data
            .get("composer_empty")
            .and_then(Value::boolean)
            .is_none()
        {
            return Ok(None);
        }
        if let Some(composer) = old.get("composer") {
            state.push(("composer", Data::Value(composer)));
        }
    }
    let draft = !settings && string(old, "draft_revision") != string(published, "draft_revision");
    let mut fields = snapshot
        .object()
        .unwrap()
        .filter(|(key, _)| *key != "state")
        .map(|(key, value)| (key, Data::Value(value)))
        .collect::<Vec<_>>();
    fields.push(("state", Data::Object(state)));
    Ok(Some((document(Data::Object(fields))?, !draft)))
}
pub(super) fn observed(s: Value<'_>, v: &Conversation) -> State {
    let mut state = records::Projection::state(s, &v.binding.session, &v.turns);
    state.usage = v.usage.payload();
    state
}
impl Nano {
    pub(super) fn refresh(&mut self, io: &mut dyn Io, pid: u32, done: Callback<Json>) {
        self.request(
            io,
            pid,
            "state.get",
            empty().root(),
            false,
            Box::new(move |this, io, result| {
                let result = result.and_then(|doc| {
                    this.channels
                        .get_mut(&pid)
                        .ok_or_else(|| error("closed", "Nanocodex closed its control connection."))?
                        .snapshot(Json::parse(&doc.root().write()?)?)?;
                    Ok(doc)
                });
                done(this, io, result);
            }),
        );
    }
    fn seed(&mut self, io: &mut dyn Io, pid: u32, offset: u64) {
        let Some(c) = self.channels.get(&pid) else {
            return;
        };
        let s = c.snapshot.as_ref().unwrap().root();
        if c.conversations.values().all(|v| v.turns.is_empty()) {
            self.subscribe(io, pid);
            return;
        }
        if flag(s, "capabilities.history_chunked") {
            self.seed_pending(io, pid, offset);
            return;
        }
        let params = document(Data::Object(vec![
            ("snapshot_token", Data::String(string(s, "snapshot_token"))),
            ("offset", Data::Unsigned(offset)),
            ("limit", Data::Unsigned(128)),
        ]))
        .unwrap();
        self.request(
            io,
            pid,
            "history.live",
            params.root(),
            false,
            Box::new(move |this, io, result| {
                let doc = match result {
                    Ok(v) => v,
                    Err(e) => {
                        this.closed(io, pid, e.message);
                        return;
                    }
                };
                if let Some(c) = this.channels.get_mut(&pid)
                    && let Some(rows) = doc.root().get("records").and_then(Value::array)
                {
                    for row in rows {
                        let Some(v) = c
                            .conversations
                            .get_mut(string(row, "session_id"))
                            .filter(|v| v.turns.iter().any(|t| t == string(row, "turn_id")))
                        else {
                            continue;
                        };
                        v.rows.extend(
                            v.projection
                                .live(row, true, None, &digest, &printable)
                                .into_iter()
                                .filter(|r| {
                                    !matches!(
                                        r.kind,
                                        RecordKind::TurnStarted | RecordKind::TurnEnded
                                    )
                                }),
                        );
                    }
                }
                let next = doc
                    .root()
                    .get("next_offset")
                    .and_then(Value::unsigned)
                    .filter(|n| *n > offset);
                if flag(doc.root(), "has_more")
                    && let Some(next) = next
                {
                    this.seed(io, pid, next);
                } else {
                    this.subscribe(io, pid);
                }
            }),
        );
    }
    fn seed_pending(&mut self, io: &mut dyn Io, pid: u32, cursor: u64) {
        let snapshot = self
            .channels
            .get(&pid)
            .unwrap()
            .snapshot
            .as_ref()
            .unwrap()
            .root();
        let params = document(Data::Object(vec![
            (
                "boundary",
                Data::String(string(snapshot, "pending_history.boundary")),
            ),
            ("cursor", Data::Unsigned(cursor)),
            ("order", Data::String("oldest")),
            ("limit", Data::Unsigned(16)),
        ]))
        .unwrap();
        self.pending(
            io,
            pid,
            params,
            Box::new(move |this, io, result| {
                let (page, records) = match result {
                    Ok(value) => value,
                    Err(e) => {
                        this.closed(io, pid, e.message);
                        return;
                    }
                };
                if let Some(channel) = this.channels.get_mut(&pid) {
                    for record in records {
                        if string(record.root(), "type") != "agent.event" {
                            continue;
                        }
                        let Some(data) = record.root().get("data") else {
                            continue;
                        };
                        let Some(conversation) =
                            channel.conversations.get_mut(string(data, "request_id"))
                        else {
                            continue;
                        };
                        conversation.usage.observe(data);
                        if !conversation
                            .turns
                            .iter()
                            .any(|t| t == string(data, "payload.turn_id"))
                        {
                            continue;
                        }
                        conversation.rows.extend(
                            conversation
                                .projection
                                .live(data, false, None, &digest, &printable)
                                .into_iter()
                                .filter(|row| {
                                    !matches!(
                                        row.kind,
                                        RecordKind::TurnStarted | RecordKind::TurnEnded
                                    )
                                }),
                        );
                    }
                }
                if flag(page.root(), "has_more") {
                    if let Ok(next) = string(page.root(), "next_cursor").parse() {
                        this.seed(io, pid, next);
                    } else {
                        this.closed(io, pid, "Invalid Nanocodex journal cursor.".into());
                    }
                } else {
                    this.subscribe(io, pid);
                }
            }),
        );
    }
    fn subscribe(&mut self, io: &mut dyn Io, pid: u32) {
        let Some(c) = self.channels.get_mut(&pid) else {
            return;
        };
        c.seeding = false;
        c.changed = true;
        let params = document(Data::Object(vec![
            (
                "after_seq",
                Data::String(string(c.snapshot.as_ref().unwrap().root(), "seq")),
            ),
            (
                "exclude_types",
                Data::Array(vec![
                    Data::String("api.event"),
                    Data::String("model.call.started"),
                    Data::String("model.call.failed"),
                    Data::String("model.warmup.*"),
                ]),
            ),
        ]))
        .unwrap();
        self.request(
            io,
            pid,
            "events.subscribe",
            params.root(),
            false,
            Box::new(move |this, io, result| {
                if !result.is_ok_and(|d| flag(d.root(), "subscribed")) {
                    this.closed(io, pid, "Nanocodex rejected the event subscription.".into());
                    return;
                }
                if let Some(c) = this.channels.get_mut(&pid) {
                    if let Some(path) = &c.binding.transcript {
                        c.watch = io.watch(path, false).ok();
                    }
                    if let Some(done) = c.ready.take() {
                        done(io, Ok(Some(c.binding.clone())));
                    }
                }
            }),
        );
    }
    fn response(
        &mut self,
        io: &mut dyn Io,
        pid: u32,
        id: rpc::Id,
        mut call: rpc::Call<Call>,
        result: Result<Json, Error>,
    ) {
        let Some(c) = self.channels.get_mut(&pid) else {
            return;
        };
        let result = if call.value.mutation {
            result.and_then(records::Projection::receipt)
        } else {
            result
        };
        if call.value.mutation
            && result
                .as_ref()
                .is_ok_and(|d| string(d.root(), "status") == "pending")
        {
            if !c.confirmations.contains_key(&id) {
                call.deadline = io.now() + Duration::from_secs(30);
            }
            let at = io.now() + Duration::from_millis(250);
            if let Err((_, call)) = c.client.wait(io, id.clone(), call) {
                c.confirmations.remove(&id);
                (call.value.done)(
                    self,
                    io,
                    Err(error(
                        "unknown",
                        "Nanocodex could not track its pending request.",
                    )),
                );
            } else {
                c.confirmations.insert(id, Some(at));
                io.timer(at);
            }
            return;
        }
        c.confirmations.remove(&id);
        (call.value.done)(self, io, result);
    }
    fn confirm(&mut self, io: &mut dyn Io, pid: u32, id: rpc::Id) {
        let params = document(Data::Object(vec![(
            "request_id",
            match &id {
                rpc::Id::String(id) => Data::String(id),
                rpc::Id::Integer(id) => Data::Signed(*id),
            },
        )]))
        .unwrap();
        self.request(io, pid, "request.get", params.root(), false, Box::new(move |this, io, result| {
            let Some(channel) = this.channels.get_mut(&pid) else { return; };
            // A resolved event can finish the original call while this lookup is in flight.
            let Ok(call) = channel.client.take(&id) else { return; };
            let result = result.map_err(|_| error("unknown", "Nanocodex could not confirm this request. Check Terminal before trying again."));
            this.response(io, pid, id, call, result);
        }));
    }
    fn frame(&mut self, io: &mut dyn Io, pid: u32, incoming: rpc::Incoming<Call>) {
        let doc = incoming.document;
        let v = doc.root();
        let tag = string(v, "type");
        if tag.is_empty() {
            if let (Some((id, call)), Ok(rpc::Message::Response { result, .. })) =
                (incoming.call, rpc::Message::read(v))
            {
                self.response(
                    io,
                    pid,
                    id,
                    call,
                    result
                        .map_err(|e| error("native", string(e, "message")))
                        .and_then(|v| document(Data::Value(v))),
                );
            }
            return;
        }
        let Some(c) = self.channels.get_mut(&pid) else {
            return;
        };
        if let Ok(seq) = string(v, "seq").parse::<u64>() {
            c.seq = c.seq.max(seq);
        }
        match tag {
            "hello" => {
                let result = v
                    .get("snapshot")
                    .ok_or_else(|| {
                        error(
                            "protocol",
                            "Nanocodex returned an unsupported control handshake.",
                        )
                    })
                    .and_then(|v| document(Data::Value(v)))
                    .and_then(|d| c.snapshot(d));
                if v.get("protocol_version").and_then(Value::unsigned) == Some(1) && result.is_ok()
                {
                    self.seed(io, pid, 0);
                } else {
                    self.closed(
                        io,
                        pid,
                        "Nanocodex returned an unsupported control handshake.".into(),
                    );
                }
            }
            "request.resolved" => {
                if let (Some(id), Some(receipt)) = (
                    value(v, "data.request_id").and_then(Value::string),
                    value(v, "data.receipt"),
                ) {
                    if let Ok(call) = c.client.take(&rpc::Id::String(id.into())) {
                        self.response(
                            io,
                            pid,
                            rpc::Id::String(id.into()),
                            call,
                            document(Data::Value(receipt)),
                        );
                    }
                }
            }
            "agent.event" if !c.seeding => {
                let Some(data) = v.get("data") else {
                    return;
                };
                let Some(conversation) = c.conversations.get_mut(string(data, "request_id")) else {
                    return;
                };
                conversation.usage.observe(data);
                let kind = string(data, "type");
                let turn = string(data, "payload.turn_id");
                if matches!(
                    kind,
                    "run.started" | "run.completed" | "run.failed" | "model.call.completed"
                ) {
                    if kind == "run.started" {
                        if !conversation.turns.iter().any(|t| t == turn) {
                            conversation.turns.push(turn.into());
                        }
                    } else if kind != "model.call.completed" {
                        conversation.turns.retain(|t| t != turn);
                    }
                    c.changed = true;
                }
                conversation.rows.extend(
                    conversation
                        .projection
                        .live(data, false, None, &digest, &printable),
                );
                if c.flush.is_none() {
                    let at = io.now() + Duration::from_millis(60);
                    io.timer(at);
                    c.flush = Some(at);
                }
                if matches!(kind, "run.started" | "run.completed" | "run.failed")
                    && !flag(c.snapshot.as_ref().unwrap().root(), "capabilities.commands")
                {
                    self.refresh(io, pid, Box::new(|_, _, _| {}));
                }
            }
            "state.changed" | "settings.changed" => {
                if !c.change(v).unwrap_or(false) {
                    self.refresh(io, pid, Box::new(|_, _, _| {}));
                }
            }
            "conversation.active_changed" => self.refresh(io, pid, Box::new(|_, _, _| {})),
            "replay_gap" if !c.seeding => {
                let result = value(v, "data.snapshot")
                    .ok_or_else(|| error("protocol", "Nanocodex could not replay missed events."))
                    .and_then(|v| document(Data::Value(v)))
                    .and_then(|d| c.snapshot(d));
                if result.is_ok() {
                    c.seeding = true;
                    for v in c.conversations.values_mut() {
                        v.projection = records::Projection::new(v.projection.side);
                        v.usage = records::Usage::default();
                    }
                    self.seed(io, pid, 0);
                } else {
                    self.closed(io, pid, "Nanocodex could not replay missed events.".into());
                }
            }
            "history.committed" if string(v, "data.session_id") == c.binding.session => {
                let b = c.binding.clone();
                self.reload(io, b);
            }
            _ => {}
        }
    }
    pub(super) fn request(
        &mut self,
        io: &mut dyn Io,
        pid: u32,
        method: &str,
        params: Value<'_>,
        mutation: bool,
        done: Callback<Json>,
    ) {
        self.serial += 1;
        let mut bytes = [0; 16];
        if let Err(e) = io.random(&mut bytes) {
            done(self, io, Err(error("io", e.to_string())));
            return;
        }
        let name = format!("dispatch-{}-{}", digest(&bytes), self.serial);
        let Some(c) = self.channels.get_mut(&pid) else {
            done(
                self,
                io,
                Err(error(
                    "not_sent",
                    "Nanocodex’s control connection is unavailable.",
                )),
            );
            return;
        };
        let at = io.now() + Duration::from_secs(if mutation { 40 } else { 10 });
        if let Err((call, e)) = c.client.request(
            io,
            rpc::Request {
                id: rpc::Id::String(name),
                method,
                params: Data::Value(params),
                deadline: at,
                value: Call { done, mutation },
            },
            |_, bytes| {
                rpc::Lines::encode(bytes, LIMIT - 1).map_err(|_| {
                    io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "This message is too large for Nanocodex.",
                    )
                })
            },
        ) {
            (call.done)(self, io, Err(error("not_sent", e.to_string())));
        }
    }
    fn ready(&mut self, io: &mut dyn Io, pid: u32, read: bool, write: bool) {
        let c = self.channels.get_mut(&pid).unwrap();
        let fd = c.client.stream.output;
        let result = c.client.event(io, &Event::Ready { fd, read, write });
        match result {
            Ok(received) => {
                for frame in received.data {
                    self.frame(io, pid, frame);
                }
                if received.eof {
                    self.closed(io, pid, "Nanocodex closed its control connection.".into());
                }
            }
            Err(e) => self.closed(io, pid, e.to_string()),
        }
    }
    pub(super) fn closed(&mut self, io: &mut dyn Io, pid: u32, reason: String) {
        let Some(mut c) = self.channels.remove(&pid) else {
            return;
        };
        if let Some(w) = c.watch {
            io.unwatch(w);
        }
        if let Some(done) = c.ready.take() {
            done(io, Err(error("closed", reason.clone())));
        }
        for (_, call) in c.client.close(io) {
            (call.value.done)(
                self,
                io,
                Err(error(
                    if call.progress.written() == 0 {
                        "not_sent"
                    } else {
                        "unknown"
                    },
                    reason.clone(),
                )),
            );
        }
        for wait in c.waits {
            (wait.done)(self, io, Err(error("unknown", reason.clone())));
        }
    }
    fn reload(&mut self, io: &mut dyn Io, binding: Binding) {
        let pid = binding.process.pid;
        let session = binding.session.clone();
        self.page(
            io,
            binding,
            None,
            Box::new(move |this, _, result| {
                if let Ok(page) = result
                    && let Some(c) = this.channels.get_mut(&pid)
                {
                    if let Some(v) = c.conversations.get_mut(&session) {
                        v.rows.extend(page.records);
                    }
                    c.changed = true;
                }
            }),
        );
    }
    pub(super) fn handle(&mut self, io: &mut dyn Io, ui: &mut dyn Ui, event: Event) {
        match event {
            Event::Done { work, result } => {
                if let Some(done) = self.jobs.remove(&work) {
                    done(self, io, result.map_err(|e| error("io", e.to_string())));
                }
            }
            Event::Ready { fd, read, write } => {
                if let Some((_, find)) = self.connecting.remove(&fd) {
                    self.scan(io, find, Ok(Output::Written));
                } else if let Some(pid) = self
                    .channels
                    .iter()
                    .find_map(|(pid, c)| (c.client.stream.output == fd).then_some(*pid))
                {
                    self.ready(io, pid, read, write);
                }
            }
            Event::Timer { at } => {
                let fds: Vec<_> = self
                    .connecting
                    .iter()
                    .filter_map(|(fd, (t, _))| (at >= *t).then_some(*fd))
                    .collect();
                for fd in fds {
                    if let Some((_, f)) = self.connecting.remove(&fd) {
                        io.close(fd);
                        (f.done)(
                            io,
                            Err(error(
                                "deadline",
                                "Could not connect to Nanocodex’s control socket.",
                            )),
                        );
                    }
                }
                let mut confirmations = Vec::new();
                for (pid, channel) in &mut self.channels {
                    for (id, next) in &mut channel.confirmations {
                        if next.is_some_and(|next| next <= io.now()) {
                            *next = None;
                            confirmations.push((*pid, id.clone()));
                        }
                    }
                }
                for (pid, id) in confirmations {
                    self.confirm(io, pid, id);
                }
                let pids: Vec<_> = self
                    .channels
                    .iter_mut()
                    .filter_map(|(pid, c)| {
                        let expired = c.client.expired(io.now());
                        (c.ready.is_some() && at >= c.hello || !expired.is_empty())
                            .then_some((*pid, expired))
                    })
                    .collect();
                for (pid, expired) in pids {
                    self.closed(io, pid, "Nanocodex did not answer in time.".into());
                    for (_, call) in expired {
                        (call.value.done)(
                            self,
                            io,
                            Err(error(
                                if call.progress.written() == 0 {
                                    "not_sent"
                                } else {
                                    "unknown"
                                },
                                "Nanocodex did not answer in time.",
                            )),
                        );
                    }
                }
            }
            Event::Changed { watch, .. } => {
                if let Some(b) = self
                    .channels
                    .values()
                    .find(|c| c.watch == Some(watch))
                    .map(|c| c.binding.clone())
                {
                    self.reload(io, b);
                }
            }
            _ => {}
        }
        let mut completed = vec![];
        for c in self.channels.values_mut() {
            for v in c.conversations.values_mut() {
                if ui.terminal(&v.binding).is_some() {
                    v.attached = true;
                    if c.changed || c.flush.is_some_and(|t| io.now() >= t) {
                        if !v.rows.is_empty() {
                            ui.update(Update::Records {
                                binding: v.binding.clone(),
                                records: std::mem::take(&mut v.rows),
                            });
                        }
                    }
                    if c.changed && c.snapshot.is_some() {
                        ui.update(Update::State {
                            binding: v.binding.clone(),
                            state: observed(c.snapshot.as_ref().unwrap().root(), v),
                        });
                    }
                } else if v.attached {
                    v.rows.clear();
                }
            }
            if c.flush.is_some_and(|t| io.now() >= t) {
                c.flush = None;
            }
            c.changed = false;
            let mut waiting = vec![];
            for wait in std::mem::take(&mut c.waits) {
                if let Some(result) = (wait.probe)(c) {
                    completed.push((wait.done, result));
                } else if io.now() >= wait.at {
                    completed.push((
                        wait.done,
                        Err(error(
                            "unknown",
                            "Nanocodex did not confirm the conversation change.",
                        )),
                    ));
                } else {
                    waiting.push(wait);
                }
            }
            c.waits = waiting;
        }
        for (done, result) in completed {
            done(self, io, result);
        }
    }
}
