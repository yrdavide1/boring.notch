//
//  ShelfActionService.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-07.
//

import AppKit
import Foundation

/// A service providing common actions for `ShelfItem`s, such as opening, revealing, or copying paths.
@MainActor
enum ShelfActionService {
    static func open(_ item: ShelfItem) {
        switch item.kind {
        case .file(let bookmarkData):
            Bookmark(data: bookmarkData).withAccess { url in
                NSWorkspace.shared.open(url)
            }
        case .link(let url):
            NSWorkspace.shared.open(url)
        case .text(let string):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(string, forType: .string)
        }
    }

    static func reveal(_ item: ShelfItem) {
        guard case .file(let bookmarkData) = item.kind else { return }
        Bookmark(data: bookmarkData).withAccess { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    static func copyPath(_ item: ShelfItem) {
        guard case .file(let bookmarkData) = item.kind else { return }
        Bookmark(data: bookmarkData).withAccess { url in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        }
    }

    /// URLs whose security-scoped access is kept open while they sit on the pasteboard.
    private static var copiedURLs: [URL] = []

    /// Writes the items to the pasteboard in a single synchronous step, so a paste
    /// right after the Copy action always sees the new contents.
    ///
    /// Files are written as URLs. If no file resolves, the display names of the
    /// remaining items are written as text. Items whose bookmark cannot be resolved
    /// are skipped. Returns `false` and leaves the pasteboard untouched when there
    /// is nothing to write.
    @discardableResult
    static func copy(
        _ items: [ShelfItem],
        to pasteboard: NSPasteboard = .general,
        resolveFileURL: (ShelfItem) -> URL? = { ShelfStateViewModel.shared.resolveAndUpdateBookmark(for: $0) }
    ) -> Bool {
        var fileURLs: [URL] = []
        var names: [String] = []
        for item in items {
            if case .file = item.kind {
                if let url = resolveFileURL(item) {
                    fileURLs.append(url)
                } else {
                    Log.shelf.error("❌ Copy skipped shelf item \(item.id): file could not be resolved")
                }
            } else {
                names.append(item.displayName)
            }
        }

        if !fileURLs.isEmpty {
            for url in copiedURLs {
                url.stopAccessingSecurityScopedResource()
            }
            copiedURLs = fileURLs.filter { $0.startAccessingSecurityScopedResource() }
            NSLog("🔐 Started security-scoped access for \(copiedURLs.count) copied files")

            pasteboard.clearContents()
            pasteboard.writeObjects(fileURLs as [NSURL])
            return true
        }

        let text = names.filter { !$0.isEmpty }.joined(separator: "\n")
        guard !text.isEmpty else { return false }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return true
    }

    static func remove(_ item: ShelfItem) {
        ShelfStateViewModel.shared.remove(item)
    }
}
