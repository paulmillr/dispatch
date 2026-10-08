//! One alias table per capture; discovery never edits data or structural wire bytes.
use super::*;

const BASE: i128 = 1_009_843_200; // User-selected 2002-01-01, ten-digit epoch seconds.

#[derive(Default)]
struct Policy {
    rules: BTreeMap<String, String>,
    times: std::collections::BTreeSet<(String, String, i128, i128)>,
    first: Option<i128>,
    dates: std::collections::BTreeSet<(String, i128)>,
    binary: std::collections::BTreeSet<String>,
    mac: bool,
    literals: Vec<String>,
}

fn mask(value: &str) -> String {
    value
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() {
                'x'
            } else if c.is_alphanumeric() {
                match c.len_utf8() {
                    2 => '×',
                    3 => '□',
                    _ => '🞅',
                }
            } else {
                c
            }
        })
        .collect()
}

impl Policy {
    fn add(&mut self, from: String, to: String) -> io::Result<()> {
        if from == to {
            return Ok(());
        }
        if from.len() != to.len() {
            return Err(failure("discovered alias changes width"));
        }
        if self
            .rules
            .insert(from, to.clone())
            .is_some_and(|old| old != to)
        {
            return Err(failure("discovered aliases conflict"));
        }
        Ok(())
    }

    fn string(&mut self, key: Option<&str>, value: &str) -> io::Result<()> {
        for needle in self.literals.clone() {
            if value.contains(&needle) {
                self.add(needle.clone(), mask(&needle))?;
            }
        }
        // Preserve the basename and public directory structure, including .git/modules.
        for prefix in [
            "/home/",
            "/Users/",
            "/var/folders/",
            "/private/var/folders/",
        ] {
            for (at, _) in value.match_indices(prefix) {
                let tail = &value[at + prefix.len()..];
                let count = if prefix.contains("folders") { 2 } else { 1 };
                let mut end = at + prefix.len();
                for part in tail.split('/').take(count) {
                    let part = part
                        .split(|c: char| !(c.is_alphanumeric() || "._-".contains(c)))
                        .next()
                        .unwrap_or("");
                    end += part.len() + 1;
                }
                let end = end.saturating_sub(1).min(value.len());
                let from = &value[at..end];
                if from != prefix {
                    self.add(from.to_owned(), mask(from))?;
                }
            }
        }
        if value.starts_with("/Users/") || matches!(value, "Darwin" | "darwin" | "macos") {
            self.mac = true;
        }
        if let Some(time) =
            crate::date::parse(value).or_else(|| rfc(value).map(|second| second * 1000))
        {
            let second = time as i128 / 1000;
            if second > BASE {
                self.first = Some(self.first.map_or(second, |old| old.min(second)));
                self.dates.insert((value.to_owned(), second));
            }
        }
        let key = key
            .unwrap_or("")
            .replace(['_', '-'], "")
            .to_ascii_lowercase();
        let personal = matches!(
            key.as_str(),
            "hostname"
                | "host"
                | "accountid"
                | "userid"
                | "organizationid"
                | "orgid"
                | "installationid"
                | "deviceid"
                | "machineid"
                | "bootid"
                | "hostid"
                | "ioplatformuuid"
                | "platformuuid"
                | "hardwareuuid"
                | "serialnumber"
                | "macaddress"
                | "volumeuuid"
                | "diskuuid"
                | "kernelversion"
                | "kernelfingerprint"
                | "analyticsid"
                | "telemetryid"
                | "stableid"
                | "fingerprint"
                | "hostkey"
        );
        let secret = matches!(
            key.as_str(),
            "token"
                | "apikey"
                | "accesskey"
                | "authorization"
                | "password"
                | "cookie"
                | "secret"
                | "credential"
                | "accesstoken"
                | "refreshtoken"
        );
        if (personal || secret)
            && !value.is_empty()
            && !value.chars().all(|c| !c.is_alphanumeric() || c == 'x')
        {
            let compact = value.replace('-', "");
            let alias = if compact.len() == 32 && compact.bytes().all(|b| b.is_ascii_hexdigit()) {
                if compact
                    .to_ascii_lowercase()
                    .starts_with("00000000000040008000")
                {
                    return Ok(());
                }
                let mut hash = crate::hash::Sha256::new();
                hash.update(compact.to_ascii_lowercase().as_bytes());
                let digits = format!(
                    "00000000000040008000{}",
                    &capture::hex(&hash.finish())[..12]
                );
                if value.len() == 36 {
                    format!(
                        "{}-{}-{}-{}-{}",
                        &digits[..8],
                        &digits[8..12],
                        &digits[12..16],
                        &digits[16..20],
                        &digits[20..]
                    )
                } else {
                    digits
                }
            } else {
                mask(value)
            };
            self.add(value.to_owned(), alias)?;
        }
        if let Some(domain) = value.strip_prefix("linux:") {
            let id = domain.split(':').next().unwrap_or("");
            if id.bytes().all(|b| b.is_ascii_hexdigit())
                && !id.is_empty()
                && !id.bytes().all(|b| b == b'0')
            {
                let compact = id.replace('-', "").to_ascii_lowercase();
                if compact.len() == 32 && compact.starts_with("00000000000040008000") {
                    return Ok(());
                }
                let mut hash = crate::hash::Sha256::new();
                hash.update(compact.as_bytes());
                let alias = if id.len() == 32 {
                    format!(
                        "00000000000040008000{}",
                        &capture::hex(&hash.finish())[..12]
                    )
                } else {
                    "0".repeat(id.len())
                };
                self.add(id.to_owned(), alias)?;
            }
        }
        // Email, private network endpoint and SSH fingerprints are native text as well as fields.
        for token in value.split(|c: char| c.is_whitespace() || "\"'<>(),;".contains(c)) {
            if let Some((_, domain)) = token.rsplit_once('@') {
                if domain.contains('.')
                    && !domain.ends_with(".test")
                    && token != "noreply@anthropic.com"
                {
                    self.add(token.to_owned(), mask(token))?;
                }
            }
            if token.starts_with("SHA256:") && token.len() > 7 {
                self.add(token[7..].to_owned(), mask(&token[7..]))?;
            }
        }
        Ok(())
    }

