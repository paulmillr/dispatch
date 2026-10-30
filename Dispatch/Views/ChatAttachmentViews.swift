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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                                                   failure: upload.failure,
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
                            Text("Uploading…").foregroundStyle(theme.muted)
                        } else if !attachment.sizeText.isEmpty {
                            Text(attachment.sizeText).foregroundStyle(theme.muted)
                        }
                    }.frame(maxWidth: 160, alignment: .leading)
                }
            }.buttonStyle(DraftButtonStyle(foreground: theme.ink, hover: theme.ink))
                .help(failure ?? (attachment.sizeText.isEmpty ? attachment.name : "\(attachment.name) · \(attachment.sizeText)"))
            if uploading {
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

/// Files and images dropped on the transcript attach to the draft, as on the composer. Rows of a files view (paths
/// already on a host) are left to the composer, which types them.
struct ChatAttachmentDrop: DropDelegate {
    let session: ChatSession
    let coordinator: ChatCoordinator

    func validateDrop(info: DropInfo) -> Bool {
        coordinator.canAttach(session) && !info.itemProviders(for: [.item]).contains {
            $0.hasItemConformingToTypeIdentifier(NSPasteboard.PasteboardType.filesPaths.rawValue)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { validateDrop(info: info) ? DropProposal(operation: .copy) : nil }

    func performDrop(info: DropInfo) -> Bool {
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
