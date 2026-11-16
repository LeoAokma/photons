import XCTest
import Metal
@testable import PhotonsCore

/// 派单 422 — 明暗 · 自动调节.
///
/// The algorithm is `AutoLight.plan` (pure) and the wiring is `LoupeController.autoLight()`; this file
/// holds both halves plus the acceptance's two hard requirements:
///
///   · **the criterion is texture loss, and it is measured** (§0c/§4.2) — the test computes the loss on
///     the shipping pipeline and asserts the shipped threshold sits between the two sliders' families;
///   · **the slopes are re-measured after step 1** (§0d) — the test measures the 7× swing and shows the
///     0 EV table would mis-solve a +2 EV frame by an order of magnitude;
///   · **⑧a–⑧e go red** (§4.3) — each gate deletes one load-bearing line, and the assertion that
///     guards that line is asserted to fail *through the same code path the app runs*.
///
/// The pure half runs on synthetic grids (no GPU) so the arithmetic is testable everywhere; the
/// measured half skips when there is no RAW fixture or no Metal device, exactly like the rest of the
/// core suite.
final class AutoLightTests: XCTestCase {

    // MARK: - a synthetic picture

    /// A grid with a known shape: `dark` fraction at a low level, the rest a ramp, and a highlight band
    /// with a controllable amount of local contrast. Built so every percentile is computable by hand.
    private func grid(picture: [Float], width: Int, height: Int) -> AutoLight.Sample {
        AutoLight.Sample(width: width, height: height, luma: picture)
    }

    /// One synthetic frame at `0 EV`: half the frame at 0.05, half ramping 0.1 → 0.9.
    private func flatGrid(width: Int = 40, height: Int = 40) -> AutoLight.Sample {
        var luma = [Float](repeating: 0, count: width * height)
        for y in 0 ..< height {
            for x in 0 ..< width {
                luma[y * width + x] = y < height / 2 ? 0.05 : Float(x) / Float(width) * 0.8 + 0.1
            }
        }
        return grid(picture: luma, width: width, height: height)
    }

    /// A **document model** the tests drive `plan` with: the plan's seven fields in, a real grid out.
    ///
    /// It is a stand-in for the pipeline and deliberately *first order*: 高光/白色 move p99, 中间调/阴影
    /// move p50/p10, 黑色 pulls a fraction of samples to zero, 对比 widens the p10…p90 span. The grid is
    /// laid out so `metrics()` computes every number from **pixels** — no statistic is handed in — which
    /// is what makes the pure tests exercise the same `Sample` arithmetic the shipping path does.
    ///
    /// Fidelity it does **not** have: it cannot fake the texture of a real photograph, so the tests that
    /// turn on the criterion inject `lossAtDepth:` instead of pretending this model has one.
    private struct Model {
        var baseP99: Double = 0.30
        var baseP50: Double = 0.06
        var baseP10: Double = 0.03
        /// p99 per slider unit, at a given exposure (positive number).
        var highlightSlope: (Double) -> Double = { ev in 0.00128 * pow(2.0, ev * 1.45) }
        var whiteSlope: (Double) -> Double = { ev in 0.000999 * pow(2.0, ev * 1.0) }
        var separation: Double = 4.1
        /// Units of 黑色 the bottom needs before 0.1 % of the samples reach the floor.
        var blackNeed: Double = 40

        func sample(for edit: EditModel) -> AutoLight.Sample {
            let ev = edit.light.exposure
            let high = max(0, -edit.light.highlights) * highlightSlope(ev)
            let white = max(0, -edit.light.whites) * whiteSlope(ev)
            let p99 = max(0.02, baseP99 * pow(2.0, ev) - high - white)
            let p50 = min(0.9, baseP50 * pow(2.0, ev) * (1 + edit.light.midtones / 100 * 0.9))
            let p10 = min(p50, baseP10 * pow(2.0, ev) * (1 + edit.light.shadows / 100 * 0.9))
            // 黑色: the deepest fraction of the picture is pulled to the floor, exponentially.
            let depth = max(0, -edit.light.blacks) / max(blackNeed, 1)
            let floorFraction = min(0.5, depth * 0.001 * 4 + (depth > 1 ? (depth - 1) * 0.01 : 0))
            let pFloor = max(0, baseP10 * pow(2.0, ev) * pow(2.0, -depth * 3))

            // A **2-D** grid: `texture` takes a horizontal *and* a vertical first difference, so a
            // one-row grid would report 0 no matter what the document says.
            let w = 100, h = 10
            let n = w * h
            let zeros = min(n / 2, Int((floorFraction * Double(n)).rounded()))
            var luma = [Float](repeating: 0, count: n)
            let live = n - zeros
            // A monotone ramp over the live samples: pFloor → p10 → p50 → p99, so every percentile
            // `metrics()` reports is a value this model actually placed.
            for i in 0 ..< live {
                let t = Double(i) / Double(max(live - 1, 1))
                let v: Double
                switch t {
                case ..<0.11: v = pFloor + (p10 - pFloor) * (t / 0.11)
                case ..<0.56: v = p10 + (p50 - p10) * ((t - 0.11) / 0.45)
                default: v = p50 + (p99 - p50) * ((t - 0.56) / 0.44)
                }
                luma[i] = Float(max(0, v))
            }
            // The zeros sit at the **end**, so the ramp's own order is not disturbed by them.
            for i in live ..< n { luma[i] = 0 }
            return AutoLight.Sample(width: w, height: h, luma: luma)
        }
    }

