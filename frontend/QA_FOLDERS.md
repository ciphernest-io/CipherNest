# Folders — Phase B on-device QA checklist

Two devices = S (phone) and V (tablet/second phone), same account. Sync = pull-to-refresh or Settings → Sync Now on BOTH devices (order matters where stated).

**Coverage legend — read this first.** The harness and DB tests prove these semantics at the LOG and SQLITE layers only. Per the blind-spot map, UI state has ZERO property-test coverage — your devices are the entire safety net for the pixel layer.

- `[LOG]` — semantics proven by the 500-seed harness + sealed sweep. What's unverified: that the screen actually shows it.
- `[DB]` — additionally pinned by a scripted two-device SQLite test (sync_engine_db_test). What's unverified: the widget layer above the row.
- `[UI]` — no test backing at all. Everything here is first-run code.

## 1. Basics (single device)

- [ ] `[UI]` Home shows the "Folders" card SECOND (after Photos & Videos, before Documents/Music/Other Files); opens the browser at root.
- [ ] `[UI]` + creates a folder; appears instantly (no sync needed). Same-name sibling is refused with a snackbar.
- [ ] `[UI]` Nested create: open folder → + → child appears with correct count chips.
- [ ] `[UI]` Rename / Move / Delete via the ⋮ menu. Move picker indents the tree and HIDES the folder's own subtree.
- [ ] `[UI]` Gallery → hold-to-select photos → folder icon in toolbar → move to a folder → snackbar; files appear in the folder browser; Photos tab STILL shows them (gallery always shows all media — the global lens toggle is retired).
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

## 6. Albums `[UI]`

- [ ] Albums tab renders THREE strata: "On this phone" (derived device albums), "My albums" ("Synced across your devices" subtitle; smart albums + curated + Create card), and the "Show albums not backed up" toggle at the bottom. (The old "don't sync yet" line is GONE — see §12 for the full album-sync checklist.)

## 7. Phase C — system folders + Files-tab media presentation

The one-tree model this phase implements: **Files = the Drive view** (everything as a file system, media as rows), **Photos & Videos = the Google Photos view** (all media as the swipeable timeline). A photo appears in BOTH; only the presentation differs.

- [ ] `[DB]` **Deterministic convergence (FLAT device-album tree):** enable auto-sync → the tree is `Phone Backup → <Device name> → <Album>` — ONE level per MediaStore bucket display name (Camera, Screenshots, WhatsApp Images), NEVER a filesystem path mirror (the old `Android/media/com.whatsapp/…` five-level chain is the bug this replaces). The device level is keyed on the MODEL string — a reinstall reuses the same subtree; S and V each get their OWN device folder; two identical handsets would merge (accepted trade-off). Every id (root included) is ACCOUNT-SALTED: with two accounts linked on one phone, each account materializes its own complete Phone Backup tree — neither blocks nor hides the other's. Tested: independent creates fold to one flat chain, `is_system` = 1 at every level. What's unverified: the screens.
- [ ] `[UI]` **Single root row:** Files root shows "Phone Backup" as ONE row (phone icon, "Auto-synced media · N items" subtitle), sorted BELOW user folders. The device folder appears after tapping in; flat album folders below it. A WhatsApp image lands in `WhatsApp Images` DIRECTLY under the device — one tap from the device folder.
- [ ] `[UI]` **Auto-synced photo appears in BOTH views:** in the gallery timeline (as always) AND as a file row in Phone Backup/<Device>/Camera. It is NOT hidden from the gallery.
- [ ] `[UI]` **Media as rows, not a grid:** every media file anywhere in the Files tree renders as a row — thumbnail left, name/size/date right; videos get a small play glyph on the thumb. The grid stays in Photos & Videos.
- [ ] `[UI]` **Single-file preview:** tapping a media row opens it full-screen IN PLACE. Back returns to the folder. Try to swipe sideways → nothing (no adjacent files). No filmstrip, no scrubber, no "1 / N" counter. Videos: play/pause, mute, frame-capture still work (no timeline scrub — deliberate).
- [ ] `[UI]` **Deletion respected, never fought:** delete `Camera` → the next auto-synced photo lands in the NEAREST LIVE ANCESTOR (the device folder, else Phone Backup, else the vault root — unfiled but still in the gallery). Purge a system folder from the bin → it is NEVER recreated (purge is terminal); new photos take the same fallback. `[LOG]` for the terminality, `[UI]` for where files land visibly.
- [ ] `[UI]` **Rename survives, any level:** rename "Camera" (or the device folder) to anything → later auto-synced photos still file into it (placement is by id, not name), and it keeps its system icon.

## 8. Phase D — multi-file upload, upload-here, folder import

