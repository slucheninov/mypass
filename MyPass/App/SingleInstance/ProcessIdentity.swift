import Foundation
import Darwin

/// A process named by its pid AND its kernel start time.
///
/// A pid alone is reusable, so a stale notification or a recycled pid could
/// point at an unrelated process. The kernel start time (`sysctl`
/// `KERN_PROC_PID`) is independent of LaunchServices registration: a process
/// started by direct `exec` has no `NSRunningApplication.launchDate`, and a
/// process that has not created its `NSApplication` yet is invisible to
/// `runningApplications`, but both always have a kernel start time. It is also
/// readable from inside the App Sandbox, unlike `kill(pid, 0)`, which reports
/// EPERM ("may be alive") for another user-owned sandbox scope and therefore
/// cannot tell "exited" from "alive".
///
/// Ordering is (start time, pid): the strictly newer process is the greater one.
struct ProcessIdentity: Hashable, Comparable {
    let pid: Int32
    let startMicroseconds: Int64

    static func < (lhs: ProcessIdentity, rhs: ProcessIdentity) -> Bool {
        if lhs.startMicroseconds != rhs.startMicroseconds {
            return lhs.startMicroseconds < rhs.startMicroseconds
        }
        return lhs.pid < rhs.pid
    }
}

enum KernelProcessTable {
    /// The identity of `pid` as the kernel sees it right now, or `nil` when no
    /// such process exists or it has already exited and is only a zombie
    /// awaiting its parent's `wait`.
    static func identity(ofPID pid: Int32) -> ProcessIdentity? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        guard info.kp_proc.p_pid == pid, info.kp_proc.p_stat != 5 /* SZOMB */ else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        return ProcessIdentity(
            pid: pid,
            startMicroseconds: Int64(started.tv_sec) * 1_000_000 + Int64(started.tv_usec)
        )
    }

    static var current: ProcessIdentity? { identity(ofPID: getpid()) }

    /// `true` only while the very same process (same pid AND same start time) is alive.
    static func isAlive(_ identity: ProcessIdentity) -> Bool {
        Self.identity(ofPID: identity.pid) == identity
    }
}
