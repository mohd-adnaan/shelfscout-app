import ARKit
import React
import SwiftUI
import UIKit
#if canImport(FoundationModels)
import FoundationModels
#endif

@objc(ARKitNavigationModule)
final class ARKitNavigationModule: NSObject {
    private var presentedController: UIViewController?
    private var pendingResolve: RCTPromiseResolveBlock?
    private var activeTargetName: String?
    /// Set by the launching config; when true an `arrived` result that needs
    /// no reaching handoff leaves the screen mounted so the next leg can
    /// retarget without paying another relocalization.
    private var keepSessionAlive = false

    /// How long a launch may sit without the AR screen actually appearing
    /// before we conclude the presentation failed and recover.
    private static let presentationWatchdogSeconds: TimeInterval = 6

    /// Guards against a launch that never produces a visible screen.
    ///
    /// `pendingResolve` is a single slot, and `startNavigation` refuses to
    /// launch while it is occupied ("ARKit navigation is already running").
    /// So if a launch ever sets it without the screen coming up — UIKit
    /// silently refuses to present when the presenter is already presenting
    /// something, which happens whenever a JS `Alert.alert` or the reaching
    /// screen is on top — then `onDone` can never fire, the slot stays
    /// occupied for the life of the process, and navigation is dead until the
    /// app is force-quit. That is one of the pilot "app hangs" reports.
    ///
    /// This timer resolves the caller and clears the slot instead.
    private var presentationWatchdog: DispatchWorkItem?

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

    /// Set the language for ALL native speech — route guidance, reaching, and
    /// the AVSpeechSynthesisVoice picked by TTSManager.
    ///
    /// JS calls this at startup and on every Settings change, so native never
    /// has to guess and never falls back to the system locale (which the app
    /// language deliberately overrides).
    @objc(setLanguage:resolver:rejecter:)
    func setLanguage(
        _ code: String,
        resolver resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        let language = AppLanguage(code: code)
        AppLocale.current = language
        NSLog("🌐 [ARKitNavigationModule] Native speech language → \(language.rawValue)")
        resolve(language.rawValue)
    }

    /// Spoken-label vocabulary across every saved route map. The JS layer
    /// grounds ASR targets against this before launching the AR session, so
    /// "serial" resolves to "cereal" instead of dead-ending guidance.
    @objc(availableNavigationTargets:rejecter:)
    func availableNavigationTargets(
        _ resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        resolve(SemanticRouteNavigator.availableTargetVocabulary())
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

            // The route manager is a manual screen. A warm navigation session
            // left mounted would both be stranded by presenting on top of it
            // and make this screen behave as an automated run, so tear it
            // down first — and only look up the presenter afterwards, since
            // the controller being dismissed cannot present anything.
            let teardownNeeded = self.presentedController != nil
            if teardownNeeded {
                self.dismissPresentedController(resolveCancelledNavigation: self.pendingResolve != nil)
            }
            ARKitNavigationSession.shared.end()

            let present = {
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
                    clockFaceDirections: false,
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

            if teardownNeeded {
                // Let the dismissal animation finish before presenting.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: present)
            } else {
                present()
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
                    routeMapId: nil,
                    routeName: nil,
                    targetWorldPosition: nil,
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
                    routeMapId: nil,
                    routeName: nil,
                    targetWorldPosition: nil,
                    message: "No navigation target was provided."
                ).dictionary())
                return
            }

            guard self.pendingResolve == nil else {
                resolve(ARKitNavigationNativeResult(
                    success: false,
                    reason: "error",
                    targetName: targetName,
                    routeMapId: nil,
                    routeName: nil,
                    targetWorldPosition: nil,
                    message: "ARKit navigation is already running."
                ).dictionary())
                return
            }

            guard let presenter = Self.topViewController() else {
                resolve(ARKitNavigationNativeResult(
                    success: false,
                    reason: "error",
                    targetName: targetName,
                    routeMapId: nil,
                    routeName: nil,
                    targetWorldPosition: nil,
                    message: "Could not open ARKit navigation."
                ).dictionary())
                return
            }

            self.pendingResolve = resolve
            self.activeTargetName = targetName
            self.keepSessionAlive = (config["keepSessionAlive"] as? NSNumber)?.boolValue ?? false
            ARKitNavigationSession.shared.begin(target: targetName)

