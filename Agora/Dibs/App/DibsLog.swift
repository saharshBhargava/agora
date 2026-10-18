import Foundation
import os

/// Remote-debug log: each event goes to stdout as `DIBS: <time> <message>` (read with
/// `xcrun devicectl device process launch --console`) and to os_log, subsystem `dev.dibs.app`.
enum DibsLog {
    private static let logger = Logger(subsystem: "dev.dibs.app", category: "dibs")

    static func event(_ s: String) {
        let time = Date().formatted(.iso8601.time(includingFractionalSeconds: true))
        print("DIBS: \(time) \(s)")
        logger.log("\(s, privacy: .public)")
    }
}
