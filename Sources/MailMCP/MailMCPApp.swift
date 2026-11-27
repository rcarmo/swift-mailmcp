import AppKit

final class MailMCPApp: NSObject, NSApplicationDelegate {
    typealias StartServer = (String, URL, @escaping (Result<Void, Error>) -> Void) throws -> (HTTPServer, String)

    private let startServer: StartServer
    private var server: HTTPServer?
    private var endpoint: String?
    private var tokenSettings: TokenSettings?
    private var currentToken: String?
    private var statusItem: NSStatusItem?
    private let menuStatus = NSMenuItem(title: "Starting server…", action: nil, keyEquivalent: "")
    private let status = NSTextField(labelWithString: "Starting server…")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let tokenField = NSSecureTextField()
    private let tokenMessage = NSTextField(wrappingLabelWithString: "")
    private let setTokenButton = NSButton(title: "Set Token", target: nil, action: nil)
    private let copyTokenButton = NSButton(title: "Copy Token", target: nil, action: nil)
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 490, height: 235),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)

    private init(startServer: @escaping StartServer) {
        self.startServer = startServer
    }

    static func run(startServer: @escaping StartServer) {
        let app = NSApplication.shared
        let delegate = MailMCPApp(startServer: startServer)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenus()
        installWindow()
        window.makeKeyAndOrderFront(nil)

        do {
            let settings = try TokenSettings()
            tokenSettings = settings
            tokenField.isEnabled = settings.isEditable
            setTokenButton.isEnabled = settings.isEditable
            if !settings.isEditable { tokenMessage.stringValue = "Token supplied by MAILMCP_TOKEN." }
            let token = try settings.load()
            currentToken = token
            tokenField.stringValue = token
            copyTokenButton.isEnabled = true
            startListening(token: token, directory: settings.directory)
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            updateStatus(.failure(error))
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showStatus()
        return true
    }

    private func installMenus() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "MailMCP")
        appMenu.addItem(withTitle: "Quit MailMCP", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu

        let menu = NSMenu()
        menu.addItem(menuStatus)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show Status", action: #selector(showStatus), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit MailMCP", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "envelope", accessibilityDescription: "MailMCP")
        item.button?.toolTip = "MailMCP"
        item.menu = menu
        statusItem = item
    }

    private func installWindow() {
        window.title = "MailMCP"
        window.isReleasedWhenClosed = false
        window.center()
        status.font = .systemFont(ofSize: 18, weight: .semibold)
        detail.textColor = .secondaryLabelColor
        detail.isSelectable = true

        let tokenTitle = NSTextField(labelWithString: "Bearer token")
        tokenTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        tokenField.placeholderString = "Enter a new token"
        tokenField.setAccessibilityLabel("Bearer token")
        tokenField.isEnabled = false
        setTokenButton.isEnabled = false
        setTokenButton.target = self
        setTokenButton.action = #selector(saveToken)
        copyTokenButton.isEnabled = false
        copyTokenButton.target = self
        copyTokenButton.action = #selector(copyToken)
        tokenMessage.textColor = .secondaryLabelColor
        tokenMessage.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let controls = NSStackView(views: [tokenField, setTokenButton, copyTokenButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        let separator = NSBox()
        separator.boxType = .separator
        let stack = NSStackView(views: [status, detail, separator, tokenTitle, controls, tokenMessage])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(16, after: detail)
        stack.setCustomSpacing(14, after: separator)
        stack.translatesAutoresizingMaskIntoConstraints = false
        guard let content = window.contentView else { return }
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            controls.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tokenMessage.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        window.initialFirstResponder = nil
    }

    @objc private func showStatus() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func saveToken() {
        guard let tokenSettings else { return }
        let token = tokenField.currentEditor()?.string ?? tokenField.stringValue
        do {
            try tokenSettings.save(token)
            currentToken = token
            copyTokenButton.isEnabled = true
            window.makeFirstResponder(nil)
            tokenField.stringValue = token
            if let server {
                server.setToken(token)
            } else {
                startListening(token: token, directory: tokenSettings.directory)
            }
            tokenMessage.stringValue = "Token saved. Update your MCP clients to use it."
        } catch {
            tokenMessage.stringValue = error.localizedDescription
        }
    }

    @objc private func copyToken() {
        guard let currentToken else { return }
        let item = NSPasteboardItem()
        item.setString(currentToken, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        NSPasteboard.general.clearContents()
        tokenMessage.stringValue = NSPasteboard.general.writeObjects([item])
            ? "Token copied to the clipboard." : "Could not copy the token."
    }

    private func startListening(token: String, directory: URL) {
        do {
            (server, endpoint) = try startServer(token, directory) { [weak self] result in
                DispatchQueue.main.async { self?.updateStatus(result) }
            }
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            updateStatus(.failure(error))
        }
    }

    private func updateStatus(_ result: Result<Void, Error>) {
        switch result {
        case .success:
            status.stringValue = "Server running"
            detail.stringValue = endpoint ?? ""
        case .failure(let error):
            server = nil
            status.stringValue = "Server unavailable"
            detail.stringValue = error.localizedDescription
        }
        menuStatus.title = status.stringValue
        statusItem?.button?.toolTip = "MailMCP: \(status.stringValue)"
    }
}