            let routeMapId = config["routeMapId"] as? String
            let routeMapName = config["routeMapName"] as? String
            let speakLandmarks = (config["speakLandmarks"] as? NSNumber)?.boolValue ?? true
            let errorRecovery = (config["errorRecovery"] as? NSNumber)?.boolValue ?? true
            let clockFaceDirections = (config["clockFaceDirections"] as? NSNumber)?.boolValue ?? false
            let voiceOverEnabled = (config["voiceOverEnabled"] as? NSNumber)?.boolValue ?? UIAccessibility.isVoiceOverRunning
            let ttsRate = (config["ttsRate"] as? NSNumber)?.doubleValue

            // Per-session language, so a session launched right after a
            // Settings change cannot race the setLanguage() call.
            if let languageCode = config["language"] as? String {
                AppLocale.current = AppLanguage(code: languageCode)
            }
            // Same reasoning for the spoken distance unit: read it per session
            // rather than trusting whatever a previous one left behind.
            NavigationUnits.current = NavigationDistanceUnit(code: config["distanceUnit"] as? String)

            let host = ARKitRouteHostView(
                launchTargetName: targetName,
                launchRouteMapId: routeMapId,
                launchRouteMapName: routeMapName,
                speakLandmarks: speakLandmarks,
                errorRecovery: errorRecovery,
                clockFaceDirections: clockFaceDirections,
                voiceOverEnabled: voiceOverEnabled,
                ttsRate: ttsRate,
                onDone: { [weak self] in
                    self?.finishNavigation(ARKitNavigationNativeResult(
                        success: false,
                        reason: "cancelled",
                        targetName: targetName,
                        routeMapId: routeMapId,
                        routeName: routeMapName,
                        targetWorldPosition: nil,
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

            // Arm before presenting: if `present` is silently refused (the
            // presenter is already presenting), no callback of ours will ever
            // run and only this timer can free the module.
            self.armPresentationWatchdog(targetName: targetName,
                                         routeMapId: routeMapId,
                                         routeMapName: routeMapName)

            presenter.present(controller, animated: true) { [weak self] in
                // The screen is up and its own callbacks now govern the
                // session's lifetime, which may legitimately last minutes.
                self?.cancelPresentationWatchdog()
            }
        }
    }

    /// Fail the pending launch if the AR screen has not appeared in time.
    private func armPresentationWatchdog(
        targetName: String,
        routeMapId: String?,
        routeMapName: String?
    ) {
        cancelPresentationWatchdog()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.presentationWatchdog != nil else { return }
            self.presentationWatchdog = nil

            // Presented successfully in the meantime? Nothing to do.
            if let controller = self.presentedController,
               controller.viewIfLoaded?.window != nil {
                return
            }

            NSLog("[ARKitNavigationModule] AR screen never appeared — recovering so navigation is not wedged")

            let controller = self.presentedController
            self.presentedController = nil
            controller?.dismiss(animated: false)

            ARKitNavigationSession.shared.end()
            self.keepSessionAlive = false
            self.activeTargetName = nil

            let resolver = self.pendingResolve
            self.pendingResolve = nil
            resolver?(ARKitNavigationNativeResult(
                success: false,
                reason: "error",
                targetName: targetName,
                routeMapId: routeMapId,
                routeName: routeMapName,
                targetWorldPosition: nil,
                message: "Could not open ARKit navigation. Please try again."
            ).dictionary())
        }

        presentationWatchdog = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.presentationWatchdogSeconds,
            execute: work
        )
    }

    private func cancelPresentationWatchdog() {
        presentationWatchdog?.cancel()
        presentationWatchdog = nil
    }

