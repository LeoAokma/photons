# Panorama UI and iPad responsiveness fixes

Separate follow-up to the current iPad source `7855ac9` (PR #3, not yet merged at start). Branch: `codex/panorama-ui-performance`. Excludes the deghost PR and Mac perspective PR. Publication base is awaiting the owner’s choice; implementation and validation proceed here.

| Tracking ID | Independent acceptance goal | Dependencies |
| --- | --- | --- |
| PANO-UI-01 | iPad histogram stays in a preview corner and folds to Histogram. | Existing PR #3 histogram |
| PANO-UI-02 | Panorama zoom shows low-resolution preview notice, never requests detail renders. | Existing PR #3 zoom |
| PANO-UI-03 | Multi-selection taps and highlight changes respond without gesture arbitration/editor loading. | Existing PR #3 grid |
| PANO-UI-04 | Preserve/recover grid thumbnails on panorama dismissal and memory pressure. | Existing PR #3 caching |
| PANO-UI-05 | Mac histogram overlay fits its actual content. | None |

## PANO-UI-01 — `2eb2bf0`

Removed the 100 pt histogram frame in the iPad control sidebar: the richer histogram’s fixed plot and text exceeded that space and overlapped LCC controls. The histogram now sizes to its contents inside the bottom-left preview overlay, follows HDR/SDR mode, and folds/expands from its labeled Histogram button. English/Chinese label included. Validation: iPad simulator build and `IPadUITests.testPanoramaHistogramStaysInsidePreviewAndFolds` passed (1 test, 0 failures), covering landscape/portrait bounds and fold/unfold. The first test attempt used a global accessibility query that matched the underlying inspector; the query is now scoped to the panorama card. No physical-device verification. No rendering or LCC changes; revert independently.

## PANO-UI-02

Panorama zoom now shows “Previewing low-res stitch” / “正在预览低分辨率接片”; Fit clears the notice. Removed the panorama detail renderer, which previously decoded/composited the full output before cropping to the viewport. Ordinary-photo detail rendering and full-quality panorama export remain available. Files: MobileWorkspaceModel, MobileEngine, MobilePhotoCanvas, localization and iPad tests. Depends on PR #3 zoom; independent of PANO-UI-01 behavior.

Validation: simulator build passed; two engine tests passed (missing originals cannot trigger a panorama detail decode; ordinary edited-photo detail pixels still match full-resolution output). The zoom/notice/Fit UI test passed after scoping its accessibility query to the foreground canvas; the initial query matched the background canvas as well. `git diff --check` passed. Simulator only; no physical-device/HDR-display quality claim. Revert independently to restore the former detail behavior.
