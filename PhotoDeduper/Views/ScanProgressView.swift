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

                // Reassurance line. Hashing + scoring a large library legitimately
                // runs for minutes, and a bar that creeps with no context reads as
                // "stuck/frozen" — users were force-quitting mid-scan. Shown only
                // until an ETA is available: once `formatETA` is giving a concrete
                // "~Nm remaining" the wait is self-explanatory, so this generic
                // caption would just be noise stacked under a real number.
                if eta == nil {
                    Text("Large libraries can take a few minutes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button(role: .cancel) {
                    viewModel.cancelScan()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                        .frame(width: 120)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                // .cancelAction already binds Esc to this button (verified live on
                // macOS), so cancelling by keyboard works today — it was just
                // invisible. The .help tooltip and the caption below ADVERTISE it
                // without touching the wiring, so the affordance is discoverable
                // whether the user reaches for the mouse or the keyboard.
                .keyboardShortcut(.cancelAction)
                .help("Cancel scan (Esc)")
                .padding(.top, 8)

                Text("Press Esc to cancel.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

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
