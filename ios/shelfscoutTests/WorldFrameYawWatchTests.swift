import XCTest
@testable import shelfscout

/// The failure these cover, from the 2026-07-29 IGA trace:
///
/// The app promoted to `isLocalized` 1.0 s after loading the map, while ARKit was
/// still tracking in its own `.gravity` frame. Because the journey began at the
/// route's first node — which is also the saved map's origin — the pose snapped
/// onto the right edge at 0.25 m cross-track and looked perfect. The yaw did not:
/// the AR heading then walked 220.7° → ~0.7° → 237° across ticks that every one
/// reported the user standing still. Nothing detected that, because the only
/// re-resolution trigger was a >1.5 m POSITION jump — and rotating a frame about
/// a point the user is standing on moves the position by nothing. The route stayed
/// locked to the abandoned bearing for the whole journey, which is what the user
/// experienced as the route running off behind them.
///
/// These tests pin the detector that closes that gap, and — just as important —
/// pin that it does NOT fire on ordinary user turns, because a detector that
/// re-resolves the route every few seconds would be worse than the original bug.
final class WorldFrameYawWatchTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    private func time(_ seconds: Double) -> Date {
        start.addingTimeInterval(seconds)
    }

    // MARK: - The failure

    func testStillUserWithSteppingARYawIsReportedAsFrameRotation() {
        var watch = WorldFrameYawWatch()
        watch.acceptAlignment(arHeading: 220.7, deviceYaw: 310.0)

        var detections: [WorldFrameYawWatch.Detection] = []
        for tick in 0..<40 {
            let t = 3.12 + Double(tick) * 0.25
            // The frame re-orients 140° at t=4.0. The phone never moves.
            let arHeading = t < 4.0 ? 220.7 : 0.7
            if let detection = watch.ingest(
                at: time(t), arHeading: arHeading, deviceYaw: 310.0, usedTiltFallback: false
            ) {
                detections.append(detection)
            }
        }

        XCTAssertFalse(detections.isEmpty, "a 140° frame rotation under a still phone must be reported")
        let first = try? XCTUnwrap(detections.first)
        XCTAssertEqual(first?.detector, .stillDevice)
        XCTAssertEqual(abs(first?.rotationDegrees ?? 0), 140, accuracy: 1.0)
    }

    func testFrameRotationIsStillCaughtWhenTheUserPansThroughIt() {
        // The real session: the moment the frame rotated, guidance said "Turn
        // sharp left", the user panned, and 81 alignment cues were deferred as
        // `heading_sweeping`. No quiet window ever brackets the step, so the
        // still-device detector cannot fire and the cumulative one must.
        var watch = WorldFrameYawWatch()
        watch.acceptAlignment(arHeading: 220.7, deviceYaw: 310.0)

        var detections: [WorldFrameYawWatch.Detection] = []
        for tick in 0..<160 {
            let t = Double(tick) * 0.25
            let deviceYaw = 310.0 + 55.0 * sin(t * 1.3)   // continuous sweeping
            let frameOffset = t < 8.0 ? 0.0 : -140.0
            var arHeading = (220.7 + frameOffset + (deviceYaw - 310.0))
                .truncatingRemainder(dividingBy: 360)
            if arHeading < 0 { arHeading += 360 }
            if let detection = watch.ingest(
                at: time(t), arHeading: arHeading, deviceYaw: deviceYaw, usedTiltFallback: false
            ) {
                detections.append(detection)
            }
        }

        XCTAssertTrue(
            detections.contains { $0.detector == .cumulative },
            "with the user panning throughout, only the cumulative detector can catch the shift"
        )
        XCTAssertFalse(
            detections.contains { $0.detector == .stillDevice },
            "no window is quiet here, so the still-device detector must not claim one was"
        )
    }

    // MARK: - Must not fire

    func testOrdinaryUserTurnWithAStableFrameIsNotReported() {
        var watch = WorldFrameYawWatch()
        watch.acceptAlignment(arHeading: 100.0, deviceYaw: 40.0)

        var detections: [WorldFrameYawWatch.Detection] = []
        for tick in 0..<80 {
            let t = Double(tick) * 0.25
            // 140° turn over 3 s, then held. The AR heading tracks it exactly.
            let turned = min(140.0, max(0, t - 1.0) * 46.0)
            var arHeading = (100.0 + turned).truncatingRemainder(dividingBy: 360)
            if arHeading < 0 { arHeading += 360 }
            if let detection = watch.ingest(
                at: time(t), arHeading: arHeading, deviceYaw: 40.0 + turned, usedTiltFallback: false
            ) {
                detections.append(detection)
            }
        }

        XCTAssertTrue(detections.isEmpty, "a turn the device corroborates is not a frame rotation")
    }

    func testInvertedDeviceYawSignDisablesTheCumulativeDetectorInsteadOfMisfiring() {
        // `IMUState.deviceYawDegrees` negates `CMAttitude.yaw` to match this
        // app's clockwise-positive headings. If that negation is ever wrong for
        // some OS or device, subtracting the two becomes adding them: every turn
        // would read as double its size and re-resolve the route. The convention
        // is therefore measured from the user's own turns rather than assumed,
        // and a disagreeing measurement must disable the cumulative path — not
        // silently invert it.
        var watch = WorldFrameYawWatch()
        watch.acceptAlignment(arHeading: 100.0, deviceYaw: 40.0)

        var detections: [WorldFrameYawWatch.Detection] = []
        for tick in 0..<80 {
            let t = Double(tick) * 0.25
            let turned = min(140.0, max(0, t - 1.0) * 46.0)
            var arHeading = (100.0 + turned).truncatingRemainder(dividingBy: 360)
            if arHeading < 0 { arHeading += 360 }
            if let detection = watch.ingest(
                at: time(t),
                arHeading: arHeading,
                deviceYaw: 40.0 - turned,        // <-- inverted
                usedTiltFallback: false
            ) {
                detections.append(detection)
            }
        }

        XCTAssertEqual(watch.signConvention, .add, "the inverted convention must be detected")
        XCTAssertTrue(detections.isEmpty, "an inverted sign must produce no corrections at all")
    }

    func testTiltReferenceSwitchIsNotReadAsRotation() {
        // Past ~70° of pitch the heading comes from the camera's UP vector
        // instead of its forward vector. The two do not agree under roll, so the
        // switch is a step change in the value for an unchanged physical facing.
        var watch = WorldFrameYawWatch()
        watch.acceptAlignment(arHeading: 100.0, deviceYaw: 40.0)

        var detections: [WorldFrameYawWatch.Detection] = []
        for tick in 0..<24 {
            let t = Double(tick) * 0.25
            let tilted = t >= 2.0
            if let detection = watch.ingest(
                at: time(t),
                arHeading: tilted ? 190.0 : 100.0,
                deviceYaw: 40.0,
                usedTiltFallback: tilted
            ) {
                detections.append(detection)
            }
        }

        XCTAssertTrue(detections.isEmpty, "a heading-reference switch is not the frame moving")
    }

    // MARK: - Bookkeeping

    func testOneRotationIsReportedOnceNotOnEveryFrameAfterIt() {
        var watch = WorldFrameYawWatch()
        watch.acceptAlignment(arHeading: 0.0, deviceYaw: 0.0)

        var detections: [WorldFrameYawWatch.Detection] = []
        for tick in 0..<60 {
            let t = Double(tick) * 0.25
            let arHeading = t < 2.0 ? 0.0 : 140.0
            if let detection = watch.ingest(
                at: time(t), arHeading: arHeading, deviceYaw: 0.0, usedTiltFallback: false
            ) {
                detections.append(detection)
            }
        }

        XCTAssertEqual(
            detections.count, 1,
            "re-baselining onto the corrected frame must stop the same step repeating"
        )
    }

    func testDriftIsMeasuredFromTheAcceptedAlignmentNotTheLatestFrame() {
        var watch = WorldFrameYawWatch()
        watch.acceptAlignment(arHeading: 220.7, deviceYaw: 310.0)

        // Phone unmoved, AR heading now 140° away: that is entirely frame.
        let drift = watch.frameYawDrift(arHeading: 80.7, deviceYaw: 310.0)
        XCTAssertEqual(abs(drift ?? 0), 140, accuracy: 0.01)

        // Phone turned 90° and the AR heading followed: no frame rotation.
        let corroborated = watch.frameYawDrift(arHeading: 310.7, deviceYaw: 40.0)
        XCTAssertEqual(abs(corroborated ?? 999), 0, accuracy: 0.01)
    }

    func testNoDriftWithoutAnAcceptedAlignment() {
        var watch = WorldFrameYawWatch()
        watch.acceptAlignment(arHeading: nil, deviceYaw: nil)
        XCTAssertNil(watch.frameYawDrift(arHeading: 10, deviceYaw: 20))
    }
}