Everything in this section is `[UI]` + real-cloud plumbing — zero property-test coverage. The pipeline itself is the OLD home-screen flow extracted verbatim (plus folderId + the dedup pre-check), so single-file uploads are regression checks, not new behavior.

- [ ] **Single-file regression, all four home categories:** photo, video, PDF (thumbnail renders), audio (plays offline after upload). Behavior must be IDENTICAL to before — same snackbar, same rollback on airplane-mode failure (no phantom row, no bin entry).
- [ ] **Multi-select from home:** pick 5+ photos at once → FAB counts "Encrypting 2/5…", all land in the gallery, one summary snackbar. Background the app mid-batch → notification shows, batch completes.
- [ ] **Duplicate pre-check:** upload the same photo twice from home → second run reports "1 already in your vault", NO new row, NO cloud upload. A video duplicate is NOT pre-checked (streamed single-pass — lands as "name (1)", deliberate).
- [ ] **Upload here (both v1 limitations closed):** Files browser FAB → "Upload files" inside a folder → files land IN that folder, correctly typed by extension (a jpg picked here still gets a thumbnail + shows in Photos). Root browser → lands unfiled.
- [ ] **Non-media open from the browser:** tap a PDF/zip row → spinner on the row → opens in the system viewer (decrypt to app-private temp only). Tap a music row → plays as a single track (full-queue behavior stays in the Music tab).
- [ ] **Folder import:** FAB → "Import a folder" → pick a folder with subfolders → CipherNest mirrors the structure under the current folder, files upload one at a time with progress; summary names the new folder. **Windows-copy semantics:** a file whose bytes already exist elsewhere in the vault STILL lands in the imported folder as a real second copy (own row + own blob — a copy costs storage; expect "name (1)" if the filename is taken). The imported folder must arrive complete: count the files. Empty subfolders are not created. >2000 files → summary says "first 2000 files only". (Home-upload dedup above is unchanged — skip applies there, not here.)
- [ ] **OEM picker check (the pre-authorized cut):** if ACTION_OPEN_DOCUMENT_TREE misbehaves on either phone (empty tree, crash, unreadable docs), that's the cut condition — report it and "Import a folder" gets removed in favor of multi-file only.
- [ ] **Cache hygiene:** after any import/upload (success AND failure), Settings cache figure returns to baseline — SAF cache copies and picker copies must not linger.

## 9. QA Round 3 — home fix, one-tree consistency, folder hide, bin viewer, counts

