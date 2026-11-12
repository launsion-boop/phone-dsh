// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — host process footprint sampler (GAP-39 / budgets.md §3).
//
// budgets.md §3 (R1, 2026-11-13) gives the engine-memory side of the memory
// proxy two production inputs: the platform memory-pressure warning
// (`PhoneDSHMemoryPressureObserver`) and the **host process** `phys_footprint`
// (`task_info`/`TASK_VM_INFO`). This file provides the second one.
//
// The value is booked once against §4's `App process` row and never added to
// the Engine heap row: the footprint contains the App process (including the
// host side of WKWebView), while WebContent is a separate process with no
// readable heap on iOS. The sampled engine heap therefore stays permanently
// `target`, and this value MUST NOT be converted into an Engine-heap
// percentage or fed to `reportEngineHeapBytes`.
//
// This unit only samples and reports. It never compares the footprint with a
// budget, never triggers a budget action, and leaves every §4 number and the
// existing `clearTmp -> plannedRestart` order unchanged.

import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// One host-process footprint reading, keyed by the Worker epoch it was
/// booked in (budgets.md §4: one §4 `App process` reading per epoch).
struct PhoneDSHHostFootprintReading: Equatable, Sendable {
    /// `phys_footprint` in bytes, as accounted to the App process.
    let bytes: Int
    /// Last durably closed WAL epoch at the time of the reading. Readings in
    /// the same epoch are the same booking, so only the first one is kept.
    let epoch: UInt64
}

/// Samples the host process footprint named by budgets.md §3.
enum PhoneDSHHostFootprintSampler {
    /// Reads the App process `phys_footprint`, in bytes.
    ///
    /// The syscall is `task_info(mach_task_self(), TASK_VM_INFO, ...)`. The
    /// flavor matters: `mach_task_basic_info` (`MACH_TASK_BASIC_INFO`) only
    /// carries `virtual_size` and `resident_size`, and neither is the
    /// jetsam-accounted footprint — resident size also counts clean shared
    /// pages and is not what the system books to the App process. Only
    /// `task_vm_info_data_t` (`TASK_VM_INFO`) exposes the `phys_footprint`
    /// field, so this is the flavor that actually returns the quantity §3
    /// names. (`os_proc_available_memory()` is the remaining *headroom*, not
    /// usage, so it is not an input here.)
    ///
    /// Returns `nil` when the platform does not provide the syscall or the
    /// syscall fails. A missing sample is never read as zero.
    ///
    /// NOT_VERIFIED on a device: how `phys_footprint` tracks jetsam. This
    /// sampler only reports the number the system accounts to the process.
    static func sampleBytes() -> Int? {
        #if canImport(Darwin)
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
        guard result == KERN_SUCCESS, info.phys_footprint > 0 else { return nil }
        return Int(clamping: info.phys_footprint)
        #else
        // No Mach `task_info` outside Darwin. This is not a zero reading: the
        // caller treats `nil` as "no sample".
        return nil
        #endif
    }
}
