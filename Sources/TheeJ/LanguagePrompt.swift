#if canImport(AppKit)
import AppKit

// The first window a new install shows: the Mac's language, or English, to confirm or change. It speaks
// the language picked in it, and saves it on Continue.
final class LanguagePrompt: NSObject {
    private var language = Language.current
    private let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    private let heading = NSTextField(labelWithString: "")
    private let note = NSTextField(wrappingLabelWithString: "")
    private let picker = NSPopUpButton()
    private let done = NSButton(title: "", target: nil, action: nil)

    // Returns once Continue is clicked.
    func run() {
        heading.font = .boldSystemFont(ofSize: 16)
        note.textColor = .secondaryLabelColor
        note.alignment = .center
        // A fixed width, so the window only grows down when a language takes two lines.
        note.preferredMaxLayoutWidth = 280
        note.widthAnchor.constraint(equalToConstant: 280).isActive = true
        // Each language is named in itself, so it can always be found.
        for language in Language.allCases { picker.addItem(withTitle: "\(language.flag) \(language.name)") }
        picker.selectItem(at: Language.allCases.firstIndex(of: language) ?? 0)
        picker.target = self
        picker.action = #selector(pick)
        done.target = self
        done.action = #selector(finish)
        done.keyEquivalent = "\r"
        let icon = NSImageView(image: makeAppIcon(side: 64, scale: 2))
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let content = NSStackView(views: [icon, heading, picker, note, done])
        content.orientation = .vertical
        content.spacing = 12
        content.setCustomSpacing(20, after: note)
        content.edgeInsets = NSEdgeInsets(top: 24, left: 32, bottom: 24, right: 32)
        // A centred stack keeps only its top and bottom insets, so the sides are set here.
        content.widthAnchor.constraint(equalTo: note.widthAnchor, constant: 64).isActive = true
        window.contentView = content
        window.isReleasedWhenClosed = false
        name()
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()  // a menu bar app that has not finished launching may not be let in front
        NSApp.runModal(for: window)
        window.orderOut(nil)
    }

    private func name() {
        window.title = appName
        heading.stringValue = tr("choose_language", in: language)
        note.stringValue = tr("language_note", in: language)
        done.title = tr("continue", in: language)
        let top = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        window.setContentSize(window.contentView!.fittingSize)
        window.setFrameTopLeftPoint(top)
    }

    @objc private func pick() {
        language = Language.allCases[picker.indexOfSelectedItem]
        name()
    }

    @objc private func finish() {
        prefs.set(language.rawValue, forKey: "language")
        NSApp.stopModal()
    }
}
#endif
