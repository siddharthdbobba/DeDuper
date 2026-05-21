import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ReviewViewModel()

    var body: some View {
        Group {
            switch viewModel.scanState {
            case .idle:
                SplashView(viewModel: viewModel)
            case .scanning:
                ScanProgressView(viewModel: viewModel)
            case .reviewing:
                ReviewView(viewModel: viewModel)
            case .done(let kept, let deleted, let freed):
                DoneView(keptCount: kept, deletedCount: deleted, freedBytes: freed, viewModel: viewModel)
            case .error(let msg):
                ErrorView(message: msg, viewModel: viewModel)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.scanState.tag)
    }
}

extension ScanState {
    var tag: Int {
        switch self {
        case .idle: 0
        case .scanning: 1
        case .reviewing: 2
        case .done: 3
        case .error: 4
        }
    }
}

struct ErrorView: View {
    let message: String
    @ObservedObject var viewModel: ReviewViewModel

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.orange)
            Text("Something went wrong")
                .font(.title2.bold())
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Button("Try Again") { viewModel.reset() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
