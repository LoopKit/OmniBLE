//
//  OmnipodPumpManager+UI.swift
//  OmnipodKit
//
//  Created by Pete Schwamb on 8/4/18.
//  Copyright © 2018 Pete Schwamb. All rights reserved.
//

import Foundation

import UIKit
import LoopKit
import LoopKitUI
import SwiftUI

extension DashPumpManager: PumpManagerUI {
    public static var onboardingImage: UIImage? {
        return UIImage(named: "Onboarding", in: Bundle(for: DashSettingsViewModel.self), compatibleWith: nil)
    }
        
    public static func setupViewController(initialSettings settings: PumpManagerSetupSettings, bluetoothProvider: BluetoothProvider, colorPalette: LoopUIColorPalette, allowDebugFeatures: Bool, allowedInsulinTypes: [InsulinType]) -> SetupUIResult<PumpManagerViewController, PumpManagerUI> {
        let vc = DashUICoordinator(colorPalette: colorPalette, pumpManagerType: self, basalSchedule: settings.basalSchedule, allowDebugFeatures: allowDebugFeatures, allowedInsulinTypes: allowedInsulinTypes)
        return .userInteractionRequired(vc)
    }
        
    public func settingsViewController(bluetoothProvider: BluetoothProvider, colorPalette: LoopUIColorPalette, allowDebugFeatures: Bool, allowedInsulinTypes: [InsulinType]) -> PumpManagerViewController {
        return DashUICoordinator(pumpManager: self, colorPalette: colorPalette, allowDebugFeatures: allowDebugFeatures, allowedInsulinTypes: allowedInsulinTypes)
    }
    
    public func deliveryUncertaintyRecoveryViewController(colorPalette: LoopUIColorPalette, allowDebugFeatures: Bool) -> (UIViewController & CompletionNotifying) {
        return DashUICoordinator(pumpManager: self, colorPalette: colorPalette, allowDebugFeatures: allowDebugFeatures)
    }
    
    public var smallImage: UIImage? {
        return UIImage(named: "Pod", in: Bundle(for: DashSettingsViewModel.self), compatibleWith: nil)!
    }

    public func hudProvider(bluetoothProvider: BluetoothProvider, colorPalette: LoopUIColorPalette, allowedInsulinTypes: [InsulinType]) -> HUDProvider? {
        return DashHUDProvider(pumpManager: self, bluetoothProvider: bluetoothProvider, colorPalette: colorPalette, allowedInsulinTypes: allowedInsulinTypes)
    }

    public static func createHUDView(rawValue: HUDProvider.HUDViewRawState) -> LevelHUDView? {
        return DashHUDProvider.createHUDView(rawValue: rawValue)
    }
}

// MARK: - DeliveryLimitSettingsTableViewControllerSyncSource
extension DashPumpManager {
    public func syncDeliveryLimitSettings(for viewController: DeliveryLimitSettingsTableViewController, completion: @escaping (DeliveryLimitSettingsResult) -> Void) {
        guard let maxBasalRate = viewController.maximumBasalRatePerHour,
            let maxBolus = viewController.maximumBolus else
        {
            completion(.failure(PodCommsError.invalidData))
            return
        }
        
        completion(.success(maximumBasalRatePerHour: maxBasalRate, maximumBolus: maxBolus))
    }
    
    public func syncButtonTitle(for viewController: DeliveryLimitSettingsTableViewController) -> String {
        return LocalizedString("Save", comment: "Title of button to save delivery limit settings")    }
    
    public func syncButtonDetailText(for viewController: DeliveryLimitSettingsTableViewController) -> String? {
        return nil
    }
    
    public func deliveryLimitSettingsTableViewControllerIsReadOnly(_ viewController: DeliveryLimitSettingsTableViewController) -> Bool {
        return false
    }
}

// MARK: - BasalScheduleTableViewControllerSyncSource
extension DashPumpManager {

    public func syncScheduleValues(for viewController: BasalScheduleTableViewController, completion: @escaping (SyncBasalScheduleResult<Double>) -> Void) {
        let newSchedule = BasalSchedule(repeatingScheduleValues: viewController.scheduleItems)
        setBasalSchedule(newSchedule) { (error) in
            if let error = error {
                completion(.failure(error))
            } else {
                completion(.success(scheduleItems: viewController.scheduleItems, timeZone: self.state.timeZone))
            }
        }
    }

    public func syncButtonTitle(for viewController: BasalScheduleTableViewController) -> String {
        if self.hasActivePod {
            return LocalizedString("Sync With Pod", comment: "Title of button to sync basal profile from pod")
        } else {
            return LocalizedString("Save", comment: "Title of button to sync basal profile when no pod paired")
        }
    }

    public func syncButtonDetailText(for viewController: BasalScheduleTableViewController) -> String? {
        return nil
    }

    public func basalScheduleTableViewControllerIsReadOnly(_ viewController: BasalScheduleTableViewController) -> Bool {
        return false
    }
}

// MARK: - PumpStatusIndicator
extension DashPumpManager {
    public var pumpStatusHighlight: DeviceStatusHighlight? {
        guard state.podState?.fault != nil else {
            return nil
        }

        return PumpManagerStatus.PumpStatusHighlight(localizedMessage: LocalizedString("Pod Fault", comment: "Inform the user that there is a pod fault."),
                                                     imageName: "exclamationmark.circle.fill",
                                                     state: .critical)
    }
    
    public var pumpLifecycleProgress: DeviceLifecycleProgress? {
        return nil
    }
    
    public var pumpStatusBadge: DeviceStatusBadge? {
        return nil
    }

}

