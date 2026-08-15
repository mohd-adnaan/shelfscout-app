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
        // One-leg route: the distance is stated once, the leg contributes the
        // direction.
        XCTAssertTrue(navigator.currentInstruction.contains("Milk is 8 meters away."))
        XCTAssertTrue(navigator.currentInstruction.contains("toward milk."))
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
        XCTAssertTrue(navigator.currentInstruction.hasPrefix("4 meters,"))
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

    func testDoublingBackCorridorDoesNotRouteUserBackwards() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.doublingBackMap()])

        // Just short of Junction and already facing the Elevators leg. The
        // Corner→Printer edge runs 0.15 m away while Junction's own leg is
        // 0.60 m away, so nearest-edge alone snapped to the spur and routed the
        // user down to Printer and back — 11.9 m instead of 5.2 m.
        let started = navigator.startNavigation(
            to: "Elevators",
            arPosition: simd_float3(0.15, 0, 6.4),
            imuState: Self.imu(bearing: 270),
            speakLandmarks: false,
            arHeading: 270
        )

        XCTAssertTrue(started)
        XCTAssertEqual(navigator.phase, .navigating)
        XCTAssertEqual(
            navigator.totalRemainingMeters, 5.15, accuracy: 0.4,
            "Should walk straight to Elevators, not back down the spur"
        )
        XCTAssertLessThan(
            navigator.totalRemainingMeters, 8.0,
            "Routing back through Printer costs ~12 m and passes a POI already behind the user"
        )
    }

    func testFrameRealignmentDisarmsHeadingGate() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.lTurnARMap()])
        navigator.armHeadingGateForTesting()
        XCTAssertTrue(navigator.headingGateArmedForTesting)

        navigator.noteARFrameRealigned()

        XCTAssertFalse(
            navigator.headingGateArmedForTesting,
            "Discarding the frame bias discards the match that earned the gate; left armed it filters keyframes against a heading known to be uncorrected, so the bias can never be re-measured"
        )
    }

    func testOverlappingCorridorIsCountedInCaptureQuality() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.doublingBackMap()])

        // Junction vs the Corner→Printer edge: 0.3 m apart, headings 90° apart.
        XCTAssertEqual(navigator.activeMap?.captureQuality?.overlappingCorridorCount, 1)
        XCTAssertTrue(
            navigator.activeMap?.captureQuality?.warnings.contains { $0.contains("twice heading different ways") } ?? false,
            "An overlapping corridor should warn the mapper"
        )
    }

    func testStraightRouteReportsNoCorridorOverlap() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.lTurnMap()])

        XCTAssertEqual(navigator.activeMap?.captureQuality?.overlappingCorridorCount, 0)
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
        // At the turn the cue is the bare command; 2.5 m out it must still be
        // the pre-announcement that carries a distance.
        XCTAssertNotEqual(navigator.currentInstruction, "Turn right.")
        XCTAssertTrue(navigator.currentInstruction.contains("Turn right in "))
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

    /// Clock-face phrasing renames the cue every 30°, so a user swaying while
    /// walking used to be spoken to on every rename. Neighbouring hours are one
    /// correction; two hours apart is genuinely new.
    func testNeighbouringClockHoursAreOneCorrectionNotTwo() {
        XCTAssertTrue(SemanticRouteNavigator.isSameSpokenCorrection("align_clock_2_0", as: "align_clock_3_0"))
        XCTAssertTrue(SemanticRouteNavigator.isSameSpokenCorrection("off_route_clock_12", as: "off_route_clock_1"))
        XCTAssertFalse(SemanticRouteNavigator.isSameSpokenCorrection("align_clock_2_0", as: "align_clock_4_0"))
        // A left/right flip is never the same correction, however close the
        // hours look numerically.
        XCTAssertFalse(SemanticRouteNavigator.isSameSpokenCorrection("align_clock_11_0", as: "align_clock_1_0"))
        // Same hour on a different leg, or from a different subsystem, is a
        // different cue — the hour is only compared when everything else matches.
        XCTAssertFalse(SemanticRouteNavigator.isSameSpokenCorrection("align_clock_2_1", as: "align_clock_2_0"))
        XCTAssertFalse(SemanticRouteNavigator.isSameSpokenCorrection("off_route_clock_2", as: "align_clock_2"))
        // Left/right keys keep the old exact-match behaviour.
        XCTAssertTrue(SemanticRouteNavigator.isSameSpokenCorrection("align_left_0", as: "align_left_0"))
        XCTAssertFalse(SemanticRouteNavigator.isSameSpokenCorrection("align_left_0", as: "align_right_0"))
        XCTAssertFalse(SemanticRouteNavigator.isSameSpokenCorrection("align_left_0", as: nil))
    }

    // MARK: - Course correction (aisle centring)

    /// The pilot bump: walking straight down the aisle but drifting toward the
    /// right-hand shelf. Cross-track recovery does not arm this early, so
    /// before the course cue existed the user heard nothing until contact.
    func testDriftTowardTheShelfIsNudgedBackBeforeRecoveryArms() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.straightMap(coordinateSpace: "ar_world_xz")])
        XCTAssertTrue(navigator.startNavigation(
            to: "Milk",
            arPosition: simd_float3(0, 0, 0),
            imuState: Self.imu(bearing: 0),
            speakLandmarks: false,
            clockFaceDirections: true,
            arHeading: 10
        ))
        navigator.expireGuidanceIntroProtectionForTesting()

        // Three metres along, 0.7 m right of the centre line and angled 10°
        // further right — Henrique's line. Well under the 1.05 m cross-track
        // limit and the 55° alignment threshold, so nothing else speaks.
        let pose = simd_float3(0.7, 0, -3.0)
        let walking = Self.imu(isMoving: true, x: 0, y: 3.0, bearing: 10)
        navigator.update(imuState: walking, arPosition: pose, arHeading: 10, arLocalized: true)
        XCTAssertNotEqual(navigator.phase, .recovering)

        // A drift has to persist before it is spoken; one tick is not a course.
        XCTAssertTrue(navigator.expireCourseCorrectionHoldForTesting())
        navigator.update(imuState: walking, arPosition: pose, arHeading: 10, arLocalized: true)

        XCTAssertEqual(navigator.speechCue?.text, "Ease to 11 o'clock.")
        XCTAssertEqual(navigator.phase, .navigating)
    }

    func testCentredWalkerIsLeftAlone() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.straightMap(coordinateSpace: "ar_world_xz")])
        XCTAssertTrue(navigator.startNavigation(
            to: "Milk",
            arPosition: simd_float3(0, 0, 0),
            imuState: Self.imu(bearing: 0),
            speakLandmarks: false,
            clockFaceDirections: true,
            arHeading: 0
        ))
        navigator.expireGuidanceIntroProtectionForTesting()

        // A third of a metre off centre and facing straight: inside every aisle
        // this app maps, and nothing worth speaking about.
        let walking = Self.imu(isMoving: true, x: 0, y: 3.0, bearing: 0)
        navigator.update(
            imuState: walking,
            arPosition: simd_float3(0.35, 0, -3.0),
            arHeading: 0,
            arLocalized: true
        )
        XCTAssertFalse(navigator.expireCourseCorrectionHoldForTesting())
    }

    /// Same geometry, left/right phrasing: the correction must read as a small
    /// adjustment, not as the "turn left" that walks someone into the far shelf.
    func testCourseCorrectionSpeaksASlightBearWithoutClockFace() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.straightMap(coordinateSpace: "ar_world_xz")])
        XCTAssertTrue(navigator.startNavigation(
            to: "Milk",
            arPosition: simd_float3(0, 0, 0),
            imuState: Self.imu(bearing: 0),
            speakLandmarks: false,
            arHeading: 10
        ))
        navigator.expireGuidanceIntroProtectionForTesting()

        let pose = simd_float3(0.7, 0, -3.0)
        let walking = Self.imu(isMoving: true, x: 0, y: 3.0, bearing: 10)
        navigator.update(imuState: walking, arPosition: pose, arHeading: 10, arLocalized: true)
        XCTAssertTrue(navigator.expireCourseCorrectionHoldForTesting())
        navigator.update(imuState: walking, arPosition: pose, arHeading: 10, arLocalized: true)

        XCTAssertEqual(navigator.speechCue?.text, "Bear slightly left.")
    }

    /// Turn-by-turn-only is a study condition: with error recovery off the user
    /// asked for no corrective interjections at all.
    func testCourseCorrectionSilentWhenErrorRecoveryDisabled() {
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
        navigator.expireGuidanceIntroProtectionForTesting()

        let walking = Self.imu(isMoving: true, x: 0, y: 3.0, bearing: 10)
        navigator.update(
            imuState: walking,
            arPosition: simd_float3(0.7, 0, -3.0),
            arHeading: 10,
            arLocalized: true
        )
        XCTAssertFalse(navigator.expireCourseCorrectionHoldForTesting())
    }

    // MARK: - Distance unit

    func testStepsUnitSpeaksRouteDistancesAsSteps() {
        NavigationUnits.current = .steps
        defer { NavigationUnits.current = .meters }

        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.straightMap(coordinateSpace: "pdr_xy")])
        XCTAssertTrue(navigator.startNavigation(
            to: "Milk",
            arPosition: nil,
            imuState: Self.imu(bearing: 0),
            speakLandmarks: false,
            arHeading: 0
        ))

        // 8 m at 0.65 m per step is 12 steps — under the rounding threshold, so
        // it is spoken exactly.
        XCTAssertTrue(navigator.currentInstruction.contains("12 steps"))
        XCTAssertFalse(navigator.currentInstruction.contains("meters"))
    }

    func testMetersRemainTheDefaultUnit() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.straightMap(coordinateSpace: "pdr_xy")])
        XCTAssertTrue(navigator.startNavigation(
            to: "Milk",
            arPosition: nil,
            imuState: Self.imu(bearing: 0),
            speakLandmarks: false,
            arHeading: 0
        ))
        XCTAssertTrue(navigator.currentInstruction.contains("8 meters"))
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

        XCTAssertEqual(navigator.speechCue?.text.hasPrefix("8 meters,"), true)
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
        XCTAssertNotNil(navigator.speechCue?.text.range(of: "8 meters,"))
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
        // The dropped stub must not move where the user is judged to be.
        XCTAssertEqual(navigator.spokenStartLabel, "Onions")
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
        XCTAssertEqual(navigator.currentInstruction, "Arrived at Onions, on your left.")
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

    func testPoseCorrectionRealignsTheRouteInsteadOfRestartingIt() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.igaMap(coordinateSpace: "ar_world_xz")])
        XCTAssertTrue(navigator.startNavigation(
            to: "Onions",
            arPosition: simd_float3(0, 0, 0),
            imuState: Self.imu(bearing: 218),
            speakLandmarks: false,
            arHeading: 218
        ))
        XCTAssertTrue(navigator.currentInstruction.hasPrefix("Onions is"))

        // ARKit finishes aligning to the saved map: the user was really 8 m
        // along, not at the route start.
        navigator.speechCue = nil
        XCTAssertTrue(navigator.realignRouteToCorrectedPose(
            arPosition: simd_float3(-3.37, 0, 4.35),
            imuState: Self.imu(bearing: 132),
            heading: 132
        ))

        // One correction cue, not a fresh journey announcement — restarting
        // re-resolves the start edge and can speak a different turn each time.
        XCTAssertFalse(navigator.currentInstruction.hasPrefix("Onions is"))
        XCTAssertEqual(navigator.speechCue?.text, navigator.currentInstruction)
        // Re-resolved from where they actually are, not from the route start.
        XCTAssertNotEqual(navigator.routeSteps.first?.from.name, "Cereals")

        // ARKit keeps nudging the pose; that must not re-resolve the route
        // again while the user is acting on the cue they just heard.
        navigator.speechCue = nil
        XCTAssertFalse(navigator.realignRouteToCorrectedPose(
            arPosition: simd_float3(-3.37, 0, 4.35),
            imuState: Self.imu(bearing: 132),
            heading: 132
        ))
        XCTAssertNil(navigator.speechCue)
    }

    func testStraightPointMergesOnCollinearityNotLength() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.narrowAisleStartMap()])

        XCTAssertTrue(navigator.startNavigation(
            to: "Onions",
            arPosition: nil,
            imuState: Self.imu(x: 0, y: 0, bearing: 233),
            speakLandmarks: false,
            arHeading: 233
        ))

        // The straight point sits 1.6 m in — longer than any stub threshold,
        // and still not a decision point. Re-capturing the same aisle moves
        // that number around, so the rule cannot depend on it.
        XCTAssertEqual(navigator.routeSteps.count, 2)
        XCTAssertEqual(navigator.routeSteps.first?.to.name, "Left turn 2")
        XCTAssertEqual(navigator.routeSteps.first?.edge.distanceMeters ?? 0, 5.6, accuracy: 0.1)
    }

    func testTurningUserIsNotBuriedInContradictoryAlignmentCues() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.igaMap()])

        // Standing at Cereals facing the shelf: the route runs behind them.
        XCTAssertTrue(navigator.startNavigation(
            to: "Onions",
            arPosition: nil,
            imuState: Self.imu(x: 0, y: 0, bearing: 51),
            speakLandmarks: false,
            arHeading: 51
        ))
        XCTAssertTrue(navigator.currentInstruction.contains("face the route"))

        navigator.speechCue = nil
        navigator.update(
            imuState: Self.imu(x: 0, y: 0, bearing: 51),
            arPosition: nil,
            arHeading: 51,
            arLocalized: false
        )
        XCTAssertNil(navigator.speechCue, "the opening cue must not be spoken again a tick later")

        // Part-way round the turn the band changes from "turn around" to
        // "turn sharp left". Announcing that crossing is what stacked three
        // contradicting instructions on top of each other in the store.
        navigator.update(
            imuState: Self.imu(x: 0, y: 0, bearing: 120),
            arPosition: nil,
            arHeading: 120,
            arLocalized: false
        )
        XCTAssertNil(navigator.speechCue, "a user already turning must not be re-cued")
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

    /// Walking is not evidence of being lost.
    ///
    /// Route evidence used to be bucketed by the progress it had when it was
    /// captured, so a walking user's own trail spread across several buckets
    /// and the ones far enough apart registered as rival claims about where
    /// they were. At normal pace the status sat on "ambiguous" for the whole
    /// leg, which put guidance into the belief hold ("Hold on. Pan the phone
    /// slowly." / "Route lost.") and swallowed the turn cue at the end of it.
    /// AR and PDR agreeing perfectly, on the mapped IGA route, must read as
    /// locked the whole way down the leg.
    func testWalkingALegDoesNotMakeTheUsersOwnTrailARivalPosition() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.igaMap(coordinateSpace: "ar_world_xz")])
        XCTAssertTrue(navigator.startNavigation(
            to: "Onions",
            arPosition: simd_float3(0, 0, 0),
            imuState: Self.imu(bearing: 218),
            speakLandmarks: false,
            arHeading: 218
        ))

        let leg = navigator.routeSteps[0]
        XCTAssertEqual(leg.to.name, "Left turn 2")
        let bearing = leg.edge.bearingDegrees
        let radians = bearing * .pi / 180
        // Stop short of the leg end so the assertion reads the belief while
        // walking, not the reset that a step advance performs.
        let stride = 0.275
        let ticks = 14

        for tick in 1...ticks {
            let travelled = Double(tick) * stride
            let x = sin(radians) * travelled
            let y = cos(radians) * travelled
            navigator.update(
                imuState: Self.imu(isMoving: true, x: x, y: y, bearing: bearing),
                arPosition: simd_float3(Float(x), 0, Float(-y)),
                arHeading: bearing,
                arLocalized: true
            )
        }

        XCTAssertEqual(navigator.routeLocalizationStatus, .locked)
        XCTAssertEqual(navigator.lastObservation?.isInstructionSafe, true)
        XCTAssertEqual(navigator.phase, .navigating)
        XCTAssertFalse(navigator.currentInstruction.contains("Pan the phone"))
        XCTAssertFalse(navigator.currentInstruction.contains("Route lost"))
    }

    /// A localized AR pose standing on the turn node is direct evidence, and
    /// must be acted on before any corrective nudge claims the tick. The
    /// alignment cue used to run first and return, so a user who had already
    /// started turning was told to face the leg they had just finished instead
    /// of being given the turn.
    func testPoseOnTheTurnNodeGivesTheTurnRatherThanANudgeBackToTheOldLeg() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.lTurnARMap()])
        XCTAssertTrue(navigator.startNavigation(
            to: "Checkout",
            arPosition: simd_float3(0, 0, 0),
            imuState: Self.imu(bearing: 0),
            speakLandmarks: false,
            arHeading: 0
        ))
        navigator.setRouteProgressForTesting(stepIndex: 0, progressMeters: 3.2, markRecentAdvance: true)

        // Standing on the turn node, already swung onto the next leg's bearing
        // — 90° off the leg being walked, inside the alignment cue's window.
        navigator.update(
            imuState: Self.imu(isMoving: true, bearing: 90),
            arPosition: simd_float3(0, 0, -3.9),
            arHeading: 90,
            arLocalized: true
        )

        XCTAssertEqual(navigator.currentStepIndex, 1)
        XCTAssertTrue(
            navigator.currentInstruction.hasPrefix("Turn right."),
            "expected the turn, got: \(navigator.currentInstruction)"
        )
    }

    /// One saved image is one place. Every step is offered every keyframe, so
    /// the images either side of a turn node were claimed by both the step
    /// ending there and the step starting there. The duplicates scored
    /// identically against the live frame, the ambiguity guard saw a tie
    /// across two step indices, and the match was thrown away — silencing
    /// visual matching at exactly the decision points it exists to confirm.
    func testKeyframesAtATurnNodeAreNotClaimedByTwoStepsAtOnce() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.lTurnMapWithKeyframesAtTheTurn()])
        XCTAssertTrue(navigator.startNavigation(
            to: "Checkout",
            arPosition: simd_float3(0, 0, 0),
            imuState: Self.imu(bearing: 0),
            speakLandmarks: false,
            arHeading: 0
        ))

        let attribution = navigator.visualCandidateAttributionForTesting()
        XCTAssertFalse(attribution.isEmpty, "keyframes near the turn produced no candidates")
        let ids = attribution.map { $0.fingerprintID }
        XCTAssertEqual(
            ids.count,
            Set(ids).count,
            "a fingerprint was offered to more than one step: \(attribution)"
        )
    }

    /// The metre either side of a turn node is one place. Two legs that merely
    /// run close together are not.
    func testTurnNodeStraddleIsOnePlaceButParallelLegsAreNot() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.lTurnARMap()])
        XCTAssertTrue(navigator.startNavigation(
            to: "Checkout",
            arPosition: simd_float3(0, 0, 0),
            imuState: Self.imu(bearing: 0),
            speakLandmarks: false,
            arHeading: 0
        ))

        // End of leg 1 and start of leg 2 are the same node.
        XCTAssertTrue(navigator.isSameRoutePlace(
            stepIndex: 0,
            progressMeters: 4.0,
            otherStepIndex: 1,
            otherProgressMeters: 0.0
        ))
        // Opposite ends of the L are 4 m apart and stay a real ambiguity.
        XCTAssertFalse(navigator.isSameRoutePlace(
            stepIndex: 0,
            progressMeters: 0.0,
            otherStepIndex: 1,
            otherProgressMeters: 4.0
        ))
    }

    // MARK: - Heading-settle gate

    func testOpeningCueSkipsTurnCommandWhileHeadingStillSweeping() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.straightMap(coordinateSpace: "pdr_xy")])

        // The relocalization pan: three headings sweeping 160° within the
        // settle window, right before guidance starts.
        for heading in [40.0, 120.0, 200.0] {
            navigator.update(
                imuState: Self.imu(bearing: heading),
                arPosition: nil,
                arHeading: heading,
                arLocalized: false
            )
        }

        XCTAssertTrue(navigator.startNavigation(
            to: "Milk",
            arPosition: nil,
            imuState: Self.imu(bearing: 180),
            speakLandmarks: false,
            arHeading: 180
        ))
        // The 180 reading is one instant of the sweep, not a facing: the
        // opening announcement must not command a turn from it.
        XCTAssertFalse(navigator.currentInstruction.contains("Turn around"))
        XCTAssertTrue(navigator.currentInstruction.contains("Milk is 8 meters away."))
        XCTAssertTrue(navigator.currentInstruction.contains("Toward Milk."))

        // Once the user settles still facing the wrong way, the cue is owed —
        // and now it is computed from a heading they actually hold.
        navigator.settleHeadingForTesting()
        navigator.update(
            imuState: Self.imu(bearing: 180),
            arPosition: nil,
            arHeading: 180,
            arLocalized: false
        )
        XCTAssertTrue(navigator.currentInstruction.contains("Turn around to face the route."))
    }

    // MARK: - Dropped leading stub facing

    func testReverseStartFacingTheDroppedStubHearsNoTurnCommand() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.reverseStubMap()])

        // Standing at Onions, already turned around to face Left turn 1 —
        // the direction the return walk physically starts in (318°).
        XCTAssertTrue(navigator.startNavigation(
            to: "Spices",
            arPosition: nil,
            imuState: Self.imu(x: 0.736, y: -0.817, bearing: 318),
            speakLandmarks: false,
            arHeading: 318
        ))

        // The stub was dropped and the first leg bears 23° — 65° off. That
        // turn happens AT the stub's far end; commanding it now told a
        // correctly-facing user to turn into the shelf.
        XCTAssertEqual(navigator.spokenStartLabel, "Onions")
        XCTAssertFalse(navigator.currentInstruction.contains("face the route"))

        navigator.update(
            imuState: Self.imu(x: 0.736, y: -0.817, bearing: 318),
            arPosition: nil,
            arHeading: 318,
            arLocalized: false
        )
        XCTAssertFalse(navigator.currentInstruction.contains("face the route"))
    }

    // MARK: - Re-capture node reuse

    func testReturnCaptureReusesExistingNodesInsteadOfDuplicating() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.igaMap()], activeMapID: "iga")
        XCTAssertTrue(navigator.beginRouteCaptureAppending(toMapID: "iga"))
        let nodesBefore = navigator.activeMap?.nodes.count ?? 0
        let edgesBefore = navigator.activeMap?.edges.count ?? 0

        // The return walk starts by re-marking the destination shelf…
        XCTAssertTrue(navigator.captureStart(
            named: "Onions",
            arPosition: nil,
            arHeading: 138,
            imuState: Self.imu(x: -0.90, y: -16.60, bearing: 138)
        ))
        // …and re-marks the aisle turn a step away from mapped "Left turn 4".
        XCTAssertTrue(navigator.captureTurn(
            .right,
            arPosition: nil,
            arHeading: 23,
            imuState: Self.imu(x: -1.70, y: -16.20, bearing: 23)
        ))

        // Same places, same graph: no duplicate chain, no parallel edges.
        XCTAssertEqual(navigator.activeMap?.nodes.count, nodesBefore)
        XCTAssertEqual(navigator.activeMap?.edges.count, edgesBefore)
        XCTAssertTrue(navigator.activeMap?.nodes.contains(where: { $0.name == "Left turn 4" }) ?? false)
    }

    // MARK: - Endpoint anchoring persistence

    func testAnchoredEndpointIsNotRepromptedInLaterCaptureSession() {
        var saved = Self.igaMap(coordinateSpace: "ar_world_xz")
        saved.anchoredNodeIds = ["onions"]
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([saved], activeMapID: "iga")
        XCTAssertTrue(navigator.beginRouteCaptureAppending(toMapID: "iga"))

        // Standing at Onions, whose 360° sweep a previous session banked.
        navigator.update(
            imuState: Self.imu(x: -0.93, y: -16.63, bearing: 90),
            arPosition: simd_float3(-0.93, 0, 16.63),
            arHeading: 90,
            arLocalized: true
        )
        XCTAssertFalse(navigator.currentInstruction.contains("full circle"))

        // Control: an endpoint never anchored still asks for its sweep.
        navigator.update(
            imuState: Self.imu(bearing: 90),
            arPosition: simd_float3(0, 0, 0),
            arHeading: 90,
            arLocalized: true
        )
        XCTAssertTrue(navigator.currentInstruction.contains("full circle"))
    }

    // MARK: - Route overlay polyline

    func testRemainingRoutePolylineEndsAtDestination() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.lTurnARMap()])
        XCTAssertTrue(navigator.startNavigation(
            to: "Checkout",
            arPosition: simd_float3(0, 0, 0),
            imuState: Self.imu(bearing: 0),
            speakLandmarks: false,
            arHeading: 0
        ))

        let polyline = navigator.remainingRoutePolyline()
        XCTAssertGreaterThanOrEqual(polyline.count, 3)
        XCTAssertEqual(polyline.last?.x ?? -1, 4, accuracy: 0.01)
        XCTAssertEqual(polyline.last?.y ?? -1, 4, accuracy: 0.01)
    }

    /// The reverse of a narrow-aisle capture: Spices ──7 m at 23°── Left turn 1
    /// ──1.1 m at 138°── Onions. Walked back from Onions the 1.1 m hop is a
    /// leading stub bearing 318°, and the leg it drops onto bears 23° — the
    /// 65° disagreement that made guidance command a turn at a user already
    /// facing the way.
    private static func reverseStubMap() -> SemanticRouteMap {
        let spices = node(id: "spices", name: "Spices", point: SemanticRoutePoint(x: 2.735, y: 6.444), kind: .entrance)
        let turn = node(
            id: "turn1",
            name: "Left turn 1",
            point: SemanticRoutePoint(x: 0, y: 0),
            kind: .intersection,
            turnHint: .left
        )
        let onions = node(id: "onions", name: "Onions", point: SemanticRoutePoint(x: 0.736, y: -0.817), kind: .destination)
        return map(id: "reverse-stub", coordinateSpace: "pdr_xy", nodes: [spices, turn, onions])
    }

    /// The July 25 evening re-capture of the same aisle, where the straight
    /// point landed 1.6 m from the shelf instead of 1.4 m.
    private static func narrowAisleStartMap() -> SemanticRouteMap {
        let cereals = node(id: "cereals", name: "Cereals", point: SemanticRoutePoint(x: 0, y: 0), kind: .destination)
        let straight = node(
            id: "straight1",
            name: "Straight point 1",
            point: SemanticRoutePoint(x: -1.28, y: -0.96),
            kind: .waypoint,
            turnHint: .straight
        )
        let left2 = node(
            id: "left2",
            name: "Left turn 2",
            point: SemanticRoutePoint(x: -4.34, y: -3.53),
            kind: .intersection,
            turnHint: .left
        )
        let onions = node(id: "onions", name: "Onions", point: SemanticRoutePoint(x: 0.30, y: -9.92), kind: .destination)
        return map(id: "narrow-aisle", coordinateSpace: "pdr_xy", nodes: [cereals, straight, left2, onions])
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

    /// An L route whose saved images sit within a metre of the turn node —
    /// close enough for the geometric fallback on both the step that ends
    /// there and the step that starts there to claim them.
    private static func lTurnMapWithKeyframesAtTheTurn() -> SemanticRouteMap {
        var map = lTurnARMap()
        let poses = [(0.0, 3.4), (0.0, 3.8), (0.0, 4.0), (0.35, 4.0)]
        let keyframes = poses.enumerated().map { index, pose in
            keyframe(id: "turn-\(index)", x: pose.0, y: pose.1, heading: 45)
        }
        map.keyframes = keyframes
        map.visualFingerprints = Dictionary(
            uniqueKeysWithValues: keyframes.compactMap { frame in
                frame.visualFingerprintId.map { ($0, fingerprint()) }
            }
        )
        return map
    }

    private static func fingerprint() -> ARVisualFingerprint {
        ARVisualFingerprint(
            dimension: 2,
            luma: [0, 0, 0, 0],
            colorMean: [0, 0, 0],
            averageHash: 0,
            featurePrintData: nil,
            createdAt: Date(timeIntervalSince1970: 0)
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

    /// A route that walks into a dead-end spur and back out, the shape that
    /// misrouted a real capture. Junction sits 0.3 m off the Corner→Printer
    /// edge while heading 90° away from it, so the nearest edge to someone
    /// standing on Junction is one they have no business being routed onto.
    private static func doublingBackMap() -> SemanticRouteMap {
        let start = node(id: "start", name: "Entrance", point: SemanticRoutePoint(x: 0, y: 0), kind: .entrance)
        let corner = node(id: "corner", name: "Corner", point: SemanticRoutePoint(x: 0, y: -4), kind: .intersection)
        let spur = node(id: "printer", name: "Printer", point: SemanticRoutePoint(x: 0, y: -10), kind: .destination)
        let junction = node(id: "junction", name: "Junction", point: SemanticRoutePoint(x: 0.3, y: -7), kind: .intersection, turnHint: .left)
        let target = node(id: "elevators", name: "Elevators", point: SemanticRoutePoint(x: -5, y: -7), kind: .destination)
        return map(
            id: "doubling-back",
            coordinateSpace: "ar_world_xz",
            nodes: [start, corner, spur, junction, target]
        )
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

    // MARK: - Office field map (2026-07-27)

    /// Forward guidance over the real Office capture. The two "Straight point"
    /// nodes bend by 5° and 8°, so shaping must fold them away and leave four
    /// walked legs — not six, and not a first cue of "walk one metre".
    func testOfficeMapForwardShapesToFourLegsWithCorrectTurns() {
        let navigator = SemanticRouteNavigator()
        let map = Self.officeMap()
        navigator.replaceMapsForTesting([map])
        let desk = map.nodes.first { $0.id == "desk" }!

        XCTAssertTrue(navigator.startNavigation(
            to: "Door",
            arPosition: Self.arPosition(desk.point),
            imuState: Self.imu(bearing: 47),
            speakLandmarks: false,
            arHeading: 47
        ))

        let legs = navigator.routeSteps
        XCTAssertEqual(legs.map(\.from.name), ["Adnaan Desk", "Right turn 2", "Left turn 3", "Right turn 4"])
        XCTAssertEqual(legs.map(\.to.name), ["Right turn 2", "Left turn 3", "Right turn 4", "Door"])
        XCTAssertEqual(legs.reduce(0) { $0 + $1.edge.distanceMeters }, 16.2, accuracy: 0.15)

        // Walking out, each labelled turn must match the label the mapper gave
        // it: right at "Right turn 2", left at "Left turn 3", right at 4.
        let turns = Self.signedTurns(between: legs)
        XCTAssertGreaterThan(turns[0], 25, "Right turn 2 should turn right walking out")
        XCTAssertLessThan(turns[1], -25, "Left turn 3 should turn left walking out")
        XCTAssertGreaterThan(turns[2], 25, "Right turn 4 should turn right walking out")
    }

    /// The return journey over the same capture. Every labelled turn reverses:
    /// "Right turn 4" is a LEFT on the way back. A route that walks the graph
    /// backwards but keeps the recorded handedness is the bidirectional bug.
    func testOfficeMapReverseMirrorsEveryTurn() {
        let navigator = SemanticRouteNavigator()
        let map = Self.officeMap()
        navigator.replaceMapsForTesting([map])
        let door = map.nodes.first { $0.id == "door" }!

        XCTAssertTrue(navigator.startNavigation(
            to: "Adnaan Desk",
            arPosition: Self.arPosition(door.point),
            imuState: Self.imu(bearing: 320),
            speakLandmarks: false,
            arHeading: 320
        ))

        let legs = navigator.routeSteps
        XCTAssertEqual(legs.map(\.from.name), ["Door", "Right turn 4", "Left turn 3", "Right turn 2"])
        XCTAssertEqual(legs.map(\.to.name), ["Right turn 4", "Left turn 3", "Right turn 2", "Adnaan Desk"])
        XCTAssertEqual(legs.reduce(0) { $0 + $1.edge.distanceMeters }, 16.2, accuracy: 0.15)

        let turns = Self.signedTurns(between: legs)
        XCTAssertLessThan(turns[0], -25, "Right turn 4 must become a LEFT on the way back")
        XCTAssertGreaterThan(turns[1], 25, "Left turn 3 must become a RIGHT on the way back")
        XCTAssertLessThan(turns[2], -25, "Right turn 2 must become a LEFT on the way back")
    }

    /// The AR arrow overlay has to have something to draw the moment guidance
    /// starts, and it has to end on the destination.
    func testOfficeMapPublishesRouteOverlayPolyline() {
        let navigator = SemanticRouteNavigator()
        let map = Self.officeMap()
        navigator.replaceMapsForTesting([map])
        let desk = map.nodes.first { $0.id == "desk" }!
        let door = map.nodes.first { $0.id == "door" }!

        XCTAssertTrue(navigator.startNavigation(
            to: "Door",
            arPosition: Self.arPosition(desk.point),
            imuState: Self.imu(bearing: 47),
            speakLandmarks: false,
            arHeading: 47
        ))

        let polyline = navigator.remainingRoutePolyline()
        XCTAssertEqual(polyline.count, 5, "believed position plus the four leg ends")
        XCTAssertEqual(polyline.first!.distance(to: desk.point), 0, accuracy: 0.2)
        XCTAssertEqual(polyline.last!.distance(to: door.point), 0, accuracy: 0.01)
    }

    /// The on-screen needle must agree with the leg being guided: facing along
    /// the first leg reads as aligned, facing the other way reads as a
    /// half-turn. This is the number every spoken turn is derived from.
    func testHeadingErrorToActiveLegTracksTheGuidedLeg() {
        let navigator = SemanticRouteNavigator()
        let map = Self.officeMap()
        navigator.replaceMapsForTesting([map])
        let desk = map.nodes.first { $0.id == "desk" }!

        XCTAssertTrue(navigator.startNavigation(
            to: "Door",
            arPosition: Self.arPosition(desk.point),
            imuState: Self.imu(bearing: 47),
            speakLandmarks: false,
            arHeading: 47
        ))

        let aligned = navigator.headingErrorToActiveLeg(liveHeading: 50)
        XCTAssertNotNil(aligned)
        XCTAssertEqual(abs(aligned ?? 99), 0, accuracy: 12)

        let reversed = navigator.headingErrorToActiveLeg(liveHeading: 230)
        XCTAssertEqual(abs(reversed ?? 0), 180, accuracy: 12)
    }

    // MARK: - Pilot cue-wording fixes (11 Aug 2026)

    /// The cue that calls a turn also has to restart the walking. Participants
    /// completed the turn and stood still, because "Turn right. 11 meters,
    /// toward the next turn." never said to move.
    func testTurnCueTellsTheUserToWalkAndLaterCuesDoNot() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.lTurnARMap()])
        XCTAssertTrue(navigator.startNavigation(
            to: "Checkout",
            arPosition: simd_float3(0, 0, 0),
            imuState: Self.imu(bearing: 0),
            speakLandmarks: false,
            arHeading: 0
        ))

        // Standing on the turn node: the advance fires and calls the turn.
        navigator.update(
            imuState: Self.imu(isMoving: true, x: 0, y: 3.9, bearing: 0),
            arPosition: simd_float3(0, 0, -3.9),
            arHeading: 0,
            arLocalized: true
        )
        XCTAssertEqual(navigator.currentStepIndex, 1)
        XCTAssertTrue(
            navigator.currentInstruction.contains("Walk "),
            "the turn cue must restart the walk, got: \(navigator.currentInstruction)"
        )

        // Mid-leg, walking the new leg: the verb is spent and does not repeat.
        navigator.update(
            imuState: Self.imu(isMoving: true, x: 1.5, y: 4, bearing: 90),
            arPosition: simd_float3(1.5, 0, -4),
            arHeading: 90,
            arLocalized: true
        )
        XCTAssertFalse(
            navigator.currentInstruction.contains("Walk "),
            "routine leg cues stay bare, got: \(navigator.currentInstruction)"
        )
    }

    /// The opening cue used to append the landmark it was about to pass, so a
    /// user who had not moved yet heard three clauses, one of them about a
    /// shelf they were standing at. The standalone landmark cue still fires.
    func testOpeningCueDoesNotAppendThePassingLandmarkClause() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.lTurnMapWithSecondSegmentLandmark()])
        XCTAssertTrue(navigator.startNavigation(
            to: "Checkout",
            arPosition: simd_float3(0, 0, 0),
            imuState: Self.imu(bearing: 0),
            speakLandmarks: true,
            arHeading: 0
        ))

        XCTAssertFalse(
            navigator.currentInstruction.contains("Passing"),
            "got: \(navigator.currentInstruction)"
        )
    }

    /// "Left turn 2" is a capture label. Spoken, the ordinal is a number the
    /// user cannot use.
    func testCaptureTurnOrdinalsAreNeverSpoken() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.igaMap()])
        XCTAssertTrue(navigator.startNavigation(
            to: "Onions",
            arPosition: nil,
            imuState: Self.imu(x: 0, y: 0, bearing: 217),
            speakLandmarks: false,
            arHeading: 217
        ))

        for step in navigator.routeSteps {
            let spoken = navigator.currentInstruction
            XCTAssertFalse(spoken.contains("turn 1"), "got: \(spoken)")
            XCTAssertFalse(spoken.contains("turn 2"), "got: \(spoken)")
            XCTAssertFalse(spoken.contains("turn 3"), "got: \(spoken)")
            XCTAssertFalse(spoken.contains("turn 4"), "got: \(spoken)")
            _ = step
        }
    }

    /// Walking past the destination had no voice at all: progress saturates at
    /// the end of the leg, so the strongest thing guidance could say was "about
    /// 1 meter, toward Onions" — on repeat, while the user walked away.
    func testWalkingPastTheDestinationSaysToTurnAround() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.straightMap(coordinateSpace: "ar_world_xz")])
        XCTAssertTrue(navigator.startNavigation(
            to: "Milk",
            arPosition: simd_float3(0, 0, 0),
            imuState: Self.imu(bearing: 0),
            speakLandmarks: false,
            arHeading: 0
        ))

        // The belief is pinned mid-leg — which is the state the pilot hit, with
        // guidance saying "about 1 meter, toward Onions" — while the AR pose
        // says the user is 6 m beyond Milk (which sits at y = 8) and walking.
        navigator.setRouteProgressForTesting(stepIndex: 0, progressMeters: 1.0)
        navigator.expireGuidanceIntroProtectionForTesting()
        let past = simd_float3(0, 0, -14)
        navigator.update(
            imuState: Self.imu(isMoving: true, x: 0, y: 14, bearing: 0),
            arPosition: past,
            arHeading: 0,
            arLocalized: true
        )
        XCTAssertTrue(
            navigator.expireDestinationOvershootHoldForTesting(),
            "the overshoot must be tracked from the first tick that sees it"
        )
        navigator.update(
            imuState: Self.imu(isMoving: true, x: 0, y: 14, bearing: 0),
            arPosition: past,
            arHeading: 0,
            arLocalized: true
        )

        XCTAssertTrue(
            navigator.currentInstruction.contains("Turn around")
                || navigator.currentInstruction.contains("behind you"),
            "expected an overshoot correction, got: \(navigator.currentInstruction)"
        )
    }

    /// Control: standing just short of the destination is not an overshoot.
    func testApproachingTheDestinationIsNotReportedAsAnOvershoot() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.straightMap(coordinateSpace: "ar_world_xz")])
        XCTAssertTrue(navigator.startNavigation(
            to: "Milk",
            arPosition: simd_float3(0, 0, 0),
            imuState: Self.imu(bearing: 0),
            speakLandmarks: false,
            arHeading: 0
        ))

        navigator.update(
            imuState: Self.imu(isMoving: true, x: 0, y: 6.5, bearing: 0),
            arPosition: simd_float3(0, 0, -6.5),
            arHeading: 0,
            arLocalized: true
        )

        XCTAssertFalse(
            navigator.expireDestinationOvershootHoldForTesting(),
            "1.5 m short of the destination is not an overshoot"
        )
        XCTAssertFalse(navigator.currentInstruction.contains("Turn around"))
        XCTAssertFalse(navigator.currentInstruction.contains("behind you"))
    }

    /// The opening cue states the journey and nothing else.
    ///
    /// It used to carry " Tap Done to stop guidance." on the first journey of
    /// a launch, back when that button was the only exit. The exit is the whole
    /// screen now, and the sentence only made the one announcement a
    /// participant has to hold in their head longer.
    func testOpeningCueDoesNotTeachAnExitControl() {
        let navigator = SemanticRouteNavigator()
        navigator.replaceMapsForTesting([Self.straightMap(coordinateSpace: "pdr_xy")])

        XCTAssertTrue(navigator.startNavigation(
            to: "Milk",
            arPosition: nil,
            imuState: Self.imu(bearing: 0),
            speakLandmarks: false,
            arHeading: 0
        ))
        XCTAssertFalse(
            navigator.currentInstruction.contains("Done"),
            "got: \(navigator.currentInstruction)"
        )
        XCTAssertFalse(
            navigator.currentInstruction.lowercased().contains("tap"),
            "got: \(navigator.currentInstruction)"
        )
    }

    // MARK: - Capture: a turn marked at a destination

    /// Marking the turn you take AT a shelf, without stepping away from it,
    /// must not delete the shelf.
    ///
    /// The 2026-08-11 pilot's "Test" capture marked "Biscuits", linked its
    /// reaching object, then marked the turn from the same spot. The
    /// snap-to-previous branch renamed the destination into "Left turn 1" and
    /// flipped its kind, `sanitizedMap` then dropped the reaching object it no
    /// longer considered a destination's, and arrival at Biscuits had nothing
    /// to hand off to — while Onions, whose turn was marked 0.40 m away, kept
    /// its node and reached correctly.
    func testTurnMarkedAtADestinationKeepsTheDestinationAndItsReachingObject() {
        let navigator = SemanticRouteNavigator()
        navigator.beginRouteCapture(named: "Pilot")
        XCTAssertTrue(navigator.captureStart(
            named: "Intersection",
            arPosition: simd_float3(0, 0, 0),
            arHeading: 297,
            imuState: Self.imu(bearing: 297)
        ))

        // Walk to the shelf, name it, and link the object to reach for there.
        let shelf = SemanticRoutePoint(x: -1.98, y: 1.21)
        XCTAssertTrue(navigator.captureLandmark(
            named: "Biscuits",
            side: .right,
            context: "",
            arPosition: Self.arPosition(shelf),
            isDestination: true
        ))
        XCTAssertTrue(navigator.attachReachingObject(named: "Oreos"))

        // The turn is taken at the shelf: same spot, a few cm of hand jitter.
        XCTAssertTrue(navigator.captureTurn(
            .left,
            arPosition: Self.arPosition(SemanticRoutePoint(x: -1.99, y: 1.25)),
            arHeading: 206,
            imuState: Self.imu(x: -1.99, y: 1.25, bearing: 206)
        ))

        let biscuits = navigator.activeMap?.nodes.first { $0.name == "Biscuits" }
        XCTAssertNotNil(biscuits, "the destination must survive the turn mark")
        XCTAssertEqual(biscuits?.kind, .destination)
        XCTAssertEqual(biscuits?.turnHint, .left, "the turn is recorded on it")
        XCTAssertEqual(navigator.reachingObjectName(forTarget: "Biscuits"), "Oreos")
        XCTAssertFalse(
            navigator.activeMap?.nodes.contains { $0.name == "Left turn 1" } ?? true,
            "no rival node is minted at the same spot either"
        )

        // `sanitizedMap` keeps `reachingObjectName` only on nodes that are
        // still destinations, so the kind above is what carries the link
        // through the save. Assert the field itself rather than saving, which
        // would persist a fixture to disk.
        XCTAssertEqual(biscuits?.reachingObjectName, "Oreos")
    }

    /// Control: the snap itself still works. Two structural marks made from one
    /// spot are still one node — that is what keeps a corrected turn from
    /// leaving a stub behind.
    func testTurnRemarkedAtTheSameSpotStillCollapsesToOneNode() {
        let navigator = SemanticRouteNavigator()
        navigator.beginRouteCapture(named: "Pilot")
        XCTAssertTrue(navigator.captureStart(
            named: "Intersection",
            arPosition: simd_float3(0, 0, 0),
            arHeading: 297,
            imuState: Self.imu(bearing: 297)
        ))
        let corner = SemanticRoutePoint(x: -1.98, y: 1.21)
        XCTAssertTrue(navigator.captureTurn(
            .left,
            arPosition: Self.arPosition(corner),
            arHeading: 206,
            imuState: Self.imu(x: corner.x, y: corner.y, bearing: 206)
        ))
        XCTAssertTrue(navigator.captureTurn(
            .right,
            arPosition: Self.arPosition(SemanticRoutePoint(x: -1.99, y: 1.25)),
            arHeading: 26,
            imuState: Self.imu(x: -1.99, y: 1.25, bearing: 26)
        ))

        let turns = navigator.activeMap?.nodes.filter { $0.kind == .intersection } ?? []
        XCTAssertEqual(turns.count, 1, "the second mark corrects the first")
        XCTAssertEqual(turns.first?.turnHint, .right)
    }

    private static func arPosition(_ point: SemanticRoutePoint) -> simd_float3 {
        // Route y is the negation of ARKit z; the navigator converts back.
        simd_float3(Float(point.x), 0, Float(-point.y))
    }

    private static func signedTurns(between legs: [SemanticRouteStep]) -> [Double] {
        guard legs.count >= 2 else { return [] }
        return (0..<(legs.count - 1)).map { index in
            var diff = legs[index + 1].edge.bearingDegrees - legs[index].edge.bearingDegrees
            while diff > 180 { diff -= 360 }
            while diff < -180 { diff += 360 }
            return diff
        }
    }

    /// The "Office" map exactly as captured in the field on 2026-07-27, rebuilt
    /// from its route report: 7 nodes, 16.2 m, segment bearings 47°, 52°, 126°,
    /// 61°, 132°, 140°. Node positions are derived from those bearings and
    /// distances, so this is the real graph rather than a tidied stand-in — the
    /// point is to assert on geometry that actually failed in a building.
    private static func officeMap() -> SemanticRouteMap {
        func advance(_ from: SemanticRoutePoint, bearing: Double, meters: Double) -> SemanticRoutePoint {
            let radians = bearing * .pi / 180
            return SemanticRoutePoint(
                x: from.x + meters * sin(radians),
                y: from.y + meters * cos(radians)
            )
        }

        let deskPoint = SemanticRoutePoint(x: 0, y: 0)
        let straight1Point = advance(deskPoint, bearing: 47, meters: 1.2)
        let right2Point = advance(straight1Point, bearing: 52, meters: 2.6)
        let left3Point = advance(right2Point, bearing: 126, meters: 2.1)
        let right4Point = advance(left3Point, bearing: 61, meters: 3.5)
        let straight5Point = advance(right4Point, bearing: 132, meters: 2.2)
        let doorPoint = advance(straight5Point, bearing: 140, meters: 4.6)

        return map(
            id: "office",
            coordinateSpace: "ar_world_xz",
            nodes: [
                node(id: "desk", name: "Adnaan Desk", point: deskPoint, kind: .entrance),
                node(id: "s1", name: "Straight point 1", point: straight1Point, kind: .intersection, turnHint: .straight),
                node(id: "r2", name: "Right turn 2", point: right2Point, kind: .intersection, turnHint: .right),
                node(id: "l3", name: "Left turn 3", point: left3Point, kind: .intersection, turnHint: .left),
                node(id: "r4", name: "Right turn 4", point: right4Point, kind: .intersection, turnHint: .right),
                node(id: "s5", name: "Straight point 5", point: straight5Point, kind: .intersection, turnHint: .straight),
                node(id: "door", name: "Door", point: doorPoint, kind: .destination)
            ]
        )
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
