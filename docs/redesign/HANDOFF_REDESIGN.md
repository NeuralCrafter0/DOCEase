# DOCEase redesign M1: handoff record

Status: work in progress, stopped at 11:55 on 24 Oct 2026 on the owner's "transfer" instruction. Nothing is merged. The branch is pushed as a draft PR only.

- Repository: NeuralCrafter0/DOCEase
- Branch: `redesign/m1-wip` (new; no existing #1 to #21 branch was pushed to)
- Draft PR: see the PR section at the end (filled in after push)
- Local worktree: `/workspace/redesign/app` (branch `redesign/foundation`, same commits)
- Scratch repo that owns the worktree: `/workspace/redesign/combined` (branch `redesign-base2` = the integration base)

## 1. What the base is

The redesign sits on an integration tree that combines the open PR heads. The PRs are not merged into main. The base exists only to build and test the new UI against all pending backend, QA and security work.

The base was built in two stages.

**Stage A: `89475b0` "integration base: drop QA-local suites"**. This is QA's combined tree `qa-merged15` (`99f9c4d`) plus `787993f` (merge #18), `a42f0aa` (merge #1) and `000d79d` (merge #20). The #20 merge reused the patient-detail resolution from `frontend-reports/trial_20_lows_qa_merged14`. The 43 QA-local files that exist in no PR head were then removed (`test/qa_*`, `test/support`, `tool/qa_*`, `tool/sqlcipher_harness`, `integration_test`). QA's chain also carries older, superseded revisions of #8, #10, #13 and #16. The full list is in `branch_commits_not_in_prs.txt` (next to this file).

**Stage B: `redesign-base2`**, moving A onto the 11:43 backend heads:

| Commit | What |
|---|---|
| `ecbc2c0` | merge #10 `4f3a8ee` (clean) |
| `1bafd74` | merge #16 `7b8134a`, which contains #13 `f9d905f`. Conflicts were resolved by: (a) taking #16's file where the stage-A copy equalled old #16 `9f40de5`, i.e. no other PR touched it; (b) a 3-way `git merge-file` with old #16 `9f40de5` as base for `lib/main.dart`, `lib/providers/medicine_provider.dart`, `lib/providers/patient_provider.dart`, `lib/screens/patient_detail_screen.dart` and `lib/utils/pdf_export.dart`. All five merged with 0 conflicts. |
| `abdca05` | merge #8 `58a1e10` (clean; adds `lib/utils/pick_registry.dart` + test) |
| `5c19470` | merge #21 `f374421` (contains #15 `1827d9d`) |

Open PR heads as of 11:56, and whether the branch contains them:

| PR | Head | In branch |
|---|---|---|
| #1 | f713b85 | yes |
| #2 | 24b7886 | **no** (never part of the base) |
| #3 | f00131f | yes |
| #4 | 659a363 | yes |
| #5 | 2cda5d3 | yes |
| #6 | 1bae23c | yes |
| #7 | 555a935 | yes |
| #8 | 58a1e10 | yes |
| #9 | 237ce3c | yes |
| #10 | 4f3a8ee | yes (the old b217f46 is also in history, via QA and #12) |
| #11 | eb9526b | yes |
| #12 | 987448e | yes (still based on old #10 b217f46) |
| #13 | f9d905f | yes |
| #14 | 28d87d3 | yes |
| #15 | 1827d9d | yes |
| #16 | 7b8134a | yes |
| #17 | e9e4514 | yes |
| #18 | 5309d60 | yes |
| #19 | f28961f | yes |
| #20 | d6c5253 | yes |
| #21 | cfaed37 | **no**: the branch has f374421; #21 moved after the merge |

## 2. Redesign commits (on top of the base)

| SHA | Commit |
|---|---|
| `a75d7ce` | Redesign foundation: tokens, Figtree, theme, shared components, QA keys, route reset on owner change |
| `36c7abf` | Home: new layout, states, sort, drawer/sidebar, sign-out via SessionController |
| `4338dff` | Patient form: sections, private fields, duplicate warning, refusal keeps the form open |
| `4b80e95` | Phone prefix without flag emoji, FAB icon-only at large text, Figtree licence per family |
| `378e9a3` | WIP: PatientLoad.loading reads #16 hasLoaded; screenshot fake reports hasLoaded, adds loading shot |
| (next) | docs: this handoff file, copied to `docs/redesign/HANDOFF_REDESIGN.md` |

The author on all of these is "DOCEase Frontend <frontend@users.noreply.github.com>". The stage-A scratch merges (`787993f`, `a42f0aa`, `000d79d`) carry the "DOCEase-backend" identity from the scratch repo's config at that time.

## 3. What is done

**Design system (`a75d7ce`)**
- `lib/theme/tokens.dart`: colours (light and dark, every text pair checked to at least 4.5:1), spacing, radii, motion and layout breakpoints (`Layout`, `WidthClass`).
- `lib/theme/app_theme.dart`: `AppTheme.light()` and `AppTheme.dark()` with Figtree type and component themes. `main.dart` is pinned to `ThemeMode.light` until every screen is migrated.
- Figtree in 4 static weights, about 40 KB each: `assets/fonts/Figtree-{Regular,Medium,SemiBold,Bold}.ttf`. With #14's Noto Devanagari that makes 5 files and about 398 KB, which is within #21's budget (6 files, 512 KB). **Do not add font files.**
- Shared UI in `lib/ui/components.dart`: Tone, DsCard, IconMedallion, SectionHeader, Monogram, Tag, StatusView, NoticeBanner, AppSnack, ContentWidth (needs `heightFactor: 1`), FormSection, BottomActionBar. Also `lib/ui/formatters.dart` (Fmt).
- Rewritten widgets: StatCard, PrimaryButton, AppTextField/FieldLabel, SegmentedSelector, ConfirmSheet, PatientLoadFailedView + PatientRefreshFailedBanner + RetryButton.
- New: `lib/widgets/export_confirm_sheet.dart`, the PDF confirm. It is built, but **not yet wired** into patient detail.
- QA locator contract: `lib/ui/qa_keys.dart`, string ValueKeys per QA plan v2 (home.*, patientForm.*, registerDup.*, patientDetail.*, visitSheet.*, share.*, pdfConfirm.*).
- Gap G1: `lib/ui/session_route_reset.dart` gives MaterialApp a navigatorKey. When `SessionController.ownerId` changes (null included), it pops to the first route, which also dismisses modals.

**Home (`36c7abf`, `4b80e95`, `378e9a3`)**
- App bar with brand, sync indicator and a profile avatar (key `home.openProfile`); greeting with date; "today" stats over `allPatients` by local calendar day ("—" while unknown).
- Pinned search (no IME learning) and a sort toggle: last visit (newest first; patients with no visits after) or name A–Z, sorted in memory outside build.
- Patient tiles: monogram, relation tag, "Partly unreadable" tag, age · gender · phone, last-visit line.
- States: loading skeleton (`home.loading`, now `!hasLoaded && !loadFailed`), empty, no matches, first-load failed, and a stale list under the refresh-failed banner.
- Extended FAB: hidden while read-only, loading or empty; icon-only once scrolled and at text scale 1.3 or more.
- Drawer: Patients / Insights / Profile, and Sign out through `SessionController.signOut()`, hidden by `DevMode.of(context)`.
- **The wide layout (permanent 280 px sidebar) was rejected by the owner and must be replaced** (section 4).

**Patient form (`4338dff`)**
- Validators kept verbatim. The form has sections, a private phone field ("+91" prefix, no flag emoji, since no emoji font is bundled) and relation chips.
- Duplicate warning sheet (`registerDup.*`) when a new patient has the same phone and normalised name. It is skipped while the load has failed. Same phone with a different name counts as family and is never blocked.
- `updatePatientDetails` is used for edits. A refused save (SaveRefusedException) keeps the form open with typed values and a banner (`patientForm.refused`). This was the coordinator's decision; the old tests still expect the form to close. The `_saving` double-tap guard is kept.

**Other**
- Figtree licence at `assets/fonts/figtree/OFL.txt` (per family, separate from `assets/fonts/NotoSansDevanagari-OFL.txt`), registered in `main()` with `LicenseRegistry.addLicense`.
- No google_fonts, no `GoogleFonts.*`, no remote image or font URLs in `lib/`, no new pubspec packages.

## 4. What is unfinished (with the requirements already received)

**4.1 Tablet / NavigationRail rework of Home: not started (stopped before any code)**
- Owner: remove the desktop sidebar (doctor card, text nav list, Sign out pinned at the bottom) and the desktop canvas.
- Under 840 dp (phones and portrait tablets): the phone layout (app bar, drawer, extended FAB), content centred at a comfortable max width, no sidebar.
- 840 dp and up: a slim M3 NavigationRail (icons with short labels, FAB at the top of the rail) plus a list-detail split, with the list on the left and the selected patient's detail on the right. Do the split only if it fits the real detail screen; otherwise use the rail and a centred list.
- Sign out lives in the drawer or profile, never pinned. Planned approach: the rail's menu button opens the same drawer, because the profile screen has no Sign out. No duplicate avatar top-right when the doctor is already shown.
- Planned token change: `Layout.expandedMin` 960 → 840; replace `sidebarWidth` with a list-pane width (about 380–400) and rail width 80.
- Goldens: drop the 1600 px desktop shot and the current `home_wide.png`. Use 360x640, 390x844, 800x1280 and 1280x800. Send the tablet goldens to the owner.
- QA 1: list bottom padding = FAB height + spacing on every layout, phones included (today it is a fixed 96). Add a test that the last row is hittable while the FAB shows.
- QA 2: in dev mode, no Sign out anywhere (drawer, rail, profile, menus); normal mode keeps it. Keep the existing `DevMode.of(context)`/kDevMode gating and add a test covering both modes.
- Backend 1: the detail pane is not a route, so the route reset does not clear it. Keep the selected patient id in state keyed on the owner (`SessionController.ownerId`) and cleared on session end. Deriving it in build (`selected = owner == selectedOwner ? id : null`, and null when the id is no longer in `allPatients`) means no frame ever shows the previous doctor's patient. Add a test: select a patient in the split, change owner or sign out, and the pane is empty.
- Backend 2: the pane uses the same detail widget and the same open entry point as the full-screen detail, including the coming per-patient "open" call (`PatientLoad.openPatient`, currently a no-op seam in `lib/utils/patient_load.dart`). Planned: call it from `PatientDetailScreen.initState`, keying the pane by patient id.
- Security: the selection is memory-only. No RestorationMixin, restorationScopeId, RestorableProperty, PageStorage or PageStorageKey for it or for any patient-identifying state. Add a test or source scan proving none is used.

**4.2 Patient detail redesign: not started.** `lib/screens/patient_detail_screen.dart` is still the old UI (merged base version).
- It needs embedded mode for the split (no back button; delete must not pop Home; family chips select in the pane instead of pushReplacement).
- Keys: `patientDetail.edit|delete|exportPdf|vitalsTrends|addNote|call|familyChip.<id>|timelineCard.<id>|unreadable` and `visitSheet.edit|delete|share`.
- Keep `_deleteThenClose` semantics: close only after the future completes; on failure close only the confirm and show "Could not delete … Nothing was deleted."; never pop the first route; keep the `_deleting` guard.
- Keep `_closeWhenPatientGone`, and keep live Edit/Delete hiding in the visit sheet after a failed reload.
- Show "Date unknown" for invalid dates. A patient with `hasParseErrors` is read-only. Call tooltip "Call".
- Share via ShareConfirmSheet → VisitShareText → `markShareText`.

**4.3 PDF confirm wiring.** Show `ExportConfirmSheet.show(context)` before `PdfExport.generateAndPrintPatientReport(patient, doctor:, testData: DevMode.of(context))`, with a double-tap guard (PDF-CONF-04). There is no share-as-PDF.

**4.4 Clinical note (visit form) redesign: not started.** `lib/screens/add_record_screen.dart` is the base version.
- Add a Notes field loaded from `existingRecord.notes`. Send null if it was never touched and nothing was loaded; send text otherwise, with '' for cleared or whitespace-only (DATA-NOTES-05). #16 `396d80b` keeps stored notes on null and clears on ''.
- Add a test for clearing notes.
- Photos: call `context.read<PatientProvider>().registerPickedAttachment(patientId: widget.patientId, localPath: path)` directly (typed) in the picker loop, after the mounted check and before adding to the new-attachment list. **Not** #8's `lib/utils/pick_registry.dart`.
- Port `/workspace/frontend-reports/merge_8_16/attachment_pick_saved_merged_test.dart`.
- Visit type: display any stored string and keep it unless changed. Date picker 2000..today. Save is blocked while photos process. Await the save before popping.

**4.5 `patientDetail.unreadable`.** This waits for the backend's per-patient open API (name to come with the next #16 commit). The seam is `PatientLoad.patientUnreadable` / `openPatient`. The state must show no row contents or error text, never look like an empty patient, and disable editing.

**4.6 Already done, to keep:** "+91" with no flag (`4b80e95`) and the Figtree licence registration (`4b80e95`). Do not undo them.

**4.7 Not started (M2):** login, profile, insights (reuse the stale banner), vitals trends, session/DB status restyle, dark theme switch-on (follow the system only), and the remaining screens. Only one APK is to be built, at the very end.

## 5. Tests: real results at `378e9a3`

`flutter test` (full suite, Flutter 3.41.2, `/opt/flutter-3.41.2/bin/flutter`): **789 passed, 11 skipped, 22 failed**, about 10 min 52 s. The full log is `test_runs/flutter_test_378e9a3.txt`.

All 22 failures are tests that pin the old UI or behaviour the redesign intentionally changed. None of them has been updated yet:

- `form_validation_test.dart` (9): AddPatientScreen finders for the old form.
- `patient_save_refused_test.dart` (4): expect a refused save to close the form, which the coordinator changed to keep it open. One also pins the old SnackBar and close-on-success flow.
- `patient_load_failed_test.dart` (4): Home fakes don't override `hasLoaded`, so Home shows the loading skeleton. There are also old Home finders.
- `ui_shared_widgets_test.dart` (3): old theme literals and the old SegmentedSelector.
- `a11y_contrast_test.dart` (1): old muted-token check.
- `backend/dev_mode_test.dart` (1): the source check expects Home's sign-out as `FirebaseAuth` behind `!DevMode.of(context)`. It is now `SessionController.signOut()` behind `!DevMode.of(context)`, so the check needs retargeting with backend agreement.

`flutter analyze`: 17 issues, 0 errors, 4 warnings, all of them unused imports that were already in the base and not added by the redesign: `lib/main.dart` database_helper, `doctor_profile_screen.dart` country_picker_dialog, `login_screen.dart` home_screen, `test/patient_load_failed_test.dart` patient_load. The other 13 are infos. The log is `test_runs/flutter_analyze_378e9a3.txt`.

The targeted runs during the work (shots harness, shared widgets, Home tests) are superseded by the full run above.

## 6. Golden screenshots

The goldens are local only and git-ignored (`test/shots/goldens/`). They were rendered at 11:48 from the working tree that was committed a minute later as `2b3c53f` (rebased as `4b80e95`), so they show `4b80e95` without the `378e9a3` hasLoaded change:

`/workspace/redesign/app/test/shots/goldens/` contains `home_list.png`, `home_list_dark.png`, `home_empty.png`, `home_failed.png`, `home_stale.png`, `home_nomatch.png`, `home_text2x.png`, `home_small.png`, `home_drawer.png`, `home_scrolled.png`, `home_wide.png` (**rejected design**), `form_new.png`, `form_edit.png`, `form_errors.png`, `form_dup.png` and `form_text2x.png`. `home_loading.png` has not been rendered yet. Contact sheets used in review are at `/tmp/home_sheet3.png`, `/tmp/form_sheet2.png` and `/tmp/fix_sheet.png`; they are temporary.

Regenerate them with:
```
cd <repo> && SHOTS=1 flutter test test/shots/home_shots_test.dart --update-goldens
```
The harness (`test/shots/home_shots_test.dart`, `test/shots/shot_fonts.dart`) loads Figtree and the Material icons from the Flutter SDK cache and enables real shadows. Each shot pumps a fresh tree.

## 7. Exact steps to continue

1. Check out the branch: `git fetch origin redesign/m1-wip && git checkout redesign/m1-wip`.
2. Optionally refresh the base: merge #21 `cfaed37` and any newer backend heads (#16's next commit brings the per-patient open API name). For rebased heads, use the same method as stage B: take theirs where nothing else touched the file, otherwise `git merge-file` with the previous PR head as base.
3. Run `flutter pub get`, `flutter analyze`, then `flutter test` and compare against section 5.
4. Build the tablet layout (4.1) together with the patient detail redesign (4.2), since the split needs the embedded detail. Then the PDF confirm (4.3), then the visit form (4.4).
5. Update the 22 old-UI tests, with the reasons from section 5. Add the new tests listed in 4.1 (FAB padding/hit test, dev-mode Sign out in both modes, split pane cleared on owner change/sign-out, restoration/PageStorage scan) and 4.4 (notes clearing, ported pick test).
6. Render goldens at 360x640, 390x844, 800x1280 and 1280x800 (drop `home_wide.png`) and send the tablet ones to the owner.
7. Keep the rules: no new packages without DevOps and security sign-off; no new font files; images at most 200 KB and 2048 px; no google_fonts or remote URLs; only the public provider API in screens; await every mutation before success UI; fixed user-facing strings (never error text); don't touch the lock screen (`app_lock.dart`) without security; `kDevMode`/`dev_mode.dart`/`lib/dev/*` stay byte-identical.

## 8. Notes and sources (local, under /workspace)

- Running notes, with every requirement received and its timestamp: `/workspace/redesign/notes/phase1_findings.md`.
- Commit appendix: `/workspace/redesign/notes/branch_commits_not_in_prs.txt`.
- Inputs: the QA plan v2 (`/home/ubuntu/upload/8dd921a1a9ac455140a1704b_UI_ACCEPTANCE_REGRESSION_PLAN.md`), the backend contract (`/home/ubuntu/upload/dfc9492cf9b9c06f62a2517b_ui_redesign_contract.md`), the data model review (`/home/ubuntu/upload/61c2078a6c478ac29ef8a913_redesign_data_model_review.md`) and the brief (`/home/ubuntu/upload/pasted_content_E6APTtSTRYwQ1GmBD0h1dA.txt`).

These local files do not travel with the GitHub branch. Only this handoff document is copied into the branch.

## 9. Push record

(filled in after push)
