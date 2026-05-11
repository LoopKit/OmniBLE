//
//  PodKeepAliveView.swift
//  OmniBLE
//
//  Created by Joe Moran on 9/3/25.
//  Copyright © 2025 Joe Moran. All rights reserved.
//
//  Adapted from LoopFollow

import SwiftUI
import Combine
import Foundation

struct PodKeepAliveView: View {
    @ObservedObject var viewModel: PodKeepAliveViewModel = PodKeepAliveViewModel()

    @State private var forceRefresh = false

    @ObservedObject var bleManager = BLEManager.shared

    private var title: String
    private var initialValue: PodKeepAlive
    @State private var preference: PodKeepAlive

    init(title: String, initialValue: PodKeepAlive, onChange: @escaping (_ selectedValue: PodKeepAlive) -> Void) {
        self.title = title
        self.initialValue = initialValue
        self._preference = State(initialValue: initialValue)
        savedOnChange = onChange
    }

    var body: some View {
        List {
            refreshTypeSection

            if viewModel.podKeepAlive.isBluetooth {
                selectedDeviceSection
                availableDevicesSection
            }
        }
        .onAppear {
            self.forceRefresh.toggle()
        }
        .insetGroupedListStyle()
        .navigationBarTitle(Text(title), displayMode: .automatic)
    }

    // MARK: - Subviews / Computed Properties

    private var refreshTypeSection: some View {
        Section {
            VStack(alignment: .center, spacing: 4) {
                Text("For use with iPhone 16 or iPhone 17e when used with InPlay BLE (Atlas) DASH pods; otherwise leave disabled.", comment: "Hardware which benefits from Pod Keep Alive")
                    .font(.body)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("When enabled and pod is within range, additional pod status requests are issued to minimize pod Bluetooth disconnects.", comment: "Summary of the Pod Keep Alive concept")
                    .font(.body)
                    .foregroundColor(.primary)
            }

            Picker("Pod Keep Alive", selection: $viewModel.podKeepAlive) {
                ForEach(PodKeepAlive.allCases, id: \.self) { type in
                    Text(type.title).tag(type)
                }
            }
            .pickerStyle(MenuPickerStyle())

            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.podKeepAlive.description)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var selectedDeviceSection: some View {
        if let storedDevice = bleManager.getSelectedDevice() {
            Section(header: Text("Selected Device")) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(storedDevice.name ?? "Unknown Device")
                        .font(.headline)

                    deviceConnectionStatus(for: storedDevice)

                    HStack {
                        Spacer()
                        Button(action: {
                            bleManager.disconnect()
                        }) {
                            Text("Disconnect")
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                        Spacer()
                    }
                }
                .padding(.vertical, 8)
            }
            .id(forceRefresh)
        }
    }

    private func formattedTimeString(from seconds: TimeInterval) -> String {
        if seconds < 60 {
            return "\(Int(seconds)) seconds"
        } else {
            let minutes = Int(seconds / 60)
            let seconds = Int(seconds.truncatingRemainder(dividingBy: 60))
            return "\(minutes):\(String(format: "%02d", seconds)) minutes"
        }
    }

    private var availableDevicesSection: some View {
        Section(header: scanningStatusHeader) {
            BLEDeviceSelectionView(
                bleManager: bleManager,
                selectedFilter: viewModel.podKeepAlive,
                onSelectDevice: { device in
                    bleManager.connect(device: device)
                }
            )
        }
    }

    private var scanningStatusHeader: some View {
        Text("\(Storage.shared.selectedBLEDevice.value != nil ? "Additional" : "Scanning for") \(viewModel.podKeepAlive.title)...")
            .font(.subheadline)
            .foregroundColor(.secondary)
    }

    private func deviceConnectionStatus(for device: BLEDevice) -> some View {
        let expectedConnectionTime: TimeInterval = bleManager.expectedHeartbeatInterval() ?? 300
        let now = Date()
        let timeSinceLastConnection = device.isConnected ? 0 : now.timeIntervalSince(device.lastConnected ?? now)

        if device.isConnected {
            return Text("Connected")
                .foregroundColor(.green)
        } else if let lastConnected = device.lastConnected {
            let timeRatio = timeSinceLastConnection / expectedConnectionTime
            let timeString = formattedTimeString(from: timeSinceLastConnection)

            if timeRatio < 1.0 {
                return Text("Disconnected for \(timeString)")
                    .foregroundColor(.green)
            } else if timeRatio <= 1.15 {
                return Text("Disconnected for \(timeString)")
                    .foregroundColor(.orange)
            } else if timeRatio <= 3.0 {
                return Text("Disconnected for \(timeString)")
                    .foregroundColor(.red)
            } else {
                return Text("Last connection: \(lastConnected)")
                    .foregroundColor(.red)
            }
        } else {
            return Text("Reconnecting...")
                .foregroundColor(.orange)
        }
    }
}

fileprivate var savedOnChange: ((_ selectedValue: PodKeepAlive) -> Void)?

