import Foundation

private func storedToken(in directory: URL) throws -> String? {
    let url = directory.appendingPathComponent("token")
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    if fd < 0 && errno == ENOENT { return nil }
    guard fd >= 0 else { throw Failure("Cannot open MailMCP token file (errno \(errno)).") }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
          info.st_mode & 0o077 == 0 else {
        throw Failure("MailMCP token file must be a regular file owned by this user with owner-only permissions.")
    }
    let data = try file.read(upToCount: 514) ?? Data()
    guard data.count < 514 else { throw Failure("MailMCP token file is too large.") }
    return String(data: data, encoding: .ascii)?.trimmingCharacters(in: .newlines)
}

do {
    if CommandLine.arguments.dropFirst() == ["--authorize-mail"] {
        try Mail().authorize()
        print("Mail Automation is authorized.")
    } else {
        guard CommandLine.arguments.count == 1 else { throw Failure("Usage: MailMCP [--authorize-mail]") }
        let environment = ProcessInfo.processInfo.environment
        let stateDirectory: URL
        if let path = environment["MAILMCP_STATE_DIR"] {
            guard path.hasPrefix("/") else { throw Failure("MAILMCP_STATE_DIR must be an absolute path.") }
            stateDirectory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            stateDirectory = MoveOperations.defaultDirectory
        }
        guard let token = try environment["MAILMCP_TOKEN"] ?? storedToken(in: stateDirectory), (32...512).contains(token.utf8.count),
              token.utf8.allSatisfy({ (33...126).contains($0) && $0 != 44 }) else {
            throw Failure("Set MAILMCP_TOKEN or create the owner-only MailMCP token file in Application Support. Generate a token with openssl rand -hex 32.")
        }
        guard let port = UInt16(environment["MAILMCP_PORT"] ?? "8765"), port != 0 else {
            throw Failure("MAILMCP_PORT must be between 1 and 65535.")
        }
        let server = try HTTPServer(port: port, token: token, stateDirectory: stateDirectory)
        let handoff = try (environment["MAILMCP_HANDOFF_OPERATIONS"] ?? "").split(separator: ",").map { value in
            guard let id = UUID(uuidString: String(value)) else { throw Failure("Invalid move handoff ID.") }
            return id
        }
        try server.start(handoff: handoff)
        withExtendedLifetime(server) { RunLoop.main.run() }
    }
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
