import SwiftUI
import UIKit

struct MessageBubble: View {
    let message: Message
    var senderName: String? = nil
    var progress: Double? = nil
    var imageData: Data? = nil
    var onRetry: (() -> Void)?
    var onRetryMedia: (() -> Void)?

    var body: some View {
        HStack {
            if message.isFromMe { Spacer(minLength: 48) }

            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                if let senderName, !message.isFromMe {
                    Text(senderName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(GlassTheme.accent)
                        .padding(.horizontal, 4)
                }

                if message.isImage {
                    imageContent
                } else {
                    textContent
                }

                if message.isFromMe {
                    statusRow
                }
            }

            if !message.isFromMe { Spacer(minLength: 48) }
        }
        .padding(.horizontal, GlassTheme.spacing)
        .padding(.vertical, 2)
    }

    private var textContent: some View {
        Text(message.text)
            .font(.body)
            .foregroundStyle(message.isFromMe ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: GlassTheme.bubbleRadius, style: .continuous)
                    .fill(message.isFromMe ? GlassTheme.outgoingBubble : GlassTheme.incomingBubble)
            )
    }

    @ViewBuilder
    private var imageContent: some View {
        VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 6) {
            ZStack {
                if let imageData, let uiImage = UIImage(data: imageData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: 240, maxHeight: 280)
                        .clipped()
                } else if let thumb = message.thumbnailData, let uiImage = UIImage(data: thumb) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: 240, maxHeight: 280)
                        .clipped()
                        .overlay {
                            if message.mediaTransfer != .ready {
                                transferOverlay
                            }
                        }
                } else {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 180, height: 140)
                        .overlay {
                            transferOverlay
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            if message.text != "Photo", !message.text.isEmpty {
                Text(message.text)
                    .font(.subheadline)
                    .foregroundStyle(message.isFromMe ? Color.white : Color.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(message.isFromMe ? GlassTheme.outgoingBubble : GlassTheme.incomingBubble)
                    )
            }

            if !message.isFromMe, message.mediaTransfer == .failed || message.mediaTransfer == .pending {
                Button {
                    onRetryMedia?()
                } label: {
                    Label(
                        message.mediaTransfer == .pending
                            ? "Waiting for nearby link"
                            : "Retry download",
                        systemImage: message.mediaTransfer == .pending
                            ? "antenna.radiowaves.left.and.right"
                            : "arrow.clockwise"
                    )
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(GlassTheme.accent)
            }
        }
    }

    private var transferOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
            VStack(spacing: 8) {
                if message.mediaTransfer == .pending {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.white)
                } else {
                    ProgressView(value: progress ?? 0)
                        .progressViewStyle(.circular)
                        .tint(.white)
                }
                Text(progressLabel)
                    .font(.caption2)
                    .foregroundStyle(.white)
            }
        }
    }

    private var progressLabel: String {
        switch message.mediaTransfer {
        case .pending:
            return "Need direct link"
        case .failed:
            return "Failed"
        case .ready:
            return "Ready"
        case .none, .transferring:
            let value = progress ?? 0
            if value <= 0 { return "Downloading…" }
            if value >= 1 { return "Ready" }
            return "\(Int(value * 100))%"
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 4) {
            switch message.status {
            case .pending:
                Image(systemName: "clock")
            case .sent:
                Image(systemName: "checkmark")
            case .delivered:
                Image(systemName: "checkmark.circle.fill")
            case .failed:
                Button {
                    onRetry?()
                } label: {
                    Label("Retry", systemImage: "exclamationmark.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}
