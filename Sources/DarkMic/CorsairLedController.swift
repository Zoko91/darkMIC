import Foundation
import IOKit
import IOKit.hid

enum HeadsetStatus: Equatable {
    case receiverDisconnected
    case headsetOffline
    case liveLedOff
    case mutedRedLed
    case hardwareMode
}

final class CorsairLedController {
    private static let vendorID = 0x1B1C
    private static let productID = 0x0A97 // CORSAIR HS80 MAX WIRELESS Gaming Receiver
    private static let usagePage = 0xFF42

    private static let reportLength = 64
    private static let routeChild: UInt8 = 0x09
    private static let cmdSet: UInt8 = 0x01
    private static let cmdGet: UInt8 = 0x02
    private static let cmdCloseHandle: UInt8 = 0x05
    private static let cmdWriteData: UInt8 = 0x06
    private static let cmdOpenHandle: UInt8 = 0x0D

    private static let propMode: UInt8 = 0x03
    private static let propBatteryLevel: UInt8 = 0x0F
    private static let propChargeState: UInt8 = 0x10
    private static let propSubdevices: UInt8 = 0x36
    private static let propMicMute: UInt8 = 0xA6

    private enum PendingQuery {
        case micMute
        case lightingMode(muted: Bool)
    }

    private let manager: IOHIDManager
    private var device: IOHIDDevice?
    private var reportBuffer: UnsafeMutableBufferPointer<UInt8>?

    private var pendingWorkItems: [DispatchWorkItem] = []
    private var reconnectConfirmWorkItem: DispatchWorkItem?
    private var pendingQuery: PendingQuery?
    private var forceNextApply = true
    private var lastAppliedMuted: Bool?
    private var lastCommandFailed = false
    private var lastCommandSucceeded = false

    private(set) var isEnabled: Bool = true
    private(set) var status: HeadsetStatus = .receiverDisconnected {
        didSet {
            if status != oldValue {
                onStatusChange?(status)
            }
        }
    }

    var onStatusChange: ((HeadsetStatus) -> Void)?

