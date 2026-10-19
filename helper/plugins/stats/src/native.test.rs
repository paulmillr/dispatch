use super::*;

fn list(rows: Vec<Data<'_>>) -> Data<'_> {
    Data::Object(vec![
        ("boot", Data::String("boot")),
        ("truncated", Data::Bool(false)),
        ("processes", Data::Array(rows)),
    ])
}

/// A macOS row: ps's own percentage, no start.
fn percent(pid: u64, cpu: f64) -> Data<'static> {
    Data::Object(vec![
        ("pid", Data::Unsigned(pid)),
        ("name", Data::String("worker")),
        ("cpu", Data::Real(cpu)),
        ("rss", Data::Unsigned(4096)),
    ])
}

/// A Linux row: its start and its CPU time so far.
fn counter(pid: u64, start: Option<&str>, nanos: u64) -> Data<'_> {
    let mut fields = vec![("pid", Data::Unsigned(pid))];
    fields.extend(start.map(|start| ("start", Data::String(start))));
    fields.extend([
        ("name", Data::String("worker")),
        ("cpuNanos", Data::Unsigned(nanos)),
        ("rss", Data::Unsigned(4096)),
    ]);
    Data::Object(fields)
}

fn row(pid: u32, start: Option<&str>, cpu: Option<f64>) -> Row {
    Row {
        pid,
        start: start.map(Into::into),
        name: "worker".into(),
        cpu,
        rss: Some(4096),
    }
}

#[test]
fn a_percentage_is_shown_at_once_a_cpu_time_from_its_previous_sample() {
    // The rule is per row: either kind in one list.
    let mut rates = Rates::default();
    let sample = |nanos| list(vec![percent(7, 12.5), counter(8, Some("100"), nanos)]);
    assert_eq!(
        rates.processes_at(&sample(1_000_000_000), 10.0),
        Ok((
            vec![row(7, None, Some(12.5)), row(8, Some("100"), None)],
            false
        ))
    );
    // One more CPU second in two seconds: half of one core.
    assert_eq!(
        rates.processes_at(&sample(2_000_000_000), 12.0),
        Ok((
            vec![row(7, None, Some(12.5)), row(8, Some("100"), Some(50.0))],
            false
        ))
    );
}

#[test]
fn a_list_holding_anything_but_process_rows_is_refused() {
    for rows in [
        vec![percent(7, 12.5), counter(7, Some("100"), 0)],
        // Without its start a CPU time cannot be compared with the previous sample's.
        vec![counter(7, None, 0)],
        vec![percent(7, -1.0)],
    ] {
        assert_eq!(
            Rates::default().processes_at(&list(rows), 10.0),
            Err(invalid())
        );
    }
    // Text, as ps writes it, is not a list.
    let text = Data::Object(vec![
        ("boot", Data::String("boot")),
        ("truncated", Data::Bool(false)),
        ("ps", Data::String("    7  12.5      4 /bin/worker\n")),
    ]);
    assert_eq!(Rates::default().processes_at(&text, 10.0), Err(invalid()));
}
