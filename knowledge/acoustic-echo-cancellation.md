# Acoustic echo cancellation on macOS: what we measured

Research notes from 2026-08-01. Read this before touching microphone capture or reviving the AEC
option — it records dead ends that cost a full session to find, and the measurements that killed
the whole approach.

## Verdict

**The macOS system voice-processing unit (AUVoiceIO) cancels nothing on this machine, and makes the
recording worse.** It is not a wiring bug: with a perfect internal playback reference the echo still
comes through at full strength, amplified by ~19 dB relative to a plain capture. The AEC setting was
implemented, verified end to end, and then measured to be actively harmful.

The AEC option and the whole VPIO capture path were removed on 2026-08-01. What replaced them is
the echo gate — see [echo-gate-calibration.md](echo-gate-calibration.md) — which compares the two
tracks' loudness envelopes and skips leaked utterances before recognition, backed by transcript
deduplication ([TranscriptDeduplicator.swift](../Sources/MeetingsHelper/Transcription/TranscriptDeduplicator.swift)).
Neither depends on Core Audio behaving.

## Test machine

Measurements are hardware-specific — do not generalize them without re-running the probe below.

| | |
|---|---|
| Machine | Mac mini, macOS 24.6.0 (Darwin) |
| Default input | C922 Pro Stream Webcam (USB), device 51, 48 kHz stereo |
| Default output | Mac mini built-in speakers, device 93 |
| Voice processor | VoiceProcessorV10, tuning `AID36/VPVX/database.v1.0.xml` |

The input and the output are **separate USB/built-in devices with no shared clock**. On a MacBook,
where the mic and speakers are one device with a known board ID, VPIO very likely behaves
differently. Re-measure before concluding anything there.

## The measurement

Method: play a 14 s `say` sample through the speakers starting at t=3 s, capture the microphone,
report per-second RMS in dBFS. "Floor" is the second before playback starts; "echo" is the average
over t=6…11; "rise" is the difference. Nobody spoke during the test — every dB above the floor is
speaker leakage.

| Capture path | Floor | Echo | Rise | Peak |
|---|---|---|---|---|
| Raw `AVAudioEngine` tap (AEC off) | −56.6 dB | −42.4 dB | +14.2 dB | 0.04 |
| VPIO as shipped (AGC off, ducking min) | −50.7 dB | −23.4 dB | +27.3 dB | 0.45 |
| VPIO rendering the sample itself (perfect reference) | −57.5 dB | −25.5 dB | +32.0 dB | 0.44 |
| VPIO stock (no property sets at all) | −59.2 dB | −34.8 dB | +24.4 dB | 0.10 |
| VPIO with `mEnableAdvancedDucking = true` | −58.4 dB | −23.5 dB | +34.9 dB | 0.41 |

Read the first two rows together: routing the microphone through the echo canceller made the echo
**19 dB louder** in absolute terms and **13 dB worse** relative to the noise floor. The VP voice
chain (`Dynamics` → `Voice` → `Voice_Mix` DSP nodes) applies heavy makeup gain that AGC-off does not
disable — `kAUVoiceIOProperty_VoiceProcessingEnableAGC = 0` is accepted (`agc=0` status, confirmed in
the log as property 2 `Enable_Acoustic_Gain_Control` = 0) and changes nothing about it.

Row three is the decisive one. There the probe renders the sample through the unit's own output
element, which is exactly how FaceTime feeds VPIO: the reference signal is sample-accurate, in the
same clock domain, zero latency uncertainty. If any cancellation existed, it would show up here.
Instead this is the **worst** result. The canceller is inert.

Rows four and five say the property configuration is not to blame: stock settings leak too, and
advanced ducking only shifts levels around.

### Evidence in real recordings

Recording 18:38 (27 s, AEC on, dedup off) — `transcript.json` contains five pairs of identical lines
with identical offsets, one `me` and one `others` each ("So that is the idea behind RAG",
"RAG stands for Retrieval Augmented Generation", …). Everything the speakers played landed in the
microphone track verbatim. `mic.wav` peaks reach 0.51 against 0.29 in `system.wav` — the "echo
cancelled" copy is louder than the source.

## Why it fails (from the logs)

VPIO initializes without a single error and still does nothing. The interesting lines:

