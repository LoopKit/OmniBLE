//
//  PodLifeState.swift
//  OmniBLE
//
//  Created by Pete Schwamb on 3/9/20.
//  Copyright © 2020 Tidepool. All rights reserved.
//

import Foundation
import SwiftUI

import LoopKitUI

enum PodLifeState {
    case podActivating
    // Time remaining
    case timeRemaining(TimeInterval)
    // Time since expiry
    case expired
    case podDeactivating
    case podAlarm(DetailedStatus)
    case noPod
    
    var progress: Double {
        switch self {
        case .timeRemaining(let timeRemaining):
            return max(0, min(1, (1 - (timeRemaining / Pod.nominalPodLife))))
        case .expired:
            return 1
        case .podAlarm(let status):
            switch status.faultEventCode.faultType {
            case .exceededMaximumPodLife80Hrs:
                return 1
            default:
                return max(0, min(1, (status.faultEventTimeSinceActivation ?? Pod.nominalPodLife) / Pod.nominalPodLife))
            }
        case .podDeactivating:
            return 1
        case .noPod, .podActivating:
            return 0
        }
    }
    
    func progressColor(insulinTintColor: Color, guidanceColors: GuidanceColors) -> Color {
        switch self {
        case .expired:
            return guidanceColors.critical
        case .podAlarm/*(let alarm, _)*/:
            return guidanceColors.critical
//            switch alarm?.alarmCode {
//            case .podExpired:
//                return guidanceColors.critical
//            default:
//                return Color.secondary
//            }
        case .timeRemaining(let timeRemaining):
            return timeRemaining <= Pod.timeRemainingWarningThreshold ? guidanceColors.warning : insulinTintColor
        default:
            return Color.secondary
        }
    }
    
    func labelColor(using guidanceColors: GuidanceColors) -> Color  {
        switch self {
        case .podAlarm, .expired:
            return guidanceColors.critical
        default:
            return .secondary
        }
    }

    
    var localizedLabelText: String {
        switch self {
        case .podActivating:
            return LocalizedString("Unfinished Activation", comment: "Label for pod life state when pod not fully activated")
        case .timeRemaining:
            return LocalizedString("Pod expires in", comment: "Label for pod life state when time remaining")
        case .expired:
            return LocalizedString("Pod expired", comment: "Label for pod life state when within pod expiration window")
        case .podDeactivating:
            return LocalizedString("Unfinished deactivation", comment: "Label for pod life state when pod not fully deactivated")
        case .podAlarm(let status):
            return String(format: LocalizedString("Pod alarm: %1$@", comment: "Format string for label for pod life state when pod is in alarm state (1: The fault description)"), status.faultEventCode.description)
        case .noPod:
            return LocalizedString("No Pod", comment: "Label for pod life state when no pod paired")
        }
    }

    var nextPodLifecycleAction: DashUIScreen {
        switch self {
        case .podActivating, .noPod:
            return .pairPod
        default:
            return .deactivate
        }
    }
    
    var nextPodLifecycleActionDescription: String {
        switch self {
        case .podActivating, .noPod:
            return LocalizedString("Pair Pod", comment: "Settings page link description when next lifecycle action is to pair new pod")
        case .podDeactivating:
            return LocalizedString("Finish deactivation", comment: "Settings page link description when next lifecycle action is to finish deactivation")
        default:
            return LocalizedString("Replace Pod", comment: "Settings page link description when next lifecycle action is to replace pod")
        }
    }
    
    var nextPodLifecycleActionColor: Color {
        switch self {
        case .podActivating, .noPod:
            return .accentColor
        default:
            return .red
        }
    }

    var isActive: Bool {
        switch self {
        case .expired, .timeRemaining:
            return true
        default:
            return false
        }
    }

    var allowsPumpManagerRemoval: Bool {
        if case .noPod = self {
            return true
        }
        return false
    }
}
