import Foundation
import OSLog

struct CallTrace {
    private static let logger = Logger(subsystem: "net.rcarmo.mailmcp", category: "requests")
    private static let traceToStderr = ProcessInfo.processInfo.environment["MAILMCP_TRACE_STDERR"] == "1"
    let id: UUID
    let tool: String
    private let start = ProcessInfo.processInfo.systemUptime

    init(_ tool: String, id: UUID = UUID()) {
        self.tool = tool
        self.id = id
    }

    var elapsed: TimeInterval { ProcessInfo.processInfo.systemUptime - start }

    // Messages contain timings, Apple Event codes, and server-generated identifiers only.
    func log(_ event: String) {
        let line = "trace=\(id.uuidString) tool=\(tool) event=\(event) elapsed_ms=\(Int(elapsed * 1000))"
        Self.logger.notice("\(line, privacy: .public)")
        if Self.traceToStderr { fputs(line + "\n", stderr) }
    }
}
