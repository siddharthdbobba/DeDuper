import SwiftUI

struct ScanProgressView: View {
    @ObservedObject var viewModel: ReviewViewModel

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "photo.stack")
                .font(.system(size: 70))
                .foregroundStyle(.blue)
                .symbolEffect(.pulse, options: .repeating)

            if case .scanning(let progress, let message, let phase, let eta) = viewModel.scanState {
                VStack(spacing: 6) {
                    Text(phase.rawValue)
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(message)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .animation(nil, value: message)
                }

                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 360)
                    .animation(.easeOut(duration: 0.4), value: progress)

                HStack(spacing: 24) {
                    HStack(spacing: 4) {
                        Image(systemName: "percent").font(.caption2).foregroundStyle(.secondary)
                        Text("\(Int(progress * 100))%")
                            .font(.caption.monospacedDigit())
                    }
                    if let eta {
                        HStack(spacing: 4) {
                            Image(systemName: "clock").font(.caption2).foregroundStyle(.secondary)
                            Text(formatETA(eta))
                                .font(.caption.monospacedDigit())
                        }
                    }
                }
                .foregroundStyle(.secondary)

                Button(role: .cancel) {
                    viewModel.cancelScan()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                        .frame(width: 120)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .keyboardShortcut(.cancelAction)
                .padding(.top, 8)

#if os(iOS)
                Label("Keep the app open while scanning", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 4)
#endif
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func formatETA(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total <= 5  { return "Almost done" }
        if total < 60  { return "~\(total)s remaining" }
        let minutes = total / 60
        let secs    = total % 60
        if secs == 0   { return "~\(minutes)m remaining" }
        return "~\(minutes)m \(secs)s remaining"
    }
}
