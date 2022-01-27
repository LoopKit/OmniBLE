//
//  DashSettingsViewModel.swift
//  OmniBLE
//
//  Created by Pete Schwamb on 3/8/20.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopKit
import HealthKit


enum DashSettingsViewAlert {
    case suspendError(Error)
    case resumeError(Error)
    case syncTimeError(OmniBLEPumpManagerError)
    case changeConfirmationBeepsError(OmniBLEPumpManagerError)
}

public enum ReservoirLevelHighlightState: String, Equatable {
    case normal
    case warning
    case critical
}

struct DashSettingsNotice {
    let title: String
    let description: String
}

class OmniBLESettingsViewModel: ObservableObject {
    
    @Published var lifeState: PodLifeState
    
    @Published var activatedAt: Date?
    
    @Published var changingConfirmationBeeps: Bool = false

    var confirmationBeeps: Bool {
        get {
            pumpManager.confirmationBeeps
        }
    }
    
    var activatedAtString: String {
        if let activatedAt = activatedAt {
            return dateFormatter.string(from: activatedAt)
        } else {
            return "—"
        }
    }
    
    var expiresAtString: String {
        if let activatedAt = activatedAt {
            return dateFormatter.string(from: activatedAt + Pod.nominalPodLife)
        } else {
            return "—"
        }
    }

    // Expiration reminder date for current pod
    @Published var expirationReminderDate: Date?
    
    var allowedScheduledReminderDates: [Date]? {
        return pumpManager.allowedExpirationReminderDates
    }

    // Hours before expiration
    @Published var expirationReminderDefault: Int {
        didSet {
            self.pumpManager.defaultExpirationReminderOffset = .hours(Double(expirationReminderDefault))
        }
    }
    
    // Units to alert at
    @Published var lowReservoirAlertValue: Int
    
    @Published var basalDeliveryState: PumpManagerStatus.BasalDeliveryState?

    @Published var basalDeliveryRate: Double?

    @Published var activeAlert: DashSettingsViewAlert? = nil {
        didSet {
            if activeAlert != nil {
                alertIsPresented = true
            }
        }
    }

    @Published var alertIsPresented: Bool = false {
        didSet {
            if !alertIsPresented {
                activeAlert = nil
            }
        }
    }
    
    @Published var reservoirLevel: ReservoirLevel?
    
    @Published var reservoirLevelHighlightState: ReservoirLevelHighlightState?
    
    @Published var synchronizingTime: Bool = false
    
    var timeZone: TimeZone {
        return pumpManager.status.timeZone
    }
    
    var podVersion: PodVersion? {
        return pumpManager.podVersion
    }
        
    var viewTitle: String {
        return pumpManager.localizedTitle
    }
    
    var isClockOffset: Bool {
        return pumpManager.isClockOffset
    }
    
    var notice: DashSettingsNotice? {
        if pumpManager.isClockOffset {
            return DashSettingsNotice(
                title: LocalizedString("Time Change Detected", comment: "title for time change detected notice"),
                description: LocalizedString("The time on your pump is different from the current time. Your pump’s time controls your scheduled basal rates. You can review the time difference and configure your pump.", comment: "description for time change detected notice"))
        } else {
            return nil
        }
    }

    var isScheduledBasal: Bool {
        switch basalDeliveryState {
        case .active(_), .initiatingTempBasal:
            return true
        case .tempBasal(_), .cancelingTempBasal, .suspending, .suspended(_), .resuming, .none:
            return false
        }
    }
    
