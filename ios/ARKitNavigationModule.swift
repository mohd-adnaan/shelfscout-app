import ARKit
import React
import SwiftUI
import UIKit

@objc(ARKitNavigationModule)
final class ARKitNavigationModule: NSObject {
    private var presentedController: UIViewController?
    private var pendingResolve: RCTPromiseResolveBlock?
    private var activeTargetName: String?

    @objc
    static func requiresMainQueueSetup() -> Bool {
        true
    }

    @objc(isAvailable:rejecter:)
    func isAvailable(
        _ resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        resolve(ARWorldTrackingConfiguration.isSupported)
    }

    @objc(presentRouteManager:rejecter:)
    func presentRouteManager(
        _ resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        DispatchQueue.main.async {
            guard ARWorldTrackingConfiguration.isSupported else {
                reject("ar_unavailable", "ARKit world tracking is not available on this device.", nil)
                return
            }

            guard let presenter = Self.topViewController() else {
                reject("presentation_error", "Could not find a view controller for AR route mapping.", nil)
                return
            }

            let host = ARKitRouteHostView(
                launchTargetName: nil,
                launchRouteMapId: nil,
                launchRouteMapName: nil,
                speakLandmarks: true,
                errorRecovery: true,
                ttsRate: nil,
                onDone: { [weak self] in
                    self?.dismissPresentedController(resolveCancelledNavigation: false)
                },
                onAutomationComplete: nil
            )

            let controller = UIHostingController(rootView: host)
            controller.modalPresentationStyle = .fullScreen
            self.presentedController = controller
            presenter.present(controller, animated: true) {
                resolve(nil)
            }
        }
    }

