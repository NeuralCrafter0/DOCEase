/// Whose data the app is working with right now: the owner of the open,
/// ready session. That is the signed-in Firebase uid in the normal app, and
/// `local` (kLocalOwnerId) in dev mode. It is null while signed out,
/// starting, waiting for approval, migrating, failed, or tearing down.
///
/// Only [SessionController] sets it. Code without a BuildContext reads it,
/// for example PR #8's photo picker:
///
/// ```dart
/// AttachmentStorage.currentOwnerId = () => CurrentOwner.id;
/// ```
///
/// Photo folders are `sha256(owner)` hex, first 32 characters
/// (`LocalPhotoStore.ownerFolderName`), so a photo picked while
/// [id] is X lands in the same folder the providers use for X.
abstract final class CurrentOwner {
  static String? _id;
  static Object? _setter;

  /// The current owner id, or null when no session is ready.
  static String? get id => _id;

  /// Called by SessionController only. [by] identifies the controller, so a
  /// disposed controller cannot clear a newer controller's owner.
  static void update(String? id, {required Object by}) {
    _id = id;
    _setter = by;
  }

  /// Clears the owner if [by] set it last (SessionController.dispose).
  static void clearIfSetBy(Object by) {
    if (identical(_setter, by)) {
      _id = null;
      _setter = null;
    }
  }
}
