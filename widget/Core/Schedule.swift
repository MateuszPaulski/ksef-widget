import Foundation

public enum RunSchedule {
    public static let interval: TimeInterval = 3600

    /// A last run in the future means the clock moved back, so it is due too.
    public static func isDue(lastRunAt: Date?, now: Date) -> Bool {
        guard let lastRunAt else { return true }
        // Whole milliseconds: Double dates an hour apart differ from 3600 by rounding noise.
        let elapsed = KsefTime.millis(now) - KsefTime.millis(lastRunAt)
        return elapsed < 0 || elapsed >= Int64(interval) * 1000
    }

    /// The later of the snapshot's `updatedAt` (any status) and the end of this process's last run.
    public static func lastRunAt(snapshot: URL, lastRunEnd: Date?) -> Date? {
        let written = readSnapshotStatus(snapshot)?.updatedAt
        guard let written, let lastRunEnd else { return written ?? lastRunEnd }
        return max(written, lastRunEnd)
    }
}

/// Main actor because the menu reads `isRunning` synchronously.
@MainActor
public final class RunGate {
    public private(set) var isRunning = false

    public init() {}

    /// False when another body is running; `body` is then not called.
    public func runIfIdle(_ body: () async -> Void) async -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        defer { isRunning = false }
        await body()
        return true
    }
}

public enum LegacyLaunchAgent {
    public static func isInstalled(_ paths: AppPaths) -> Bool {
        FileManager.default.fileExists(atPath: paths.legacyLaunchAgent.path)
    }
}
