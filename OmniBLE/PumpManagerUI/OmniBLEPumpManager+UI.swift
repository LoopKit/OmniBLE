//
//  OmniBLEPumpManager+UI.swift
//  OmniBLE
//
//  Based on OmniKitUI/PumpManager/OmnipodPumpManager+UI.swift
//  Created by Pete Schwamb on 8/4/18.
//  Copyright © 2018 Pete Schwamb. All rights reserved.
//  Copyright © 2021 OmniBLE Authors. All rights reserved.
//

import Foundation

import UIKit
import LoopKit
import LoopKitUI
import SwiftUI

extension OmniBLEPumpManager: PumpManagerUI {

    public static var onboardingImage: UIImage? {
        return UIImage(named: "Pod", in: Bundle(for: OmniBLESettingsViewController.self), compatibleWith: nil)!
    }

    static public func setupViewController(initialSettings settings: PumpManagerSetupSettings, bluetoothProvider: BluetoothProvider, colorPalette: LoopUIColorPalette, allowDebugFeatures: Bool, allowedInsulinTypes: [InsulinType]) -> SetupUIResult<PumpManagerViewController, PumpManagerUI> {
        let navVC = OmniBLEPumpManagerSetupViewController.instantiateFromStoryboard()
        let insulinSelectionView = InsulinTypeConfirmation(initialValue: .novolog, supportedInsulinTypes: allowedInsulinTypes) { [weak navVC] (confirmedType) in
            if let navVC = navVC {
                navVC.insulinType = confirmedType
                let nextViewController = navVC.storyboard?.instantiateViewController(identifier: "PairPodSetup") as! PairPodSetupViewController
                navVC.pushViewController(nextViewController, animated: true)
            }
        }
        let rootVC = UIHostingController(rootView: insulinSelectionView)
        rootVC.title = "Insulin Type"
        navVC.pushViewController(rootVC, animated: false)
        navVC.navigationBar.backgroundColor = .secondarySystemBackground
        navVC.maxBasalRateUnitsPerHour = settings.maxBasalRateUnitsPerHour
        navVC.maxBolusUnits = settings.maxBolusUnits
        navVC.basalSchedule = settings.basalSchedule
        return .userInteractionRequired(navVC)
    }

    public func settingsViewController(bluetoothProvider: BluetoothProvider, colorPalette: LoopUIColorPalette, allowDebugFeatures: Bool, allowedInsulinTypes: [InsulinType]) -> PumpManagerViewController {
        let settings = OmniBLESettingsViewController(pumpManager: self)
        let nav = PumpManagerSettingsNavigationViewController(rootViewController: settings)
        return nav
    }

    public func deliveryUncertaintyRecoveryViewController(colorPalette: LoopUIColorPalette, allowDebugFeatures: Bool) -> (UIViewController & CompletionNotifying) {

        // Return settings for now; uncertainty recovery not implemented yet
        let settings = OmniBLESettingsViewController(pumpManager: self)
        let nav = SettingsNavigationViewController(rootViewController: settings)
        return nav
    }


    public var smallImage: UIImage? {
        return UIImage(named: "Pod", in: Bundle(for: OmniBLESettingsViewController.self), compatibleWith: nil)!
    }

    public func hudProvider(bluetoothProvider: BluetoothProvider, colorPalette: LoopUIColorPalette, allowedInsulinTypes: [InsulinType]) -> HUDProvider? {
        return OmniBLEHUDProvider(pumpManager: self, bluetoothProvider: bluetoothProvider, colorPalette: colorPalette, allowedInsulinTypes: allowedInsulinTypes)
    }

    public static func createHUDView(rawValue: HUDProvider.HUDViewRawState) -> LevelHUDView? {
        return OmniBLEHUDProvider.createHUDView(rawValue: rawValue)
    }
}

// MARK: - DeliveryLimitSettingsTableViewControllerSyncSource
extension OmniBLEPumpManager {
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
extension OmniBLEPumpManager {

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
extension OmniBLEPumpManager {
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