```
vpPlatformUtil.mm:315   Cannot retrieve theDeviceBoardID string...     [Error, twice]
AUVPAggregate.cpp:3101  input device 51 -> ...C922 Pro Stream Webcam...; output device 93 -> BuiltInSpeakerDevice
AUVPAggregate.cpp:2683  neither new devices nor old devices are bluetooth
AUVPAggregate.cpp:6694  AUHAL reported mic channel count: 2, ref channel count: 0   → later 2
Voice_Processor: property 26 'Ref_Device_ID' is 93
Voice_Processor: property 25 'Ref_Port_Type' is 0
Voice_Processor: property 59 'Tap_Stream_Enabled' is 0
Voice_Processor: property 28 'Ref_Hardware_Physical_Sample_Rate' is 48000
Voice_Processor: property 31 'Ref_Hardware_Output_Latency' is 60
Voice_Processor: property 33 'Ref_Hardware_Output_Safety_Offset' is 48
```

So the reference path is wired: the aggregate found both devices, the DSP graph contains an `Echo`
node, `Ref_Stream_Format` and the hardware latency numbers are set, and voice processing reports it
is "not bypassed". The failure is upstream of all that — `Cannot retrieve theDeviceBoardID` means
the platform tuning lookup did not identify this Mac, so the processor runs a generic profile whose
echo stage evidently does nothing on a non-Apple input device. That is a guess about the mechanism;
the measurement is the fact.

## Side effects of enabling VPIO

Worth knowing even if the AEC option is removed, because these are user-visible:

- **It ducks other audio while recording.** `AUVPAggregate.cpp:1893 Applying -4.000000 dB of static
  ducking`, and in Core Audio: `AudioDeviceDuck(93, 0.177828, …)` = −15 dB on the built-in speakers
  during setup, then `AudioDeviceDuck(162, 0.630957, …)` = −4 dB on the aggregate. Restored with
  `AudioDeviceDuck(162, 1.000000, …)` on stop. Video played noticeably quieter during recording.
  `mEnableAdvancedDucking = false` with `mDuckingLevel = .min` does **not** prevent the static −4 dB.
- **It owns a duplex route and can steal the default output.** Releasing the unit can make macOS
  promote the built-in speaker to default output, especially after Bluetooth. `MicrophoneCapture`
  worked around this by capturing the default output/system-output devices before teardown and
  restoring them (`DefaultOutputRoute`, removed together with VPIO along with the
  `AudioObjectID` default-output read/write helpers it was the only caller of). Restore it from
  history if VPIO ever comes back.

## What does work: driving AUVoiceIO through the C API

If VPIO is ever needed again (other hardware, other purpose), this is the working recipe — it
delivers buffers reliably, ~31 callbacks/s, zero render errors:

1. `AudioComponentFindNext` on `kAudioUnitType_Output` / `kAudioUnitSubType_VoiceProcessingIO` /
   `kAudioUnitManufacturer_Apple`, then `AudioComponentInstanceNew`.
2. `kAudioOutputUnitProperty_EnableIO` = 1 on (Input scope, element 1) **and** (Output scope,
   element 0). The output side must be enabled even if unused.
3. Set one fixed client format on (Output scope, element 1) and (Input scope, element 0) — 16 kHz
   mono Float32 packed. The unit resamples from the hardware internally, so **device switches never
   change the format the app sees**. This is a real advantage over the raw engine path.
4. Input callback via `kAudioOutputUnitProperty_SetInputCallback` (Global scope, element 1); inside
   it call `AudioUnitRender` to pull the buffer.
5. Render callback on (Input scope, element 0) that memsets the buffers and sets
   `.unitRenderAction_OutputIsSilence` — the output element has to render something.
6. `AudioUnitInitialize`, then `AudioOutputUnitStart`.
7. The callback refCon must point at an object the capture class keeps alive; store it **before**
   starting the unit.

**The VPIO aggregate follows default-device switches on its own.** Verified live: the default output
was switched Mac mini Speakers → LG HDR 4K → back during a 10 s run and the callback rate never
dipped. No configuration-change handling is needed on this path — unlike `AVAudioEngine`.

## Dead ends — do not retry

- **`AVAudioInputNode.setVoiceProcessingEnabled(true)` on an input-only `AVAudioEngine` never
  delivers buffers.** The engine reports running, the tap never fires, the WAV comes out as a 4096-byte
  header with zero frames. Probe: 0 callbacks in 4 seconds.