    let dateFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.timeStyle = .short
        dateFormatter.dateStyle = .medium
        dateFormatter.doesRelativeDateFormatting = true
        return dateFormatter
    }()
    
    let timeFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.timeStyle = .short
        dateFormatter.dateStyle = .none
        return dateFormatter
    }()

    let basalRateFormatter: NumberFormatter = {
        let unit = HKUnit.internationalUnit()
        let numberFormatter = NumberFormatter()
        numberFormatter.numberStyle = .decimal
        numberFormatter.minimumFractionDigits = 1
        numberFormatter.minimumIntegerDigits = 1
        return numberFormatter
    }()
    
    let reservoirVolumeFormatter = QuantityFormatter(for: .internationalUnit())
    
    var didFinish: (() -> Void)?
    
    var navigateTo: ((DashUIScreen) -> Void)?
    
    private let pumpManager: OmniBLEPumpManager
    
    init(pumpManager: OmniBLEPumpManager) {
        self.pumpManager = pumpManager
        
        lifeState = pumpManager.lifeState
        activatedAt = pumpManager.podActivatedAt
        basalDeliveryState = pumpManager.status.basalDeliveryState
        basalDeliveryRate = self.pumpManager.basalDeliveryRate
        reservoirLevel = self.pumpManager.reservoirLevel
        reservoirLevelHighlightState = self.pumpManager.reservoirLevelHighlightState
        expirationReminderDate = self.pumpManager.scheduledExpirationReminder
        expirationReminderDefault = Int(self.pumpManager.defaultExpirationReminderOffset.hours)
        lowReservoirAlertValue = Int(self.pumpManager.state.lowReservoirReminderValue)
        pumpManager.addPodStateObserver(self, queue: DispatchQueue.main)
    }
    
    func changeTimeZoneTapped() {
        synchronizingTime = true
        pumpManager.setTime { (error) in
            DispatchQueue.main.async {
                self.synchronizingTime = false
                self.lifeState = self.pumpManager.lifeState
                if let error = error {
                    self.activeAlert = .syncTimeError(error)
                }
            }
        }
    }
    
    func doneTapped() {
        self.didFinish?()
    }
    
    func stopUsingOmnipodTapped() {
        self.pumpManager.notifyDelegateOfDeactivation {
            DispatchQueue.main.async {
                self.didFinish?()
            }
        }
    }
    
    func suspendDelivery(duration: TimeInterval) {
        // TODO: add reminder setting
        pumpManager.suspendDelivery() { (error) in
            DispatchQueue.main.async {
                if let error = error {
                    self.activeAlert = .suspendError(error)
                }
            }
        }
    }
    
    func resumeDelivery() {
        pumpManager.resumeDelivery { (error) in
            DispatchQueue.main.async {
                if let error = error {
                    self.activeAlert = .resumeError(error)
                }
            }
        }
    }
    
    func saveScheduledExpirationReminder(_ selectedDate: Date, _ completion: @escaping (Error?) -> Void) {
        if let podExpiresAt = pumpManager.podExpiresAt {
            let intervalBeforeExpiration = podExpiresAt.timeIntervalSince(selectedDate)
            pumpManager.updateExpirationReminder(.hours(round(intervalBeforeExpiration.hours))) { (error) in
                DispatchQueue.main.async {
                    if error == nil {
                        self.expirationReminderDate = selectedDate
                    }
                    completion(error)
                }
            }
        }
    }

    func saveLowReservoirReminder(_ selectedValue: Int, _ completion: @escaping (Error?) -> Void) {
        pumpManager.updateLowReservoirReminder(selectedValue) { (error) in
            DispatchQueue.main.async {
                if error == nil {
                    self.lowReservoirAlertValue = selectedValue
                }
                completion(error)
            }
        }
    }
 
    func setConfirmationBeeps(enabled: Bool) {
        self.changingConfirmationBeeps = true
        pumpManager.setConfirmationBeeps(enabled: enabled) { error in
            DispatchQueue.main.async {
                self.changingConfirmationBeeps = false
                if let error = error {
                    self.activeAlert = .changeConfirmationBeepsError(error)
                }
            }
        }
    }
    
    var podOk: Bool {
        guard basalDeliveryState != nil else { return false }
        
        switch lifeState {
        case .noPod, .podAlarm, .podActivating, .podDeactivating:
            return false
        default:
            return true
        }
    }
    
    func reservoirText(for level: ReservoirLevel) -> String {
        switch level {
        case .aboveThreshold:
            let quantity = HKQuantity(unit: .internationalUnit(), doubleValue: Pod.maximumReservoirReading)
            let thresholdString = reservoirVolumeFormatter.string(from: quantity, for: .internationalUnit(), includeUnit: false) ?? ""
            let unitString = reservoirVolumeFormatter.string(from: .internationalUnit(), forValue: Pod.maximumReservoirReading, avoidLineBreaking: true)
            return String(format: LocalizedString("%1$@+ %2$@", comment: "Format string for reservoir level above max measurable threshold. (1: measurable reservoir threshold) (2: units)"),
                          thresholdString, unitString)
        case .valid(let value):
            let quantity = HKQuantity(unit: .internationalUnit(), doubleValue: value)
            return reservoirVolumeFormatter.string(from: quantity, for: .internationalUnit()) ?? ""
        }
    }
}

extension OmniBLESettingsViewModel: PodStateObserver {
    func podStateDidUpdate(_ state: PodState?) {
        lifeState = self.pumpManager.lifeState
        basalDeliveryState = self.pumpManager.status.basalDeliveryState
        basalDeliveryRate = self.pumpManager.basalDeliveryRate
        reservoirLevel = self.pumpManager.reservoirLevel
        activatedAt = state?.activatedAt
        reservoirLevelHighlightState = self.pumpManager.reservoirLevelHighlightState
        expirationReminderDate = self.pumpManager.scheduledExpirationReminder
    }
}

extension OmniBLEPumpManager {
    var lifeState: PodLifeState {
        switch podCommState {
        case .fault(let status):
            return .podAlarm(status)
        case .noPod:
            return .noPod
        case .activating:
            return .podActivating
        case .deactivating:
            return .podDeactivating
        case .active:
            if let podTimeRemaining = podTimeRemaining {
                if podTimeRemaining > 0 {
                    return .timeRemaining(podTimeRemaining)
                } else {
                    return .expired
                }
            } else {
                return .podDeactivating
            }
        }
    }
    
    var basalDeliveryRate: Double? {
        if let tempBasal = state.podState?.unfinalizedTempBasal, !tempBasal.isFinished {
            return tempBasal.rate
        } else {
            switch state.podState?.suspendState {
            case .resumed:
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = state.timeZone
                return state.basalSchedule.currentRate(using: calendar, at: dateGenerator())
            case .suspended, .none:
                return nil
            }
        }
    }
}

extension PumpManagerStatus.BasalDeliveryState {
    var suspendResumeActionText: String {
        switch self {
        case .active, .tempBasal, .cancelingTempBasal, .initiatingTempBasal:
            return LocalizedString("Suspend Insulin Delivery", comment: "Text for suspend resume button when insulin delivery active")
        case .suspending:
            return LocalizedString("Suspending insulin delivery...", comment: "Text for suspend resume button when insulin delivery is suspending")
        case .suspended:
            return LocalizedString("Tap to Resume Insulin Delivery", comment: "Text for suspend resume button when insulin delivery is suspended")
        case .resuming:
            return LocalizedString("Resuming insulin delivery...", comment: "Text for suspend resume button when insulin delivery is resuming")
        }
    }
    
    var transitioning: Bool {
        switch self {
        case .suspending, .resuming:
            return true
        default:
            return false
        }
    }    
}
