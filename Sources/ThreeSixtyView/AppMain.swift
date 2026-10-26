#if os(macOS)
import AppKit
import ProjectionMath
import ThreeSixtyEngine

@main
enum AppEntry {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            Task {
                var code = portableSelfTest()
                do {
                    try await MacRoundTrip.runAll()
                } catch {
                    fputs("MAC ROUND TRIP FAILED: \(error)\n", stderr)
                    code = 1
                }
                exit(code)
            }
            dispatchMain()
        }
        if let index = CommandLine.arguments.firstIndex(of: "--write-fixtures"),
           CommandLine.arguments.count > index + 1 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            do {
                try writeFixtures(to: directory)
                exit(0)
            } catch {
                fputs("\(error)\n", stderr)
                exit(1)
            }
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        AppDelegate.keepAlive = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var keepAlive: AppDelegate?
    let controller = MainWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMenu()
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        controller.showWindow(nil)
        controller.model.openDropped(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func makeMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About ThreeSixtyView", action: #selector(MainWindowController.showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit ThreeSixtyView", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let file = NSMenu(title: "File")
        fileItem.submenu = file
        file.addItem(item("Open…", #selector(MainWindowController.openDocument(_:)), "o"))
        file.addItem(item("Open Folder…", #selector(MainWindowController.openFolder(_:)), "O"))
        file.addItem(item("Add Back Lens…", #selector(MainWindowController.addBackLens(_:)), ""))
        file.addItem(.separator())
        file.addItem(item("Export Still…", #selector(MainWindowController.exportStill(_:)), "S"))
        file.addItem(item("Export View…", #selector(MainWindowController.exportView(_:)), "E"))
        file.addItem(item("Export YouTube 360…", #selector(MainWindowController.exportYouTube(_:)), ""))
        file.addItem(item("Trim Original…", #selector(MainWindowController.trimOriginal(_:)), ""))
        file.addItem(item("Record View Path", #selector(MainWindowController.toggleRecord(_:)), "R"))
        file.addItem(item("Join Clips…", #selector(MainWindowController.joinClips(_:)), ""))
        file.addItem(item("Stills to Video…", #selector(MainWindowController.stillsToVideo(_:)), ""))

        let unfoldItem = NSMenuItem()
        main.addItem(unfoldItem)
        let unfold = NSMenu(title: "Unfold")
        unfoldItem.submenu = unfold
        for mode in UnfoldMode.allCases {
            let entry = NSMenuItem(title: mode.title, action: #selector(MainWindowController.chooseUnfold(_:)), keyEquivalent: "")
            entry.tag = Int(mode.rawValue)
            entry.target = controller
            unfold.addItem(entry)
        }
        unfold.addItem(.separator())
        unfold.addItem(item("Reset View", #selector(MainWindowController.resetView(_:)), "0"))
        return main
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = controller
        return entry
    }
}
#endif
