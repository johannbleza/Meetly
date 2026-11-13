import CoreAudio
import Darwin
import Foundation

/// Reports which other apps are using the microphone, using Core Audio's per-process objects.
///
/// Needs no permission. The device-level "running somewhere" flag can't be used because
/// Meetly's own capture would set it for the whole meeting.
nonisolated enum AudioProcessMonitor {
    static func bundleIDsUsingMicrophone() -> Set<String> {
        let ownPID = getpid()
        var bundleIDs = Set<String>()

        for process in processObjects() {
            guard isRunningInput(process), pid(of: process) != ownPID,
                  let bundleID = bundleID(of: process) else {
                continue
            }
            bundleIDs.insert(bundleID)
        }
        return bundleIDs
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func processObjects() -> [AudioObjectID] {
        var propertyAddress = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &propertyAddress, 0, nil, &size) == noErr else {
            return []
        }

        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &propertyAddress, 0, nil, &size, &objects) == noErr else {
            return []
        }
        return objects
    }

    private static func isRunningInput(_ process: AudioObjectID) -> Bool {
        var propertyAddress = address(kAudioProcessPropertyIsRunningInput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(process, &propertyAddress, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    private static func pid(of process: AudioObjectID) -> pid_t? {
        var propertyAddress = address(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(process, &propertyAddress, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private static func bundleID(of process: AudioObjectID) -> String? {
        var propertyAddress = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(process, &propertyAddress, 0, nil, &size, &value)
        guard status == noErr, let bundleID = value?.takeRetainedValue() as String?, !bundleID.isEmpty else {
            return nil
        }
        return bundleID
    }
}
