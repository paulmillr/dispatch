import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The composer's attach control, before the microphone: an open panel for any number of files (⇧⌘A from the
/// composer). Shown only when the conversation's helper keeps attachments (`ChatSession.acceptsAttachments`).
struct ChatAttachButton: View {
    @Environment(\.chatTheme) private var theme
    let session: ChatSession
    let coordinator: ChatCoordinator

    var body: some View {
        let size = max(24, theme.typography.detailLineHeight + 10)
        let enabled = coordinator.canAttach(session)
        Button { Self.choose(session: session, coordinator: coordinator) } label: {
            Image(systemName: "paperclip")
                .font(.system(size: theme.typography.detailSize + 1, weight: .medium))
                .foregroundStyle(theme.muted.opacity(enabled ? 1 : 0.45))
                .frame(width: size, height: size)
                .contentShape(Rectangle())
                .hoverFill(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help(enabled: enabled))
        .accessibilityLabel("Attach files")
        .accessibilityIdentifier("chat-attach")
    }

    private func help(enabled: Bool) -> String {
        if enabled { return "Attach files or images · ⇧⌘A · or drop or paste them" }
        if session.draftIsCommand { return "Commands take no attachments" }
        if session.editingQueuedID != nil { return "A queued message keeps its attachments" }
        return "Attachments are unavailable right now"
    }

    /// The open panel, as a sheet on the chat's window: the files it returns are read in this process and uploaded.
    static func choose(session: ChatSession, coordinator: ChatCoordinator, window: NSWindow? = nil) {
        guard coordinator.canAttach(session) else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        panel.prompt = "Attach"
        panel.message = "Choose files or images to send to \(session.agentTitle)."
        let finish: (NSApplication.ModalResponse) -> Void = { [weak session] response in
            guard response == .OK, let session else { return }
            coordinator.attach(panel.urls.map { .file($0) }, to: session)
            session.focusRequest = System.uuid()
        }
        if let window = window ?? NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(panel.runModal()) }
    }
}

/// The draft's attachments above the editor: stored ones, uploads still running (spinner) or failed (retry), and why
/// the last attach was refused.
struct ChatComposerAttachments: View {
    @Environment(\.chatTheme) private var theme
    @MotionReduced private var reduceMotion
    let session: ChatSession
    let coordinator: ChatCoordinator

    /// A chip: an attachment of the draft, or one still uploading (or failed). An upload that lands keeps its id, so
    /// its chip stays put as it becomes the attachment.
    private struct Chip: Identifiable {
        let attachment: ChatAttachment
        var upload: ChatAttachmentUpload? = nil
        var id: String { attachment.id }
    }

    /// The row's height in the composer, for the editor's height bound.
    static func height(_ session: ChatSession, theme: ChatTheme) -> CGFloat {
        let chips = session.drafts.shape.hasAttachments || !session.draftUploads.isEmpty
        return (chips ? chipHeight(theme) + 6 : 0) + (session.attachmentError != nil ? theme.typography.detailLineHeight + 4 : 0)
    }

    static func chipHeight(_ theme: ChatTheme) -> CGFloat { max(32, theme.typography.detailLineHeight * 2 + 6) }

    var body: some View {
        let endpoint = session.helper?.endpoint
        VStack(alignment: .leading, spacing: 4) {
            if session.drafts.shape.hasAttachments || !session.draftUploads.isEmpty {
                let attachments = session.drafts.current.attachments
                let chips = attachments.map { Chip(attachment: $0) } + session.draftUploads
                    .filter { upload in !attachments.contains { $0.id == upload.id } }
                    .map { Chip(attachment: $0.attachment, upload: $0) }
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(chips) { chip in
                            if let upload = chip.upload {
                                ChatAttachmentChip(attachment: upload.attachment, endpoint: nil, uploading: upload.uploading,
                                                   sent: upload.sent, failure: upload.failure,
                                                   open: { if upload.thumbnail != nil { ChatAttachmentPreview.shared.open(upload.attachment, endpoint: nil) } },
                                                   remove: { coordinator.removeAttachment(upload.id, from: session) },
                                                   retry: { coordinator.retryAttachment(upload.id, in: session) })
                                    .transition(chipTransition)
                            } else {
                                ChatAttachmentChip(attachment: chip.attachment, endpoint: endpoint,
                                                   open: { ChatAttachmentPreview.shared.open(chip.attachment, endpoint: endpoint) },
                                                   remove: { coordinator.removeAttachment(chip.attachment.id, from: session) })
                                    .transition(chipTransition)
                            }
                        }
                    }
                    // Pasted, dropped, removed and landed chips change outside any animation; the row's own does.
                    .animation(InterfaceMotion.animation(reduce: reduceMotion, duration: 0.2),
                               value: chips.map { "\($0.id) \($0.upload?.uploading == true) \($0.upload?.failure != nil)" })
                }
                // Never, not hidden: with scroll bars shown always (no trackpad) hidden still draws one.
                .scrollIndicators(.never)
                .frame(height: Self.chipHeight(theme))
                .accessibilityIdentifier("chat-attachments")
            }
            if let error = session.attachmentError {
                Button { session.attachmentError = nil } label: {
                    Label(error, systemImage: "exclamationmark.triangle.fill").labelStyle(.titleAndIcon)
                        .foregroundStyle(theme.red).lineLimit(1).truncationMode(.tail)
                        .hoverFill(RoundedRectangle(cornerRadius: 4), outset: 3)
                }.buttonStyle(.plain).help("Dismiss")
                    .font(theme.typography.detail)
                    .accessibilityIdentifier("chat-attachment-error")
            }
        }
        .padding(.horizontal, 12).padding(.top, 6)
    }

    private var chipTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.85, anchor: .leading).combined(with: .opacity)
    }
}

