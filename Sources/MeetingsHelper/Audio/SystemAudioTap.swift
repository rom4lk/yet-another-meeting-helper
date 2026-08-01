import AudioToolbox
import AVFoundation
import Foundation

/// Captures the audio output of a specific set of processes using a Core Audio process tap
/// (macOS 14.4+). Scoping the tap to the meeting app's processes keeps unrelated audio —
/// music, notifications, another browser tab — out of the recording.
final class SystemAudioTap {
    private let processObjectIDs: [AudioObjectID]
    private let queue = DispatchQueue(label: "com.kovalev.MeetingsHelper.systemTap", qos: .userInitiated)

    private var tapID = AudioObjectID.unknown
    private var aggregateDeviceID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?

    private(set) var format: AVAudioFormat?

    init(processObjectIDs: [AudioObjectID]) {
        self.processObjectIDs = processObjectIDs
    }

    deinit { stop() }

    /// Starts delivering buffers on a private serial queue. The buffer is only valid for the
    /// duration of the callback — copy anything you need to keep.
    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        guard !processObjectIDs.isEmpty else {
            throw CoreAudioError("No audio processes to tap.")
        }

        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
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

        Log.audio.info("System audio tap started on \(self.processObjectIDs.count, privacy: .public) process(es)")
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
