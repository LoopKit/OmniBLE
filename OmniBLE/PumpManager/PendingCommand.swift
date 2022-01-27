//
//  PendingCommand.swift
//  OmniBLE
//
//  Created by Pete Schwamb on 1/18/22.
//  Copyright © 2022 Pete Schwamb. All rights reserved.
//

import Foundation
import LoopKit


public enum StartProgram: RawRepresentable {
    public typealias RawValue = [String: Any]

    case bolus(volume: Double, automatic: Bool)
    case basalProgram(schedule: BasalSchedule)
    case tempBasal(unitsPerHour: Double, duration: TimeInterval)
    
    private enum StartProgramType: Int {
        case bolus, basalProgram, tempBasal
    }
    
    public var rawValue: RawValue {
        switch self {
        case .bolus(let volume, let automatic):
            return [
                "programType": StartProgramType.bolus,
                "volume": volume,
                "automatic": automatic
            ]
        case .basalProgram(let schedule):
            return [
                "programType": StartProgramType.basalProgram,
                "schedule": schedule.rawValue
            ]
        case .tempBasal(let unitsPerHour, let duration):
            return [
                "programType": StartProgramType.tempBasal,
                "unitsPerHour": unitsPerHour,
                "duration": duration
            ]
        }
    }

    public init?(rawValue: RawValue) {
        guard let encodedTypeRaw = rawValue["programType"] as? StartProgramType.RawValue,
            let encodedType = StartProgramType(rawValue: encodedTypeRaw) else
        {
            return nil
        }
        switch encodedType {
        case .bolus:
            guard let volume = rawValue["volume"] as? Double,
                  let automatic = rawValue["automatic"] as? Bool else
            {
                return nil
            }
            self = .bolus(volume: volume, automatic: automatic)
        case .basalProgram:
            guard let rawSchedule = rawValue["schedule"] as? BasalSchedule.RawValue,
                  let schedule = BasalSchedule(rawValue: rawSchedule) else
            {
                return nil
            }
            self = .basalProgram(schedule: schedule)
        case .tempBasal:
            guard let unitsPerHour = rawValue["unitsPerHour"] as? Double,
                  let duration = rawValue["duration"] as? TimeInterval else
            {
                return nil
            }
            self = .tempBasal(unitsPerHour: unitsPerHour, duration: duration)
        }
    }
    
    public static func == (lhs: StartProgram, rhs: StartProgram) -> Bool {
        switch(lhs, rhs) {
        case (.bolus(let lhsVolume, let lhsAutomatic), .bolus(let rhsVolume, let rhsAutomatic)):
            return lhsVolume == rhsVolume && lhsAutomatic == rhsAutomatic
        case (.basalProgram(let lhsSchedule), .basalProgram(let rhsSchedule)):
            return lhsSchedule == rhsSchedule
        case (.tempBasal(let lhsUnitsPerHour, let lhsDuration), .tempBasal(let rhsUnitsPerHour, let rhsDuration)):
            return lhsUnitsPerHour == rhsUnitsPerHour && lhsDuration == rhsDuration
        default:
            return false
        }
    }
}

public enum StopProgram: Int {
    case bolus
    case tempBasal
    case stopAll
}



public enum PendingCommand: RawRepresentable, Equatable {
    public typealias RawValue = [String: Any]

    case program(StartProgram, Date)
    case stopProgram(StopProgram, Date)
    
    private enum PendingCommandType: Int {
        case startProgram, stopProgram
    }
    
    public var commandDate: Date {
        switch self {
        case .program(_, let date):
            return date
        case .stopProgram(_, let date):
            return date
        }
    }

    public init?(rawValue: RawValue) {
        guard let rawPendingCommandType = rawValue["type"] as? PendingCommandType.RawValue else {
            return nil
        }
        
        guard let commandDate = rawValue["date"] as? Date else {
            return nil
        }

        switch PendingCommandType(rawValue: rawPendingCommandType) {
        case .startProgram?:
            guard let rawUnacknowledgedProgram = rawValue["unacknowledgedProgram"] as? StartProgram.RawValue else {
                return nil
            }
            if let program = StartProgram(rawValue: rawUnacknowledgedProgram) {
                self = .program(program, commandDate)
            } else {
                return nil
            }
        case .stopProgram?:
            guard let rawUnacknowledgedStopProgram = rawValue["unacknowledgedStopProgram"] as? StopProgram.RawValue else {
                return nil
            }
            if let stopProgram = StopProgram(rawValue: rawUnacknowledgedStopProgram) {
                self = .stopProgram(stopProgram, commandDate)
            } else {
                return nil
            }
        default:
            return nil
        }
    }

    public var rawValue: RawValue {
        var rawValue: RawValue = [:]
        
        switch self {
        case .program(let program, let date):
            rawValue["type"] = PendingCommandType.startProgram.rawValue
            rawValue["date"] = date
            rawValue["unacknowledgedProgram"] = program.rawValue
        case .stopProgram(let stopProgram, let date):
            rawValue["type"] = PendingCommandType.stopProgram.rawValue
            rawValue["date"] = date
            rawValue["unacknowledgedStopProgram"] = stopProgram.rawValue
        }
        return rawValue
    }
    
    public static func == (lhs: PendingCommand, rhs: PendingCommand) -> Bool {
        switch(lhs, rhs) {
        case (.program(let lhsProgram, let lhsDate), .program(let rhsProgram, let rhsDate)):
            return lhsProgram == rhsProgram && lhsDate == rhsDate
        case (.stopProgram(let lhsStopProgram, let lhsDate), .stopProgram(let rhsStopProgram, let rhsDate)):
            return lhsStopProgram == rhsStopProgram && lhsDate == rhsDate
        default:
            return false
        }
    }
}

