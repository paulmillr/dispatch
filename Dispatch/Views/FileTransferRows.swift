import SwiftUI

/// The 34 pt rows under the list, one per transfer (F2b "Transfer row · states"): a 2 pt progress bar along the top,
/// the stage dots (pack · send · unpack) and Cancel while it runs; the conflict question and a failure grow to two
/// lines. Finished rows slide away when the engine removes them.
struct FileTransferRows: View {
    let session: FilesSession
    @MotionReduced private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ForEach(session.transfers) { transfer in
                FileTransferRow(transfer: transfer, host: host(for: transfer))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Only the rows' own stack animates: the list above keeps its layout while a row comes or goes.
        .animation(InterfaceMotion.animation(reduce: reduceMotion), value: session.transfers.map(\.id))
        .clipped()
    }

    /// Where a row's archive unpacks: the shown host for copies into this list, this Mac for rows dragged out.
    private func host(for transfer: FileTransfer) -> String {
        guard transfer.kind != .copyOut else { return "this Mac" }
        return session.source?.hostLabel ?? session.hostLabel ?? "this Mac"
    }
}

struct FileTransferRow: View {
    let transfer: FileTransfer
    let host: String

    private var palette: SidebarPalette { Chrome.palette }
    @Environment(\.appTypography) private var typography

    var body: some View {
        let text = FileTransferText(transfer, host: host)
        Group {
            switch transfer.stage {
            case .conflict:
                FileConflictPrompt(transfer: transfer, text: text)
            case .failed:
                failure(text)
            default:
                progressRow(text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(TransferRowChrome())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(text.spoken)
        .accessibilityIdentifier("file-transfer-\(transfer.id.uuidString)")
    }

    private func progressRow(_ text: FileTransferText) -> some View {
        HStack(spacing: 10) {
            if transfer.stage == .done {
                Text("✓").foregroundStyle(palette.green)
            } else if transfer.isActive {
                Image(systemName: transfer.kind == .copyOut ? "arrow.down" : "arrow.up")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .help("To \(text.destination)")
                    .accessibilityHidden(true)
            }
            title(text)
            if let detail = text.detail {
                if text.separated { Text("·").foregroundStyle(palette.detail) }
                Text(detail).foregroundStyle(palette.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
            if transfer.isActive { StageDots(stage: transfer.stage, archived: transfer.archived) }
            closeButton
        }
        .font(typography, .label)
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(height: 34)
        .overlay(alignment: .top) { bar }
    }

    private func title(_ text: FileTransferText) -> some View {
        (Text(text.title).foregroundColor(palette.secondary)
            + Text(text.emphasis ?? "").foregroundColor(palette.ink))
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func failure(_ text: FileTransferText) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "diamond.fill").imageScale(.small).foregroundStyle(palette.warning)
                Text(text.title).foregroundStyle(palette.secondary).lineLimit(2)
                Spacer(minLength: 0)
                if let retry = transfer.retry {
                    Button("Retry") { retry() }
                        .buttonStyle(FileTransferButtonStyle())
                        .help("Retry · copy again from the start")
                        .accessibilityIdentifier("file-transfer-retry")
                }
                closeButton
            }
            if let note = text.note {
                Text(note).font(typography, .caption).foregroundStyle(palette.muted)
            }
        }
        .font(typography, .label)
        .padding(.vertical, 8)
        .padding(.leading, 14)
        .padding(.trailing, 12)
    }

    /// The cross cancels while the copy can still stop, and dismisses a settled row; it dims once entries move in.
    private var closeButton: some View {
        let settled = !transfer.isActive
        let enabled = transfer.cancellable || (settled && transfer.cancel != nil)
        return Button { transfer.cancel?() } label: {
            Image(systemName: "xmark").font(typography.symbol(.caption, weight: .semibold))
                .frame(minWidth: 22, minHeight: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? palette.sidebarDetail : palette.faint)
        .disabled(!enabled)
        .help(settled ? "Dismiss" : Self.cancelHelp(transfer))
        .accessibilityLabel(settled ? "Dismiss" : "Cancel")
        .accessibilityIdentifier(settled ? "file-transfer-dismiss" : "file-transfer-cancel")
    }

    /// What Cancel leaves: an archive copy writes nothing until it unpacks; files written one by one stay.
    static func cancelHelp(_ transfer: FileTransfer) -> String {
        transfer.archived ? "Cancel · nothing is written until unpacking starts"
            : "Cancel · stops after the file being written; files already copied stay"
    }

    /// The 2 pt bar: how far the copy got, green once done.
    private var bar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(palette.separator)
                Rectangle()
                    .fill(transfer.stage == .done ? palette.green : palette.accent)
                    .frame(width: geometry.size.width * Self.fraction(transfer))
            }
        }
        .frame(height: 2)
        .offset(y: -1)
        .accessibilityHidden(true)
    }

