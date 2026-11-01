import Foundation

/// Static facts about the machine that drive model recommendations.
enum DeviceInfo {
    static var physicalMemoryBytes: UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }

    /// Rounded up to the nearest whole GB, which is how Apple markets memory.
    static var memoryGB: Int {
        let gb = Double(physicalMemoryBytes) / 1_073_741_824.0
        return Int(gb.rounded())
    }

    static var chipName: String {
        var size = 0
        if sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 {
            var buffer = [CChar](repeating: 0, count: size)
            if sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 {
                return String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return "Apple Silicon"
    }

    static var coreCount: Int {
        ProcessInfo.processInfo.processorCount
    }

    static var osVersionString: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// Liquid Glass needs macOS 26 or newer; everything below degrades to materials.
    static var supportsLiquidGlass: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    static var machineSummary: String {
        "\(chipName) · \(memoryGB) GB · \(coreCount) 核 · macOS \(osVersionString)"
    }
}