- **Pulling the output node into the graph to "complete" it fails to initialize.** Every variant —
  `mainMixerNode`, input → muted mixer → output, VP enabled on the output node too, all combinations —
  fails `engine.start()` with **−10875** (`kAUInitialize` on the output node). There is no arrangement
  of `AVAudioEngine` that makes voice processing work for capture on this system.
- **SpeexDSP AEC** was the previous approach and was removed in favour of the system unit. If AEC is
  ever revived, note that a software canceller needs a reference signal from the system tap plus its
  own delay estimation and clock-drift tracking — a serious DSP project with an uncertain outcome,
  not a quick fix.

## `AVAudioEngine` behaviour on device switches (the raw capture path)

Not AEC, but discovered in the same investigation and load-bearing for microphone capture:

- The engine **stops itself** whenever the input device changes (headphones connect, default device
  switches) and **never restarts on its own**:
  `AVAudioEngine.mm:1458 Engine@…: iounit configuration changed > stopping the engine`.
- It then posts `.AVAudioEngineConfigurationChange` — in a burst, roughly one every 650 ms, so
  restarts must be coalesced.
- The fix in `MicrophoneCapture` (observer + 0.3 s coalesced restart) is confirmed working in
  production logs: stop at 18:00:54.765, new engine started at 18:00:55.219 — a 0.45 s gap, and audio
  continued in `mic.wav` afterwards.
- Install the tap with `format: nil`. Passing a format read just before a device switch can raise an
  Objective-C exception inside `AVAudioIONodeImpl::SetOutputFormat` that Swift cannot catch.
- Downstream, `AudioTrackWriter` recreates its converter when the incoming buffer format changes and
  pads gaps longer than 1 s with silence, so a restart on a different device keeps the track aligned
  to the shared timeline.

## Diagnostics that made this possible

- **`log` in zsh is a shell builtin that shadows the macOS CLI.** Always use `/usr/bin/log`, and never
  hide stderr — the failure otherwise looks like "no output".
- **`os_log` `.info` messages are not persisted to disk.** Only `.error` and framework Default-level
  messages survive to `log show`. The whole diagnosis came from CoreAudio/AVFAudio Default logs, not
  from the app's own logging.
- Useful invocations:

```bash
/usr/bin/log show --start "2026-08-01 18:38:50" --end "2026-08-01 18:39:30" --predicate 'process == "MeetingsHelper" AND (sender == "AudioDSP" OR sender == "CoreAudio")'
```

```bash
/usr/bin/log show --start "2026-08-01 18:00:00" --predicate 'process == "MeetingsHelper" AND sender == "AVFAudio"' | grep -E "start, was|stop, was|configuration changed"
```

- Log markers worth grepping: `AUVPAggregate.cpp`, `theDeviceBoardID`, `ref channel count`,
  `AudioDeviceDuck`, `iounit configuration changed`, `Applying .* dB of static ducking`.
- To check whether a track actually contains audio rather than trusting the UI: a 4096-byte WAV is an
  empty header. Per-second peak levels tell interruptions apart from silence.

## Reproducing the measurement

Build the probe, generate a test sample, run each mode. Playback must start at t=3 s; the probe
prints a summary line with the rise over the floor.

```bash
swiftc -O main.swift -o aectest -framework AudioToolbox -framework AVFoundation
say -o speech.aiff "The quick brown fox jumps over the lazy dog. This is a test of the echo cancellation system. The voice processor should remove this sentence from the microphone signal completely."
afconvert -f WAVE -d LEI16@16000 -c 1 speech.aiff speech.wav
```

```bash
./aectest raw & PROBE=$!; sleep 3; afplay speech.wav & wait $PROBE
```

```bash
./aectest vp & PROBE=$!; sleep 3; afplay speech.wav & wait $PROBE
```

```bash
./aectest vpplay speech.wav
```

`main.swift`:

