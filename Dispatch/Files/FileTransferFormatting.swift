import Foundation

/// The numbers a transfer row shows: "31 of 48 MB", "12 MB/s", "6.2 s", "5,120".
/// Sizes are decimal like Finder's, so a row and Finder agree on what arrived.
enum FileTransferFormatting {
    private static let units = ["B", "KB", "MB", "GB", "TB"]

    /// The unit a size reads in, and the size in that unit.
    private static func scaled(_ bytes: Double, unit: Int? = nil) -> (value: Double, unit: Int) {
        if let unit { return (bytes / pow(1000, Double(unit)), unit) }
        var value = bytes, index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        return (value, index)
    }

    /// One decimal below 100 ("5.7 of 11.8 MB"), none when it is zero ("48 MB") and above; bytes are always whole.
    private static func number(_ value: Double, unit: Int) -> String {
        if unit == 0 || value >= 99.95 { return String(Int(value.rounded())) }
        let text = String(format: "%.1f", value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    static func bytes(_ count: UInt64) -> String {
        let (value, unit) = scaled(Double(count))
        return number(value, unit: unit) + " " + units[unit]
    }

    /// "31 of 48 MB": both in the total's unit, so the done part never reads larger than the whole.
    static func progress(_ done: UInt64, of total: UInt64) -> String {
        let unit = scaled(Double(total)).unit
        let done = scaled(Double(min(done, total)), unit: unit).value, whole = scaled(Double(total), unit: unit).value
        return number(done, unit: unit) + " of " + number(whole, unit: unit) + " " + units[unit]
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        bytes(UInt64(max(0, bytesPerSecond).rounded())) + "/s"
    }

    /// "6.2 s" under ten seconds, "42 s" under a minute, "3 min 12 s" beyond.
    static func duration(_ seconds: TimeInterval) -> String {
        let seconds = max(0, seconds)
        if seconds < 10 { return String(format: "%.1f s", seconds) }
        if seconds < 60 { return "\(Int(seconds.rounded())) s" }
        let whole = Int(seconds.rounded())
        return "\(whole / 60) min \(whole % 60) s"
    }

    /// "5,120": grouped the same way on every Mac, as the mockups read.
    static func count(_ value: UInt64) -> String {
        let digits = Array(String(value))
        var out = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(digit)
        }
        return out
    }

    /// "1 item", "5,120 items".
    static func items(_ value: UInt64) -> String {
        count(value) + (value == 1 ? " item" : " items")
    }

    /// What a row calls a folder: "fixtures/", or "/" for the root.
    static func folderLabel(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? "/" : name + "/"
    }
}

/// What one transfer row says in its state (F2b "Transfer row · states"). Pure, so tests read it without a window.
@MainActor struct FileTransferText: Equatable {
    /// Leading text; `emphasis` (the target) follows it in the brighter ink.
    var title: String
    var emphasis: String?
    /// Muted text after the title; `separated` puts a "·" between them.
    var detail: String?
    var separated = false
    /// The second line of a failure: what the target was left with.
    var note: String?

    /// `host` is where the archive unpacks: the target's host name, or "this Mac".
    init(_ transfer: FileTransfer, host: String) {
        let label = transfer.targetLabel
        let items = FileTransferFormatting.items(UInt64(transfer.items))
        func copying(_ detail: String?) -> (String, String?, String?, Bool) {
            ("Copying \(items) to ", label, detail, detail != nil)
        }
        let parts: (title: String, emphasis: String?, detail: String?, separated: Bool)
        switch transfer.stage {
        case .preparing:
            parts = copying(nil)
        case .packing:
            parts = copying("packing…")
        case .sending:
            var detail = transfer.bytesTotal.map { FileTransferFormatting.progress(transfer.bytesDone, of: $0) }
                ?? FileTransferFormatting.bytes(transfer.bytesDone)
            if let rate = transfer.rate { detail += " · " + FileTransferFormatting.rate(rate) }
            parts = ("Sending", nil, detail, false)
        case .unpacking:
            // Rows dragged out unpack into the drop folder; the others on the shown host.
            let title = transfer.kind == .copyOut ? "Unpacking into \(label)" : "Unpacking on \(host)"
            parts = (title, nil, transfer.entries.map(FileTransferFormatting.items), false)
        case .done where transfer.entriesDone == 0 && transfer.skipped > 0:
            parts = ("Nothing to copy", nil, "\(FileTransferFormatting.count(transfer.skipped)) skipped", true)
        case .done:
            var detail = transfer.bytesTotal.map(FileTransferFormatting.bytes) ?? FileTransferFormatting.bytes(transfer.bytesDone)
            if let finished = transfer.finishedAt {
                detail += " · " + FileTransferFormatting.duration(finished.timeIntervalSince(transfer.startedAt))
            }
            if transfer.skipped > 0 { detail += " · \(FileTransferFormatting.count(transfer.skipped)) skipped" }
            parts = ("\(FileTransferFormatting.items(transfer.entriesDone)) copied", nil, detail, false)
        case .conflict(let existing):
            let what = existing.count == 1 && transfer.items == 1 ? existing[0] : "\(FileTransferFormatting.count(UInt64(existing.count))) of these"
            parts = ("\(label) already has \(what)", nil, nil, false)
        case .failed(let message, _):
            parts = (message, nil, nil, false)
        case .cancelled:
            let detail = transfer.uncertain ? "some items may have been written to \(label)"
                : transfer.entriesDone == 0 ? "nothing was written to \(label)"
                : "\(FileTransferFormatting.items(transfer.entriesDone)) copied before"
            parts = ("Cancelled", nil, detail, false)
        }
        (title, emphasis, detail, separated) = parts
        // What the target holds after a failure: unknown when a write went unanswered, else what arrived first.
        if case .failed(_, let retryable) = transfer.stage {
            if transfer.uncertain {
                note = "Some items may have been written to \(label)"
            } else if transfer.entriesDone > 0 {
                note = "\(FileTransferFormatting.items(transfer.entriesDone)) copied to \(label) before"
            } else if retryable {
                note = "Nothing was written to \(label)"
            }
        }
    }

    /// The whole text, as VoiceOver reads the row.
    var spoken: String {
        [title + (emphasis ?? ""), detail, note].compactMap { $0 }.joined(separator: ", ")
    }
}