class PodKeepAliveViewModel: ObservableObject {
    @Published var podKeepAlive: PodKeepAlive

    private var storage = Storage.shared
    private var cancellables = Set<AnyCancellable>()

    private var isInitialSetup = true // Tracks whether the value is being set initially

    init() {
        podKeepAlive = storage.podKeepAlive.value
        setupBindings()
    }

    private func setupBindings() {
        $podKeepAlive
            .dropFirst() // Ignore the initial emission during setup
            .sink { [weak self] newValue in
                guard let self = self else { return }
                self.handlePodKeepAliveChange(oldValue: storage.podKeepAlive.value, newValue: newValue)

                // Persist the change
                storage.podKeepAlive.value = newValue
                savedOnChange?(newValue) // Ugh
            }
            .store(in: &cancellables)
    }

    private func handlePodKeepAliveChange(oldValue: PodKeepAlive, newValue: PodKeepAlive) {
        let lastUpdateTime = storage.lastUpdateTime.value
        let refreshTimerInterval = storage.refreshTimerInterval.value
        let refreshTimeTarget = lastUpdateTime + refreshTimerInterval
        var refreshInterval = refreshTimeTarget.timeIntervalSinceNow
        if refreshInterval < 0 {
            refreshInterval = .seconds(1)
        }

        switch newValue {
        case .silentTune, .whenOpen:
            /// Setup a refreshTimer to try to prevent a possible pod disconnect
            /// pod disconnect if no pod comms are done in the remaining window.
            print("handlePodKeepAliveChange: initializing refresh timer for \(refreshInterval.timeIntervalStr) with refreshTimeTarget \(timeStr(refreshTimeTarget))")
            setup_refreshTimer(when: refreshInterval)

        case .rileyLink:
            /// trigger a refresh right now if there is less than a minunte until the end of remaining window
            if refreshInterval < .seconds(60), let refresh = refreshFunc {
                print("handlePodKeepAliveChange: calling refresh with only \(refreshInterval.timeIntervalStr) left before refreshTimeTarget \(timeStr(refreshTimeTarget))")
                refresh()
            }

        case .disabled:
            break
        }

        if oldValue == .silentTune || newValue == .disabled {
            print("handlePodKeepAliveChange: stopping background task")
            BackgroundTask.shared.stopBackgroundTask()
        }

        print("handlePodKeepAliveChange: calling BLEManager.disconnect")
        BLEManager.shared.disconnect()
    }
}

enum PodKeepAlive: Int, CaseIterable, Codable {
    case disabled
    case whenOpen
    case silentTune
    case rileyLink

    var title: String {
        switch self {
        case .disabled:
            return LocalizedString("Disabled", comment: "Title string for PodKeepAlive.disabled")
        case .whenOpen:
            return LocalizedString("When Open", comment: "Title string for PodKeepAlive.whenOpen")
        case .silentTune:
            return LocalizedString("Silent Tune", comment: "Title string for PodKeepAlive.silentTune")
        case .rileyLink:
            return LocalizedString("RileyLink", comment: "Title string for PodKeepAlive.rileyLink")
        }
    }

    var description: String {
        switch self {
        case .disabled:
            return LocalizedString("Pod keep alive disabled. Pod disconnects 3 minutes after last message exchange (nominal behavior).", comment: "Description for PodKeepAlive.disabled")
        case .whenOpen:
            return LocalizedString("Pod keep alive enabled when app is in the foreground with phone unlocked. Additional pod status request issued after 2 minutes, 40 seconds.", comment: "Description for PodKeepAlive.whenOpen")
        case .silentTune:
            return LocalizedString("Pod keep alive enabled. Additional pod status request issued after 2 minutes, 40 seconds.\n\nAttempt to keep pod connected even when phone is locked by using a silent tune playing in the background. The silent tune may be interrupted by other apps. If silent tune is interrupted, pod keep alive stops working. The silent tune consumes extra iPhone battery.", comment: "Description for PodKeepAlive.silentTune")
        case .rileyLink:
            return LocalizedString("Pod keep alive enabled. Additional pod status request issued after 2 minutes.\n\nRequires a RileyLink-compatible device within Bluetooth range. Allows pod keep alive messages when app is in background. This method uses less iPhone battery and slightly more DASH battery than the Silent Tune method. The RileyLink-compatible device must be selected and be connected.", comment: "Description for PodKeepAlive.rileyLink")
        }
    }

    /// Indicates if the device type uses Bluetooth
    var isBluetooth: Bool {
        switch self {
        case .rileyLink:
            return true
        case .disabled, .whenOpen, .silentTune:
            return false
        }
    }

    var heartBeatInterval: TimeInterval? {
        switch self {
        case .rileyLink:
            return 60
        default:
            return nil
        }
    }

    var estimatedDelayBasedOnHeartbeat: Bool {
        switch self {
        case .rileyLink:
            return true
        default:
            return false
        }
    }

