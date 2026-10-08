use super::*;

impl Saved {
    pub(super) fn cursor(&self, session: &str) -> Result<String, Error> {
        let metadata = self.grown.metadata;
        let bytes = |values: &[u8]| {
            Data::Array(
                values
                    .iter()
                    .map(|byte| Data::Unsigned(u64::from(*byte)))
                    .collect(),
            )
        };
        let modified = metadata.modified_ns.to_string();
        let changed = metadata.changed_ns.to_string();
        let path = digest(self.path.as_os_str().as_encoded_bytes());
        let data = Data::Object(vec![
            ("session", Data::String(session)),
            ("path", Data::String(&path)),
            ("device", Data::Unsigned(metadata.device)),
            ("inode", Data::Unsigned(metadata.inode)),
            ("size", Data::Unsigned(metadata.size)),
            ("modified", Data::String(&modified)),
            ("changed", Data::String(&changed)),
            ("prefix", bytes(&self.grown.prefix)),
            ("tail", bytes(&self.grown.tail)),
            ("generation", Data::String(&self.generation)),
            ("offset", Data::Unsigned(self.offset)),
            ("turn", Data::String(self.turn.as_deref().unwrap_or(""))),
            ("model", Data::String(self.model.as_deref().unwrap_or(""))),
            ("effort", Data::String(self.effort.as_deref().unwrap_or(""))),
        ]);
        String::from_utf8(json::write(&data)?)
            .map_err(|_| error("changed", "Invalid transcript cursor"))
    }

    pub(super) fn resume(source: &Transcript) -> Result<Option<Self>, Error> {
        let Some(cursor) = source.later.as_deref().filter(|cursor| !cursor.is_empty()) else {
            return Ok(None);
        };
        let doc = Json::parse(cursor.as_bytes())?;
        let root = doc.root();
        if string(root, "session") != source.session
            || string(root, "path") != digest(source.path.as_os_str().as_encoded_bytes())
        {
            return Err(error(
                "changed",
                "Transcript cursor belongs to a different archive",
            ));
        }
        let unsigned = |key: &str| {
            root.get(key)
                .and_then(Value::unsigned)
                .ok_or_else(|| error("changed", "Invalid transcript cursor"))
        };
        let time = |key: &str| {
            string(root, key)
                .parse::<i128>()
                .map_err(|_| error("changed", "Invalid transcript cursor"))
        };
        let bytes = |key: &str| -> Result<Vec<u8>, Error> {
            let values = root
                .get(key)
                .and_then(Value::array)
                .ok_or_else(|| error("changed", "Invalid transcript cursor"))?;
            let bytes = values
                .map(|value| {
                    value
                        .unsigned()
                        .and_then(|n| u8::try_from(n).ok())
                        .ok_or_else(|| error("changed", "Invalid transcript cursor"))
                })
                .collect::<Result<Vec<_>, _>>()?;
            if bytes.len() > 256 {
                return Err(error("changed", "Invalid transcript cursor"));
            }
            Ok(bytes)
        };
        let optional = |key: &str| {
            root.get(key)
                .and_then(Value::string)
                .filter(|value| !value.is_empty())
                .map(str::to_owned)
        };
        let size = unsigned("size")?;
        let offset = unsigned("offset")?;
        let tail = bytes("tail")?;
        if offset > size || tail.len() as u64 > size {
            return Err(error("changed", "Invalid transcript cursor"));
        }
        Ok(Some(Self {
            path: source.path.clone(),
            grown: Grown {
                metadata: Metadata {
                    kind: FileKind::File,
                    size,
                    device: unsigned("device")?,
                    inode: unsigned("inode")?,
                    modified_ns: time("modified")?,
                    changed_ns: time("changed")?,
                },
                prefix: bytes("prefix")?,
                tail,
            },
            generation: string(root, "generation").to_owned(),
            offset,
            turn: optional("turn"),
            model: optional("model"),
            effort: optional("effort"),
        }))
    }
}
