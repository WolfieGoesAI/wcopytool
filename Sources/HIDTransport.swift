import Foundation
import IOKit
import IOKit.hid

/// Thin IOHIDManager wrapper for the wCopy device. Matches the known VID/PID set,
/// opens the first present device, delivers 64-byte input reports via a callback.
final class HIDTransport {
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    // Persistently allocated so the pointer handed to IOKit stays valid for the
    // lifetime of the input-report callback registration. Oversized so a larger
    // input report is never truncated.
    private let inputCapacity = 1024
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
    private var outReportSize = 64   // learned from the device on connect

    deinit { inputBuffer.deallocate() }

    /// Human-readable IOReturn code for the log.
    private func ioName(_ r: IOReturn) -> String {
        switch r {
        case kIOReturnSuccess: return "success"
        case kIOReturnNotOpen: return "notOpen"
        case kIOReturnNoDevice: return "noDevice"
        case kIOReturnExclusiveAccess: return "exclusiveAccess"
        case kIOReturnBadArgument: return "badArgument"
        case kIOReturnUnsupported: return "unsupported"
        case kIOReturnError: return "error"
        case kIOReturnNotPermitted: return "notPermitted(TCC?)"
        default: return String(format: "0x%08X", r)
        }
    }

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
        // Report-descriptor sizes — these tell us the correct Output length / whether a report ID is used.
        let inSz = intProp(dev, kIOHIDMaxInputReportSizeKey)
        let outSz = intProp(dev, kIOHIDMaxOutputReportSizeKey)
        let featSz = intProp(dev, kIOHIDMaxFeatureReportSizeKey)
        let usagePage = intProp(dev, kIOHIDPrimaryUsagePageKey)
        let usage = intProp(dev, kIOHIDPrimaryUsageKey)
        if outSz > 0 { outReportSize = outSz }
        onConnect?(connectedLabel)
        onLog?("connected \(connectedLabel)")
        onLog?(String(format: "report sizes: in=%d out=%d feature=%d  usagePage=0x%02X usage=0x%02X",
                      inSz, outSz, featSz, usagePage, usage))
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

    private func setReport(_ d: IOHIDDevice, _ type: IOHIDReportType, _ reportID: Int, _ data: [UInt8]) -> IOReturn {
        data.withUnsafeBufferPointer { ptr in
            IOHIDDeviceSetReport(d, type, CFIndex(reportID), ptr.baseAddress!, ptr.count)
        }
    }

    /// Send an Output report, with fallbacks so we discover what the firmware accepts.
    /// Tries, in order: Output/id0/len64 → Output sized to the descriptor → Output with
    /// first byte as report-ID → Feature report. Logs each attempt's result.
    @discardableResult
    func send(_ bytes: [UInt8], reportID: Int = 0) -> Bool {
        guard let d = device else { onLog?("send: not connected"); return false }
        onLog?("TX \(hex(bytes))")

        // 1) Output, report-ID 0, as given.
        var r = setReport(d, kIOHIDReportTypeOutput, reportID, bytes)
        if r == kIOReturnSuccess { return true }
        onLog?("  Output/id0/len\(bytes.count): \(ioName(r))")

        // 2) Output sized exactly to the descriptor's output report size.
        if outReportSize > 0 && outReportSize != bytes.count {
            var sized = bytes
            if sized.count < outReportSize { sized += [UInt8](repeating: 0, count: outReportSize - sized.count) }
            sized = Array(sized.prefix(outReportSize))
            r = setReport(d, kIOHIDReportTypeOutput, 0, sized)
            if r == kIOReturnSuccess { onLog?("  → sent sized len\(outReportSize)"); return true }
            onLog?("  Output/id0/len\(outReportSize): \(ioName(r))")
        }

        // 3) Treat first byte as the report ID (numbered report), rest as data.
        if let first = bytes.first {
            let rest = Array(bytes.dropFirst())
            r = setReport(d, kIOHIDReportTypeOutput, Int(first), rest)
            if r == kIOReturnSuccess { onLog?("  → sent with report-ID 0x\(String(first, radix:16))"); return true }
            onLog?("  Output/id\(first)/len\(rest.count): \(ioName(r))")
        }

        // 4) Last resort: Feature report.
        r = setReport(d, kIOHIDReportTypeFeature, reportID, bytes)
        if r == kIOReturnSuccess { onLog?("  → sent as Feature report"); return true }
        onLog?("  Feature/id0: \(ioName(r))  — all send attempts failed")
        return false
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
