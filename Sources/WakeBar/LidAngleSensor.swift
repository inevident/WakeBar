import Foundation
import IOKit.hid

protocol LidAngleSensing: Sendable {
    func currentAngle() async -> Double?
    func stop() async
}

extension LidAngleSensing {
    func stop() async {}
}

actor MacBookLidAngleSensor: LidAngleSensing {
    private static let noOptions = IOOptionBits(kIOHIDOptionsTypeNone)
    private static let appleVendorID = 0x05AC
    private static let lidAngleProductID = 0x8104
    private static let sensorUsagePage = 0x0020
    private static let orientationUsage = 0x008A
    private static let unavailableProbeRetryInterval: TimeInterval = 30
    private static let readFailureRetryInterval: TimeInterval = 2

    private var device: IOHIDDevice?
    private var isOpen = false
    private var nextProbeAt = Date.distantPast

    func currentAngle() -> Double? {
        if device == nil {
            guard Date() >= nextProbeAt else { return nil }
            device = Self.findReadableDevice()
            guard device != nil else {
                nextProbeAt = Date().addingTimeInterval(
                    Self.unavailableProbeRetryInterval
                )
                return nil
            }
        }

        guard let device else { return nil }

        if !isOpen {
            guard IOHIDDeviceOpen(device, Self.noOptions) == kIOReturnSuccess else {
                self.device = nil
                nextProbeAt = Date().addingTimeInterval(
                    Self.readFailureRetryInterval
                )
                return nil
            }
            isOpen = true
        }

        guard let angle = Self.readAngle(from: device) else {
            IOHIDDeviceClose(device, Self.noOptions)
            isOpen = false
            self.device = nil
            nextProbeAt = Date().addingTimeInterval(
                Self.readFailureRetryInterval
            )
            return nil
        }

        return angle
    }

    func stop() {
        if isOpen, let device {
            IOHIDDeviceClose(device, Self.noOptions)
        }
        isOpen = false
    }

    static func decodeAngle(
        report: [UInt8],
        length: Int
    ) -> Double? {
        guard length >= 3, report.count >= 3 else { return nil }
        let rawValue = UInt16(report[2]) << 8 | UInt16(report[1])
        let angle = Double(rawValue)
        guard (0...180).contains(angle) else { return nil }
        return angle
    }

    private static func findReadableDevice() -> IOHIDDevice? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, noOptions)
        guard IOHIDManagerOpen(manager, noOptions) == kIOReturnSuccess else {
            return nil
        }
        defer { IOHIDManagerClose(manager, noOptions) }

        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: appleVendorID,
            kIOHIDProductIDKey as String: lidAngleProductID,
            "UsagePage": sensorUsagePage,
            "Usage": orientationUsage
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return nil
        }

        for device in devices {
            guard IOHIDDeviceOpen(device, noOptions) == kIOReturnSuccess else {
                continue
            }
            let angle = readAngle(from: device)
            IOHIDDeviceClose(device, noOptions)
            if angle != nil {
                return device
            }
        }

        return nil
    }

    private static func readAngle(from device: IOHIDDevice) -> Double? {
        var report = [UInt8](repeating: 0, count: 8)
        var length = CFIndex(report.count)
        let result = IOHIDDeviceGetReport(
            device,
            kIOHIDReportTypeFeature,
            1,
            &report,
            &length
        )

        guard result == kIOReturnSuccess else { return nil }
        return decodeAngle(report: report, length: length)
    }
}

struct LidClosureDetector {
    private enum Position {
        case unknown
        case open
        case closed
    }

    static let closedThreshold = 5.0
    static let reopenedThreshold = 10.0
    static let requiredClosedSamples = 2
    static let invalidSamplesBeforeReset = 8

    private var position = Position.unknown
    private var consecutiveClosedSamples = 0
    private var consecutiveInvalidSamples = 0

    var isClosed: Bool {
        position == .closed
    }

    mutating func observe(angle: Double?) -> Bool {
        guard let angle,
              angle.isFinite,
              (0...180).contains(angle) else {
            consecutiveClosedSamples = 0
            consecutiveInvalidSamples += 1
            if consecutiveInvalidSamples >= Self.invalidSamplesBeforeReset {
                reset()
            }
            return false
        }

        consecutiveInvalidSamples = 0

        if angle <= Self.closedThreshold {
            consecutiveClosedSamples += 1
            guard consecutiveClosedSamples >= Self.requiredClosedSamples else {
                return false
            }

            switch position {
            case .unknown:
                position = .closed
                return false
            case .open:
                position = .closed
                return true
            case .closed:
                return false
            }
        }

        consecutiveClosedSamples = 0
        if angle >= Self.reopenedThreshold {
            position = .open
        }
        return false
    }

    mutating func reset() {
        position = .unknown
        consecutiveClosedSamples = 0
        consecutiveInvalidSamples = 0
    }
}
