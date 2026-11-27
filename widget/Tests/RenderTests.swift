import AppKit
import SwiftUI
import XCTest

// Sizes are the iOS HIG values standing in for the undocumented macOS ones: a layout check, not pixel truth.
@MainActor
final class RenderTests: XCTestCase {
    private let mediumSize = CGSize(width: 364, height: 170)
    private let largeSize = CGSize(width: 364, height: 382)
    private let scale: CGFloat = 2

    func testRenderMedium() throws {
        try render(Fixtures.snapshot(), isLarge: false, name: "medium")
    }

    func testRenderMediumDark() throws {
        try render(Fixtures.snapshot(), isLarge: false, name: "medium-dark", dark: true)
    }

    func testRenderLarge() throws {
        try render(Fixtures.snapshot(invoiceCount: 8), isLarge: true, name: "large")
    }

    func testRenderLargeDark() throws {
        try render(Fixtures.snapshot(invoiceCount: 8), isLarge: true, name: "large-dark", dark: true)
    }

    func testRenderMediumFailed() throws {
        let reason = "Uwierzytelnienie w KSeF nieudane (kod 460: Uwierzytelnianie zakończone niepowodzeniem z powodu błędu certyfikatu — Certyfikat odwołany)"
        try render(Fixtures.snapshot(status: .failed, reason: reason), isLarge: false, name: "medium-failed")
    }

    func testRenderMediumStale() throws {
        try render(Fixtures.snapshot(), isLarge: false, name: "medium-stale", now: Fixtures.updatedAt.addingTimeInterval(5 * 3600))
    }

    func testRenderMediumSummary() throws {
        try render(Fixtures.snapshot(yearSummary: Self.plainSummary), isLarge: false, name: "medium-summary")
    }

    func testRenderMediumSummaryDark() throws {
        try render(Fixtures.snapshot(yearSummary: Self.plainSummary), isLarge: false, name: "medium-summary-dark", dark: true)
    }

    func testRenderLargeSummary() throws {
        try render(Fixtures.snapshot(invoiceCount: 8, yearSummary: Self.plainSummary), isLarge: true, name: "large-summary")
    }

    func testRenderLargeSummaryDark() throws {
        try render(Fixtures.snapshot(invoiceCount: 8, yearSummary: Self.plainSummary), isLarge: true, name: "large-summary-dark", dark: true)
    }

    func testRenderMediumSummaryStale() throws {
        let summary = Snapshot.YearSummary(
            text: "2026 netto (stan na 26.11 11:00) · wydatki 48\u{a0}210,55 PLN · przychody 182\u{a0}400,00 PLN", warning: true)
        try render(Fixtures.snapshot(yearSummary: summary), isLarge: false, name: "medium-summary-stale")
    }

    func testRenderMediumSummaryCurrency() throws {
        let summary = Snapshot.YearSummary(
            text: "2026 netto (stan na 26.11 11:00) · wydatki 1\u{a0}234\u{a0}567,89 PLN + 12\u{a0}345,67 EUR"
                + " · przychody 2\u{a0}345\u{a0}678,90 PLN + 1200,00 USD",
            warning: true)
        try render(Fixtures.snapshot(yearSummary: summary), isLarge: false, name: "medium-summary-currency")
    }

    func testRenderMediumSummaryFailed() throws {
        let reason = "Uwierzytelnienie w KSeF nieudane (kod 460: Uwierzytelnianie zakończone niepowodzeniem z powodu błędu certyfikatu — Certyfikat odwołany)"
        try render(Fixtures.snapshot(status: .failed, reason: reason, yearSummary: Self.plainSummary), isLarge: false, name: "medium-summary-failed")
    }

    func testRenderMediumSummaryPending() throws {
        let summary = Snapshot.YearSummary(text: "2026 · podsumowanie w przygotowaniu", warning: true)
        try render(Fixtures.snapshot(yearSummary: summary), isLarge: false, name: "medium-summary-pending")
    }

    func testRenderMediumSummarySkipped() throws {
        let summary = Snapshot.YearSummary(
            text: "2026 netto · wydatki 48\u{a0}210,55 PLN · przychody 182\u{a0}400,00 PLN · pominięte: 1", warning: true)
        try render(Fixtures.snapshot(yearSummary: summary), isLarge: false, name: "medium-summary-skipped")
    }

    func testRenderLargeSummaryFailed() throws {
        let reason = "Uwierzytelnienie w KSeF nieudane (kod 460: Uwierzytelnianie zakończone niepowodzeniem z powodu błędu certyfikatu — Certyfikat odwołany)"
        let snapshot = Fixtures.snapshot(status: .failed, reason: reason, invoiceCount: 8, yearSummary: Self.plainSummary)
        try render(snapshot, isLarge: true, name: "large-summary-failed")
    }

    private static let plainSummary = Snapshot.YearSummary(
        text: "2026 netto · wydatki 48\u{a0}210,55 PLN · przychody 182\u{a0}400,00 PLN", warning: false)

    private func render(_ snapshot: Snapshot, isLarge: Bool, name: String, dark: Bool = false, now: Date = Fixtures.now) throws {
        guard let directory = ProcessInfo.processInfo.environment["WIDGET_RENDER_DIR"] else {
            throw XCTSkip("set TEST_RUNNER_WIDGET_RENDER_DIR to render PNGs")
        }
        let size = isLarge ? largeSize : mediumSize
        // ImageRenderer draws Link as a placeholder and skips containerBackground, so links are off and the
        // background is part of the rendered view.
        let view = InvoiceListView(model: WidgetModel.make(.success(snapshot), now: now), isLarge: isLarge, linksEnabled: false)
            .padding(16)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(dark ? Color(white: 0.16) : Color.white)
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, Int(size.width * scale))
        XCTAssertEqual(image.height, Int(size.height * scale))
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
}
