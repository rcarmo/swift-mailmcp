import Foundation

struct TokenSettings {
    let directory: URL
    private let override: String?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        if let path = environment["MAILMCP_STATE_DIR"] {
            guard path.hasPrefix("/") else { throw Failure("MAILMCP_STATE_DIR must be an absolute path.") }
            directory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            directory = MoveOperations.defaultDirectory
        }
        override = environment["MAILMCP_TOKEN"]
    }

    var isEditable: Bool { override == nil }
    private var file: URL { directory.appendingPathComponent("token") }

    func load() throws -> String {
        if let override {
            try Self.validate(override)
            return override
        }
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 && errno == ENOENT {
            throw Failure("Set a bearer token to start the server.")
        }
        guard fd >= 0 else { throw Failure("Cannot open the MailMCP token file (errno \(errno)).") }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0 else {
            throw Failure("MailMCP token file must be a regular file owned by this user with owner-only permissions.")
        }
        let data = try input.read(upToCount: 514) ?? Data()
        guard data.count < 514, let token = String(data: data, encoding: .ascii)?.trimmingCharacters(in: .newlines) else {
            throw Failure("The MailMCP token file is too large or contains non-ASCII characters.")
        }
        try Self.validate(token)
        return token
    }

    func save(_ token: String) throws {
        guard isEditable else { throw Failure("The active token is set by MAILMCP_TOKEN.") }
        try Self.validate(token)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Create the replacement with mode 0600 before writing any secret bytes, then swap it in atomically.
        var template = Array(directory.appendingPathComponent(".token.XXXXXXXX").path.utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw Failure("Cannot create a private token file (errno \(errno)).") }
        let temporary = String(cString: template)
        defer { unlink(temporary) }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try output.write(contentsOf: Data((token + "\n").utf8))
        try output.close()
        guard rename(temporary, file.path) == 0 else {
            throw Failure("Cannot replace the MailMCP token file (errno \(errno)).")
        }
    }

    private static func validate(_ token: String) throws {
        guard (32...512).contains(token.utf8.count),
              token.utf8.allSatisfy({ (33...126).contains($0) && $0 != 44 }) else {
            throw Failure("Use 32 to 512 printable ASCII characters without spaces or commas.")
        }
    }
}
