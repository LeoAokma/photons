# macOS perspective stitching

Base: upstream/main `737f92d54056bf4f77fe93daa1c366e6bae639a1`. Branch: `codex/mac-perspective-stitching`.

The request is to audit the iPad perspective stitcher and expose the shared capability on macOS in a separate PR. HDR/LCC image-quality diagnosis is separate and makes no production rendering changes.

## Independent changes and dependencies

| ID | Acceptance goal | Dependencies |
| --- | --- | --- |
| MAC-PERSPECTIVE-01 | Preserve the capture mode across the export-worker snapshot; read legacy snapshots as shift. | None |
| MAC-PERSPECTIVE-02 | Reject projective transforms whose horizon crosses a source image before computing canvas bounds or rendering restored geometry. | None |
| MAC-PERSPECTIVE-03 | Enable Mac perspective selection, appropriate controls and failure handling; retain shift behavior. | 01, 02 |

## MAC-PERSPECTIVE-01 — export capture mode

Previously the private worker snapshot preserved projective matrices but omitted `registrationMode`, so restoring a perspective plan silently changed it to shift. The snapshot now records the mode and defaults missing legacy values to shift, including old shift captures which used projective registration as a fallback.

Files: `PanoramaSnapshot.swift`, `PanoramaProvenanceTests.swift`. Validation: `swift test --filter PanoramaProvenanceTests` passed 4 tests, 0 failures on 2026-11-17. Limitations: old snapshots cannot recover an omitted capture mode; interpreting them as shift preserves the previous contract. This change is additive and can be reverted independently before the Mac entry point is enabled.
