import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DocEaseBackupExclusion") {
      BackupExclusion.register(messenger: registrar.messenger())
    }
  }
}

/// `docease/backup_exclusion`: sets NSURLIsExcludedFromBackupKey on a path
/// (the encrypted patient database, its directory and key-check sidecar),
/// so they never go to iCloud/iTunes backups. Called by
/// PlatformBackupExcluder in lib/providers/database_helper.dart after every
/// successful open (an atomic file replace drops the attribute).
enum BackupExclusion {
  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "docease/backup_exclusion", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "excludeFromBackup",
        let args = call.arguments as? [String: Any],
        let path = args["path"] as? String
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      var url = URL(fileURLWithPath: path)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      do {
        try url.setResourceValues(values)
        result(nil)
      } catch {
        // No path or error text: the caller logs only the code.
        result(FlutterError(code: "exclude_failed", message: nil, details: nil))
      }
    }
  }
}
