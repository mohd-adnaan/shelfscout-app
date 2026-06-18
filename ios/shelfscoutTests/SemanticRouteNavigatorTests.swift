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

    private static func map(id: String, coordinateSpace: String, nodes: [SemanticRouteNode]) -> SemanticRouteMap {
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
            landmarks: [],
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
