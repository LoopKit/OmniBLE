//
//  OmniBLEPumpManager.swift
//  OmniBLE
//
//  Based on OmniKit/PumpManager/OmnipodPumpManager.swift
//  Created by Pete Schwamb on 8/4/18.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import HealthKit
import LoopKit
import UserNotifications
import os.log


public protocol PodStateObserver: AnyObject {
    func podStateDidUpdate(_ state: PodState?)
}

public enum OmniBLEPumpManagerError: Error {
    case noPodPaired
    case podAlreadyPaired
    case notReadyForCannulaInsertion
    case communication(Error)
    case state(Error)
}

public enum PodCommState: Equatable {
    case noPod
    case activating
    case active
    case fault(DetailedStatus)
    case deactivating
}

extension OmniBLEPumpManagerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noPodPaired:
            return LocalizedString("No pod paired", comment: "Error message shown when no pod is paired")
        case .podAlreadyPaired:
            return LocalizedString("Pod already paired", comment: "Error message shown when user cannot pair because pod is already paired")
        case .notReadyForCannulaInsertion:
            return LocalizedString("Pod is not in a state ready for cannula insertion.", comment: "Error message when cannula insertion fails because the pod is in an unexpected state")
        case .communication(let error):
            if let error = error as? LocalizedError {
                return error.errorDescription
            } else {
                return String(describing: error)
            }
        case .state(let error):
            if let error = error as? LocalizedError {
                return error.errorDescription
            } else {
                return String(describing: error)
            }
        }
    }

    public var failureReason: String? {
        return nil
    }

    public var recoverySuggestion: String? {
        switch self {
        case .noPodPaired:
            return LocalizedString("Please pair a new pod", comment: "Recovery suggestion shown when no pod is paired")
        default:
            return nil
        }
    }
}

public class OmniBLEPumpManager: DeviceManager {

    public let managerIdentifier: String = "Omnipod-Dash" // use a single token to make parsing log files easier

    public let localizedTitle = LocalizedString("Omnipod Dash", comment: "Generic title of the OmniBLE pump manager")

    static let podAlarmNotificationIdentifier = "OmniBLE:\(LoopNotificationCategory.pumpFault.rawValue)"

    let podExpirationNotificationIdentifier: Alert.Identifier

    public init(state: OmniBLEPumpManagerState, dateGenerator: @escaping () -> Date = Date.init) {
        self.lockedState = Locked(state)

        self.dateGenerator = dateGenerator

        let podComms = PodComms(podState: state.podState, myId: state.controllerId, podId: state.podId)
        self.lockedPodComms = Locked(podComms)

        self.podExpirationNotificationIdentifier = Alert.Identifier(managerIdentifier: managerIdentifier,
                                                               alertIdentifier: LoopNotificationCategory.pumpExpired.rawValue)

        self.podComms.delegate = self
        self.podComms.messageLogger = self

    }

    public required convenience init?(rawState: PumpManager.RawStateValue) {
        guard let state = OmniBLEPumpManagerState(rawValue: rawState) else
        {
            return nil
        }

        self.init(state: state)
    }

    private var podComms: PodComms {
        get {
            return lockedPodComms.value
        }
        set {
            lockedPodComms.value = newValue
        }
    }
    private let lockedPodComms: Locked<PodComms>

    private let podStateObservers = WeakSynchronizedSet<PodStateObserver>()

    // Primarily used for testing
    public let dateGenerator: () -> Date

    public var state: OmniBLEPumpManagerState {
        return lockedState.value
    }

    private func setState(_ changes: (_ state: inout OmniBLEPumpManagerState) -> Void) -> Void {
        return setStateWithResult(changes)
    }

    @discardableResult
    private func mutateState(_ changes: (_ state: inout OmniBLEPumpManagerState) -> Void) -> OmniBLEPumpManagerState {
        return setStateWithResult({ (state) -> OmniBLEPumpManagerState in
            changes(&state)
            return state
        })
    }

    // Status can change even when state does not, because some status changes
    // purely based on time. This provides a mechanism to evaluate status changes
    // as time progresses and trigger status updates to clients.
    private func evaluateStatus() {
        setState { state in
            // status is evaluated in the setState call
        }
    }

    private func setStateWithResult<ReturnType>(_ changes: (_ state: inout OmniBLEPumpManagerState) -> ReturnType) -> ReturnType {
        var oldValue: OmniBLEPumpManagerState!
        var returnType: ReturnType!
        var shouldNotifyStatusUpdate = false
        var oldStatus: PumpManagerStatus?

        let newValue = lockedState.mutate { (state) in
            oldValue = state
            let oldStatusEvaluationDate = state.lastStatusChange
            let oldHighlight = buildPumpStatusHighlight(for: oldValue, andDate: oldStatusEvaluationDate)
            oldStatus = status(for: oldValue)

            returnType = changes(&state)

            let newStatusEvaluationDate = Date()
            let newStatus = status(for: state)
            let newHighlight = buildPumpStatusHighlight(for: state, andDate: newStatusEvaluationDate)

            if oldStatus != newStatus || oldHighlight != newHighlight {
                shouldNotifyStatusUpdate = true
                state.lastStatusChange = newStatusEvaluationDate
            }
        }

        if oldValue.podState != newValue.podState {
            podStateObservers.forEach { (observer) in
                observer.podStateDidUpdate(newValue.podState)
            }

            if oldValue.podState?.lastInsulinMeasurements?.reservoirLevel != newValue.podState?.lastInsulinMeasurements?.reservoirLevel {
                if let lastInsulinMeasurements = newValue.podState?.lastInsulinMeasurements, let reservoirLevel = lastInsulinMeasurements.reservoirLevel {
                    self.pumpDelegate.notify({ (delegate) in
                        self.log.info("DU: updating reservoir level %{public}@", String(describing: reservoirLevel))
                        delegate?.pumpManager(self, didReadReservoirValue: reservoirLevel, at: lastInsulinMeasurements.validTime) { _ in }
                    })
                }
            }
        }

        // Ideally we ensure that oldValue.rawValue != newValue.rawValue, but the types aren't
        // defined as equatable
        pumpDelegate.notify { (delegate) in
            delegate?.pumpManagerDidUpdateState(self)
        }

        if let oldStatus = oldStatus, shouldNotifyStatusUpdate {
            notifyStatusObservers(oldStatus: oldStatus)
        }

        return returnType
    }

    private let lockedState: Locked<OmniBLEPumpManagerState>

    private let statusObservers = WeakSynchronizedSet<PumpManagerStatusObserver>()

    private func notifyStatusObservers(oldStatus: PumpManagerStatus) {
        let status = self.status
        pumpDelegate.notify { (delegate) in
            delegate?.pumpManager(self, didUpdate: status, oldStatus: oldStatus)
        }
        statusObservers.forEach { (observer) in
            observer.pumpManager(self, didUpdate: status, oldStatus: oldStatus)
        }
    }

    private func logDeviceCommunication(_ message: String, type: DeviceLogEntryType = .send) {
        var podAddress = "noPod"
        if let podState = self.state.podState {
            podAddress = String(format:"%04X", podState.address)
        }
        self.pumpDelegate.notify { (delegate) in
            delegate?.deviceManager(self, logEventForDeviceIdentifier: podAddress, type: type, message: message, completion: nil)
        }
    }
    
    // Not persisted
    var provideHeartbeat: Bool = false

    private var lastHeartbeat: Date = .distantPast
    
    public func setMustProvideBLEHeartbeat(_ mustProvideBLEHeartbeat: Bool) {
        provideHeartbeat = mustProvideBLEHeartbeat
    }

    private func issueHeartbeatIfNeeded() {
        if self.provideHeartbeat, dateGenerator().timeIntervalSince(lastHeartbeat) > .minutes(2) {
            self.pumpDelegate.notify { (delegate) in
                delegate?.pumpManagerBLEHeartbeatDidFire(self)
            }
            self.lastHeartbeat = Date()
        }
    }

    private let pumpDelegate = WeakSynchronizedDelegate<PumpManagerDelegate>()

    public let log = OSLog(category: "OmniBLEPumpManager")

    private var lastLoopRecommendation: Date?

    // MARK: - CustomDebugStringConvertible

    public var debugDescription: String {
        let lines = [
            "## OmniBLEPumpManager",
            "podComms: \(String(reflecting: podComms))",
            "provideHeartbeat: \(provideHeartbeat)",
            "state: \(String(reflecting: state))",
            "status: \(String(describing: status))",
            "podStateObservers.count: \(podStateObservers.cleanupDeallocatedElements().count)",
            "statusObservers.count: \(statusObservers.cleanupDeallocatedElements().count)",
        ]
        return lines.joined(separator: "\n")
    }
}

extension OmniBLEPumpManager {
    // MARK: - PodStateObserver

    public func addPodStateObserver(_ observer: PodStateObserver, queue: DispatchQueue) {
        podStateObservers.insert(observer, queue: queue)
    }

    public func removePodStateObserver(_ observer: PodStateObserver) {
        podStateObservers.removeElement(observer)
    }

    private func status(for state: OmniBLEPumpManagerState) -> PumpManagerStatus {
        return PumpManagerStatus(
            timeZone: state.timeZone,
            device: device(for: state),
            pumpBatteryChargeRemaining: nil,
            basalDeliveryState: basalDeliveryState(for: state),
            bolusState: bolusState(for: state),
            insulinType: state.insulinType
        )
    }

