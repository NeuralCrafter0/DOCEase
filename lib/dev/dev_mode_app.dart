import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/dev_mode.dart';
import '../providers/doctor_provider.dart';
import '../providers/medicine_provider.dart';
import '../providers/patient_provider.dart';
import '../screens/home_screen.dart';
import '../services/local_photo_store.dart';
import '../services/log_codes.dart';
import '../services/session_controller.dart';
import '../widgets/session_status_view.dart';

/// Dev mode (kDevMode) provider tree around [app]: every provider is
/// on-phone only and the session opens the encrypted DB for
/// [kLocalOwnerId], and widgets see `DevMode.of(context) == true`.
/// Nothing here touches Firebase or Google Sign-In.
Future<Widget> buildDevModeApp(Widget app) async {
  try {
    await LocalPhotoStore.instance.init();
  } catch (e) {
    debugPrint('Photo folder unavailable: ${errorCode(e)}');
  }
  return MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => PatientProvider(cloudSync: false)),
      ChangeNotifierProvider(create: (_) => DoctorProvider(cloudSync: false)),
      ChangeNotifierProvider(create: (_) => MedicineProvider(cloudSync: false)),
      ChangeNotifierProvider(
        create: (ctx) => SessionController.localOnly(
          patients: ctx.read<PatientProvider>(),
          doctor: ctx.read<DoctorProvider>(),
          medicines: ctx.read<MedicineProvider>(),
        ),
      ),
    ],
    child: DevMode(enabled: true, child: app),
  );
}

/// Dev mode root: no login screen and no biometric lock. Shows HomeScreen
/// once the on-phone DB is open (SessionStatusView while opening/failing).
class DevModeHome extends StatelessWidget {
  const DevModeHome({super.key});

  @override
  Widget build(BuildContext context) => Consumer<SessionController>(
        builder: (ctx, session, _) =>
            session.isReady ? const HomeScreen() : SessionStatusView(session: session),
      );
}

/// MaterialApp.builder for dev mode: a red strip with [kDevModeBannerText]
/// above every screen and dialog.
Widget devModeBannerBuilder(BuildContext context, Widget? child) {
  final media = MediaQuery.of(context);
  return Column(children: [
    Material(
      color: const Color(0xFFB91C1C),
      child: Padding(
        padding: EdgeInsets.only(top: media.padding.top, bottom: 2),
        child: const SizedBox(
          width: double.infinity,
          child: Text(kDevModeBannerText,
              key: Key('devModeBanner'),
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
        ),
      ),
    ),
    Expanded(
      child: MediaQuery.removePadding(context: context, removeTop: true, child: child ?? const SizedBox()),
    ),
  ]);
}
