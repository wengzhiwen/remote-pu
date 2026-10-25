import Foundation
import IOKit

/// Small helpers over the IOKit registry.
enum IORegistry {
    /// All services matching an IOKit class name. Caller owns the returned objects.
    static func services(matching className: String) -> [io_object_t] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var result: [io_object_t] = []
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            result.append(entry)
            entry = IOIteratorNext(iterator)
        }
        return result
    }

    static func property(_ entry: io_object_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func properties(_ entry: io_object_t) -> [String: Any] {
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return [:] }
        return dict
    }

    static func name(_ entry: io_object_t) -> String {
        var buf = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(entry, &buf)
        return String(cString: buf)
    }

    static func className(_ entry: io_object_t) -> String {
        var buf = [CChar](repeating: 0, count: 128)
        IOObjectGetClass(entry, &buf)
        return String(cString: buf)
    }

    static func children(of path: String, plane: String = kIODeviceTreePlane) -> [io_object_t] {
        let parent = IORegistryEntryFromPath(kIOMainPortDefault, path)
        guard parent != 0 else { return [] }
        defer { IOObjectRelease(parent) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(parent, plane, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [io_object_t] = []
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            result.append(entry)
            entry = IOIteratorNext(iterator)
        }
        return result
    }

    static func uint32(fromData value: Any?) -> UInt32? {
        guard let data = value as? Data, data.count >= 4 else { return nil }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
    }

    static func string(fromData value: Any?) -> String? {
        if let s = value as? String { return s }
        guard let data = value as? Data else { return nil }
        let bytes = data.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
}