    /// Determines if a BLEDevice matches the specific device type
    func matches(_ device: BLEDevice) -> Bool {
        switch self {
        case .rileyLink:
            let rileyUUIDString = "0235733b-99c5-4197-b856-69219c2a3845"
            if let services = device.advertisedServices {
                return services.map { $0.lowercased() }
                    .contains(rileyUUIDString.lowercased())
            }
            return false

        case .disabled, .whenOpen, .silentTune:
            return false
        }
    }
}


class Storage {
    var bgUpdateDelay = StorageValue<Int>(key: "bgUpdateDelay", defaultValue: 10)
    var lastUpdateTime = StorageValue<Date>(key: "lastUpdateTime", defaultValue: .distantPast)
    var podKeepAlive = StorageValue<PodKeepAlive>(key: "podKeepAlive", defaultValue: .disabled)
    var selectedBLEDevice = StorageValue<BLEDevice?>(key: "selectedBLEDevice", defaultValue: nil)
    var sensorScheduleOffset = StorageValue<Double?>(key: "sensorScheduleOffset", defaultValue: nil)
    var inBackground = StorageValue<Bool>(key: "inBackground", defaultValue: false)

    // Seconds after last update to force another when pod keep alives are enabled.
    // Should be 60N + some-pad, < 180 (pod disconnect interval), > 60 (RL heartbeat interval)
    var refreshTimerInterval = StorageValue<TimeInterval>(key: "refreshTimerInterval", defaultValue: (60 * 2) + 40)

    static let shared = Storage()

    private init() {}
}


class StorageValue<T: Codable & Equatable>: ObservableObject {
    let key: String

    @Published var value: T {
        didSet {
            guard value != oldValue else { return }

            if let encodedData = try? JSONEncoder().encode(value) {
                StorageValue.defaults.set(encodedData, forKey: key)
            }
        }
    }

    var exists: Bool {
        return StorageValue.defaults.object(forKey: key) != nil
    }

    private static var defaults: UserDefaults {
        return UserDefaults.standard
    }

    init(key: String, defaultValue: T) {
        self.key = key

        if let data = StorageValue.defaults.data(forKey: key),
           let decodedValue = try? JSONDecoder().decode(T.self, from: data)
        {
            value = decodedValue
        } else {
            value = defaultValue
        }
    }

    func remove() {
        StorageValue.defaults.removeObject(forKey: key)
    }
}


import AVFoundation

class BackgroundTask {
    // MARK: - Vars

    static let shared = BackgroundTask()

    var player = AVAudioPlayer()

    // MARK: - Methods

    func startBackgroundTask(hasPod: Bool) {
        Storage.shared.inBackground.value = true
        if hasPod && Storage.shared.podKeepAlive.value == .silentTune {
            NotificationCenter.default.addObserver(self, selector: #selector(interruptedAudio), name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance())
            playAudio()
        }
    }

    func stopBackgroundTask() {
        Storage.shared.inBackground.value = false
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
        player.stop()
    }

    @objc fileprivate func interruptedAudio(_ notification: Notification) {
        if notification.name == AVAudioSession.interruptionNotification, notification.userInfo != nil,
           Storage.shared.podKeepAlive.value == .silentTune
        {
            let info = notification.userInfo!
            var intValue = 0
            (info[AVAudioSessionInterruptionTypeKey]! as AnyObject).getValue(&intValue)
            if intValue == 1 {
                playAudio()
            }
        }
    }

    fileprivate func playAudio() {
        let forResource = "blank"
        let ofType = "wav"
        do {
            let bundle = Bundle(for: OmniBLEHUDProvider.self).path(forResource: forResource, ofType: ofType)
            guard let bundle = bundle else {
                return
            }
            let alertSound = URL(fileURLWithPath: bundle)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: .mixWithOthers)
            try AVAudioSession.sharedInstance().setActive(true)
            try player = AVAudioPlayer(contentsOf: alertSound)
            // Play audio forever by setting num of loops to -1
            player.numberOfLoops = -1
            player.volume = 0.01
            player.prepareToPlay()
            player.play()
        } catch {
        }
    }
}


import CoreBluetooth

class BLEManager: NSObject, ObservableObject {

    static let shared = BLEManager()

    @Published private(set) var devices: [BLEDevice] = []

    private var centralManager: CBCentralManager!
    private var activeDevice: BluetoothDevice?

    override init() {
        super.init()

        centralManager = CBCentralManager(
            delegate: self,
            queue: .main
        )
        if let device = Storage.shared.selectedBLEDevice.value {
            devices.append(device)
            findAndUpdateDevice(with: device.id.uuidString) { device in
                device.rssi = 0
            }
            connect(device: device)
        }
    }

    func getSelectedDevice() -> BLEDevice? {
        return devices.first { $0.id == Storage.shared.selectedBLEDevice.value?.id }
    }

    func startScanning() {
        guard centralManager.state == .poweredOn else {
            return
        }
        centralManager.scanForPeripherals(withServices: nil, options: nil)

        cleanupOldDevices()
    }

