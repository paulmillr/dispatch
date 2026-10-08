use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::Path,
};

#[path = "../src/hash.rs"]
mod hash;

// Only public declarations and the dispatch table determine the schema.
// Implementation locals, comments and client templates cannot change the wire IDs.
fn words(source: &str) -> Vec<String> {
    let mut result = Vec::new();
    let bytes = source.as_bytes();
    let mut at = 0;
    for _ in 0..bytes.len() {
        if at >= bytes.len() {
            break;
        }
        if bytes[at..].starts_with(b"//") {
            at += bytes[at..]
                .iter()
                .position(|b| *b == b'\n')
                .unwrap_or(bytes.len() - at);
        } else if bytes[at..].starts_with(b"/*") {
            at += 2;
            let mut depth = 1;
            for _ in 0..bytes.len() {
                if at >= bytes.len() || depth == 0 {
                    break;
                }
                if bytes[at..].starts_with(b"/*") {
                    depth += 1;
                    at += 2;
                } else if bytes[at..].starts_with(b"*/") {
                    depth -= 1;
                    at += 2;
                } else {
                    at += 1;
                }
            }
        } else if bytes[at] == b'"' {
            let start = at;
            at += 1;
            for _ in 0..bytes.len() {
                if at >= bytes.len() {
                    break;
                }
                if bytes[at] == b'\\' {
                    at += 2;
                } else if bytes[at] == b'"' {
                    at += 1;
                    break;
                } else {
                    at += 1;
                }
            }
            result.push(source[start..at.min(bytes.len())].to_owned());
        } else if bytes[at].is_ascii_alphabetic() || bytes[at] == b'_' {
            let start = at;
            at += 1;
            for _ in 0..bytes.len() {
                if at >= bytes.len() || !(bytes[at].is_ascii_alphanumeric() || bytes[at] == b'_') {
                    break;
                }
                at += 1;
            }
            result.push(source[start..at].to_owned());
        } else if !bytes[at].is_ascii_whitespace() {
            result.push((bytes[at] as char).to_string());
            at += 1;
        } else {
            at += 1;
        }
    }
    result
}

/// Types with an `Encode` implementation anywhere in core (records! entries included).
fn encoded(directory: &Path) -> BTreeSet<String> {
    let mut names = BTreeSet::new();
    for entry in fs::read_dir(directory).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            names.extend(encoded(&path));
            continue;
        }
        if path.extension().and_then(|v| v.to_str()) != Some("rs") {
            continue;
        }
        println!("cargo:rerun-if-changed={}", path.display());
        let tokens = words(&fs::read_to_string(&path).unwrap());
        for (at, token) in tokens.iter().enumerate() {
            if token == "Encode" && tokens.get(at + 1).is_some_and(|v| v == "for") {
                names.insert(tokens[at + 2].clone());
            }
        }
        if let Some(start) = tokens.windows(3).position(|w| w == ["records", "!", "{"]) {
            let mut depth = 0;
            for at in start + 2..tokens.len() {
                match tokens[at].as_str() {
                    "{" => {
                        if depth == 1 {
                            names.insert(tokens[at - 1].clone());
                        }
                        depth += 1;
                    }
                    "}" => depth -= 1,
                    _ => {}
                }
                if depth == 0 {
                    break;
                }
            }
        }
    }
    names
}

