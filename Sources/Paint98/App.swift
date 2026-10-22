import AppKit
import PaintCore

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var controller: MainController?
    private var pendingOpen: [URL] = []
    private var launched = false

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMainMenu()
        let c = MainController()
        controller = c
        c.show()
        NSApp.activate(ignoringOtherApps: true)
        launched = true
        if let url = pendingOpen.first { c.open(url) }
        pendingOpen.removeAll()

        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest") {
            let path = i + 1 < args.count ? args[i + 1] : NSTemporaryDirectory() + "paint98-selftest"
            SelfTest(controller: c, outputDir: URL(fileURLWithPath: path)).start()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if launched, let c = controller {
            c.open(url)
            c.show()
        } else {
            pendingOpen = [url]
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // しまったウインドウ・隠したアプリでも確認する（閉じたウインドウだけは確認済み）
        guard let c = controller, !c.isClosed else { return .terminateNow }
        c.commitText()
        return c.confirmDiscard() ? .terminateNow : .terminateCancel
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - メニュー

    private func item(_ title: String, _ action: Selector?, _ key: String = "",
                      _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        return i
    }

    private func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let m = NSMenu(title: title)
        for i in items { m.addItem(i) }
        let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        top.submenu = m
        return top
    }

    private var sep: NSMenuItem { .separator() }

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()
        let appName = "ペイント 98"

        let services = NSMenuItem(title: "サービス", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "サービス")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        main.addItem(menu(appName, [
            item("\(appName)について", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "", []),
            sep,
            services,
            sep,
            item("\(appName)を隠す", #selector(NSApplication.hide(_:)), "h"),
            item("ほかを隠す", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("すべてを表示", #selector(NSApplication.unhideAllApplications(_:)), "", []),
            sep,
            item("\(appName)を終了", #selector(NSApplication.terminate(_:)), "q"),
        ]))

        main.addItem(menu("ファイル", [
            item("新規", #selector(MainController.paintNew(_:)), "n"),
            item("開く…", #selector(MainController.paintOpen(_:)), "o"),
            sep,
            item("上書き保存", #selector(MainController.paintSave(_:)), "s"),
            item("名前を付けて保存…", #selector(MainController.paintSaveAs(_:)), "s", [.command, .shift]),
            sep,
            item("ファイルから貼り付け…", #selector(MainController.pasteFromFile(_:))),
            item("選択範囲をファイルへ保存…", #selector(MainController.copyToFile(_:))),
            sep,
            item("閉じる", #selector(NSWindow.performClose(_:)), "w"),
        ]))

        main.addItem(menu("編集", [
            // 標準の undo: / redo: / paste: にしておくと、フォントパネルやダイアログの入力欄でも ⌘Z / ⌘V が効く。
            // キャンバス（CanvasView）と文字の入力欄（PaintTextView）がそれぞれ受け取る
            item("元に戻す", #selector(CanvasView.undo(_:)), "z"),
            item("やり直し", #selector(CanvasView.redo(_:)), "z", [.command, .shift]),
            sep,
            item("切り取り", #selector(MainController.cut(_:)), "x"),
            item("コピー", #selector(MainController.copy(_:)), "c"),
            item("貼り付け", #selector(NSText.paste(_:)), "v"),
            item("位置を指定して貼り付け…", #selector(MainController.pasteAtPosition(_:)), "v", [.command, .shift]),
            item("新規画像として貼り付け", #selector(MainController.pasteAsNewImage(_:)), "v", [.command, .option]),
            sep,
            item("選択範囲のクリア（delete キー）", #selector(MainController.delete(_:))),
            item("すべて選択", #selector(MainController.selectAll(_:)), "a"),
            sep,
            item("新規キャンバスへの貼り付けで画像サイズに合わせる", #selector(MainController.toggleFitPaste(_:))),
        ]))

        let zoomEq = item("拡大", #selector(MainController.zoomIn(_:)), "=")
        zoomEq.isHidden = true
        zoomEq.allowsKeyEquivalentWhenHidden = true
        main.addItem(menu("表示", [
            item("ツールボックス", #selector(MainController.toggleToolbox(_:)), "t"),
            item("カラーボックス", #selector(MainController.toggleColorBox(_:)), "l"),
            item("ステータスバー", #selector(MainController.toggleStatusBar(_:))),
            sep,
            item("拡大", #selector(MainController.zoomIn(_:)), "+"),
            zoomEq,
            item("縮小", #selector(MainController.zoomOut(_:)), "-"),
            item("実際のサイズ", #selector(MainController.actualSize(_:)), "0"),
            item("グリッドを表示", #selector(MainController.toggleGrid(_:)), "g"),
            sep,
            item("フォントパネル", #selector(MainController.showFontPanel(_:))),
        ]))

        main.addItem(menu("イメージ", [
            item("反転と回転…", #selector(MainController.flipRotate(_:)), "r"),
            item("伸縮…", #selector(MainController.stretch(_:))),
            item("色の反転", #selector(MainController.invertColors(_:)), "i"),
            item("キャンバスのサイズ…", #selector(MainController.canvasSize(_:)), "e"),
            item("選択範囲でトリミング", #selector(MainController.cropToSelection(_:)), "x", [.command, .shift]),
            item("イメージのクリア", #selector(MainController.clearImage(_:)), "n", [.command, .shift]),
            sep,
            item("不透明な描画", #selector(MainController.toggleOpaque(_:))),
        ]))

        main.addItem(menu("色", [
            item("色の編集…", #selector(MainController.editColors(_:))),
            item("描画色と背景色を入れ替え", #selector(MainController.swapColors(_:)), "k"),
        ]))

        let windowItem = menu("ウインドウ", [
            item("しまう", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("拡大／縮小", #selector(NSWindow.performZoom(_:)), "", []),
        ])
        NSApp.windowsMenu = windowItem.submenu
        main.addItem(windowItem)

        let helpItem = menu("ヘルプ", [
            item("ペイント 98 の使い方", #selector(MainController.showHelp(_:)), "?"),
        ])
        NSApp.helpMenu = helpItem.submenu
        main.addItem(helpItem)
        return main
    }
}