/// One attachment as a chip: thumbnail or document icon, name and size; click previews it, × removes it.
struct ChatAttachmentChip: View {
    @Environment(\.chatTheme) private var theme
    let attachment: ChatAttachment
    let endpoint: HelperWorkspace.Endpoint?
    var uploading = false
    /// While uploading: the share written to the helper's connection (ChatAttachmentUpload.sent).
    var sent: Double?
    var failure: String?
    let open: () -> Void
    var remove: (() -> Void)?
    var retry: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: open) {
                HStack(spacing: 6) {
                    ChatAttachmentThumbnail(attachment: attachment, endpoint: endpoint, side: 22)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(attachment.name).lineLimit(1).truncationMode(.middle)
                        if let failure {
                            Text(failure).foregroundStyle(theme.red).lineLimit(1).truncationMode(.tail)
                        } else if uploading {
                            Text(uploadStatus).foregroundStyle(theme.muted).monospacedDigit()
                        } else if !attachment.sizeText.isEmpty {
                            Text(attachment.sizeText).foregroundStyle(theme.muted)
                        }
                    }.frame(maxWidth: 160, alignment: .leading)
                }
            }.buttonStyle(DraftButtonStyle(foreground: theme.ink, hover: theme.ink))
                .help(failure ?? (attachment.sizeText.isEmpty ? attachment.name : "\(attachment.name) · \(attachment.sizeText)"))
            if uploading, let sent, sent < 1 {
                // Determinate while the bytes go out; all written, the host stores them and the spinner takes over.
                ProgressView(value: sent).progressViewStyle(.circular).controlSize(.mini)
                    .accessibilityLabel("Uploading").accessibilityValue("\(Int(sent * 100)) percent")
            } else if uploading {
                ProgressView().controlSize(.mini).accessibilityLabel("Uploading")
            } else if let retry, failure != nil {
                Button(action: retry) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(DraftButtonStyle(foreground: theme.muted, hover: theme.ink))
                    .help("Try again").accessibilityLabel("Upload \(attachment.name) again")
            }
            if let remove {
                Button(action: remove) { Image(systemName: "xmark").imageScale(.small) }
                    .buttonStyle(DraftButtonStyle(foreground: theme.muted, hover: theme.ink))
                    .help("Remove").accessibilityLabel("Remove \(attachment.name)")
                    .accessibilityIdentifier("chat-attachment-remove-\(attachment.id)")
            }
        }
        .font(theme.typography.font(offset: -1.5))
        .padding(.horizontal, 6)
        .frame(height: ChatComposerAttachments.chipHeight(theme))
        .background(theme.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-attachment-\(attachment.id)")
    }
}

extension ChatAttachmentChip {
    /// "Uploading…" while the file is read, "Uploading 42%" as it is written, "Finishing…" once all of it is out and
    /// the host is still receiving or storing it.
    var uploadStatus: String {
        guard let sent else { return "Uploading…" }
        return sent < 1 ? "Uploading \(Int(sent * 100))%" : "Finishing…"
    }
}

