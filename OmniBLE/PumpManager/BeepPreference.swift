//
//  BeepPreference.swift
//  OmniBLE
//
//  Created by Pete Schwamb on 2/14/22.
//  Copyright © 2022 LoopKit Authors. All rights reserved.
//

import Foundation

public enum BeepPreference: Int, CaseIterable {
    case silent
    case manualCommands
    case extended

    var title: String {
        switch self {
        case .silent:
            return LocalizedString("Disabled", comment: "Title string for BeepPreference.silent")
        case .manualCommands:
            return LocalizedString("Enabled", comment: "Title string for BeepPreference.manualCommands")
        case .extended:
            return LocalizedString("Extended", comment: "Title string for BeepPreference.extended")
        }
    }

    var description: String {
        switch self {
        case .silent:
            return LocalizedString("No confidence reminders are used.", comment: "Description for BeepPreference.silent")
        case .manualCommands:
            return LocalizedString("Confidence reminders will sound for commands you initiate, like bolus, cancel bolus, suspend, resume, etc. When Loop automatically adjusts delivery, the pod will remain silent.", comment: "Description for BeepPreference.manualCommands")
        case .extended:
            return LocalizedString("All manual delivery commands will beep, as well as automatic boluses.", comment: "Description for BeepPreference.extended")
        }
    }

    var shouldBeepForManualCommand: Bool {
        return self == .extended || self == .manualCommands
    }

    var shouldBeepForAutomaticBolus: Bool {
        return self == .extended
    }
}
