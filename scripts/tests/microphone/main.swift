// Run: scripts/tests/run_microphone_tests.sh
import Foundation

var failures = 0
func expect(_ name: String, _ condition: Bool) { if condition { print("ok   \(name)") } else { failures += 1; print("FAIL \(name)") } }

let builtIn = MicrophoneDevice(deviceID: 1, uid: "builtin", name: "MacBook Microphone")
let usb = MicrophoneDevice(deviceID: 2, uid: "usb", name: "USB Mic")

expect("no pick follows the system input",
       MicrophoneCenter.resolveActiveDevice(selectedUID: nil, devices: [builtIn, usb], systemDefault: usb) == usb)
expect("a pick wins over the system input",
       MicrophoneCenter.resolveActiveDevice(selectedUID: "builtin", devices: [builtIn, usb], systemDefault: usb) == builtIn)
expect("an unplugged pick falls back to the system input",
       MicrophoneCenter.resolveActiveDevice(selectedUID: "gone", devices: [builtIn, usb], systemDefault: usb) == usb)
expect("no system input falls back to the first device",
       MicrophoneCenter.resolveActiveDevice(selectedUID: nil, devices: [builtIn], systemDefault: nil) == builtIn)
expect("no devices at all gives nothing",
       MicrophoneCenter.resolveActiveDevice(selectedUID: "usb", devices: [], systemDefault: nil) == nil)

expect("silence reads as zero", MicrophoneCenter.meterLevel(fromRMS: 0) == 0)
expect("very quiet reads as zero", MicrophoneCenter.meterLevel(fromRMS: 0.0005) == 0)
expect("loud speech fills the meter", MicrophoneCenter.meterLevel(fromRMS: 0.5) == 1)
let normal = MicrophoneCenter.meterLevel(fromRMS: 0.05)
expect("normal speech sits in the middle (\(normal))", normal > 0.5 && normal < 0.9)

// Real hardware on this Mac (informational; a Mac with no input device still passes).
let devices = MicrophoneCenter.inputDevices()
print("input devices here: \(devices.map(\.name))")
print("system input: \(MicrophoneCenter.systemDefaultInput()?.name ?? "none")")
expect("every listed device has a name and a uid", devices.allSatisfy { !$0.name.isEmpty && !$0.uid.isEmpty })
if let system = MicrophoneCenter.systemDefaultInput() { expect("the system input is in the list", devices.contains(system)) }

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED"); exit(failures == 0 ? 0 : 1)
