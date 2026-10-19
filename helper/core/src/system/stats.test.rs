use super::*;

fn scan() -> Scan {
    Scan {
        started: Instant::now(),
        rows: Vec::new(),
        truncated: false,
        bytes: 1024,
    }
}

fn rows(scan: &Scan) -> (Vec<u8>, bool) {
    let rows = Data::Array(scan.rows.iter().map(Counter::data).collect());
    (write(&rows).unwrap(), scan.truncated)
}

#[test]
fn ps_lines_are_rows_named_by_their_executable() {
    // Aligned numbers (rss in KiB), then the whole path, spaces included. A line that is no process
    // row (pid 0, a number that is not one, no path) is left out.
    let output = concat!(
        "    1   0.3  20240 /sbin/launchd\n",
        "  412 112.5   2048 /Applications/Some App.app/Contents/MacOS/Some App\n",
        "  413   0.0      8 worker\n",
        "    0   0.0      8 kernel\n",
        "  414     x      8 /bin/odd\n",
        "  415   0.0      8\n",
        "  416   1.0      8 /bin/last",
    );
    let mut scan = scan();
    ps(&mut scan, output.as_bytes()).unwrap();
    let row = |pid, name, cpu, rss| {
        Data::Object(vec![
            ("pid", Data::Signed(pid)),
            ("name", Data::String(name)),
            ("cpu", Data::Real(cpu)),
            ("rss", Data::Unsigned(rss)),
        ])
    };
    let expected = Data::Array(vec![
        row(1, "launchd", 0.3, 20240 * 1024),
        row(412, "Some App", 112.5, 2048 * 1024),
        row(413, "worker", 0.0, 8192),
        row(416, "last", 1.0, 8192),
    ]);
    assert_eq!(rows(&scan), (write(&expected).unwrap(), false));
}

#[test]
fn a_list_stops_at_4096_rows_and_says_it_is_partial() {
    // The stats plugin takes at most 4096 rows; ps has no limit of its own.
    let output: String = (1..=4097)
        .map(|pid| format!("{pid} 0.0 4 worker\n"))
        .collect();
    let mut scan = scan();
    ps(&mut scan, output.as_bytes()).unwrap();
    let last = scan.rows.last().map(|row| row.pid);
    assert_eq!(
        (scan.rows.len(), last, scan.truncated),
        (4096, Some(4096), true)
    );
}

#[cfg(target_os = "linux")]
#[test]
fn a_proc_stat_line_is_a_row_with_its_start_and_cpu_time() {
    // 250 + 50 ticks at 100 per second; 25 pages of 4 KiB.
    let stat = b"7 (my worker) S 1 7 7 0 -1 4194560 100 0 0 0 250 50 0 0 20 0 1 0 12345 1000000 25";
    let row = linux::row(stat, 7, 100, 4096).unwrap();
    let expected = Data::Object(vec![
        ("pid", Data::Signed(7)),
        ("start", Data::String("12345")),
        ("name", Data::String("my worker")),
        ("cpuNanos", Data::Unsigned(3_000_000_000)),
        ("rss", Data::Unsigned(102_400)),
    ]);
    assert_eq!(write(&row.data()).unwrap(), write(&expected).unwrap());
}
