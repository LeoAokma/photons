import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// **402 — 裁剪框/引导线不该盖到顶栏与胶片条背景上。**
///
/// 用户口径：
///
/// > 「裁剪框，引导线，之前修过会出区域到侧栏，实际上除了左侧栏，还会出现在顶部横条（包括红绿灯），
/// > 以及底部胶片条的背景上。」
///
/// 394 的「遮挡而不裁剪」路线不变（用户：「超出画布边界没问题」）。本单补齐两个漏面，而它们是**两种**
/// 不同的修法：
///
/// ① **顶栏是层级问题** —— `headerGlass` / `topBar` 曾经排在 `canvasHost` 之前（即之下），
///   越界的 overlay 连同画布的黑底盖住了顶栏与红绿灯；
/// ② **胶片条是缺底板** —— 它的 `view` 是 `drawsBackground = false` 的 `NSScrollView`、cell 背景
///   `.clear`，层次本来就对，但那块**没有像素**去遮挡越界部分。
///
/// 每一格都是「越界真实发生 **且** 被盖住」两件事同时成立，与 394 ② 同构。
@MainActor
final class CropOverlayAboveChrome402Tests: XCTestCase {

    private var workDir: URL!
    private var editors: [EditorWindowController] = []
    private var savedBrowserMode: Any?
    private var savedBrowserWidth: Any?

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-402-chrome-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        // `setBrowserMode` persists the mode in the user's defaults; a test must not leave the app
        // opening in whichever mode it switched to.
        savedBrowserMode = UserDefaults.standard.object(forKey: "photons.browserMode")
        savedBrowserWidth = UserDefaults.standard.object(forKey: "photons.browserWidth")
    }

    override func tearDownWithError() throws {
        for editor in editors { editor.window?.close() }
        editors.removeAll()
        for (key, value) in [("photons.browserMode", savedBrowserMode),
                             ("photons.browserWidth", savedBrowserWidth)] {
            if let value { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - harness

    private struct Workspace {
        let editor: EditorWindowController
        let window: NSWindow
        let root: WorkspaceRootView
        let loupe: LoupeController
        let session: CatalogSession
    }

    private func makeWorkspace() throws -> Workspace {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        editors.append(editor)
        let window = try XCTUnwrap(editor.window)
        let root = try XCTUnwrap(editor.rootView)
        root.layoutSubtreeIfNeeded()
        CropUITestSupport.pump(0.05)
        root.layoutSubtreeIfNeeded()
        return Workspace(editor: editor, window: window, root: root,
                         loupe: root.loupeController, session: editor.session)
    }

    /// `canvasHost` is reached without new API: it is the superview `showModule(for:)` installs the
    /// loupe's own view into.
    private func canvasHost(_ w: Workspace) throws -> NSView {
        try XCTUnwrap(w.loupe.view.superview, "the canvas module is not in a host")
    }

    private func index(of view: NSView, in root: WorkspaceRootView) -> Int? {
        root.subviews.firstIndex { $0 === view }
    }

    private func requireIndex(of view: NSView, in root: WorkspaceRootView,
                              _ label: String) throws -> Int {
        try XCTUnwrap(index(of: view, in: root), "\(label) is not a direct subview of the workspace")
    }

    private func drawnRect(_ layout: CropToolLayout) -> NSRect {
        let xs = layout.corners.map(\.x), ys = layout.corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func describe(_ r: NSRect) -> String {
        String(format: "(%.1f, %.1f) %.1f×%.1f", r.minX, r.minY, r.width, r.height)
    }

    /// The five faces, in `subviews` order, as one report line.
    private func inventory(_ w: Workspace) throws -> String {
        let host = try canvasHost(w)
        func pos(_ view: NSView?, _ name: String) -> String {
            guard let view, let i = index(of: view, in: w.root) else { return "\(name)[—]" }
            return "\(name)[\(i)]"
        }
        return [
            pos(w.root.headerGlass, "headerGlass"),
            pos(w.root.topBar, "topBar"),
            pos(host, "canvasHost"),
            pos(w.root.browserPane.view, "browserPane"),
            pos(w.root.inspectorHost, "inspectorHost"),
            pos(w.root.filmstripBackdrop, "filmstripBackdrop"),
            pos(w.root.filmstripController.view, "filmstrip"),
            pos(w.root.importProgressBar, "importProgressBar"),
            pos(w.root.forwardCompatNotice, "forwardCompatNotice"),
        ].joined(separator: " ")
    }

    // MARK: - ① the top bar

    /// ① — `headerGlass` and `topBar` are both **added after** `canvasHost` (so they sit on top and
    /// cover the overhang), `headerGlass` still before `topBar` (it is the buttons' backdrop), and a
    /// crop draft that really reaches above the canvas' top edge intersects `topBar.frame`.
    ///
    /// It also measures 2.1's regression risk: `headerGlass` spans the window's full width up to
    /// `topBar.maxY`, so if that height were wrong it would cover the canvas' top band. The overlap
    /// must be exactly 0 pt tall.
    func testTheTopBarIsAboveTheCanvas() throws {
        let w = try makeWorkspace()
        XCTAssertTrue(CropUITestSupport.openCropTool(w.loupe, w.session))
        CropUITestSupport.pump(0.05)

        // A frame reaching above the photograph: `top < 0` in the draft's normalized space. The canvas'
        // clamp is switched off **for the construction only** — this is the layering test, not the
        // clamp's own law (`clampsFrameToView = false` is the documented test gate 394 ② also uses).
        w.loupe.cropTool.clampsFrameToView = false
        w.loupe.cropTool.draft.crop = CropRect(left: 0.10, top: -0.35, right: 0.80, bottom: 0.75)
        w.loupe.refreshCropTool()
        CropUITestSupport.pump(0.05)

        let overlay = w.loupe.cropOverlayViewForAudit
        let layout = try XCTUnwrap(w.loupe.cropOverlayLayoutForTesting, "no frame drawn")
        let drawn = drawnRect(layout)
        let drawnInRoot = overlay.convert(drawn, to: w.root)
        let host = try canvasHost(w)
        let canvasRect = host.frame
        let topBarFrame = w.root.topBar.frame
        let overlap = drawnInRoot.intersection(topBarFrame)
        let glass = try requireIndex(of: w.root.headerGlass, in: w.root, "headerGlass")
        let bar = try requireIndex(of: w.root.topBar, in: w.root, "topBar")
        let canvas = try requireIndex(of: host, in: w.root, "canvasHost")
        let glassOverCanvas = w.root.headerGlass.frame.intersection(canvasRect)

        print("""
        402 ① · \(try inventory(w)) · \
        drawn(in overlay) \(describe(drawn)) · drawn(in root) \(describe(drawnInRoot)) · \
        canvas \(describe(canvasRect)) · topBar \(describe(topBarFrame)) · \
        交集 \(describe(overlap)) (null=\(overlap.isNull)) · \
        headerGlass \(describe(w.root.headerGlass.frame)) ∩ canvas 高度 \
        \(glassOverCanvas.isNull ? 0 : glassOverCanvas.height)
        """)

        XCTAssertLessThan(drawnInRoot.minY, canvasRect.minY,
                          "① 前提：框必须越出画布上边界，实际 \(describe(drawnInRoot)) vs 画布上沿 \(canvasRect.minY)")
        XCTAssertFalse(overlap.isNull, "① 前提：越界部分必须真的压在顶栏矩形上")
        XCTAssertGreaterThan(overlap.width, 1, "① 越界的那一块太窄，说明不了遮挡")
        XCTAssertGreaterThan(overlap.height, 1, "① 越界的那一块太窄，说明不了遮挡")
        XCTAssertGreaterThan(bar, canvas,
                             "① 期望 topBar 索引 \(canvas + 1) > canvasHost 索引 \(canvas)，"
                             + "实际 \(bar) vs \(canvas) — 顶栏在画布之下，越界 overlay 会盖住它和红绿灯")
        XCTAssertGreaterThan(glass, canvas,
                             "① 期望 headerGlass 索引 > canvasHost 索引 \(canvas)，实际 \(glass) vs \(canvas)"
                             + " — 玻璃在画布之下，红绿灯那条会露出 overlay")
        XCTAssertLessThan(glass, bar, "① headerGlass[\(glass)] 必须仍在 topBar[\(bar)] 之前（玻璃衬托按钮）")
        XCTAssertTrue(glassOverCanvas.isNull || glassOverCanvas.height <= 0.001,
                      "① 回归：headerGlass \(describe(w.root.headerGlass.frame)) 盖住了画布上沿 "
                      + "\(describe(glassOverCanvas))（必须为 0 高）")
    }

    // MARK: - ② the filmstrip plate

    /// ② — the filmstrip has a real plate: an `NSVisualEffectView` added **after** `canvasHost` (so it
    /// covers the overhang) and **before** `filmstripController.view` (so the thumbnails are on top),
    /// with exactly the strip's frame, `.underWindowBackground` / `.behindWindow`.
    ///
    /// Then the strip goes away (`.list`): the plate must go with it — a stale 86 pt plate over the
    /// canvas would be this lane's bug inverted.
    func testTheFilmstripHasAnOpaqueBackdrop() throws {
        let w = try makeWorkspace()
        w.root.setBrowserMode(.filmstrip)
        w.root.layoutSubtreeIfNeeded()
        CropUITestSupport.pump(0.05)
        w.root.layoutSubtreeIfNeeded()

        let host = try canvasHost(w)
        let canvas = try requireIndex(of: host, in: w.root, "canvasHost")
        let backdrop = w.root.filmstripBackdrop
        let plate = try requireIndex(of: backdrop, in: w.root, "filmstripBackdrop")
        let strip = try requireIndex(of: w.root.filmstripController.view, in: w.root,
                                     "filmstripController.view")
        let plateFrame = backdrop.frame
        let stripFrame = w.root.filmstripController.view.frame

        print("""
        402 ② · \(try inventory(w)) · backdrop \(describe(plateFrame)) · \
        strip \(describe(stripFrame)) · \
        frameEqual \(plateFrame == stripFrame) · \
        material \(backdrop.material.rawValue) blending \(backdrop.blendingMode.rawValue) \
        hidden \(backdrop.isHidden) · canvas \(describe(host.frame))
        """)

        XCTAssertGreaterThan(plate, canvas,
                             "② 底板在画布之下（filmstripBackdrop[\(plate)] ≤ canvasHost[\(canvas)]），"
                             + "越界的 overlay 仍会画到胶片条那块")
        XCTAssertLessThan(plate, strip, "② 底板必须在胶片条之上层吗？不 —— 底板[\(plate)] 必须排在 "
                          + "filmstrip[\(strip)] 之前（缩略图要画在板上）")
        XCTAssertFalse(plateFrame.isEmpty, "② 胶片条模式下底板不能是空矩形")
        XCTAssertEqual(plateFrame.origin.x, stripFrame.origin.x, accuracy: 0, "② 底板 x 必须与胶片条相同")
        XCTAssertEqual(plateFrame.origin.y, stripFrame.origin.y, accuracy: 0, "② 底板 y 必须与胶片条相同")
        XCTAssertEqual(plateFrame.width, stripFrame.width, accuracy: 0, "② 底板宽必须与胶片条相同")
        XCTAssertEqual(plateFrame.height, stripFrame.height, accuracy: 0, "② 底板高必须与胶片条相同")
        XCTAssertEqual(plateFrame.height, WorkspaceLayout.filmstripHeight, accuracy: 0.001,
                       "② 底板高度必须就是那一条 86 pt")
        XCTAssertEqual(backdrop.material, .underWindowBackground, "② 材质与右侧检查器底板同款")
        XCTAssertEqual(backdrop.blendingMode, .behindWindow,
                       "② `.behindWindow` 才是完全不透明的采样层，overlay 透不过来")
        XCTAssertEqual(backdrop.state, .followsWindowActiveState)
        XCTAssertFalse(backdrop.isHidden, "② 胶片条模式底板必须在")

        // 观感/不透明度证据：真实渲染一帧，读板子与胶片条本体中心的像素 alpha。底板应当是不透明的
        // 采样层，而胶片条自己那个 `drawsBackground = false` 的滚动视图读出来是 0 —— 这正是漏色的
        // 原因（no assertion here: it is the *measurement* the report quotes, not a new contract）。
        for (name, view) in [("filmstripBackdrop", backdrop as NSView),
                             ("filmstrip.view", w.root.filmstripController.view)] {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let x = rep.pixelsWide / 2, y = rep.pixelsHigh / 2
            let a = rep.colorAt(x: x, y: y)?.alphaComponent ?? -1
            print(String(format: "402 ② · %@ centre pixel alpha %.3f", name, a))
        }

        // The strip is hidden → the plate goes with it.
        w.root.setBrowserMode(.list)
        w.root.layoutSubtreeIfNeeded()
        CropUITestSupport.pump(0.05)
        w.root.layoutSubtreeIfNeeded()
        print("""
        402 ② · mode .list · backdrop \(describe(backdrop.frame)) hidden \(backdrop.isHidden) · \
        strip hidden \(w.root.filmstripController.view.isHidden)
        """)
        XCTAssertTrue(backdrop.isHidden || backdrop.frame.height == 0,
                      "② 胶片条隐藏后仍留着 \(describe(backdrop.frame)) 的板子压着画布")
    }

    // MARK: - ③ 394's regression guard

    /// ③ — 394's result must survive this lane: the browser is still above the canvas, and a frame
    /// reaching left of the canvas really does intersect it.
    func testABorderlineOverlaysStillDoesNotCoverTheLeftBrowser() throws {
        let w = try makeWorkspace()
        XCTAssertTrue(CropUITestSupport.openCropTool(w.loupe, w.session))
        CropUITestSupport.pump(0.05)

        w.loupe.cropTool.clampsFrameToView = false
        w.loupe.cropTool.draft.crop = CropRect(left: -0.12, top: 0.25, right: 0.55, bottom: 0.95)
        w.loupe.refreshCropTool()
        CropUITestSupport.pump(0.05)

        let overlay = w.loupe.cropOverlayViewForAudit
        let layout = try XCTUnwrap(w.loupe.cropOverlayLayoutForTesting, "no frame drawn")
        let drawnInRoot = overlay.convert(drawnRect(layout), to: w.root)
        let panelFrame = w.root.browserPane.view.frame
        let overlap = drawnInRoot.intersection(panelFrame)
        let host = try canvasHost(w)
        let canvas = try requireIndex(of: host, in: w.root, "canvasHost")
        let browser = try requireIndex(of: w.root.browserPane.view, in: w.root, "browserPane.view")

        print("""
        402 ③ · \(try inventory(w)) · drawn(in root) \(describe(drawnInRoot)) · \
        browser \(describe(panelFrame)) · 交集 \(describe(overlap)) (null=\(overlap.isNull))
        """)

        XCTAssertFalse(overlap.isNull, "③ 前提：越界部分必须真的压在侧栏矩形上")
        XCTAssertGreaterThan(overlap.width, 1, "③ 越界的那一块太窄，说明不了遮挡")
        XCTAssertGreaterThan(browser, canvas,
                             "③ 394 的成果被改回去了：browserPane[\(browser)] ≤ canvasHost[\(canvas)]")
    }

    // MARK: - ④ notices stay topmost

    /// ④ — 394's first tier: the import line and the provenance notice stay above **every** panel.
    func testTheNoticeAndProgressStayOnTop() throws {
        let w = try makeWorkspace()
        let host = try canvasHost(w)
        let progress = try requireIndex(of: w.root.importProgressBar, in: w.root, "importProgressBar")
        let notice = try requireIndex(of: w.root.forwardCompatNotice, in: w.root,
                                      "forwardCompatNotice")
        var panels: [(String, Int)] = [
            ("headerGlass", try requireIndex(of: w.root.headerGlass, in: w.root, "headerGlass")),
            ("topBar", try requireIndex(of: w.root.topBar, in: w.root, "topBar")),
            ("canvasHost", try requireIndex(of: host, in: w.root, "canvasHost")),
            ("browserPane", try requireIndex(of: w.root.browserPane.view, in: w.root, "browserPane")),
            ("inspectorHost", try requireIndex(of: w.root.inspectorHost, in: w.root, "inspectorHost")),
            ("filmstripBackdrop", try requireIndex(of: w.root.filmstripBackdrop, in: w.root,
                                                   "filmstripBackdrop")),
            ("filmstrip", try requireIndex(of: w.root.filmstripController.view, in: w.root,
                                           "filmstrip")),
        ]
        for strip in w.root.subviews where strip is WorkspaceDivider {
            panels.append(("divider", try requireIndex(of: strip, in: w.root, "divider")))
        }

        print("""
        402 ④ · \(try inventory(w)) · importProgressBar[\(progress)] forwardCompatNotice[\(notice)] · \
        max panel index \(panels.map(\.1).max() ?? -1)
        """)

        for (name, i) in panels {
            XCTAssertGreaterThan(progress, i, "④ importProgressBar[\(progress)] 必须高于 \(name)[\(i)]")
            XCTAssertGreaterThan(notice, i, "④ forwardCompatNotice[\(notice)] 必须高于 \(name)[\(i)]")
        }
    }
}
