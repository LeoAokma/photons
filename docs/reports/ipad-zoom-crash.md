# iPad 100% zoom crash

Branch: `codex/ipad-zoom-crash-fix`, based on the tested panorama-fixes branch at `1198925`. Local development only; the owner requested no PR for now. Existing worktrees are preserved. Do not rebase this work onto the unexpectedly rewound upstream main.

| Tracking | Acceptance | Dependency |
| --- | --- | --- |
| IPAD-ZOOM-01 | Reject unsupported source textures with a recoverable error before Metal can abort. | Existing shared RAW decoder/render graph |
| IPAD-ZOOM-02 | Render detail within device and memory limits; retain zoom geometry and disclose any reduced detail resolution. | IPAD-ZOOM-01, existing iPad zoom |

## Evidence

Two local simulator reports at 02:12:17 and 02:12:29 on 2026-11-17 (America/New_York) end in SIGABRT inside `MTLTextureDescriptorInternal.validateWithDevice`, called from `RAWDecoder.decodeDetailed` through `MobileEngine.detail`. The simulator log reports a 11664 × 8750 texture against an 8192 × 8192 limit. The old check considered approximate memory only, so it did not prevent this invalid allocation. The owner confirmed the failure was in this local simulator. No physical-device failure is claimed.

Apple documents hardware-family texture dimensions in [Metal Feature Set Tables](https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf). The simulator needs its own conservative limit, independent of the host Mac GPU. Do not infer simulated M5 texture support from the simulated device name.

## IPAD-ZOOM-01 — `b9e2c5e`

Added shared source-texture validation before RAW texture allocation and RenderGraph source upload (including orientation). Oversized inputs now throw a recoverable `TextureDimensionError`; the simulator limit is 8192, and physical GPU families use the documented limits. Pixel arithmetic and decode settings are unchanged.

Validation: Mac package compiled; texture-dimension rejection and 9 existing window-rendering tests passed. The filter also selected an existing social-media window UI test, which passed (11 Mac tests total). iPad simulator build and 2 tests passed: the local 100 MP RAW now reports 11664 × 8750 exceeding 8192 without terminating, and ordinary edited-photo detail still matches full-resolution pixels. No device test was run. Private crash reports and RAW samples are retained locally, outside Git.

## IPAD-ZOOM-02 — adaptive detail resolution

The detail renderer now budgets the complete decoded source, viewport intermediates/halo and retained stages before decoding. It selects a stable resolution that fits texture dimensions and an estimated memory budget (60% of available memory, capped at 2 GiB); existing source storage is accounted for during panning. Invalid viewport requests and extremely low memory return a recoverable message while keeping the preview. Cancelled work is checked before decoding, and temporary decode/render objects are bounded by an autorelease pool.

Zoom geometry is unchanged: 100%/200%/Fit and panning still refer to original photo dimensions. Normal-size photos retain true 1:1 detail. For the local 11664 × 8750 RAW on the simulator, the detail source is 50%; the UI explicitly shows **Detail preview limited to 50% resolution** (Chinese: **细节预览分辨率限制为 50%**). This is higher-resolution detail than the fit preview, but it is not a claim of native 100% detail for that oversized photo. Full-source tiling is not implemented in this change. No HDR mapping, edit arithmetic, or export resolution is silently changed.

The effective detail resolution participates in the cache key; paired HDR/SDR patches and the decoded source are reused. Files: MobileDetailSizing, MobileEngine, MobilePhotoCanvas, MobileWorkspaceModel, English/Chinese resources, iPad engine/UI tests. Depends on IPAD-ZOOM-01 and the existing iPad zoom implementation in the preserved `1198925` baseline.

### Validation

Final validation used the repository's original pinned packages (GRDB 7.11.1, NonlocalMatchFilter 1.0.0), `-onlyUsePackageVersionsFromResolvedFile`, and iPad Pro 13-inch (M5) simulator / iOS 27.2. No dependency changes are committed.

Six engine tests and two UI tests passed across the final runs, with no remaining skips:

- Oversized actual RAW returns a typed error instead of Metal SIGABRT.
- Detail sizing respects texture/memory limits, preserves normalized viewport geometry and rejects malformed requests.
- Under very low memory, detail does not decode and the cached photo remains available.
- Bounded detail pixels match the visible region of a full edited render at the declared resolution, including exposure, crop and rotation (maximum difference below 0.015 in half-float channel values).
- The actual 100 MP RAW produces a 1004 × 785 detail patch at 50%; HDR/SDR reuse does not rerender and panning reuses the source decode. The model keeps the base preview and clears the notice on Fit.
- Existing ordinary-photo 1:1 detail pixel test still passes.
- Existing double-tap Fit / 50% / 200% / custom magnification UI test passes.
- Actual RAW UI test passes 100% → pan → 200% → HDR/SDR → Fit → 100%, checking foreground survival and the explicit 50% detail notice.

Commands: `xcodebuild ... build-for-testing` followed by `test-without-building` for the locally bundled RAW UI fixture; engine reruns use `xcodebuild ... test`, all with the pinned-package flag. Logs: `/tmp/photons-zoom-final-validation.log` (four engine tests plus both UI tests passed; two test assertions needed refinement) and `/tmp/photons-zoom-final-pixel-tests.log` (the remaining two passed). The pixel assertion now compares the visible area rather than the halo's offscreen border; decode reuse checks the detail rung rather than unrelated thumbnail decodes in the host app. Earlier UI testing caught and fixed the localization placeholder format. An initial fixture-copy attempt used a stale simulator container UUID and skipped the optional UI test; the final fixture-enabled run executed it successfully.

`git diff --check` passed. This is targeted simulator/Mac validation, not a full-suite or physical-iPad claim. The conservative detail budget is an estimate, not a proof against every possible system memory-pressure event.

### Delivery / revert

Local branch `codex/ipad-zoom-crash-fix`; no PR, remote push or TestFlight upload. IPAD-ZOOM-02 can be reverted independently (retaining the source guard); reverting IPAD-ZOOM-01 removes crash protection and should also remove its dependent sizing API use. Both commits carry detailed provenance and validation. Existing branches/worktrees and original photos are preserved. Optional RAW files and screenshots remain ignored under `local/` / `.build/`.