    /// Start the next leg of a journey on the AR screen already on top.
    ///
    /// The whole point is to skip relocalization: the session is still
    /// tracking the loaded world map, so the live pose is known and guidance
    /// can start from where the user actually stands — the exact case that
    /// fails on a cold start when they face against the capture direction.
    /// Falls back to a normal launch when no warm session is mounted.
    @objc(continueNavigation:resolver:rejecter:)
    func continueNavigation(
        _ config: NSDictionary,
        resolver resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        DispatchQueue.main.async {
            let targetName = (config["targetName"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard !targetName.isEmpty else {
                resolve(ARKitNavigationNativeResult(
                    success: false,
                    reason: "target_not_found",
                    targetName: nil,
                    routeMapId: nil,
                    routeName: nil,
                    targetWorldPosition: nil,
                    message: "No navigation target was provided."
                ).dictionary())
                return
            }

            // A still-searching session is retargetable too: continuing its
            // relocalization is strictly better than resetting tracking, even
            // though (unlike a warm arrival) the pose is not yet known.
            let canRetarget = self.presentedController != nil &&
                self.pendingResolve == nil &&
                (ARKitNavigationSession.shared.isWarm || ARKitNavigationSession.shared.isSearching)

            guard canRetarget else {
                // A screen left mounted by a warm arrival that has since lost
                // tracking cannot be retargeted, and presenting on top of it
                // would strand it. Tear it down first, then launch normally.
                if self.presentedController != nil, self.pendingResolve == nil {
                    self.dismissPresentedController(resolveCancelledNavigation: false)
                }
                self.startNavigation(config, resolver: resolve, rejecter: reject)
                return
            }

            if let languageCode = config["language"] as? String {
                AppLocale.current = AppLanguage(code: languageCode)
            }
            NavigationUnits.current = NavigationDistanceUnit(code: config["distanceUnit"] as? String)

            self.pendingResolve = resolve
            self.activeTargetName = targetName
            self.keepSessionAlive = (config["keepSessionAlive"] as? NSNumber)?.boolValue ?? false
            ARKitNavigationSession.shared.retarget(to: targetName)
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
            // The screen reported an outcome, so it clearly came up.
            self.cancelPresentationWatchdog()

            let resolver = self.pendingResolve
            self.pendingResolve = nil
            self.activeTargetName = nil

            // Reaching runs its own AR session and needs the camera, so a
            // handoff arrival must still tear this screen down.
            let arrivedWarm = result.success &&
                result.reason == "arrived" &&
                result.reachingObjectName == nil
            // A relocalization attempt that timed out but is still searching:
            // keeping the screen mounted is the whole point, because tearing
            // it down would reset tracking and make the retry start cold.
            let searchingWarm = result.reason == "relocalization_failed" && result.sessionAlive

            let canStayWarm = self.keepSessionAlive &&
                (arrivedWarm || searchingWarm) &&
                self.presentedController != nil

            if canStayWarm {
                var warmResult = result
                warmResult.sessionAlive = true
                resolver?(warmResult.dictionary())
                return
            }

            ARKitNavigationSession.shared.end()
            let shouldResolveBeforeDismiss = result.success && result.reason == "arrived"

            // Resolve at most once, whichever path gets there first.
            var didResolve = false
            let resolveResult: () -> Void = {
                guard !didResolve else { return }
                didResolve = true
                resolver?(result.dictionary())
            }

            if let controller = self.presentedController {
                self.presentedController = nil
                if shouldResolveBeforeDismiss {
                    resolveResult()
                    controller.dismiss(animated: true)
                } else {
                    controller.dismiss(animated: true, completion: resolveResult)
                    // Backstop: UIKit skips the completion block if this
                    // controller is not the one actually presented (an alert
                    // or the reaching screen got on top, or it was already
                    // dismissed). Without this the resolver is dropped and
                    // the JS turn hangs forever.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        if !didResolve {
                            NSLog("[ARKitNavigationModule] dismiss completion never ran — resolving anyway")
                            resolveResult()
                        }
                    }
                }
            } else {
                resolveResult()
            }
        }
    }