    private func device(for state: OmniBLEPumpManagerState) -> HKDevice {
        if let podState = state.podState {
            return HKDevice(
                name: managerIdentifier,
                manufacturer: "Insulet",
                model: "Dash",
                hardwareVersion: String(podState.productId),
                firmwareVersion: podState.firmwareVersion + " " + podState.bleFirmwareVersion,
                softwareVersion: String(OmniBLEVersionNumber),
                localIdentifier: String(format:"%04X", podState.address),
                udiDeviceIdentifier: nil
            )
        } else {
            return HKDevice(
                name: managerIdentifier,
                manufacturer: "Insulet",
                model: "Dash",
                hardwareVersion: nil,
                firmwareVersion: nil,
                softwareVersion: String(OmniBLEVersionNumber),
                localIdentifier: nil,
                udiDeviceIdentifier: nil
            )
        }
    }

    private func basalDeliveryState(for state: OmniBLEPumpManagerState) -> PumpManagerStatus.BasalDeliveryState {
        guard let podState = state.podState else {
            return .active(.distantPast)
        }

        switch podCommState(for: state) {
        case .fault:
            return .active(.distantPast)
        default:
            break
        }

        switch state.suspendEngageState {
        case .engaging:
            return .suspending
        case .disengaging:
            return .resuming
        case .stable:
            break
        }

        switch state.tempBasalEngageState {
        case .engaging:
            return .initiatingTempBasal
        case .disengaging:
            return .cancelingTempBasal
        case .stable:
            if let tempBasal = podState.unfinalizedTempBasal, !tempBasal.isFinished {
                return .tempBasal(DoseEntry(tempBasal))
            }
            switch podState.suspendState {
            case .resumed(let date):
                return .active(date)
            case .suspended(let date):
                return .suspended(date)
            }
        }
    }

    private func bolusState(for state: OmniBLEPumpManagerState) -> PumpManagerStatus.BolusState {
        guard let podState = state.podState else {
            return .noBolus
        }

        switch state.bolusEngageState {
        case .engaging:
            return .initiating
        case .disengaging:
            return .canceling
        case .stable:
            // TODO: need to evaluate isFinished at a particular date, instead of now()
            // as this function is called for old states, to compare to current state
            if let bolus = podState.unfinalizedBolus, !bolus.isFinished {
                return .inProgress(DoseEntry(bolus))
            }
        }
        return .noBolus
    }

    private func podCommState(for state: OmniBLEPumpManagerState) -> PodCommState {
        guard let podState = state.podState else {
            return .noPod
        }
        guard podState.fault == nil else {
            return .fault(podState.fault!)
        }

        if podState.isActive {
            return .active
        } else if !podState.isSetupComplete {
            return .activating
        }
        return .deactivating
    }

    public var podCommState: PodCommState {
        return podCommState(for: state)
    }

    public var podActivatedAt: Date? {
        return state.podState?.activatedAt
    }

    public var podExpiresAt: Date? {
        return state.podState?.expiresAt
    }

    public var hasActivePod: Bool {
        return state.hasActivePod
    }

    public var hasSetupPod: Bool {
        return state.hasSetupPod
    }

    // If time remaining is negative, the pod has been expired for that amount of time.
    public var podTimeRemaining: TimeInterval? {
        guard let expiresAt = state.podState?.expiresAt else { return nil }
        return expiresAt.timeIntervalSince(dateGenerator())
    }

    private var shouldWarnPodEOL: Bool {
        guard let podTimeRemaining = podTimeRemaining,
              podTimeRemaining > 0 && podTimeRemaining <= Pod.timeRemainingWarningThreshold else
        {
            return false
        }

        return true
    }

    public var durationBetweenLastPodCommAndActivation: TimeInterval? {
        guard let lastPodCommDate = state.podState?.lastInsulinMeasurements?.validTime,
              let activationTime = podActivatedAt else
        {
            return nil
        }

        return lastPodCommDate.timeIntervalSince(activationTime)
    }

    public var confirmationBeeps: Bool {
        get {
            return state.confirmationBeeps
        }
    }

    // From last status response
    public var reservoirLevel: ReservoirLevel? {
        return state.reservoirLevel
    }

    public var podTotalDelivery: HKQuantity? {
        guard let delivery = state.podState?.lastInsulinMeasurements?.delivered else {
            return nil
        }
        return HKQuantity(unit: .internationalUnit(), doubleValue: delivery)
    }

    public var lastStatusDate: Date? {
        guard let date = state.podState?.lastInsulinMeasurements?.validTime else {
            return nil
        }
        return date
    }

    public var defaultExpirationReminderOffset: TimeInterval {
        set {
            mutateState { (state) in
                state.defaultExpirationReminderOffset = newValue
            }
        }
        get {
            state.defaultExpirationReminderOffset
        }
    }

    public var lowReservoirReminderValue: Double {
        set {
            mutateState { (state) in
                state.lowReservoirReminderValue = newValue
            }
        }
        get {
            state.lowReservoirReminderValue
        }
    }

    public var podAttachmentConfirmed: Bool {
        set {
            mutateState { (state) in
                state.podAttachmentConfirmed = newValue
            }
        }
        get {
            state.podAttachmentConfirmed
        }
    }

    public var initialConfigurationCompleted: Bool {
        set {
            mutateState { (state) in
                state.initialConfigurationCompleted = newValue
            }
        }
        get {
            state.initialConfigurationCompleted
        }
    }

    public var expiresAt: Date? {
        return state.podState?.expiresAt
    }

    public var podDetails: PodDetails? {
        guard let podState = state.podState else {
            return nil
        }
        return PodDetails(
            lotNumber: podState.lotNo,
            sequenceNumber: podState.lotSeq,
            firmwareVersion: podState.firmwareVersion,
            bleFirmwareVersion: podState.bleFirmwareVersion,
            totalDelivery: podState.lastInsulinMeasurements?.delivered,
            lastStatus: podState.lastInsulinMeasurements?.validTime,
            fault: podState.fault?.faultEventCode
        )
    }

    public func buildPumpStatusHighlight(for state: OmniBLEPumpManagerState, andDate date: Date = Date()) -> PumpManagerStatus.PumpStatusHighlight? {
        if state.pendingCommand != nil {
            return PumpManagerStatus.PumpStatusHighlight(localizedMessage: NSLocalizedString("Comms Issue", comment: "Status highlight that delivery is uncertain."),
                                                         imageName: "exclamationmark.circle.fill",
                                                         state: .critical)
        }

        switch podCommState(for: state) {
        case .activating:
            return PumpManagerStatus.PumpStatusHighlight(
                localizedMessage: NSLocalizedString("Finish Pairing", comment: "Status highlight that when pod is activating."),
                imageName: "exclamationmark.circle.fill",
                state: .warning)
        case .deactivating:
            return PumpManagerStatus.PumpStatusHighlight(
                localizedMessage: NSLocalizedString("Finish Deactivation", comment: "Status highlight that when pod is deactivating."),
                imageName: "exclamationmark.circle.fill",
                state: .warning)
        case .noPod:
            return PumpManagerStatus.PumpStatusHighlight(
                localizedMessage: NSLocalizedString("No Pod", comment: "Status highlight that when no pod is paired."),
                imageName: "exclamationmark.circle.fill",
                state: .warning)
        case .fault(let detail):
            var message: String
            switch detail.faultEventCode.faultType {
            case .reservoirEmpty:
                message = LocalizedString("No Insulin", comment: "Status highlight message for emptyReservoir alarm.")
            case .exceededMaximumPodLife80Hrs:
                message = LocalizedString("Pod Expired", comment: "Status highlight message for podExpired alarm.")
            case .occluded:
                message = LocalizedString("Pod Occlusion", comment: "Status highlight message for occlusion alarm.")
            default:
                message = LocalizedString("Pod Error", comment: "Status highlight message for other alarm.")
            }
            return PumpManagerStatus.PumpStatusHighlight(
                localizedMessage: message,
                imageName: "exclamationmark.circle.fill",
                state: .critical)
        case .active:
            if let reservoirPercent = state.reservoirLevel?.percentage, reservoirPercent == 0 {
                return PumpManagerStatus.PumpStatusHighlight(
                    localizedMessage: NSLocalizedString("No Insulin", comment: "Status highlight that a pump is out of insulin."),
                    imageName: "exclamationmark.circle.fill",
                    state: .critical)
            } else if state.podState?.isSuspended == true {
                return PumpManagerStatus.PumpStatusHighlight(
                    localizedMessage: NSLocalizedString("Insulin Suspended", comment: "Status highlight that insulin delivery was suspended."),
                    imageName: "pause.circle.fill",
                    state: .warning)
            } else if date.timeIntervalSince(state.lastPumpDataReportDate ?? .distantPast) > .minutes(12) {
                return PumpManagerStatus.PumpStatusHighlight(
                    localizedMessage: NSLocalizedString("No Data", comment: "Status highlight when communications with the pod haven't happened recently."),
                    imageName: "exclamationmark.circle.fill",
                    state: .critical)
            }
            return nil
        }
    }

    public var reservoirLevelHighlightState: ReservoirLevelHighlightState? {
        guard let reservoirLevel = reservoirLevel else {
            return nil
        }

        switch reservoirLevel {
        case .aboveThreshold:
            return .normal
        case .valid(let value):
            if value > state.lowReservoirReminderValue {
                return .normal
            } else if value > 0 {
                return .warning
            } else {
                return .critical
            }
        }
    }

