import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// User-facing sign-in error text. Never shows raw exception text, and never
/// reveals whether an account exists: every credential-type failure gets the
/// same message.
class AuthErrorMessages {
  AuthErrorMessages._();

  static const String incorrectCredentials = 'Email or password is incorrect';
  static const String network = 'No internet connection. Check your connection and try again.';
  static const String tooManyAttempts = 'Too many attempts. Try again later.';
  static const String generic = 'Sign-in failed. Try again.';
  static const String googleFailed = 'Google sign-in failed. Try again.';

  /// Codes that must all look the same to the user (no account enumeration).
  static const Set<String> _credentialCodes = {
    'user-not-found',
    'wrong-password',
    'invalid-credential',
    'invalid-login-credentials',
    'invalid-email',
    'user-disabled',
    'INVALID_LOGIN_CREDENTIALS',
  };

  /// Message for an email/password sign-in failure.
  static String forEmailSignIn(Object error) {
    if (error is FirebaseAuthException) {
      if (_credentialCodes.contains(error.code)) return incorrectCredentials;
      if (error.code == 'network-request-failed') return network;
      if (error.code == 'too-many-requests') return tooManyAttempts;
    }
    return generic;
  }

  /// Message for a Google sign-in failure, or null when the user just closed
  /// the account picker (nothing to show).
  static String? forGoogleSignIn(Object error) {
    if (error is GoogleSignInException && error.code == GoogleSignInExceptionCode.canceled) return null;
    if (error is FirebaseAuthException) {
      if (error.code == 'network-request-failed') return network;
      if (error.code == 'too-many-requests') return tooManyAttempts;
    }
    return googleFailed;
  }
}