    func disconnect() {
        if let device = activeDevice {
            device.disconnect()
            activeDevice = nil
            device.lastHeartbeatTime = nil
        }
        Storage.shared.selectedBLEDevice.value = nil
    }

    func connect(device: BLEDevice) {
        disconnect()

        if let matchedType = PodKeepAlive.allCases.first(where: { $0.matches(device) }) {
            Storage.shared.podKeepAlive.value = matchedType
            Storage.shared.selectedBLEDevice.value = device

            findAndUpdateDevice(with: device.id.uuidString) { device in
                device.isConnected = false
                device.lastConnected = nil
            }

            switch matchedType {
            case .rileyLink:
                activeDevice = RileyLinkHeartbeatBluetoothDevice(address: device.id.uuidString, name: device.name, bluetoothDeviceDelegate: self)
                activeDevice?.connect()
            case .silentTune, .whenOpen, .disabled:
                return
            }
        } else {
        }
    }

    func stopScanning() {
        centralManager.stopScan()
    }

    func expectedHeartbeatInterval() -> TimeInterval? {
        guard let device = activeDevice else {
            return nil
        }

        return device.expectedHeartbeatInterval()
    }

    private func addOrUpdateDevice(_ device: BLEDevice) {
        if let idx = devices.firstIndex(where: { $0.id == device.id }) {
            var updatedDevice = devices[idx]
            updatedDevice.rssi = device.rssi
            updatedDevice.lastSeen = Date()
            devices[idx] = updatedDevice
        } else {
            var newDevice = device
            newDevice.lastSeen = Date()
            devices.append(newDevice)
        }

        devices = devices
    }

    private func cleanupOldDevices() {
        let expirationDate = Date().addingTimeInterval(-600) // 10 minutes ago

        /// Get the selected device's ID (if any)
        let selectedDeviceID = Storage.shared.selectedBLEDevice.value?.id

        /// Filter devices, keeping those seen within the last 10 minutes or the selected device
        devices = devices.filter { $0.lastSeen > expirationDate || $0.id == selectedDeviceID }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            break
        default:
            print("@@@ Central state = \(central.state.rawValue), not powered on.")
        }
    }

    func centralManager(_: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber)
    {
        let uuid = peripheral.identifier
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
            .map { $0.uuidString }

        let device = BLEDevice(
            id: uuid,
            name: peripheral.name,
            rssi: RSSI.intValue,
            advertisedServices: services,
            lastSeen: Date()
        )

        addOrUpdateDevice(device)
    }

    func findAndUpdateDevice(with deviceAddress: String, update: (inout BLEDevice) -> Void) {
        if let idx = devices.firstIndex(where: { $0.id.uuidString == deviceAddress }) {
            var device = devices[idx]
            update(&device)
            devices[idx] = device

            devices = devices
        }
    }
}

extension BLEManager: BluetoothDeviceDelegate {
    func didConnectTo(bluetoothDevice: BluetoothDevice) {

        findAndUpdateDevice(with: bluetoothDevice.deviceAddress) { device in
            device.isConnected = true
            device.lastConnected = Date()
        }
    }

    func didDisconnectFrom(bluetoothDevice: BluetoothDevice) {

        findAndUpdateDevice(with: bluetoothDevice.deviceAddress) { device in
            device.isConnected = false
            device.lastConnected = Date()
        }
    }

    func heartBeat() {
        guard let device = activeDevice else {
            return
        }

        let now = Date()
        let nowTimeStr=timeStr(now)
        guard let expectedInterval = device.expectedHeartbeatInterval() else {
            device.lastHeartbeatTime = now
            // TaskScheduler.shared.checkTasksNow()
            return
        }

        let marginPercentage = 0.15 // 15% margin
        let margin = expectedInterval * marginPercentage
        let threshold = expectedInterval + margin

        if let last = device.lastHeartbeatTime {
            let elapsedTime = now.timeIntervalSince(last)
            if elapsedTime > threshold {
                let delay = elapsedTime - expectedInterval
                print("@@@ HeartBeat triggered (Delayed by \(String(format: "%.1f", delay)) seconds)")
            }
        } else {
            print("@@@ HeartBeat triggered (First heartbeat)")
        }

        device.lastHeartbeatTime = now

        let lastUpdateTime = Storage.shared.lastUpdateTime.value

        let refreshTimerInterval = Storage.shared.refreshTimerInterval.value
        let refreshTargetTime = lastUpdateTime.addingTimeInterval(refreshTimerInterval)
        let refreshTargetTimeStr = timeStr(refreshTargetTime)
        print("@@@ HeartBeat next refresh target time of \(timeStr(lastUpdateTime)) + \(refreshTimerInterval.timeIntervalStr) = \(refreshTargetTimeStr)")

        let nextExpectedHeartbeatTime = now.addingTimeInterval(expectedInterval)
        let nextExpectedHeartbeatTimeStr = timeStr(nextExpectedHeartbeatTime)
        print("@@@ HeartBeat next heartbeat expected at \(nowTimeStr) + \(expectedInterval.timeIntervalStr) = \(nextExpectedHeartbeatTimeStr)")

        let pad: TimeInterval = .seconds(5)
        if refreshTargetTime < nextExpectedHeartbeatTime - pad {
            print("@@@ HeartBeat refreshTargetTime \(refreshTargetTimeStr) within \(pad.timeIntervalStr) of nextExpectedHeartbeatTime \(nextExpectedHeartbeatTimeStr)")
            if let refresh = refreshFunc {
                print("@@@ HeartBeat calling refresh with inBackground \(Storage.shared.inBackground.value) at \(nowTimeStr)")
                refresh()
            }
        }
    }
}