pub fn generate(root: &Path, output: &Path) {
    let mut paths = vec![root.join("src/api.rs"), root.join("src/dispatch/table.rs")];
    paths.extend(
        fs::read_dir(root.join("src/api"))
            .unwrap()
            .map(|entry| entry.unwrap().path()),
    );
    paths.sort();
    // The one common RPC envelope; operation-specific fields come from declarations.
    let mut symbols: BTreeSet<String> = [
        "method", "params", "result", "error", "stream", "chunks", "bytes", "encoding",
    ]
    .into_iter()
    .map(str::to_owned)
    .collect();
    let mut records = BTreeMap::new();
    let encoded = encoded(&root.join("src"));
    for path in paths {
        if path.extension().and_then(|v| v.to_str()) != Some("rs") {
            continue;
        }
        println!("cargo:rerun-if-changed={}", path.display());
        let tokens = words(&fs::read_to_string(&path).unwrap());
        for at in 0..tokens.len().saturating_sub(3) {
            if tokens[at] != "pub" || tokens[at + 1] != "struct" {
                continue;
            }
            let name = &tokens[at + 2];
            let Some(start) = tokens[at + 3..]
                .iter()
                .position(|v| v == "{" || v == ";")
                .map(|n| n + at + 3)
            else {
                continue;
            };
            if tokens[start] != "{" {
                continue;
            }
            let mut depth = 1;
            let mut fields = Vec::new();
            for i in start + 1..tokens.len() {
                match tokens[i].as_str() {
                    "{" => depth += 1,
                    "}" => depth -= 1,
                    "pub" if depth == 1 && tokens.get(i + 2).is_some_and(|v| v == ":") => {
                        fields.push(tokens[i + 1].clone());
                    }
                    _ => {}
                }
                if depth == 0 {
                    break;
                }
            }
            // Only structs core encodes are wire records; others (Transcript, request inputs)
            // never reach the wire as these objects, so their fields must not move the schema.
            if !fields.is_empty() && encoded.contains(name) {
                records.insert(name.clone(), fields);
            }
        }
        // Enum fields are public implicitly; collect their named variant layouts too.
        for at in 0..tokens.len().saturating_sub(3) {
            if tokens[at] != "pub" || tokens[at + 1] != "enum" {
                continue;
            }
            let Some(start) = tokens[at + 3..]
                .iter()
                .position(|v| v == "{")
                .map(|n| n + at + 3)
            else {
                continue;
            };
            let mut depth = 1;
            let mut variant = String::new();
            let mut fields = Vec::new();
            for i in start + 1..tokens.len() {
                if depth == 1 && tokens.get(i + 1).is_some_and(|v| v == "{") {
                    variant = tokens[i].clone();
                    fields.clear();
                }
                match tokens[i].as_str() {
                    "{" => depth += 1,
                    "}" => {
                        if depth == 2 && !fields.is_empty() {
                            records
                                .insert(format!("{}.{}", tokens[at + 2], variant), fields.clone());
                        }
                        depth -= 1;
                    }
                    _ if depth == 2
                        && tokens.get(i + 1).is_some_and(|v| v == ":")
                        && tokens.get(i + 2).is_some_and(|v| v != ":") =>
                    {
                        fields.push(tokens[i].clone())
                    }
                    _ => {}
                }
                if depth == 0 {
                    break;
                }
            }
        }
        if path.file_name().is_some_and(|name| name == "table.rs") {
            for token in &tokens {
                if token.starts_with('"') && !token.contains('\\') {
                    symbols.insert(token.trim_matches('"').to_owned());
                }
            }
        }
    }
    // A record core encodes field by field (encode.rs `records!`) has exactly those fields on the
    // wire: a public field it does not encode (an internal cursor) must not change the schema.
    let encode = root.join("src/encode.rs");
    println!("cargo:rerun-if-changed={}", encode.display());
    let tokens = words(&fs::read_to_string(&encode).unwrap());
    if let Some(start) = tokens.windows(3).position(|w| w == ["records", "!", "{"]) {
        let mut at = start + 3;
        for _ in 0..tokens.len() {
            if tokens.get(at + 1).is_none_or(|v| v != "{") {
                break;
            }
            let name = tokens[at].clone();
            let end = at + 2 + tokens[at + 2..].iter().position(|v| v == "}").unwrap();
            let fields: Vec<_> = tokens[at + 2..end].iter().filter(|v| *v != ",").cloned().collect();
            if records.contains_key(&name) {
                records.insert(name, fields);
            }
            at = end + 1;
            if tokens.get(at).is_some_and(|v| v == ";") {
                at += 1;
            }
        }
    }
    for fields in records.values() {
        symbols.extend(fields.iter().cloned());
    }
    assert!(symbols.len() < u16::MAX as usize);
    assert!(records.len() < u16::MAX as usize);
    let mut digest = hash::Sha256::new();
    for symbol in &symbols {
        digest.update(symbol.as_bytes());
        digest.update(&[0]);
    }
    for (name, fields) in &records {
        digest.update(name.as_bytes());
        for field in fields {
            digest.update(&[0]);
            digest.update(field.as_bytes());
        }
        digest.update(&[0]);
    }
    let mut schema: [u8; 8] = digest.finish()[..8].try_into().unwrap();
    // 0xFF never starts UTF-8 text, so a binary body is never mistaken for JSON by code that
    // accepts both (a digest starting with '{' broke stats' frame adapter).
    schema[0] = 0xFF;
    let items = symbols
        .iter()
        .map(|v| format!("{v:?}"))
        .collect::<Vec<_>>()
        .join(",\n");
    let layouts = records
        .values()
        .map(|v| format!("{v:?}"))
        .collect::<Vec<_>>()
        .join(",\n");
    let rust = records
        .values()
        .map(|v| format!("&{v:?}"))
        .collect::<Vec<_>>()
        .join(",\n");
    fs::write(
        output.join("wire-schema.rs"),
        format!("pub const SCHEMA: [u8; 8] = {schema:?};\npub const SYMBOLS: &[&str] = &[\n{items}\n];\npub const RECORDS: &[&[&str]] = &[\n{rust}\n];\n"),
    ).unwrap();
    let version = u64::from_le_bytes(schema);
    for (language, extension, declaration) in [
        (
            "python",
            "py",
            format!(
                "SCHEMA = bytes({schema:?})\nVERSION = int.from_bytes(SCHEMA, 'little')\nSYMBOLS = [\n{items}\n]\nRECORDS = [\n{layouts}\n]\n"
            ),
        ),
        (
            "swift",
            "swift",
            format!(
                "import Foundation\nimport CoreFoundation\n\npublic enum HelperBinary {{\n    public static let schema: [UInt8] = {schema:?}\n    public static let version: UInt64 = {version}\n    public static let symbols: [String] = [\n{items}\n]\n    public static let records: [[String]] = [\n{layouts}\n]\n"
            ),
        ),
    ] {
        let template = root.join(format!("src/wire/body.{language}"));
        println!("cargo:rerun-if-changed={}", template.display());
        let contents = declaration + &fs::read_to_string(template).unwrap();
        fs::write(output.join(format!("HelperBinary.{extension}")), &contents).unwrap();
        if language == "python" {
            let client = root.join("src/wire/body.client");
            println!("cargo:rerun-if-changed={}", client.display());
            fs::write(
                output.join("HelperTestClient.py"),
                contents + &fs::read_to_string(client).unwrap(),
            )
            .unwrap();
        }
    }
}
