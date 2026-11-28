import Core
import Persistence
import SwiftUI

/// The slim banner at the top of the library: sync progress while a sync runs, otherwise a prompt when a
/// source needs to be linked again. See docs/UI_SPEC.md (sync banner) and docs/REMOTE_SOURCES.md#robustness.
struct SyncBanner: View {
    @Environment(\.appEnvironment) private var environment
    @Environment(SyncCoordinator.self) private var sync
    @State private var needingRelink: [LibrarySource] = []

    var body: some View {
        Group {
            if let progress = sync.current, let status = SyncStatusText.running(progress) {
                banner {
                    ProgressView().controlSize(.small)
                    Text("\(progress.kind.serviceName): \(status)")
                }
            } else if let source = needingRelink.first {
                banner {
                    Image(systemName: "exclamationmark.triangle.fill").accessibilityHidden(true)
                    Text("\(source.kind.serviceName) needs to be linked again. Open Settings to choose the folder.")
                }
            }
        }
        .task {
            guard let environment else { return }
            do {
                for try await sources in environment.repositories.sources.observeSources() {
                    needingRelink = sources.filter { $0.status == .needsRelink }
                }
            } catch {
                needingRelink = []
            }
        }
    }

    private func banner(@ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8) {
            content()
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }
}
