# Folders — Phase B on-device QA checklist

Two devices = S (phone) and V (tablet/second phone), same account. Sync = pull-to-refresh or Settings → Sync Now on BOTH devices (order matters where stated).

**Coverage legend — read this first.** The harness and DB tests prove these semantics at the LOG and SQLITE layers only. Per the blind-spot map, UI state has ZERO property-test coverage — your devices are the entire safety net for the pixel layer.

- `[LOG]` — semantics proven by the 500-seed harness + sealed sweep. What's unverified: that the screen actually shows it.
- `[DB]` — additionally pinned by a scripted two-device SQLite test (sync_engine_db_test). What's unverified: the widget layer above the row.
- `[UI]` — no test backing at all. Everything here is first-run code.

## 1. Basics (single device)

- [ ] `[UI]` Home shows a "Folders" card FIRST in the grid; opens the browser at root.
- [ ] `[UI]` + creates a folder; appears instantly (no sync needed). Same-name sibling is refused with a snackbar.
- [ ] `[UI]` Nested create: open folder → + → child appears with correct count chips.
- [ ] `[UI]` Rename / Move / Delete via the ⋮ menu. Move picker indents the tree and HIDES the folder's own subtree.
- [ ] `[UI]` Gallery → hold-to-select photos → folder icon in toolbar → move to a folder → snackbar; files appear in the folder browser; Photos tab STILL shows them (lens ON default).
- [ ] `[UI]` Non-media file tapped in the browser shows the "opens from its category tab" notice (known v1 limitation — in-folder upload + open lands with Phase D).

## 2. Two-device tree sync `[LOG → pixels unverified]`

- [ ] Create folders + move files on S → sync → V shows the identical tree (order, nesting, counts).
- [ ] Rename a folder on V → sync → S shows the new name.
- [ ] Move a folder under a new parent on S → sync → V matches.
- [ ] Concurrent renames of the SAME folder on S and V (offline both, then sync): later HLC wins, both devices agree, no notice (cosmetic LWW).

## 3. Model A bin semantics — the harness-proven cases, now at the screen

- [ ] `[DB]` **Cascade delete, one entry:** put ~10 photos in a folder, delete the folder → Recycle Bin → Folders tab shows ONE entry with "10 items" and a path; **Photos & Videos tab gains NOTHING**.
- [ ] `[DB]` **Restore folder:** Folders tab → Restore (dialog says: "Restores this folder and the items removed with it. Items you deleted individually stay deleted.") → folder back in the browser, files back INSIDE it, on BOTH devices after sync.
- [ ] `[DB]` **Seed-178 at the UI:** delete a photo individually, THEN delete its folder, then restore the folder → the photo STAYS in the bin's Photos tab (its own entry), everything else returns. Also try the concurrent variant: S deletes the folder while V (offline) deletes one file inside it individually; sync both; restore the folder on S → V's individually-deleted file stays deleted on BOTH.
- [ ] `[DB]` **Cascade tombstone clock:** delete a folder, open the bin → the folder entry and (after drill-in) its files show "30d left", NOT "0d left" (the instant-purge regression, visible as the countdown).
- [ ] `[LOG]` **Restore under dead parent:** delete subfolder C directly, then delete parent P, then restore C from the bin → C appears at ROOT of the browser, alive. Restore P afterwards → C rejoins P ("structure remembered").
- [ ] `[LOG]` **Move-into-deleted race:** V (offline) moves a file into folder F; S deletes F; both sync → file survives at ROOT, alive, both devices.

## 4. Bin UI specifics `[UI]`

- [ ] Five tabs: Folders / Photos & Videos / Documents / Music / Other. Each type tab shows only its own individually-deleted items.
- [ ] Folder entry shows: name, greyed-when-deleted path segments, "N items · Xd left", ⋮ with Restore / Delete forever.
- [ ] **Drill-in:** tap a deleted folder → read-only contents (subfolders + file grid); long-press a file → single-file restore dialog (copy explains root-until-folder-restored, rejoin after); app bar has Restore folder + Delete forever.
- [ ] **Search:** search icon → type a filename that lived inside a deleted folder → result shows greyed path + primary **Restore "\<folder\>"** button; an individually-deleted match shows plain "Restore".
- [ ] **Bulk restore:** long-press in a type tab → "All" → Restore; also Delete forever with confirm.
- [ ] **Delete forever (folder):** confirm dialog names the item count; afterwards the entry is gone, the files are gone from search, and — after sync — gone on the second device too `[DB for the convergence, UI for the screens]`.
- [ ] Greyed path check: delete nested folders so an entry's ancestors are themselves deleted → those path segments render dimmer.

## 5. Conflict notices

- [ ] `[DB]` **Cycle race:** S moves X into Y; V (offline) moves Y into X; sync both. Tree converges identically (X under Y). **V** gets the one-time snackbar "Your move of folder "Y" was undone — it conflicted with a folder move on \<S's name\>". S gets nothing. The notice does NOT repeat on later syncs.
- [ ] `[DB]` **Folder edit-vs-delete:** V renames a folder while offline; S deletes it; V syncs → V sees "You edited folder … it's in the Recycle Bin."

## 6. Lens + albums `[UI]`

- [ ] Settings → "Category tabs show foldered files" default ON. Turn OFF → Photos/Documents/Music/Other show only unfiled items; folder browser unchanged. Turn back ON → everything reappears.
- [ ] Albums tab shows the "On this device — albums don't sync yet" line (and in the empty state).

## 7. Sweep (can't wait 30 days)

The folder-aware sweep is `[DB]`-tested (expiry math, folder-first ordering, orphan fallback). On-device spot check if desired: none practical without clock games — trust the tests here, or temporarily shorten the TTL in a debug build.

## If anything above fails

Note WHICH tag it carried. `[LOG]`/`[DB]` failures mean the materialization-to-UI gap ate a proven semantic — exactly the bug class the blind-spot map predicts. `[UI]` failures are ordinary new-screen bugs. Either way: screen, steps, both devices' states.