protocol BluetoothDeviceDelegate: AnyObject {
    func didConnectTo(bluetoothDevice: BluetoothDevice)

    func didDisconnectFrom(bluetoothDevice: BluetoothDevice)

    func heartBeat()
}

class BluetoothDevice: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    weak var bluetoothDeviceDelegate: BluetoothDeviceDelegate?
    private(set) var deviceAddress: String
    private(set) var deviceName: String?
    private let CBUUID_Advertisement: String?
    private let servicesCBUUIDs: [CBUUID]?
    private let CBUUID_ReceiveCharacteristic: String
    private var centralManager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var timeStampLastStatusUpdate: Date
    private var receiveCharacteristic: CBCharacteristic?
    private let maxTimeToWaitForPeripheralResponse = 5.0
    private var connectTimeOutTimer: Timer?
    var lastHeartbeatTime: Date?

    init(address: String, name: String?, CBUUID_Advertisement: String?, servicesCBUUIDs: [CBUUID]?, CBUUID_ReceiveCharacteristic: String, bluetoothDeviceDelegate: BluetoothDeviceDelegate) {
        lastHeartbeatTime = nil
        deviceAddress = address
        deviceName = name

        self.servicesCBUUIDs = servicesCBUUIDs
        self.CBUUID_Advertisement = CBUUID_Advertisement
        self.CBUUID_ReceiveCharacteristic = CBUUID_ReceiveCharacteristic

        timeStampLastStatusUpdate = Date()

        self.bluetoothDeviceDelegate = bluetoothDeviceDelegate

        super.init()

        initialize()
    }

    deinit {
        disconnect()
    }

    func connect() {
        if let centralManager = centralManager, !retrievePeripherals(centralManager) {
            _ = startScanning()
        }
    }

    func disconnect() {
        if let peripheral = peripheral {
            if let centralManager = centralManager {
                centralManager.cancelPeripheralConnection(peripheral)
            }
        }
    }

    func disconnectAndForget() {
        disconnect()

        peripheral = nil
        deviceName = nil
        // deviceAddress = nil
    }

    func stopScanning() {
        centralManager?.stopScan()
    }

    func isScanning() -> Bool {
        if let centralManager = centralManager {
            return centralManager.isScanning
        }
        return false
    }

    func startScanning() -> BluetoothDevice.startScanningResult {
        var returnValue = BluetoothDevice.startScanningResult.unknown

        if let peripheral = peripheral {
            switch peripheral.state {
            case .connected:
                return .alreadyConnected
            case .connecting:
                if Date() > Date(timeInterval: maxTimeToWaitForPeripheralResponse, since: timeStampLastStatusUpdate) {
                    disconnect()
                }
                return .connecting
            default: ()
            }
        }

        var services: [CBUUID]?
        if let CBUUID_Advertisement = CBUUID_Advertisement {
            services = [CBUUID(string: CBUUID_Advertisement)]
        }

        if let centralManager = centralManager {
            if centralManager.isScanning {
                return .alreadyScanning
            }
            switch centralManager.state {
            case .poweredOn:
                centralManager.scanForPeripherals(withServices: services, options: nil)
                returnValue = .success
            case .poweredOff:
                return .poweredOff
            case .unknown:
                return .unknown
            case .unauthorized:
                return .unauthorized
            default:
                return returnValue
            }
        } else {
            returnValue = .other(reason: "centralManager is nil, can not start scanning")
        }

        return returnValue
    }

    func readValueForCharacteristic(for characteristic: CBCharacteristic) {
        peripheral?.readValue(for: characteristic)
    }

    func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic) {
        if let peripheral = peripheral {
            peripheral.setNotifyValue(enabled, for: characteristic)
        }
    }

    fileprivate func stopScanAndconnect(to peripheral: CBPeripheral) {
        centralManager?.stopScan()
        deviceAddress = peripheral.identifier.uuidString
        deviceName = peripheral.name
        peripheral.delegate = self
        self.peripheral = peripheral

        if peripheral.state == .disconnected {
            connectTimeOutTimer = Timer.scheduledTimer(timeInterval: 5.0, target: self, selector: #selector(stopConnectAndRestartScanning), userInfo: nil, repeats: false)
            centralManager?.connect(peripheral, options: nil)
        } else {
            if let newCentralManager = centralManager {
                centralManager(newCentralManager, didConnect: peripheral)
            }
        }
    }

    @objc fileprivate func stopConnectAndRestartScanning() {
        disconnectAndForget()
        _ = startScanning()
    }

    func cancelConnectionTimer() {
        if let connectTimeOutTimer = connectTimeOutTimer {
            connectTimeOutTimer.invalidate()
            self.connectTimeOutTimer = nil
        }
    }

    fileprivate func retrievePeripherals(_ central: CBCentralManager) -> Bool {
        if let uuid = UUID(uuidString: deviceAddress) {
            // trace("    uuid is not nil", log: log, category: ConstantsLog.categoryBlueToothTransmitter, type: .info)
            let peripheralArr = central.retrievePeripherals(withIdentifiers: [uuid])
            if peripheralArr.count > 0 {
                peripheral = peripheralArr[0]
                if let peripheral = peripheral {
                    peripheral.delegate = self
                    let peripheralName = peripheral.name ?? "Unknown"
                    central.connect(peripheral, options: nil)
                    return true
                }
            }
        }
        return false
    }

    func centralManager(_: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData _: [String: Any], rssi _: NSNumber) {
        timeStampLastStatusUpdate = Date()

        if peripheral.identifier.uuidString == deviceAddress {
            stopScanAndconnect(to: peripheral)
        }
    }

    func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
        cancelConnectionTimer()

        timeStampLastStatusUpdate = Date()

        bluetoothDeviceDelegate?.didConnectTo(bluetoothDevice: self)

        peripheral.discoverServices(servicesCBUUIDs)
    }

    func centralManager(_: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        timeStampLastStatusUpdate = Date()

        let peripheralName = peripheral.name ?? "Unknown"
        let errorMessage = error?.localizedDescription ?? "No error details provided"

        print("@@@ Failed to connect to peripheral '\(peripheralName)' (UUID: \(peripheral.identifier.uuidString)). Error: \(errorMessage). Retrying...")

        centralManager?.connect(peripheral, options: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        timeStampLastStatusUpdate = Date()

        if central.state == .poweredOn {
            _ = retrievePeripherals(central)
        }
    }

    func centralManager(_: CBCentralManager, didDisconnectPeripheral _: CBPeripheral, error _: Error?) {
        timeStampLastStatusUpdate = Date()

        bluetoothDeviceDelegate?.didDisconnectFrom(bluetoothDevice: self)

        if let ownPeripheral = peripheral {
            centralManager?.connect(ownPeripheral, options: nil)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices _: Error?) {
        timeStampLastStatusUpdate = Date()

        if let services = peripheral.services {
            for service in services {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        } else {
            disconnect()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error _: Error?) {
        timeStampLastStatusUpdate = Date()

        if let characteristics = service.characteristics {
            for characteristic in characteristics {
                if characteristic.uuid == CBUUID(string: CBUUID_ReceiveCharacteristic) {
                    receiveCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            }
        }
    }

    func peripheral(_: CBPeripheral, didWriteValueFor _: CBCharacteristic, error _: Error?) {
        timeStampLastStatusUpdate = Date()
    }

    func peripheral(_: CBPeripheral, didUpdateNotificationStateFor _: CBCharacteristic, error _: Error?) {
        timeStampLastStatusUpdate = Date()
    }

    func peripheral(_: CBPeripheral, didUpdateValueFor _: CBCharacteristic, error _: Error?) {
        timeStampLastStatusUpdate = Date()
    }

    func centralManager(_: CBCentralManager, willRestoreState _: [String: Any]) {
        print("@@@ Restoring BLE after crash/kill")
    }

    private func initialize() {
        var cBCentralManagerOptionRestoreIdentifierKeyToUse: String?

        cBCentralManagerOptionRestoreIdentifierKeyToUse = "LoopFollow-" + deviceAddress

        centralManager = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: true, CBCentralManagerOptionRestoreIdentifierKey: cBCentralManagerOptionRestoreIdentifierKeyToUse!])
    }

    enum startScanningResult: Equatable {
        case success
        case alreadyScanning
        case poweredOff
        case alreadyConnected
        case connecting
        case unknown
        case unauthorized
        case nfcScanNeeded
        case other(reason: String)

        func description() -> String {
            switch self {
            case .success:
                return "success"
            case .alreadyScanning:
                return "alreadyScanning"
            case .poweredOff:
                return "poweredOff"
            case .alreadyConnected:
                return "alreadyConnected"
            case .connecting:
                return "connecting"
            case let .other(reason):
                return "other reason : " + reason
            case .unknown:
                return "unknown"
            case .unauthorized:
                return "unauthorized"
            case .nfcScanNeeded:
                return "nfcScanNeeded"
            }
        }
    }

    func expectedHeartbeatInterval() -> TimeInterval? {
        return nil
    }
}

extension BLEManager {
    /// Returns the expected sensor fetch offset as a formatted string ("mm:ss (fetch delay: XX sec)")
    /// for Dexcom and RileyLink devices. The expected offset is computed as the sensor's schedule offset plus the polling delay.
    /// The device’s lastSeen time is used (mod cycleDuration) to calculate the effective delay between when the sensor value
    /// becomes available and when the fetch is actually triggered.
    func expectedSensorFetchOffsetString(for device: BLEDevice) -> String? {
        guard
            let matchedType = PodKeepAlive.allCases.first(where: { $0.matches(device) }),
            let heartBeatInterval = matchedType.heartBeatInterval,
            let sensorOffset = Storage.shared.sensorScheduleOffset.value
        else {
            return nil
        }

        let heartbeatLast: Date? = {
            if matchedType.estimatedDelayBasedOnHeartbeat {
                guard device.isConnected, let lastHeartbeat = activeDevice?.lastHeartbeatTime else {
                    return nil
                }
                return lastHeartbeat
            } else {
                return device.lastSeen
            }
        }()

        guard let heartbeatLast = heartbeatLast else {
            return nil
        }

        let pollingDelay: TimeInterval = Double(Storage.shared.bgUpdateDelay.value)

        let expectedOffset = sensorOffset + pollingDelay

        // If the heartbeat interval isn't a typical 60 or 300 seconds,
        // we simply return a string indicating that the delay is "up to" the heartbeat interval.
        if heartBeatInterval != 60, heartBeatInterval != 300 {
            return "up to \(Int(heartBeatInterval)) sec"
        }

        let effectiveDelay = CycleHelper.computeDelay(sensorOffset: expectedOffset, heartbeatLast: heartbeatLast, heartbeatInterval: heartBeatInterval)

        return "\(Int(effectiveDelay)) sec"
    }
}


class RileyLinkHeartbeatBluetoothDevice: BluetoothDevice {
    private let CBUUID_Service_RileyLink: String = "0235733B-99C5-4197-B856-69219C2A3845"
    private let CBUUID_ReceiveCharacteristic_TimerTick: String = "6E6C7910-B89E-43A5-78AF-50C5E2B86F7E"
    private let CBUUID_ReceiveCharacteristic_Data: String = "C842E849-5028-42E2-867C-016ADADA9155"

    var refreshFunc: (() -> Void)?

    init(address: String, name: String?, bluetoothDeviceDelegate: BluetoothDeviceDelegate) {
        super.init(
            address: address,
            name: name,
            CBUUID_Advertisement: nil,
            servicesCBUUIDs: [CBUUID(string: CBUUID_Service_RileyLink)],
            CBUUID_ReceiveCharacteristic: CBUUID_ReceiveCharacteristic_TimerTick,
            bluetoothDeviceDelegate: bluetoothDeviceDelegate
        )
    }

    override func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        super.centralManager(central, didConnect: peripheral)
    }

    override func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        super.peripheral(peripheral, didUpdateValueFor: characteristic, error: error)

        guard characteristic.uuid == CBUUID(string: CBUUID_ReceiveCharacteristic_TimerTick) else {
            return
        }

        bluetoothDeviceDelegate?.heartBeat()
    }

    override func expectedHeartbeatInterval() -> TimeInterval? {
        return 60
    }
}


