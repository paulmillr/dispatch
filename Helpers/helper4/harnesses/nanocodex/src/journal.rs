//! Expand the native disk journal's inline and chunked record descriptors.
use super::*;

#[derive(Default)]
pub struct Chunks {
    pub offset: u64,
    bytes: Vec<u8>,
    record: Option<(String, u64)>,
}
impl Chunks {
    /// Append one native history.pending.read reply without altering its bytes.
    pub fn append(&mut self, value: Value<'_>) -> Result<Option<Json>, Error> {
        let result = (|| {
            if string(value, "status") == "rejected" {
                return Err(error("native", string(value, "code")));
            }
            let bytes = value
                .get("bytes")
                .and_then(Value::array)
                .and_then(|bytes| {
                    bytes
                        .map(|v| v.unsigned().and_then(|v| u8::try_from(v).ok()))
                        .collect::<Option<Vec<_>>>()
                })
                .ok_or_else(|| error("protocol", "Invalid Nanocodex journal bytes."))?;
            let next = string(value, "next_offset").parse::<u64>().ok();
            let total = string(value, "total_bytes").parse::<u64>().ok();
            let more = value.get("has_more").and_then(Value::boolean);
            let id = string(value, "record_id");
            if next != self.offset.checked_add(bytes.len() as u64)
                || self.offset != self.bytes.len() as u64
                || total.is_none()
                || more.is_none()
                || id.is_empty()
                || next > total
                || more != Some(next < total)
                || (more == Some(true) && bytes.is_empty())
                || self
                    .record
                    .as_ref()
                    .is_some_and(|(record, size)| record != id || Some(*size) != total)
            {
                return Err(error("protocol", "Invalid Nanocodex journal chunk."));
            }
            self.bytes
                .try_reserve(bytes.len())
                .map_err(|_| error("protocol", "Nanocodex journal exceeds available memory."))?;
            self.bytes.extend(bytes);
            if more == Some(true) {
                self.offset = next.unwrap();
                self.record = Some((id.to_owned(), total.unwrap()));
                Ok(None)
            } else {
                Json::parse(&self.bytes).map(Some)
            }
        })();
        if !matches!(result, Ok(None)) {
            self.bytes.clear();
            self.offset = 0;
            self.record = None;
        }
        result
    }
}

struct Read {
    pid: u32,
    page: Json,
    records: Vec<Json>,
    values: Vec<Json>,
    index: usize,
    chunks: Chunks,
    done: Callback<(Json, Vec<Json>)>,
}

impl Nano {
    pub(super) fn pending(
        &mut self,
        io: &mut dyn Io,
        pid: u32,
        params: Json,
        done: Callback<(Json, Vec<Json>)>,
    ) {
        self.request(
            io,
            pid,
            "history.pending",
            params.root(),
            false,
            Box::new(move |this, io, result| {
                let result = result.and_then(|page| {
                    if string(page.root(), "status") == "rejected" {
                        return Err(error("native", string(page.root(), "code")));
                    }
                    let records = page
                        .root()
                        .get("records")
                        .and_then(Value::array)
                        .ok_or_else(|| error("protocol", "Invalid Nanocodex journal history."))?
                        .map(|v| document(Data::Value(v)))
                        .collect::<Result<Vec<_>, Error>>()?;
                    Ok((page, records))
                });
                match result {
                    Ok((page, records)) => this.read_pending(
                        io,
                        Read {
                            pid,
                            page,
                            records,
                            values: vec![],
                            index: 0,
                            chunks: Chunks::default(),
                            done,
                        },
                    ),
                    Err(e) => done(this, io, Err(e)),
                }
            }),
        );
    }

    fn read_pending(&mut self, io: &mut dyn Io, mut read: Read) {
        for index in read.index..read.records.len() {
            let record = read.records[index].root();
            if let Some(value) = record.get("value") {
                match document(Data::Value(value)) {
                    Ok(value) => read.values.push(value),
                    Err(e) => {
                        (read.done)(self, io, Err(e));
                        return;
                    }
                }
                read.index += 1;
                continue;
            }
            let params = document(Data::Object(vec![
                (
                    "boundary",
                    Data::String(string(read.page.root(), "boundary")),
                ),
                ("record_id", Data::String(string(record, "record_id"))),
                ("offset", Data::Unsigned(read.chunks.offset)),
            ]))
            .unwrap();
            self.request(
                io,
                read.pid,
                "history.pending.read",
                params.root(),
                false,
                Box::new(move |this, io, result| {
                    let result = result.and_then(|part| {
                        if let Some(record) = read.chunks.append(part.root())? {
                            read.values.push(record);
                            read.index += 1;
                        }
                        Ok(())
                    });
                    match result {
                        Ok(()) => this.read_pending(io, read),
                        Err(e) => (read.done)(this, io, Err(e)),
                    }
                }),
            );
            return;
        }
        (read.done)(self, io, Ok((read.page, read.values)));
    }
}
