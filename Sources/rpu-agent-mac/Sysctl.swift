import Darwin
import Foundation

enum Sysctl {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size + 1)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static func int(_ name: String) -> Int64? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
        switch size {
        case 4:
            var v: Int32 = 0
            var s = 4
            guard sysctlbyname(name, &v, &s, nil, 0) == 0 else { return nil }
            return Int64(v)
        case 8:
            var v: Int64 = 0
            var s = 8
            guard sysctlbyname(name, &v, &s, nil, 0) == 0 else { return nil }
            return v
        default:
            return nil
        }
    }
}

/// Monotonic seconds.
func monotonicNow() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
}

extension Double {
    func rounded(_ places: Int) -> Double {
        let m = pow(10.0, Double(places))
        return (self * m).rounded() / m
    }
}

extension Optional where Wrapped == Double {
    func rounded(_ places: Int) -> Double? { map { $0.rounded(places) } }
}
