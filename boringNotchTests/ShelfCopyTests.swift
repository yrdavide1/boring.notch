//
//  ShelfCopyTests.swift
//  boringNotchTests
//

import AppKit
import XCTest

@testable import boringNotch

@MainActor
final class ShelfCopyTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("boringNotchTests.shelfCopy.\(UUID().uuidString)"))
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        pasteboard = nil
    }

    private func fileItem() -> ShelfItem {
        ShelfItem(kind: .file(bookmark: Data()))
    }

    private func fileURLsOnPasteboard() -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    func testFilesAreOnPasteboardWhenCopyReturns() {
        let first = fileItem()
        let second = fileItem()
        let urls = [
            first.id: URL(fileURLWithPath: "/tmp/first.sql"),
            second.id: URL(fileURLWithPath: "/tmp/second.sql"),
        ]

        let copied = ShelfActionService.copy([first, second], to: pasteboard) { urls[$0.id] }

        XCTAssertTrue(copied)
        XCTAssertEqual(fileURLsOnPasteboard(), [urls[first.id]!, urls[second.id]!])
    }

    func testUnresolvableFilesAreSkipped() {
        let resolvable = fileItem()
        let broken = fileItem()
        let url = URL(fileURLWithPath: "/tmp/ok.sql")

        let copied = ShelfActionService.copy([broken, resolvable], to: pasteboard) {
            $0.id == resolvable.id ? url : nil
        }

        XCTAssertTrue(copied)
        XCTAssertEqual(fileURLsOnPasteboard(), [url])
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func testNothingCopiedLeavesPasteboardUntouched() {
        pasteboard.clearContents()
        pasteboard.setString("previous", forType: .string)

        let copied = ShelfActionService.copy([fileItem(), fileItem()], to: pasteboard) { _ in nil }

        XCTAssertFalse(copied)
        XCTAssertEqual(pasteboard.string(forType: .string), "previous")
    }

    func testTextItemsAreCopiedAsText() {
        let items = [ShelfItem(kind: .text(string: "one")), ShelfItem(kind: .text(string: "two"))]

        let copied = ShelfActionService.copy(items, to: pasteboard) { _ in nil }

        XCTAssertTrue(copied)
        XCTAssertEqual(pasteboard.string(forType: .string), "one\ntwo")
    }

    func testDataFileNameIsNeverHidden() {
        XCTAssertEqual(TemporaryFileStorageService.dataFileName(suggestedName: nil, fileExtension: "png"), "Untitled.png")
        XCTAssertEqual(TemporaryFileStorageService.dataFileName(suggestedName: "  ", fileExtension: nil), "Untitled")
        XCTAssertEqual(TemporaryFileStorageService.dataFileName(suggestedName: "photo", fileExtension: "jpeg"), "photo.jpeg")
        XCTAssertEqual(TemporaryFileStorageService.dataFileName(suggestedName: "report.pdf", fileExtension: "data"), "report.pdf")
    }
}
