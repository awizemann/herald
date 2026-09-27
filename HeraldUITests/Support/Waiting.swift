import XCTest

/// Waiting, never sleeping: every helper polls a condition until it holds or
/// a deadline passes, spinning the run loop in between (so XCUITest keeps
/// processing), and returns whether it held. Assert on the result — a helper
/// never fails the test itself, so a caller can also wait for an ABSENCE.
@MainActor
enum Wait {
    /// How often a condition is re-evaluated. Each evaluation snapshots the
    /// app's accessibility tree, so not tighter than this.
    static let pollInterval: TimeInterval = 0.2

    /// Polls `condition` until it returns true or `timeout` passes. Always
    /// evaluates at least once.
    @discardableResult
    static func until(
        timeout: TimeInterval = HeraldApp.defaultTimeout,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if condition() { return true }
            if Date() >= deadline { return false }
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(pollInterval)))
        }
    }

    /// The opposite wait: polls `condition` for the whole `duration` and
    /// returns false the moment it stops holding — for "nothing ELSE happens"
    /// assertions (no second send, no refresh storm, the error stays up).
    /// Still polling, never sleeping; `duration` is how long "nothing" must last.
    static func holds(for duration: TimeInterval, _ condition: () -> Bool) -> Bool {
        !until(timeout: duration) { !condition() }
    }

    /// Polls `produce` until it yields a non-nil value; `nil` on timeout.
    static func value<T>(
        timeout: TimeInterval = HeraldApp.defaultTimeout,
        _ produce: () -> T?
    ) -> T? {
        var result: T?
        until(timeout: timeout) {
            result = produce()
            return result != nil
        }
        return result
    }
}

@MainActor
extension XCUIElement {
    /// Waits for the element to exist.
    @discardableResult
    func waitUntilExists(timeout: TimeInterval = HeraldApp.defaultTimeout) -> Bool {
        waitForExistence(timeout: timeout)
    }

    /// Waits for the element to STOP existing (or never to have existed).
    @discardableResult
    func waitUntilGone(timeout: TimeInterval = HeraldApp.defaultTimeout) -> Bool {
        Wait.until(timeout: timeout) { !exists }
    }

    /// Waits until the element exists and is enabled (hittable controls).
    @discardableResult
    func waitUntilEnabled(timeout: TimeInterval = HeraldApp.defaultTimeout) -> Bool {
        Wait.until(timeout: timeout) { exists && isEnabled }
    }

    /// Waits until the element's accessibility LABEL satisfies `predicate`.
    @discardableResult
    func waitForLabel(
        timeout: TimeInterval = HeraldApp.defaultTimeout,
        _ predicate: (String) -> Bool
    ) -> Bool {
        Wait.until(timeout: timeout) { exists && predicate(label) }
    }

    /// Waits until the element's accessibility VALUE (as a string) satisfies
    /// `predicate`.
    @discardableResult
    func waitForValue(
        timeout: TimeInterval = HeraldApp.defaultTimeout,
        _ predicate: (String) -> Bool
    ) -> Bool {
        Wait.until(timeout: timeout) { exists && predicate(stringValue) }
    }

    /// The accessibility value as a string (`""` when there is none).
    var stringValue: String {
        (value as? String) ?? ""
    }

    /// Clicks after waiting for the element; fails the test when it never
    /// becomes available.
    func waitAndClick(
        timeout: TimeInterval = HeraldApp.defaultTimeout,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard waitUntilEnabled(timeout: timeout) else {
            XCTFail("\(self) never became available to click", file: file, line: line)
            return
        }
        click()
    }

    /// Clicks into a text field/view and types `text`.
    func clickAndType(
        _ text: String,
        timeout: TimeInterval = HeraldApp.defaultTimeout,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        waitAndClick(timeout: timeout, file: file, line: line)
        typeText(text)
    }
}

@MainActor
extension XCUIElement {
    /// Any element (whatever its type) with this accessibility identifier.
    /// SwiftUI's element types vary by control and OS release (a combined
    /// `Text` group can be a staticText or a group), so page objects query by
    /// identifier across all types.
    func element(id: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: id).firstMatch
    }
}