    fn scalar(&mut self, key: Option<&str>, value: Value<'_>) -> io::Result<()> {
        if let Some(text) = value.string() {
            self.string(key, text)?;
            self.collect(text.as_bytes(), 1)?;
        }
        let Some(key) = key else {
            return Ok(());
        };
        let name = key.replace(['_', '-'], "").to_ascii_lowercase();
        let old = value.string().map(str::to_owned).or_else(|| {
            value
                .number()
                .and_then(|_| value.write().ok())
                .and_then(|bytes| String::from_utf8(bytes).ok())
        });
        if let Some(old) = old {
            if let Ok(number) = old.split('.').next().unwrap_or("").parse::<i128>() {
                if matches!(name.as_str(), "uid" | "owneruid" | "accountuid")
                    && (number >= 1000 || self.mac && number >= 500)
                {
                    let mapped = if self.mac { 501 } else { 1000 };
                    let quoted = value.string().is_some();
                    let from = format!(
                        "\"{key}\":{}",
                        if quoted {
                            format!("\"{old}\"")
                        } else {
                            old.clone()
                        }
                    );
                    let alias = if quoted {
                        format!("\"{:0width$}\"", mapped, width = old.len())
                    } else {
                        format!("{:>width$}", mapped, width = old.len())
                    };
                    self.add(from, format!("\"{key}\":{alias}"))?;
                    for harness in ["claude", "codex", "pi", "nanocodex"] {
                        self.add(
                            format!("{harness}-{old}"),
                            format!("{harness}-{:0width$}", mapped, width = old.len()),
                        )?;
                    }
                }
                if matches!(
                    name.as_str(),
                    "device" | "inode" | "dev" | "ino" | "deviceid" | "hostid"
                ) && number >= 1000
                    && !old.starts_with("100")
                {
                    let mut hash = crate::hash::Sha256::new();
                    hash.update(old.as_bytes());
                    let digits = hash.finish();
                    let alias = format!(
                        "100{}",
                        (0..old.len() - 3)
                            .map(|n| (b'0' + digits[n % digits.len()] % 10) as char)
                            .collect::<String>()
                    );
                    self.add(format!("\"{key}\":{old}"), format!("\"{key}\":{alias}"))?;
                    self.add(
                        format!("\"{key}\":\"{old}\""),
                        format!("\"{key}\":\"{alias}\""),
                    )?;
                }
                if name != "clock"
                    && (name.contains("time")
                        || name.contains("started")
                        || name.contains("modified")
                        || name.contains("changed")
                        || matches!(name.as_str(), "mtime" | "ctime" | "birth" | "timestamp")
                        || name == "start" && self.mac)
                {
                    let scale = if name.ends_with("ns") {
                        1_000_000_000
                    } else if name.ends_with("us") {
                        1_000_000
                    } else if name.ends_with("ms") {
                        1000
                    } else {
                        [1, 1000, 1_000_000, 1_000_000_000]
                            .into_iter()
                            .find(|scale| (BASE..4_102_444_800).contains(&(number / scale)))
                            .unwrap_or(1)
                    };
                    let second = number / scale;
                    if (BASE..4_102_444_800).contains(&second) {
                        self.first = Some(self.first.map_or(second, |old| old.min(second)));
                        self.times.insert((key.to_owned(), old, number, scale));
                    }
                }
            }
        }
        Ok(())
    }

