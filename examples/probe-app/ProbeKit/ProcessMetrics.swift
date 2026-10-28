// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — ProbeKit: process memory proxy metrics (PLAN §2.5).
//
// iOS exposes no exact per-process memory budget to the App. The probe records
// two proxies on every memory sample:
//
//   * `phys_footprint` from `task_vm_info` — the App process footprint the
//     system accounts (includes the WKWebView's host-side memory, not the
//     separate WebContent process);
//   * `os_proc_available_memory()` — the headroom the App may use before
//     jetsam, when the platform reports it.
//
// Both are proxies, not a WebContent-process measurement. Whether they track
// jetsam on an iPhone is NOT_VERIFIED.

import Foundation

public enum ProbeProcessMetrics {
    /// The App process `phys_footprint`, in bytes, or `nil` when unavailable.
    public static func physicalFootprintBytes() -> Int64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_,
                          task_flavor_t(TASK_VM_INFO),
                          rebound,
                          &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int64(info.phys_footprint)
    }

    /// Headroom reported by `os_proc_available_memory()`, or `nil`.
    public static func availableMemoryBytes() -> Int64? {
        let value = os_proc_available_memory()
        guard value > 0 else { return nil }
        return Int64(value)
    }

    /// Physical memory installed on the device.
    public static func physicalMemoryBytes() -> Int64 {
        Int64(ProcessInfo.processInfo.physicalMemory)
    }
}
