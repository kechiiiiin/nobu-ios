import AVFoundation
import SwiftUI
import UIKit

/// スキャン。バーコードにかざすと「買った」で入り、5秒の「取り消す」が出る。
/// 登録してもカメラは止めない（そのまま次の本へ）。
struct ScanView: View {
    /// スキャンのタブが選ばれているか（別のタブへ移ったらカメラを止める）
    let isSelected: Bool

    @Environment(ToastCenter.self) private var toasts
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var camera = ScanCamera()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if case .running = camera.phase {
                CameraPreview(session: camera.session).ignoresSafeArea()
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.white.opacity(0.85), lineWidth: 3)
                    .frame(width: 260, height: 150)
                    .shadow(radius: 6)
            }
            VStack {
                Spacer()
                controls
            }
            .padding()
        }
        .navigationTitle("スキャン")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear {
            camera.onConfirm = { isbn in Task { await register(isbn) } }
        }
        .onDisappear { camera.stop() }
        .onChange(of: isSelected) { _, selected in
            if !selected { camera.stop() }
        }
        .onChange(of: scenePhase) { _, phase in
            // 別のアプリに切り替えると iOS はカメラを止める。黙って死なないよう起動ボタンに戻す
            if phase != .active { camera.stop("アプリを離れたのでカメラを止めました。もう一度起動してください。") }
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch camera.phase {
        case .running:
            HStack {
                Text(camera.count > 0 ? "読み取り中・この回 \(camera.count) 冊" : "読み取り中")
                    .font(.subheadline)
                Spacer()
                Button("止める") { camera.stop() }
                    .buttonStyle(.bordered)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        case .denied:
            panel(message: "カメラが許可されていません。設定アプリの「NoBu」からカメラを許可してください。") {
                Button("設定を開く") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        default:
            panel(message: message) {
                Button(startLabel) { camera.start() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(camera.phase == .starting)
            }
        }
    }

    private var startLabel: String { camera.phase == .starting ? "起動中…" : "カメラを起動" }

    private var message: String {
        switch camera.phase {
        case .idle(let reason) where !reason.isEmpty: return reason
        case .failed(let reason): return reason
        default:
            return "本の裏のバーコード（上の段・978…）にかざすと、「買った」で本棚に入ります。止めずに次の本へどうぞ。"
        }
    }

    private func panel<Content: View>(message: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 12) {
            Text(message).font(.callout).multilineTextAlignment(.center)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - 登録

    private func register(_ isbn: String) async {
        camera.busy = true
        defer { camera.busy = false }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        do {
            let result = try await NobuAPI.shared.addIsbn(isbn, status: .bought)
            if result.result == "already" {
                toasts.show(Toast(text: "もう持っています（\(result.book.status.label)）",
                                  title: result.book.title, coverURL: result.book.cover_url))
            } else {
                camera.count += 1
                toasts.show(Toast(
                    text: result.result == "advanced" ? "「気になる」→「買った」にしました" : "「買った」に入れました",
                    title: result.book.title,
                    coverURL: result.book.cover_url,
                    undo: result.event_id.map { eventID in
                        {
                            do {
                                _ = try await NobuAPI.shared.undo(eventId: eventID)
                                // 本がカメラの前に残っていても読み直さない（一度外してから戻せばまた読める）
                                camera.holdUntilGone(isbn)
                                camera.count = max(0, camera.count - 1)
                                model.shelfChanged()
                            } catch {
                                toasts.error(error)
                            }
                        }
                    }
                ))
            }
            model.shelfChanged()
        } catch {
            camera.holdUntilGone(isbn)
            toasts.error(error)
        }
    }
}

/// `AVCaptureVideoPreviewLayer` を SwiftUI に載せるだけの薄い入れ物
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        if view.previewLayer.session !== session { view.previewLayer.session = session }
    }
}
