import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var configChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    GeneratedPluginRegistrant.register(with: self)

    DispatchQueue.main.async { [weak self] in
      self?.setupMethodChannelsIfNeeded()
    }

    return result
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    setupMethodChannelsIfNeeded()
  }

  private func setupMethodChannelsIfNeeded() {
    guard configChannel == nil else {
      return
    }

    guard let flutterViewController = rootFlutterViewController() else {
      return
    }

    let channel = FlutterMethodChannel(
      name: "babycare/config",
      binaryMessenger: flutterViewController.binaryMessenger
    )

    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "openVehicleConfiguration":
        self?.openVehicleConfiguration(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    configChannel = channel
  }

  private func rootFlutterViewController() -> FlutterViewController? {
    if let flutterViewController = window?.rootViewController as? FlutterViewController {
      return flutterViewController
    }

    return UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .compactMap { $0.rootViewController as? FlutterViewController }
      .first
  }

  private func topViewController(from root: UIViewController?) -> UIViewController? {
    guard let root = root else {
      return nil
    }

    if let navigationController = root as? UINavigationController {
      return topViewController(from: navigationController.visibleViewController)
    }

    if let tabBarController = root as? UITabBarController {
      return topViewController(from: tabBarController.selectedViewController)
    }

    if let presentedViewController = root.presentedViewController {
      return topViewController(from: presentedViewController)
    }

    return root
  }

  private func openVehicleConfiguration(result: @escaping FlutterResult) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self,
            let presentingVC = self.topViewController(from: self.window?.rootViewController)
      else {
        result(FlutterError(code: "NO_ROOT_VC", message: "No root view controller", details: nil))
        return
      }

      let vehicleConfigVC = VehicleConfigurationViewController()
      let navigationController = UINavigationController(rootViewController: vehicleConfigVC)

      let appearance = UINavigationBarAppearance()
      appearance.configureWithTransparentBackground()
      appearance.backgroundColor = UIColor(red: 0.027, green: 0.165, blue: 0.227, alpha: 1.0)
      appearance.titleTextAttributes = [.foregroundColor: UIColor.white]
      navigationController.navigationBar.standardAppearance = appearance
      navigationController.navigationBar.scrollEdgeAppearance = appearance
      navigationController.navigationBar.tintColor = .white
      navigationController.modalPresentationStyle = .fullScreen

      presentingVC.present(navigationController, animated: true) {
        result(true)
      }
    }
  }
}
