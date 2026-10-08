/// Native four-digit-year ISO-8601 timestamps, in epoch milliseconds.
/// Calendar overflow and conversion through Foundation's 2001 epoch preserve
/// c1654cc TranscriptReader.date. Record fallback policy belongs to the caller.
pub fn parse(value: &str) -> Option<i64> {
    let value = value.trim_start();
    let bytes = value.as_bytes();
    if bytes.get(4) != Some(&b'-')
        || bytes.get(7) != Some(&b'-')
        || bytes.get(10) != Some(&b'T')
        || bytes.get(13) != Some(&b':')
        || bytes.get(16) != Some(&b':')
    {
        return None;
    }
    let number = |start, length| {
        let part = value.get(start..start + length)?;
        part.bytes()
            .all(|byte| byte.is_ascii_digit())
            .then(|| part.parse::<i64>().ok())
            .flatten()
    };
    let year = number(0, 4)?;
    let month = number(5, 2)?;
    let day = number(8, 2)?;
    let hour = number(11, 2)?;
    let minute = number(14, 2)?;
    let second = number(17, 2)?;
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    let mut at = 19;
    let mut fraction = 0.0;
    if bytes.get(at) == Some(&b'.') {
        at += 1;
        let count = bytes[at..]
            .iter()
            .take_while(|byte| byte.is_ascii_digit())
            .count();
        if count == 0 {
            return None;
        }
        fraction = value.get(at - 1..at + count)?.parse::<f64>().ok()?;
        at += count;
    }
    let offset = match bytes.get(at)? {
        b'Z' => 0,
        sign @ (b'+' | b'-') => {
            at += 1;
            let count = bytes[at..]
                .iter()
                .take(2)
                .take_while(|byte| byte.is_ascii_digit())
                .count();
            if count == 0 {
                return None;
            }
            let hours = number(at, count)?;
            // Foundation's zone-hour scanner backtracks to a valid prefix.
            let seconds = if hours > 23 {
                number(at, 1)? * 3600
            } else {
                at += count;
                at += usize::from(bytes.get(at) == Some(&b':'));
                hours * 3600 + number(at, 2).unwrap_or(0) * 60
            };
            seconds * if *sign == b'-' { -1 } else { 1 }
        }
        _ => return None,
    };
    let year = year - i64::from(month <= 2);
    let era = year.div_euclid(400);
    let year = year - era * 400;
    let month = month + if month > 2 { -3 } else { 9 };
    let days = era * 146097 + year * 365 + year / 4 - year / 100 + (153 * month + 2) / 5 + day
        - 1
        - 719468;
    let seconds = days * 86400 + hour * 3600 + minute * 60 + second - offset;
    let reference = 978307200.0;
    Some((((seconds as f64 - reference) + fraction + reference) * 1000.0) as i64)
}
