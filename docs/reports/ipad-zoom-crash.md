# iPad 100% zoom crash

Branch: `codex/ipad-zoom-crash-fix`, based on the tested panorama-fixes branch at `1198925`. Local development only; the owner requested no PR for now. Existing worktrees are preserved. Do not rebase this work onto the unexpectedly rewound upstream main.

| Tracking | Acceptance | Dependency |
| --- | --- | --- |
| IPAD-ZOOM-01 | Reject unsupported source textures with a recoverable error before Metal can abort. | Existing shared RAW decoder/render graph |
| IPAD-ZOOM-02 | Render detail within device and memory limits; retain zoom geometry and disclose any reduced detail resolution. | IPAD-ZOOM-01, existing iPad zoom |

## Evidence

Two local simulator reports at 02:12:17 and 02:12:29 on 2026-11-17 (America/New_York) end in SIGABRT inside `MTLTextureDescriptorInternal.validateWithDevice`, called from `RAWDecoder.decodeDetailed` through `MobileEngine.detail`. The simulator log reports a 11664 × 8750 texture against an 8192 × 8192 limit. The old check considered approximate memory only, so it did not prevent this invalid allocation. This is direct evidence for the local simulator failure; no physical-device crash report has been supplied.

Apple documents hardware-family texture dimensions in [Metal Feature Set Tables](https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf). The simulator needs its own conservative limit, independent of the host Mac GPU. Do not infer simulated M5 texture support from the simulated device name.

## IPAD-ZOOM-01

Added shared source-texture validation before RAW texture allocation and RenderGraph source upload (including orientation). Oversized inputs now throw a recoverable `TextureDimensionError`; the simulator limit is 8192, and physical GPU families use the documented limits. Pixel arithmetic and decode settings are unchanged.

Validation: Mac package compiled; texture-dimension rejection and 9 existing window-rendering tests passed. The filter also selected an existing social-media window UI test; its result is recorded in the local log. iPad simulator build and 2 tests passed: the local 100 MP RAW now reports 11664 × 8750 exceeding 8192 without terminating, and ordinary edited-photo detail still matches full-resolution pixels. No device test was run. Private crash reports and RAW samples are retained locally, outside Git.

IPAD-ZOOM-02 implementation pending. Until that layer is added, oversized details report an error while preserving the existing photo preview.

