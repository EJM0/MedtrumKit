import LoopKit
@testable import MedtrumKit
import XCTest

/// Handing the patch to another controller (MedtrumPumpManager+DeviceHandoff), as OmniTests/DeviceHandoffTests
final class DeviceHandoffTests: XCTestCase {
    private let pumpSN = Data([0x28, 0xD8, 0x12, 0x4A])
    private let handle = UUID()

    private func makeState() -> MedtrumPumpState {
        let state = MedtrumPumpState(nil)
        state.pumpSN = pumpSN
        state.peripheralIdentifier = handle
        state.sessionToken = Data([1, 2, 3, 4])
        state.pumpState = .active
        state.patchSessionEnded = false
        state.patchId = UInt64(256).toData(length: 4)
        return state
    }

    private func makeTempBasal() -> UnfinalizedDose {
        UnfinalizedDose(decisionId: nil, tempRate: 2, duration: .minutes(30), insulinType: nil, automatic: true)
    }

    private func makeBolus() -> UnfinalizedDose {
        UnfinalizedDose(decisionId: nil, units: 1, duration: 40, activationType: .manualNoRecommendation, insulinType: nil)
    }

    private func export(_ state: MedtrumPumpState) -> SharedDeviceConfiguration {
        SharedDeviceConfiguration(managerIdentifier: "Medtrum", asOf: Date(), state: state.sharedCopy().rawValue)
    }

    // MARK: Export and adopt

    func testExportLeavesOutWhatIsThisControllers() {
        let state = makeState()
        state.controlReleased = true
        state.configuredByAnotherController = true
        state.inFlightDosesInheritedAway = true
        state.untrackedDeliveryIsForeign = true
        let bolus = makeBolus()
        state.bolusDose = bolus
        state.basalDose = makeTempBasal()

        let shared = state.sharedCopy()

        XCTAssertNil(shared.peripheralIdentifier)
        XCTAssertFalse(shared.controlReleased)
        XCTAssertFalse(shared.configuredByAnotherController)
        XCTAssertFalse(shared.inFlightDosesInheritedAway)
        XCTAssertFalse(shared.untrackedDeliveryIsForeign)
        // What another controller needs: the token, and the doses in flight under the same identities
        XCTAssertEqual(shared.sessionToken, state.sessionToken)
        XCTAssertEqual(shared.pumpSN, pumpSN)
        XCTAssertEqual(shared.bolusDose?.startDate, bolus.startDate)
        XCTAssertEqual(shared.basalDose.type, .tempBasal)
        // The original is untouched
        XCTAssertEqual(state.peripheralIdentifier, handle)
    }

    func testAdoptAttachesThisDevicesHandleOnlyForTheSameBase() {
        let configuration = export(makeState())
        let ours = ["pumpSN": pumpSN, "peripheralIdentifier": handle.uuidString] as [String: Any]
        let anotherBase = ["pumpSN": Data([9, 9, 9, 9]), "peripheralIdentifier": handle.uuidString] as [String: Any]

        let adopted = MedtrumPumpManager.adoptedState(from: configuration, localState: ours)
        XCTAssertEqual(adopted?.peripheralIdentifier, handle)
        XCTAssertEqual(adopted?.configuredByAnotherController, true)
        XCTAssertEqual(adopted?.untrackedDeliveryIsForeign, true)

        XCTAssertNil(MedtrumPumpManager.adoptedState(from: configuration, localState: anotherBase)?.peripheralIdentifier)
        XCTAssertNil(MedtrumPumpManager.adoptedState(from: configuration, localState: nil)?.peripheralIdentifier)

        XCTAssertFalse(MedtrumPumpManager.takeControlNeedsSearch(adopting: configuration, localState: ours))
        XCTAssertTrue(MedtrumPumpManager.takeControlNeedsSearch(adopting: configuration, localState: anotherBase))
        XCTAssertTrue(MedtrumPumpManager.takeControlNeedsSearch(adopting: configuration, localState: nil))
    }

    func testNothingToAdoptWithoutABase() {
        let configuration = SharedDeviceConfiguration(
            managerIdentifier: "Medtrum",
            asOf: Date(),
            state: MedtrumPumpState(nil).rawValue
        )
        XCTAssertNil(MedtrumPumpManager.adoptedState(from: configuration, localState: nil))
    }

    func testLocalStateRoundTrips() {
        let state = makeState()
        XCTAssertEqual(MedtrumPumpState.handle(in: state.localState, forPumpSN: pumpSN), handle)

        state.peripheralIdentifier = nil
        XCTAssertNil(state.localState)
    }

    func testHandOffFlagsArePersisted() {
        let state = makeState()
        state.controlReleased = true
        state.inFlightDosesInheritedAway = true
        state.untrackedDeliveryIsForeign = true
        state.configuredByAnotherController = true

        let restored = MedtrumPumpState(rawValue: state.rawValue)
        XCTAssertTrue(restored.controlReleased)
        XCTAssertTrue(restored.inFlightDosesInheritedAway)
        XCTAssertTrue(restored.untrackedDeliveryIsForeign)
        XCTAssertTrue(restored.configuredByAnotherController)
    }

