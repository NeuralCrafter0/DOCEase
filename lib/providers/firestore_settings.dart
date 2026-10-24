import 'package:cloud_firestore/cloud_firestore.dart';

/// Turns off Firestore's offline persistence. Its on-disk cache would keep
/// patient records unencrypted on the device, outside SQLCipher.
///
/// Call once in `main()` right after `Firebase.initializeApp()` and before
/// any other Firestore use (settings cannot change after first use).
///
/// Consequence: offline writes now only queue in memory and are lost if the
/// app is killed before they reach the server. Retrying after a restart
/// relies on the local `sync_state = dirty` rows (see DatabaseHelper and
/// PatientProvider), not on the Firestore cache.
void configureFirestoreForEncryptedLocalStore([FirebaseFirestore? firestore]) {
  final fs = firestore ?? FirebaseFirestore.instance;
  fs.settings = const Settings(persistenceEnabled: false);
}
