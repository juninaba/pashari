import AppKit

/// Pashari lives in the menu bar, so macOS never shows this menu, but the
/// shortcuts work all the same while one of Pashari's windows is in front.
/// Without it, ⌘W would not close Settings, and ⌘C and ⌘V would do nothing
/// in text fields such as the folder picker's.
enum MainMenu {
    static func make() -> NSMenu {
        let mainMenu = NSMenu()
        // The first menu is always the app menu. Pashari's stays empty: Quit
        // in it would make ⌘Q quit with an unsaved screenshot in the editor.
        mainMenu.addSubmenu(NSMenu(title: "Pashari"))
        mainMenu.addSubmenu(fileMenu())
        mainMenu.addSubmenu(editMenu())
        return mainMenu
    }

    // The titles are never shown, so they are not translated.

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        menu.addItem(withTitle: "Save", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        // Swift has no name for these two actions, so they are spelled out.
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return menu
    }
}

private extension NSMenu {
    func addSubmenu(_ submenu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
