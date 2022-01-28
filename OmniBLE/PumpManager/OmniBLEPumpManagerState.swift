//
//  OmniBLEPumpManagerState.swift
//  OmniBLE
//
//  Based on OmniKit/PumpManager/OmnipodPumpManagerState.swift
//  Created by Pete Schwamb on 8/4/18.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import LoopKit


public struct OmniBLEPumpManagerState: RawRepresentable, Equatable {
    public typealias RawValue = PumpManager.RawStateValue

    public static let version = 2
    
    public var isOnboarded: Bool = false
    
    public var podState: PodState?

    public var timeZone: TimeZone

    public var basalSchedule: BasalSchedule

    public var unstoredDoses: [UnfinalizedDose]

    public var confirmationBeeps: Bool
    
    public var controllerId: UInt32 = 0

    public var podId: UInt32 = 0

    public var scheduledExpirationReminderOffset: TimeInterval?
    
    public var defaultExpirationReminderOffset = Pod.defaultExpirationReminderOffset

    public var lowReservoirReminderValue: Double
    
    public var podAttachmentConfirmed: Bool
    
    public var pendingCommand: PendingCommand?

    public var activeAlerts: Set<PumpManagerAlert>
    
    public var alertsWithPendingAcknowledgment: Set<PumpManagerAlert>

    public var acknowledgedTimeOffsetAlert: Bool
    
    // Indicates that the user has completed initial configuration
    // which means they have configured any parameters, but may not have paired a pod yet.
    public var initialConfigurationCompleted: Bool = false
    
    
    // From last status response
    public var reservoirLevel: ReservoirLevel? {
        guard let level = podState?.lastInsulinMeasurements?.reservoirLevel else {
            return nil
        }
        return ReservoirLevel(rawValue: level)
    }

    // Temporal state not persisted

    internal enum EngageablePumpState: Equatable {
        case engaging
        case disengaging
        case stable
    }

    internal var suspendEngageState: EngageablePumpState = .stable

    internal var bolusEngageState: EngageablePumpState = .stable

    internal var tempBasalEngageState: EngageablePumpState = .stable

    internal var lastPumpDataReportDate: Date?
    
    internal var insulinType: InsulinType?
    
    // MARK: -

    public init(podState: PodState?, timeZone: TimeZone, basalSchedule: BasalSchedule, controllerId: UInt32? = nil, podId: UInt32? = nil, insulinType: InsulinType?) {
        self.podState = podState
        self.timeZone = timeZone
        self.basalSchedule = basalSchedule
        self.unstoredDoses = []
        self.confirmationBeeps = false
        if controllerId != nil && podId != nil {
            self.controllerId = controllerId!
            self.podId = podId!
        } else {
            let myId = createControllerId()
            self.controllerId = myId
            self.podId = myId + 1
        }
        self.insulinType = insulinType
        self.lowReservoirReminderValue = Pod.defaultLowReservoirReminder
        self.podAttachmentConfirmed = false
        self.acknowledgedTimeOffsetAlert = false
        self.activeAlerts = []
        self.alertsWithPendingAcknowledgment = []
    }

    public init?(rawValue: RawValue) {

        guard let version = rawValue["version"] as? Int else {
            return nil
        }

        let basalSchedule: BasalSchedule

        if version == 1 {
            // migrate: basalSchedule moved from podState to oppm state
            if let podStateRaw = rawValue["podState"] as? PodState.RawValue,
                let rawBasalSchedule = podStateRaw["basalSchedule"] as? BasalSchedule.RawValue,
                let migrateSchedule = BasalSchedule(rawValue: rawBasalSchedule)
            {
                basalSchedule = migrateSchedule
            } else {
                return nil
            }
        } else {
            guard let rawBasalSchedule = rawValue["basalSchedule"] as? BasalSchedule.RawValue,
                let schedule = BasalSchedule(rawValue: rawBasalSchedule) else
            {
                return nil
            }
            basalSchedule = schedule
        }
        let podState: PodState?
        if let podStateRaw = rawValue["podState"] as? PodState.RawValue {
            podState = PodState(rawValue: podStateRaw)
        } else {
            podState = nil
        }

        let timeZone: TimeZone
        if let timeZoneSeconds = rawValue["timeZone"] as? Int,
            let tz = TimeZone(secondsFromGMT: timeZoneSeconds) {
            timeZone = tz
        } else {
            timeZone = TimeZone.currentFixed
        }

        var controllerId = rawValue["controllerId"] as? UInt32
        var podId = rawValue["podId"] as? UInt32
        if controllerId == nil || podId == nil {
            // continue using the constant controllerId
            // value until this pod is deactivated
            controllerId = CONTROLLER_ID
            podId = podState?.address
        }

        var insulinType: InsulinType?
        if let rawInsulinType = rawValue["insulinType"] as? InsulinType.RawValue {
            insulinType = InsulinType(rawValue: rawInsulinType)
        }

        self.init(
            podState: podState,
            timeZone: timeZone,
            basalSchedule: basalSchedule,
            controllerId: controllerId,
            podId: podId,
            insulinType: insulinType ?? .novolog
        )
        
        self.isOnboarded = rawValue["isOnboarded"] as? Bool ?? true // Backward compatibility

        if let rawUnstoredDoses = rawValue["unstoredDoses"] as? [UnfinalizedDose.RawValue] {
            self.unstoredDoses = rawUnstoredDoses.compactMap( { UnfinalizedDose(rawValue: $0) } )
        } else {
            self.unstoredDoses = []
        }

        self.confirmationBeeps = rawValue["confirmationBeeps"] as? Bool ?? rawValue["bolusBeeps"] as? Bool ?? false

        self.scheduledExpirationReminderOffset = rawValue["scheduledExpirationReminderOffset"] as? TimeInterval
        
        self.defaultExpirationReminderOffset = rawValue["defaultExpirationReminderOffset"] as? TimeInterval ?? Pod.defaultExpirationReminderOffset
        
        self.lowReservoirReminderValue = rawValue["lowReservoirReminderValue"] as? Double ?? Pod.defaultLowReservoirReminder

        self.podAttachmentConfirmed = rawValue["podAttachmentConfirmed"] as? Bool ?? false

        self.initialConfigurationCompleted = rawValue["initialConfigurationCompleted"] as? Bool ?? true
        
        self.acknowledgedTimeOffsetAlert = rawValue["acknowledgedTimeOffsetAlert"] as? Bool ?? false
        
        if let rawPendingCommand = rawValue["pendingCommand"] as? PendingCommand.RawValue {
            self.pendingCommand = PendingCommand(rawValue: rawPendingCommand)
        } else {
            self.pendingCommand = nil
        }

        self.activeAlerts = []
        if let rawActiveAlerts = rawValue["activeAlerts"] as? [PumpManagerAlert.RawValue] {
            for rawAlert in rawActiveAlerts {
                if let alert = PumpManagerAlert(rawValue: rawAlert) {
                    self.activeAlerts.insert(alert)
                }
            }
        }

        self.alertsWithPendingAcknowledgment = []
        if let rawAlerts = rawValue["alertsWithPendingAcknowledgment"] as? [PumpManagerAlert.RawValue] {
            for rawAlert in rawAlerts {
                if let alert = PumpManagerAlert(rawValue: rawAlert) {
                    self.alertsWithPendingAcknowledgment.insert(alert)
                }
            }
        }
    }

