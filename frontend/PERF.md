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

## Baseline (capture pending — fill before FIX-1 lands)

| Scenario | p50 build | p90 | p99 | raster p90 | >16ms % | >32ms % | Top zones | Memory peak |
|---|---|---|---|---|---|---|---|---|
| S1 3-col | | | | | | | | — |
| S1 7-col | | | | | | | | — |
| S1 justified | | | | | | | | — |
| S2 viewer | | | | | | | | — |
| S3 scroll+upload | | | | | | | | — |
| S4 scroll+backfill | | | | | | | | — |
| S5 memory | — | — | — | — | — | — | — | |

## After each fix

Append a dated row-set per fix cluster: `FIX-n (commit) — scenario — before →
after`, keeping the original baseline rows untouched.
