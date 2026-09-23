import AVFoundation
import Foundation

/// 背面カメラで EAN-13 を読む。**確定の判定は `ScanGate` に任せる**（同じロジックをここに書かない）。
///
/// Web 版は 150ms ごとに1フレーム見て `ScanGate.feed` へ渡していた。AVFoundation は
/// 「読めたとき」に呼ばれる作りなので、こちらも 150ms の刻みで自分から feed する。
/// **何も写っていないフレームを渡さないと「一度カメラから外れた」が判定できない**ので、
/// 直前の読み取りが古くなったら空配列を渡す。
@Observable
final class ScanCamera: NSObject, AVCaptureMetadataOutputObjectsDelegate {

    enum Phase: Equatable {
        /// 起動前・止めた後（文字があれば止まった理由）
        case idle(String)
        case starting
        case running
        /// カメラが許可されていない
        case denied
        case failed(String)
    }

    /// 直前の読み取りを「いま写っている」とみなす長さ（1フレームの読み損じで外れたことにしない）
    private static let freshness: TimeInterval = 0.4
    private static let tick: TimeInterval = 0.15

    var phase: Phase = .idle("")
    /// この回に入れた冊数
    var count = 0

    @ObservationIgnored let session = AVCaptureSession()
    /// 確定した ISBN（呼ばれるのはメインスレッド）
    @ObservationIgnored var onConfirm: ((String) -> Void)?
    /// 登録の通信中は読み取りを止める
    @ObservationIgnored var busy = false

    @ObservationIgnored private let gate = ScanGate()
    @ObservationIgnored private let queue = DispatchQueue(label: "jp.kechiiiiin.nobu.camera")
    @ObservationIgnored private var configured = false
    @ObservationIgnored private var latest: (codes: [String], at: TimeInterval) = ([], 0)
    @ObservationIgnored private var ticker: Timer?

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: - 起動・停止

    func start() {
        switch phase {
        case .starting, .running: return
        default: break
        }
        phase = .starting
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            open()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted { self.open() } else { self.phase = .denied }
                }
            }
        default:
            phase = .denied
        }
    }

    func stop(_ reason: String = "") {
        ticker?.invalidate()
        ticker = nil
        latest = ([], 0)
        let session = session
        queue.async { if session.isRunning { session.stopRunning() } }
        phase = .idle(reason)
    }

    /// 取り消した・登録に失敗した本を、一度カメラから外すまで読み直さない
    func holdUntilGone(_ isbn: String) {
        gate.holdUntilGone(isbn, now: now)
    }

    private func open() {
        let session = session
        queue.async { [weak self] in
            guard let self else { return }
            if !self.configured {
                do {
                    try self.configure()
                    self.configured = true
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    DispatchQueue.main.async { self.phase = .failed(message) }
                    return
                }
            }
            if !session.isRunning { session.startRunning() }
            DispatchQueue.main.async {
                self.phase = .running
                self.startTicker()
            }
        }
    }

    private enum CameraError: LocalizedError {
        case noDevice
        case noOutput
        var errorDescription: String? {
            switch self {
            case .noDevice: return "カメラが見つかりませんでした"
            case .noOutput: return "カメラの読み取りを用意できませんでした"
            }
        }
    }

    private func configure() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { throw CameraError.noDevice }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { throw CameraError.noOutput }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        // 書籍のバーコードは EAN-13 の2段組み。2段目（192…）は ScanGate（ISBN）側で捨てる
        output.metadataObjectTypes = output.availableMetadataObjectTypes.contains(.ean13) ? [.ean13] : []
    }

    // MARK: - 読み取り

    private func startTicker() {
        ticker?.invalidate()
        let timer = Timer(timeInterval: Self.tick, target: self, selector: #selector(onTick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    @objc private func onTick() { feed() }

    private func feed() {
        guard case .running = phase, !busy else { return }
        let now = now
        let codes = now - latest.at < Self.freshness ? latest.codes : []
        if let isbn = gate.feed(codes, now: now) { onConfirm?(isbn) }
    }

    /// ⚠️ 呼ばれるのは**メインスレッド**（`setMetadataObjectsDelegate` に `.main` を渡している）。
    /// ここでは覚えるだけで、確定の判定は 150ms ごとの `feed()` が `ScanGate` に任せる。
    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        latest = (metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }, now)
    }
}