enum CycleHelper {
    /// Returns a positive modulus value (always between 0 and modulus).
    static func positiveModulo(_ value: TimeInterval, modulus: TimeInterval) -> TimeInterval {
        let remainder = value.truncatingRemainder(dividingBy: modulus)
        return remainder < 0 ? remainder + modulus : remainder
    }

    /// Calculates the cycle offset for a given date relative to midnight.
    /// The offset is the number of seconds into the cycle (i.e., date mod interval).
    static func cycleOffset(for date: Date, interval: TimeInterval) -> TimeInterval {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let secondsSinceMidnight = date.timeIntervalSince(startOfDay)
        return secondsSinceMidnight.truncatingRemainder(dividingBy: interval)
    }

    /// Same as above, but takes a timestamp (seconds since 1970) instead of a Date.
    static func cycleOffset(for timestamp: TimeInterval, interval: TimeInterval) -> TimeInterval {
        let date = Date(timeIntervalSince1970: timestamp)
        return cycleOffset(for: date, interval: interval)
    }

    /// Computes the delay experienced when using a heartbeat device to read a sensor value.
    /// The calculation is based on a sensor reference (Date) and sensor interval.
    /// All calculations assume midnight as the base reference.
    static func computeDelay(sensorReference: Date,
                             sensorInterval: TimeInterval,
                             heartbeatLast: Date,
                             heartbeatInterval: TimeInterval) -> TimeInterval
    {
        let sensorOffset = cycleOffset(for: sensorReference, interval: sensorInterval)
        let hbOffset = cycleOffset(for: heartbeatLast, interval: heartbeatInterval)
        return positiveModulo(hbOffset - sensorOffset, modulus: heartbeatInterval)
    }

