//
//  NotificationSettingsView.swift
//  OmniBLE
//
//  Created by Pete Schwamb on 2/3/21.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import LoopAlgorithm
import LoopKit
import LoopKitUI
import SwiftUI

struct NotificationSettingsView: View {

    var dateFormatter: DateFormatter
    
    @Binding var expirationReminderDefault: Int
    
    @State private var showingHourPicker: Bool = false
    
    var scheduledReminderDate: Date?
    
    var allowedScheduledReminderDates: [Date]?
    
    var lowReservoirReminderValue: Int
    
    var onSaveScheduledExpirationReminder: ((_ selectedDate: Date?, _ completion: @escaping (_ error: Error?) -> Void) -> Void)?
    
    var onSaveLowReservoirReminder: ((_ selectedValue: Int, _ completion: @escaping (_ error: Error?) -> Void) -> Void)?
    
    var insulinQuantityFormatter = QuantityFormatter(for: .internationalUnit)

    var body: some View {
        RoundedCardScrollView {
            RoundedCard(
                title: LocalizedString("Omnipod Reminders", comment: "Title for omnipod reminders section"),
                footer: LocalizedString("A reminder is configured during Pod setup to notify you in advance of Pod expiration. Set the number of hours advance notice you would like to configure by default when pairing a new Pod.", comment: "Footer text for omnipod reminders section")
            ) {
                ExpirationReminderPickerView(expirationReminderDefault: $expirationReminderDefault)
            }

            if let allowedDates = allowedScheduledReminderDates {
                RoundedCard(
                    footer: LocalizedString("Expiration reminder time for the current Pod.", comment: "Footer text for scheduled reminder area"))
                {
                    Text(LocalizedString("Scheduled Reminder", comment: "Title of scheduled reminder card on NotificationSettingsView"))
                    Divider()
                    scheduledReminderRow(scheduledDate: scheduledReminderDate, allowedDates: allowedDates)
                }
            }

            RoundedCard(footer: LocalizedString("You will be notified when the amount of insulin in the Pod reaches this level.", comment: "Footer text for low reservoir value row")) {
                lowReservoirValueRow
            }

            RoundedCard<EmptyView>(
                title: LocalizedString("Critical Alerts", comment: "Title for critical alerts description"),
                footer: LocalizedString("The reminders above will not sound on your device when it is in Silent or Do Not Disturb mode. There are other critical Pod alerts that will sound on your device even when set to Silent or Do Not Disturb mode.\n\nThe Pod will also use audible beeps for all Pod reminders and alerts except when the Pod is Silenced.", comment: "Description text for critical alerts")
            )
        }
        .navigationBarTitle(LocalizedString("Notification Settings", comment: "navigation title for notification settings"))
    }
    
    @State private var scheduleReminderDateEditViewIsShown: Bool = false
    
    private func scheduledReminderRow(scheduledDate: Date?, allowedDates: [Date]) -> some View {
        Group {
            // Make the expiration reminder time read-only if there aren't any more available times.
            if allowedDates.isEmpty {
                scheduledReminderRowContents(disclosure: false)
            } else {
                NavigationLink(
                    destination: ScheduledExpirationReminderEditView(
                        scheduledExpirationReminderDate: scheduledDate,
                        allowedDates: allowedDates,
                        dateFormatter: dateFormatter,
                        onSave: onSaveScheduledExpirationReminder,
                        onFinish: { scheduleReminderDateEditViewIsShown = false }),
                    isActive: $scheduleReminderDateEditViewIsShown)
                {
                    scheduledReminderRowContents(disclosure: true)
                }
            }
        }
    }
    
    private func scheduledReminderRowContents(disclosure: Bool) -> some View {
        RoundedCardValueRow(
            label: LocalizedString("Time", comment: "Label for scheduled reminder value row"),
            value: scheduledReminderDateString(scheduledReminderDate),
            highlightValue: false,
            disclosure: disclosure
        )
    }
    
    private func scheduledReminderDateString(_ scheduledDate: Date?) -> String {
        if let scheduledDate = scheduledDate {
            return dateFormatter.string(from: scheduledDate)
        } else {
            return LocalizedString("No Reminder", comment: "Value text for no expiration reminder")
        }
    }

    @State private var lowReservoirReminderEditViewIsShown: Bool = false

    var lowReservoirValueRow: some View {
        NavigationLink(
            destination: LowReservoirReminderEditView(
                lowReservoirReminderValue: lowReservoirReminderValue,
                insulinQuantityFormatter: insulinQuantityFormatter,
                onSave: onSaveLowReservoirReminder,
                onFinish: { lowReservoirReminderEditViewIsShown = false }),
            isActive: $lowReservoirReminderEditViewIsShown)
        {
            RoundedCardValueRow(
                label: LocalizedString("Low Reservoir Reminder", comment: "Label for low reservoir reminder row"),
                value: insulinQuantityFormatter.string(from: LoopQuantity(unit: .internationalUnit, doubleValue: Double(lowReservoirReminderValue))) ?? "",
                highlightValue: false,
                disclosure: true)
        }
    }
}

struct NotificationSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        return Group {
            let now = Date()
            NavigationView {
                NotificationSettingsView(dateFormatter: DateFormatter(), expirationReminderDefault: .constant(2), scheduledReminderDate: now + TimeInterval(hours: 1), allowedScheduledReminderDates: [now, now - TimeInterval(hours: 2), now - TimeInterval(hours: 3)], lowReservoirReminderValue: 20)
                    .previewDevice(PreviewDevice(rawValue:"iPod touch (7th generation)"))
                    .previewDisplayName("iPod touch (7th generation)")
            }

            NavigationView {
                NotificationSettingsView(dateFormatter: DateFormatter(), expirationReminderDefault: .constant(2), scheduledReminderDate: now + TimeInterval(hours: 1), allowedScheduledReminderDates: [now, now - TimeInterval(hours: 2), now - TimeInterval(hours: 3)], lowReservoirReminderValue: 20)
                    .colorScheme(.dark)
                    .previewDevice(PreviewDevice(rawValue: "iPhone XS Max"))
                    .previewDisplayName("iPhone XS Max - Dark")
            }
        }
    }
}