/// An attachment's picture: its thumbnail (kept, or read from the host), else the file type's icon or a placeholder.
struct ChatAttachmentThumbnail: View {
    @Environment(\.chatTheme) private var theme
    let attachment: ChatAttachment
    let endpoint: HelperWorkspace.Endpoint?
    let side: CGFloat
    /// Aspect fit within `side` (a single image in a message) rather than a square crop.
    var fit = false

    var body: some View {
        if let image = ChatAttachmentThumbnails.shared.image(attachment, endpoint: endpoint) {
            Image(nsImage: image).resizable()
                .aspectRatio(contentMode: fit ? .fit : .fill)
                .frame(maxWidth: side, maxHeight: side)
                .frame(width: fit ? nil : side, height: fit ? nil : side)
                .clipShape(RoundedRectangle(cornerRadius: side > 40 ? 8 : 4))
        } else if attachment.kind == .file {
            Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (attachment.name as NSString).pathExtension) ?? .data))
                .resizable().frame(width: side, height: side)
        } else {
            RoundedRectangle(cornerRadius: side > 40 ? 8 : 4).fill(theme.ink.opacity(0.08))
                .frame(width: side, height: fit ? side * 0.75 : side)
                .overlay { Image(systemName: "photo").foregroundStyle(theme.muted) }
                .task(id: attachment.path) { ChatAttachmentThumbnails.shared.request(attachment, endpoint: endpoint) }
        }
    }
}

/// A user message's attachments above its text: images in a grid of up to four a row (one alone keeps its shape),
/// files as chips. Click previews.
struct ChatMessageAttachments: View {
    @Environment(\.chatTheme) private var theme
    let attachments: [ChatAttachment]
    let endpoint: HelperWorkspace.Endpoint?
    let maxWidth: CGFloat
    var alignment: HorizontalAlignment = .trailing

    var body: some View {
        let images = attachments.filter { $0.kind == .image }, files = attachments.filter { $0.kind == .file }
        VStack(alignment: alignment, spacing: 6) {
            if images.count == 1, let image = images.first {
                tile(image, side: min(160, maxWidth), fit: true)
            } else if !images.isEmpty {
                let side = max(48, min(120, (maxWidth - 18) / 4))
                ForEach(Array(stride(from: 0, to: images.count, by: 4)), id: \.self) { start in
                    HStack(spacing: 6) {
                        ForEach(images[start..<min(start + 4, images.count)]) { tile($0, side: side, fit: false) }
                    }
                }
            }
            ForEach(files) { file in
                ChatAttachmentChip(attachment: file, endpoint: endpoint,
                                   open: { ChatAttachmentPreview.shared.open(file, endpoint: endpoint) })
            }
        }
    }

    private func tile(_ attachment: ChatAttachment, side: CGFloat, fit: Bool) -> some View {
        Button { ChatAttachmentPreview.shared.open(attachment, endpoint: endpoint) } label: {
            ChatAttachmentThumbnail(attachment: attachment, endpoint: endpoint, side: side, fit: fit)
        }.buttonStyle(.plain)
            .help(attachment.name)
            .accessibilityLabel("Image \(attachment.name)")
            .accessibilityIdentifier("chat-attachment-\(attachment.id)")
    }
}

/// Files and images dropped anywhere on the chat's pane attach to the draft, as on the composer. Rows of a files view
/// (paths already on a host) are left to the composer, which types them.
struct ChatAttachmentDrop: DropDelegate {
    let session: ChatSession
    let coordinator: ChatCoordinator

    func validateDrop(info: DropInfo) -> Bool {
        coordinator.canAttach(session) && !info.itemProviders(for: [.item]).contains {
            $0.hasItemConformingToTypeIdentifier(NSPasteboard.PasteboardType.filesPaths.rawValue)
        }
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else { return }
        ChatAttachmentDrag.entered(session, composer: false, pasteboard: NSPasteboard(name: .drag))
    }

    func dropExited(info: DropInfo) { ChatAttachmentDrag.exited(session, composer: false) }

    func dropUpdated(info: DropInfo) -> DropProposal? { validateDrop(info: info) ? DropProposal(operation: .copy) : nil }

    func performDrop(info: DropInfo) -> Bool {
        session.attachmentDrag = nil
        guard validateDrop(info: info) else { return false }
        let providers = info.itemProviders(for: [.fileURL, .image])
        guard !providers.isEmpty else { return false }
        let session = session, coordinator = coordinator
        Task { @MainActor in
            var sources: [ChatAttachmentSource] = []
            for provider in providers {
                if let source = await Self.source(provider) { sources.append(source) }
            }
            coordinator.attach(sources, to: session)
        }
        return true
    }

