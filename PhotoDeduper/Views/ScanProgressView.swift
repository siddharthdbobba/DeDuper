import SwiftUI

struct ScanProgressView: View {
    @ObservedObject var viewModel: ReviewViewModel

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "photo.stack")
                .font(.system(size: 70))
                .foregroundStyle(.blue)
                .symbolEffect(.pulse, options: .repeating)

            if case .scanning(let progress, let message) = viewModel.scanState {
                Text(message)
                    .font(.headline)
                    .animation(nil, value: message)

                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 320)
                    .animation(.easeOut(duration: 0.4), value: progress)

                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

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
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