    init(enabled: Bool = true) {
        self.isEnabled = enabled
        self.manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: Self.vendorID,
            kIOHIDProductIDKey as String: Self.productID,
            kIOHIDPrimaryUsagePageKey as String: Self.usagePage
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, dev in
            guard let context else { return }
            MainActor.assumeIsolated {
                let controller = Unmanaged<CorsairLedController>.fromOpaque(context).takeUnretainedValue()
                controller.attachDevice(dev)
            }
        }, ctx)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, dev in
            guard let context else { return }
            MainActor.assumeIsolated {
                let controller = Unmanaged<CorsairLedController>.fromOpaque(context).takeUnretainedValue()
                controller.detachDevice(dev)
            }
        }, ctx)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func stop() {
        cancelPendingWork()
        reconnectConfirmWorkItem?.cancel()
        reconnectConfirmWorkItem = nil
        if let dev = device {
            IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
            device = nil
        }
        reportBuffer?.deallocate()
        reportBuffer = nil
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        forceNextApply = true
        lastAppliedMuted = nil
        sync(force: true)
    }

    /// Queries the headset's mic mute state (prop 0xA6) and applies the right LED color:
    /// - Unmuted (boom down): mic LED OFF (0, 0, 0) — blocks the white/blue live light
    /// - Muted (boom up): mic LED RED (255, 0, 0) — keeps the red mute indicator
    func sync(force: Bool = false) {
        guard device != nil else {
            status = .receiverDisconnected
            return
        }
        if !isEnabled {
            if force {
                restoreHardwareMode()
            } else {
                // Still check online/offline so the menu bar icon tracks headset power
                queryMicMuteState()
            }
            return
        }
        if force {
            forceNextApply = true
        }
        queryMicMuteState()
    }

    private func attachDevice(_ dev: IOHIDDevice) {
        guard device == nil else { return }
        guard IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return }

        let buf = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: Self.reportLength)
        buf.initialize(repeating: 0)
        reportBuffer = buf
        device = dev
        lastAppliedMuted = nil
        forceNextApply = true

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            dev,
            buf.baseAddress!,
            buf.count,
            { context, _, _, _, _, report, length in
                guard let context, length >= 5 else { return }
                let buffer = UnsafeBufferPointer(start: report, count: length)
                MainActor.assumeIsolated {
                    let controller = Unmanaged<CorsairLedController>.fromOpaque(context).takeUnretainedValue()
                    controller.handleReport(buffer)
                }
            },
            ctx
        )
        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        sync(force: true)
    }

    private func detachDevice(_ dev: IOHIDDevice) {
        guard let current = device, CFEqual(current, dev) else { return }
        cancelPendingWork()
        reconnectConfirmWorkItem?.cancel()
        reconnectConfirmWorkItem = nil
        IOHIDDeviceClose(current, IOOptionBits(kIOHIDOptionsTypeNone))
        device = nil
        reportBuffer?.deallocate()
        reportBuffer = nil
        lastAppliedMuted = nil
        pendingQuery = nil
        status = .receiverDisconnected
    }

    private func queryMicMuteState() {
        pendingQuery = .micMute
        sendReport(Self.makeFrame([0x02, Self.routeChild, Self.cmdGet, Self.propMicMute]))
    }

    private func queryLightingMode(muted: Bool) {
        pendingQuery = .lightingMode(muted: muted)
        sendReport(Self.makeFrame([0x02, Self.routeChild, Self.cmdGet, Self.propMode]))
    }

    private func scheduleReconnectConfirmation() {
        reconnectConfirmWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isEnabled else { return }
            self.sync(force: true)
        }
        reconnectConfirmWorkItem = item
        // Re-assert LED off 2 seconds after headset powers on in case firmware boot overrides it
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: item)
    }

    private func applyMicLed(muted: Bool, wasOffline: Bool) {
        cancelPendingWork()

        let micR: UInt8 = muted ? 0xFF : 0x00
        let micG: UInt8 = 0x00
        let micB: UInt8 = 0x00

        let frames: [[UInt8]] = [
            // 1. Switch headset lighting to software mode (prop 0x03 = 0x02)
            Self.makeFrame([0x02, Self.routeChild, Self.cmdSet, Self.propMode, 0x00, 0x02]),
            // 2. Open ALT_LIGHTING handle (resource 0x22)
            Self.makeFrame([0x02, Self.routeChild, Self.cmdOpenHandle, 0x00, 0x22, 0x00]),
            // 3. Write LED 0 (earcups = off) and LED 1 (mic tip = off when live, red when muted)
            Self.makeFrame([
                0x02, Self.routeChild, Self.cmdWriteData,
                0x00,                   // handle
                0x08, 0x00, 0x00, 0x00, // payload size = 8 bytes (LE32)
                0x12, 0x00,             // direct lighting header
                0x00, 0x00, 0x00,       // earcups RGB = off
                micR, micG, micB        // mic tip RGB = off (live) or red (muted)
            ]),
            // 4. Close lighting handle
            Self.makeFrame([0x02, Self.routeChild, Self.cmdCloseHandle, 0x00, 0x00])
        ]

        lastCommandFailed = false
        lastCommandSucceeded = false

        let spacing: TimeInterval = 0.055
        for (index, frame) in frames.enumerated() {
            let item = DispatchWorkItem { [weak self] in
                self?.sendReport(frame)
            }
            pendingWorkItems.append(item)
            if index == 0 {
                item.perform()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + spacing * Double(index), execute: item)
            }
        }

        let finishItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingWorkItems.removeAll()
            if self.lastCommandFailed || !self.lastCommandSucceeded {
                self.lastAppliedMuted = nil
                self.status = .headsetOffline
            } else {
                self.lastAppliedMuted = muted
                self.forceNextApply = false
                self.status = muted ? .mutedRedLed : .liveLedOff
                if wasOffline {
                    self.scheduleReconnectConfirmation()
                }
            }
        }
        pendingWorkItems.append(finishItem)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + spacing * Double(frames.count - 1) + 0.2,
            execute: finishItem
        )
    }

    private func restoreHardwareMode() {
        cancelPendingWork()
        reconnectConfirmWorkItem?.cancel()
        reconnectConfirmWorkItem = nil
        lastCommandFailed = false
        lastCommandSucceeded = false
        sendReport(Self.makeFrame([0x02, Self.routeChild, Self.cmdSet, Self.propMode, 0x00, 0x01]))

        let finishItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingWorkItems.removeAll()
            if self.lastCommandFailed || !self.lastCommandSucceeded {
                self.status = .headsetOffline
            } else {
                self.status = .hardwareMode
            }
        }
        pendingWorkItems.append(finishItem)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: finishItem)
    }

    private func cancelPendingWork() {
        for item in pendingWorkItems {
            item.cancel()
        }
        pendingWorkItems.removeAll()
    }

    private func sendReport(_ frame: [UInt8]) {
        guard let dev = device else { return }
        frame.withUnsafeBytes { raw in
            _ = IOHIDDeviceSetReport(
                dev,
                kIOHIDReportTypeOutput,
                CFIndex(0x02),
                raw.baseAddress!.assumingMemoryBound(to: UInt8.self),
                frame.count
            )
        }
    }

    private func handleReport(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard bytes.count >= 6 else { return }

        // Unsolicited notifications:
        // - Report ID 0x03: [0x03, 0x01, 0x01, propID, 0x00, val]
        // - Async push on Report ID 0x01: [0x01, 0x01, 0x01, propID, valLo, valHi]
        //   (Distinguished from cmdSet ACK [0x01, 0x01, 0x01, err] by checking known property IDs)
        let knownNotificationProps: Set<UInt8> = [
            Self.propMicMute,
            Self.propBatteryLevel,
            Self.propChargeState,
            Self.propSubdevices
        ]
        let isReport3Notification = (bytes[0] == 0x03 && bytes[1] == 0x01 && bytes[2] == 0x01)
        let isAsyncPushNotification = (bytes[0] == 0x01 && bytes[1] == 0x01 && bytes[2] == 0x01 && knownNotificationProps.contains(bytes[3]))

        if isReport3Notification || isAsyncPushNotification {
            let propID = bytes[3]
            if isEnabled && propID == Self.propMicMute {
                forceNextApply = true
                queryMicMuteState()
            } else if status == .headsetOffline || status == .receiverDisconnected {
                // Headset just came back online
                sync(force: true)
            }
            return
        }

        // Command response from subdevice 1: [0x01, 0x01, cmd, err, valLo, valHi...]
        guard bytes[0] == 0x01, bytes[1] == 0x01 else { return }
        let cmd = bytes[2]
        let err = bytes[3]

        if cmd == Self.cmdGet, let query = pendingQuery {
            // Ignore responses from other apps (e.g. PowerLevel querying 16-bit battery 0x0F)
            // when the payload does not look like a boolean/mode byte (0x00..0x02 with high byte 0x00).
            if err == 0x00 && (bytes[4] > 0x02 || bytes[5] != 0x00) {
                return
            }

            pendingQuery = nil
            guard err == 0x00 else {
                lastAppliedMuted = nil
                status = .headsetOffline
                return
            }

            let wasOffline = (status == .headsetOffline || status == .receiverDisconnected)

            switch query {
            case .micMute:
                let muted = bytes[4] != 0x00
                if !isEnabled {
                    status = .hardwareMode
                    return
                }
                if forceNextApply || lastAppliedMuted != muted || wasOffline {
                    applyMicLed(muted: muted, wasOffline: wasOffline)
                } else {
                    // Verify headset didn't silently revert to hardware mode (0x01)
                    queryLightingMode(muted: muted)
                }

            case .lightingMode(let muted):
                let mode = bytes[4]
                if mode != 0x02 {
                    applyMicLed(muted: muted, wasOffline: false)
                }
            }
            return
        }

        if cmd == Self.cmdSet || cmd == Self.cmdOpenHandle || cmd == Self.cmdWriteData || cmd == Self.cmdCloseHandle {
            if err == 0x00 {
                lastCommandSucceeded = true
            } else {
                lastCommandFailed = true
            }
        }
    }

    private static func makeFrame(_ prefix: [UInt8]) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: reportLength)
        let count = min(prefix.count, reportLength)
        for i in 0..<count {
            frame[i] = prefix[i]
        }
        return frame
    }
}
