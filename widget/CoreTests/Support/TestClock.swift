import Foundation
@testable import KsefCore

// Half a millisecond in, so that flooring back to milliseconds is exact whatever the Double arithmetic does.
private func date(millis: Int64) -> Date {
    Date(timeIntervalSince1970: (Double(millis) + 0.5) / 1000)
}

func instant(_ iso: String) -> Date {
    date(millis: KsefTime.millis(iso)!)
}

/// `now` is synchronous but `sleep` must move it, so the clock is a locked class and not an actor.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Int64
    private var slept: [Int] = []

    init(_ start: Date) { current = KsefTime.millis(start) }

    var now: Date {
        lock.withLock { date(millis: current) }
    }

    var sleeps: [Int] { lock.withLock { slept } }

    func sleep(_ milliseconds: Int) {
        lock.withLock {
            slept.append(milliseconds)
            current += Int64(milliseconds)
        }
    }
}

/// Mutable state shared with `@Sendable` closures in a test.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    func update<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&stored) }
    }
}

/// The message of the error `body` throws, nil when it does not throw.
func thrownMessage<T>(_ body: () async throws -> T) async -> String? {
    do {
        _ = try await body()
        return nil
    } catch {
        return errorMessage(error)
    }
}
