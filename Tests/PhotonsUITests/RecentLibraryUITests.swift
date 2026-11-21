import XCTest
import AppKit
import PhotonsCatalog
@testable import PhotonsUI

/// 295 B — 启动恢复上次打开的库.
///
/// `AppDelegate` is an executable target a test bundle cannot import, so the decision it makes lives
/// in `RecentLibrary.launchURL` (pure, injectable) and the write lives in `CatalogSession.open`
/// (`RecentLibrary.Store`, injectable). These tests pin both, plus the smoke-run opt-out that keeps
/// `make ui-smoke` from rewriting the user's preference.
final class RecentLibraryUITests: XCTestCase {

    private var workDir: URL!

    /// An in-memory `RecentLibrary.Store` — this test must not touch the real defaults domain.
    private final class MemoryStore: RecentLibrary.Store {
        var values: [String: String] = [:]
        func string(forKey key: String) -> String? { values[key] }
        func set(_ value: String?, forKey key: String) {
            if let value { values[key] = value } else { values.removeValue(forKey: key) }
        }
    }

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-recent-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    @MainActor
    func testFileMenuRefreshesRecentLibrariesAndOpensChosenDuplicateName() throws {
        _ = NSApplication.shared
        let main = MainMenu.build()
        let file = try XCTUnwrap(main.items.compactMap(\.submenu).first {
            $0.items.contains { $0.action == #selector(EditorWindowController.openLibraryAction(_:)) }
        })
        XCTAssertTrue(file.items.contains { $0.submenu is RecentLibrariesMenu })

        let store = MemoryStore()
        let menu = RecentLibrariesMenu(store: store)
        menu.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.numberOfItems, 1)
        XCTAssertFalse(menu.items[0].isEnabled)

        let a = workDir.appendingPathComponent("first/Session.photonslibrary")
        let b = workDir.appendingPathComponent("second/Session.photonslibrary")
        _ = try Catalog.create(at: a)
        _ = try Catalog.create(at: b)
        RecentLibrary.remember(a, in: store)
        RecentLibrary.remember(b, in: store)
        menu.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items.map(\.toolTip), [b.path, a.path])
        XCTAssertNotEqual(menu.items[0].title, menu.items[1].title)
        let editor = EditorWindowController()
        editor.session.remembersRecentLibrary = false
        let selected = menu.items[1]
        let action = try XCTUnwrap(selected.action)
        XCTAssertTrue(NSApp.sendAction(action, to: editor, from: selected))
        XCTAssertEqual(editor.session.libraryURL?.standardizedFileURL.path, a.standardizedFileURL.path)
        LibraryHistory.remove(b, in: store)
        menu.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items.map(\.title), ["Session"])
    }

    // MARK: - the store

    func testRememberThenRecall() throws {
        let store = MemoryStore()
        let url = workDir.appendingPathComponent("A.\(LibraryLayout.packageExtension)")
        XCTAssertNil(RecentLibrary.recall(from: store))

        RecentLibrary.remember(url, in: store)
        XCTAssertEqual(RecentLibrary.recall(from: store), url.standardizedFileURL)

        RecentLibrary.forget(in: store)
        XCTAssertNil(RecentLibrary.recall(from: store))
    }

    // MARK: - the write is part of a successful open

    @MainActor
    func testOpeningALibraryRecordsIt() throws {
        let store = MemoryStore()
        let package = workDir.appendingPathComponent("B.\(LibraryLayout.packageExtension)")
        _ = try Catalog.create(at: package)

        let session = CatalogSession(recentLibraryStore: store)
        XCTAssertNil(RecentLibrary.recall(from: store), "nothing recorded before the open")
        try session.open(package)

        XCTAssertEqual(RecentLibrary.recall(from: store)?.path, package.standardizedFileURL.path)
    }

    /// What `UISmokeRunner` sets. The smoke library is a fixture; it must not become "last opened".
    @MainActor
    func testSmokeRunsDoNotOverwriteTheRememberedLibrary() throws {
        let store = MemoryStore()
        let previous = workDir.appendingPathComponent("Previous.\(LibraryLayout.packageExtension)")
        RecentLibrary.remember(previous, in: store)

        let smokeLibrary = workDir.appendingPathComponent("Smoke.\(LibraryLayout.packageExtension)")
        _ = try Catalog.create(at: smokeLibrary)
        let session = CatalogSession(recentLibraryStore: store)
        session.remembersRecentLibrary = false
        try session.open(smokeLibrary)

        XCTAssertEqual(RecentLibrary.recall(from: store)?.path, previous.standardizedFileURL.path,
                       "the smoke run left the user's preference alone")
    }

    // MARK: - what launch opens (pure)

    func testLaunchURLPrefersTheCommandLineAndDropsVanishedPaths() throws {
        let explicit = "/tmp/explicit.photonslibrary"
        XCTAssertEqual(RecentLibrary.launchURL(explicit: explicit,
                                               remembered: URL(fileURLWithPath: "/tmp/other"),
                                               isDirectory: { _ in false })?.path,
                       explicit,
                       "the command line wins even when it is not a directory yet — the open reports that")

        XCTAssertNil(RecentLibrary.launchURL(explicit: nil,
                                             remembered: URL(fileURLWithPath: "/tmp/gone.photonslibrary"),
                                             isDirectory: { _ in false }),
                     "a vanished library means an empty window, not a remembered dead path")

        let here = URL(fileURLWithPath: "/tmp/here.photonslibrary")
        XCTAssertEqual(RecentLibrary.launchURL(explicit: nil, remembered: here,
                                               isDirectory: { _ in true }),
                       here)
    }
}