    public func buildPumpLifecycleProgress(for state: OmniBLEPumpManagerState) -> PumpManagerStatus.PumpLifecycleProgress? {
        switch podCommState {
        case .active:
            if shouldWarnPodEOL,
               let podTimeRemaining = podTimeRemaining
            {
                let percentCompleted = max(0, min(1, (1 - (podTimeRemaining / Pod.nominalPodLife))))
                return PumpManagerStatus.PumpLifecycleProgress(percentComplete: percentCompleted, progressState: .warning)
            } else if let podTimeRemaining = podTimeRemaining, podTimeRemaining <= 0 {
                // Pod is expired
                return PumpManagerStatus.PumpLifecycleProgress(percentComplete: 1, progressState: .critical)
            }
            return nil
        case .fault(let detail):
            if detail.faultEventCode.faultType == .exceededMaximumPodLife80Hrs {
                return PumpManagerStatus.PumpLifecycleProgress(percentComplete: 100, progressState: .critical)
            } else {
                if shouldWarnPodEOL,
                   let durationBetweenLastPodCommAndActivation = durationBetweenLastPodCommAndActivation
                {
                    let percentCompleted = max(0, min(1, durationBetweenLastPodCommAndActivation / Pod.nominalPodLife))
                    return PumpManagerStatus.PumpLifecycleProgress(percentComplete: percentCompleted, progressState: .dimmed)
                }
            }
            return nil
        case .noPod, .activating, .deactivating:
            return nil
        }
    }


    // MARK: - Pod comms

    // Does not support concurrent callers. Not thread-safe.
    public func forgetPod(completion: @escaping () -> Void) {

        self.podComms.forgetCurrentPod()

        let resetPodState = { (_ state: inout OmniBLEPumpManagerState) in
            if state.controllerId == CONTROLLER_ID {
                // Switch from using the common fixed controllerId to a created semi-unique one
                state.controllerId = createControllerId()
                state.podId = state.controllerId + 1
                self.log.info("Switched controllerId from %x to %x", CONTROLLER_ID, state.controllerId)
            } else {
                // Already have a created controllerId, just need to advance podId for the next pod
                let lastPodId = state.podId
                state.podId = nextPodId(lastPodId: lastPodId)
                self.log.info("Advanced podId from %x to %x", lastPodId, state.podId)
            }
            self.podComms.prepForNewPod(myId: state.controllerId, podId: state.podId)

            state.podState = nil
        }

        // TODO: PodState shouldn't be mutated outside of the session queue
        // TODO: Consider serializing the entire forget-pod path instead of relying on the UI to do it

        let state = mutateState { (state) in
            state.podState?.finalizeFinishedDoses()
        }

        if let dosesToStore = state.podState?.dosesToStore {
            store(doses: dosesToStore, completion: { error in
                self.setState({ (state) in
                    if error != nil {
                        state.unstoredDoses.append(contentsOf: dosesToStore)
                    }

                    resetPodState(&state)
                })
                completion()
            })
        } else {
            setState { (state) in
                resetPodState(&state)
            }

            completion()
        }
    }


    // MARK: Testing

    #if targetEnvironment(simulator)
    private func jumpStartPod(lotNo: UInt32, lotSeq: UInt32, fault: DetailedStatus? = nil, startDate: Date? = nil, mockFault: Bool) {
        let start = startDate ?? Date()
        let fakeLtk = Data(hexadecimalString: "fedcba98765432100123456789abcdef")!
        var podState = PodState(address: state.podId, ltk: fakeLtk,
            firmwareVersion: "jumpstarted", bleFirmwareVersion: "jumpstarted",
            lotNo: lotNo, lotSeq: lotSeq, productId: dashProductId,
            bleIdentifier: "0000-0000")

        podState.setupProgress = .podPaired
        podState.activatedAt = start
        podState.expiresAt = start + .hours(72)

        let fault = mockFault ? try? DetailedStatus(encodedData: Data(hexadecimalString: "020f0000000900345c000103ff0001000005ae056029")!) : nil
        podState.fault = fault

        self.podComms = PodComms(podState: podState, myId: state.controllerId, podId: state.podId)

        setState({ (state) in
            state.podState = podState
            state.scheduledExpirationReminderOffset = state.defaultExpirationReminderOffset
        })
    }
    #endif

    // MARK: - Pairing

    func connectToNewPod(completion: @escaping (Result<OmniBLE, Error>) -> Void) {
        podComms.connectToNewPod(completion)
    }

    // Called on the main thread
    public func pairAndPrime(completion: @escaping (PumpManagerResult<TimeInterval>) -> Void) {
        #if targetEnvironment(simulator)
        // If we're in the simulator, create a mock PodState
        let mockFaultDuringPairing = false
        let mockCommsErrorDuringPairing = false
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .seconds(2)) {
            self.jumpStartPod(lotNo: 135601809, lotSeq: 0800525, mockFault: mockFaultDuringPairing)
            let fault: DetailedStatus? = self.setStateWithResult({ (state) in
                state.podState?.setupProgress = .priming
                return state.podState?.fault
            })
            if mockFaultDuringPairing {
                // completion(.failure(PodCommsError.podFault(fault: fault!)))
            } else if mockCommsErrorDuringPairing {
                // completion(.failure(PodCommsError.noResponse))
            } else {
                let mockPrimeDuration = TimeInterval(.seconds(3))
                completion(.success(mockPrimeDuration))
            }
        }
        #else
        let primeSession = { (result: PodComms.SessionRunResult) in
            switch result {
            case .success(let session):
                // We're on the session queue
                session.assertOnSessionQueue()

                self.log.default("Beginning pod prime")

                // Clean up any previously un-stored doses if needed
                let unstoredDoses = self.state.unstoredDoses
                if self.store(doses: unstoredDoses, in: session) {
                    self.setState({ (state) in
                        state.unstoredDoses.removeAll()
                    })
                }

                do {
                    let primeFinishedAt = try session.prime()
                    completion(.success(primeFinishedAt))
                } catch let error {
                    completion(.failure(.communication(error as? LocalizedError)))
                }
            case .failure(let error):
                completion(.failure(.communication(error)))
            }
        }

        let needsPairing = setStateWithResult({ (state) -> Bool in
            guard let podState = state.podState else {
                return true // Needs pairing
            }

            // Return true if not yet paired
            return podState.setupProgress.isPaired == false
        })

