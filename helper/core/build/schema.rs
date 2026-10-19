use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::Path,
};


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
        // Enum fields are public implicitly; collect the named variant layouts of the enums core encodes. An enum that
        // never reaches the wire (a helper's internal jobs) must not add layouts, as structs above.
        for at in 0..tokens.len().saturating_sub(3) {
            if tokens[at] != "pub" || tokens[at + 1] != "enum" || !encoded.contains(&tokens[at + 2]) {
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
    let (schema, symbols, layouts) = registered(&root.join("src/wire/registry.txt"), &symbols, &records);
    assert!(symbols.len() < u16::MAX as usize);
    assert!(layouts.len() < u16::MAX as usize);
    // Names are looked up through their sorted order (body.rs `symbol`): the table itself is in number order.
    let mut order: Vec<usize> = (0..symbols.len()).collect();
    order.sort_by(|a, b| symbols[*a].cmp(&symbols[*b]));
    let order = order.iter().map(|index| index.to_string()).collect::<Vec<_>>().join(", ");
    let items = symbols
        .iter()
        .map(|v| format!("{v:?}"))
        .collect::<Vec<_>>()
        .join(",\n");
    let rust = layouts
        .iter()
        .map(|v| format!("&{v:?}"))
        .collect::<Vec<_>>()
        .join(",\n");
    let layouts = layouts
        .iter()
        .map(|v| format!("{v:?}"))
        .collect::<Vec<_>>()
        .join(",\n");
    fs::write(
        output.join("wire-schema.rs"),
        format!("pub const SCHEMA: [u8; 8] = {schema:?};\npub const SYMBOLS: &[&str] = &[\n{items}\n];\npub const SYMBOL_ORDER: &[u16] = &[{order}];\npub const RECORDS: &[&[&str]] = &[\n{rust}\n];\n"),
    ).unwrap();
    let version = u64::from_le_bytes(schema);
    // The app's codec; the helper and the app are the only implementations of this format.
    let template = root.join("src/wire/body.swift");
    println!("cargo:rerun-if-changed={}", template.display());
    fs::write(
        output.join("HelperBinary.swift"),
        format!(
            "// Generated by helper/core/build/schema.rs from helper/core/src/wire/body.swift: edit those, not this file.\nimport Foundation\nimport CoreFoundation\n\npublic enum HelperBinary {{\n    public static let schema: [UInt8] = {schema:?}\n    public static let version: UInt64 = {version}\n    public static let symbols: [String] = [\n{items}\n]\n    public static let records: [[String]] = [\n{layouts}\n]\n"
        ) + &fs::read_to_string(template).unwrap(),
    )
    .unwrap();
}

/// The wire's permanent numbers (src/wire/registry.txt): its generation id, then names and record layouts in number
/// order, with what `symbols` and `records` hold that it does not appended (sorted, so every build appends alike) and
/// written back. Numbers never move, so a recording made before an addition still reads every name it holds, and the
/// generation id, which starts every wire body, changes only with a new table (a breaking change, made by hand).
fn registered(path: &Path, symbols: &BTreeSet<String>, records: &BTreeMap<String, Vec<String>>)
    -> ([u8; 8], Vec<String>, Vec<Vec<String>>) {
    println!("cargo:rerun-if-changed={}", path.display());
    let text = fs::read_to_string(path).unwrap_or_else(|error| panic!("{}: {error}", path.display()));
    let (mut schema, mut table, mut layouts) = (None, Vec::new(), Vec::new());
    for line in text.lines().filter(|line| !line.is_empty() && !line.starts_with('#')) {
        let mut parts = line.split('\t');
        match parts.next() {
            Some("schema") => schema = parts.next().map(str::to_owned),
            Some("s") => table.push(parts.next().unwrap_or_default().to_owned()),
            Some("r") => layouts.push(parts.map(str::to_owned).collect::<Vec<_>>()),
            _ => panic!("{}: unknown line {line:?}", path.display()),
        }
    }
    let schema = schema.unwrap_or_else(|| panic!("{}: no schema line", path.display()));
    let schema: Vec<u8> = (0..schema.len()).step_by(2).map(|at| u8::from_str_radix(&schema[at..at + 2], 16).unwrap()).collect();
    let schema: [u8; 8] = schema.try_into().unwrap_or_else(|_| panic!("{}: the schema is 8 bytes of hex", path.display()));
    // 0xFF never starts UTF-8 text, so a binary body is never mistaken for JSON by code that accepts both.
    assert_eq!(schema[0], 0xFF, "{}: a schema starts with ff", path.display());
    let unique: BTreeSet<&String> = table.iter().collect();
    assert_eq!(unique.len(), table.len(), "{}: a name is listed twice", path.display());
    let new: Vec<String> = symbols.iter().filter(|symbol| !unique.contains(symbol)).cloned().collect();
    let mut added: Vec<Vec<String>> = Vec::new();
    for fields in records.values() {
        if !layouts.contains(fields) && !added.contains(fields) {
            added.push(fields.clone());
        }
    }
    if !new.is_empty() || !added.is_empty() {
        let mut appended = text.clone();
        if !appended.ends_with('\n') {
            appended.push('\n');
        }
        for symbol in &new {
            assert!(!symbol.contains(['\t', '\n']), "a wire name holds a tab or a newline: {symbol:?}");
            appended.push_str(&format!("s\t{symbol}\n"));
        }
        for fields in &added {
            appended.push_str(&format!("r\t{}\n", fields.join("\t")));
        }
        // Builds for several targets may run at once: each writes the same text, whole, by rename.
        let temporary = path.with_extension(format!("txt.{}", std::process::id()));
        fs::write(&temporary, appended).unwrap();
        fs::rename(&temporary, path).unwrap();
        println!("cargo:warning=wire registry: {} names and {} record layouts appended to {}; commit it with the change",
                 new.len(), added.len(), path.display());
        table.extend(new);
        layouts.extend(added);
    }
    (schema, table, layouts)
}
