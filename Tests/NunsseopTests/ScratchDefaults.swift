import Darwin
import Foundation

/// A defaults domain of a test's own, emptied when it is made. A fixed name was shared by every run of the suite at the same time (two
/// worktrees, a retry beside a run that has not ended), and one run emptying its domain emptied the other's. The runs at the same time
/// each hold a slot (a lock on a file, kept until the process ends) and the slot is in the name; so a name is shared only with a run that
/// is over, and the system's file for a domain, which stays after the domain is emptied, does not pile up past the number of slots.
final class ScratchDefaults {
    let defaults: UserDefaults
    private let name: String

    init(_ label: String) {
        name = "NunsseopTests.\(label).\(Self.slot)"
        defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
    }

    func remove() { defaults.removePersistentDomain(forName: name) }

    /// The lowest number nobody else holds. The descriptor stays open for the life of the process, which is what holds the lock.
    private static let slot: Int = {
        for number in 0..<64 {
            let fd = open(FileManager.default.temporaryDirectory.appendingPathComponent("nunsseop-test-defaults-\(number).lock").path,
                          O_CREAT | O_RDWR, 0o600)
            if fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 { return number }
            if fd >= 0 { close(fd) }
        }
        return Int(getpid())
    }()
}
