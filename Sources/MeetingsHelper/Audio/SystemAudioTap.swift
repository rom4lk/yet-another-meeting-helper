import AudioToolbox
import AVFoundation
import Foundation

/// Captures system output using a Core Audio process tap (macOS 14.4+).
final class SystemAudioTap {
    enum Scope {
        case processes([AudioObjectID])
        case allSystemAudio(excluding: [AudioObjectID])
    }

    private let scope: Scope
    private let queue = DispatchQueue(label: "com.kovalev.MeetingsHelper.systemTap", qos: .userInitiated)

    private static let initializationAttempts = 100
    private static let ioAttempts = 20
    private static let retryDelay: TimeInterval = 0.01

    private var tapID = AudioObjectID.unknown
    private var aggregateDeviceID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?

    private(set) var format: AVAudioFormat?

    init(scope: Scope) {
        self.scope = scope
    }

    deinit { stop() }

    /// Creates the process tap and waits until its aggregate device exposes an input stream.
    func prepare() throws {
        let description: CATapDescription
        switch scope {
        case .processes(let processObjectIDs):
            guard !processObjectIDs.isEmpty else {
                throw CoreAudioError("No audio processes to tap.")
            }
            description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        case .allSystemAudio(let excludedObjectIDs):
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: excludedObjectIDs)
        }
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.name = "MeetingsHelper"

        var err = AudioHardwareCreateProcessTap(description, &tapID)
        guard err == noErr, tapID.isValid else {
            throw CoreAudioError("Cannot create process tap: \(err). The system audio recording permission is most likely missing.")
        }

        var streamDescription = try tapID.readTapStreamBasicDescription()
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw CoreAudioError("Cannot build AVAudioFormat from tap description.")
        }
        self.format = format

        // The aggregate needs only the tap. Adding the physical output device contributes a
        // second input buffer on some routes, so the callback no longer matches the tap format.
        let aggregateDescription = Self.aggregateDescription(tapUUID: description.uuid)

        err = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateDeviceID)
        guard err == noErr, aggregateDeviceID.isValid else {
            throw CoreAudioError("Cannot create aggregate device: \(err)")
        }

        do {
            try waitForAggregateInputStream()
        } catch {
            stop()
            throw error
        }
    }

    /// Starts delivering buffers on a private serial queue. The buffer is only valid for the
    /// duration of the callback — copy anything you need to keep.
    func start(
        onFirstBuffer: @escaping () -> Void,
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void
    ) throws {
        guard let format, aggregateDeviceID.isValid else {
            throw CoreAudioError("System audio tap was not prepared.")
        }

        final class DeliveryState {
            var deliveredFirstBuffer = false
            var reportedInvalidLayout = false
        }
        let deliveryState = DeliveryState()

        try createIOProc { inputData in
            let bufferCount = Int(inputData.pointee.mNumberBuffers)
            let expectedBufferCount = format.isInterleaved ? 1 : Int(format.channelCount)
            guard bufferCount == expectedBufferCount else {
                if !deliveryState.reportedInvalidLayout {
                    deliveryState.reportedInvalidLayout = true
                    Log.audio.error(
                        "System tap delivered \(bufferCount, privacy: .public) buffers; expected \(expectedBufferCount, privacy: .public)"
                    )
                }
                return
            }

            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                bufferListNoCopy: inputData,
                deallocator: nil
            ) else { return }

            onBuffer(buffer)
            if !deliveryState.deliveredFirstBuffer {
                deliveryState.deliveredFirstBuffer = true
                onFirstBuffer()
            }
        }

        try startAggregateDevice()

        switch scope {
        case .processes(let processObjectIDs):
            Log.audio.info("System audio tap started on \(processObjectIDs.count, privacy: .public) process(es)")
        case .allSystemAudio:
            Log.audio.info("System audio tap started for all system audio")
        }
    }

    static func aggregateDescription(tapUUID: UUID) -> [String: Any] {
        [
            kAudioAggregateDeviceNameKey: "MeetingsHelper Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUUID.uuidString
                ]
            ]
        ]
    }

    private func waitForAggregateInputStream() throws {
        for attempt in 0..<Self.initializationAttempts {
            if aggregateHasInputStream { return }
            if attempt + 1 < Self.initializationAttempts {
                Thread.sleep(forTimeInterval: Self.retryDelay)
            }
        }

        throw CoreAudioError("Aggregate device did not expose the system audio stream.")
    }

    private var aggregateHasInputStream: Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            aggregateDeviceID,
            &address,
            0,
            nil,
            &dataSize
        ) == noErr, dataSize >= MemoryLayout<AudioBufferList>.size else { return false }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }

        let list = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(
            aggregateDeviceID,
            &address,
            0,
            nil,
            &dataSize,
            list
        ) == noErr else { return false }

        return UnsafeMutableAudioBufferListPointer(list).contains { $0.mNumberChannels > 0 }
    }

    private func createIOProc(
        onInputData: @escaping (UnsafePointer<AudioBufferList>) -> Void
    ) throws {
        var lastError: OSStatus = noErr

        for attempt in 0..<Self.ioAttempts {
            var candidate: AudioDeviceIOProcID?
            let err = AudioDeviceCreateIOProcIDWithBlock(
                &candidate,
                aggregateDeviceID,
                queue
            ) { _, inputData, _, _, _ in
                onInputData(inputData)
            }

            if err == noErr, let candidate {
                ioProcID = candidate
                return
            }

            lastError = err
            if let candidate {
                AudioDeviceDestroyIOProcID(aggregateDeviceID, candidate)
            }
            if attempt + 1 < Self.ioAttempts {
                Thread.sleep(forTimeInterval: Self.retryDelay)
            }
        }

        throw CoreAudioError("Cannot create IO proc: \(lastError)")
    }

    private func startAggregateDevice() throws {
        var lastError: OSStatus = noErr

        for attempt in 0..<Self.ioAttempts {
            let err = AudioDeviceStart(aggregateDeviceID, ioProcID)
            if err == noErr { return }

            lastError = err
            if attempt + 1 < Self.ioAttempts {
                Thread.sleep(forTimeInterval: Self.retryDelay)
            }
        }

        throw CoreAudioError("Cannot start aggregate device: \(lastError)")
    }

    func stop() {
        if aggregateDeviceID.isValid {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            if let ioProcID {
                AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
                self.ioProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = .unknown
        }

        if tapID.isValid {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = .unknown
        }

        format = nil
    }
}
