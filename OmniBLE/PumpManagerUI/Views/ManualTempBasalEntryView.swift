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

    var enactBasal: ((Double,TimeInterval,(Error?)->Void) -> Void)?
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
                    Text(LocalizedString("Set Temporary Basal", comment: "Button text for setting manual temporary basal rate"))
                }
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


struct WithPopover<Content: View, PopoverContent: View>: View {

    @Binding var showPopover: Bool
    var popoverSize: CGSize? = nil
    var arrowDirections: UIPopoverArrowDirection = [.down]
    let content: () -> Content
    let popoverContent: () -> PopoverContent

    var body: some View {
        content()
            .background(
                Wrapper(showPopover: $showPopover, arrowDirections: arrowDirections, popoverSize: popoverSize, popoverContent: popoverContent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
    }

    struct Wrapper<PopoverContent: View> : UIViewControllerRepresentable {

        @Binding var showPopover: Bool
        var arrowDirections: UIPopoverArrowDirection
        let popoverSize: CGSize?
        let popoverContent: () -> PopoverContent

        func makeUIViewController(context: UIViewControllerRepresentableContext<Wrapper<PopoverContent>>) -> WrapperViewController<PopoverContent> {
            return WrapperViewController(
                popoverSize: popoverSize,
                permittedArrowDirections: arrowDirections,
                popoverContent: popoverContent) {
                self.showPopover = false
            }
        }

        func updateUIViewController(_ uiViewController: WrapperViewController<PopoverContent>,
                                    context: UIViewControllerRepresentableContext<Wrapper<PopoverContent>>) {
            uiViewController.updateSize(popoverSize)

            if showPopover {
                uiViewController.showPopover()
            }
            else {
                uiViewController.hidePopover()
            }
        }
    }

    class WrapperViewController<PopoverContent: View>: UIViewController, UIPopoverPresentationControllerDelegate {

        var popoverSize: CGSize?
        let permittedArrowDirections: UIPopoverArrowDirection
        let popoverContent: () -> PopoverContent
        let onDismiss: () -> Void

        var popoverVC: UIViewController?

        required init?(coder: NSCoder) { fatalError("") }
        init(popoverSize: CGSize?,
             permittedArrowDirections: UIPopoverArrowDirection,
             popoverContent: @escaping () -> PopoverContent,
             onDismiss: @escaping() -> Void) {
            self.popoverSize = popoverSize
            self.permittedArrowDirections = permittedArrowDirections
            self.popoverContent = popoverContent
            self.onDismiss = onDismiss
            super.init(nibName: nil, bundle: nil)
        }

        override func viewDidLoad() {
            super.viewDidLoad()
        }

        func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle {
            return .none // this is what forces popovers on iPhone
        }

        func showPopover() {
            guard popoverVC == nil else { return }
            let vc = UIHostingController(rootView: popoverContent())
            if let size = popoverSize { vc.preferredContentSize = size }
            vc.modalPresentationStyle = UIModalPresentationStyle.popover
            if let popover = vc.popoverPresentationController {
                popover.sourceView = view
                popover.permittedArrowDirections = self.permittedArrowDirections
                popover.delegate = self
            }
            popoverVC = vc
            self.present(vc, animated: true, completion: nil)
        }

        func hidePopover() {
            guard let vc = popoverVC, !vc.isBeingDismissed else { return }
            vc.dismiss(animated: true, completion: nil)
            popoverVC = nil
        }

        func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
            popoverVC = nil
            self.onDismiss()
        }

        func updateSize(_ size: CGSize?) {
            self.popoverSize = size
            if let vc = popoverVC, let size = size {
                vc.preferredContentSize = size
            }
        }
    }
}
