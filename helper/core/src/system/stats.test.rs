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

#[cfg(target_os = "macos")]
#[test]
fn host_samples_release_the_host_port() {
    // stats.host runs in the long-lived helper: each mach_host_self() it takes is released, or every sample
    // would add a reference to the host port until Mach refuses more.
    unsafe extern "C" {
        fn mach_port_get_refs(task: u32, name: u32, right: u32, refs: *mut u32) -> i32;
    }
    let references = || {
        let mut count = 0;
        // SAFETY: scalar Mach calls on this task's own send right (MACH_PORT_RIGHT_SEND, 0), released after.
        unsafe {
            let port = darwin::mach_host_self();
            assert_eq!(mach_port_get_refs(darwin::mach_task_self_, port, 0, &mut count), 0);
            darwin::mach_port_deallocate(darwin::mach_task_self_, port);
        }
        count
    };
    let before = references();
    for _ in 0..100 {
        macos::host(&mut Host::default(), true);
    }
    assert_eq!(references(), before);
}

#[cfg(target_os = "macos")]
#[test]
fn interface_records_are_links_with_64_bit_counters() {
    // ifmibdata: the name at 0, flags at 20, ifi_ibytes and ifi_obytes at 116 and 124 (if_data64 at 52).
    let record = |name: &str, flags: u32, received: u64, sent: u64| {
        let mut record = vec![0u8; 180];
        record[..name.len()].copy_from_slice(name.as_bytes());
        record[20..24].copy_from_slice(&flags.to_ne_bytes());
        record[116..124].copy_from_slice(&received.to_ne_bytes());
        record[124..132].copy_from_slice(&sent.to_ne_bytes());
        record
    };
    let row = macos::link(&record("en0", 0x8863, 11 << 30, 7)).unwrap();
    assert_eq!((row.name.as_str(), row.received, row.sent), ("en0", 11 << 30, 7));
    assert!(macos::link(&record("lo0", 0x8049, 1, 1)).is_none(), "IFF_LOOPBACK is left out");
    assert!(macos::link(&record("en1", 0, 1, 1)[..131]).is_none(), "a short record is no link");
    assert!(macos::link(&record("", 0, 1, 1)).is_none());
}
