import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    PrivacyCover.shared.install()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// Hides patient data from the app-switcher snapshot (security review
  /// F4-2). iOS takes that snapshot as the scene resigns active, after
  /// Flutter has stopped drawing, so the Flutter lock screen is not in it.
  /// The cover is drawn natively the moment a scene is about to go inactive
  /// and removed when it is active again. It does not unlock or authenticate
  /// anything; the Flutter app lock still re-locks on every backgrounding.
  final class PrivacyCover: NSObject {
    static let shared = PrivacyCover()
    private var covers: [ObjectIdentifier: UIView] = [:]

    func install() {
      let center = NotificationCenter.default
      center.addObserver(
        self, selector: #selector(sceneWillDeactivate(_:)),
        name: UIScene.willDeactivateNotification, object: nil)
      center.addObserver(
        self, selector: #selector(sceneDidActivate(_:)),
        name: UIScene.didActivateNotification, object: nil)
    }

    @objc private func sceneWillDeactivate(_ notification: Notification) {
      guard let scene = notification.object as? UIWindowScene else { return }
      for window in scene.windows where covers[ObjectIdentifier(window)] == nil {
        let cover = UIView(frame: window.bounds)
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // Same colour as the Flutter lock screen (0xFF1E293B).
        cover.backgroundColor = UIColor(red: 30 / 255, green: 41 / 255, blue: 59 / 255, alpha: 1)
        let shield = UIImageView(image: UIImage(systemName: "shield"))
        shield.tintColor = .white
        shield.contentMode = .scaleAspectFit
        shield.translatesAutoresizingMaskIntoConstraints = false
        cover.addSubview(shield)
        NSLayoutConstraint.activate([
          shield.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
          shield.centerYAnchor.constraint(equalTo: cover.centerYAnchor),
          shield.widthAnchor.constraint(equalToConstant: 80),
          shield.heightAnchor.constraint(equalToConstant: 80),
        ])
        window.addSubview(cover)
        covers[ObjectIdentifier(window)] = cover
      }
    }

    @objc private func sceneDidActivate(_ notification: Notification) {
      guard let scene = notification.object as? UIWindowScene else { return }
      for window in scene.windows {
        covers.removeValue(forKey: ObjectIdentifier(window))?.removeFromSuperview()
      }
    }
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
