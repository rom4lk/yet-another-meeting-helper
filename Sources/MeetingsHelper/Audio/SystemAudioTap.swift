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

    private var tapID = AudioObjectID.unknown
    private var aggregateDeviceID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?

    private(set) var format: AVAudioFormat?

    init(scope: Scope) {
        self.scope = scope
    }

    deinit { stop() }

    /// Starts delivering buffers on a private serial queue. The buffer is only valid for the
    /// duration of the callback — copy anything you need to keep.
    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
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

        // The tap has to live inside an aggregate device before we can pull samples from it.
        let outputUID = try AudioObjectID.readDefaultSystemOutputDevice().readDeviceUID()
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MeetingsHelper Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString
                ]
            ]
        ]

        err = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateDeviceID)
        guard err == noErr, aggregateDeviceID.isValid else {
            throw CoreAudioError("Cannot create aggregate device: \(err)")
        }

        err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, queue) { _, inputData, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil) else { return }
            onBuffer(buffer)
        }
        guard err == noErr else { throw CoreAudioError("Cannot create IO proc: \(err)") }

        err = AudioDeviceStart(aggregateDeviceID, ioProcID)
        guard err == noErr else { throw CoreAudioError("Cannot start aggregate device: \(err)") }

        switch scope {
        case .processes(let processObjectIDs):
            Log.audio.info("System audio tap started on \(processObjectIDs.count, privacy: .public) process(es)")
        case .allSystemAudio:
            Log.audio.info("System audio tap started for all system audio")
        }
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
    }
}
