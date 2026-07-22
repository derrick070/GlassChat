import SwiftUI

struct MessageBubble: View {
    let message: Message
    var onRetry: (() -> Void)?

    var body: some View {
        HStack {
            if message.isFromMe { Spacer(minLength: 48) }

            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(message.isFromMe ? Color.white : Color.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: GlassTheme.bubbleRadius, style: .continuous)
                            .fill(message.isFromMe ? GlassTheme.outgoingBubble : GlassTheme.incomingBubble)
                    )

                if message.isFromMe {
                    statusRow
                }
            }

            if !message.isFromMe { Spacer(minLength: 48) }
        }
        .padding(.horizontal, GlassTheme.spacing)
        .padding(.vertical, 2)
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
