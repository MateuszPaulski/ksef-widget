import Foundation
@testable import KsefCore

func instant(_ iso: String) -> Date {
    Date(timeIntervalSince1970: Double(KsefTime.millis(iso)!) / 1000)
}

/// `now` is synchronous but `sleep` must move it, so the clock is a locked class and not an actor.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Int64
    private var slept: [Int] = []

    init(_ start: Date) { current = KsefTime.millis(start) }

    var now: Date {
        lock.withLock { Date(timeIntervalSince1970: Double(current) / 1000) }
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
