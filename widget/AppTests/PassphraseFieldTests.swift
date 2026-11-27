import AppKit
import SwiftUI
import XCTest

@MainActor
final class PassphraseFieldTests: XCTestCase {
    func testFieldOptsOutOfPasswordAutoFill() {
        let field = makePassphraseField(placeholder: "")
        XCTAssertEqual(field.contentType, .newPassword)
        XCTAssertFalse(field.isAutomaticTextCompletionEnabled)
    }

    func testPlaceholderIsPassedThrough() {
        XCTAssertEqual(makePassphraseField(placeholder: "").placeholderString, "")
        XCTAssertEqual(
            makePassphraseField(placeholder: "zapisane — wpisz, aby zmienić").placeholderString, "zapisane — wpisz, aby zmienić"
        )
    }

    func testEditingUpdatesTheBinding() {
        var text = ""
        let coordinator = PassphraseField.Coordinator(text: Binding(get: { text }, set: { text = $0 }))
        let field = makePassphraseField(placeholder: "")
        field.stringValue = "tajne hasło"
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(text, "tajne hasło")
    }
}
