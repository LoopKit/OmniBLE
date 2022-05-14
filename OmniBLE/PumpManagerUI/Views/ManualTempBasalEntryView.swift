//
//  ManualTempBasalEntryView.swift
//  OmniBLE
//
//  Created by Pete Schwamb on 5/14/22.
//  Copyright © 2022 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopKitUI
import LoopKit
import HealthKit

struct ManualTempBasalEntryView: View {

    @Environment(\.guidanceColors) var guidanceColors

    @State private var rateEntered: Double = 0.0
    @State private var durationEntered: TimeInterval = 0.5
    @State private var showPicker: Bool = false
    @State private var error: Error?
    @State private var enacting: Bool = false
    @State private var showingAlert: Bool = false

    var enactBasal: ((Double,TimeInterval,@escaping (Error?)->Void) -> Void)?
    var didCancel: (() -> Void)?

    private static let rateFormatter: QuantityFormatter = {
        let quantityFormatter = QuantityFormatter()
        quantityFormatter.setPreferredNumberFormatter(for: .internationalUnitsPerHour)
        quantityFormatter.numberFormatter.minimumFractionDigits = 2
        return quantityFormatter
    }()

    private var rateUnitsLabel: some View {
        Text(QuantityFormatter().string(from: .internationalUnitsPerHour))
            .foregroundColor(Color(.secondaryLabel))
    }

    private static let durationFormatter: QuantityFormatter = {
        let quantityFormatter = QuantityFormatter()
        quantityFormatter.setPreferredNumberFormatter(for: .hour())
        quantityFormatter.numberFormatter.minimumFractionDigits = 1
        quantityFormatter.numberFormatter.maximumFractionDigits = 1
        quantityFormatter.unitStyle = .long
        return quantityFormatter
    }()

    private var durationUnitsLabel: some View {
        Text(QuantityFormatter().string(from: .hour()))
            .foregroundColor(Color(.secondaryLabel))
    }

    func formatRate(_ rate: Double) -> String {
        let unit = HKUnit.internationalUnitsPerHour
        return ManualTempBasalEntryView.rateFormatter.string(from: HKQuantity(unit: unit, doubleValue: rate), for: unit) ?? ""
    }

    func formatDuration(_ duration: TimeInterval) -> String {
        let unit = HKUnit.hour()
        return ManualTempBasalEntryView.durationFormatter.string(from: HKQuantity(unit: unit, doubleValue: duration), for: unit) ?? ""
    }

    var supportedDurations: [TimeInterval] = [0.5, 1, 1.5, 2, 2.5, 3, 3.5, 4, 4.5, 5, 5.5, 6]

    var body: some View {
        NavigationView {
            VStack {
                List {
                    HStack {
                        Spacer()
                        Text(String(format: LocalizedString("%1$@ for %2$@", comment: "Summary string for temporary basal rate configuration page"), formatRate(rateEntered), formatDuration(durationEntered)))
                    }
                    HStack {
                        ResizeablePicker(selection: $rateEntered,
                                         data: Pod.supportedBasalRates,
                                         formatter: { formatRate($0) })
                        ResizeablePicker(selection: $durationEntered,
                                         data: supportedDurations,
                                         formatter: { formatDuration($0) })
                    }.frame(maxHeight: 162.0)
                    Section {
                        Text(LocalizedString("Loop will not automatically adjust your insulin delivery until the temporary basal rate finishes or is canceled.", comment: "Description text on manual temp basal action sheet"))
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Button(action: {
                    enacting = true
                    enactBasal?(rateEntered, durationEntered) { (error) in
                        enacting = false
                        self.error = error
                        if let error = error {
                            showingAlert = true
                        }
                    }
                }) {
                    HStack {
                        if enacting {
                            SwiftUI.ProgressView()
                        } else {
                            Text(LocalizedString("Set Temporary Basal", comment: "Button text for setting manual temporary basal rate"))
                        }
                    }
                }
                .disabled(enacting)
                .buttonStyle(ActionButtonStyle(.primary))
                .padding()
            }
            .navigationTitle(NSLocalizedString("Set Basal Rate", comment: "Navigation Title for ManualTempBasalEntryView"))
            .navigationBarItems(trailing: cancelButton)
            .alert(isPresented: $showingAlert, content: { alert })

        }
    }

    var alert: SwiftUI.Alert {
        let errorMessage = error?.localizedDescription ?? "Unknown"
        return SwiftUI.Alert(
            title: Text(LocalizedString("Temporary Basal Failed", comment: "Alert title for a failure to set temporary basal")),
            message: Text(String(format: LocalizedString("Unable to set a temporary basal rate: %1$@", comment: "Alert format string for a failure to set temporary basal. (1: error message)"), errorMessage))
        )
    }


    var cancelButton: some View {
        Button(NSLocalizedString("Cancel", comment: "Cancel button text in navigation bar on insert cannula screen")) {
            didCancel?()
        }
        .accessibility(identifier: "button_cancel")
    }

}


