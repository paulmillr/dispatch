//! Native id correlation and caller deadlines over the shared Stream. Authentication,
//! native receipts/errors and the decision to close on expiry stay with the harness.
use super::{
    Error, Id, Message, Pending,
    transport::{Codec, Progress, Stream},
};
use crate::{
    api::{Event, Io},
    json::{self, Data, Json},
};
use std::{io, time::Instant};

pub struct Request<'a, T> {
    pub id: Id,
    pub method: &'a str,
    pub params: Data<'a>,
    pub deadline: Instant,
    pub value: T,
}
#[derive(Debug)]
pub struct Call<T> {
    pub value: T,
    pub deadline: Instant,
    pub progress: Progress,
}
pub struct Incoming<T> {
    /// Unchanged full native document, including errors and unknown fields.
    pub document: Json,
    /// Only a matching response takes a call; server requests never consume outgoing IDs.
    pub call: Option<(Id, Call<T>)>,
}
pub struct Received<T> {
    pub data: Vec<Incoming<T>>,
    pub eof: bool,
}
pub struct Client<C, T> {
    /// Owners also use this for auth, notifications and replies to native server requests.
    pub stream: Stream<C>,
    pending: Pending<Call<T>>,
}
impl<C: Codec, T> Client<C, T> {
    pub fn new(stream: Stream<C>, capacity: usize, ids: usize) -> Self {
        Self {
            stream,
            pending: Pending::new(capacity, ids),
        }
    }
    /// IDs must remain unique for this connection, including after timeout. The encoder
    /// adds native LF/WebSocket framing through Io; admission failure returns the context.
    pub fn request(
        &mut self,
        io: &mut dyn Io,
        request: Request<'_, T>,
        encode: impl FnOnce(&mut dyn Io, Vec<u8>) -> io::Result<Vec<u8>>,
    ) -> Result<(), (T, io::Error)> {
        if request.deadline <= io.now() {
            return Err((request.value, io::ErrorKind::TimedOut.into()));
        }
        let id = request.id;
        let progress = Progress::default();
        let call = Call {
            value: request.value,
            deadline: request.deadline,
            progress: progress.clone(),
        };
        self.pending
            .try_insert(id.clone(), call)
            .map_err(|(error, call)| {
                (
                    call.value,
                    io::Error::new(
                        io::ErrorKind::InvalidInput,
                        format!("native pending: {error:?}"),
                    ),
                )
            })?;
        let result = (|| {
            let bytes = json::write(&Data::Object(vec![
                (
                    "id",
                    match &id {
                        Id::Integer(v) => Data::Signed(*v),
                        Id::String(v) => Data::String(v),
                    },
                ),
                ("method", Data::String(request.method)),
                ("params", request.params),
            ]))
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e.message))?;
            let document = Json::parse(&bytes)
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e.message))?;
            Message::read(document.root()).map_err(|e| {
                io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("native request: {e:?}"),
                )
            })?;
            let bytes = encode(io, bytes)?;
            self.stream.send_tracked(io, bytes, None, None, progress)?;
            io.timer(request.deadline);
            Ok(())
        })();
        result.map_err(|e| (self.pending.take(&id).unwrap().value, e))
    }
    /// Native pending receipts can put the same context back with a new deadline. There is
    /// no retransmission; resolve a later native event with take(original_id).
    pub fn wait(&mut self, io: &mut dyn Io, id: Id, call: Call<T>) -> Result<(), (Error, Call<T>)> {
        let at = call.deadline;
        self.pending.try_insert(id, call)?;
        io.timer(at);
        Ok(())
    }
    pub fn take(&mut self, id: &Id) -> Result<Call<T>, Error> {
        self.pending.take(id)
    }
    pub fn expired(&mut self, now: Instant) -> Vec<(Id, Call<T>)> {
        let ids: Vec<_> = self
            .pending
            .iter()
            .filter(|(_, call)| call.deadline <= now)
            .map(|(id, _)| id.clone())
            .collect();
        ids.into_iter()
            .map(|id| {
                let call = self.pending.take(&id).unwrap();
                (id, call)
            })
            .collect()
    }
    /// Complete JSON-object documents. A frame that is anything else ends the stream (eof)
    /// after the frames before it; c51466a nanocodex.rs:327-329.
    /// The owner handles non-RPC hello/events and native "pending" results without guessing.
    pub fn event(&mut self, io: &mut dyn Io, event: &Event) -> io::Result<Received<T>> {
        let received = self.stream.event(io, event)?;
        let mut data = Vec::new();
        for bytes in received.data {
            let Some(document) = Json::parse(&bytes).ok().filter(|d| d.root().object().is_some())
            else {
                return Ok(Received { data, eof: true });
            };
            let call = if let Ok(Message::Response { id, .. }) = Message::read(document.root()) {
                self.take(&id).ok().map(|call| (id, call))
            } else {
                None
            };
            data.push(Incoming { document, call });
        }
        Ok(Received {
            data,
            eof: received.eof,
        })
    }
    /// Drain once. Exact per-packet written counts remain available even when Stream's
    /// deferred write-completion callbacks have not run yet; never resend these calls.
    pub fn close(&mut self, io: &mut dyn Io) -> Vec<(Id, Call<T>)> {
        self.stream.close(io);
        self.pending.drain().collect()
    }
}
