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

    func testPhoneticSlipStackedOnPluralDriftResolvesToMappedLabel() {
        // "cereals" (spoken) misheard as "serials" carries both a plural 's'
        // the saved singular "Cereal" doesn't have AND the c/s phonetic swap.
        // Either drift alone lands on an earlier cascade rung; stacked
        // together they used to miss every rung.
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.cerealMap()])

        let started = navigator.startNavigation(
            to: "serials",
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

    func testExtraSpokenWordResolvesToMappedLabel() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.loungeMap()])

        let started = navigator.startNavigation(
            to: "400 lounge room",
            arPosition: nil,
            imuState: Self.imu(bearing: 0),
            speakLandmarks: false,
            arHeading: 0
        )

        XCTAssertTrue(started)
        XCTAssertEqual(navigator.targetName, "400 Lounge")
    }

    func testAmbiguousContainmentRefusesToGuessDestination() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.twoLoungeMap()])

        let started = navigator.startNavigation(
            to: "lounge",
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

    // MARK: - Bidirectional map coverage

    /// The old `suffix(120)` cap evicted the forward pass as soon as a reverse
    /// enrichment walk appended its own keyframes, so a two-way map silently
    /// became one-way again. Density pruning must keep both directions.
    func testReverseKeyframesDoNotEvictForwardKeyframes() {
        var keyframes: [SemanticRouteKeyframe] = []
        for index in 0..<140 {
            keyframes.append(Self.keyframe(
                id: "fwd-\(index)",
                x: 0,
                y: Double(index) * 0.7,
                heading: 0
            ))
        }
        for index in 0..<140 {
            keyframes.append(Self.keyframe(
                id: "rev-\(index)",
                x: 0,
                y: Double(139 - index) * 0.7,
                heading: 180
            ))
        }

        let pruned = SemanticRouteNavigator.prunedVisualKeyframes(keyframes)
        let keptIDs = Set(pruned.map(\.id))

        XCTAssertTrue(keptIDs.contains { $0.hasPrefix("fwd-") }, "forward pass was evicted")
        XCTAssertTrue(keptIDs.contains { $0.hasPrefix("rev-") }, "reverse pass was evicted")
        // Same corridor, opposite headings → both survive as distinct evidence.
        XCTAssertGreaterThan(pruned.filter { $0.headingDegrees == 0 }.count, 100)
        XCTAssertGreaterThan(pruned.filter { $0.headingDegrees == 180 }.count, 100)
    }

    /// Repeated passes down the same corridor facing the same way are
    /// redundant; only the newest survives so the map cannot grow without
    /// bound across many enrichment walks.
    func testSameDirectionResamplingCollapsesToNewest() {
        let first = Self.keyframe(id: "old", x: 0, y: 0, heading: 0)
        let second = Self.keyframe(id: "new", x: 0.05, y: 0.05, heading: 5)

        let pruned = SemanticRouteNavigator.prunedVisualKeyframes([first, second])

        XCTAssertEqual(pruned.map(\.id), ["new"])
    }

    /// The reverse leg of a journey: standing at the far destination and
    /// asking for the start must route backwards along the captured edges,
    /// not snap to the original capture start.
    func testReverseDirectionJourneyRoutesBackFromDestination() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.straightMap(coordinateSpace: "pdr_xy")])

        // Standing at Milk (0, 8) — the captured destination — heading back.
        let started = navigator.startNavigation(
            to: "Entrance",
            arPosition: nil,
            imuState: Self.imu(x: 0, y: 8, bearing: 180),
            speakLandmarks: false,
            arHeading: 180
        )

        XCTAssertTrue(started)
        XCTAssertEqual(navigator.phase, .navigating)
        XCTAssertEqual(navigator.routeSteps.first?.from.name, "Milk")
        XCTAssertEqual(navigator.routeSteps.last?.to.name, "Entrance")
        // Already facing the way the reverse route runs: no turn-around cue.
        XCTAssertFalse(navigator.currentInstruction.contains("Turn around"))
    }

    // MARK: - Narrow-aisle stub legs

    func testFacingStubAtDestinationBecomesArrivalFacingNotAWalk() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.igaMap()])

        XCTAssertTrue(navigator.startNavigation(
            to: "Onions",
            arPosition: nil,
            imuState: Self.imu(x: 0, y: 0, bearing: 217),
            speakLandmarks: false,
            arHeading: 217
        ))

        // The 1.0 m hop onto the shelf is a facing, so the last leg walked ends
        // at the turn in the aisle, not at the shelf itself.
        XCTAssertEqual(navigator.routeSteps.last?.to.name, "Left turn 4")
        XCTAssertEqual(navigator.arrivalFacing?.side, .left)
        XCTAssertEqual(navigator.arrivalFacing?.meters ?? 0, 1.0, accuracy: 0.15)
    }

    func testJourneyOpensWithDestinationAndDistanceNotAStubCountdown() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.igaMap()])

        XCTAssertTrue(navigator.startNavigation(
            to: "Onions",
            arPosition: nil,
            imuState: Self.imu(x: 0, y: 0, bearing: 217),
            speakLandmarks: false,
            arHeading: 217
        ))

        XCTAssertTrue(navigator.currentInstruction.contains("Onions is 21 meters away."))
        // The old failure: the whole 22 m route opened on the 1.4 m stub.
        XCTAssertFalse(navigator.currentInstruction.contains("less than one meter"))
    }

    func testCollinearStubLegMergesIntoTheLegItContinues() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.igaMap()])

        XCTAssertTrue(navigator.startNavigation(
            to: "Onions",
            arPosition: nil,
            imuState: Self.imu(x: 0, y: 0, bearing: 217),
            speakLandmarks: false,
            arHeading: 217
        ))

        // Cereals → Straight point 1 → Left turn 2 is one 5.5 m walk, not a
        // 1.4 m leg with a turn cue at the end of it.
        XCTAssertEqual(navigator.routeSteps.first?.from.name, "Cereals")
        XCTAssertEqual(navigator.routeSteps.first?.to.name, "Left turn 2")
        XCTAssertEqual(navigator.routeSteps.first?.edge.distanceMeters ?? 0, 5.5, accuracy: 0.2)
        XCTAssertEqual(navigator.routeSteps.count, 3)
    }

    func testStartingAtAShelfDropsTheHopBackIntoTheAisle() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.igaMap()])

        // Standing at Onions facing the shelf, asking to go back to Cereals.
        XCTAssertTrue(navigator.startNavigation(
            to: "Cereals",
            arPosition: nil,
            imuState: Self.imu(x: -0.93, y: -16.63, bearing: 121),
            speakLandmarks: false,
            arHeading: 121
        ))

        XCTAssertEqual(navigator.routeSteps.first?.from.name, "Left turn 4")
        XCTAssertEqual(navigator.routeSteps.last?.to.name, "Cereals")
        // Facing the shelf, the first thing to do is turn back to the aisle —
        // not walk a metre into it.
        XCTAssertTrue(navigator.currentInstruction.contains("Turn left to face the route."))
        XCTAssertFalse(navigator.currentInstruction.contains("less than one meter"))
    }

    func testArrivalSpeaksWhichWayTheShelfIs() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.igaMap(coordinateSpace: "ar_world_xz")])
        XCTAssertTrue(navigator.startNavigation(
            to: "Onions",
            arPosition: simd_float3(0, 0, 0),
            imuState: Self.imu(bearing: 217),
            speakLandmarks: false,
            arHeading: 217
        ))

        let lastStep = navigator.routeSteps.count - 1
        navigator.setRouteProgressForTesting(
            stepIndex: lastStep,
            progressMeters: navigator.routeSteps[lastStep].edge.distanceMeters
        )
        // Standing on Left turn 4, the last node of the walked route.
        navigator.update(
            imuState: Self.imu(isMoving: true, bearing: 212),
            arPosition: simd_float3(-1.78, 0, 16.11),
            arHeading: 212,
            arLocalized: true
        )

        XCTAssertEqual(navigator.phase, .arrived)
        XCTAssertTrue(navigator.currentInstruction.contains("Arrived at Onions."))
        XCTAssertTrue(navigator.currentInstruction.contains("It is on your left."))
    }

    func testStraightPointIsNeverSpokenAsAPlaceOrATurn() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.igaMap()])
        XCTAssertTrue(navigator.startNavigation(
            to: "Onions",
            arPosition: nil,
            imuState: Self.imu(x: 0, y: 0, bearing: 217),
            speakLandmarks: false,
            arHeading: 217
        ))

        XCTAssertFalse(navigator.currentInstruction.contains("Straight point"))
    }

    func testReturnJourneyMirrorsTurnHintsRecordedOnTheWayOut() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.igaMap()])
        XCTAssertTrue(navigator.startNavigation(
            to: "Cereals",
            arPosition: nil,
            imuState: Self.imu(x: -0.93, y: -16.63, bearing: 32),
            speakLandmarks: false,
            arHeading: 32
        ))

        // "Right turn 3" was labelled walking out from Cereals. Coming back the
        // other way through the same node the user has to turn LEFT — speaking
        // the stored label sends them into the wrong aisle.
        let first = navigator.routeSteps[0]
        XCTAssertEqual(first.to.name, "Right turn 3")
        navigator.setRouteProgressForTesting(stepIndex: 0, progressMeters: first.edge.distanceMeters)
        navigator.update(
            imuState: Self.imu(x: -0.93, y: -16.63, bearing: 32),
            arPosition: nil,
            arHeading: 32,
            arLocalized: false
        )

        XCTAssertEqual(navigator.currentStepIndex, 1)
        XCTAssertTrue(navigator.currentInstruction.hasPrefix("Turn left."))
    }

    /// The July 25 IGA capture: two shelf destinations joined by a zig-zag of
    /// aisles, with a stub leg pinned at each end so arrival can say which way
    /// to face. Distances and bearings are the ones in the saved route report.
    private static func igaMap(coordinateSpace: String = "pdr_xy") -> SemanticRouteMap {
        let cereals = node(id: "cereals", name: "Cereals", point: SemanticRoutePoint(x: 0, y: 0), kind: .destination)
        let straight = node(
            id: "straight1",
            name: "Straight point 1",
            point: SemanticRoutePoint(x: -0.84, y: -1.12),
            kind: .waypoint,
            turnHint: .straight
        )
        let left2 = node(
            id: "left2",
            name: "Left turn 2",
            point: SemanticRoutePoint(x: -3.37, y: -4.35),
            kind: .intersection,
            turnHint: .left
        )
        let right3 = node(
            id: "right3",
            name: "Right turn 3",
            point: SemanticRoutePoint(x: 2.35, y: -9.50),
            kind: .intersection,
            turnHint: .right
        )
        let left4 = node(
            id: "left4",
            name: "Left turn 4",
            point: SemanticRoutePoint(x: -1.78, y: -16.11),
            kind: .intersection,
            turnHint: .left
        )
        let onions = node(id: "onions", name: "Onions", point: SemanticRoutePoint(x: -0.93, y: -16.63), kind: .destination)
        return map(
            id: "iga",
            coordinateSpace: coordinateSpace,
            nodes: [cereals, straight, left2, right3, left4, onions]
        )
    }

    private static func keyframe(
        id: String,
        x: Double,
        y: Double,
        heading: Double
    ) -> SemanticRouteKeyframe {
        SemanticRouteKeyframe(
            id: id,
            segmentID: nil,
            pose: SemanticRoutePoint(x: x, y: y),
            headingDegrees: heading,
            distanceFromSegmentStart: y,
            visualFingerprintId: "fp-\(id)",
            trackingQuality: "ar_world_tracking_visual",
            capturedAt: Date(timeIntervalSince1970: 0)
        )
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

    private static func loungeMap() -> SemanticRouteMap {
        let start = node(id: "start", name: "Entrance", point: SemanticRoutePoint(x: 0, y: 0), kind: .entrance)
        let target = node(id: "lounge", name: "400 Lounge", point: SemanticRoutePoint(x: 0, y: 8), kind: .destination)
        return map(id: "lounge-route", coordinateSpace: "pdr_xy", nodes: [start, target])
    }

    private static func twoLoungeMap() -> SemanticRouteMap {
        let start = node(id: "start", name: "Entrance", point: SemanticRoutePoint(x: 0, y: 0), kind: .entrance)
        let north = node(id: "north", name: "North Lounge", point: SemanticRoutePoint(x: 0, y: 8), kind: .destination)
        let south = node(id: "south", name: "South Lounge", point: SemanticRoutePoint(x: 0, y: 16), kind: .destination)
        return map(id: "two-lounge-route", coordinateSpace: "pdr_xy", nodes: [start, north, south])
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