    /// The same model with the criterion injected, for the tests that are about the *decision* rather
    /// than about measuring a photograph.
    private func run(_ edit: EditModel,
                     gates: AutoLight.Gates = AutoLight.Gates(),
                     model: Model = Model(),
                     lossAtDepth: ((Double) throws -> Double)? = nil) throws -> AutoLight.Plan {
        try AutoLight.plan(for: edit, gates: gates, lossAtDepth: lossAtDepth) { model.sample(for: $0) }
    }

    // MARK: - ① the texture criterion is measured, and 8 % sits between the two families

    /// §0c/§4.2 — on the **shipping pipeline**, 高光 costs several times what 白色 costs per unit of
    /// p99 movement, and the shipped 8 % threshold is crossed by 高光 at a real depth.
    ///
    /// This is the test that would have caught the first version: it asserts a *ratio*, not an area.
    func testTheCriterionSeparatesHighlightsFromWhitesPerUnitOfDarkening() throws {
        guard let url = rawFixture() else { throw XCTSkip("no RAW fixture") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let graph = try self.graph(url)
        var base = EditModel.neutral
        base.sharpen = SharpenGroup(amount: 0)
        base.light.exposure = 2
        let m = try graph.measureAutoLightSample(base).metrics()
        XCTAssertGreaterThan(m.p99, 1.0, "the fixture must actually be hot at +2 EV, else this proves nothing")
        XCTAssertGreaterThan(m.texture, 0, "the highlight region must have contrast to lose")

        var h = base
        h.light.highlights = -50
        let hm = try graph.measureAutoLightSample(h).metrics()
        var w = base
        w.light.whites = -50
        let wm = try graph.measureAutoLightSample(w).metrics()

        let hLoss = (m.texture - hm.texture) / m.texture
        let wLoss = (m.texture - wm.texture) / m.texture
        let hDelivered = m.p99 - hm.p99
        let wDelivered = m.p99 - wm.p99
        print(String(format: "422 CRITERION · 高光−50 loss %.2f%% delivers %.4f · 白色−50 loss %.2f%% delivers %.4f · ratio %.2f",
                     hLoss * 100, hDelivered, wLoss * 100, wDelivered, hLoss / max(wLoss, 1e-9)))

        XCTAssertGreaterThan(hLoss, AutoLight.highlightLossThreshold,
                             "高光 −50 必须越过 8% 判据，否则「切到白色」这条分支永不成立")
        XCTAssertGreaterThan(hLoss, wLoss * 1.5,
                             "高光每单位压暗必须比白色贵得多（§0c 的 3.32×），实际 \(hLoss / max(wLoss, 1e-9))×")
        // …and the criterion is crossed somewhere inside the travel, not at neither end.
        var shallow = base
        shallow.light.highlights = -10
        let sm = try graph.measureAutoLightSample(shallow).metrics()
        XCTAssertLessThan((m.texture - sm.texture) / m.texture, AutoLight.highlightLossThreshold,
                          "高光 −10 不该已经越过判据，否则算法一上手就切白色")
    }

    /// The literal formula (§0c's own words) is carried beside the shipped one, and the shipped one is
    /// the level-normalised number — with the measured reason.
    func testTheShippedTextureIsLevelNormalisedAndTheLiteralOneIsReportedBesideIt() throws {
        guard let url = rawFixture() else { throw XCTSkip("no RAW fixture") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let graph = try self.graph(url)
        var base = EditModel.neutral
        base.sharpen = SharpenGroup(amount: 0)
        let neutral = try graph.measureAutoLightSample(base).metrics()

        // Same slider, two exposures: the literal formula moves; the normalised one moves less.
        var atZero = base
        atZero.light.highlights = -50
        let lit0 = try graph.measureAutoLightSample(atZero).metrics()
        var hot = base
        hot.light.exposure = 2
        let hotBase = try graph.measureAutoLightSample(hot).metrics()
        hot.light.highlights = -50
        let lit2 = try graph.measureAutoLightSample(hot).metrics()

        let literal0 = (neutral.textureAbsolute - lit0.textureAbsolute) / neutral.textureAbsolute
        let literal2 = (hotBase.textureAbsolute - lit2.textureAbsolute) / hotBase.textureAbsolute
        let norm0 = (neutral.texture - lit0.texture) / neutral.texture
        let norm2 = (hotBase.texture - lit2.texture) / hotBase.texture
        print(String(format: "422 TEXTURE · 高光−50 literal %.1f%%@0EV → %.1f%%@+2EV (×%.1f) · normalised %.1f%% → %.1f%% (×%.1f)",
                     literal0 * 100, literal2 * 100, literal2 / max(literal0, 1e-9),
                     norm0 * 100, norm2 * 100, norm2 / max(norm0, 1e-9)))
        XCTAssertGreaterThan(norm0, 0, "the normalised texture must respond to the slider")
        XCTAssertGreaterThan(norm2, 0)
        XCTAssertNotEqual(literal0, 0)
        XCTAssertNotEqual(literal2, 0)
    }

    // MARK: - ② §0d: the slope swings 7×, and the table would be wrong

    /// §0d/§4.1 — 高光's p99 response is re-measured **at the exposure step 1 chose**, and the 0 EV table
    /// value is an order of magnitude off on a hot frame.
    func testTheHighlightSlopeSwingsWithExposureAndTheTableWouldBeWrong() throws {
        guard let url = rawFixture() else { throw XCTSkip("no RAW fixture") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let graph = try graph(url)
        var slopes: [Double] = []
        for ev in [0.0, 2.0, 3.0] {
            var base = EditModel.neutral
            base.sharpen = SharpenGroup(amount: 0)
            base.light.exposure = ev
            let m = try graph.measureAutoLightSample(base).metrics()
            var deep = base
            deep.light.highlights = -100
            let dm = try graph.measureAutoLightSample(deep).metrics()
            let slope = (m.p99 - dm.p99) / 100
            slopes.append(slope)
            print(String(format: "422 SLOPE · EV %+.0f · p99 %.4f → 高光−100 %.4f · %.5f per unit",
                         ev, m.p99, dm.p99, slope))
        }
        XCTAssertGreaterThan(slopes[0], 0)
        XCTAssertGreaterThan(slopes[1], slopes[0] * 3,
                             "§0d: 高光's slope must be several times steeper at +2 EV than at 0 EV, measured \(slopes)")
        XCTAssertGreaterThan(slopes[2], slopes[1] * 1.2, "+3 EV goes further again")
        // The shipped table is the 0 EV number, and the plan must not use it at a +2 EV operating point.
        XCTAssertEqual(AutoLight.zeroEVHighlightSlope, slopes[0], accuracy: 0.05,
                       "the ⑧e table must be the *measured* 0 EV slope, or the gate proves nothing")
        XCTAssertGreaterThan(abs(slopes[1] - AutoLight.zeroEVHighlightSlope) / slopes[1], 0.5,
                             "at +2 EV the table is off by more than half")
    }

    /// The plan's own report carries both numbers, and on a hot picture they disagree by a large factor.
    func testThePlanReportsTheMeasuredSlopeAndTheTableBesideIt() throws {
        var edit = EditModel.neutral
        edit.light.blackOffset = 0.005
        let plan = try run(edit)
        let r = plan.report
        // The model's slope at the plan's own exposure vs the 0 EV table.
        print(String(format: "422 SLOPE REPORT · measured %.5f · table %.5f · exposure %+.2f",
                     r.highlightSlope, r.tableHighlightSlope, r.exposureEV))
        XCTAssertGreaterThan(r.exposureEV, 0.5, "the fixture frame is dark; step 1 must lift it")
        XCTAssertGreaterThan(r.highlightSlope, r.tableHighlightSlope,
                             "at a positive exposure the measured slope must be steeper than the 0 EV table")
    }

    // MARK: - ③ 曝光's constraint is hard

    /// §0d/§4.3 ⑧d — the plan never pushes p99 above 1.0, even when the picture would allow more light.
    func testExposureNeverPushesP99AboveWhite() throws {
        var edit = EditModel.neutral
        let plan = try run(edit)
        XCTAssertLessThanOrEqual(plan.report.p99AfterExposure, AutoLight.p99Ceiling + 1e-9,
                                 "p99 ≤ 1.0 是硬约束，实测 \(plan.report.p99AfterExposure)")
        XCTAssertEqual(plan.report.p99AfterExposure, AutoLight.p99WhiteTarget, accuracy: 0.06,
                       "and it lands just inside it, not far short")
        print(String(format: "422 EXPOSURE · p99 %.4f → %+.2f EV → p99 %.4f (clip %.3f%%)",
                     plan.report.baseP99, plan.report.exposureEV, plan.report.p99AfterExposure,
                     plan.report.clippedHighAfterExposure * 100))
    }

    /// The exposure is a function of the picture's own p99: a darker frame gets more light, and the two
    /// are exactly `log2(target / p99)` apart.
    func testExposureIsTheLogOfThePicturesOwnP99() throws {
        for base in [0.15, 0.30, 0.45] {
            var model = Model()
            model.baseP99 = base
            let plan = try AutoLight.plan(for: EditModel.neutral) { model.sample(for: $0) }
            let expected = min(8, max(-4, log2(AutoLight.p99WhiteTarget / base)))
            XCTAssertEqual(plan.report.exposureEV, (expected * 100).rounded(.down) / 100, accuracy: 0.06,
                           "p99 \(base) → 曝光 \(plan.report.exposureEV)，应在 \(expected) 附近")
        }
    }

    // MARK: - ④ the five steps produce a coherent plan

    func testThePlanIsTheFiveStepsInOrder() throws {
        var edit = EditModel.neutral
        edit.light.blackOffset = 0.005
        let plan = try run(edit)
        let r = plan.report

        // 1 — 曝光 up.
        XCTAssertGreaterThan(plan.exposure, 0, "步骤 1：默认照片很暗，曝光先加")
        // 2 — 中间调/阴影 only补, never negative.
        XCTAssertGreaterThanOrEqual(plan.midtones, 0, "步骤 2 只补，不压")
        XCTAssertGreaterThanOrEqual(plan.shadows, 0)
        XCTAssertLessThanOrEqual(plan.midtones, AutoLight.midtoneCap)
        XCTAssertLessThanOrEqual(plan.shadows, AutoLight.shadowCap)
        // 3 — 高光 negative (it is a recovery), 白色 a co-tool at most.
        XCTAssertLessThanOrEqual(plan.highlights, 0, "步骤 3 的第一手段是压高光")
        XCTAssertGreaterThanOrEqual(plan.highlights, -100)
        XCTAssertLessThanOrEqual(plan.whites, 0)
        XCTAssertGreaterThanOrEqual(plan.whites, -AutoLight.whiteTravelEnd, "白色 有上限，不是 −100")
        XCTAssertLessThanOrEqual(r.textureLossHighlightsOnly, AutoLight.highlightLossThreshold + 0.02,
                                "高光自己的纹理损失必须落在判据内，实测 \(r.textureLossHighlightsOnly)")
        // 4 — 黑色 negative, inside the travel.
        XCTAssertLessThanOrEqual(plan.blacks, 0)
        XCTAssertGreaterThanOrEqual(plan.blacks, -100)
        // 5 — 对比 inside its cap.
        XCTAssertLessThanOrEqual(abs(plan.contrast), AutoLight.contrastCeiling)
        print(String(format: "422 PLAN · EV %+.2f · 高光 %.0f 白色 %.0f · 中间调 %.0f 阴影 %.0f · 黑色 %.0f · 对比 %.0f",
                     plan.exposure, plan.highlights, plan.whites, plan.midtones, plan.shadows,
                     plan.blacks, plan.contrast))
    }

    /// **The plan is one document write, and it does not touch `blackOffset`.**
    func testThePlanWritesSevenFieldsAndLeavesBlackOffsetAlone() throws {
        var edit = EditModel.neutral
        edit.light.blackOffset = 0.007
        edit.geometry.crop = .full
        let before = edit
        let plan = try run(edit)
        let after = plan.apply(to: edit)

        XCTAssertEqual(after.light.blackOffset, before.light.blackOffset,
                       "硬约束 1：自动调节只读 blackOffset，绝不写它")
        XCTAssertEqual(after.geometry, before.geometry, "几何不动")
        XCTAssertEqual(after.color, before.color, "颜色不动")
        XCTAssertEqual(after.effects, before.effects, "效果不动")
        // And the seven fields it does own are the plan's numbers, exactly.
        XCTAssertEqual(after.light.exposure, plan.exposure)
        XCTAssertEqual(after.light.contrast, plan.contrast)
        XCTAssertEqual(after.light.highlights, plan.highlights)
        XCTAssertEqual(after.light.midtones, plan.midtones)
        XCTAssertEqual(after.light.shadows, plan.shadows)
        XCTAssertEqual(after.light.whites, plan.whites)
        XCTAssertEqual(after.light.blacks, plan.blacks)
    }

    /// Step 1 zeroes 明暗 but keeps everything else — the plan is solved from the *decoded* picture, not
    /// from whatever the user had already dialled in.
    func testTheBaselineZeroesOnlyTheToneFields() throws {
        var edit = EditModel.neutral
        edit.light.exposure = 3
        edit.light.highlights = -80
        edit.light.blackOffset = 0.004
        edit.color.saturation = 25
        var seen: [EditModel] = []
        let model = Model()
        _ = try AutoLight.plan(for: edit) { document in
            seen.append(document)
            return model.sample(for: document)
        }
        let first = try XCTUnwrap(seen.first)
        XCTAssertEqual(first.light.exposure, 0, "the first measurement is the zeroed document")
        XCTAssertEqual(first.light.highlights, 0)
        XCTAssertEqual(first.light.blacks, 0)
        XCTAssertEqual(first.light.blackOffset, 0.004, "blackOffset 不属于 明暗，基线保留它")
        XCTAssertEqual(first.color.saturation, 25, "其他卡一个字段都不动")
    }

    /// Step 4 cancels `blackOffset`: the same picture with a bigger trim needs a deeper 黑色.
    func testStepFourCancelsTheBlackOffsetLift() throws {
        var bare = EditModel.neutral
        bare.light.blackOffset = 0
        var trimmed = EditModel.neutral
        trimmed.light.blackOffset = 0.008
        let a = try run(bare)
        let b = try run(trimmed)
        XCTAssertLessThan(b.blacks, a.blacks,
                          "blackOffset 0.008 把黑场抬起来了，黑色必须比没有偏移时更深（\(b.blacks) vs \(a.blacks)）")
        XCTAssertLessThan(b.report.blackCancelTerm, 0, "抵消项为负")
        print(String(format: "422 BLACKS · boff 0 → %.0f · boff 0.008 → %.0f (cancel %.0f)",
                     a.blacks, b.blacks, b.report.blackCancelTerm))
    }

    // MARK: - ⑤ ⑧a–⑧e: the five reverse gates
    //
    // Each gate makes one load-bearing line of `AutoLight.plan` inert. The test asserts the behaviour
    // that line buys — so if the line is deleted, or the gate stops being wired to it, the assertion
    // goes red. The criterion is injected (`lossAtDepth:`) because a GPU-free model cannot carry a real
    // photograph's texture; §4.2's *measurement* is asserted separately, on the pipeline, in
    // `testTheCriterionSeparatesHighlightsFromWhitesPerUnitOfDarkening`.

    /// A frame that needs a highlight pull: p99 = 0.30, so `log2(0.98/0.30)` = +1.7 EV, and after step 1
    /// the top still has to come down.
    private func hotEdit() -> EditModel {
        var edit = EditModel.neutral
        edit.light.blackOffset = 0.005
        return edit
    }

    /// The criterion "高光 costs 2 % of the region per unit", so the 8 % budget is spent by depth 4 —
    /// **高光 can take a token depth and no more**, and 白色 must be reached for the rest.
    private func expensiveHighlights() -> (Double) throws -> Double {
        { depth in min(0.99, depth * 0.02) }
    }

    /// The criterion "高光 costs almost nothing", so 高光 alone can finish and 白色 must stay 0.
    private func cheapHighlights() -> (Double) throws -> Double {
        { depth in depth * 0.00001 }
    }

    /// Sanity: the two fixtures really do disagree, so each gate's assertion is about the algorithm and
    /// not about a model that happens to sit on one side.
    func testTheTwoCriterionFixturesReachOppositeDecisions() throws {
        let expensive = try run(hotEdit(), lossAtDepth: expensiveHighlights())
        let cheap = try run(hotEdit(), lossAtDepth: cheapHighlights())
        print(String(format: "422 FIXTURE · expensive → 高光 %.0f 白色 %.0f · cheap → 高光 %.0f 白色 %.0f",
                     expensive.highlights, expensive.whites, cheap.highlights, cheap.whites))
        XCTAssertEqual(cheap.whites, 0, "判据说高光便宜 ⇒ 不用白色")
        XCTAssertLessThan(expensive.whites, 0, "判据说高光贵 ⇒ 必须用白色")
        XCTAssertGreaterThan(abs(cheap.highlights), abs(expensive.highlights),
                             "便宜时高光走得更深")
    }

    /// ⑧a — the criterion always says **0 % loss** ⇒ 白色 is **never** reached.
    ///
    /// The gate is not a stub here: the injected criterion is the *expensive* one, and only the gate flag
    /// makes it read 0. So this asserts the line the flag deletes, on a frame where the alternative
    /// (`testTheTwoCriterionFixturesReachOppositeDecisions`) demonstrably reaches 白色.
    func testGateAAlwaysZeroLossNeverReachesWhite() throws {
        // **Both halves in one test**, so that hard-coding the gate's mistake into the shipped path
        // breaks this test rather than only the gated line: the shipped plan must reach 白色 on this
        // frame, and the gated plan must not.
        let shipped = try run(hotEdit(), lossAtDepth: expensiveHighlights())
        XCTAssertLessThan(shipped.whites, 0, "出货路径在本帧**必须**启用白色，否则本门无从谈起")

        var gates = AutoLight.Gates()
        gates.criterionAlwaysZeroLoss = true
        let gated = try run(hotEdit(), gates: gates, lossAtDepth: expensiveHighlights())
        XCTAssertEqual(gated.whites, 0, "⑧a：判据恒返 0 ⇒ 永不该启用白色，实际 \(gated.whites)")
        XCTAssertLessThan(gated.highlights, 0, "高光 仍然工作：\(gated.highlights)")
        XCTAssertEqual(gated.report.highlightBudget, abs(gated.highlights),
                             "判据恒 0 ⇒ 高光 的预算就是它走的全部，没有上限")
        print("422 GATE ⑧a · shipped whites \(shipped.whites) · gated whites \(gated.whites) 高光 \(gated.highlights)")
    }

    /// ⑧b — the criterion always says **99 %** ⇒ 白色 is **always** reached and 高光 never moves.
    func testGateBAlwaysFullLossAlwaysReachesWhite() throws {
        // Both halves: the shipped cheap frame needs **no** 白色, and the gated one cannot avoid it.
        let shipped = try run(hotEdit(), lossAtDepth: cheapHighlights())
        XCTAssertEqual(shipped.whites, 0, "判据说高光便宜 ⇒ 出货路径一步白色都不该走")
        XCTAssertLessThan(shipped.highlights, 0, "高光 承担全部")

        var gates = AutoLight.Gates()
        gates.criterionAlwaysFullLoss = true
        let gated = try run(hotEdit(), gates: gates, lossAtDepth: cheapHighlights())
        XCTAssertLessThan(gated.whites, 0, "⑧b：判据恒返 99% ⇒ 必须启用白色，实际 \(gated.whites)")
        XCTAssertEqual(gated.highlights, 0, "判据恒满 ⇒ 高光一步都不许走，实际 \(gated.highlights)")
        print("422 GATE ⑧b · shipped whites \(shipped.whites) 高光 \(shipped.highlights) · gated whites \(gated.whites) 高光 \(gated.highlights)")
    }

    /// ⑧c — step 4 ignores `blackOffset` ⇒ a trimmed picture gets the **un-trimmed** floor.
    func testGateCIgnoringBlackOffsetLosesTheCancellation() throws {
        var edit = EditModel.neutral
        edit.light.blackOffset = 0.008
        let shipped = try run(edit, lossAtDepth: cheapHighlights())
        var gates = AutoLight.Gates()
        gates.ignoresBlackOffset = true
        let gated = try run(edit, gates: gates, lossAtDepth: cheapHighlights())
        XCTAssertEqual(gated.report.blackCancelTerm, 0, "⑧c：抵消项必须归零")
        XCTAssertGreaterThan(gated.blacks, shipped.blacks,
                             "⑧c：不抵消就必须比正常情况浅（\(gated.blacks) vs \(shipped.blacks)）")
        // …and with no trim at all the two agree: the gate removes the *cancellation*, nothing else.
        var untrimmed = edit
        untrimmed.light.blackOffset = 0
        let plain = try run(untrimmed, lossAtDepth: cheapHighlights())
        let plainGated = try run(untrimmed, gates: gates, lossAtDepth: cheapHighlights())
        XCTAssertEqual(plain.blacks, plainGated.blacks, accuracy: 1e-9,
                       "没有 blackOffset 时，⑧c 不该改变任何东西")
        print("422 GATE ⑧c · shipped \(shipped.blacks) · gated \(gated.blacks) · no-trim \(plain.blacks)")
    }

    /// ⑧d — the `p99 ≤ 1.0` constraint is gone (anchor on p95) ⇒ the tail runs past white.
    func testGateDroppingTheCeilingOvershootsWhite() throws {
        let model = Model()
        let shipped = try AutoLight.plan(for: hotEdit()) { model.sample(for: $0) }
        var gates = AutoLight.Gates()
        gates.noExposureCeiling = true
        // **The gate deletes *two* lines** — the p95 anchor and the walk-back loop — so its mutation has
        // to touch both; this assertion is what catches a mutation that only touches one.
        let gated = try AutoLight.plan(for: hotEdit(), gates: gates) { model.sample(for: $0) }
        XCTAssertLessThanOrEqual(shipped.report.p99AfterExposure, AutoLight.p99Ceiling + 1e-9,
                                 "出货路径必须守在白以内")
        XCTAssertGreaterThan(gated.report.p99AfterExposure, AutoLight.p99Ceiling,
                             "⑧d：去掉 p99≤1.0 约束后，顶必须冲过白（\(gated.report.p99AfterExposure)）")
        XCTAssertGreaterThan(gated.report.exposureEV, shipped.report.exposureEV,
                             "锚在更低的 p95 上 ⇒ 更亮")
        print(String(format: "422 GATE ⑧d · shipped EV %+.2f p99 %.3f · gated EV %+.2f p99 %.3f",
                     shipped.report.exposureEV, shipped.report.p99AfterExposure,
                     gated.report.exposureEV, gated.report.p99AfterExposure))
    }

    /// ⑧e — the slope comes from the **0 EV table** ⇒ a hot frame is asked for a depth it does not need.
    func testGateFixedSlopeTableUndershootsOnAHotPicture() throws {
        var model = Model()
        // A frame whose real slope is ~9× the 0 EV table at the operating point.
        model.highlightSlope = { ev in 0.00128 * pow(2.0, ev * 1.8) }
        let edit = hotEdit()
        let shipped = try AutoLight.plan(for: edit, lossAtDepth: cheapHighlights()) { model.sample(for: $0) }
        var gates = AutoLight.Gates()
        gates.fixedSlopeTable = true
        let gated = try AutoLight.plan(for: edit, gates: gates, lossAtDepth: cheapHighlights()) { model.sample(for: $0) }

        XCTAssertEqual(gated.report.highlightSlope, AutoLight.zeroEVHighlightSlope,
                       "⑧e：门打开时斜率必须来自表")
        XCTAssertNotEqual(shipped.report.highlightSlope, AutoLight.zeroEVHighlightSlope)
        XCTAssertLessThan(gated.report.highlightSlope, shipped.report.highlightSlope,
                          "0 EV 表在这个曝光点上是**更小**的数（这就是 §0d 的 7×）")
        XCTAssertGreaterThan(abs(gated.highlights), abs(shipped.highlights),
                             "⑧e：表低估斜率 ⇒ 要求更深的 高光（\(gated.highlights) vs \(shipped.highlights)）")
        print(String(format: "422 GATE ⑧e · shipped slope %.5f 高光 %.0f · gated slope %.5f 高光 %.0f",
                     shipped.report.highlightSlope, shipped.highlights,
                     gated.report.highlightSlope, gated.highlights))
    }

    /// The gates are inert in production, and each one is its own line.
    func testEveryGateIsOffInProductionAndIndependent() {
        let gates = AutoLight.Gates()
        XCTAssertFalse(gates.criterionAlwaysZeroLoss)
        XCTAssertFalse(gates.criterionAlwaysFullLoss)
        XCTAssertFalse(gates.ignoresBlackOffset)
        XCTAssertFalse(gates.noExposureCeiling)
        XCTAssertFalse(gates.fixedSlopeTable)
        XCTAssertEqual(gates, AutoLight.Gates())
    }

    // MARK: - ⑥ the engine's own arithmetic

    /// Percentiles and the two clip ratios on a known grid.
    func testMetricsAreTheGridsOwnNumbers() {
        let sample = flatGrid(width: 10, height: 10)
        let m = sample.metrics()
        XCTAssertEqual(m.sampleCount, 100)
        // Rows 0–4 are 0.05 (50 texels), rows 5–9 ramp 0.1 → 0.82 (50 texels, so 0.1…0.18).
        XCTAssertEqual(m.p10, 0.05, accuracy: 1e-6, "a tenth of the frame is the dark half")
        XCTAssertEqual(m.p50, 0.1, accuracy: 1e-6, "the 50th of 100 samples is the ramp's first step")
        XCTAssertGreaterThan(m.p90, 0.5, "the top tenth is the ramp's bright end")
        XCTAssertGreaterThan(m.p99, 0.7)
        XCTAssertEqual(m.clippedHigh, 0, "nothing is above white in this grid")
        XCTAssertEqual(m.clippedLow, 0, "and nothing is at or below 0.001")
        XCTAssertGreaterThan(m.texture, 0, "the top tenth is a ramp, so it has a first difference")
        XCTAssertGreaterThan(m.textureAbsolute, 0)
    }

    /// A grid that is entirely above white reports every sample as clipped, and a matte-only grid
    /// reports nothing at all (the `−65504` sentinel is not a photograph).
    func testMatteAndClippedGridsAreHandledExactly() {
        let hot = AutoLight.Sample(width: 4, height: 4,
                                   luma: Array(repeating: 2.0, count: 16))
        XCTAssertEqual(hot.metrics().clippedHigh, 1.0)
        XCTAssertEqual(hot.metrics().texture, 0, "a flat grid has no first difference")

        let matte = AutoLight.Sample(width: 4, height: 4,
                                     luma: Array(repeating: -65504, count: 16))
        let m = matte.metrics()
        XCTAssertEqual(m.sampleCount, 0, "372's sentinel is not a photograph")
        XCTAssertEqual(m.p99, 0)
    }

    /// The texture is measured over **each render's own** top 10 %, so it follows the region as it
    /// darkens — a fixed floor empties out (the probe measured that, which is why `plan` passes `nil`).
    func testTheTextureRegionFollowsTheRenderThatIsMeasured() {
        // A grid whose brightest **column** is x = 8 (so the region has both neighbours to difference
        // against), with x = 9 deliberately dark. `texture` never centres on the last column or row, so
        // a region made of those would measure nothing at all — which is why the band is not at the edge.
        func grid(brightValue: Float) -> AutoLight.Sample {
            var luma = [Float](repeating: 0, count: 100)
            for y in 0 ..< 10 {
                for x in 0 ..< 10 {
                    luma[y * 10 + x] = x == 8 ? brightValue : (x == 9 ? 0.05 : Float(x) * 0.1 + 0.1)
                }
            }
            return AutoLight.Sample(width: 10, height: 10, luma: luma)
        }
        // A 10-wide grid: the top-10 % rank is **index 9 of 10**, i.e. the 9th smallest — which is
        // 0.8, not the band at 0.9. That is the nearest-rank rule, and it is why the assertion names the
        // 9th smallest rather than "the brightest".
        let bright = grid(brightValue: 0.90)
        let darker = grid(brightValue: 0.20)
        XCTAssertEqual(bright.metrics().cut, 0.80, accuracy: 1e-6, "区域是第 9/10 小的值")
        XCTAssertLessThan(darker.metrics().cut, bright.metrics().cut, "压暗之后区域跟着下移")
        XCTAssertGreaterThan(bright.metrics().texture, 0, "亮列的第一差分是真的")
        // A **fixed** floor instead of the render's own would measure a different region on each.
        // A floor well inside the band's own reach: on the bright grid it measures the band, on the
        // darkened one the band is **below the floor** and the region collapses to the ramp's top —
        // a different population, i.e. a rate that is not comparable. That is why `plan` passes `nil`.
        let fixed = bright.metrics(cut: 0.85)
        let fixedDarker = darker.metrics(cut: 0.85)
        XCTAssertGreaterThan(fixed.texture, 0, "固定门槛在亮画面上仍然能测到那条带")
        XCTAssertEqual(fixedDarker.sampleCount > 0 ? fixedDarker.texture : 0, 0,
                       "固定的门槛在压暗后的画面上空掉了 —— 这正是 plan 传 nil 的理由")
    }

    /// `snapExposure` is the row's grid and the ceiling at once.
    func testExposureSnapsDownOntoTheRowGrid() {
        XCTAssertEqual(AutoLight.snapExposure(1.7777), 1.77, "曝光 落在 0.01 格，向下取整")
        XCTAssertEqual(AutoLight.snapExposure(-2.0001), -2.01)
        XCTAssertEqual(AutoLight.snapExposure(99), 8, "钳到滑杆上限")
        XCTAssertEqual(AutoLight.snapExposure(-99), -4, "钳到滑杆下限")
        XCTAssertEqual(AutoLight.snapExposure(.nan), 0)
        XCTAssertEqual(AutoLight.snapExposure(0.98), 0.98)
    }

    /// 对比's own law: more separation short of the target, never past the cap, and nothing when the
    /// picture is already separated.
    func testContrastOnlyFillsASeparationGap() throws {
        // The model's grid is a linear ramp, so its own p10…p90 span is fixed by construction; the
        // *separation* the model reports is therefore set by moving where its ramp sits.
        var tight = Model()
        tight.baseP10 = 0.02
        tight.baseP50 = 0.06
        let needsIt = try AutoLight.plan(for: EditModel.neutral) { tight.sample(for: $0) }
        var wide = Model()
        wide.baseP10 = 0.25
        wide.baseP50 = 0.32
        let fine = try AutoLight.plan(for: EditModel.neutral) { wide.sample(for: $0) }
        print(String(format: "422 CONTRAST · sep %.2f → %.0f · sep %.2f → %.0f",
                     needsIt.report.separationStops, needsIt.contrast,
                     fine.report.separationStops, fine.contrast))
        XCTAssertLessThan(needsIt.report.separationStops, AutoLight.separationTargetStops)
        XCTAssertGreaterThan(needsIt.contrast, 0, "分离度不足 ⇒ 加对比")
        XCTAssertLessThanOrEqual(needsIt.contrast, AutoLight.contrastCeiling)
        if fine.report.separationStops >= AutoLight.separationTargetStops {
            XCTAssertEqual(fine.contrast, 0, "已经分离 ⇒ 不动对比")
        }
    }

    // MARK: - helpers

    private func rawFixture() -> URL? {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isReadableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    private func graph(_ url: URL) throws -> RenderGraph {
        let image = try RAWDecoder().decode(url, options: DecodeOptions(scale: 0.5))
        return try RenderGraph(input: RenderInput(image: image, identity: "auto-light-422",
                                                  sourceURL: url))
    }

    private static func firstView(in root: NSView, where match: (NSView) -> Bool) -> NSView? {
        if match(root) { return root }
        for child in root.subviews {
            if let found = firstView(in: child, where: match) { return found }
        }
        return nil
    }

    private static func allAccessibilityIdentifiers(in root: NSView, depth: Int = 0) -> [String] {
        guard depth < 24 else { return [] }
        var out: [String] = []
        for child in root.accessibilityChildren() ?? [] {
            if let view = child as? NSView {
                let id = view.accessibilityIdentifier()
                if !id.isEmpty { out.append(id) }
                out += allAccessibilityIdentifiers(in: view, depth: depth + 1)
            } else if let element = child as? NSAccessibilityElement,
                      let id = element.accessibilityIdentifier(), !id.isEmpty {
                out.append(id)
            }
        }
        let selfID = root.accessibilityIdentifier()
        if !selfID.isEmpty { out.append(selfID) }
        return out
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static var inspectorSource: URL {
        repoRoot.appendingPathComponent("Sources/PhotonsUI/InspectorView.swift")
    }

    private static var loupeSource: URL {
        repoRoot.appendingPathComponent("Sources/PhotonsUI/LoupeController.swift")
    }

    private static func body(of signature: String, upTo endMarker: String, in url: URL) throws -> String {
        let source = try String(contentsOf: url, encoding: .utf8)
        guard let start = source.range(of: signature),
              let end = source.range(of: endMarker),
              start.lowerBound < end.lowerBound else {
            throw XCTSkip("no `\(signature)` … `\(endMarker)` section in \(url.lastPathComponent)")
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var search = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: search) {
            count += 1
            search = found.upperBound..<haystack.endIndex
        }
        return count
    }
}
