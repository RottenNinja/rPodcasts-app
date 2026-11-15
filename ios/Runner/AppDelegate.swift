import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, UIDocumentPickerDelegate {
  private var saving: FlutterResult?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // The name shown on the server's Devices page, so sign-in needn't ask for one.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DeviceName") {
      FlutterMethodChannel(name: "rpodcasts/device", binaryMessenger: registrar.messenger()).setMethodCallHandler { call, result in
        result(call.method == "name" ? UIDevice.current.name : FlutterMethodNotImplemented)
      }
    }
    // Saves text through the system "save to" picker, so the user chooses where the file goes.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FileSaver") {
      FlutterMethodChannel(name: "rpodcasts/files", binaryMessenger: registrar.messenger()).setMethodCallHandler { [weak self] call, result in
        guard let self, call.method == "save", let args = call.arguments as? [String: String], let name = args["name"], let text = args["text"] else {
          return result(FlutterMethodNotImplemented)
        }
        self.save(name: name, text: text, result: result)
      }
    }
  }

  private func save(name: String, text: String, result: @escaping FlutterResult) {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    do {
      try text.write(to: file, atomically: true, encoding: .utf8)
    } catch {
      return result(FlutterError(code: "save", message: error.localizedDescription, details: nil))
    }
    let root = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
    guard var top = root else {
      return result(FlutterError(code: "save", message: "No window to show the file picker in", details: nil))
    }
    while let next = top.presentedViewController { top = next }
    saving?(false)
    saving = result
    let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
    picker.delegate = self
    top.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    saving?(true)
    saving = nil
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    saving?(false)
    saving = nil
  }
}
