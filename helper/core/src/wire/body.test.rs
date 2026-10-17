use super::*;
use crate::json::Json;

#[test]
fn agent_json_with_a_repeated_key_is_refused_when_encoded_not_when_read() {
    // root() expects what was checked when made; the reader refuses a repeated key at any depth.
    let repeated = Json::parse(br#"{"turn":{"model":"m1","model":"m2"}}"#).unwrap();
    assert_eq!(Encoded::value(&Data::Value(repeated.root())).map(|_| ()), Err(crate::dispatch::invalid("request")));
    let distinct = Json::parse(br#"{"turn":{"model":"m1","effort":"high"}}"#).unwrap();
    let made = Encoded::value(&Data::Value(distinct.root())).unwrap();
    assert_eq!(encode_plain(&made.root()), encode_plain(&Data::Value(distinct.root())));
}

/// A wire body: an array holding one array of `count` nulls per count.
fn arrays(counts: &[usize]) -> Vec<u8> {
    let mut out = SCHEMA.to_vec();
    array(&mut out, counts.len());
    for count in counts {
        array(&mut out, *count);
        out.resize(out.len() + count, 0);
    }
    out
}

#[test]
fn a_wire_body_holds_at_most_values_values_in_all_its_arrays() {
    // Every array is a value too: VALUES in all, then one more, in one array or spread over two.
    let decoded = |counts: &[usize]| decode(&arrays(counts)).map(|_| ()).map_err(|error| error.code);
    assert_eq!(decoded(&[VALUES - 2]), Ok(()));
    assert_eq!(decoded(&[VALUES / 2, VALUES / 2 - 3]), Ok(()));
    assert_eq!(decoded(&[VALUES - 1]), Err("protocol"));
    assert_eq!(decoded(&[VALUES / 2, VALUES / 2 - 2]), Err("protocol"));
    // A plain value is the helper's own (a capture's, a job's): not counted.
    assert!(decode_plain(&arrays(&[VALUES])[SCHEMA.len()..]).is_ok());
}
