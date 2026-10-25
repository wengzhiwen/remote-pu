import Foundation
import IOKit

func fourCC(_ s: String) -> UInt32 {
    var v: UInt32 = 0
    for b in s.utf8.prefix(4) { v = v << 8 | UInt32(b) }
    return v
}

func fourCCString(_ v: UInt32) -> String {
    let bytes = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    return String(decoding: bytes, as: UTF8.self)
}

/// AppleSMC user client (read-only). Works without root on Apple Silicon.
///
/// The kernel interface takes an 80-byte SMCKeyData_t; we address it as raw bytes at
/// the C struct offsets instead of relying on Swift struct layout:
///   0 key(u32) · 28 keyInfo.dataSize(u32) · 32 keyInfo.dataType(u32) · 36 keyInfo.attr(u8)
///   40 result(u8) · 41 status(u8) · 42 data8/command(u8) · 44 data32(u32) · 48 bytes[32]
final class SMC {
    struct KeyInfo {
        var size: UInt32
        var type: UInt32
        var typeName: String { fourCCString(type) }
    }

    private enum Cmd: UInt8 {
        case readKey = 5
        case keyFromIndex = 8
        case keyInfo = 9
    }

    private var connection: io_connect_t = 0
    private var infoCache: [UInt32: KeyInfo] = [:]

    init?() {
        let services = IORegistry.services(matching: "AppleSMC")
        guard !services.isEmpty else { return nil }
        // Apple Silicon exposes the key endpoint as AppleSMCKeysEndpoint.
        let chosen = services.first { IORegistry.className($0) == "AppleSMCKeysEndpoint" } ?? services[0]
        defer { services.forEach { IOObjectRelease($0) } }
        guard IOServiceOpen(chosen, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    private func call(_ input: [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: 80)
        var outSize = 80
        let kr = input.withUnsafeBytes { inRaw in
            output.withUnsafeMutableBytes { outRaw in
                IOConnectCallStructMethod(connection, 2, inRaw.baseAddress, 80, outRaw.baseAddress, &outSize)
            }
        }
        guard kr == KERN_SUCCESS, output[40] == 0 else { return nil }
        return output
    }

    private static func put32(_ buf: inout [UInt8], _ offset: Int, _ value: UInt32) {
        withUnsafeBytes(of: value) { for i in 0..<4 { buf[offset + i] = $0[i] } }
    }

    private static func get32(_ buf: [UInt8], _ offset: Int) -> UInt32 {
        buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }

    func keyInfo(_ key: UInt32) -> KeyInfo? {
        if let cached = infoCache[key] { return cached }
        var input = [UInt8](repeating: 0, count: 80)
        Self.put32(&input, 0, key)
        input[42] = Cmd.keyInfo.rawValue
        guard let out = call(input) else { return nil }
        let info = KeyInfo(size: Self.get32(out, 28), type: Self.get32(out, 32))
        infoCache[key] = info
        return info
    }

    func readBytes(_ key: UInt32) -> (KeyInfo, [UInt8])? {
        guard let info = keyInfo(key), info.size > 0, info.size <= 32 else { return nil }
        var input = [UInt8](repeating: 0, count: 80)
        Self.put32(&input, 0, key)
        Self.put32(&input, 28, info.size)
        input[42] = Cmd.readKey.rawValue
        guard let out = call(input) else { return nil }
        return (info, Array(out[48..<(48 + Int(info.size))]))
    }

    func read(_ key: String) -> Double? { read(fourCC(key)) }

    func read(_ key: UInt32) -> Double? {
        guard let (info, bytes) = readBytes(key) else { return nil }
        return Self.decode(type: info.typeName, bytes: bytes)
    }

    func key(at index: UInt32) -> UInt32? {
        var input = [UInt8](repeating: 0, count: 80)
        input[42] = Cmd.keyFromIndex.rawValue
        Self.put32(&input, 44, index)
        guard let out = call(input) else { return nil }
        return Self.get32(out, 0)
    }

    var keyCount: Int { Int(read("#KEY") ?? 0) }

    func allKeys() -> [UInt32] {
        (0..<UInt32(keyCount)).compactMap { key(at: $0) }
    }

    static func decode(type: String, bytes: [UInt8]) -> Double? {
        func be16() -> UInt16 { bytes.count >= 2 ? UInt16(bytes[0]) << 8 | UInt16(bytes[1]) : 0 }
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            let f = Float(bitPattern: bits)
            return f.isFinite ? Double(f) : nil
        case "ui8 ", "flag":
            return bytes.first.map(Double.init)
        case "ui16":
            return Double(be16())
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        case "si8 ":
            return bytes.first.map { Double(Int8(bitPattern: $0)) }
        case "si16":
            return Double(Int16(bitPattern: be16()))
        case "sp78":
            return Double(Int16(bitPattern: be16())) / 256
        case "fpe2":
            return Double(be16()) / 4
        case "fp88":
            return Double(be16()) / 256
        default:
            return nil
        }
    }
}

/// Temperatures, fans and system power from the SMC.
///
/// Sensor key names differ between chip generations, so instead of hard-coding them we
/// enumerate every float "T…" key once and classify by prefix (Tp/Te = CPU die,
/// Tg = GPU), keeping only plausible readings. `--dump-smc` shows what was found.
final class SMCSensors {
    let smc: SMC
    private(set) var cpuKeys: [UInt32] = []
    private(set) var gpuKeys: [UInt32] = []
    private(set) var fanCount = 0
    private(set) var hasSystemPower = false