    @objc(startNavigation:resolver:rejecter:)
    func startNavigation(
        _ config: NSDictionary,
        resolver resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        DispatchQueue.main.async {
            guard ARWorldTrackingConfiguration.isSupported else {
                resolve(ARKitNavigationNativeResult(
                    success: false,
                    reason: "ar_unavailable",
                    targetName: config["targetName"] as? String,
                    routeName: nil,
                    message: "ARKit world tracking is not available on this device."
                ).dictionary())
                return
            }

            let targetName = (config["targetName"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !targetName.isEmpty else {
                resolve(ARKitNavigationNativeResult(
                    success: false,
                    reason: "target_not_found",
                    targetName: nil,
                    routeName: nil,
                    message: "No navigation target was provided."
                ).dictionary())
                return
            }

            guard self.pendingResolve == nil else {
                resolve(ARKitNavigationNativeResult(
                    success: false,
                    reason: "error",
                    targetName: targetName,
                    routeName: nil,
                    message: "ARKit navigation is already running."
                ).dictionary())
                return
            }

            guard let presenter = Self.topViewController() else {
                resolve(ARKitNavigationNativeResult(
                    success: false,
                    reason: "error",
                    targetName: targetName,
                    routeName: nil,
                    message: "Could not open ARKit navigation."
                ).dictionary())
                return
            }

            self.pendingResolve = resolve
            self.activeTargetName = targetName

            let routeMapId = config["routeMapId"] as? String
            let routeMapName = config["routeMapName"] as? String
            let speakLandmarks = (config["speakLandmarks"] as? NSNumber)?.boolValue ?? true
            let errorRecovery = (config["errorRecovery"] as? NSNumber)?.boolValue ?? true
            let ttsRate = (config["ttsRate"] as? NSNumber)?.doubleValue

            let host = ARKitRouteHostView(
                launchTargetName: targetName,
                launchRouteMapId: routeMapId,
                launchRouteMapName: routeMapName,
                speakLandmarks: speakLandmarks,
                errorRecovery: errorRecovery,
                ttsRate: ttsRate,
                onDone: { [weak self] in
                    self?.finishNavigation(ARKitNavigationNativeResult(
                        success: false,
                        reason: "cancelled",
                        targetName: targetName,
                        routeName: routeMapName,
                        message: "ARKit navigation cancelled."
                    ))
                },
                onAutomationComplete: { [weak self] result in
                    self?.finishNavigation(result)
                }
            )

            let controller = UIHostingController(rootView: host)
            controller.modalPresentationStyle = .fullScreen
            self.presentedController = controller
            presenter.present(controller, animated: true)
        }
    }

    @objc(stopNavigation:rejecter:)
    func stopNavigation(
        _ resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        DispatchQueue.main.async {
            self.dismissPresentedController(resolveCancelledNavigation: true)
            resolve(nil)
        }
    }

    private func finishNavigation(_ result: ARKitNavigationNativeResult) {
        DispatchQueue.main.async {
            let resolver = self.pendingResolve
            self.pendingResolve = nil
            self.activeTargetName = nil
            let shouldResolveBeforeDismiss = result.success && result.reason == "arrived"

            let resolveResult: () -> Void = {
                resolver?(result.dictionary())
            }

            if let controller = self.presentedController {
                self.presentedController = nil
                if shouldResolveBeforeDismiss {
                    resolveResult()
                    controller.dismiss(animated: true)
                } else {
                    controller.dismiss(animated: true, completion: resolveResult)
                }
            } else {
                resolveResult()
            }
        }
    }

    private func dismissPresentedController(resolveCancelledNavigation: Bool) {
        let resolver = pendingResolve
        let targetName = activeTargetName
        pendingResolve = nil
        activeTargetName = nil

        if let controller = presentedController {
            presentedController = nil
            controller.dismiss(animated: true) {
                if resolveCancelledNavigation {
                    resolver?(ARKitNavigationNativeResult(
                        success: false,
                        reason: "cancelled",
                        targetName: targetName,
                        routeName: nil,
                        message: "ARKit navigation cancelled."
                    ).dictionary())
                }
            }
        } else if resolveCancelledNavigation {
            resolver?(ARKitNavigationNativeResult(
                success: false,
                reason: "cancelled",
                targetName: targetName,
                routeName: nil,
                message: "ARKit navigation cancelled."
            ).dictionary())
        }
    }

    private static func topViewController(
        base: UIViewController? = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .rootViewController
    ) -> UIViewController? {
        if let navigation = base as? UINavigationController {
            return topViewController(base: navigation.visibleViewController)
        }
        if let tab = base as? UITabBarController,
           let selected = tab.selectedViewController {
            return topViewController(base: selected)
        }
        if let presented = base?.presentedViewController {
            return topViewController(base: presented)
        }
        return base
    }
}

private struct ARKitRouteHostView: View {
    @StateObject private var sensorManager: IMUSensorManager
    @StateObject private var ttsManager: TTSManager

    let launchTargetName: String?
    let launchRouteMapId: String?
    let launchRouteMapName: String?
    let speakLandmarks: Bool
    let errorRecovery: Bool
    let onDone: () -> Void
    let onAutomationComplete: ((ARKitNavigationNativeResult) -> Void)?

    init(
        launchTargetName: String?,
        launchRouteMapId: String?,
        launchRouteMapName: String?,
        speakLandmarks: Bool,
        errorRecovery: Bool,
        ttsRate: Double?,
        onDone: @escaping () -> Void,
        onAutomationComplete: ((ARKitNavigationNativeResult) -> Void)?
    ) {
        let sensor = IMUSensorManager()
        let speech = TTSManager()
        speech.setSpeechRate(ttsRate)
        _sensorManager = StateObject(wrappedValue: sensor)
        _ttsManager = StateObject(wrappedValue: speech)
        self.launchTargetName = launchTargetName
        self.launchRouteMapId = launchRouteMapId
        self.launchRouteMapName = launchRouteMapName
        self.speakLandmarks = speakLandmarks
        self.errorRecovery = errorRecovery
        self.onDone = onDone
        self.onAutomationComplete = onAutomationComplete
    }

    var body: some View {
        NavigationView {
            ARMappingView(
                launchTargetName: launchTargetName,
                launchRouteMapId: launchRouteMapId,
                launchRouteMapName: launchRouteMapName,
                launchSpeakLandmarks: speakLandmarks,
                launchErrorRecovery: errorRecovery,
                onAutomationComplete: onAutomationComplete
            )
            .environmentObject(sensorManager)
            .environmentObject(ttsManager)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done", action: onDone)
                }
            }
        }
        .accentColor(launchTargetName == nil ? Color.accentColor : Color(red: 0.18, green: 0.72, blue: 0.62))
        .navigationViewStyle(.stack)
    }
}
