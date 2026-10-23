/// Cancels work that belongs to one signed-in session.
///
/// SessionController creates one token per session and cancels it when that
/// session ends (sign-out or a switch to another account). Long-running work
/// such as PatientProvider.loadAndSync checks [isCancelled] after every await
/// and drops its results, so data loaded for doctor A is never applied while
/// doctor B is signed in.
class SyncCancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}
