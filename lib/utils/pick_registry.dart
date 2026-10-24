import '../providers/patient_provider.dart';

/// Tells the patient provider that the picker has copied a photo for
/// [patientId]'s visit form to [localPath] (the processor's JPEG in the
/// app's photo folder, `attachments/<owner>/`).
///
/// #16 (Security L-1) adds `PatientProvider.registerPickedAttachment`. From
/// then on a save keeps a new local photo only if it was registered this
/// session, so without this call every new photo would be left out of the
/// save and later deleted by the sweep (for a camera photo, the only copy).
///
/// It is called by name until #16 is merged, so this branch builds on its
/// own (no registry there, so nothing to do) and the call is in place
/// whichever of #8 / #16 merges second. Once both are in, replace the body
/// with the direct call:
///
///     provider.registerPickedAttachment(patientId: patientId, localPath: localPath);
void registerPickedAttachment(PatientProvider provider, {required String patientId, required String localPath}) {
  try {
    (provider as dynamic).registerPickedAttachment(patientId: patientId, localPath: localPath);
  } on NoSuchMethodError {
    // Before #16: no registry; saves keep picked photos as they always have.
  }
}
