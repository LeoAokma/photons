# iPad development preview validation — 2026-11-16

## Scope

This revision adds an iPadOS 18+ development preview using the existing Swift/Metal, catalog, panorama, LCC and export modules. It is not desktop feature parity or an iPad TestFlight submission. Development guidance is advisory: [Mac/iPad suggestions](../mac-ipad-development.md).

## Builds and checks

- Xcode 27.2 / iPadOS 27.2 simulator, iPad Pro 13-inch (M5), Apple Silicon host.
- Simulator Debug build and optimized Release preview build; unsigned generic iOS-device SDK build. Both SwiftPM and the Xcode project pin GRDB 7.11.1.
- Final iPad functional selection: six engine tests plus one UI workflow passed (`ipad-test-9.xcresult`). The two export/geometry tests passed again after the final metadata-preservation change (`ipad-test-10.xcresult`).
- The optional real-RAW test passed earlier in the same implementation (`ipad-test-5.xcresult`): B0000659–B0000662, four original .3FR files, automatic registration, bundled 43XL profile position solve/correction, lossless linear DNG export configured to 2048 px, structural metadata readback and automatic import. The registered canvas was 21,305 × 15,366. The Debug workflow took approximately 464 seconds; this is not a physical-iPad benchmark or a measured ground-truth LCC-position result.
- Generated Bayer calibration verifies both traditional matching-flat LCC and profile correction, including flattening of known falloff. Generated overlapping images verify registration, reduced-size composite rendering, lossless DNG, embedded geometry and import. An actual projective distortion fixture verifies the Perspective path and its portable capture-mode record.
- Drag-coordinate checks cover screen-to-millimetre conversion, right/up axes, body travel clamping and a rotated single-axis body. UI checks exercise sidebar hiding, grid pinch sizing, tap-to-toggle inspector, long-press multiselection, required mode choice, the full-screen panorama preview, dragging and stale-preview export gating, re-alignment, export dismissal and all three full-screen Settings tabs. Both Shift and Perspective entry points are exercised.
- Reimported DNG → cropped/resized TIFF preserves the original source geometry. Gain-map trimming composes into the same metadata mapping. Explicit Perspective manifests cannot be treated as physical shift positions by post-LCC; existing manifests without the new mode continue to decode.
- Mac focused checks: the controls/LCC/independent-import selection passed 22 tests and skipped 3 optional external-fixture tests. After the mode/metadata additions, the projective/provenance/post-LCC/export-metadata selection passed 11 and skipped 2 external-fixture tests. No failures in either selection. `PHOTONS_LANGUAGE=zh-Hans` is used because existing LightCard tests assert Chinese labels.

Commands use `xcodebuild -project Apps/iPad/PhotonsIPad.xcodeproj -scheme "Photons iPad Preview"`, selecting the simulator or `generic/platform=iOS`, and `CODE_SIGNING_ALLOWED=NO`. The final routine simulator run skips `testOptionalRealRAWWorkflow`, which was already exercised with the private fixtures. Run `python3 scripts/ipad-preview.py test` to include it when local RAW samples are bundled.

## Limits

Physical iPad memory, thermals, HDR display headroom, background behaviour and large full-resolution exports remain unverified. The preview visibly offers 2048/4096/6000 px exports. RAW LCC still reads full mosaics and is expensive in Debug; the interactive local preview uses an optimized Release build. Perspective currently uses planar homographies for modest changes in view, not spherical/360° projection. Correct individual sources before perspective stitching when LCC is needed.

The 43XL calibration is a developer-created user profile. The four approximately 810 MB Boston RAWs are optional local resources and are not committed to Git. The simulator sample build includes them; default Release archives omit them unless explicitly requested. Generated CI fixtures contain no private photographs.

This is scoped verification, not a claim that the repository's full historical acceptance suite passes. The existing upstream PR also has pre-existing integration conflicts with upstream main; these checks validate this branch, not an upstream merge result.