    // MARK: Release and take back

    func testReleaseHandsTheDosesInFlightOverAndTakeBackDropsThem() {
        let state = makeState()
        state.basalDose = makeTempBasal()
        state.bolusDose = makeBolus()

        state.releaseControl()
        XCTAssertTrue(state.controlReleased)
        XCTAssertTrue(state.inFlightDosesInheritedAway)

        state.resolveAfterForeignControl(dropInFlight: state.inFlightDosesInheritedAway)
        XCTAssertFalse(state.controlReleased)
        XCTAssertFalse(state.inFlightDosesInheritedAway)
        XCTAssertTrue(state.untrackedDeliveryIsForeign)
        XCTAssertNil(state.bolusDose)
        XCTAssertEqual(state.basalDose.type, .basal)
    }

    func testReleaseWithNothingInFlightKeepsTheRecordsAtTakeBack() {
        let state = makeState()
        let scheduled = state.basalDose

        state.releaseControl()
        XCTAssertFalse(state.inFlightDosesInheritedAway)

        state.resolveAfterForeignControl(dropInFlight: state.inFlightDosesInheritedAway)
        XCTAssertTrue(state.basalDose === scheduled)
        XCTAssertTrue(state.untrackedDeliveryIsForeign)
    }

    // MARK: Odometer

    // A MedtrumPumpManager can't be built here: its central's restore identifier needs a host app with the
    // bluetooth-central background mode, so the manager's forwarding is left to the device checks
    func testDeliveredUnitsComeFromTheReservoirInPulses() {
        let state = makeState()
        let readAt = Date(timeIntervalSince1970: 1000)
        state.initialReservoir = 200
        state.reservoir = 187.349_999
        state.reservoirReadAt = readAt

        XCTAssertEqual(state.deliveredUnits?.units ?? -1, 12.65, accuracy: 1e-9)
        XCTAssertEqual(state.deliveredUnits?.at, readAt)

        state.patchSessionEnded = true
        XCTAssertNil(state.deliveredUnits)
        state.patchSessionEnded = false

        state.initialReservoir = nil
        XCTAssertNil(state.deliveredUnits)
    }

    // MARK: Delivery this controller did not command

    func testAForeignSuspendIsFollowedButNotBooked() {
        let state = makeState()
        state.untrackedDeliveryIsForeign = true

        let events = StateSyncer.recordSuspendIfDelivering(state: state, basal: nil, receivedAt: Date())
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(state.basalDose.type, .suspend)
    }

    func testAnOwnSuspendIsBooked() {
        let state = makeState()

        let events = StateSyncer.recordSuspendIfDelivering(state: state, basal: nil, receivedAt: Date())
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(state.basalDose.type, .suspend)
    }

    func testForeignDeliverySettlesOnceThePatchIsOnItsSchedule() {
        let state = makeState()
        state.untrackedDeliveryIsForeign = true

        var response = SynchronizePacketResponse(state: .active, activeAlarms: [])
        response.basal = BasalData(type: .ABSOLUTE_TEMP, sequence: 1, patchId: 256, startTime: Date(), rate: 2, delivery: 0)
        StateSyncer.settleForeignDelivery(syncResponse: response, state: state, fullSync: true)
        XCTAssertTrue(state.untrackedDeliveryIsForeign, "another controller's temp basal is still running")

        response.basal = BasalData(type: .STANDARD, sequence: 2, patchId: 256, startTime: Date(), rate: 1, delivery: 0)
        response.bolus = BolusData(type: 0, completed: false, delivered: 0.5)
        StateSyncer.settleForeignDelivery(syncResponse: response, state: state, fullSync: true)
        XCTAssertTrue(state.untrackedDeliveryIsForeign, "a bolus is still running")

        StateSyncer.settleForeignDelivery(syncResponse: response, state: state, fullSync: false)
        response.bolus = nil
        StateSyncer.settleForeignDelivery(syncResponse: response, state: state, fullSync: false)
        XCTAssertTrue(state.untrackedDeliveryIsForeign, "a notification is not a full status")

        StateSyncer.settleForeignDelivery(syncResponse: response, state: state, fullSync: true)
        XCTAssertFalse(state.untrackedDeliveryIsForeign)
    }

