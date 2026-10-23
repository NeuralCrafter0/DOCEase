// QA shim (not committed): installLocalAuth over PR #4's LocalAuthPlatform.
import 'package:flutter/services.dart';
import 'package:local_auth_platform_interface/local_auth_platform_interface.dart';

class QaLocalAuth extends LocalAuthPlatform {
  QaLocalAuth(this.mode);
  final String mode; // 'allow' | 'deny' | 'throw' | 'unsupported'
  int authCalls = 0;
  @override
  Future<bool> isDeviceSupported() async => mode != 'unsupported';
  @override
  Future<bool> deviceSupportsBiometrics() async => mode != 'unsupported';
  @override
  Future<List<BiometricType>> getEnrolledBiometrics() async => const [];
  @override
  Future<bool> authenticate({
    required String localizedReason,
    required Iterable<AuthMessages> authMessages,
    AuthenticationOptions options = const AuthenticationOptions(),
  }) async {
    authCalls++;
    if (mode == 'unsupported') throw PlatformException(code: 'NotAvailable');
    if (mode == 'throw') throw PlatformException(code: 'NotAvailable');
    return mode == 'allow';
  }
}

QaLocalAuth installLocalAuth(String mode) {
  final f = QaLocalAuth(mode);
  LocalAuthPlatform.instance = f;
  return f;
}
