// Regression tests for generic sign-in errors (security review C8).
import 'package:docease/utils/auth_error_messages.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';

FirebaseAuthException fae(String code) =>
    FirebaseAuthException(code: code, message: 'There is no user record corresponding to this identifier ($code).');

void main() {
  test('C8 same message for user-not-found, wrong-password, invalid-credential', () {
    final messages = {
      for (final c in ['user-not-found', 'wrong-password', 'invalid-credential', 'invalid-email', 'user-disabled', 'INVALID_LOGIN_CREDENTIALS'])
        AuthErrorMessages.forEmailSignIn(fae(c)),
    };
    expect(messages, {AuthErrorMessages.incorrectCredentials});
  });

  test('never shows raw exception text', () {
    for (final e in <Object>[fae('internal-error'), Exception('[firebase_auth/user-not-found] secret'), StateError('x')]) {
      final m = AuthErrorMessages.forEmailSignIn(e);
      expect(m, isNot(contains('firebase_auth')));
      expect(m, isNot(contains('user-not-found')));
      expect(m, isNot(contains('no user record')));
    }
    expect(AuthErrorMessages.forEmailSignIn(fae('internal-error')), AuthErrorMessages.generic);
  });

  test('network and rate-limit errors get their own (non-enumerating) text', () {
    expect(AuthErrorMessages.forEmailSignIn(fae('network-request-failed')), AuthErrorMessages.network);
    expect(AuthErrorMessages.forEmailSignIn(fae('too-many-requests')), AuthErrorMessages.tooManyAttempts);
  });

  test('Google: cancel is silent, everything else is generic', () {
    expect(AuthErrorMessages.forGoogleSignIn(const GoogleSignInException(code: GoogleSignInExceptionCode.canceled)), isNull);
    expect(AuthErrorMessages.forGoogleSignIn(const GoogleSignInException(code: GoogleSignInExceptionCode.interrupted)), AuthErrorMessages.googleFailed);
    expect(AuthErrorMessages.forGoogleSignIn(const GoogleSignInException(code: GoogleSignInExceptionCode.unknownError, description: 'raw detail')), AuthErrorMessages.googleFailed);
    expect(AuthErrorMessages.forGoogleSignIn(fae('account-exists-with-different-credential')), AuthErrorMessages.googleFailed);
    expect(AuthErrorMessages.forGoogleSignIn(fae('network-request-failed')), AuthErrorMessages.network);
  });
}
