// Mirrors exactly how PhotoSweep.forApp() builds the app's sweep, but for an
// injected database, photo store and clock (forApp() hard-codes
// DatabaseHelper.instance, LocalPhotoStore.instance and the real clock, so
// tests can't age files through it).
//
// HEAD-SPECIFIC. This copy matches #16 a8eaf9e:
//   factory PhotoSweep.forApp() => PhotoSweep(db: DatabaseHelper.instance);
// Keys and references come from the DB itself (#10's
// referencedAttachmentKeys + AttachmentRefs.attachmentKey). If forApp()
// changes, update this file; SWP-00 pins forApp() itself.
import 'package:docease/providers/local_database.dart';
import 'package:docease/services/local_photo_store.dart';
import 'package:docease/services/photo_sweep.dart';

const appWiringHead = 'a8eaf9e (PhotoSweep(db: DatabaseHelper.instance))';

PhotoSweep appSweep(LocalDatabase db, LocalPhotoStore photos,
        DateTime Function() now) =>
    PhotoSweep(db: db, photos: photos, now: now);
