import Foundation

private func startServer(token: String, stateDirectory: URL,
                         onStatus: ((Result<Void, Error>) -> Void)? = nil) throws -> (HTTPServer, String) {
    let environment = ProcessInfo.processInfo.environment
    guard let port = UInt16(environment["MAILMCP_PORT"] ?? "8765"), port != 0 else {
        throw Failure("MAILMCP_PORT must be between 1 and 65535.")
    }
    let handoff = try (environment["MAILMCP_HANDOFF_OPERATIONS"] ?? "").split(separator: ",").map { value in
        guard let id = UUID(uuidString: String(value)) else { throw Failure("Invalid move handoff ID.") }
        return id
    }
    let server = try HTTPServer(port: port, token: token, stateDirectory: stateDirectory, onStatus: onStatus)
    try server.start(handoff: handoff)
    return (server, "http://127.0.0.1:\(port)/mcp")
}

do {
    let arguments = CommandLine.arguments.dropFirst()
    switch Array(arguments) {
    case ["--authorize-mail"]:
        try Mail().authorize()
        print("Mail Automation is authorized.")
    case [] where Bundle.main.bundleURL.pathExtension == "app":
        MailMCPApp.run(startServer: startServer)
    case [], ["--headless"]:
        let settings = try TokenSettings()
        let (server, _) = try startServer(token: settings.load(), stateDirectory: settings.directory)
        withExtendedLifetime(server) { RunLoop.main.run() }
    default:
        throw Failure("Usage: MailMCP [--authorize-mail | --headless]")
    }
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