- [ ] `[UI]` **Home:** five cards in order Photos & Videos / Folders / Documents / Music / **Other Files** (was silently dropped — it must be back). Rotate → landscape shows 2+2+1 rows, the odd last card at half width.
- [ ] `[UI]` **One-tree consistency:** a photo filed in ANY folder appears in Photos & Videos, Albums, and Stories alike. The Settings toggle "Category tabs show foldered files" is GONE.
- [ ] `[DB]` **Folder hide (synced):** hide a folder on S (folder row ⋮ or open-folder menu) → its files (and every descendant's) vanish from Photos/Stories/Albums (smart AND manual, counts AND covers)/Documents/Music/Other/track picker/add-to-album picker — but STAY in the Files browser (with "Hidden from views" cue) and the Recycle Bin. Sync → V matches. Unhide → all reappear. Hide, delete, restore → still hidden. Concurrent hide on S + move-child-out on V → child's files visible again on both.
- [ ] `[UI]` **Home upload destination:** FAB sheet leads with "To: My Vault" → tap, pick a folder → upload lands there (check the Files browser); reopen the sheet → back to My Vault. Browser upload sheet subtitle names the folder.
- [ ] `[UI]` **Bin viewer:** open a binned photo → only Restore / Info / Delete remain (no favourite/edit/share/save/wallpaper/print/copy; info sheet has no Edit). Delete → "Delete permanently?" → gone from bin, cloud blob deleted, converges to the other device after sync. Restore → returns to gallery, bin refreshes on pop. Deleting the last item pops the viewer. Same from the folder drill-in.
- [ ] `[DB]` **Bin viewer regression (the clock/detach bug):** open a photo INSIDE a binned folder's drill-in, tap delete, CANCEL the dialog → restoring the folder must still restore that photo (the old bug detached it via a second deleteFile op).
- [ ] `[UI]` **Counts:** a folder holding only a subfolder reads "1 item"; Phone Backup counts its device folder. Delete confirm names subtree totals ("N folders and M files inside").

## 10. Activity pill & notifications `[UI]` — all-new surface, zero prior art

- [ ] **Pill placement per screen:** start an upload, then visit — gallery (pill floats ABOVE the bottom nav), Music with a queue playing (above the MiniPlayerBar) and without (low position), the photo viewer (above the action pill + filmstrip), Settings/Documents/Home (low position). Never covers tappable chrome.
- [ ] **Toast pass-through:** while a toast is visible, tap a grid tile BESIDE it — the tap must land. Swipe the toast → gone instantly. A second toast replaces the first (no stale queue).
- [ ] **Pill behavior:** tap → task sheet (running rows with progress bars, recent history, "Playing <track>" row when music plays → taps into Now Playing). Swipe pill away → hidden, work continues; next task event re-shows it. Multi-task: pill fronts the priority task with a "+N" chip.
- [ ] **Upload story:** multi-file upload from home → pill counts "Encrypting 3/10…", terminal flash shows the summary ("10 files secured"), sheet's Recent keeps it. FAB just shows busy (counts live in the pill now).
- [ ] **Backgrounded upload:** background the app mid-batch → the "Securing your file…" notification now shows LIVE text + a determinate progress bar; tap opens the app; completion while backgrounded posts a "Completed activities" notification.
- [ ] `[DB]` **BG-sync live bridge:** with background mode on, force a worker run (adb `cmd jobscheduler run`) WHILE the app is open → pill shows "Backing up N/M" live and the gallery refreshes the moment it finishes (no more randomly-appearing photos). Kill the app, let a worker run finish, reopen → "N photos secured while you were away" entry + gallery current.
- [ ] **Migration controls from the sheet:** start a migration, leave the screen, open the sheet → pause/resume/cancel work; reopen the migration screen → its state agrees (paused shows paused).
- [ ] **Sync Now reentrancy:** tap Sync Now while a backup is already running → "Backup already running" toast, no duplicate run.
- [ ] **Honest bulk counts:** bulk ops (restore/delete/move ≥5 items) run as pill tasks with real success counts — force a failure (airplane mode mid-batch on delete-forever) and check the "N failed" tail appears instead of a clean count.
- [ ] **Quiet failures:** a failed vault-index backup or sweep surfaces as an error toast; successes stay silent (sheet history only).
- [ ] **Share/save non-blocking:** "Send file" on a large cloud-only video → pill counts the decrypt, you can keep browsing, the system share sheet opens when done. Same for Save to device (confirm dialog first, then pill).
- [ ] **Stability:** switch themes mid-task (pill survives, restyled); hot restart while a bg worker runs (no port crash, progress resumes); rotate mid-task.

## 11. QA Round 5 — placement fix, top pill, pick-then-place, capture, per-file hide, visuals, album art

- [ ] `[DB]` **No root flash:** upload into folder F (home place-flow AND browser upload-here) → rows visible IN F from the first frame; auto-sync photo lands in Phone Backup's tree with no flash at root. Also: a favorite toggled mid-upload survives (addFile now carries flags).
- [ ] `[UI]` **Pill at the TOP:** below the AppBar on plain screens, below the TabBar on Music/Recycle Bin, below the selection bar when selecting in gallery/browser, over the photo in the viewer. NO yellow underline anywhere, any theme. Toast sits under the pill and never shifts it.
- [ ] `[UI]` **Pick-then-place:** home FAB → Take photo / Record video / Upload files. Upload files → picker: files dimmed + inert, folders navigate, New-folder works mid-flow, footer shows "3 files → 〈folder〉", 'Upload here' at depth 3 returns home in ONE motion, Cancel and full back-out upload nothing. Browser's own FAB flow unchanged (uploads into the viewed folder).
- [ ] `[UI]` **Capture:** permission denial aborts with a toast. Photo: shutter → place flow → uploads as media with thumbnail, name CNEST_yyyyMMdd_HHmmss.jpg. Video: record with timer → stop → place → plays after upload (.mp4 streamed path). From the BROWSER sheet capture lands straight in the current folder. After upload the temp dir holds NO plaintext capture (Settings cache at baseline). Background mid-recording → no crash on resume; flash cycles; lens flips; PHOTO↔VIDEO toggles.
- [ ] `[UI]` **ZK check:** after captures, the system gallery (Google Photos/Samsung Gallery) shows NO copy of the captured photo/video.
- [ ] `[DB]` **Per-file hide:** hide one file from the viewer overflow, a browser row ⋮, gallery multi-select, and browser multi-select → gone from Photos/Albums/Stories/Documents/Music/Other/favorites/covers; STILL in the Files browser (dimmed + "Hidden from views") and the Recycle Bin. Unhide from the browser row and the viewer. Sync → V matches. Concurrent hide + favorite on S/V → both flags land on both devices. Bulk ≥5 → pill task with an honest count.
- [ ] `[UI]` **File visuals:** pdf rows in the browser show real page thumbnails; docx/xlsx/csv/zip/code/ipynb show the same colored icons in the browser, Documents tab, and Other Files tab (identical glyphs). (docx/xlsx real previews are impossible client-side under zero-knowledge — icons are the Drive-parity answer.)
- [ ] `[UI]` **Album art:** upload an mp3 with embedded art and an m4a with covr → art shows in track rows, the track picker, audio details, the mini-player disc, and Now Playing; the lock-screen/media notification shows art ONLY while "show titles" is on (toggle off → generic, next queue). Art-less tracks keep the note placeholder.
- [ ] `[UI]` **Other Files icon:** archive-box glyph on the home card + empty state, distinct from the Folders card, in every theme pack.

## 12. Auto-sync restructure + synced albums — flat tree, per-album selection, backfill, derived albums, album sync

- [ ] `[UI]` **Onboarding choice:** fresh install → after signup, enabling auto-sync (Quick Settings or Settings) opens "Which albums should back up?" — All albums / Choose albums. All albums → second ask: From now / Include existing photos (the latter queues a backfill for every current bucket). Choose albums → the checklist screen preset to selected-mode.
- [ ] `[UI]` **Backed-up albums screen (Settings → Auto-Sync):** All/Selected radio; in All mode rows render checked + dimmed (informational); in Selected mode ticking a bucket asks From now / Include existing (with the real item count), unticking stops future uploads (already-vaulted copies stay). Choices survive app restart.
- [ ] `[DB]` **Selection is enforced:** Selected mode with only Camera ticked → a new WhatsApp image does NOT upload; a new Camera photo does. Flip to All → the next sync picks up new photos from every bucket (WhatsApp Images included — this was the silent flood behavior, now opt-in-visible).
- [ ] `[DB]` **Flat placement everywhere:** auto-sync, per-album backfill, AND the Migration screen all file device-gallery media into `Phone Backup/<Device>/<Album>` (Migration used to drop everything at the vault root — that's fixed). Manual home/browser uploads are untouched (user-placed).
- [ ] `[UI]` **Backfill:** enroll a 100+ photo bucket with "Include existing" → ActivityCenter task "Backing up <Album> N/M" with pause/resume/cancel; photos land in the album's folder + gallery. Cancel mid-run → task says it resumes next sync; the NEXT sync (or re-enroll) picks up the remainder with no duplicates. Airplane mode mid-backfill → failures reported, flag kept, retried later.
- [ ] `[UI]` **Device naming:** the device folder is created with the registry name (defaults to "Samsung SM-A556E"-style). Settings → Devices → rename → the Phone Backup device folder renames too; auto-sync keeps filing into it (id is model-keyed, not name-keyed).
- [ ] `[UI]` **Derived device albums:** Albums tab "On this phone" section shows one album per distinct device-album name with a smartphone glyph on art-less covers. After V syncs, S's "Camera" album shows the UNION of both phones' Camera folders (and vice versa). Hidden folder → its share vanishes; binned folder likewise. Long-press delete inside a derived album warns it bins the FILE vault-wide (membership = folder location), and does exactly that.
- [ ] `[UI]` **Name collision:** create a curated album named "Camera" → both exist, in their own sections, no clash, no block.
- [ ] `[UI]` **Reveal toggle:** "Show albums not backed up" → Selected mode shows un-enrolled buckets dimmed with "N · not backed up"; tapping one runs the enroll sheet and it moves out of the dimmed set. All mode → "Every album on this phone is backed up." message instead.
- [ ] `[DB]` **Album sync happy path:** S creates album "Trip", adds 3 photos, sets a cover → sync → V shows Trip with the same 3 photos in the same order (added_at is the op wall) and the same cover. V renames + removes one → sync → S matches. Playlists: create on S, add tracks → V's Music tab shows it (kind rides the create op).
- [ ] `[DB]` **Album races:** OFFLINE — S adds a photo to Trip while V deletes Trip; reconnect both → Trip is GONE on both, permanently (delete is terminal, no resurrection), and the photo itself is untouched. OFFLINE — S adds photo X while V removes X → both converge to the same LWW winner. Deleting a photo to the bin keeps its membership hidden-but-recoverable: restore from bin → it's back in its albums.
- [ ] `[UI]` **Smart strata intact:** All Photos / Videos / Recently added / Favourites still work; the old heuristic "Camera" and "Screenshots" smart albums are GONE (derived albums replaced them); smart playlists unaffected by album sync.

## 13. Sweep (can't wait 30 days)

The folder-aware sweep is `[DB]`-tested (expiry math, folder-first ordering, orphan fallback). On-device spot check if desired: none practical without clock games — trust the tests here, or temporarily shorten the TTL in a debug build.

## If anything above fails

Note WHICH tag it carried. `[LOG]`/`[DB]` failures mean the materialization-to-UI gap ate a proven semantic — exactly the bug class the blind-spot map predicts. `[UI]` failures are ordinary new-screen bugs. Either way: screen, steps, both devices' states.
