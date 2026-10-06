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
    let registry = engineBridge.pluginRegistry
    GeneratedPluginRegistrant.register(with: registry)
    SecureEnclaveBridge.register(with: registry.registrar(forPlugin: "SecureEnclaveBridge")!)
    ImageBridge.register(with: registry.registrar(forPlugin: "ImageBridge")!)

    // Dart excludes Application Support before opening its persistent stores
    let storage = FlutterMethodChannel(
      name: "miuchio/storage",
      binaryMessenger: registry.registrar(forPlugin: "StorageBridge")!.messenger()
    )
    storage.setMethodCallHandler { call, result in
      guard call.method == "excludeFromBackup",
        let path = (call.arguments as? [String: Any])?["path"] as? String
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
        result(FlutterError(code: "E_NATIVE", message: "\(error)", details: nil))
      }
    }
  }
}
