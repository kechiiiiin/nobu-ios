import XCTest

/// 本棚の状態チップ（読んでる／買った／気になる／読了／保留）を**実際にタップして**確かめる。
///
/// 2026-09-24 の不具合はここが要る理由そのもの——チップは当たり判定も状態の切替えも生きていて、
/// **描かれていないだけ**だった。だから「タップできた」では足りない。選ばれているチップの
/// アクセントカラーが**画面に出ているか**（スクリーンショットの画素）まで見る。
///
/// ⚠️ ローカルの Worker（`cd ~/work/nobu && npm run dev`）が 127.0.0.1:8787 で動いていて、
/// `scripts/seed-local.sh` で検査用の本が入っていることが前提。実機・本番には一切触らない。`make uitest` で走る。
final class ShelfChipUITests: XCTestCase {

    private static let baseURL = "http://127.0.0.1:8787"

    override func setUp() { continueAfterFailure = false }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-nobuBaseURL", Self.baseURL,
            // ローカルは DEV_BYPASS_AUTH で素通りするので、中身は何でもよい（秘密ではない）
            "-nobuAccessId", "devdummy",
            "-nobuAccessSecret", "devdummy"
        ]
        app.launch()
        return app
    }

    @discardableResult
    private func shot(_ app: XCUIApplication, _ name: String) -> XCUIScreenshot {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return screenshot
    }

    /// `rect`（画面の座標）の中に「アクセントカラーらしい青」の画素があるか。
    /// 選ばれているチップは下地がアクセントカラーなので、描かれていれば必ず見つかる。
    private func hasAccentPixels(_ screenshot: XCUIScreenshot, in rect: CGRect, window: CGRect) -> Bool {
        guard let cg = screenshot.image.cgImage, window.width > 0 else { return false }
        let scale = CGFloat(cg.width) / window.width
        let box = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                         width: rect.width * scale, height: rect.height * scale)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard !box.isEmpty, let cropped = cg.cropping(to: box) else { return false }

        let width = cropped.width, height = cropped.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            if b > 150 && b > r + 60 && b > g + 30 { return true }
        }
        return false
    }

    func testShelfChipsAreVisibleAndSwitchTheList() throws {
        let app = launchApp()

        XCTAssertTrue(app.tabBars.buttons["本棚"].waitForExistence(timeout: 30), "下タブに本棚が無い")
        app.tabBars.buttons["本棚"].tap()

        let reading = app.buttons["shelf-chip-reading"]
        XCTAssertTrue(reading.waitForExistence(timeout: 30), "チップが出ない")
        let window = app.windows.firstMatch.frame

        // 既定は「読んでる」
        XCTAssertTrue(app.staticTexts["検査・読んでる"]
            .waitForExistence(timeout: 30), "既定の『読んでる』の本が出ていない")
        let first = shot(app, "1-reading")

        // ⚠️ ここが 2026-09-24 の不具合の本丸。押せるだけでは駄目で、**見えて**いること
        XCTAssertTrue(hasAccentPixels(first, in: reading.frame, window: window),
                      "チップが描かれていない（当たり判定はあるのに見えない）")

        // 読了
        let read = app.buttons["shelf-chip-read"]
        read.tap()
        XCTAssertTrue(app.staticTexts["検査・読了"].waitForExistence(timeout: 30),
                      "『読了』を押しても一覧が変わらない")
        let second = shot(app, "2-read")
        XCTAssertTrue(read.isSelected, "『読了』が選ばれた状態になっていない")
        XCTAssertTrue(hasAccentPixels(second, in: read.frame, window: window),
                      "『読了』が選ばれた見た目になっていない")

        // 保留
        let paused = app.buttons["shelf-chip-paused"]
        paused.tap()
        XCTAssertTrue(app.staticTexts["検査・保留"].waitForExistence(timeout: 30),
                      "『保留』を押しても一覧が変わらない")
        shot(app, "3-paused")
        XCTAssertTrue(paused.isSelected, "『保留』が選ばれた状態になっていない")

        // 買った
        let bought = app.buttons["shelf-chip-bought"]
        bought.tap()
        XCTAssertTrue(app.staticTexts["検査・買った"].waitForExistence(timeout: 30),
                      "『買った』を押しても一覧が変わらない")
        shot(app, "4-bought")

        // 気になる
        let want = app.buttons["shelf-chip-want"]
        want.tap()
        XCTAssertTrue(app.staticTexts["検査・気になる"].waitForExistence(timeout: 30),
                      "『気になる』を押しても一覧が変わらない")
        shot(app, "5-want")

        // 読んでるへ戻る
        reading.tap()
        XCTAssertTrue(app.staticTexts["検査・読んでる"]
            .waitForExistence(timeout: 30), "『読んでる』へ戻れない")
        shot(app, "6-back-to-reading")
    }

    /// 同じ作りが他の画面にも無いかの見回り（記録タブ・本のページ）。
    /// どちらもバーの下に `safeAreaInset` で帯を差し込んでいないので巻き添えは無いはずだが、
    /// 見た目が壊れていないことをスクリーンショットで残しておく。
    func testOtherScreensStillRender() throws {
        let app = launchApp()

        // 記録タブ（起動時はここ）
        XCTAssertTrue(app.staticTexts["検査・気になる"].waitForExistence(timeout: 30), "記録タブが出ない")
        shot(app, "7-timeline")

        // 本のページ（状態の5択は素の HStack）
        app.staticTexts["検査・気になる"].firstMatch.tap()
        for label in ["気になる", "買った", "読んでる", "保留", "読了"] {
            XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 30), "本のページに『\(label)』が無い")
        }
        shot(app, "8-book")
    }

    /// 記録タブの「同じ日に複数冊読んだ」行（2026-09-24 の不具合）。
    /// 以前は書影ごとに NavigationLink を入れ子にしていて、List が書影のあいだに「>」を並べ、
    /// 書名も「A／B」と繋げて崩れていた。いまは1冊の行と同じ形の**1つのリンク**で、押すとその日の一覧へ行く。
    /// 前提: `scripts/seed-local.sh` が 検査・読了／保留／買った を 2026-09-22 に読んだことにしている。
    func testMultiBookReadRowIsOneLink() throws {
        let app = launchApp()
        XCTAssertTrue(app.staticTexts["検査・気になる"].waitForExistence(timeout: 30), "記録タブが出ない")

        let row = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH '読んだ：' AND label CONTAINS '検査・保留' AND label CONTAINS '検査・読了'")).firstMatch
        for _ in 0..<8 where !(row.exists && row.isHittable) { app.swipeUp() }
        XCTAssertTrue(row.exists && row.isHittable, "複数冊の「読んだ」行が見つからない")
        shot(app, "9-timeline-multi-read")

        row.tap()
        XCTAssertTrue(app.navigationBars["2026-09-22 に読んだ本"].waitForExistence(timeout: 15),
                      "複数冊の行を押しても、その日の一覧が開かない")
        let item = { (title: String) in
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        }
        for title in ["検査・読了", "検査・保留", "検査・買った"] {
            XCTAssertTrue(item(title).waitForExistence(timeout: 15), "その日の一覧に『\(title)』が無い")
        }
        shot(app, "10-read-day")

        item("検査・保留").tap()
        XCTAssertTrue(app.buttons["保留"].waitForExistence(timeout: 30), "一覧から本のページへ行けない")
    }
}