    fn collect(&mut self, bytes: &[u8], depth: usize) -> io::Result<()> {
        if depth > crate::wire::body::DEPTH {
            return Err(failure("private data nesting exceeds codec bound"));
        }
        if let Some(header) = bytes.get(..13).and_then(|raw| {
            crate::wire::Header::decode(raw.try_into().ok()?, crate::wire::LIMIT).ok()
        }) {
            let end = 13 + header.len as usize;
            if end <= bytes.len()
                && !matches!(
                    header.kind,
                    crate::wire::Kind::Chunk | crate::wire::Kind::Cancel
                )
            {
                let document = crate::wire::body::decode(&bytes[13..end])
                    .map_err(|_| failure("encoded capture uses an unknown codec"))?;
                scalars(document.root(), None, &mut |key, value| {
                    self.scalar(key, value)
                })?;
                if end < bytes.len() {
                    self.collect(&bytes[end..], depth + 1)?;
                }
            }
            return Ok(());
        }
        if let Ok(document) = Json::parse(bytes) {
            return scalars(document.root(), None, &mut |key, value| {
                self.scalar(key, value)
            });
        }
        if bytes.contains(&b'\n') {
            for line in bytes.split(|b| *b == b'\n') {
                if let Ok(document) = Json::parse(line) {
                    scalars(document.root(), None, &mut |key, value| {
                        self.scalar(key, value)
                    })?;
                } else if let Ok(text) = std::str::from_utf8(line) {
                    self.string(None, text)?;
                }
            }
            return Ok(());
        }
        let Ok(text) = std::str::from_utf8(bytes) else {
            return Ok(());
        };
        if bytes.len() >= 2 && bytes.len() % 2 == 0 && bytes.iter().all(u8::is_ascii_hexdigit) {
            return self.collect(&capture::unhex(text)?, depth + 1);
        }
        let string =
            crate::json::write(&crate::json::Data::String(text)).map_err(|_| file::invalid())?;
        let document = Json::parse(&string).map_err(|_| file::invalid())?;
        if let Ok(decoded) = crate::base64::decode(document.root()) {
            if !decoded.is_empty() && crate::base64::encode(&decoded) == text {
                return self.collect(&decoded, depth + 1);
            }
        }
        self.string(None, text)?;
        Ok(())
    }
}