```swift
import AVFoundation
import AudioToolbox
import Foundation

// AEC measurement probe.
// Modes:
//   raw          - AVAudioEngine input tap, no processing (baseline echo level)
//   vp           - VPIO as the app used it: silence render, AGC off, ducking min
//   vpdefault    - VPIO with no AGC/ducking property sets (stock behaviour)
//   vpduck       - VPIO like vp but with advanced ducking enabled
//   vpplay <wav> - VPIO renders the wav itself through its output element after 3 s
// Usage: aectest <mode> [playfile] [dump.wav]

let arguments = CommandLine.arguments
let mode = arguments.count > 1 ? arguments[1] : "vp"
let playFilePath = arguments.count > 2 ? arguments[2] : nil
let dumpPath = arguments.count > 3 ? arguments[3] : nil
let totalSeconds = 13

final class Meter {
    let lock = NSLock()
    var sumOfSquares: Double = 0
    var sampleCount = 0
    var peak: Float = 0
    var captured: [Float] = []
    var keepCaptured = false

    func add(_ samples: UnsafePointer<Float>, count: Int) {
        lock.lock()
        for i in 0..<count {
            let value = samples[i]
            sumOfSquares += Double(value * value)
            if abs(value) > peak { peak = abs(value) }
        }
        sampleCount += count
        if keepCaptured {
            captured.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
        }
        lock.unlock()
    }

    func drain() -> (rmsDB: Double, peak: Float) {
        lock.lock()
        defer { sumOfSquares = 0; sampleCount = 0; peak = 0; lock.unlock() }
        guard sampleCount > 0, sumOfSquares > 0 else { return (-120, peak) }
        let rms = (sumOfSquares / Double(sampleCount)).squareRoot()
        return (20 * log10(rms), peak)
    }
}

let meter = Meter()
meter.keepCaptured = dumpPath != nil

final class VPContext {
    var unit: AudioUnit?
    var playSamples: [Float]?
    var playDelayFrames = 3 * 16_000
    var renderPosition = 0
}
let context = VPContext()

let inputProc: AURenderCallback = { refCon, actionFlags, timestamp, busNumber, frameCount, _ in
    let context = Unmanaged<VPContext>.fromOpaque(refCon).takeUnretainedValue()
    guard let unit = context.unit else { return noErr }
    let byteSize = frameCount * 4
    let data = malloc(Int(byteSize))
    var bufferList = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: byteSize, mData: data)
    )
    defer { free(data) }
    let status = AudioUnitRender(unit, actionFlags, timestamp, busNumber, frameCount, &bufferList)
    guard status == noErr, let rendered = bufferList.mBuffers.mData else { return status }
    meter.add(rendered.assumingMemoryBound(to: Float.self), count: Int(frameCount))
    return noErr
}

let renderProc: AURenderCallback = { refCon, actionFlags, _, _, frameCount, ioData in
    let context = Unmanaged<VPContext>.fromOpaque(refCon).takeUnretainedValue()
    guard let ioData else { return noErr }
    let buffers = UnsafeMutableAudioBufferListPointer(ioData)
    for buffer in buffers {
        if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
    }
    guard let samples = context.playSamples,
          let out = buffers.first?.mData?.assumingMemoryBound(to: Float.self)
    else {
        actionFlags.pointee.insert(.unitRenderAction_OutputIsSilence)
        return noErr
    }
    var wroteAny = false
    for frame in 0..<Int(frameCount) {
        let position = context.renderPosition + frame - context.playDelayFrames
        if position >= 0 && position < samples.count {
            out[frame] = samples[position]
            wroteAny = true
        }
    }
    context.renderPosition += Int(frameCount)
    if !wroteAny { actionFlags.pointee.insert(.unitRenderAction_OutputIsSilence) }
    return noErr
}

func fail(_ message: String) -> Never {
    print("FAIL: \(message)")
    exit(1)
}

func check(_ status: OSStatus, _ what: String) {
    if status != noErr { fail("\(what): \(status)") }
}

var engine: AVAudioEngine?

switch mode {
case "raw":
    let audioEngine = AVAudioEngine()
    let input = audioEngine.inputNode
    let format = input.outputFormat(forBus: 0)
    print("raw capture format: \(format.sampleRate) Hz, \(format.channelCount) ch")
    input.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
        guard let channel = buffer.floatChannelData?[0] else { return }
        meter.add(channel, count: Int(buffer.frameLength))
    }
    audioEngine.prepare()
    do { try audioEngine.start() } catch { fail("engine start: \(error)") }
    engine = audioEngine

case "vp", "vpdefault", "vpduck", "vpplay":
    var description = AudioComponentDescription(
        componentType: kAudioUnitType_Output,
        componentSubType: kAudioUnitSubType_VoiceProcessingIO,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0,
        componentFlagsMask: 0
    )
    guard let component = AudioComponentFindNext(nil, &description) else { fail("no VPIO") }
    var createdUnit: AudioUnit?
    check(AudioComponentInstanceNew(component, &createdUnit), "instantiate")
    let unit = createdUnit!
    context.unit = unit

    var enabled: UInt32 = 1
    let flagSize = UInt32(MemoryLayout<UInt32>.size)
    check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enabled, flagSize), "enable input")
    check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enabled, flagSize), "enable output")

    var format = AudioStreamBasicDescription(
        mSampleRate: 16_000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
        mBytesPerPacket: 4,
        mFramesPerPacket: 1,
        mBytesPerFrame: 4,
        mChannelsPerFrame: 1,
        mBitsPerChannel: 32,
        mReserved: 0
    )
    let asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, asbdSize), "capture format")
    check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, asbdSize), "render format")

    if mode != "vpdefault" {
        var agc: UInt32 = 0
        let agcStatus = AudioUnitSetProperty(unit, kAUVoiceIOProperty_VoiceProcessingEnableAGC, kAudioUnitScope_Global, 0, &agc, flagSize)
        var ducking = AUVoiceIOOtherAudioDuckingConfiguration(
            mEnableAdvancedDucking: mode == "vpduck" ? true : false,
            mDuckingLevel: .min
        )
        let duckStatus = AudioUnitSetProperty(
            unit, kAUVoiceIOProperty_OtherAudioDuckingConfiguration, kAudioUnitScope_Global, 0,
            &ducking, UInt32(MemoryLayout<AUVoiceIOOtherAudioDuckingConfiguration>.size)
        )
        print("agc=\(agcStatus) ducking=\(duckStatus)")
    }

    if mode == "vpplay" {
        guard let playFilePath else { fail("vpplay needs a file") }
        let file = try! AVAudioFile(forReading: URL(fileURLWithPath: playFilePath))
        guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1 else {
            fail("play file must be 16 kHz mono, got \(file.processingFormat)")
        }
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try! file.read(into: buffer)
        context.playSamples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        print("loaded \(context.playSamples!.count) frames to render through the unit")
    }

    let refCon = UnsafeMutableRawPointer(Unmanaged.passUnretained(context).toOpaque())
    let callbackSize = UInt32(MemoryLayout<AURenderCallbackStruct>.size)
    var inputCallback = AURenderCallbackStruct(inputProc: inputProc, inputProcRefCon: refCon)
    check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 1, &inputCallback, callbackSize), "input callback")
    var renderCallback = AURenderCallbackStruct(inputProc: renderProc, inputProcRefCon: refCon)
    check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &renderCallback, callbackSize), "render callback")

    check(AudioUnitInitialize(unit), "initialize")
    check(AudioOutputUnitStart(unit), "start")

default:
    fail("unknown mode \(mode)")
}

var perSecondRMS: [Double] = []
for second in 1...totalSeconds {
    Thread.sleep(forTimeInterval: 1)
    let (rmsDB, peak) = meter.drain()
    perSecondRMS.append(rmsDB)
    print(String(format: "t=%02d rms=%6.1f dB  peak=%.4f", second, rmsDB, peak))
}

func averageDB(_ values: ArraySlice<Double>) -> Double {
    let powers = values.map { pow(10, $0 / 10) }
    return 10 * log10(powers.reduce(0, +) / Double(powers.count))
}

// Playback runs from t=3; use t=2 as the floor and t=6...11 as the echo window.
let floorDB = perSecondRMS[1]
let playbackDB = averageDB(perSecondRMS[5...10])
print(String(format: "SUMMARY mode=%@ floor=%.1f dB playback=%.1f dB rise=%.1f dB", mode, floorDB, playbackDB, playbackDB - floorDB))

if let dumpPath {
    let dumpFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false
    ]
    meter.lock.lock()
    let samples = meter.captured
    meter.lock.unlock()
    if let file = try? AVAudioFile(forWriting: URL(fileURLWithPath: dumpPath), settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false),
       let buffer = AVAudioPCMBuffer(pcmFormat: dumpFormat, frameCapacity: AVAudioFrameCount(samples.count)) {
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        try? file.write(from: buffer)
        print("dumped \(samples.count) frames to \(dumpPath)")
    }
}

engine?.stop()
if let unit = context.unit {
    AudioOutputUnitStop(unit)
    AudioUnitUninitialize(unit)
    AudioComponentInstanceDispose(unit)
}
```
