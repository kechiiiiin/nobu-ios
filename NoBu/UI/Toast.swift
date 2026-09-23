import SwiftUI

/// 画面の下に出る短い知らせ。書影つき・「取り消す」つきにできる（Web 版の showToast と同じ役目）。
struct Toast: Identifiable {
    let id = UUID()
    var text: String
    var title: String?
    var coverURL: String?
    /// 「取り消す」を押したときの処理。nil ならボタンを出さない
    var undo: (@MainActor () async -> Void)?
    /// 自動で消えるまでの秒数（取り消しつきは長め）
    var seconds: Double = 5
}

@MainActor
@Observable
final class ToastCenter {
    var current: Toast?
    private var dismissTask: Task<Void, Never>?

    func show(_ toast: Toast) {
        dismissTask?.cancel()
        current = toast
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(toast.seconds))
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }

    func show(_ text: String) { show(Toast(text: text)) }

    func error(_ error: Error) {
        if error is CancellationError { return }
        show(Toast(text: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
    }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }
}

struct ToastOverlay: View {
    @Environment(ToastCenter.self) private var toasts
    @State private var busy = false

    var body: some View {
        if let toast = toasts.current {
            HStack(spacing: 10) {
                if let cover = toast.coverURL {
                    CoverView(url: cover, title: toast.title ?? "", size: .tiny)
                }
                VStack(alignment: .leading, spacing: 2) {
                    if let title = toast.title {
                        Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(toast.text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if let undo = toast.undo {
                    Button("取り消す") {
                        guard !busy else { return }
                        busy = true
                        Task {
                            await undo()
                            busy = false
                            toasts.dismiss()
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(busy)
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(radius: 8, y: 2)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onTapGesture { if toast.undo == nil { toasts.dismiss() } }
        }
    }
}