    /// Overloaded version of computeDelay where the sensor cycle offset is already known.
    static func computeDelay(sensorOffset: TimeInterval,
                             heartbeatLast: Date,
                             heartbeatInterval: TimeInterval) -> TimeInterval
    {
        let hbOffset = cycleOffset(for: heartbeatLast, interval: heartbeatInterval)
        return positiveModulo(hbOffset - sensorOffset, modulus: heartbeatInterval)
    }
}


struct BLEDeviceSelectionView: View {
    @ObservedObject var bleManager: BLEManager
    var selectedFilter: PodKeepAlive
    var onSelectDevice: (BLEDevice) -> Void

    var body: some View {
        VStack {
            let filteredDevices = bleManager.devices.filter { selectedFilter.matches($0) && !isSelected($0) }
            let additionalStr = Storage.shared.selectedBLEDevice.value != nil ? "additional " : ""
            if filteredDevices.isEmpty {
                Text("No \(additionalStr)RileyLinks found. They will appear here when discovered.")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            } else {
                ForEach(filteredDevices, id: \.id) { device in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(device.name ?? "Unknown")

                            Text("RSSI: \(device.rssi) dBm")
                                .foregroundColor(.secondary)
                                .font(.footnote)

                            if let offset = BLEManager.shared.expectedSensorFetchOffsetString(for: device) {
                                //Text("Expected bg delay: \(offset)")
                                Text("Expected offset: \(offset)")
                                    .foregroundColor(.secondary)
                                    .font(.footnote)
                            }
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onSelectDevice(device)
                    }
                }
            }
        }
        .onAppear {
            bleManager.startScanning()
        }
        .onDisappear {
            bleManager.stopScanning()
        }
    }

    private func isSelected(_ device: BLEDevice) -> Bool {
        guard let selectedDevice = Storage.shared.selectedBLEDevice.value else {
            return false
        }
        return selectedDevice.id == device.id
    }
}


