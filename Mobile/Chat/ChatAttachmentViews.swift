import SwiftUI
import UIKit

extension EnvironmentValues {
    /// Opens an attachment full screen (`ChatThreadView`'s preview); nil where nothing previews.
    @Entry var chatOpenAttachment: ((ChatAttachment) -> Void)? = nil
}

/// A user message with attachments (docs/ios.md, Attachments): image thumbnails in a grid and file chips on the user's
/// side above the text bubble, as iMessage puts photos above a message. Without text only the attachments show.
struct ChatUserMessage: View {
    let text: String
    var attachments: [ChatAttachment] = []
    var host: UUID? = nil
    var read: (@MainActor (String) async throws -> Data?)? = nil
    var faded = false
    @Environment(\.chatSearchMarks) private var marks
    @Environment(\.chatSearchCurrent) private var current

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if !attachments.isEmpty {
                ChatMessageAttachments(attachments: attachments, host: host, read: read, faded: faded)
            }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachments.isEmpty {
                ChatBubble(side: .user, faded: faded) {
                    if var marker = ChatSearchMarker(marks, current: current) { Text(marker.mark(text)) } else { Text(text) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// A message's attachments, right-aligned within the user's bubble width: images first (one large, else up to four
/// a row), then file chips. A tap opens one (`chatOpenAttachment`).
struct ChatMessageAttachments: View {
    let attachments: [ChatAttachment]
    var host: UUID?
    var read: (@MainActor (String) async throws -> Data?)?
    var faded = false
    @Environment(\.chatColumnWidth) private var column
    @Environment(\.chatMeasure) private var measure
    @Environment(\.chatOpenAttachment) private var open

    static let spacing: CGFloat = 4
    static let columns = 4

    /// A tile's side for `count` images in a bubble at most `width` wide: one large, else up to four a row.
    static func tile(count: Int, width: CGFloat) -> CGFloat {
        if count <= 1 { return min(220, width * 0.8).rounded() }
        let columns = CGFloat(min(count, Self.columns))
        return min(110, ((width - spacing * (columns - 1)) / columns).rounded(.down))
    }

    var body: some View {
        let width = ChatMeasure.bubble(user: true, column: column, measure: measure)
        let images = attachments.filter { $0.kind == .image }
        let files = attachments.filter { $0.kind == .file }
        let side = Self.tile(count: images.count, width: width)
        VStack(alignment: .trailing, spacing: Self.spacing) {
            ForEach(Array(stride(from: 0, to: images.count, by: Self.columns)), id: \.self) { start in
                HStack(spacing: Self.spacing) {
                    ForEach(images[start..<min(start + Self.columns, images.count)]) { image in
                        Button { open?(image) } label: {
                            ChatAttachmentTile(attachment: image, host: host, read: read, side: side)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Image, \(image.name)")
                    }
                }
            }
            ForEach(files) { file in
                Button { open?(file) } label: { ChatFileChip(attachment: file).frame(maxWidth: width, alignment: .trailing) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("File, \(file.name)")
            }
        }
        .opacity(faded ? 0.55 : 1)
    }
}

/// One image: its thumbnail, else one fetched from the host, else a placeholder with the photo symbol.
struct ChatAttachmentTile: View {
    let attachment: ChatAttachment
    var host: UUID?
    var read: (@MainActor (String) async throws -> Data?)?
    let side: CGFloat
    var corner: CGFloat = 16
    private var thumbnails: MobileAttachmentThumbnails { .shared }

    var body: some View {
        let image = thumbnails.image(attachment, host: host, read: read)
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.faintFill
                Image(systemName: "photo").font(.system(size: min(28, side / 3))).foregroundStyle(.secondary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(Color.hairline, lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

/// A file: the document symbol, its name and size.
struct ChatFileChip: View {
    let attachment: ChatAttachment
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.fill").font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.name).font(.subheadline.weight(.medium)).lineLimit(1).truncationMode(.middle)
                if !attachment.sizeText.isEmpty {
                    Text(attachment.sizeText).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.bubbleAgent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// What the composer's strip shows and does (`CodeComposer.attachments`): stored attachments and running uploads, the
/// last error, and the actions. Nil on the composer: attaching is not offered (the helper lacks the feature, the
/// conversation is not live, or the draft is a command).
struct ComposerAttachments {
    struct Chip: Identifiable, Equatable {
        let id: String
        var name: String
        var kind: ChatAttachment.Kind
        var detail: String = ""
        var thumbnail: Data?
        var uploading = false
        var error: String?
    }
    var chips: [Chip] = []
    var error: String?
    /// "+", paste and drop take files now.
    var enabled = true
    /// How many more a message takes.
    var remaining = ChatAttachment.maximumCount
    var add: ([MobileAttachmentSource]) -> Void = { _ in }
    var remove: (String) -> Void = { _ in }
    var retry: (String) -> Void = { _ in }
    var open: (String) -> Void = { _ in }
    var dismissError: () -> Void = {}

    /// The session's draft attachments, then that draft's uploads.
    @MainActor static func chips(_ session: MobileChatSession) -> [Chip] {
        session.drafts.current.attachments.map {
            Chip(id: $0.id, name: $0.name, kind: $0.kind, detail: $0.sizeText, thumbnail: $0.thumbnail)
        } + session.draftUploads.map {
            Chip(id: $0.id, name: $0.name, kind: $0.kind, thumbnail: $0.thumbnail, uploading: $0.error == nil, error: $0.error)
        }
    }
}

/// The strip above the composer's field: a chip per attachment (thumbnail or document, a spinner while it uploads,
/// Retry after a failure, ✕ to remove), and the last error under it. A tap opens a stored one.
struct ComposerAttachmentStrip: View {
    let attachments: ComposerAttachments
    static let height: CGFloat = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !attachments.chips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments.chips) { chip in ComposerAttachmentChip(chip: chip, attachments: attachments) }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                }
                .frame(height: Self.height)
                .scrollClipDisabled()
            }
            if let error = attachments.error ?? attachments.chips.lazy.compactMap(\.error).first {
                Button(action: attachments.dismissError) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.destructive)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .accessibilityIdentifier("composer-attachment-error")
            }
        }
        .accessibilityIdentifier("composer-attachments")
    }
}

private struct ComposerAttachmentChip: View {
    let chip: ComposerAttachments.Chip
    let attachments: ComposerAttachments
    private static let side: CGFloat = 50

    var body: some View {
        content
            .opacity(chip.uploading ? 0.6 : 1)
            .overlay {
                if chip.uploading { ProgressView() }
                else if chip.error != nil {
                    Button { attachments.retry(chip.id) } label: {
                        Image(systemName: "arrow.clockwise.circle.fill").font(.title2).symbolRenderingMode(.multicolor)
                            .foregroundStyle(.white, Color.destructive)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Retry \(chip.name)")
                }
            }
            .overlay(alignment: .topTrailing) {
                Button { attachments.remove(chip.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .frame(width: 18, height: 18)
                        .background(Color.primary.opacity(0.75), in: Circle())
                        // A 32 point target around the small glyph.
                        .padding(7)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .offset(x: 13, y: -13)
                .accessibilityLabel("Remove \(chip.name)")
            }
            .onTapGesture { if !chip.uploading, chip.error == nil { attachments.open(chip.id) } }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(chip.name + (chip.uploading ? ", uploading" : chip.error != nil ? ", failed" : ""))
    }

    @ViewBuilder private var content: some View {
        if chip.kind == .image || chip.thumbnail != nil {
            ChatAttachmentTile(attachment: ChatAttachment(id: chip.id, name: chip.name, kind: .image, size: 0, path: nil,
                                                          thumbnail: chip.thumbnail),
                               side: Self.side, corner: 10)
        } else {
            HStack(spacing: 6) {
                Image(systemName: "doc.fill").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(chip.name).font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    if !chip.detail.isEmpty { Text(chip.detail).font(.caption2).foregroundStyle(.secondary) }
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: 160, minHeight: Self.side, maxHeight: Self.side, alignment: .leading)
            .background(Color.faintFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

/// An attachment full screen: an image at the size the host keeps (its thumbnail until that arrives, or instead of it
/// when the host's copy cannot be read; without either, why), a file's name, size and host path.
struct MobileAttachmentPreview: View {
    let attachment: ChatAttachment
    /// The conversation's host, whose thumbnail cache may hold a smaller copy.
    var host: UUID?
    var read: (@MainActor (String) async throws -> Data?)?
    @State private var full: UIImage?
    /// Why the host's copy did not come (none named, gone, unreadable); nil while it may still.
    @State private var missing: String?
    @Environment(\.dismiss) private var dismiss

    /// What shows until the full image arrives, or instead of it.
    private var thumbnail: UIImage? {
        attachment.thumbnail.flatMap(UIImage.init(data:))
            ?? MobileAttachmentThumbnails.shared.image(attachment, host: host, read: nil)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if attachment.kind == .image {
                    Color.black.ignoresSafeArea()
                    if let image = full ?? thumbnail {
                        Image(uiImage: image).resizable().scaledToFit().ignoresSafeArea(edges: .bottom)
                            .accessibilityLabel("Image, \(attachment.name)")
                    } else if let missing {
                        VStack(spacing: 10) {
                            Image(systemName: "photo").font(.system(size: 48))
                            Text(missing).multilineTextAlignment(.center)
                        }
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(24)
                        .accessibilityIdentifier("attachment-preview-missing")
                    } else {
                        ProgressView().tint(.white)
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.fill").font(.system(size: 48)).foregroundStyle(.secondary)
                        Text(attachment.name).font(.headline).multilineTextAlignment(.center)
                        if !attachment.sizeText.isEmpty { Text(attachment.sizeText).foregroundStyle(.secondary) }
                        if let path = attachment.path {
                            Text(path).font(.footnote.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(24)
                }
            }
            .navigationTitle(attachment.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(attachment.kind == .image ? .visible : .automatic, for: .navigationBar)
            .toolbarColorScheme(attachment.kind == .image ? .dark : nil, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .task {
            guard attachment.kind == .image else { return }
            missing = nil
            guard let path = attachment.path else { missing = Self.gone; return }
            guard let read else { missing = Self.unreachable; return }
            do {
                guard let data = try await read(path) else { missing = Self.unreachable; return }
                let image = await Task.detached(priority: .userInitiated) { UIImage(data: data)?.preparingForDisplay() }.value
                if let image { full = image } else { missing = Self.gone }
            } catch let failure as HelperFailure where MobileAttachmentThumbnails.permanent.contains(failure.code) {
                missing = Self.gone
            } catch {
                missing = Self.unreachable
            }
        }
    }

    static let gone = "Not available on the host any more."
    static let unreachable = "The host's copy cannot be read right now."
}