    /// Tear down the AR screen.
    ///
    /// `resolveCancelledNavigation` selects the *reason* reported to a waiting
    /// caller, not whether one is answered at all. A pending resolver is
    /// ALWAYS invoked: this used to drop it on the `false` path, which left
    /// the JS `await ARKitNavigationBridge.startNavigation(...)` waiting on a
    /// promise that could never settle, holding `isProcessingRef` true and
    /// silently swallowing every later tap.
    private func dismissPresentedController(resolveCancelledNavigation: Bool) {
        cancelPresentationWatchdog()

        let resolver = pendingResolve
        let targetName = activeTargetName
        pendingResolve = nil
        activeTargetName = nil
        keepSessionAlive = false
        ARKitNavigationSession.shared.end()

        let result = ARKitNavigationNativeResult(
            success: false,
            reason: resolveCancelledNavigation ? "cancelled" : "superseded",
            targetName: targetName,
            routeMapId: nil,
            routeName: nil,
            targetWorldPosition: nil,
            message: resolveCancelledNavigation
                ? "ARKit navigation cancelled."
                : "ARKit navigation was replaced by a newer request."
        ).dictionary()

        // Resolve at most once, whichever path gets there first.
        var didResolve = false
        let resolveResult: () -> Void = {
            guard !didResolve else { return }
            didResolve = true
            resolver?(result)
        }

        if let controller = presentedController {
            presentedController = nil
            // Resolve from the completion, as before: JS reacts to this result
            // by reclaiming the RN camera, and the AR screen must have finished
            // going away — and released the camera — before that happens.
            controller.dismiss(animated: true, completion: resolveResult)
            // Backstop for the case that made this a hang: UIKit skips the
            // completion entirely when this controller is not the one actually
            // presented, and a skipped completion means the JS turn waits on a
            // promise that can never settle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if !didResolve {
                    NSLog("[ARKitNavigationModule] dismiss completion never ran — resolving anyway")
                    resolveResult()
                }
            }
        } else {
            resolveResult()
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

@objc(OnDeviceLLMModule)
final class OnDeviceLLMModule: NSObject {
    @objc
    static func requiresMainQueueSetup() -> Bool {
        false
    }

    @objc(isAvailable:rejecter:)
    func isAvailable(
        _ resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        resolve(availabilityDictionary())
    }

    @objc(classifyIntent:resolver:rejecter:)
    func classifyIntent(
        _ payload: NSDictionary,
        resolver resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        let text = sanitized(payload["text"] as? String)
        guard !text.isEmpty else {
            resolve(fallbackDictionary(reason: "empty_text"))
            return
        }
        runTask(
            prompt: """
            You classify a blind navigation assistant request. Return strict JSON only:
            {"intent":"navigation|reaching|scene|stop|unknown","target":string|null,"needsImage":boolean,"confidence":number}
            Do not provide navigation distances or turns. User text: \(jsonString(text))
            """,
            fallbackReason: "foundation_models_unavailable",
            resolve: resolve
        )
    }

    @objc(detectTurnEnd:resolver:rejecter:)
    func detectTurnEnd(
        _ payload: NSDictionary,
        resolver resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        let transcript = sanitized(payload["transcript"] as? String)
        guard !transcript.isEmpty else {
            resolve(fallbackDictionary(reason: "empty_transcript"))
            return
        }
        let silenceDurationMs = number(payload["silenceDurationMs"]) ?? 0
        let silenceThresholdMs = number(payload["silenceThresholdMs"]) ?? 1500
        runTask(
            prompt: """
            You are an end-of-utterance detector. Return strict JSON only:
            {"shouldAutoSubmit":boolean,"confidence":number,"reason":string}
            Consider silence >= threshold likely complete unless the transcript is clearly unfinished.
            Input: {"transcript":\(jsonString(transcript)),"silenceDurationMs":\(Int(silenceDurationMs)),"silenceThresholdMs":\(Int(silenceThresholdMs))}
            """,
            fallbackReason: "foundation_models_unavailable",
            resolve: resolve
        )
    }

    @objc(rewriteGuidance:resolver:rejecter:)
    func rewriteGuidance(
        _ payload: NSDictionary,
        resolver resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        let instruction = sanitized(payload["instruction"] as? String)
        let routeStatus = sanitized(payload["routeStatus"] as? String)
        let isInstructionSafe = (payload["isInstructionSafe"] as? NSNumber)?.boolValue ?? false
        guard !instruction.isEmpty else {
            resolve(fallbackDictionary(reason: "empty_instruction"))
            return
        }
        runTask(
            prompt: """
            Rewrite the provided deterministic route instruction for speech. Return strict JSON only:
            {"text":string,"confidence":number}
            Hard rules: do not invent distances, turns, landmarks, objects, hazards, or arrival.
            If isInstructionSafe is false, tell the user to pause and scan slowly.
            Input: {"instruction":\(jsonString(instruction)),"routeStatus":\(jsonString(routeStatus)),"isInstructionSafe":\(isInstructionSafe)}
            """,
            fallbackReason: "foundation_models_unavailable",
            resolve: resolve
        )
    }

    private func runTask(
        prompt: String,
        fallbackReason: String,
        resolve: @escaping RCTPromiseResolveBlock
    ) {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            Task {
                do {
                    let output = try await runFoundationModel(prompt: prompt)
                    let json = extractJSONObject(from: output) ?? output
                    let confidence = parsedConfidence(from: json) ?? 0.72
                    resolve([
                        "available": true,
                        "usedProvider": "apple_foundation_models",
                        "confidence": confidence,
                        "needsBackend": false,
                        "json": json,
                        "rawText": output,
                        "appleFmAvailable": true
                    ])
                } catch {
                    resolve(self.fallbackDictionary(reason: error.localizedDescription))
                }
            }
            return
        }
        #endif
        resolve(fallbackDictionary(reason: fallbackReason))
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func runFoundationModel(prompt: String) async throws -> String {
        let model = SystemLanguageModel.default
        if let reason = foundationModelUnavailableReason(model.availability) {
            throw NSError(
                domain: "OnDeviceLLMModule",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: reason]
            )
        }

        let session = LanguageModelSession(model: model)
        let response = try await session.respond(to: prompt)
        return String(describing: response.content)
    }
    #endif

    private func availabilityDictionary() -> [String: Any] {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let model = SystemLanguageModel.default
            if let reason = foundationModelUnavailableReason(model.availability) {
                return fallbackDictionary(reason: reason)
            } else {
                return [
                    "available": true,
                    "usedProvider": "apple_foundation_models",
                    "confidence": 1,
                    "needsBackend": false,
                    "appleFmAvailable": true
                ]
            }
        }
        return fallbackDictionary(reason: "foundation_models_requires_ios_26")
        #else
        return fallbackDictionary(reason: "foundation_models_framework_not_linked")
        #endif
    }

    private func fallbackDictionary(reason: String) -> [String: Any] {
        [
            "available": false,
            "usedProvider": "none",
            "confidence": 0,
            "needsBackend": true,
            "fallbackReason": reason,
            "appleFmAvailable": false,
            "appleFmUnavailableReason": reason
        ]
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func foundationModelUnavailableReason(
        _ availability: SystemLanguageModel.Availability
    ) -> String? {
        switch availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "foundation_models_device_not_eligible"
            case .appleIntelligenceNotEnabled:
                return "foundation_models_apple_intelligence_not_enabled"
            case .modelNotReady:
                return "foundation_models_model_not_ready"
            @unknown default:
                return "foundation_models_unavailable_unknown"
            }
        @unknown default:
            return "foundation_models_unavailable_unknown"
        }
    }
    #endif

    private func sanitized(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private func jsonString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return encoded
    }

    private func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end else {
            return nil
        }
        return String(text[start...end])
    }

    private func parsedConfidence(from json: String) -> Double? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let value = object["confidence"] as? NSNumber {
            return min(max(value.doubleValue, 0), 1)
        }
        if let value = object["confidence"] as? Double {
            return min(max(value, 0), 1)
        }
        return nil
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
    let clockFaceDirections: Bool
    let voiceOverEnabled: Bool
    let onDone: () -> Void
    let onAutomationComplete: ((ARKitNavigationNativeResult) -> Void)?

    init(
        launchTargetName: String?,
        launchRouteMapId: String?,
        launchRouteMapName: String?,
        speakLandmarks: Bool,
        errorRecovery: Bool,
        clockFaceDirections: Bool = false,
        voiceOverEnabled: Bool = UIAccessibility.isVoiceOverRunning,
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
        self.clockFaceDirections = clockFaceDirections
        self.voiceOverEnabled = voiceOverEnabled
        self.onDone = onDone
        self.onAutomationComplete = onAutomationComplete
    }

    /// Non-nil only for a guidance run, where the exit is the whole screen.
    /// The route manager is a screen of controls and keeps its Done button as
    /// the single way out — a stray tap there must not close it.
    private var guidanceExitHandler: (() -> Void)? {
        launchTargetName == nil ? nil : onDone
    }

    var body: some View {
        NavigationView {
            ARMappingView(
                launchTargetName: launchTargetName,
                launchRouteMapId: launchRouteMapId,
                launchRouteMapName: launchRouteMapName,
                launchSpeakLandmarks: speakLandmarks,
                launchErrorRecovery: errorRecovery,
                launchClockFaceDirections: clockFaceDirections,
                launchVoiceOverEnabled: voiceOverEnabled,
                onAutomationComplete: onAutomationComplete,
                onExitRequested: guidanceExitHandler
            )
            .environmentObject(sensorManager)
            .environmentObject(ttsManager)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    // "Done" alone tells a VoiceOver user nothing about what it
                    // finishes. It is no longer the only way out of a guidance
                    // run — the whole screen is — but it stays as the visible
                    // control a sighted observer expects, and as the route
                    // manager's only exit.
                    Button("Done", action: onDone)
                        .accessibilityLabel(
                            launchTargetName == nil ? "Done" : NavLoc.stopGuidanceButton()
                        )
                        .accessibilityHint(
                            launchTargetName == nil ? "" : NavLoc.stopGuidanceButtonHint()
                        )
                }
            }
        }
        .accentColor(launchTargetName == nil ? Color.accentColor : Color(red: 0.18, green: 0.72, blue: 0.62))
        .navigationViewStyle(.stack)
    }
}
