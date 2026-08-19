# Performance Baseline (Phase 0)

Every optimization (FIX-1..8, see the approved plan) is justified against the
numbers below — no fix ships without a before/after row for its scenario.

## How to capture

1. Device: the Samsung A55 (S), seeded corpus: ~300 local auto-synced photos
   (MediaStore-bound), ~30 cloud-only files, 5 videos. Charge >50%, screen
   timeout off, no other foreground apps.
2. `flutter run --profile` from `frontend/`, open DevTools → Performance.
3. Timeline zones are pre-wired (`lib/src/utils/perf_trace.dart`); the named
   zones attribute main-isolate time:
   `applyMergedState`, `replayOps`, `aesEncryptFile`, `aesDecryptFile`,
   `sha256Hash`, `getFilesByType`, `groupByDate/Month/Year`,
   `gridThumbLadder`, `viewerLoadImages`, `viewerPrefetch`.
4. Per scenario: record ~30s, export the frame chart, note p50/p90/p99 build
   and raster times, % frames >16ms and >32ms, the top-5 zones by self-time,
   and (S5) the DevTools memory peak.

## Scenarios

- **S1** Gallery cold open + 30s continuous scroll, at 3-col, 7-col, and the
  justified zoom level (three captures).
- **S2** Viewer: open a photo, 10 swipes (include 2 videos), 3 dismiss-drag
  gestures (cancel mid-drag), close.
- **S3** Repeat S1's 3-col scroll WHILE a 20-file manual upload batch runs.
- **S4** Repeat S1's 3-col scroll during a 100-photo bucket backfill.
- **S5** Memory watermark: swipe through 40 photos in the viewer, then idle
  10s; record the heap peak and whether it plateaus or climbs.

## Targets

- S1: p95 build+raster < 16 ms, zero stalls > 100 ms.
- S3/S4: jank within 1.5× of S1 (upload must not own the UI thread).
- S5: peak < 400 MB, plateaus after swiping stops.

## Baseline — captured 2026-08-19, A55 (Android 16), profile build @ f2abe80

Corpus: real vault, 58 photos (57 MediaStore-bound) for the first block;
118 photos after the S3 seed ingest. Battery 32→52% CHARGING (below the
>50% protocol floor — noted; device was on mains throughout). Captures via
VM-service timeline probe (scratchpad perf_probe), adb-driven gestures;
zoom-level variants and the backfill scenario (S4) were NOT captured
(pinch automation + vault pollution; capture with FIX re-measures if
needed). All numbers are ms.

| Scenario | build p50/p90/p99 | raster p50/p90/p99 | >16ms | >32ms | Zones seen | Memory (PSS/Graphics MB) |
|---|---|---|---|---|---|---|
| S1 scroll, 58 photos | 1.4 / 2.3 / 3.6 | 2.3 / 3.2 / 6.3 | 0% | 0% | none (memo working) | — |
| S1 scroll, 118 photos | 1.4 / 5.1 / 12.8 (max 16.4) | 2.4 / 5.5 / 9.5 (max 52.5) | 0.3% | 0.3% | getFilesByType ×10 (187ms, max 34), applyMergedState 34 | 489 / 254 idle |
| S2 viewer, 10 swipes | 0.9 / 2.1 / 5.0 (max 17.1) | 1.7 / 3.2 / 6.1 | 0.2% | 0% | viewerLoadImages ×6 (423ms, max 102) | **682→855 / 371→576 (+17-20 MB per page)** |
| S2 dismiss-drag ×6 | 1.5 / **7.6** / **16.9** | 2.1 / 3.4 / 6.8 | 1.4% | 0% | none | 814 after |
| S3 scroll during 60-file upload (×2 windows) | 1.3-1.7 / 2.1-2.4 / 3.5-4.0 | 2.0-2.3 / 2.7-3.3 / 7.2-9.0 (max 30.7) | 0.5% | 0% | per uploaded file: applyMergedState 22-29, getFilesByType ×6 (69-86ms), aesEncryptFile ×2, groupByDate ×4 | 554 / 305 mid-sync |

## Measured verdict (what the numbers say vs. the static audit)

1. **Scroll at 58 photos is CLEAN** — zero jank. The felt "jank at 10+
   photos" does not reproduce as frame drops at this corpus on this device.
2. **Scaling is real and steep**: doubling to 118 photos moved scroll p90
   2.3→5.1ms and p99 3.6→12.8ms with the first >16ms frames appearing.
   Extrapolated (grouping + section inflation are O(N) per build), a
   few-hundred-photo vault blows the frame budget — consistent with the
   pre-wipe experience.
3. **The viewer is the worst measured offender**: +17-20 MB PSS per swiped
   page (keep-alive retention, F4) — 682→855 MB in ten swipes; a budget
   device OOMs/LMK-kills near swipe 30. FIX-4 is justified by hardware
   numbers, not just reading.
4. **Dismiss-drag** (F5): build p90 7.6ms / p99 16.9ms at just 118 photos —
   the per-pointer whole-Scaffold rebuild measured; scales with filmstrip N.
5. **Upload overhead per file at F≈130**: applyMergedState 22-34ms + six
   full-table re-queries (~80ms) + four regroups — ~120ms of main-thread
   work per uploaded file TODAY, growing quadratically (F1/F2). At this
   corpus it hides between frames; at 1k+ files it is seconds per file.
6. Crypto zones were small here (0.3MB files, 8s network cadence): AES
   ~7ms/file at this size. F3 matters most for the viewer/prefetch path
   (viewerLoadImages max 102ms) and large files, not thumb-sized uploads.

Re-measure protocol per fix: rerun the SAME probe scenarios at the
118-photo corpus (PERFB seed batch is kept in the vault for exactly this).

## After each fix

Append a dated row-set per fix cluster: `FIX-n (commit) — scenario — before →
after`, keeping the original baseline rows untouched.
