import Foundation

/// Locks the Mac's screen immediately, like  → Lock Screen (⌃⌘Q).
enum ScreenLock {
    private typealias LockFunction = @convention(c) () -> Int32

    /// The same private function the system's Lock Screen command uses.
    private static let lockFunction: LockFunction? = {
        let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        guard let handle = dlopen(path, RTLD_NOW),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else { return nil }
        return unsafeBitCast(symbol, to: LockFunction.self)
    }()

    static func lock() {
        if let lockFunction {
            _ = lockFunction()
        } else {
            // Fallback: sleeping the display locks the Mac when a password is required after sleep.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["displaysleepnow"]
            try? process.run()
        }
    }
}
