# macOS perspective stitching

Base: upstream/main `737f92d54056bf4f77fe93daa1c366e6bae639a1`. Branch: `codex/mac-perspective-stitching`.

The request is to audit the iPad perspective stitcher and expose the shared capability on macOS in a separate PR. HDR/LCC image-quality diagnosis is separate and makes no production rendering changes.

## Independent changes and dependencies

| ID | Acceptance goal | Dependencies |
| --- | --- | --- |
| MAC-PERSPECTIVE-01 | Preserve the capture mode across the export-worker snapshot; read legacy snapshots as shift. | None |
| MAC-PERSPECTIVE-02 | Reject projective transforms whose horizon crosses a source image before computing canvas bounds or rendering restored geometry. | None |
| MAC-PERSPECTIVE-03 | Enable Mac perspective selection, appropriate controls and failure handling; retain shift behavior. | 01, 02 |

## MAC-PERSPECTIVE-01 — export capture mode (`024c3ce`)

Previously the private worker snapshot preserved projective matrices but omitted `registrationMode`, so restoring a perspective plan silently changed it to shift. The snapshot now records the mode and defaults missing legacy values to shift, including old shift captures which used projective registration as a fallback.

Files: `PanoramaSnapshot.swift`, `PanoramaProvenanceTests.swift`. Validation: `swift test --filter PanoramaProvenanceTests` passed 4 tests, 0 failures on 2026-11-17. Limitations: old snapshots cannot recover an omitted capture mode; interpreting them as shift preserves the previous contract. This change is additive and can be reverted independently before the Mac entry point is enabled.


## MAC-PERSPECTIVE-02 — finite image domains

An invertible homography can have finite corners while a projective horizon crosses its interior. Four individually plausible transforms reproduce this after composition. Check the affine denominator at all four corners for a consistent sign and a relative distance from zero before computing the canvas. Apply the same validation to direct preview/export plans, worker snapshots and portable manifests.

Files: `PanoramaTransform.swift`, `PanoramaEngine.swift`, `PanoramaSnapshot.swift`, `PanoramaManifest.swift`, two panorama test suites, English/Chinese messages. Validation: `swift test --filter 'ProjectiveRegistrationTests|PanoramaProvenanceTests'` passed 8 tests, 0 failures. Includes composed-horizon rejection, invertible negative matrix scale, on-edge horizons, invalid restored/direct plans, robust fitting with outliers, unrelated/collinear matches and metadata round trips. Limits: this validates the geometric domain, not scene parallax or aesthetic registration quality. No solver thresholds, HDR/LCC pixel operations or shift behavior changed. No dependencies; the Mac entry point depends on this guard.
