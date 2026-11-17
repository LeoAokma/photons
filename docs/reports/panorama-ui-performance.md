# Panorama UI and iPad responsiveness fixes

Separate follow-up to the current iPad source `7855ac9` (PR #3, not yet merged at start). Branch: `codex/panorama-ui-performance`. Excludes the deghost PR and Mac perspective PR. Owner decision: complete these fixes now, wait for PR #3 to merge, then submit an independent PR against the updated main. Do not duplicate PR #3 or merge it on the owner’s behalf.

| Tracking ID | Independent acceptance goal | Dependencies |
| --- | --- | --- |
| PANO-UI-01 | iPad histogram stays in a preview corner and folds to Histogram. | Existing PR #3 histogram |
| PANO-UI-02 | Panorama zoom shows low-resolution preview notice, never requests detail renders. | Existing PR #3 zoom |
| PANO-UI-03 | Multi-selection taps and highlight changes respond without gesture arbitration/editor loading. | Existing PR #3 grid |
| PANO-UI-04 | Preserve/recover grid thumbnails on panorama dismissal and memory pressure. | Existing PR #3 caching |
| PANO-UI-05 | Mac histogram overlay fits its actual content. | None |

## PANO-UI-01 — `2eb2bf0`

Removed the 100 pt histogram frame in the iPad control sidebar: the richer histogram’s fixed plot and text exceeded that space and overlapped LCC controls. The histogram now sizes to its contents inside the bottom-left preview overlay, follows HDR/SDR mode, and folds/expands from its labeled Histogram button. English/Chinese label included. Validation: iPad simulator build and `IPadUITests.testPanoramaHistogramStaysInsidePreviewAndFolds` passed (1 test, 0 failures), covering landscape/portrait bounds and fold/unfold. The first test attempt used a global accessibility query that matched the underlying inspector; the query is now scoped to the panorama card. No physical-device verification. No rendering or LCC changes; revert independently.

## PANO-UI-02 — `ca4c5c4`

Panorama zoom now shows “Previewing low-res stitch” / “正在预览低分辨率接片”; Fit clears the notice. Removed the panorama detail renderer, which previously decoded/composited the full output before cropping to the viewport. Ordinary-photo detail rendering and full-quality panorama export remain available. Files: MobileWorkspaceModel, MobileEngine, MobilePhotoCanvas, localization and iPad tests. Depends on PR #3 zoom; independent of PANO-UI-01 behavior.

Validation: simulator build passed; two engine tests passed (missing originals cannot trigger a panorama detail decode; ordinary edited-photo detail pixels still match full-resolution output). The zoom/notice/Fit UI test passed after scoping its accessibility query to the foreground canvas; the initial query matched the background canvas as well. `git diff --check` passed. Simulator only; no physical-device/HDR-display quality claim. Revert independently to restore the former detail behavior.

## PANO-UI-03 — `ec5a6a7`

Selection mode now uses a single-tap recognizer directly. Each checkbox updates only the selected-ID set, without resetting the active editor, reading edit/history data or cancelling its render. Initial long-press selection still loads the initial photo once; ordinary browsing retains double-tap opening. Unchanged thumbnail images are not resubmitted to CALayer on every highlight redraw. Files: MobileWorkspaceView, MobileWorkspaceModel, iPad tests. Depends on PR #3 grid, no preceding fix behavior.

Validation: simulator build and 2 tests passed: 40 model toggles preserve the editor without touching missing originals; UI selection/deselection and rapid double-taps stay in the grid, and normal double-tap opening works after leaving selection mode. No physical-device latency benchmark; this removes the identified blocking paths rather than promising a measured frame-time target. `git diff --check` passed. Revert independently.

## PANO-UI-04 — `09cf2a1`

Memory warnings previously erased every grid thumbnail and cancelled its loader; neither panorama dismissal nor a completed job reliably restarted the loader. Preserve currently visible (and pre-panorama visible) thumbnails plus the active photo under pressure. Load only missing visible cells, with a small recent cache (64 entries unless the visible set itself is larger). Coalesce appearances, skip ready images, recover cancelled loads after jobs/dismissal/cache clearing, and make root startup idempotent. HDR/SDR changes mark display variants stale while retaining existing images until their cached counterparts arrive. Files: MobileWorkspaceModel, MobileWorkspaceView, iPad engine tests. Depends on PR #3 caching; PANO-UI-02 also removes a source of avoidable memory pressure but is not required for recovery.

Validation: iPad simulator build; 3 engine tests passed (pressure retention, disk-backed recovery after a cancelling job, idempotent restart, HDR/SDR cached reuse, missing-load recovery without panorama, transient panorama close). Two existing UI tests passed: full grid/inspector/panorama/tone/export/close workflow and cache measurement/clearing. Recovery assertions verified unchanged renderCount and retained CGImage identities. `git diff --check` passed. Tests inject memory warnings with generated fixtures; the reported physical-iPad memory-pressure event was not directly captured. Revert independently; no library/original/edit deletion.

## PANO-UI-05 — `55faa84`

The Mac panorama overlay now uses `HistogramCardView.contentHeight` (90 pt) instead of a fixed 126 pt. Width and padding are unchanged; the plot, clipping statistics and readout row retain their existing geometry. The background loses 36 pt of unused bottom space. File: Sources/PhotonsUI/PanoramaHDRPreview.swift. No behavioral dependencies and no histogram/HDR arithmetic changes.

Validation: `swift test --skip-update --filter 'HistogramCardHeightTests|PanoramaHDRTests'` built the Mac package and passed all 10 tests, 0 skipped, including drawn content bounds, readout visibility, EDR surface pixels and HDR export. Existing pinned dependency checkouts were reused locally. `git diff --check` passed. No new tests for the one-line layout change; existing measured layout tests cover its sizing source. Revert independently.

## Commit index and delivery

| Tracking | Commit | Acceptance result |
| --- | --- | --- |
| PANO-UI-01 | `2eb2bf0` | Histogram inside the iPad preview, with fold/unfold button |
| PANO-UI-02 | `ca4c5c4` | Low-res stitch notice at zoom, no panorama detail jobs |
| PANO-UI-03 | `ec5a6a7` | Direct multi-selection feedback without editor reloads |
| PANO-UI-04 | `09cf2a1` | Retain/recover thumbnails through panorama and memory pressure |
| PANO-UI-05 | `55faa84` | Mac histogram background fits actual content |

Per-change verification totals: 11 iPad tests (6 engine, 5 UI) and 10 Mac tests passed. The early failures in two UI tests were ambiguous selectors and are documented above; scoped foreground queries passed. This is targeted verification, not a claim that the complete repository suite or physical-device TestFlight testing ran.

The deghost checkbox is separate: [PR #5](https://github.com/chemharuka/photons/pull/5), single commit `a77cddb`. This branch contains none of that commit and none of PR #4's Mac perspective changes.

PR #3 was still open at completion. Per the owner's explicit choice, do not open this follow-up PR until #3 merges. Then fetch upstream, transplant only the five functional commits and this tracking update onto the resulting main (including the case where #3 is squash-merged), resolve integration changes, revalidate affected paths, and open one PR titled **Fix iPad panorama previews and grid responsiveness**. Preserve this source branch and the other existing worktrees. A prepared PR body is retained locally in `local/release/panorama-ui-performance-pr.md`.

No TestFlight upload or source-library cleanup is included in this request. Generated simulator fixtures were used for validation; private photographs and local build artifacts are excluded from Git.