    /// Packing and unpacking report nothing until they finish, so they hold fixed shares around the sending bytes.
    static func fraction(_ transfer: FileTransfer) -> CGFloat {
        switch transfer.stage {
        case .preparing: 0
        case .packing: 0.05
        case .sending:
            0.1 + 0.8 * (transfer.bytesTotal.map { $0 == 0 ? 1 : min(1, Double(transfer.bytesDone) / Double($0)) } ?? 0)
        case .unpacking: 0.9
        case .done: 1
        case .conflict, .failed, .cancelled: 0
        }
    }
}

/// The copy's steps as dots (packed, sent, unpacked): green once done, accent while running, dim ahead, their names in
/// the help. Files written one by one are neither packed nor unpacked: they show the send dot alone.
private struct StageDots: View {
    @Environment(\.appTypography) private var typography
    let stage: FileTransfer.Stage
    let archived: Bool
    private var palette: SidebarPalette { Chrome.palette }

    var body: some View {
        let names = archived ? ["Packing", "Sending", "Unpacking"] : ["Sending"]
        let active: Int = switch stage {
        case .preparing: -1
        case .packing: 0
        case .sending: archived ? 1 : 0
        default: names.count - 1
        }
        HStack(spacing: 5) {
            ForEach(Array(names.enumerated()), id: \.offset) { index, _ in
                Circle()
                    .fill(index < active ? palette.green : index == active ? palette.accent : palette.controlBorder)
                    .frame(width: 5, height: 5)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .help(Self.help(names: names, active: active))
        .accessibilityHidden(true)
    }
}

extension StageDots {
    /// "Step 2 of 3: Sending · packed into one archive, unpacked as a whole at the end".
    static func help(names: [String], active: Int) -> String {
        let step = min(max(active, 0), names.count - 1)
        let what = names.count > 1 ? " · packed into one archive, unpacked as a whole at the end" : " · file by file"
        return "Step \(step + 1) of \(names.count): \(names[step])" + what
    }
}

struct FileTransferButtonStyle: ButtonStyle {
    @Environment(\.appTypography) var typography
    /// The quiet Cancel at the end of the conflict question: no fill, muted.
    var quiet = false

    func makeBody(configuration: Configuration) -> some View {
        let palette = Chrome.palette
        configuration.label
            .font(typography, .body)
            .foregroundStyle(quiet ? palette.muted : palette.secondary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .hoverFill(RoundedRectangle(cornerRadius: 5))
            .background(quiet ? Color.clear : palette.ink.opacity(configuration.isPressed ? 0.12 : 0.07),
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
    }
}

/// A transfer row's chrome: flat, a bar under the list with a rule along its top; on Liquid Glass a rounded glass
/// panel floating over the list's foot, inset from its edges, its progress bar clipped to the panel's corners.
private struct TransferRowChrome: ViewModifier {
    func body(content: Content) -> some View {
        let palette = Chrome.palette
        if LiquidGlassStore.shared.active {
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            content.clipShape(shape)
                .liquidGlass(in: shape, fallback: palette.window)
                .padding(.horizontal, 8).padding(.vertical, 3)
        } else {
            content
                .background(palette.window)
                .overlay(alignment: .top) { Rectangle().fill(palette.separator).frame(height: 1) }
        }
    }
}