impl Redactor {
    /// Discover machine/account literals in a real trace. The private literal list is optional.
    /// Only the current production codec is accepted; no schema snapshots or raw binary masks.
    pub fn capture(source: &Path, literals: &[String], budget: usize) -> io::Result<Self> {
        let mut policy = Policy {
            literals: literals.to_vec(),
            ..Policy::default()
        };
        let mut streams: BTreeMap<String, Vec<u8>> = BTreeMap::new();
        let mut chunks: BTreeMap<String, crate::wire::Collector> = BTreeMap::new();
        for line in BufReader::new(file::open(source)?).lines() {
            let line = line?;
            if line.len() > budget {
                return Err(failure("capture row exceeds scrub budget"));
            }
            let document = Json::parse(line.as_bytes()).map_err(|_| file::invalid())?;
            let row = document.root();
            if row.get("section").and_then(Value::string) == Some("startup")
                && row.get("op").and_then(Value::string) == Some("context")
            {
                return Err(failure(
                    "launch context contains a private environment; scrub requires a reviewed context policy",
                ));
            }
            policy.collect(line.as_bytes(), 0)?;
            let retained: usize = policy
                .rules
                .iter()
                .map(|(a, b)| a.len() + b.len())
                .sum::<usize>()
                + policy
                    .times
                    .iter()
                    .map(|(a, b, _, _)| a.len() + b.len() + 64)
                    .sum::<usize>()
                + policy
                    .dates
                    .iter()
                    .map(|(a, _)| a.len() + 32)
                    .sum::<usize>();
            if retained > budget {
                return Err(failure("private alias discovery exceeds scrub budget"));
            }

            let section = row
                .get("section")
                .and_then(Value::string)
                .ok_or_else(file::invalid)?;
            let op = row
                .get("op")
                .and_then(Value::string)
                .ok_or_else(file::invalid)?;
            let args = row
                .get("args")
                .and_then(Value::string)
                .ok_or_else(file::invalid)?;
            let data = capture::unhex(
                row.get("data")
                    .and_then(Value::string)
                    .ok_or_else(file::invalid)?,
            )?;
            let completion = Json::parse(&data).map_err(|_| file::invalid())?;
            let payload = completion
                .root()
                .get("output")
                .and_then(|v| v.get("bytes"))
                .and_then(Value::string);
            if section == "ui" && op == "random" && args == "16" {
                if let Some(payload) = payload {
                    let bytes = capture::unhex(payload)?;
                    if bytes.len() == 16 && !bytes.starts_with(b"fixture-") {
                        let mut hash = crate::hash::Sha256::new();
                        hash.update(&bytes);
                        let mut alias = b"fixture-".to_vec();
                        alias.extend_from_slice(&hash.finish()[..8]);
                        policy.add(payload.to_owned(), capture::hex(&alias))?;
                        policy.binary.insert(payload.to_owned());
                    }
                }
            }
            if section == "startup" && op == "account" {
                if let Some(payload) = payload {
                    let bytes = capture::unhex(payload)?;
                    let uid = u32::from_le_bytes(
                        bytes
                            .get(..4)
                            .ok_or_else(file::invalid)?
                            .try_into()
                            .map_err(|_| file::invalid())?,
                    );
                    let text = format!("{{\"uid\":{uid}}}");
                    policy.collect(text.as_bytes(), 0)?;
                    if let Ok(home) = std::str::from_utf8(&bytes[4..]) {
                        policy.string(Some("home"), home)?;
                    }
                }
            }
            if section != "ui" || !matches!(op, "read" | "write") {
                continue;
            }
            let Some(payload) = payload else {
                continue;
            };
            let bytes = if op == "write" && !args.contains(" len=") {
                capture::unhex(args.split_once(' ').ok_or_else(file::invalid)?.1)?
            } else {
                capture::unhex(payload)?
            };
            let fd = args.split_whitespace().next().ok_or_else(file::invalid)?;
            let stream = streams.entry(format!("{op} {fd}")).or_default();
            stream.extend(bytes);
            let mut at = 0;
            for _ in 0..stream.len() {
                let Some(header) = stream.get(at..at + 13) else {
                    break;
                };
                let header =
                    crate::wire::Header::decode(header.try_into().unwrap(), crate::wire::LIMIT)
                        .map_err(|_| file::invalid())?;
                let end = at + 13 + header.len as usize;
                if end > stream.len() {
                    break;
                }
                let identity = format!("{op} {fd} {}", header.id);
                if header.kind == crate::wire::Kind::Chunk || chunks.contains_key(&identity) {
                    let collector = chunks
                        .entry(identity.clone())
                        .or_insert_with(|| crate::wire::Collector::new(header.id, budget));
                    if let Some(value) = collector
                        .push(header, &stream[at + 13..end])
                        .map_err(|_| file::invalid())?
                    {
                        match value {
                            crate::wire::Received::Json(bytes) => policy.collect(&bytes, 0)?,
                            crate::wire::Received::Binary { bytes, metadata } => {
                                policy.collect(&bytes, 0)?;
                                scalars(metadata.root(), None, &mut |key, value| {
                                    policy.scalar(key, value)
                                })?;
                            }
                        }
                        chunks.remove(&identity);
                    }
                } else if header.kind != crate::wire::Kind::Cancel {
                    let document = crate::wire::body::decode(&stream[at + 13..end])
                        .map_err(|_| failure("capture does not use current helper codec"))?;
                    scalars(document.root(), None, &mut |key, value| {
                        policy.scalar(key, value)
                    })?;
                }
                at = end;
            }
            stream.drain(..at);
            if streams.values().map(Vec::len).sum::<usize>() > budget {
                return Err(failure("capture streams exceed scrub budget"));
            }
        }
        if !chunks.is_empty() || streams.values().any(|bytes| !bytes.is_empty()) {
            return Err(failure("capture has unfinished UI frames"));
        }
        if let Some(first) = policy.first {
            for (key, old, value, scale) in std::mem::take(&mut policy.times) {
                let mut new = (value + (BASE - first) * scale).to_string();
                if let Some((_, fraction)) = old.split_once('.') {
                    new.push('.');
                    new.push_str(fraction);
                }
                policy.add(
                    format!("\"{key}\":{old}"),
                    format!("\"{key}\":{new:>width$}", width = old.len()),
                )?;
                policy.add(
                    format!("\"{key}\":\"{old}\""),
                    format!("\"{key}\":\"{new:0>width$}\"", width = old.len()),
                )?;
            }
        }
        if let Some(first) = policy.first {
            for (old, _) in std::mem::take(&mut policy.dates) {
                let alias = if let Some(seconds) = rfc(&old) {
                    let iso = utc(seconds + (BASE - first) as i64);
                    let day = iso[8..10].parse::<u32>().map_err(|_| file::invalid())?;
                    let month = iso[5..7].parse::<usize>().map_err(|_| file::invalid())?;
                    let weekday = (seconds + (BASE - first) as i64)
                        .div_euclid(86400)
                        .rem_euclid(7);
                    let weekday =
                        ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"][weekday as usize];
                    let month = [
                        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct",
                        "Nov", "Dec",
                    ][month - 1];
                    let padding = old.as_bytes().get(8) == Some(&b' ');
                    format!(
                        "{weekday} {month} {} {} {}",
                        if padding {
                            format!("{day:>2}")
                        } else {
                            day.to_string()
                        },
                        &iso[11..19],
                        &iso[..4]
                    )
                } else {
                    let local = crate::date::parse(&format!("{}Z", &old[..19]))
                        .ok_or_else(file::invalid)?
                        / 1000;
                    format!("{}{}", utc(local + (BASE - first) as i64), &old[19..])
                };
                policy.add(old, alias)?;
            }
        }
        let rules: Vec<_> = policy
            .rules
            .iter()
            .map(|(from, to)| Rule {
                from,
                to,
                binary: policy.binary.contains(from),
            })
            .collect();
        Self::new(&rules, budget)
    }
}

fn utc(seconds: i64) -> String {
    let days = seconds.div_euclid(86400);
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let year = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = mp + if mp < 10 { 3 } else { -9 };
    let year = year + i64::from(month <= 2);
    let clock = seconds.rem_euclid(86400);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}",
        clock / 3600,
        clock / 60 % 60,
        clock % 60
    )
}

fn rfc(value: &str) -> Option<i64> {
    let parts: Vec<_> = value.split_whitespace().collect();
    if parts.len() != 5 || parts[0].len() != 3 || parts[3].len() != 8 || parts[4].len() != 4 {
        return None;
    }
    let month = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]
    .iter()
    .position(|month| *month == parts[1])?
        + 1;
    let day = parts[2].parse::<u32>().ok()?;
    crate::date::parse(&format!("{}-{month:02}-{day:02}T{}Z", parts[4], parts[3]))
        .map(|millis| millis / 1000)
}
