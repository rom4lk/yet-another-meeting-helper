import AudioToolbox
import Foundation

/// Thin Swift wrappers over the `AudioObjectGetPropertyData` C API.
///
/// Adapted from Guilherme Rambo's AudioCap sample (MIT), trimmed to what this app needs.
/// https://github.com/insidegui/AudioCap

struct CoreAudioError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    init(_ message: String) { self.message = message }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = kAudioObjectUnknown

    var isValid: Bool { self != kAudioObjectUnknown }
}

// MARK: - Process objects

extension AudioObjectID {
    /// Every process that Core Audio currently knows about, i.e. that has performed audio I/O.
    ///
    /// Note: a process only shows up here once it actually touches audio, so right after a
    /// meeting starts the list may not contain the conferencing app yet.
    static func readProcessList() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(.system, &address, 0, nil, &dataSize)
        guard err == noErr else { throw CoreAudioError("Cannot size process list: \(err)") }

        var value = [AudioObjectID](repeating: .unknown, count: Int(dataSize) / MemoryLayout<AudioObjectID>.size)
        err = AudioObjectGetPropertyData(.system, &address, 0, nil, &dataSize, &value)
        guard err == noErr else { throw CoreAudioError("Cannot read process list: \(err)") }

        return value
    }

    var processBundleID: String? {
        guard let value = try? readString(kAudioProcessPropertyBundleID), !value.isEmpty else { return nil }
        return value
    }

    var processPID: pid_t? {
        guard let value = try? read(kAudioProcessPropertyPID, defaultValue: pid_t(-1)), value > 0 else { return nil }
        return value
    }

    /// `true` while the process is capturing from an input device (i.e. holding the microphone).
    var isRunningInput: Bool {
        (try? readBool(kAudioProcessPropertyIsRunningInput)) ?? false
    }

    /// `true` while the process is playing audio.
    var isRunningOutput: Bool {
        (try? readBool(kAudioProcessPropertyIsRunningOutput)) ?? false
    }
}

// MARK: - Devices and taps

extension AudioObjectID {
    static func readDefaultInputDevice() throws -> AudioDeviceID {
        try AudioObjectID.system.read(
            kAudioHardwarePropertyDefaultInputDevice,
            defaultValue: AudioDeviceID.unknown
        )
    }

    static func readDefaultOutputDevice() throws -> AudioDeviceID {
        try AudioObjectID.system.read(
            kAudioHardwarePropertyDefaultOutputDevice,
            defaultValue: AudioDeviceID.unknown
        )
    }

    static func readDefaultSystemOutputDevice() throws -> AudioDeviceID {
        try AudioObjectID.system.read(
            kAudioHardwarePropertyDefaultSystemOutputDevice,
            defaultValue: AudioDeviceID.unknown
        )
    }

    static func setDefaultOutputDevice(_ deviceID: AudioDeviceID) throws {
        try AudioObjectID.system.write(kAudioHardwarePropertyDefaultOutputDevice, value: deviceID)
    }

    static func setDefaultSystemOutputDevice(_ deviceID: AudioDeviceID) throws {
        try AudioObjectID.system.write(kAudioHardwarePropertyDefaultSystemOutputDevice, value: deviceID)
    }

    func readDeviceName() throws -> String {
        try readString(kAudioObjectPropertyName)
    }

    func readDeviceUID() throws -> String {
        try readString(kAudioDevicePropertyDeviceUID)
    }

    func readTapStreamBasicDescription() throws -> AudioStreamBasicDescription {
        try read(kAudioTapPropertyFormat, defaultValue: AudioStreamBasicDescription())
    }
}

// MARK: - Generic property access

extension AudioObjectID {
    func read<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        defaultValue: T
    ) throws -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)

        var dataSize: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &dataSize)
        guard err == noErr else { throw CoreAudioError("Cannot size property \(selector): \(err)") }

        var value: T = defaultValue
        err = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, ptr)
        }
        guard err == noErr else { throw CoreAudioError("Cannot read property \(selector): \(err)") }

        return value
    }

    func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        try read(selector, defaultValue: "" as CFString) as String
    }

    func readBool(_ selector: AudioObjectPropertySelector) throws -> Bool {
        let value: UInt32 = try read(selector, defaultValue: 0)
        return value == 1
    }

    func write<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        value: T
    ) throws {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var mutableValue = value
        let dataSize = UInt32(MemoryLayout<T>.size)
        let err = withUnsafePointer(to: &mutableValue) { pointer in
            AudioObjectSetPropertyData(self, &address, 0, nil, dataSize, pointer)
        }
        guard err == noErr else { throw CoreAudioError("Cannot write property \(selector): \(err)") }
    }
}
