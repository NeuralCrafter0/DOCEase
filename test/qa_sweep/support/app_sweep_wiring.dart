// Mirrors exactly how PhotoSweep.forApp() builds the app's sweep, but for an
// injected database, photo store, clock and load status (forApp() hard-codes
// DatabaseHelper.instance, PatientLoadStatus.instance, LocalPhotoStore.instance
// and the real clock, so tests can't age files through it).
//
// HEAD-SPECIFIC. This copy matches #16 3a695b0:
//   factory PhotoSweep.forApp() =>
//       PhotoSweep(db: DatabaseHelper.instance, loadStatus: PatientLoadStatus.instance);
// Keys and references come from the DB itself (#10's
// referencedAttachmentKeys + AttachmentRefs.attachmentKey). If forApp()
// changes, update this file; SWP-00 pins forApp() itself.
import 'package:docease/providers/local_database.dart';
import 'package:docease/services/local_photo_store.dart';
import 'package:docease/services/patient_load_status.dart';
import 'package:docease/services/photo_sweep.dart';

const appWiringHead =
    '3a695b0 (PhotoSweep(db: DatabaseHelper.instance, loadStatus: PatientLoadStatus.instance))';

/// [loadStatus] defaults to a fresh, never-failed status (the app's
/// instance is a process-wide singleton; tests must not share it).
PhotoSweep appSweep(LocalDatabase db, LocalPhotoStore photos,
        DateTime Function() now, {PatientLoadStatus? loadStatus}) =>
    PhotoSweep(db: db, photos: photos, now: now,
        loadStatus: loadStatus ?? PatientLoadStatus());
