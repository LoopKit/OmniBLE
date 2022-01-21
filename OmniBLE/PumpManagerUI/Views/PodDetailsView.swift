//
//  PodDetailsView.swift
//  OmniBLE
//
//  Created by Pete Schwamb on 4/14/20.
//  Copyright © 2020 Tidepool. All rights reserved.
//

import SwiftUI
import LoopKitUI

public struct PodVersion {
    var lotNumber: UInt64
    var sequenceNumber: UInt32
    var firmwareVersion: String
    var bleFirmwareVersion: String
}

struct PodDetailsView: View {
    
    var podVersion: PodVersion
    
    private func row(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
        }
    }
    
    var body: some View {
        List {
            row(LocalizedString("Lot Number", comment: "description label for lot number pod details row"), value: String(describing: podVersion.lotNumber))
            row(LocalizedString("Sequence Number", comment: "description label for sequence number pod details row"), value: String(describing: podVersion.sequenceNumber))
            row(LocalizedString("Firmware Version", comment: "description label for firmware version pod details row"), value: podVersion.firmwareVersion)
        }
        .navigationBarTitle(Text(LocalizedString("Device Details", comment: "title for device details page")), displayMode: .automatic)
    }
}

struct PodDetailsView_Previews: PreviewProvider {
    static var previews: some View {
        PodDetailsView(podVersion: PodVersion(lotNumber: 0x1234, sequenceNumber: 0x1234, firmwareVersion: "1.1.1", bleFirmwareVersion: "2.2.2"))
    }
}