        if needsPairing {

            self.log.default("Pairing pod before priming")

            connectToNewPod(completion: { result in
                switch result {
                case .failure(let error):
                    completion(.failure(.communication(error as? LocalizedError)))
                case .success:
                    self.podComms.pairAndSetupPod(timeZone: .currentFixed, messageLogger: self)
                    { (result) in

                        // Calls completion
                        primeSession(result)
                    }

                }

            })
        } else {
            self.log.default("Pod already paired. Continuing.")

            self.podComms.runSession(withName: "Prime pod") { (result) in
                // Calls completion
                primeSession(result)
            }
        }
        #endif
    }

    // Called on the main thread
    public func insertCannula(completion: @escaping (Result<TimeInterval,OmniBLEPumpManagerError>) -> Void) {
        #if targetEnvironment(simulator)
        let mockDelay = TimeInterval(seconds: 3)
        let mockFaultDuringInsertCannula = false
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + mockDelay) {
            let result = self.setStateWithResult({ (state) -> Result<TimeInterval,OmniBLEPumpManagerError> in
                if mockFaultDuringInsertCannula {
                    let fault = try! DetailedStatus(encodedData: Data(hexadecimalString: "020d0000000e00c36a020703ff020900002899080082")!)
                    state.podState?.fault = fault
                    // return .failure(PodCommsError.podFault(fault: fault))
                }

                // Mock success
                state.podState?.setupProgress = .completed
                return .success(mockDelay)
            })

            completion(result)
        }
        #else
        let preError = setStateWithResult({ (state) -> OmniBLEPumpManagerError? in
            guard let podState = state.podState, podState.readyForCannulaInsertion else
            {
                return .notReadyForCannulaInsertion
            }

            state.scheduledExpirationReminderOffset = state.defaultExpirationReminderOffset

            guard podState.setupProgress.needsCannulaInsertion else {
                return .podAlreadyPaired
            }

            return nil
        })

        if let error = preError {
            completion(.failure(.state(error)))
            return
        }

        let timeZone = self.state.timeZone

        self.podComms.runSession(withName: "Insert cannula") { (result) in
            switch result {
            case .success(let session):
                do {
                    if self.state.podState?.setupProgress.needsInitialBasalSchedule == true {
                        let scheduleOffset = timeZone.scheduleOffset(forDate: Date())
                        try session.programInitialBasalSchedule(self.state.basalSchedule, scheduleOffset: scheduleOffset)

                        session.dosesForStorage() { (doses) -> Bool in
                            return self.store(doses: doses, in: session)
                        }
                    }

                    let expiration = self.podExpiresAt ?? Date().addingTimeInterval(Pod.nominalPodLife)
                    let timeUntilExpirationReminder = expiration.addingTimeInterval(-self.state.defaultExpirationReminderOffset).timeIntervalSince(self.dateGenerator())

                    let alerts: [PodAlert] = [
                        .expirationReminder(timeUntilExpirationReminder),
                        .lowReservoir(self.state.lowReservoirReminderValue)
                    ]

                    let finishWait = try session.insertCannula(optionalAlerts: alerts)
                    completion(.success(finishWait))
                } catch let error {
                    completion(.failure(.communication(error)))
                }
            case .failure(let error):
                completion(.failure(.communication(error)))
            }
        }
        #endif
    }

    public func checkCannulaInsertionFinished(completion: @escaping (OmniBLEPumpManagerError?) -> Void) {
        self.podComms.runSession(withName: "Check cannula insertion finished") { (result) in
            switch result {
            case .success(let session):
                do {
                    try session.checkInsertionCompleted()
                    completion(nil)
                } catch let error {
                    self.log.error("Failed to fetch pod status: %{public}@", String(describing: error))
                    completion(.communication(error))
                }
            case .failure(let error):
                self.log.error("Failed to fetch pod status: %{public}@", String(describing: error))
                completion(.communication(error))
            }
        }
    }

    public func refreshStatus(emitConfirmationBeep: Bool = false, completion: ((_ result: PumpManagerResult<StatusResponse>) -> Void)? = nil) {
        guard self.hasActivePod else {
            completion?(.failure(.deviceState(OmniBLEPumpManagerError.noPodPaired)))
            return
        }

        self.getPodStatus(emitConfirmationBeep: emitConfirmationBeep, completion: completion)
    }

    public func getPodStatus(emitConfirmationBeep: Bool, completion: ((_ result: PumpManagerResult<StatusResponse>) -> Void)? = nil) {

        podComms.runSession(withName: "Get pod status") { (result) in
            do {
                switch result {
                case .success(let session):
                    let beepType: BeepConfigType? = self.confirmationBeeps && emitConfirmationBeep ? .bipBip : nil
                    let status = try session.getStatus(confirmationBeepType: beepType)
                    session.dosesForStorage({ (doses) -> Bool in
                        self.store(doses: doses, in: session)
                    })
                    completion?(.success(status))
                case .failure(let error):
                    self.evaluateStatus() 
                    throw error
                }
                self.issueHeartbeatIfNeeded()
            } catch let error {
                completion?(.failure(.communication(error as? LocalizedError)))
                self.log.error("Failed to fetch pod status: %{public}@", String(describing: error))
            }
        }
    }

    // MARK: - Pump Commands

    public func acknowledgePodAlerts(_ alertsToAcknowledge: AlertSet, completion: @escaping (_ alerts: [AlertSlot: PodAlert]?) -> Void) {
        guard self.hasActivePod else {
            completion(nil)
            return
        }

        self.podComms.runSession(withName: "Acknowledge Alarms") { (result) in
            let session: PodCommsSession
            switch result {
            case .success(let s):
                session = s
            case .failure:
                completion(nil)
                return
            }

            do {
                let beepType: BeepConfigType? = self.confirmationBeeps ? .bipBip : nil
                let alerts = try session.acknowledgePodAlerts(alerts: alertsToAcknowledge, confirmationBeepType: beepType)
                completion(alerts)
            } catch {
                completion(nil)
            }
        }
    }

    public func setTime(completion: @escaping (OmniBLEPumpManagerError?) -> Void) {

        guard state.hasActivePod else {
            completion(OmniBLEPumpManagerError.noPodPaired)
            return
        }

        guard state.podState?.unfinalizedBolus?.isFinished != false else {
            completion(.state(PodCommsError.unfinalizedBolus))
            return
        }

        let timeZone = TimeZone.currentFixed
        self.podComms.runSession(withName: "Set time zone") { (result) in
            switch result {
            case .success(let session):
                do {
                    let beep = self.confirmationBeeps
                    let _ = try session.setTime(timeZone: timeZone, basalSchedule: self.state.basalSchedule, date: Date(), acknowledgementBeep: beep, completionBeep: beep)
                    self.clearSuspendReminder()
                    self.setState { (state) in
                        state.timeZone = timeZone
                    }
                    completion(nil)
                } catch let error {
                    completion(.communication(error))
                }
            case .failure(let error):
                completion(.communication(error))
            }
        }
    }

    public func setBasalSchedule(_ schedule: BasalSchedule, completion: @escaping (Error?) -> Void) {
        let shouldContinue = setStateWithResult({ (state) -> PumpManagerResult<Bool> in
            guard state.hasActivePod else {
                // If there's no active pod yet, save the basal schedule anyway
                state.basalSchedule = schedule
                return .success(false)
            }

            guard state.podState?.unfinalizedBolus?.isFinished != false else {
                return .failure(.deviceState(PodCommsError.unfinalizedBolus))
            }

            return .success(true)
        })

        switch shouldContinue {
        case .success(true):
            break
        case .success(false):
            completion(nil)
            return
        case .failure(let error):
            completion(error)
            return
        }

        let timeZone = self.state.timeZone

        self.podComms.runSession(withName: "Save Basal Profile") { (result) in
            do {
                switch result {
                case .success(let session):
                    let scheduleOffset = timeZone.scheduleOffset(forDate: Date())
                    let result = session.cancelDelivery(deliveryType: .all)
                    switch result {
                    case .certainFailure(let error):
                        throw error
                    case .uncertainFailure(let error):
                        throw error
                    case .success:
                        break
                    }
                    let beep = self.confirmationBeeps
                    let _ = try session.setBasalSchedule(schedule: schedule, scheduleOffset: scheduleOffset, acknowledgementBeep: beep, completionBeep: beep)
                    self.clearSuspendReminder()

                    self.setState { (state) in
                        state.basalSchedule = schedule
                    }
                    completion(nil)
                case .failure(let error):
                    throw error
                }
            } catch let error {
                self.log.error("Save basal profile failed: %{public}@", String(describing: error))
                completion(error)
            }
        }
    }

    // Called on the main thread.
    // The UI is responsible for serializing calls to this method;
    // it does not handle concurrent calls.
    public func deactivatePod(completion: @escaping (OmniBLEPumpManagerError?) -> Void) {
        #if targetEnvironment(simulator)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .seconds(2)) {

            self.forgetPod(completion: {
                completion(nil)
            })
        }
        #else
        guard self.state.podState != nil else {
            completion(OmniBLEPumpManagerError.noPodPaired)
            return
        }

        self.podComms.runSession(withName: "Deactivate pod") { (result) in
            switch result {
            case .success(let session):
                do {
                    try session.deactivatePod()

                    self.forgetPod(completion: {
                        completion(nil)
                    })
                } catch let error {
                    completion(OmniBLEPumpManagerError.communication(error))
                }
            case .failure(let error):
                completion(OmniBLEPumpManagerError.communication(error))
            }
        }
        #endif
    }

    public func readPodStatus(completion: @escaping (Result<DetailedStatus, Error>) -> Void) {
        // use hasSetupPod to be able to read pod info from a faulted Pod
        guard self.hasSetupPod else {
            completion(.failure(OmniBLEPumpManagerError.noPodPaired))
            return
        }

        podComms.runSession(withName: "Read pod status") { (result) in
            do {
                switch result {
                case .success(let session):
                    let beepType: BeepConfigType? = self.confirmationBeeps ? .bipBip : nil
                    let detailedStatus = try session.getDetailedStatus(confirmationBeepType: beepType)
                    session.dosesForStorage({ (doses) -> Bool in
                        self.store(doses: doses, in: session)
                    })
                    completion(.success(detailedStatus))
                case .failure(let error):
                    completion(.failure(error))
                }
            } catch let error {
                completion(.failure(error))
            }
        }
    }

    public func testingCommands(completion: @escaping (Error?) -> Void) {
        // use hasSetupPod so the user can see any fault info and post fault commands can be attempted
        guard self.hasSetupPod else {
            completion(OmniBLEPumpManagerError.noPodPaired)
            return
        }

        self.podComms.runSession(withName: "Testing Commands") { (result) in
            switch result {
            case .success(let session):
                do {
                    let beepType: BeepConfigType? = self.confirmationBeeps ? .beepBeepBeep : nil
                    try session.testingCommands(confirmationBeepType: beepType)
                    completion(nil)
                } catch let error {
                    completion(error)
                }
            case .failure(let error):
                completion(error)
            }
        }
    }

    public func playTestBeeps(completion: @escaping (Error?) -> Void) {
        guard self.hasActivePod else {
            completion(OmniBLEPumpManagerError.noPodPaired)
            return
        }
        guard state.podState?.unfinalizedBolus?.scheduledCertainty == .uncertain || state.podState?.unfinalizedBolus?.isFinished != false else {
            self.log.info("Skipping Play Test Beeps due to bolus still in progress.")
            completion(PodCommsError.unfinalizedBolus)
            return
        }

        self.podComms.runSession(withName: "Play Test Beeps") { (result) in
            switch result {
            case .success(let session):
                let basalCompletionBeep = self.confirmationBeeps
                let tempBasalCompletionBeep = false
                let bolusCompletionBeep = self.confirmationBeeps
                let result = session.beepConfig(beepConfigType: .bipBeepBipBeepBipBeepBipBeep, basalCompletionBeep: basalCompletionBeep, tempBasalCompletionBeep: tempBasalCompletionBeep, bolusCompletionBeep: bolusCompletionBeep)

                switch result {
                case .success:
                    completion(nil)
                case .failure(let error):
                    completion(error)
                }
            case .failure(let error):
                completion(error)
            }
        }
    }

    public func readPulseLog(completion: @escaping (Result<String, Error>) -> Void) {
        // use hasSetupPod to be able to read pulse log from a faulted Pod
        guard self.hasSetupPod else {
            completion(.failure(OmniBLEPumpManagerError.noPodPaired))
            return
        }
        guard state.podState?.isFaulted == true || state.podState?.unfinalizedBolus?.scheduledCertainty == .uncertain || state.podState?.unfinalizedBolus?.isFinished != false else
        {
            self.log.info("Skipping Read Pulse Log due to bolus still in progress.")
            completion(.failure(PodCommsError.unfinalizedBolus))
            return
        }

        self.podComms.runSession(withName: "Read Pulse Log") { (result) in
            switch result {
            case .success(let session):
                do {
                    // read the most recent 50 entries from the pulse log
                    let beepType: BeepConfigType? = self.confirmationBeeps ? .bipBeeeeep : nil
                    let podInfoResponse = try session.readPodInfo(podInfoResponseSubType: .pulseLogRecent, confirmationBeepType: beepType)
                    guard let podInfoPulseLogRecent = podInfoResponse.podInfo as? PodInfoPulseLogRecent else {
                        self.log.error("Unable to decode PulseLogRecent: %s", String(describing: podInfoResponse))
                        completion(.failure(PodCommsError.unexpectedResponse(response: .podInfoResponse)))
                        return
                    }
                    let lastPulseNumber = Int(podInfoPulseLogRecent.indexLastEntry)
                    let str = pulseLogString(pulseLogEntries: podInfoPulseLogRecent.pulseLog, lastPulseNumber: lastPulseNumber)
                    completion(.success(str))
                } catch let error {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    public func setConfirmationBeeps(enabled: Bool, completion: @escaping (OmniBLEPumpManagerError?) -> Void) {
        self.log.default("Set Confirmation Beeps to %s", String(describing: enabled))
        guard self.hasActivePod else {
            self.setState { state in
                state.confirmationBeeps = enabled // set here to allow changes on a faulted Pod
            }
            completion(nil)
            return
        }

        let name: String = enabled ? "Enable Confirmation Beeps" : "Disable Confirmation Beeps"
        self.podComms.runSession(withName: name) { (result) in
            switch result {
            case .success(let session):
                let beepConfigType: BeepConfigType = enabled ? .bipBip : .noBeep
                let basalCompletionBeep = enabled
                let tempBasalCompletionBeep = false
                let bolusCompletionBeep = enabled

                // enable/disable Pod completion beeps for any in-progress insulin delivery
                let result = session.beepConfig(beepConfigType: beepConfigType, basalCompletionBeep: basalCompletionBeep, tempBasalCompletionBeep: tempBasalCompletionBeep, bolusCompletionBeep: bolusCompletionBeep)

                switch result {
                case .success:
                    self.setState { state in
                        state.confirmationBeeps = enabled // set here to allow changes on a faulted Pod
                    }
                    completion(nil)
                case .failure(let error):
                    completion(.communication(error))
                }
            case .failure(let error):
                completion(.communication(error))
            }
        }
    }

    // Reconnected to the pod, and we know program was successful
    private func pendingCommandSucceeded(pendingCommand: PendingCommand, podStatus: StatusResponse) {
//        self.mutateState { (state) in
//            switch pendingCommand {
//            case .program(let program, let commandDate):
//                if let dose = program.unfinalizedDose(at: commandDate, withCertainty: .certain) {
//                    if dose.isFinished {
//                        state.podState?.finalizedDoses.append(dose)
//                        if case .resume = dose.doseType {
//                            state.suspendState = .resumed(commandDate)
//                        }
//                    } else {
//                        switch dose.doseType {
//                        case .bolus:
//                            state.unfinalizedBolus = dose
//                        case .tempBasal:
//                            state.unfinalizedTempBasal = dose
//                        default:
//                            break
//                        }
//                    }
//                    state.updateFromPodStatus(status: podStatus)
//                }
//            case .stopProgram(let stopProgram, let commandDate):
//                var bolusCancel = false
//                var tempBasalCancel = false
//                var didSuspend = false
//                switch stopProgram {
//                case .bolus:
//                    bolusCancel = true
//                case .tempBasal:
//                    tempBasalCancel = true
//                case .stopAll:
//                    bolusCancel = true
//                    tempBasalCancel = true
//                    didSuspend = true
//                }
//
//                if bolusCancel, let bolus = state.unfinalizedBolus, !bolus.isFinished(at: commandDate) {
//                    state.unfinalizedBolus?.cancel(at: commandDate, withRemaining: podStatus.bolusUnitsRemaining)
//                }
//                if tempBasalCancel, let tempBasal = state.unfinalizedTempBasal, !tempBasal.isFinished(at: commandDate) {
//                    state.unfinalizedTempBasal?.cancel(at: commandDate)
//                }
//                if didSuspend {
//                    state.finishedDoses.append(UnfinalizedDose(suspendStartTime: commandDate, scheduledCertainty: .certain))
//                    state.suspendState = .suspended(commandDate)
//                }
//                state.updateFromPodStatus(status: podStatus)
//            }
//        }
//        self.finalizeAndStoreDoses()
    }

    // Reconnected to the pod, and we know program was not received
    private func pendingCommandFailed(pendingCommand: PendingCommand, podStatus: StatusResponse) {
//        // Nothing to do besides update using the pod status, because we already responded to Loop as if the commands failed.
//        self.mutateState({ (state) in
//            state.updateFromPodStatus(status: podStatus)
//        })
//        self.finalizeAndStoreDoses()
    }

    // Giving up on pod; we will assume commands failed/succeeded in the direction of positive net delivery
    private func resolveAnyPendingCommandWithUncertainty() {
//        guard let pendingCommand = state.pendingCommand else {
//            return
//        }
//
//        var calendar = Calendar(identifier: .gregorian)
//        calendar.timeZone = state.timeZone
//
//        self.mutateState { (state) in
//            switch pendingCommand {
//            case .program(let program, let commandDate):
//                let scheduledSegmentAtCommandTime = state.basalProgram.currentRate(using: calendar, at: commandDate)
//
//                if let dose = program.unfinalizedDose(at: commandDate, withCertainty: .uncertain) {
//                    switch dose.doseType {
//                    case .bolus:
//                        if dose.isFinished(at: dateGenerator()) {
//                            state.finishedDoses.append(dose)
//                        } else {
//                            state.unfinalizedBolus = dose
//                        }
//                    case .tempBasal:
//                        // Assume a high temp succeeded, but low temp failed
//                        let rate = dose.programmedRate ?? dose.rate
//                        if rate > scheduledSegmentAtCommandTime.basalRateUnitsPerHour {
//                            if dose.isFinished(at: dateGenerator()) {
//                                state.finishedDoses.append(dose)
//                            } else {
//                                state.unfinalizedTempBasal = dose
//                            }
//                        }
//                    case .resume:
//                        state.finishedDoses.append(dose)
//                    case .suspend:
//                        break // start program is never a suspend
//                    }
//                }
//            case .stopProgram(let stopProgram, let commandDate):
//                let scheduledSegmentAtCommandTime = state.basalProgram.currentRate(using: calendar, at: commandDate)
//
//                // All stop programs result in reduced delivery, except for stopping a low temp, so we assume all stop
//                // commands failed, except for low temp
//                var tempBasalCancel = false
//
//                switch stopProgram {
//                case .tempBasal:
//                    tempBasalCancel = true
//                case .stopAll:
//                    tempBasalCancel = true
//                default:
//                    break
//                }
//
//                if tempBasalCancel,
//                    let tempBasal = state.unfinalizedTempBasal,
//                    !tempBasal.isFinished(at: commandDate),
//                    (tempBasal.programmedRate ?? tempBasal.rate) < scheduledSegmentAtCommandTime.basalRateUnitsPerHour
//                {
//                    state.unfinalizedTempBasal?.cancel(at: commandDate)
//                }
//            }
//            state.pendingCommand = nil
//        }
    }

    public func attemptUnacknowledgedCommandRecovery() {
//        if let pendingCommand = self.state.pendingCommand {
//            podCommManager.queryAndClearUnacknowledgedCommand { (result) in
//                switch result {
//                case .success(let retryResult):
//                    if retryResult.hasPendingCommandProgrammed {
//                        self.pendingCommandSucceeded(pendingCommand: pendingCommand, podStatus: retryResult.status)
//                    } else {
//                        self.pendingCommandFailed(pendingCommand: pendingCommand, podStatus: retryResult.status)
//                    }
//                    self.mutateState { (state) in
//                        state.pendingCommand = nil
//                    }
//                case .failure:
//                    break
//                }
//            }
//        }
    }

}

// MARK: - PumpManager
extension OmniBLEPumpManager: PumpManager {

    public static var onboardingMaximumBasalScheduleEntryCount: Int {
        return Pod.maximumBasalScheduleEntryCount
    }

    public static var onboardingSupportedMaximumBolusVolumes: [Double] {
        return onboardingSupportedBolusVolumes
    }

    public var supportedMaximumBolusVolumes: [Double] {
        return supportedBolusVolumes
    }

    public static var onboardingSupportedBolusVolumes: [Double] {
        // 0.05 units for rates between 0.05-30U/hr
        // 0 is not a supported bolus volume
        return (1...600).map { Double($0) / Double(Pod.pulsesPerUnit) }
    }

    public var supportedBolusVolumes: [Double] {
        // 0.05 units for rates between 0.05-30U/hr
        // 0 is not a supported bolus volume
        return (1...600).map { Double($0) / Double(Pod.pulsesPerUnit) }
    }

    public static var onboardingSupportedBasalRates: [Double] {
        // 0.05 units for rates between 0.05-30U/hr
        // 0 U/hr is not a supported scheduled basal rate for Eros, but it is for Dash
        return (1...600).map { Double($0) / Double(Pod.pulsesPerUnit) }
    }

    public var supportedBasalRates: [Double] {
        // 0.05 units for rates between 0.05-30U/hr
        // 0 is not a supported scheduled basal rate
        return (1...600).map { Double($0) / Double(Pod.pulsesPerUnit) }
    }

    public func roundToSupportedBolusVolume(units: Double) -> Double {
        // We do support rounding a 0 U volume to 0
        return supportedBolusVolumes.last(where: { $0 <= units }) ?? 0
    }

    public func roundToSupportedBasalRate(unitsPerHour: Double) -> Double {
        // We do support rounding a 0 U/hr rate to 0
        return supportedBasalRates.last(where: { $0 <= unitsPerHour }) ?? 0
    }

    public var maximumBasalScheduleEntryCount: Int {
        return Pod.maximumBasalScheduleEntryCount
    }

    public var minimumBasalScheduleEntryDuration: TimeInterval {
        return Pod.minimumBasalScheduleEntryDuration
    }

    public var pumpRecordsBasalProfileStartEvents: Bool {
        return false
    }

    public var pumpReservoirCapacity: Double {
        return Pod.reservoirCapacity
    }

    public var isOnboarded: Bool { state.isOnboarded }

    public var insulinType: InsulinType? {
        get {
            return self.state.insulinType
        }
        set {
            if let insulinType = newValue {
                self.setState { (state) in
                    state.insulinType = insulinType
                }
                //self.podComms.insulinType = insulinType
            }
        }
    }

    public var lastSync: Date? {
        return self.state.podState?.lastInsulinMeasurements?.validTime
    }

    public var status: PumpManagerStatus {
        // Acquire the lock just once
        let state = self.state

        return status(for: state)
    }

    public var rawState: PumpManager.RawStateValue {
        return state.rawValue
    }

    public var pumpManagerDelegate: PumpManagerDelegate? {
        get {
            return pumpDelegate.delegate
        }
        set {
            pumpDelegate.delegate = newValue
        }
    }

    public var delegateQueue: DispatchQueue! {
        get {
            return pumpDelegate.queue
        }
        set {
            pumpDelegate.queue = newValue
        }
    }

    // MARK: Methods

    public func completeOnboard() {
        setState({ (state) in
            state.isOnboarded = true
        })
    }
    
    public func suspendDelivery(completion: @escaping (Error?) -> Void) {
        let suspendTime: TimeInterval = .minutes(0) // untimed suspend with reminder beeps
        suspendDelivery(withSuspendReminders: suspendTime, completion: completion)
    }

    // A nil suspendReminder is untimed with no reminders beeps, a suspendReminder of 0 is untimed using reminders beeps, otherwise it
    // specifies a suspend duration implemented using an appropriate combination of suspended reminder and suspend time expired beeps.
    public func suspendDelivery(withSuspendReminders suspendReminder: TimeInterval? = nil, completion: @escaping (Error?) -> Void) {
        guard self.hasActivePod else {
            completion(OmniBLEPumpManagerError.noPodPaired)
            return
        }

        self.podComms.runSession(withName: "Suspend") { (result) in

            let session: PodCommsSession
            switch result {
            case .success(let s):
                session = s
            case .failure(let error):
                completion(error)
                return
            }

            defer {
                self.setState({ (state) in
                    state.suspendEngageState = .stable
                })
            }
            self.setState({ (state) in
                state.suspendEngageState = .engaging
            })

            // use confirmationBeepType here for confirmation beeps to avoid getting 3 beeps!
            let beepType: BeepConfigType? = self.confirmationBeeps ? .beeeeeep : nil
            let result = session.suspendDelivery(suspendReminder: suspendReminder, confirmationBeepType: beepType)
            switch result {
            case .certainFailure(let error):
                completion(error)
            case .uncertainFailure(let error):
                completion(error)
            case .success:
                session.dosesForStorage() { (doses) -> Bool in
                    return self.store(doses: doses, in: session)
                }
                completion(nil)
            }
        }
    }

    public func resumeDelivery(completion: @escaping (Error?) -> Void) {
        guard self.hasActivePod else {
            completion(OmniBLEPumpManagerError.noPodPaired)
            return
        }

        self.podComms.runSession(withName: "Resume") { (result) in

            let session: PodCommsSession
            switch result {
            case .success(let s):
                session = s
            case .failure(let error):
                completion(error)
                return
            }

            defer {
                self.setState({ (state) in
                    state.suspendEngageState = .stable
                })
            }

            self.setState({ (state) in
                state.suspendEngageState = .disengaging
            })

            do {
                let scheduleOffset = self.state.timeZone.scheduleOffset(forDate: Date())
                let beep = self.confirmationBeeps
                let _ = try session.resumeBasal(schedule: self.state.basalSchedule, scheduleOffset: scheduleOffset, acknowledgementBeep: beep, completionBeep: beep)
                self.clearSuspendReminder()
                session.dosesForStorage() { (doses) -> Bool in
                    return self.store(doses: doses, in: session)
                }
                completion(nil)
            } catch (let error) {
                completion(error)
            }
        }
    }

    fileprivate func clearSuspendReminder() {
        self.pumpDelegate.notify { (delegate) in
            delegate?.retractAlert(identifier: Alert.Identifier(managerIdentifier: self.managerIdentifier, alertIdentifier: PumpManagerAlert.suspendEnded(triggeringSlot: nil).alertIdentifier))
            delegate?.retractAlert(identifier: Alert.Identifier(managerIdentifier: self.managerIdentifier, alertIdentifier: PumpManagerAlert.suspendEnded(triggeringSlot: nil).repeatingAlertIdentifier))
        }
    }

    public func addStatusObserver(_ observer: PumpManagerStatusObserver, queue: DispatchQueue) {
        statusObservers.insert(observer, queue: queue)
    }

    public func removeStatusObserver(_ observer: PumpManagerStatusObserver) {
        statusObservers.removeElement(observer)
    }
    
    public func ensureCurrentPumpData(completion: ((Date?) -> Void)?) {
        let shouldFetchStatus = setStateWithResult { (state) -> Bool? in
            guard state.hasActivePod else {
                return nil // No active pod
            }

            return state.isPumpDataStale
        }

        switch shouldFetchStatus {
        case .none:
            completion?(lastSync)
            return // No active pod
        case true?:
            log.default("Fetching status because pumpData is too old")
            getPodStatus(emitConfirmationBeep: false) { (response) in
                completion?(self.lastSync)
            }
        case false?:
            log.default("Skipping status update because pumpData is fresh")
            completion?(self.lastSync)
        }
    }


    // MARK: - Programming Delivery

    public func enactBolus(units: Double, automatic: Bool, completion: @escaping (PumpManagerError?) -> Void) {
        guard self.hasActivePod else {
            completion(.configuration(OmniBLEPumpManagerError.noPodPaired))
            return
        }

        // Round to nearest supported volume
        let enactUnits = roundToSupportedBolusVolume(units: units)

        self.podComms.runSession(withName: "Bolus") { (result) in
            let session: PodCommsSession
            switch result {
            case .success(let s):
                session = s
            case .failure(let error):
                completion(.communication(error))
                return
            }

            defer {
                self.setState({ (state) in
                    state.bolusEngageState = .stable
                })
            }
            self.setState({ (state) in
                state.bolusEngageState = .engaging
            })

            var podStatus: StatusResponse

            do {
                podStatus = try session.getStatus()
            } catch let error {
                completion(.communication(error as? LocalizedError))
                return
            }

            // If pod suspended, resume basal before bolusing
            if podStatus.deliveryStatus == .suspended {
                do {
                    let scheduleOffset = self.state.timeZone.scheduleOffset(forDate: Date())
                    let beep = self.confirmationBeeps
                    let podStatus = try session.resumeBasal(schedule: self.state.basalSchedule, scheduleOffset: scheduleOffset, acknowledgementBeep: beep, completionBeep: beep)
                    self.clearSuspendReminder()
                    guard podStatus.deliveryStatus.bolusing == false else {
                        throw PodCommsError.unfinalizedBolus
                    }
                } catch let error {
                    completion(.deviceState(error as? LocalizedError))
                    return
                }
            }

            guard !podStatus.deliveryStatus.bolusing else {
                completion(.deviceState(PodCommsError.unfinalizedBolus))
                return
            }

            let beep = self.confirmationBeeps

            // Use the bits for the program reminder interval (not needed for a bolus command)
            //
            // This trick enables determination, from the hex message format of the log file,
            //   whether this bolus was initiated by the user or automatically by Loop
            let bolusWasAutomaticIndicator: TimeInterval = automatic ? TimeInterval(minutes: 0x3F) : 0

            let result = session.bolus(units: enactUnits, automatic: automatic, acknowledgementBeep: beep, completionBeep: beep, programReminderInterval:  bolusWasAutomaticIndicator)
            session.dosesForStorage() { (doses) -> Bool in
                return self.store(doses: doses, in: session)
            }

            switch result {
            case .success:
                completion(nil)
            case .certainFailure(let error):
                completion(.communication(error))
            case .uncertainFailure(let error):
                // TODO: Return PumpManagerError.uncertainDelivery and implement recovery
                completion(.communication(error))
            }
        }
    }

    public func cancelBolus(completion: @escaping (PumpManagerResult<DoseEntry?>) -> Void) {
        guard self.hasActivePod else {
            completion(.failure(.deviceState(OmniBLEPumpManagerError.noPodPaired)))
            return
        }

        self.podComms.runSession(withName: "Cancel Bolus") { (result) in

            let session: PodCommsSession
            switch result {
            case .success(let s):
                session = s
            case .failure(let error):
                completion(.failure(.communication(error)))
                return
            }

            do {
                defer {
                    self.setState({ (state) in
                        state.bolusEngageState = .stable
                    })
                }
                self.setState({ (state) in
                    state.bolusEngageState = .disengaging
                })

                if let bolus = self.state.podState?.unfinalizedBolus, !bolus.isFinished, bolus.scheduledCertainty == .uncertain {
                    let status = try session.getStatus()

                    if !status.deliveryStatus.bolusing {
                        completion(.success(nil))
                        return
                    }
                }

                // when cancelling a bolus use the built-in type 6 beeeeeep to match PDM if confirmation beeps are enabled
                let beeptype: BeepType = self.confirmationBeeps ? .beeeeeep : .noBeep
                let result = session.cancelDelivery(deliveryType: .bolus, beepType: beeptype)
                switch result {
                case .certainFailure(let error):
                    throw error
                case .uncertainFailure(let error):
                    throw error
                case .success(_, let canceledBolus):
                    session.dosesForStorage() { (doses) -> Bool in
                        return self.store(doses: doses, in: session)
                    }

                    let canceledDoseEntry: DoseEntry? = canceledBolus != nil ? DoseEntry(canceledBolus!) : nil
                    completion(.success(canceledDoseEntry))
                }
            } catch {
                completion(.failure(.communication(error as? LocalizedError)))
            }
        }
    }

    public func enactTempBasal(unitsPerHour: Double, for duration: TimeInterval, completion: @escaping (PumpManagerError?) -> Void) {
        guard self.hasActivePod else {
            completion(.deviceState(OmniBLEPumpManagerError.noPodPaired))
            return
        }

        // Round to nearest supported rate
        let rate = roundToSupportedBasalRate(unitsPerHour: unitsPerHour)

        self.podComms.runSession(withName: "Enact Temp Basal") { (result) in
            self.log.info("Enact temp basal %.03fU/hr for %ds", rate, Int(duration))
            let session: PodCommsSession
            switch result {
            case .success(let s):
                session = s
            case .failure(let error):
                completion(.communication(error))
                return
            }

            do {
                if case .some(.suspended) = self.state.podState?.suspendState {
                    self.log.info("Not enacting temp basal because podState indicates pod is suspended.")
                    throw PodCommsError.podSuspended
                }

                guard self.state.podState?.unfinalizedBolus?.isFinished != false else {
                    self.log.info("Not enacting temp basal because podState indicates unfinalized bolus in progress.")
                    throw PodCommsError.unfinalizedBolus
                }

                let status: StatusResponse

                // if resuming a normal basal as denoted by a 0 duration temp basal, use a confirmation beep if appropriate
                //let beep: BeepType = duration < .ulpOfOne && self.confirmationBeeps && tempBasalConfirmationBeeps ? .beep : .noBeep
                let result = session.cancelDelivery(deliveryType: .tempBasal, beepType: .noBeep)
                switch result {
                case .certainFailure(let error):
                    throw error
                case .uncertainFailure(let error):
                    throw error
                case .success(let cancelTempStatus, _):
                    status = cancelTempStatus
                }

                guard !status.deliveryStatus.bolusing else {
                    throw PodCommsError.unfinalizedBolus
                }

                guard status.deliveryStatus != .suspended else {
                    self.log.info("Canceling temp basal because status return indicates pod is suspended.")
                    throw PodCommsError.podSuspended
                }

                defer {
                    self.setState({ (state) in
                        state.tempBasalEngageState = .stable
                    })
                }

                if duration < .ulpOfOne {
                    // 0 duration temp basals are used to cancel any existing temp basal
                    self.setState({ (state) in
                        state.tempBasalEngageState = .disengaging
                    })
                    session.dosesForStorage() { (doses) -> Bool in
                        return self.store(doses: doses, in: session)
                    }
                    completion(nil)
                } else {
                    self.setState({ (state) in
                        state.tempBasalEngageState = .engaging
                    })

                    let result = session.setTempBasal(rate: rate, duration: duration, acknowledgementBeep: false, completionBeep: false)
                    session.dosesForStorage() { (doses) -> Bool in
                        return self.store(doses: doses, in: session)
                    }
                    switch result {
                    case .success:
                        completion(nil)
                    case .uncertainFailure(let error):
                        self.log.error("Temp basal uncertain error: %@", String(describing: error))
                        completion(nil)
                    case .certainFailure(let error):
                        completion(.communication(error))
                    }
                }
            } catch let error {
                self.log.error("Error during temp basal: %@", String(describing: error))
                completion(.communication(error as? LocalizedError))
            }
        }
    }

    /// Returns a dose estimator for the current bolus, if one is in progress
    public func createBolusProgressReporter(reportingOn dispatchQueue: DispatchQueue) -> DoseProgressReporter? {
        if case .inProgress(let dose) = bolusState(for: self.state) {
            return PodDoseProgressEstimator(dose: dose, pumpManager: self, reportingQueue: dispatchQueue)
        }
        return nil
    }

    public func syncBasalRateSchedule(items scheduleItems: [RepeatingScheduleValue<Double>], completion: @escaping (Result<BasalRateSchedule, Error>) -> Void) {
        let newSchedule = BasalSchedule(repeatingScheduleValues: scheduleItems)
        setBasalSchedule(newSchedule) { (error) in
            if let error = error {
                completion(.failure(error))
            } else {
                completion(.success(BasalRateSchedule(dailyItems: scheduleItems, timeZone: self.state.timeZone)!))
            }
        }
    }

    // Delivery limits are not enforced/displayed on omnipods
    public func syncDeliveryLimits(limits deliveryLimits: DeliveryLimits, completion: @escaping (Result<DeliveryLimits, Error>) -> Void) {
        completion(.success(deliveryLimits))
    }


    // MARK: - Alerts

    public var isClockOffset: Bool {
        let now = dateGenerator()
        return TimeZone.current.secondsFromGMT(for: now) != state.timeZone.secondsFromGMT(for: now)
    }

    func checkForTimeOffsetChange() {
        let isAlertActive = state.activeAlerts.contains(.timeOffsetChangeDetected)

        if !isAlertActive && isClockOffset && !state.acknowledgedTimeOffsetAlert {
            issueAlert(alert: .timeOffsetChangeDetected)
        } else if isAlertActive && !isClockOffset {
            retractAlert(alert: .timeOffsetChangeDetected)
        }
    }

    public func updateExpirationReminder(_ intervalBeforeExpiration: TimeInterval, completion: @escaping (OmniBLEPumpManagerError?) -> Void) {

        guard self.hasActivePod, let podState = state.podState, let expiresAt = podState.expiresAt else {
            completion(OmniBLEPumpManagerError.noPodPaired)
            return
        }

        self.podComms.runSession(withName: "Program Low Reservoir Reminder") { (result) in

            let session: PodCommsSession
            switch result {
            case .success(let s):
                session = s
            case .failure(let error):
                completion(.communication(error))
                return
            }

            let timeUntilReminder = expiresAt.addingTimeInterval(-intervalBeforeExpiration).timeIntervalSince(self.dateGenerator())

            let expirationReminder = PodAlert.expirationReminder(timeUntilReminder)
            do {
                try session.configureAlerts([expirationReminder], confirmationBeepType: self.confirmationBeeps ? .beep : .noBeep)
                self.mutateState({ (state) in
                    state.scheduledExpirationReminderOffset = intervalBeforeExpiration
                })
                completion(nil)
            } catch {
                completion(.communication(error))
                return
            }
        }
    }

    public var allowedExpirationReminderDates: [Date]? {
        guard let expiration = state.podState?.expiresAt else {
            return nil
        }

        let allDates = Array(stride(
            from: -Pod.expirationReminderAlertMaxHoursBeforeExpiration,
            through: -Pod.expirationReminderAlertMinHoursBeforeExpiration,
            by: 1)).map
        { (i: Int) -> Date in
            expiration.addingTimeInterval(.hours(Double(i)))
        }
        let now = dateGenerator()
        return allDates.filter { $0.timeIntervalSince(now) > 0 }
    }

    public var scheduledExpirationReminder: Date? {
        guard let expiration = state.podState?.expiresAt, let offset = state.scheduledExpirationReminderOffset else {
            return nil
        }

        // It is possible the scheduledExpirationReminderOffset does not fall on the hour, but instead be a few seconds off
        // since the allowedExpirationReminderDates are by the hour, force the offset to be on the hour
        return expiration.addingTimeInterval(-.hours(round(offset.hours)))
    }

    public func updateLowReservoirReminder(_ value: Int, completion: @escaping (OmniBLEPumpManagerError?) -> Void) {
        guard self.hasActivePod else {
            completion(OmniBLEPumpManagerError.noPodPaired)
            return
        }

        self.podComms.runSession(withName: "Program Low Reservoir Reminder") { (result) in

            let session: PodCommsSession
            switch result {
            case .success(let s):
                session = s
            case .failure(let error):
                completion(.communication(error))
                return
            }

            let lowReservoirReminder = PodAlert.lowReservoir(Double(value))
            do {
                try session.configureAlerts([lowReservoirReminder], confirmationBeepType: self.confirmationBeeps ? .beep : .noBeep)
                self.mutateState({ (state) in
                    state.lowReservoirReminderValue = Double(value)
                })
                completion(nil)
            } catch {
                completion(.communication(error))
                return
            }
        }
    }



    func issueAlert(alert: PumpManagerAlert) {
        let identifier = Alert.Identifier(managerIdentifier: self.managerIdentifier, alertIdentifier: alert.alertIdentifier)
        let loopAlert = Alert(identifier: identifier, foregroundContent: alert.foregroundContent, backgroundContent: alert.backgroundContent, trigger: .immediate)
        pumpDelegate.notify { (delegate) in
            delegate?.issueAlert(loopAlert)
        }

        if let repeatInterval = alert.repeatInterval {
            // Schedule an additional repeating 15 minute reminder for suspend period ended.
            let repeatingIdentifier = Alert.Identifier(managerIdentifier: self.managerIdentifier, alertIdentifier: alert.repeatingAlertIdentifier)
            let loopAlert = Alert(identifier: repeatingIdentifier, foregroundContent: alert.foregroundContent, backgroundContent: alert.backgroundContent, trigger: .repeating(repeatInterval: repeatInterval))
            pumpDelegate.notify { (delegate) in
                delegate?.issueAlert(loopAlert)
            }
        }

        self.mutateState { (state) in
            state.activeAlerts.insert(alert)
        }
    }

    func retractAlert(alert: PumpManagerAlert) {
        let identifier = Alert.Identifier(managerIdentifier: self.managerIdentifier, alertIdentifier: alert.alertIdentifier)
        pumpDelegate.notify { (delegate) in
            delegate?.retractAlert(identifier: identifier)
        }
        if alert.isRepeating {
            let repeatingIdentifier = Alert.Identifier(managerIdentifier: self.managerIdentifier, alertIdentifier: alert.repeatingAlertIdentifier)
            pumpDelegate.notify { (delegate) in
                delegate?.retractAlert(identifier: repeatingIdentifier)
            }
        }
        self.mutateState { (state) in
            state.activeAlerts.remove(alert)
        }
    }

    private func alertsChanged(oldAlerts: AlertSet, newAlerts: AlertSet) {
        guard let podState = state.podState else {
            preconditionFailure("trying to manage alerts without podState")
        }

        let (added, removed) = oldAlerts.compare(to: newAlerts)
        for slot in added {
            if let podAlert = podState.configuredAlerts[slot] {
                log.default("*** Alert slot triggered: %{public}@", String(describing: slot))
                if let pumpManagerAlert = getPumpManagerAlert(for: podAlert, slot: slot) {
                    issueAlert(alert: pumpManagerAlert)
                } else {
                    log.default("Ignoring alert: %{public}@", String(describing: podAlert))
                }
            } else {
                log.error("Unconfigured alert slot triggered: %{public}@", String(describing: slot))
            }
        }
        for alert in removed {
            log.default("*** Alert slot cleared: %{public}@", String(describing: alert))
        }
    }

    private func getPumpManagerAlert(for podAlert: PodAlert, slot: AlertSlot) -> PumpManagerAlert? {
        guard let podState = state.podState, let expiresAt = podState.expiresAt else {
            preconditionFailure("trying to lookup alert info without podState")
        }

        guard !podAlert.isIgnored else {
            return nil
        }

        switch podAlert {
        case .podSuspendedReminder:
            return PumpManagerAlert.suspendInProgress(triggeringSlot: slot)
        case .expirationReminder:
            let timeToExpiry = TimeInterval(hours: expiresAt.timeIntervalSince(dateGenerator()).hours.rounded())
            return PumpManagerAlert.userPodExpiration(triggeringSlot: slot, scheduledExpirationReminderOffset: timeToExpiry)
        case .expired:
            return PumpManagerAlert.podExpiring(triggeringSlot: slot)
        case .shutdownImminent:
            return PumpManagerAlert.podExpireImminent(triggeringSlot: slot)
        case .lowReservoir(let units):
            return PumpManagerAlert.lowReservoir(triggeringSlot: slot, lowReservoirReminderValue: units)
        case .finishSetupReminder, .waitingForPairingReminder:
            return PumpManagerAlert.finishSetupReminder(triggeringSlot: slot)
        case .suspendTimeExpired:
            return PumpManagerAlert.suspendEnded(triggeringSlot: slot)
        default:
            return nil
        }
    }

    private func silenceAcknowledgedAlerts() {
        for alert in state.alertsWithPendingAcknowledgment {
            if let slot = alert.triggeringSlot {
                self.podComms.runSession(withName: "Silence already acknowledged alert") { (result) in
                    switch result {
                    case .success(let session):
                        do {
                            let _ = try session.acknowledgePodAlerts(alerts: AlertSet(slots: [slot]), confirmationBeepType: self.confirmationBeeps ? .beep : .noBeep)
                        } catch {
                            return
                        }
                        self.mutateState { state in
                            state.activeAlerts.remove(alert)
                        }
                    case .failure:
                        return
                    }
                }
            }
        }
    }

    private func notifyPodFault(fault: DetailedStatus) {
        pumpDelegate.notify { delegate in
            let content = Alert.Content(title: fault.faultEventCode.notificationTitle,
                                        body: fault.faultEventCode.notificationBody,
                                        acknowledgeActionButtonLabel: LocalizedString("OK", comment: "Alert acknowledgment OK button"))
            delegate?.issueAlert(Alert(identifier: Alert.Identifier(managerIdentifier: OmniBLEPumpManager.podAlarmNotificationIdentifier,
                                                                    alertIdentifier: fault.faultEventCode.description),
                                       foregroundContent: content, backgroundContent: content,
                                       trigger: .immediate))
        }
    }

    // MARK: - Reporting Doses

    // This cannot be called from within the lockedState lock!
    func store(doses: [UnfinalizedDose], in session: PodCommsSession) -> Bool {
        session.assertOnSessionQueue()

        // We block the session until the data's confirmed stored by the delegate
        let semaphore = DispatchSemaphore(value: 0)
        var success = false

        store(doses: doses) { (error) in
            success = (error == nil)
            semaphore.signal()
        }

        semaphore.wait()

        if success {
            setState { (state) in
                state.lastPumpDataReportDate = Date()
            }
        }
        return success
    }

    func store(doses: [UnfinalizedDose], completion: @escaping (_ error: Error?) -> Void) {
        let lastSync = lastSync

        pumpDelegate.notify { (delegate) in
            guard let delegate = delegate else {
                preconditionFailure("pumpManagerDelegate cannot be nil")
            }


            delegate.pumpManager(self, hasNewPumpEvents: doses.map { NewPumpEvent($0) }, lastSync: lastSync, completion: { (error) in
                if let error = error {
                    self.log.error("Error storing pod events: %@", String(describing: error))
                } else {
                    self.log.info("DU: Stored pod events: %@", String(describing: doses))
                }

                completion(error)
            })
        }
    }
}

extension OmniBLEPumpManager: MessageLogger {
    func didSend(_ message: Data) {
        log.default("didSend: %{public}@", message.hexadecimalString)
        self.logDeviceCommunication(message.hexadecimalString, type: .send)
    }

    func didReceive(_ message: Data) {
        log.default("didReceive: %{public}@", message.hexadecimalString)
        self.logDeviceCommunication(message.hexadecimalString, type: .receive)
    }
}

extension OmniBLEPumpManager: PodCommsDelegate {

    func podCommsDidEstablishSession(_ podComms: PodComms) {

        podComms.runSession(withName: "Post-connect status fetch") { result in
            switch result {
            case .success(let session):
                let _ = try? session.getStatus(confirmationBeepType: .none)
                self.silenceAcknowledgedAlerts()
                session.dosesForStorage() { (doses) -> Bool in
                    return self.store(doses: doses, in: session)
                }
                self.issueHeartbeatIfNeeded()
            case .failure:
                // Errors can be ignored here.
                break
            }
        }
        
    }

    func podComms(_ podComms: PodComms, didChange podState: PodState) {
        let (newFault, oldAlerts, newAlerts) = setStateWithResult { (state) -> (DetailedStatus?,AlertSet,AlertSet) in
            // Check for any updates to bolus certainty, and log them
            if let bolus = state.podState?.unfinalizedBolus, bolus.scheduledCertainty == .uncertain, !bolus.isFinished {
                if podState.unfinalizedBolus?.scheduledCertainty == .some(.certain) {
                    self.log.default("Resolved bolus uncertainty: did bolus")
                } else if podState.unfinalizedBolus == nil {
                    self.log.default("Resolved bolus uncertainty: did not bolus")
                }
            }
            if (state.suspendEngageState == .engaging && podState.isSuspended) ||
               (state.suspendEngageState == .disengaging && !podState.isSuspended)
            {
                state.suspendEngageState = .stable
            }

            let newFault: DetailedStatus?

            // Check for new fault state
            if state.podState?.fault == nil, let fault = podState.fault {
                newFault = fault
            } else {
                newFault = nil
            }

            let oldAlerts: AlertSet = state.podState?.activeAlertSlots ?? AlertSet.none
            let newAlerts: AlertSet = podState.activeAlertSlots

            state.podState = podState

            return (newFault, oldAlerts, newAlerts)
        }

        if let newFault = newFault {
            notifyPodFault(fault: newFault)
        }

        if oldAlerts != newAlerts {
            self.alertsChanged(oldAlerts: oldAlerts, newAlerts: newAlerts)
        }
    }
}

extension OmniBLEPumpManager: AlertSoundVendor {
    public func getSoundBaseURL() -> URL? {
        return nil
    }

    public func getSounds() -> [Alert.Sound] {
        return []
    }
}

// MARK: - AlertResponder implementation
extension OmniBLEPumpManager {
    public func acknowledgeAlert(alertIdentifier: Alert.AlertIdentifier, completion: @escaping (Error?) -> Void) {
        guard self.hasActivePod else {
            completion(OmniBLEPumpManagerError.noPodPaired)
            return
        }

        for alert in state.activeAlerts {
            if alert.alertIdentifier == alertIdentifier {
                // If this alert was triggered by the pod find the slot to clear it.
                if let slot = alert.triggeringSlot {
                    self.podComms.runSession(withName: "Acknowledge Alert") { (result) in
                        switch result {
                        case .success(let session):
                            do {
                                let _ = try session.acknowledgePodAlerts(alerts: AlertSet(slots: [slot]), confirmationBeepType: self.confirmationBeeps ? .beep : .noBeep)
                            } catch {
                                self.mutateState { state in
                                    state.alertsWithPendingAcknowledgment.insert(alert)
                                }
                                completion(error)
                                return
                            }
                            self.mutateState { state in
                                state.activeAlerts.remove(alert)
                            }
                            completion(nil)
                        case .failure(let error):
                            self.mutateState { state in
                                state.alertsWithPendingAcknowledgment.insert(alert)
                            }
                            completion(error)
                            return
                        }
                    }
                } else {
                    // Non-pod alert
                    self.mutateState { state in
                        state.activeAlerts.remove(alert)
                        if alert == .timeOffsetChangeDetected {
                            state.acknowledgedTimeOffsetAlert = true
                        }
                    }
                    completion(nil)
                }
            }
        }
    }
}

extension FaultEventCode {
    public var notificationTitle: String {
        switch self.faultType {
        case .reservoirEmpty:
            return LocalizedString("Empty Reservoir", comment: "The title for Empty Reservoir alarm notification")
        case .occluded, .occlusionCheckStartup1, .occlusionCheckStartup2, .occlusionCheckTimeouts1, .occlusionCheckTimeouts2, .occlusionCheckTimeouts3, .occlusionCheckPulseIssue, .occlusionCheckBolusProblem:
            return LocalizedString("Occlusion Detected", comment: "The title for Occlusion alarm notification")
        case .exceededMaximumPodLife80Hrs:
            return LocalizedString("Pod Expired", comment: "The title for Pod Expired alarm notification")
        default:
            return LocalizedString("Critical Pod Error", comment: "The title for AlarmCode.other notification")
        }
    }

    public var notificationBody: String {
        return LocalizedString("Insulin delivery stopped. Change Pod now.", comment: "The default notification body for AlarmCodes")
    }
}
