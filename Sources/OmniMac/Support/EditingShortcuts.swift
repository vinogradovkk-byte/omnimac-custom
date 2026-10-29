import AppKit

/// ⌘V, ⌘C, ⌘X, ⌘A y ⌘Z en los campos de texto de OmniMac. La app no tiene menú «Edición» (vive en la barra de menús, sin
/// `mainMenu`), y sin él macOS no traduce estos atajos: no se podía pegar un token en el notch ni en sus popovers.
/// Se envían al campo que tenga el foco. Va por código de tecla, no por carácter, para que valga con cualquier distribución
/// del teclado (en la rusa la V es «м»).
enum EditingShortcuts {
    enum Action: Equatable { case paste, copy, cut, selectAll, undo, redo }

    static func action(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Action? {
        // Caps Lock, Fn y teclas del teclado numérico los cuela macOS sin que el usuario los pulse.
        let relevant = modifiers.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .function, .numericPad])
        guard relevant == [.command] || relevant == [.command, .shift] else { return nil }
        let shifted = relevant.contains(.shift)
        switch keyCode {
        case 9 where !shifted: return .paste
        case 8 where !shifted: return .copy
        case 7 where !shifted: return .cut
        case 0 where !shifted: return .selectAll
        case 6: return shifted ? .redo : .undo
        default: return nil
        }
    }

    /// Файлы или картинка в буфере обмена (скопированы в Finder или скриншот в буфер): их нельзя вставить текстом,
    /// поэтому поле комментария Asana забирает их как вложения. Возвращает адреса готовых временных файлов.
    static let pasteAttachmentsNotification = Notification.Name("com.seergiii.omnimac.pasteAttachments")

    static func attachmentsOnPasteboard(_ pasteboard: NSPasteboard = .general) -> [URL] {
        let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !files.isEmpty { return files }
        // Картинка без текста: скриншот, скопированный в буфер. Текст рядом означает обычную вставку.
        guard pasteboard.string(forType: .string) == nil,
              let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff),
              let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) else { return [] }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Скриншот \(formatter.string(from: Date())).png")
        return (try? png.write(to: url)) != nil ? [url] : []
    }

    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let action = action(keyCode: event.keyCode, modifiers: event.modifierFlags),
                  let window = event.window ?? NSApp.keyWindow, window.firstResponder is NSTextView else { return event }
            if action == .paste, window.firstResponder is NSTextView {
                let urls = attachmentsOnPasteboard()
                if !urls.isEmpty {
                    // Заберёт то поле, у которого сейчас фокус; если такого нет, вставка пройдёт как обычно.
                    var taken = false
                    NotificationCenter.default.post(name: pasteAttachmentsNotification, object: nil, userInfo: ["urls": urls, "taken": { taken = true } as () -> Void])
                    if taken { return nil }
                }
            }
            let selector: Selector
            switch action {
            case .paste: selector = #selector(NSText.paste(_:))
            case .copy: selector = #selector(NSText.copy(_:))
            case .cut: selector = #selector(NSText.cut(_:))
            case .selectAll: selector = #selector(NSText.selectAll(_:))
            case .undo: selector = Selector(("undo:"))
            case .redo: selector = Selector(("redo:"))
            }
            return NSApp.sendAction(selector, to: window.firstResponder, from: nil) ? nil : event
        }
    }
}