    /// A dropped file's URL, else the image data a browser or app drags (named for its type).
    private static func source(_ provider: NSItemProvider) async -> ChatAttachmentSource? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url: URL? = await withCheckedContinuation { done in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in done.resume(returning: url) }
            }
            if let url, url.isFileURL { return .file(url) }
        }
        guard let type = provider.registeredTypeIdentifiers.compactMap(UTType.init).first(where: { $0.conforms(to: .image) }) else { return nil }
        let data: Data? = await withCheckedContinuation { done in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in done.resume(returning: data) }
        }
        guard let data, !data.isEmpty else { return nil }
        let base = provider.suggestedName ?? "Dropped image"
        let name = (base as NSString).pathExtension.isEmpty ? base + "." + (type.preferredFilenameExtension ?? "png") : base
        return .data(name: name, data)
    }
}

/// Files or images being dragged over a chat's pane, while they are: what the composer shows it will take
/// (`ChatComposerDropWell`). AppKit hands a drag to one destination at a time, the composer's text view or, everywhere
/// else in the pane, SwiftUI's drop (`ChatAttachmentDrop`); the drag is over the pane while either has it, so moving
/// between them never lets the well fall.
struct ChatAttachmentDrag: Equatable {
    struct Item: Equatable {
        let name: String
        let image: Bool
        /// Bytes, when the file says (a dropped folder does not).
        let size: Int?

        /// "PNG · 412 KB".
        var detail: String {
            let ext = (name as NSString).pathExtension.uppercased()
            let kind = ext.isEmpty ? (image ? "Image" : "File") : ext
            guard let size, size > 0 else { return kind }
            return kind + " · " + ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        }
    }

    var items: [Item]
    var overPane = false
    var overComposer = false
    var active: Bool { overPane || overComposer }

    /// What a drop of `pasteboard` would attach, as `ChatAttachmentSource.read` reads it: nothing for rows of a files
    /// view and for text.
    @MainActor static func items(_ pasteboard: NSPasteboard) -> [Item] {
        ChatAttachmentSource.read(pasteboard).map { source in
            switch source {
            case .file(let url):
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
                let image = values?.contentType?.conforms(to: .image) ?? UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
                return Item(name: source.name, image: image, size: values?.fileSize)
            case .data(let name, let data):
                return Item(name: name, image: true, size: data.count)
            }
        }
    }

    /// The drag reached one of the pane's two targets; nothing happens for a drag that would not attach.
    @MainActor static func entered(_ session: ChatSession, composer: Bool, pasteboard: NSPasteboard) {
        let items = session.attachmentDrag?.items ?? Self.items(pasteboard)
        guard !items.isEmpty else { return }
        var drag = session.attachmentDrag ?? ChatAttachmentDrag(items: items)
        if composer { drag.overComposer = true } else { drag.overPane = true }
        if session.attachmentDrag != drag { session.attachmentDrag = drag }
    }

    /// The drag left one target (or ended there); over neither, it is gone.
    @MainActor static func exited(_ session: ChatSession, composer: Bool) {
        guard var drag = session.attachmentDrag else { return }
        if composer { drag.overComposer = false } else { drag.overPane = false }
        session.attachmentDrag = drag.active ? drag : nil
    }
}

/// The composer grown over the pane while files are dragged over it (mockups/Mac D2): its own surface (glass or panel,
/// with its borders) runs up to the pane's top over a backing that hides the transcript, outlined in the accent, and
/// the room it gained shows what it will take as chips, with the host a remote chat uploads them to. The surface is
/// the composer's background; what it shows is an overlay, above the composer's content (which stays below it), where
/// accessibility reads it. Not a target itself: the pane's drop (`ChatAttachmentDrop`) and the composer's text view
/// take the drop.
struct ChatComposerDropWell<Surface: View>: ViewModifier {
    @Environment(\.chatTheme) private var theme
    @MotionReduced private var reduceMotion
    let drag: ChatAttachmentDrag?
    /// Where the grown composer's top stops, in `ChatFlightFrames.space`.
    let top: CGFloat
    /// The remote host the chat's helper runs on; nil on this Mac.
    let host: HostRecord?
    /// Attachments the draft holds or is uploading (a message carries at most `ChatAttachment.maximumCount`).
    let attached: Int
    @ViewBuilder let surface: () -> Surface