    static let cpuPrefixes = ["Tp", "Te"]
    static let gpuPrefixes = ["Tg"]

    init(smc: SMC) {
        self.smc = smc
        for key in smc.allKeys() {
            let name = fourCCString(key)
            guard name.hasPrefix("T"), let info = smc.keyInfo(key), info.typeName == "flt ", info.size == 4,
                  let v = smc.read(key), v > 1, v < 130 else { continue }
            if Self.cpuPrefixes.contains(where: name.hasPrefix) {
                cpuKeys.append(key)
            } else if Self.gpuPrefixes.contains(where: name.hasPrefix) {
                gpuKeys.append(key)
            }
        }
        fanCount = Int(smc.read("FNum") ?? 0)
        hasSystemPower = smc.read("PSTR") != nil
    }

    private func readTemps(_ keys: [UInt32]) -> (avg: Double, max: Double)? {
        let vals = keys.compactMap { smc.read($0) }.filter { $0 > 1 && $0 < 130 }
        guard !vals.isEmpty else { return nil }
        return (vals.reduce(0, +) / Double(vals.count), vals.max()!)
    }

    func cpuTemperature() -> (avg: Double, max: Double)? { readTemps(cpuKeys) }
    func gpuTemperature() -> (avg: Double, max: Double)? { readTemps(gpuKeys) }

    func fans() -> [(rpm: Double?, min: Double?, max: Double?)] {
        (0..<fanCount).map { i in
            (smc.read("F\(i)Ac"), smc.read("F\(i)Mn"), smc.read("F\(i)Mx"))
        }
    }

    func systemPower() -> Double? {
        guard hasSystemPower, let w = smc.read("PSTR"), w >= 0, w < 2000 else { return nil }
        return w
    }