    public var rawValue: RawValue {
        var value: [String : Any] = [
            "version": OmniBLEPumpManagerState.version,
            "isOnboarded": isOnboarded,
            "timeZone": timeZone.secondsFromGMT(),
            "basalSchedule": basalSchedule.rawValue,
            "unstoredDoses": unstoredDoses.map { $0.rawValue },
            "confirmationBeeps": confirmationBeeps,
            "activeAlerts": activeAlerts.map { $0.rawValue },
            "podAttachmentConfirmed": podAttachmentConfirmed,
            "acknowledgedTimeOffsetAlert": acknowledgedTimeOffsetAlert,
            "alertsWithPendingAcknowledgment": alertsWithPendingAcknowledgment.map { $0.rawValue },
            "initialConfigurationCompleted": initialConfigurationCompleted,
        ]
        
        value["insulinType"] = insulinType?.rawValue
        value["podState"] = podState?.rawValue
        value["controllerId"] = controllerId
        value["podId"] = podId
        value["scheduledExpirationReminderOffset"] = scheduledExpirationReminderOffset
        value["defaultExpirationReminderOffset"] = defaultExpirationReminderOffset
        value["lowReservoirReminderValue"] = lowReservoirReminderValue
        value["pendingCommand"] = pendingCommand?.rawValue
        return value
    }
}

extension OmniBLEPumpManagerState {
    var hasActivePod: Bool {
        return podState?.isActive == true
    }

    var hasSetupPod: Bool {
        return podState?.isSetupComplete == true
    }

    var isPumpDataStale: Bool {
        let pumpStatusAgeTolerance = TimeInterval(minutes: 6)
        let pumpDataAge = -(self.lastPumpDataReportDate ?? .distantPast).timeIntervalSinceNow
        return pumpDataAge > pumpStatusAgeTolerance
    }
}


extension OmniBLEPumpManagerState: CustomDebugStringConvertible {
    public var debugDescription: String {
        return [
            "## OmniBLEPumpManagerState",
            "* isOnboarded: \(isOnboarded)",
            "* timeZone: \(timeZone)",
            "* basalSchedule: \(String(describing: basalSchedule))",
            "* unstoredDoses: \(String(describing: unstoredDoses))",
            "* suspendEngageState: \(String(describing: suspendEngageState))",
            "* bolusEngageState: \(String(describing: bolusEngageState))",
            "* tempBasalEngageState: \(String(describing: tempBasalEngageState))",
            "* lastPumpDataReportDate: \(String(describing: lastPumpDataReportDate))",
            "* isPumpDataStale: \(String(describing: isPumpDataStale))",
            "* confirmationBeeps: \(String(describing: confirmationBeeps))",
            "* controllerId: \(String(format: "%08X", controllerId))",
            "* podId: \(String(format: "%08X", podId))",
            "* insulinType: \(String(describing: insulinType))",
            "* scheduledExpirationReminderOffset: \(String(describing: scheduledExpirationReminderOffset))",
            "* defaultExpirationReminderOffset: \(defaultExpirationReminderOffset)",
            "* lowReservoirReminderValue: \(lowReservoirReminderValue)",
            "* podAttachmentConfirmed: \(podAttachmentConfirmed)",
            "* pendingCommand: \(String(describing: pendingCommand))",
            "* activeAlerts: \(activeAlerts)",
            "* alertsWithPendingAcknowledgment: \(alertsWithPendingAcknowledgment)",
            "* acknowledgedTimeOffsetAlert: \(acknowledgedTimeOffsetAlert)",
            "* initialConfigurationCompleted: \(initialConfigurationCompleted)",
            String(reflecting: podState),
        ].joined(separator: "\n")
    }
}
