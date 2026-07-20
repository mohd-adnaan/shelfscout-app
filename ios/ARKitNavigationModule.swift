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

            let routeMapId = config["routeMapId"] as? String
            let routeMapName = config["routeMapName"] as? String
            let speakLandmarks = (config["speakLandmarks"] as? NSNumber)?.boolValue ?? true
            let errorRecovery = (config["errorRecovery"] as? NSNumber)?.boolValue ?? true
            let clockFaceDirections = (config["clockFaceDirections"] as? NSNumber)?.boolValue ?? false
            let voiceOverEnabled = (config["voiceOverEnabled"] as? NSNumber)?.boolValue ?? UIAccessibility.isVoiceOverRunning
            let ttsRate = (config["ttsRate"] as? NSNumber)?.doubleValue

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
                        routeMapId: nil,
                        routeName: nil,
                        targetWorldPosition: nil,
                        message: "ARKit navigation cancelled."
                    ).dictionary())
                }
            }
        } else if resolveCancelledNavigation {
            resolver?(ARKitNavigationNativeResult(
                success: false,
                reason: "cancelled",
                targetName: targetName,
                routeMapId: nil,
                routeName: nil,
                targetWorldPosition: nil,
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
