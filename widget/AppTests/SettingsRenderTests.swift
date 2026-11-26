import AppKit
import KsefCore
import SwiftUI
import XCTest

// ImageRenderer draws a Form blank, so the view is hosted in a never-shown window and its layer is cached.
@MainActor
final class SettingsRenderTests: XCTestCase {
    private let noActions = SettingsActions(
        chooseCertificate: {}, chooseKey: {}, chooseFolder: {}, save: {}, check: {}, testNotification: {}, openLoginItems: {},
        setStartAtLogin: { _ in }
    )

    private func form(
        nip: String = "", dataDir: String = "~/Documents/KSeF", stored: Bool = false, startAtLogin: Bool = false,
        needsApproval: Bool = false, notifications: Bool? = nil, legacyAgent: Bool = false, message: SettingsMessage? = nil
    ) -> SettingsForm {
        SettingsForm(
            nip: nip, environment: .prod, startDate: startDate(fromText: "2026-02-01")!, dataDir: dataDir,
            certificateName: nil, keyName: nil, password: "", hasStoredCredentials: stored, startAtLogin: startAtLogin,
            loginNeedsApproval: needsApproval, notificationsAllowed: notifications, legacyAgent: legacyAgent, message: message
        )
    }

    func testRenderFirstLaunch() throws {
        try render(form(), name: "settings-first-launch")
    }

    func testRenderFirstLaunchDark() throws {
        try render(form(), name: "settings-first-launch-dark", appearance: .darkAqua)
    }

    func testRenderError() throws {
        let reason = "Uwierzytelnienie w KSeF nieudane (kod 460: Uwierzytelnianie zakończone niepowodzeniem z powodu błędu certyfikatu — Certyfikat odwołany)"
        try render(
            form(
                nip: "5265877635", dataDir: "/Volumes/Archiwum/Faktury/KSeF", stored: true, startAtLogin: true, notifications: true,
                message: SettingsMessage(text: "Błąd: " + reason, isError: true)
            ),
            name: "settings-error"
        )
    }

    func testRenderLegacyAgent() throws {
        try render(
            form(nip: "5265877635", stored: true, notifications: false, legacyAgent: true), name: "settings-legacy-agent"
        )
    }

    func testRenderNeedsApproval() throws {
        try render(
            form(
                nip: "5265877635", stored: true, needsApproval: true, notifications: true,
                message: SettingsMessage(text: "Połączenie działa. Faktury w pierwszym oknie: 3, jeszcze niezapisane: 1.", isError: false)
            ),
            name: "settings-needs-approval"
        )
    }

    private func render(_ form: SettingsForm, name: String, appearance: NSAppearance.Name = .aqua) throws {
        guard let directory = ProcessInfo.processInfo.environment["SETTINGS_RENDER_DIR"] else {
            throw XCTSkip("set TEST_RUNNER_SETTINGS_RENDER_DIR to render PNGs")
        }
        let view = NSHostingView(rootView: SettingsView(form: .constant(form), busy: false, actions: noActions))
        let size = view.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 300)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
}
