import Foundation
import IOKit
import IOKit.hid

/// Thin IOHIDManager wrapper for the wCopy device. Matches the known VID/PID set,
/// opens the first present device, delivers 64-byte input reports via a callback.
final class HIDTransport {
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    // Persistently allocated so the pointer handed to IOKit stays valid for the
    // lifetime of the input-report callback registration.
    private let inputCapacity = 64
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)

    deinit { inputBuffer.deallocate() }

    var onReport: (([UInt8]) -> Void)?
    var onConnect: ((String) -> Void)?
    var onDisconnect: (() -> Void)?
    var onLog: ((String) -> Void)?

    private(set) var connectedLabel: String = ""
    var isOpen: Bool { device != nil }

    // MARK: open / close

    /// Create the manager and start matching. Returns false if the manager can't be created.
    @discardableResult
    func start() -> Bool {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr

        // matching: array of {VendorID, ProductID}
        let matches = kKnownDevices.map { d -> CFDictionary in
            [kIOHIDVendorIDKey: d.vid, kIOHIDProductIDKey: d.pid] as CFDictionary
        }
        IOHIDManagerSetDeviceMatchingMultiple(mgr, matches as CFArray)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { ctx, _, _, dev in
            let me = Unmanaged<HIDTransport>.fromOpaque(ctx!).takeUnretainedValue()
            me.matched(dev)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { ctx, _, _, dev in
            let me = Unmanaged<HIDTransport>.fromOpaque(ctx!).takeUnretainedValue()
            me.removed(dev)
        }, ctx)

        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let r = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        if r != kIOReturnSuccess {
            onLog?(String(format: "IOHIDManagerOpen failed: 0x%08X", r))
            return false
        }
        // try any already-present device
        if let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, let d = set.first {
            matched(d)
        }
        return true
    }

    func stop() {
        if let d = device { IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeNone)) }
        device = nil
        if let m = manager {
            IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
    }

    private func intProp(_ d: IOHIDDevice, _ key: String) -> Int {
        (IOHIDDeviceGetProperty(d, key as CFString) as? Int) ?? 0
    }
    private func strProp(_ d: IOHIDDevice, _ key: String) -> String {
        (IOHIDDeviceGetProperty(d, key as CFString) as? String) ?? ""
    }

    private func matched(_ dev: IOHIDDevice) {
        if device != nil { return }   // keep the first
        let vid = intProp(dev, kIOHIDVendorIDKey)
        let pid = intProp(dev, kIOHIDProductIDKey)
        let r = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        if r != kIOReturnSuccess {
            onLog?(String(format: "IOHIDDeviceOpen %04X:%04X failed 0x%08X (permissions? run from a .app / grant Input Monitoring)", vid, pid, r))
            return
        }
        device = dev
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(dev, inputBuffer, inputCapacity, { ctx, _, _, _, _, reportPtr, reportLen in
            let me = Unmanaged<HIDTransport>.fromOpaque(ctx!).takeUnretainedValue()
            let bytes = Array(UnsafeBufferPointer(start: reportPtr, count: reportLen))
            DispatchQueue.main.async { me.onReport?(bytes) }
        }, ctx)
        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let prod = strProp(dev, kIOHIDProductKey)
        let serial = strProp(dev, kIOHIDSerialNumberKey)
        connectedLabel = String(format: "%04X:%04X  %@  SN:%@", vid, pid, prod.isEmpty ? "wCopy" : prod, serial.isEmpty ? "-" : serial)
        onConnect?(connectedLabel)
        onLog?("connected \(connectedLabel)")
    }

    private func removed(_ dev: IOHIDDevice) {
        if let cur = device, CFEqual(cur, dev) {
            device = nil
            connectedLabel = ""
            onDisconnect?()
            onLog?("device removed")
        }
    }

    // MARK: I/O

    /// Send an Output report. `reportID` 0 = unnumbered. `bytes` are the report data.
    @discardableResult
    func send(_ bytes: [UInt8], reportID: Int = 0) -> Bool {
        guard let d = device else { onLog?("send: not connected"); return false }
        var b = bytes
        let r = b.withUnsafeBufferPointer { ptr in
            IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, CFIndex(reportID), ptr.baseAddress!, ptr.count)
        }
        if r != kIOReturnSuccess {
            onLog?(String(format: "SetReport failed 0x%08X", r))
            return false
        }
        onLog?("TX \(hex(bytes))")
        return true
    }

    /// Synchronous feature-report read helper (optional; most data arrives via input callback).
    func getFeature(reportID: Int, length: Int) -> [UInt8]? {
        guard let d = device else { return nil }
        var buf = [UInt8](repeating: 0, count: length)
        var len = buf.count
        let r = buf.withUnsafeMutableBufferPointer { ptr in
            IOHIDDeviceGetReport(d, kIOHIDReportTypeFeature, CFIndex(reportID), ptr.baseAddress!, &len)
        }
        guard r == kIOReturnSuccess else { return nil }
        return Array(buf.prefix(len))
    }
}