    func testABolusUnderWayIsReportedWhoeverStartedIt() {
        let state = makeState()
        let now = Date()
        var response = SynchronizePacketResponse(state: .active, activeAlarms: [])

        response.bolus = BolusData(type: 0, completed: false, delivered: 0.5)
        let needsRecord = StateSyncer.trackBolusUnderWay(syncResponse: response, state: state, fullSync: false, receivedAt: now)
        XCTAssertTrue(needsRecord, "another controller's bolus: its amount is in the patch's history")
        XCTAssertEqual(state.reportedBolusEndsAt, now.addingTimeInterval(StateSyncer.foreignBolusEndsWithin))

        // Its history record says 2 U: the other 1.5 U at 1.5 U/min take 60 s
        state.bolusRecord = BolusRecord(startedAt: now.addingTimeInterval(-20), amount: 2, delivered: 0)
        XCTAssertFalse(StateSyncer.trackBolusUnderWay(syncResponse: response, state: state, fullSync: false, receivedAt: now))
        XCTAssertEqual(state.reportedBolusEndsAt!.timeIntervalSince(now), 60, accuracy: 1e-9)
        state.bolusRecord = nil

        // Our own 1 U bolus, 0.5 U delivered: the other 0.5 U at 1.5 U/min take 20 s
        state.bolusDose = makeBolus()
        StateSyncer.trackBolusUnderWay(syncResponse: response, state: state, fullSync: false, receivedAt: now)
        XCTAssertEqual(state.reportedBolusEndsAt!.timeIntervalSince(now), 20, accuracy: 1e-9)

        StateSyncer.trackBolusUnderWay(
            syncResponse: SynchronizePacketResponse(state: .active, activeAlarms: []),
            state: state,
            fullSync: false,
            receivedAt: now
        )
        XCTAssertNotNil(state.reportedBolusEndsAt, "a notification without bolus data says nothing about it")

        response.bolus = BolusData(type: 0, completed: true, delivered: 1)
        state.bolusRecord = BolusRecord(startedAt: now, amount: 1, delivered: 0)
        state.bolusRecordLookedUp = 7
        StateSyncer.trackBolusUnderWay(syncResponse: response, state: state, fullSync: false, receivedAt: now)
        XCTAssertNil(state.reportedBolusEndsAt)
        XCTAssertNil(state.bolusRecord)
        XCTAssertNil(state.bolusRecordLookedUp)
    }

    // MARK: Bolus history record

    func testGetRecordRequestCarriesIndexAndPatchId() {
        let packet = GetRecordPacket(recordIndex: 0x0102, patchId: 0x0A0B0C)
        XCTAssertEqual(packet.getRequestBytes(), Data([0x02, 0x01, 0x0C, 0x0B]))
    }

    func testGetRecordParsesANormalBolus() {
        let startedAt = Date.fromMedtrumSeconds(400_000_000)
        var data = Data(count: 46)
        data[6] = GetRecordPacket.validHeader
        data[8] = 1 // bolus record
        data.replaceSubrange(16 ..< 18, with: UInt64(321).toData(length: 2))
        data[18] = 0x11 // normal, from the wizard
        data.replaceSubrange(22 ..< 26, with: UInt64(400_000_000).toData(length: 4))
        data.replaceSubrange(26 ..< 28, with: UInt64(50).toData(length: 2)) // 2.5 U
        data.replaceSubrange(28 ..< 30, with: UInt64(10).toData(length: 2)) // 0.5 U
        let packet = GetRecordPacket(recordIndex: 321, patchId: 1)
        packet.totalData = data

        let response = packet.parseResponse()
        XCTAssertTrue(response.isValid)
        XCTAssertEqual(response.sequence, 321)
        XCTAssertEqual(response.bolus?.startedAt, startedAt)
        XCTAssertEqual(response.bolus?.amount ?? -1, 2.5, accuracy: 1e-9)
        XCTAssertEqual(response.bolus?.delivered ?? -1, 0.5, accuracy: 1e-9)

        data[8] = 2 // basal record
        packet.totalData = data
        XCTAssertNil(packet.parseResponse().bolus)
    }

    func testOnlyARecordOfABolusStillRunningIsUsed() {
        let now = Date()
        // 3 U take 120 s
        XCTAssertTrue(BolusRecord(startedAt: now.addingTimeInterval(-30), amount: 3, delivered: 0).canBeRunning(at: now))
        XCTAssertFalse(
            BolusRecord(startedAt: now.addingTimeInterval(-30), amount: 3, delivered: 3).canBeRunning(at: now),
            "written once it was all delivered"
        )
        XCTAssertFalse(
            BolusRecord(startedAt: now.addingTimeInterval(-600), amount: 3, delivered: 1).canBeRunning(at: now),
            "an older bolus, long over"
        )
    }

    // MARK: Connect clock

    func testAnAdoptedHandleThatNeverConnectedIsReportedOnce() {
        let clock = ConnectClock()
        clock.beginAttempt(adoptedHandle: "handle")
        XCTAssertEqual(clock.adoptedHandleThatNeverConnected(), "handle")
        XCTAssertNil(clock.adoptedHandleThatNeverConnected())

        clock.beginAttempt(adoptedHandle: "handle")
        clock.noteConnect()
        XCTAssertNil(clock.adoptedHandleThatNeverConnected())
    }
}
