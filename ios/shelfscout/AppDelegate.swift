import UIKit
import React
import React_RCTAppDelegate
import ReactAppDependencyProvider
import MWDATCore

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?

  var reactNativeDelegate: ReactNativeDelegate?
  var reactNativeFactory: RCTReactNativeFactory?

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    do {
      // AppDelegate.swift, before Wearables.configure()
      if let mwdat = Bundle.main.object(forInfoDictionaryKey: "MWDAT") as? [String: Any] {
      NSLog("🔍 [MWDAT] Resolved plist values: %@", mwdat)}
      try Wearables.configure()
      NSLog("✅ [Wearables] SDK configured")
    } catch {
      NSLog("⚠️ [Wearables] SDK configure error: %@", error.localizedDescription)
    }

    let delegate = ReactNativeDelegate()
    let factory = RCTReactNativeFactory(delegate: delegate)
    delegate.dependencyProvider = RCTAppDependencyProvider()

    reactNativeDelegate = delegate
    reactNativeFactory = factory

    window = UIWindow(frame: UIScreen.main.bounds)

    factory.startReactNative(
      withModuleName: "shelfscout",
      in: window,
      launchOptions: launchOptions
    )

    return true
  }

  func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    Task {
      do {
        _ = try await Wearables.shared.handleUrl(url)
      } catch {
        NSLog("⚠️ [Wearables] handleUrl error: %@", error.localizedDescription)
      }
    }

    return true
  }
}

class ReactNativeDelegate: RCTDefaultReactNativeFactoryDelegate {
  override func sourceURL(for bridge: RCTBridge) -> URL? {
    self.bundleURL()
  }

  override func bundleURL() -> URL? {
#if DEBUG
    RCTBundleURLProvider.sharedSettings().jsBundleURL(forBundleRoot: "index")
#else
    Bundle.main.url(forResource: "main", withExtension: "jsbundle")
#endif
  }
}