    /// Debug listing of keys, by default temperature/fan/power ones.
    func dump(all: Bool) -> String {
        var lines: [String] = ["keys: \(smc.keyCount)"]
        lines.append("cpu sensors: " + cpuKeys.map(fourCCString).joined(separator: " "))
        lines.append("gpu sensors: " + gpuKeys.map(fourCCString).joined(separator: " "))
        lines.append("fans: \(fanCount)  PSTR: \(hasSystemPower)")
        for key in smc.allKeys() {
            let name = fourCCString(key)
            guard all || ["T", "F", "P"].contains(where: name.hasPrefix) else { continue }
            guard let (info, bytes) = smc.readBytes(key) else {
                lines.append("\(name)  (unreadable)")
                continue
            }
            let value = SMC.decode(type: info.typeName, bytes: bytes).map { String(format: "%.3f", $0) } ?? "-"
            let hex = bytes.map { String(format: "%02x", $0) }.joined()
            lines.append("\(name)  [\(info.typeName)] size=\(info.size)  \(value)  0x\(hex)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Fallback CPU temperature from the HID thermal sensors ("PMU tdie*"), via private
/// IOKit SPI resolved at runtime so a missing symbol can never break the agent.
final class HIDTemperatures {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
    private typealias SetMatchingFn = @convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Int32
    private typealias CopyServicesFn = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
    private typealias CopyPropertyFn = @convention(c) (UnsafeRawPointer, CFString) -> UnsafeMutableRawPointer?
    private typealias CopyEventFn = @convention(c) (UnsafeRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    private typealias GetFloatFn = @convention(c) (UnsafeRawPointer, Int32) -> Double

    private static let temperatureEvent: Int64 = 15 // kIOHIDEventTypeTemperature

    private let copyEvent: CopyEventFn
    private let getFloat: GetFloatFn
    private let servicesArray: CFArray
    private(set) var sensors: [(name: String, ref: UnsafeRawPointer)] = []

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let createSym = dlsym(handle, "IOHIDEventSystemClientCreate"),
              let matchSym = dlsym(handle, "IOHIDEventSystemClientSetMatching"),
              let servicesSym = dlsym(handle, "IOHIDEventSystemClientCopyServices"),
              let propSym = dlsym(handle, "IOHIDServiceClientCopyProperty"),
              let eventSym = dlsym(handle, "IOHIDServiceClientCopyEvent"),
              let floatSym = dlsym(handle, "IOHIDEventGetFloatValue") else { return nil }
        let create = unsafeBitCast(createSym, to: CreateFn.self)
        let setMatching = unsafeBitCast(matchSym, to: SetMatchingFn.self)
        let copyServices = unsafeBitCast(servicesSym, to: CopyServicesFn.self)
        let copyProperty = unsafeBitCast(propSym, to: CopyPropertyFn.self)
        copyEvent = unsafeBitCast(eventSym, to: CopyEventFn.self)
        getFloat = unsafeBitCast(floatSym, to: GetFloatFn.self)

        guard let client = create(kCFAllocatorDefault) else { return nil }
        let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
        _ = setMatching(client, matching)
        guard let arrayPtr = copyServices(client) else { return nil }
        servicesArray = Unmanaged<CFArray>.fromOpaque(arrayPtr).takeRetainedValue()
        for i in 0..<CFArrayGetCount(servicesArray) {
            guard let ref = CFArrayGetValueAtIndex(servicesArray, i) else { continue }
            guard let namePtr = copyProperty(ref, "Product" as CFString) else { continue }
            let value = Unmanaged<AnyObject>.fromOpaque(namePtr).takeRetainedValue()
            if let name = value as? String { sensors.append((name, ref)) }
        }
        // `client` is intentionally kept alive for the process lifetime.
    }

    func readAll() -> [(name: String, value: Double)] {
        sensors.compactMap { sensor in
            guard let ev = copyEvent(sensor.ref, Self.temperatureEvent, 0, 0) else { return nil }
            let v = getFloat(UnsafeRawPointer(ev), Int32(Self.temperatureEvent << 16))
            Unmanaged<AnyObject>.fromOpaque(ev).release()
            return (v > 1 && v < 130) ? (sensor.name, v) : nil
        }
    }

    /// Mean/max of die sensors ("tdie").
    func cpuTemperature() -> (avg: Double, max: Double)? {
        let die = readAll().filter { $0.name.lowercased().contains("tdie") }.map(\.value)
        guard !die.isEmpty else { return nil }
        return (die.reduce(0, +) / Double(die.count), die.max()!)
    }
}
