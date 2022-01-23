//
//  PeripheralManagerErrors.swift
//  OmniBLE
//
//  Created by Randall Knutson on 8/18/21.
//  Copyright © 2021 Randall Knutson. All rights reserved.
//

import Foundation

enum PeripheralManagerError: Error {
    case cbPeripheralError(Error)
    case notReady
    case incorrectResponse
    case timeout([PeripheralManager.CommandCondition])
    case emptyValue
    case unknownCharacteristic
    case serviceNotFound
    case nack
}

