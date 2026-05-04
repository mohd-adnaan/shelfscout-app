import UIKit
import MWDATCore

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene else { return }

    let window = UIWindow(windowScene: windowScene)
    let appDelegate = UIApplication.shared.delegate as? AppDelegate
    appDelegate?.window = window

    if let factory = appDelegate?.reactNativeFactory {
      factory.startReactNative(
        withModuleName: "shelfscout",
        in: window,
        launchOptions: appDelegate?.launchOptionsCache
      )
    }

    self.window = window
  }

  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    guard let url = URLContexts.first?.url else { return }
    Task {
      do {
        _ = try await Wearables.shared.handleUrl(url)
      } catch {
        NSLog("⚠️ [Wearables] handleUrl error: %@", error.localizedDescription)
      }
    }
  }
}
