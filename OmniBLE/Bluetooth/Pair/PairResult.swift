//
//  PairResult.swift
//  OmniBLE
//
//  Created by Randall Knutson on 8/4/21.
//  Copyright © 2021 Randall Knutson. All rights reserved.
//

import Foundation

struct PairResult {
    var ltk: Data
    var address: UInt32
    var msgSeq: UInt8
}
