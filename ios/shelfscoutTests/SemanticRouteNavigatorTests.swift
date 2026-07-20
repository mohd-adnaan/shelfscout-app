import XCTest
import simd
@testable import shelfscout

@MainActor
final class SemanticRouteNavigatorTests: XCTestCase {
    func testWrongInitialHeadingSpeaksAlignmentBeforeWalking() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.straightMap(coordinateSpace: "pdr_xy")])

        let started = navigator.startNavigation(
            to: "Milk",
            arPosition: nil,
            imuState: Self.imu(bearing: 180),
            speakLandmarks: false,
            arHeading: 180
        )

        XCTAssertTrue(started)
        XCTAssertEqual(navigator.phase, .navigating)
        XCTAssertTrue(navigator.currentInstruction.contains("Turn around to face the route."))
        XCTAssertNotNil(navigator.currentInstruction.range(of: "walk", options: .caseInsensitive))
    }

    func testWrongTurnAtNextSegmentSpeaksCorrectAlignmentCue() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.lTurnMap()])
        XCTAssertTrue(navigator.startNavigation(
            to: "Checkout",
            arPosition: nil,
            imuState: Self.imu(bearing: 0),
            speakLandmarks: false,
            arHeading: 0
        ))
        navigator.setRouteProgressForTesting(stepIndex: 1, progressMeters: 0, markRecentAdvance: true)

        navigator.update(
            imuState: Self.imu(bearing: 0),
            arPosition: nil,
            arHeading: 0,
            arLocalized: false
        )

        XCTAssertEqual(navigator.currentStepIndex, 1)
        XCTAssertEqual(navigator.phase, .navigating)
        XCTAssertEqual(navigator.currentInstruction, "Turn right to face the route.")
    }

    func testHeadingAlignmentCueSuppressedWhenErrorRecoveryDisabled() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.lTurnMap()])
        XCTAssertTrue(navigator.startNavigation(
            to: "Checkout",
            arPosition: nil,
            imuState: Self.imu(bearing: 0),
            speakLandmarks: false,
            errorRecovery: false,
            arHeading: 0
        ))
        navigator.setRouteProgressForTesting(stepIndex: 1, progressMeters: 0, markRecentAdvance: true)

        navigator.update(
            imuState: Self.imu(bearing: 0),
            arPosition: nil,
            arHeading: 0,
            arLocalized: false
        )

        XCTAssertEqual(navigator.phase, .navigating)
        XCTAssertFalse(navigator.currentInstruction.contains("face the route"))
        XCTAssertTrue(navigator.currentInstruction.hasPrefix("Walk"))
    }

    func testBackwardARMovementTriggersWrongDirectionRecovery() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.straightMap(coordinateSpace: "ar_world_xz")])
        XCTAssertTrue(navigator.startNavigation(
            to: "Milk",
            arPosition: simd_float3(0, 0, 0),
            imuState: Self.imu(bearing: 0),
            speakLandmarks: false,
            arHeading: 0
        ))
        navigator.setRouteProgressForTesting(stepIndex: 0, progressMeters: 2.0)
        navigator.expireRecoveryHoldForTesting()

        navigator.update(
            imuState: Self.imu(stepCount: 3, isMoving: true, bearing: 0),
            arPosition: simd_float3(0, 0, 1.0),
            arHeading: 0,
            arLocalized: true
        )

        XCTAssertEqual(navigator.phase, .recovering)
        XCTAssertEqual(navigator.currentInstruction, "Wrong direction.")
        XCTAssertTrue(navigator.recoveryReason?.contains("Backward movement") == true)
    }

    func testRecoveryNeverEnteredWhenErrorRecoveryDisabled() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.straightMap(coordinateSpace: "ar_world_xz")])
        XCTAssertTrue(navigator.startNavigation(
            to: "Milk",
            arPosition: simd_float3(0, 0, 0),
            imuState: Self.imu(bearing: 0),
            speakLandmarks: false,
            errorRecovery: false,
            arHeading: 0
        ))
        navigator.setRouteProgressForTesting(stepIndex: 0, progressMeters: 2.0)
        navigator.expireRecoveryHoldForTesting()

        navigator.update(
            imuState: Self.imu(stepCount: 3, isMoving: true, bearing: 0),
            arPosition: simd_float3(0, 0, 1.0),
            arHeading: 0,
            arLocalized: true
        )

        XCTAssertEqual(navigator.phase, .navigating)
        XCTAssertNotEqual(navigator.currentInstruction, "Wrong direction.")
        XCTAssertNil(navigator.recoveryReason)
    }

    func testMidRouteStartLocalizesToUserPositionNotRouteStart() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.straightMap(coordinateSpace: "ar_world_xz")])

        // Standing 4 m along the 8 m route (route y = -(ARKit z)).
        let started = navigator.startNavigation(
            to: "Milk",
            arPosition: simd_float3(0, 0, -4),
            imuState: Self.imu(bearing: 0),
            speakLandmarks: false,
            arHeading: 0
        )

        XCTAssertTrue(started)
        XCTAssertEqual(navigator.phase, .navigating)
        XCTAssertEqual(navigator.currentStepIndex, 0)
        XCTAssertEqual(navigator.segmentProgressMeters, 4.0, accuracy: 0.05)
        XCTAssertEqual(navigator.segmentRemainingMeters, 4.0, accuracy: 0.05)
    }

    func testSuddenPDRStepJumpDoesNotTeleportToDestination() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.straightMap(coordinateSpace: "pdr_xy")])
        XCTAssertTrue(navigator.startNavigation(
            to: "Milk",
            arPosition: nil,
            imuState: Self.imu(stepCount: 0, bearing: 0),
            speakLandmarks: false,
            arHeading: 0
        ))

        navigator.update(
            imuState: Self.imu(stepCount: 20, isMoving: true, bearing: 0),
            arPosition: nil,
            arHeading: 0,
            arLocalized: false
        )

        XCTAssertEqual(navigator.currentStepIndex, 0)
        XCTAssertEqual(navigator.phase, .navigating)
        XCTAssertLessThanOrEqual(navigator.segmentProgressMeters, 1.21)
        XCTAssertGreaterThan(navigator.segmentRemainingMeters, 6.7)
    }

    func testSuddenPDRPositionJumpDoesNotTeleportToDestination() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.straightMap(coordinateSpace: "pdr_xy")])
        XCTAssertTrue(navigator.startNavigation(
            to: "Milk",
            arPosition: nil,
            imuState: Self.imu(stepCount: 0, x: 0, y: 0, bearing: 0),
            speakLandmarks: false,
            arHeading: 0
        ))

        navigator.update(
            imuState: Self.imu(stepCount: 0, isMoving: true, x: 0, y: 7.5, bearing: 0),
            arPosition: nil,
            arHeading: 0,
            arLocalized: false
        )

        XCTAssertEqual(navigator.currentStepIndex, 0)
        XCTAssertEqual(navigator.phase, .navigating)
        XCTAssertLessThanOrEqual(navigator.segmentProgressMeters, 1.21)
        XCTAssertGreaterThan(navigator.segmentRemainingMeters, 6.7)
    }

    func testMidSegmentLandmarkAnnouncedOnItsOwnSegmentOnly() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.lTurnMapWithSecondSegmentLandmark()])
        XCTAssertTrue(navigator.startNavigation(
            to: "Checkout",
            arPosition: nil,
            imuState: Self.imu(bearing: 0),
            speakLandmarks: true,
            arHeading: 0
        ))

        // Reach the end of segment 1. The Fridge sits on segment 2 (after the
        // turn); the turn announcement must not mention it.
        navigator.setRouteProgressForTesting(stepIndex: 0, progressMeters: 3.5)
        navigator.update(
            imuState: Self.imu(bearing: 0),
            arPosition: nil,
            arHeading: 0,
            arLocalized: false
        )

        XCTAssertEqual(navigator.currentStepIndex, 1, "Should have advanced past the turn")
        XCTAssertFalse(navigator.currentInstruction.localizedCaseInsensitiveContains("Fridge"))

        // Now on segment 2 the landmark should be announced ahead.
        navigator.expireGuidanceIntroProtectionForTesting()
        navigator.update(
            imuState: Self.imu(bearing: 90),
            arPosition: nil,
            arHeading: 90,
            arLocalized: false
        )

        XCTAssertTrue(navigator.speechCue?.text.localizedCaseInsensitiveContains("Fridge") == true)
    }

    func testCornerHintSpeaksCornerNotTurn() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.cornerMap()])
        XCTAssertTrue(navigator.startNavigation(
            to: "Checkout",
            arPosition: nil,
            imuState: Self.imu(bearing: 0),
            speakLandmarks: false,
            arHeading: 0
        ))
        navigator.setRouteProgressForTesting(stepIndex: 0, progressMeters: 3.3)

        navigator.update(
            imuState: Self.imu(bearing: 0),
            arPosition: nil,
            arHeading: 0,
            arLocalized: false
        )

        XCTAssertTrue(navigator.currentInstruction.localizedCaseInsensitiveContains("corner"))
        XCTAssertFalse(navigator.currentInstruction.localizedCaseInsensitiveContains("turn"))
    }

    func testARContradictionBlocksPrematureTurnAdvance() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.lTurnARMap()])
        XCTAssertTrue(navigator.startNavigation(
            to: "Checkout",
            arPosition: simd_float3(0, 0, 0),
            imuState: Self.imu(bearing: 0),
            speakLandmarks: false,
            arHeading: 0
        ))
        // PDR overshoot claims the turn is 0.4m away, but the localized AR
        // pose is still 2.5m from the turn node.
        navigator.setRouteProgressForTesting(stepIndex: 0, progressMeters: 3.6)

        navigator.update(
            imuState: Self.imu(bearing: 0),
            arPosition: simd_float3(2.5, 0, -3.9),
            arHeading: 0,
            arLocalized: true
        )

        XCTAssertEqual(navigator.currentStepIndex, 0, "Turn must not be announced before AR reaches it")
        XCTAssertEqual(navigator.phase, .navigating)
        XCTAssertFalse(navigator.currentInstruction.contains("At the turn"))
    }

    func testARDestinationProximityCompletesRouteDespitePDRLag() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.straightMap(coordinateSpace: "ar_world_xz")])
        XCTAssertTrue(navigator.startNavigation(
            to: "Milk",
            arPosition: simd_float3(0, 0, 0),
            imuState: Self.imu(bearing: 0),
            speakLandmarks: false,
            arHeading: 0
        ))
        // Dead reckoning lags 3m behind while the AR pose stands directly on
        // the destination node. Arrival must complete instead of telling the
        // user to keep walking into a shelf.
        navigator.setRouteProgressForTesting(stepIndex: 0, progressMeters: 5.0)

        navigator.update(
            imuState: Self.imu(bearing: 0),
            arPosition: simd_float3(0, 0, -7.6),
            arHeading: 0,
            arLocalized: true
        )

        XCTAssertEqual(navigator.phase, .arrived)
        XCTAssertTrue(navigator.currentInstruction.contains("Arrived at Milk"))
    }

    // MARK: - Spoken-target fuzzy matching

    func testPhoneticMisrecognitionResolvesToMappedLabel() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.cerealMap()])

        let started = navigator.startNavigation(
            to: "serial",
            arPosition: nil,
            imuState: Self.imu(bearing: 0),
            speakLandmarks: false,
            arHeading: 0
        )

        XCTAssertTrue(started)
        XCTAssertEqual(navigator.targetName, "Cereal")
    }

    func testPluralDriftResolvesToMappedLabel() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.onionsMap()])

        let started = navigator.startNavigation(
            to: "onion",
            arPosition: nil,
            imuState: Self.imu(bearing: 0),
            speakLandmarks: false,
            arHeading: 0
        )

        XCTAssertTrue(started)
        XCTAssertEqual(navigator.targetName, "Onions")
    }

    func testShortLabelsNeverFuzzyMatchDifferentWords() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.straightMap(coordinateSpace: "pdr_xy")])

        let started = navigator.startNavigation(
            to: "silk",
            arPosition: nil,
            imuState: Self.imu(bearing: 0),
            speakLandmarks: false,
            arHeading: 0
        )

        XCTAssertFalse(started)
        XCTAssertTrue(navigator.currentInstruction.contains("not in this semantic map"))
    }

    // MARK: - Instant-arrival gating

    func testFarPoseWithSingleNodePathRefusesInstantArrival() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.straightMap(coordinateSpace: "pdr_xy")])

        // Pose far off the route whose nearest node happens to be the
        // destination: previously this declared "already at Milk" and fired
        // the reaching handoff from across the store.
        let started = navigator.startNavigation(
            to: "Milk",
            arPosition: nil,
            imuState: Self.imu(x: 6, y: 8, bearing: 0),
            speakLandmarks: false,
            arHeading: 0
        )

        XCTAssertFalse(started)
        XCTAssertNotEqual(navigator.phase, .arrived)
        XCTAssertTrue(navigator.currentInstruction.contains("can't confirm"))
    }

    func testNearPoseWithSingleNodePathStillArrives() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.straightMap(coordinateSpace: "pdr_xy")])

        let started = navigator.startNavigation(
            to: "Milk",
            arPosition: nil,
            imuState: Self.imu(x: 0, y: 9.9, bearing: 0),
            speakLandmarks: false,
            arHeading: 0
        )

        XCTAssertTrue(started)
        XCTAssertEqual(navigator.phase, .arrived)
    }

    // MARK: - Clock-face phrasing

    func testClockFaceModeSpeaksHoursInAlignmentCue() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.straightMap(coordinateSpace: "pdr_xy")])

        // Route bearing 0, facing 90 → the route is at the user's 9 o'clock.
        let started = navigator.startNavigation(
            to: "Milk",
            arPosition: nil,
            imuState: Self.imu(bearing: 90),
            speakLandmarks: false,
            clockFaceDirections: true,
            arHeading: 90
        )

        XCTAssertTrue(started)
        XCTAssertTrue(navigator.currentInstruction.contains("9 o'clock"))
    }

    // MARK: - Paused-user cues

    func testStillnessRepromptsFullWalkInstruction() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.straightMap(coordinateSpace: "pdr_xy")])
        XCTAssertTrue(navigator.startNavigation(
            to: "Milk",
            arPosition: nil,
            imuState: Self.imu(bearing: 0),
            speakLandmarks: false,
            arHeading: 0
        ))
        navigator.expireGuidanceIntroProtectionForTesting()
        navigator.update(imuState: Self.imu(bearing: 0), arPosition: nil, arHeading: 0, arLocalized: false)

        navigator.forceStillnessRepromptWindowForTesting()
        navigator.update(imuState: Self.imu(bearing: 0), arPosition: nil, arHeading: 0, arLocalized: false)

        XCTAssertEqual(navigator.speechCue?.text.hasPrefix("Walk"), true)
    }

    func testAlignmentCompletionSpeaksWalkResumeCue() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.straightMap(coordinateSpace: "pdr_xy")])
        XCTAssertTrue(navigator.startNavigation(
            to: "Milk",
            arPosition: nil,
            imuState: Self.imu(bearing: 180),
            speakLandmarks: false,
            arHeading: 180
        ))

        // Facing away from the route → alignment cue arms the resume follow-up.
        navigator.update(imuState: Self.imu(bearing: 180), arPosition: nil, arHeading: 180, arLocalized: false)
        XCTAssertTrue(navigator.currentInstruction.contains("face the route"))

        // Turn completed → explicit walk resumption, not silence.
        navigator.update(imuState: Self.imu(bearing: 0), arPosition: nil, arHeading: 0, arLocalized: false)
        XCTAssertEqual(navigator.speechCue?.text.hasPrefix("Good."), true)
        XCTAssertNotNil(navigator.speechCue?.text.range(of: "walk", options: .caseInsensitive))
    }

    private static func cerealMap() -> SemanticRouteMap {
        let start = node(id: "start", name: "Produce", point: SemanticRoutePoint(x: 0, y: 0), kind: .entrance)
        let target = node(id: "cereal", name: "Cereal", point: SemanticRoutePoint(x: 0, y: 8), kind: .destination)
        return map(id: "cereal-route", coordinateSpace: "pdr_xy", nodes: [start, target])
    }

    private static func onionsMap() -> SemanticRouteMap {
        let start = node(id: "start", name: "Cereal", point: SemanticRoutePoint(x: 0, y: 0), kind: .entrance)
        let target = node(id: "onions", name: "Onions", point: SemanticRoutePoint(x: 0, y: 8), kind: .destination)
        return map(id: "onions-route", coordinateSpace: "pdr_xy", nodes: [start, target])
    }

    private static func straightMap(coordinateSpace: String) -> SemanticRouteMap {
        let start = node(id: "start", name: "Entrance", point: SemanticRoutePoint(x: 0, y: 0), kind: .entrance)
        let target = node(id: "milk", name: "Milk", point: SemanticRoutePoint(x: 0, y: 8), kind: .destination)
        return map(id: "straight", coordinateSpace: coordinateSpace, nodes: [start, target])
    }

    private static func lTurnMap() -> SemanticRouteMap {
        let start = node(id: "start", name: "Entrance", point: SemanticRoutePoint(x: 0, y: 0), kind: .entrance)
        let turn = node(id: "turn", name: "Corner", point: SemanticRoutePoint(x: 0, y: 4), kind: .intersection, turnHint: .right)
        let target = node(id: "checkout", name: "Checkout", point: SemanticRoutePoint(x: 4, y: 4), kind: .destination)
        return map(id: "l-turn", coordinateSpace: "pdr_xy", nodes: [start, turn, target])
    }

    private static func lTurnARMap() -> SemanticRouteMap {
        let start = node(id: "start", name: "Entrance", point: SemanticRoutePoint(x: 0, y: 0), kind: .entrance)
        let turn = node(id: "turn", name: "Turn", point: SemanticRoutePoint(x: 0, y: 4), kind: .intersection, turnHint: .right)
        let target = node(id: "checkout", name: "Checkout", point: SemanticRoutePoint(x: 4, y: 4), kind: .destination)
        return map(id: "l-turn-ar", coordinateSpace: "ar_world_xz", nodes: [start, turn, target])
    }

    private static func cornerMap() -> SemanticRouteMap {
        let start = node(id: "start", name: "Entrance", point: SemanticRoutePoint(x: 0, y: 0), kind: .entrance)
        let corner = node(id: "corner", name: "Right corner 1", point: SemanticRoutePoint(x: 0, y: 4), kind: .intersection, turnHint: .cornerRight)
        let target = node(id: "checkout", name: "Checkout", point: SemanticRoutePoint(x: 4, y: 4), kind: .destination)
        return map(id: "corner", coordinateSpace: "pdr_xy", nodes: [start, corner, target])
    }

    private static func lTurnMapWithSecondSegmentLandmark() -> SemanticRouteMap {
        let start = node(id: "start", name: "Entrance", point: SemanticRoutePoint(x: 0, y: 0), kind: .entrance)
        let turn = node(id: "turn", name: "Turn", point: SemanticRoutePoint(x: 0, y: 4), kind: .intersection, turnHint: .right)
        let target = node(id: "checkout", name: "Checkout", point: SemanticRoutePoint(x: 4, y: 4), kind: .destination)
        // Mapped mid-segment between the two turns: anchored to the turn node
        // that starts segment 2 and assigned to segment 2's edge.
        let fridge = SemanticRouteLandmark(
            id: "lm-fridge",
            name: "Fridge",
            aliases: [],
            nodeID: turn.id,
            edgeID: "\(turn.id)__\(target.id)",
            offsetMeters: 1.0,
            side: .left,
            context: nil,
            priority: 10,
            kind: .object,
            visualFingerprintIds: nil
        )
        return map(id: "l-turn-landmark", coordinateSpace: "pdr_xy", nodes: [start, turn, target], landmarks: [fridge])
    }

    private static func map(id: String, coordinateSpace: String, nodes: [SemanticRouteNode], landmarks: [SemanticRouteLandmark] = []) -> SemanticRouteMap {
        var edges: [SemanticRouteEdge] = []
        for index in 0..<(nodes.count - 1) {
            edges.append(edge(from: nodes[index], to: nodes[index + 1]))
        }
        return SemanticRouteMap(
            id: id,
            name: id,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            coordinateSpace: coordinateSpace,
            arWorldMapId: nil,
            startNodeId: nodes.first?.id,
            destinationNodeIds: nodes.filter { $0.kind == .destination }.map(\.id),
            nodes: nodes,
            edges: edges,
            landmarks: landmarks,
            keyframes: nil,
            source: "test",
            notes: nil
        )
    }

    private static func node(
        id: String,
        name: String,
        point: SemanticRoutePoint,
        kind: SemanticRouteNodeKind,
        turnHint: SemanticTurnHint? = nil
    ) -> SemanticRouteNode {
        SemanticRouteNode(
            id: id,
            name: name,
            point: point,
            headingDegrees: nil,
            kind: kind,
            turnHint: turnHint,
            aliases: [],
            capturedAt: Date(timeIntervalSince1970: 0),
            poiAnchorId: nil
        )
    }

    private static func edge(from: SemanticRouteNode, to: SemanticRouteNode) -> SemanticRouteEdge {
        SemanticRouteEdge(
            id: "\(from.id)__\(to.id)",
            fromNodeID: from.id,
            toNodeID: to.id,
            distanceMeters: from.point.distance(to: to.point),
            bearingDegrees: from.point.bearingDegrees(to: to.point),
            reverseBearingDegrees: to.point.bearingDegrees(to: from.point),
            walkableWidthMeters: 1.2,
            leftContext: nil,
            rightContext: nil,
            spokenContext: nil,
            isBidirectional: true,
            confidence: 1,
            keyframeIds: nil,
            landmarkIds: nil
        )
    }

    private static func imu(
        stepCount: Int = 0,
        isMoving: Bool = false,
        x: Double = 0,
        y: Double = 0,
        bearing: Double
    ) -> IMUState {
        IMUState(
            position: Position(x: x, y: y, bearing: bearing),
            stepCount: stepCount,
            isCalibrated: true,
            isMoving: isMoving,
            currentStepLength: 0.65,
            isStepCalibrationValid: true,
            bearing: bearing,
            headingReliability: 0.9,
            pdrUncertaintyMeters: 0.45
        )
    }
}
