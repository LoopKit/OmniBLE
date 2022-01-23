//
//  OmniBLEHUDProvider.swift
//  OmniBLE
//
//  Based on OmniKitUI/PumpManager/OmniBLEHUDProvider.swift
//  Created by Pete Schwamb on 11/26/18.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import UIKit
import LoopKit
import LoopKitUI

internal class OmniBLEHUDProvider: NSObject, HUDProvider, PodStateObserver {

    var managerIdentifier: String {
        return pumpManager.managerIdentifier
    }


    private var podState: PodState? {
        didSet {
            guard visible else {
                return
            }

            guard oldValue != podState else {
                return
            }

            if oldValue?.lastInsulinMeasurements != podState?.lastInsulinMeasurements {
                updateReservoirView()
            }

            if oldValue != nil && podState == nil {
                updateReservoirView()
            }

        }
    }

    private let pumpManager: OmniBLEPumpManager

    private var reservoirView: OmniBLEReservoirView?

    private let bluetoothProvider: BluetoothProvider

    private let colorPalette: LoopUIColorPalette

    private let allowedInsulinTypes: [InsulinType]


    var visible: Bool = false {
        didSet {
            if oldValue != visible && visible {
                hudDidAppear()
            }
        }
    }

    public init(pumpManager: OmniBLEPumpManager, bluetoothProvider: BluetoothProvider, colorPalette: LoopUIColorPalette, allowedInsulinTypes: [InsulinType]) {
        self.pumpManager = pumpManager
        self.bluetoothProvider = bluetoothProvider
        self.podState = pumpManager.state.podState
        self.colorPalette = colorPalette
        self.allowedInsulinTypes = allowedInsulinTypes
        super.init()
        self.pumpManager.addPodStateObserver(self, queue: .main)
    }

    private func updateReservoirView() {
        if let lastInsulinMeasurements = podState?.lastInsulinMeasurements,
            let reservoirView = reservoirView,
            let podState = podState
        {
            let reservoirVolume = lastInsulinMeasurements.reservoirLevel

            let reservoirLevel = reservoirVolume?.asReservoirPercentage()

            var reservoirAlertState: ReservoirAlertState = .ok
            for (_, alert) in podState.activeAlerts {
                if case .lowReservoirAlarm = alert {
                    reservoirAlertState = .lowReservoir
                    break
                }
            }

            reservoirView.update(volume: reservoirVolume, at: lastInsulinMeasurements.validTime, level: reservoirLevel, reservoirAlertState: reservoirAlertState)
        }
    }

    public func createHUDView() -> LevelHUDView? {
        self.reservoirView = OmniBLEReservoirView.instantiate()
        self.updateReservoirView()

        return reservoirView
    }

    public func didTapOnHUDView(_ view: BaseHUDView, allowDebugFeatures: Bool) -> HUDTapAction? {
        if let podState = self.podState, podState.isFaulted {
            return HUDTapAction.presentViewController(PodReplacementNavigationController.instantiatePodReplacementFlow(pumpManager))
        } else {
            return HUDTapAction.presentViewController(pumpManager.settingsViewController(bluetoothProvider: bluetoothProvider, colorPalette: colorPalette, allowDebugFeatures: allowDebugFeatures, allowedInsulinTypes: allowedInsulinTypes))
        }
    }

    func hudDidAppear() {
        updateReservoirView()
        pumpManager.refreshStatus(emitConfirmationBeep: false)
    }

    public var hudViewRawState: HUDProvider.HUDViewRawState {
        var rawValue: HUDProvider.HUDViewRawState = [:]

        if let podState = podState {
            rawValue["alerts"] = podState.activeAlerts.values.map { $0.rawValue }
        }

        if let lastInsulinMeasurements = podState?.lastInsulinMeasurements {
            rawValue["reservoirVolume"] = lastInsulinMeasurements.reservoirLevel
            rawValue["validTime"] = lastInsulinMeasurements.validTime
        }

        return rawValue
    }

    public static func createHUDView(rawValue: HUDProvider.HUDViewRawState) -> LevelHUDView? {
        guard let rawAlerts = rawValue["alerts"] as? [PodAlert.RawValue] else {
            return nil
        }

        let alerts = rawAlerts.compactMap { PodAlert.init(rawValue: $0) }
        let reservoirVolume = rawValue["reservoirVolume"] as? Double
        let validTime = rawValue["validTime"] as? Date

        let reservoirView = OmniBLEReservoirView.instantiate()
        if let validTime = validTime
        {
            let reservoirLevel = reservoirVolume?.asReservoirPercentage()
            var reservoirAlertState: ReservoirAlertState = .ok
            for alert in alerts {
                if case .lowReservoirAlarm = alert {
                    reservoirAlertState = .lowReservoir
                }
            }
            reservoirView.update(volume: reservoirVolume, at: validTime, level: reservoirLevel, reservoirAlertState: reservoirAlertState)
        }

        return reservoirView
    }

    func podStateDidUpdate(_ podState: PodState?) {
        self.podState = podState
    }
}

extension Double {
    func asReservoirPercentage() -> Double {
        return min(1, max(0, self / Pod.reservoirCapacity))
    }
}