struct BLEDevice: Identifiable, Codable, Equatable {
    let id: UUID

    var name: String?
    var rssi: Int
    var isConnected: Bool
    var advertisedServices: [String]?
    var lastSeen: Date
    var lastConnected: Date?

    init(id: UUID,
         name: String? = nil,
         rssi: Int,
         isConnected: Bool = false,
         advertisedServices: [String]? = nil,
         lastSeen: Date = Date(),
         lastConnected: Date? = nil)
    {
        self.id = id
        self.name = name
        self.rssi = rssi
        self.isConnected = isConnected
        self.advertisedServices = advertisedServices
        self.lastSeen = lastSeen
        self.lastConnected = lastConnected
    }
}


fileprivate var refreshFunc: (() -> Void)? = nil

func podKeepAliveSetup(refresh: @escaping () -> Void) {

    Storage.shared.inBackground.value = false // reset to be sure
    refreshFunc = refresh /// stash the refresh function

    let podKeepAlive = Storage.shared.podKeepAlive.value

    /// Need to handle starting playing tunes or handle RL setup for cases
    /// such as when first selecting OmniBLE pump type, right after pairing
    /// and pod type is known, or any app restart issues.
    switch podKeepAlive {
    case .silentTune:
        /// Shouldn't need to start the silent tune now as we should be in foreground
        /// BackgroundTask.shared.startBackgroundTask()
        break

    case .rileyLink:
        /// Try to force an attempt to connect if there is a selected BLE heartbeat device
        /// XXX doesn't seem to work reliably, still best to manually select RL device on restarts
        let bleManager = BLEManager()
        if let device = Storage.shared.selectedBLEDevice.value {
            print("@@@ podKeepAliveSetup attempting connect to \(device.name ?? "unknown name")")
            bleManager.connect(device: device)
        }

    default:
        break /// no extra setup actions should be needed for other cases
    }
}

fileprivate func timeStr(_ when: Date) -> String {
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "HH:mm:ss"
    let str = dateFormatter.string(from: when)
    return str
}

fileprivate var refreshTimer: Timer?

/// Manages private refreshTimer to implement pod keep alives
/// when in foreground, playing a silent tune, or under Xcode.
func setup_refreshTimer(when: TimeInterval) {
    // The following code implements a timer to trigger a refresh
    // after refreshTimerInterval seconds has past since the last response,
    refreshTimer?.invalidate()
    refreshTimer = Timer(timeInterval: when, repeats: false) { _ in
        if let refresh = refreshFunc {
            print("@@@ refreshTimer expired, doing refresh at \(timeStr(Date()))")
            refresh()
        }
    }

    let now = Date()
    let refreshTimerTarget = now + when
    print("@@@ refreshTimer created for \(timeStr(now)) + \(when.timeIntervalStr) = \(timeStr(refreshTimerTarget))")
    RunLoop.main.add(refreshTimer!, forMode: .default)
}

/// Called for each pod response received.
/// Updates saved lastUpdateTime value and acts as a front end to  refreshTimer()
func gotPodResponse() {
    let now = Date()
    Storage.shared.lastUpdateTime.value = now

    let podKeepAlive = Storage.shared.podKeepAlive.value
    if podKeepAlive == .disabled || podKeepAlive == .rileyLink {
        refreshTimer?.invalidate()
        return
    }

    setup_refreshTimer(when: Storage.shared.refreshTimerInterval.value)
}