    func body(content: Content) -> some View {
        let drag = drag?.active == true ? drag : nil
        let shape = RoundedRectangle(cornerRadius: LiquidGlassStore.shared.active ? 12 : 8, style: .continuous)
        content
            .background {
                grown(drag) { _ in
                    ZStack {
                        if drag != nil { shape.fill(theme.terminal.opacity(0.94)) }
                        surface()
                        if drag != nil {
                            shape.fill(theme.accent.opacity(0.04))
                            shape.stroke(theme.accent.opacity(0.08), lineWidth: 8)
                            shape.strokeBorder(theme.accent.opacity(0.8), lineWidth: 1.5)
                        }
                    }
                }
                .allowsHitTesting(false)
            }
            .overlay {
                if let drag {
                    grown(drag) { gained in
                        contents(drag).frame(height: gained).opacity(gained > 80 ? 1 : 0)
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .allowsHitTesting(false)
                }
            }
            .animation(InterfaceMotion.animation(reduce: reduceMotion, duration: 0.2), value: drag != nil)
    }

    /// `layer` over the composer and the room it gained above it, up to `top`, while a drag is over the pane.
    private func grown<Layer: View>(_ drag: ChatAttachmentDrag?, @ViewBuilder _ layer: @escaping (CGFloat) -> Layer) -> some View {
        GeometryReader { proxy in
            let gained = drag == nil ? 0 : max(0, proxy.frame(in: .named(ChatFlightFrames.space)).minY - top)
            layer(gained)
                .frame(width: proxy.size.width, height: proxy.size.height + gained)
                .offset(y: -gained)
        }
    }

    private func contents(_ drag: ChatAttachmentDrag) -> some View {
        let tooMany = attached + drag.items.count > ChatAttachment.maximumCount
        return VStack(spacing: 14) {
            ViewThatFits(in: .horizontal) {
                ForEach([3, 2, 1, 0], id: \.self) { shown in chips(drag.items, shown: shown) }
            }
            VStack(spacing: 5) {
                Text("Add to message").font(theme.typography.font(offset: 3, weight: .semibold)).foregroundStyle(theme.ink)
                if tooMany {
                    Text(ChatAttachmentError.tooMany.localizedDescription).foregroundStyle(theme.red)
                } else if let host {
                    let tint = host.tint?.foreground ?? theme.muted
                    HStack(spacing: 5) {
                        Text("Uploaded to")
                        HostGlyph(host: host, size: theme.typography.detailSize + 1).foregroundStyle(tint)
                        Text(host.name).foregroundStyle(tint)
                    }
                }
            }
            .font(theme.typography.detail).foregroundStyle(theme.muted)
            .multilineTextAlignment(.center)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label(drag, tooMany: tooMany))
        .accessibilityIdentifier("chat-attachment-drop")
    }

    /// The first `shown` items as chips, the rest counted; none shown, only the count.
    private func chips(_ items: [ChatAttachmentDrag.Item], shown: Int) -> some View {
        HStack(spacing: 10) {
            ForEach(Array(items.prefix(shown).enumerated()), id: \.offset) { _, item in chip(item) }
            if items.count > shown {
                Text(shown == 0 ? (items.count == 1 ? "1 file" : "\(items.count) files") : "+\(items.count - shown) more")
                    .font(theme.typography.detail).foregroundStyle(theme.muted).fixedSize()
            }
        }
    }

    private func chip(_ item: ChatAttachmentDrag.Item) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        let side = theme.typography.pointSize(offset: 6) * 1.5
        return HStack(spacing: 9) {
            Image(systemName: item.image ? "photo" : "doc").font(.system(size: theme.typography.pointSize(offset: 3)))
                .foregroundStyle(theme.accent)
                .frame(width: side, height: side)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.accent.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(theme.typography.font(offset: -1, weight: .medium)).foregroundStyle(theme.ink)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: theme.typography.pointSize() * 14, alignment: .leading)
                Text(item.detail).font(theme.typography.font(offset: -2.5)).foregroundStyle(theme.muted).lineLimit(1)
            }
            .fixedSize()
        }
        .padding(.leading, 6).padding(.trailing, 12).padding(.vertical, 6)
        .background(shape.fill(theme.terminal.opacity(0.5)))
        .overlay(shape.strokeBorder(theme.accent.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    private func label(_ drag: ChatAttachmentDrag, tooMany: Bool) -> String {
        let names = drag.items.map(\.name).joined(separator: ", ")
        if tooMany { return "Add to message: \(names). " + ChatAttachmentError.tooMany.localizedDescription }
        return "Add to message: \(names)" + (host.map { ", uploaded to \($0.name)" } ?? "")
    }
}
