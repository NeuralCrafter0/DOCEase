import 'package:flutter/material.dart';

/// Shown instead of the app when a release build was made with
/// DOCEASE_DEV_MODE=true. It blocks everything: no home, no banner,
/// no login or lock bypass, no Firebase, no database.
class DevBuildRefusedApp extends StatelessWidget {
  const DevBuildRefusedApp({super.key});

  static const title = 'Dev build refused';

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: PopScope(
          canPop: false,
          child: Scaffold(
            backgroundColor: const Color(0xFF7F1D1D),
            body: SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(mainAxisSize: MainAxisSize.min, children: const [
                    Icon(Icons.block, color: Colors.white, size: 64),
                    SizedBox(height: 16),
                    Text(title,
                        key: Key('devBuildRefused'),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
                    SizedBox(height: 12),
                    Text(
                      'This release build was made with DOCEASE_DEV_MODE=true. '
                      'Dev mode only runs in debug or profile builds of the dev flavor. '
                      'Rebuild without the define.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white70, fontSize: 15),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ),
      );
}
