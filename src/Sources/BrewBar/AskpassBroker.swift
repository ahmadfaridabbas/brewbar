import Foundation
import Darwin

/// Securely answers `sudo`'s askpass prompt for the one Homebrew command that needs an admin
/// password (a cask whose payload runs `/usr/sbin/installer -pkg`, e.g. `zoom`). Homebrew only
/// passes `sudo -A` when `SUDO_ASKPASS` is set; sudo then runs that helper and reads the password
/// from the helper's **standard output** (see `man sudo`).
///
/// SECURITY MODEL (the whole point of this type):
/// - The password is NEVER placed in `argv`, in an environment variable, or in a regular file.
/// - The helper script we write contains only two FIFO paths — not the password.
/// - When sudo runs the helper, the helper (1) writes one byte to a *request* FIFO to tell BrewBar
///   "sudo is asking now", then (2) `cat`s a *response* FIFO to its stdout. BrewBar prompts the user
///   with a native secure field, then writes the password to the response FIFO exactly once. The
///   password transits only a 0600 FIFO (an in-kernel pipe buffer; no bytes hit the filesystem) and
///   otherwise lives only in a Swift `String` held for the duration of the install.
/// - The temp directory is `0700`, both FIFOs are `0600`, owned by the current user. Everything is
///   removed when the command finishes (or on stop/clear/deinit).
///
/// Each sudo authentication re-invokes the helper (sudo may retry a few times), so the request
/// watcher loops: every time the helper signals, BrewBar is asked again. The caller decides whether
/// to re-prompt or reuse the password it already has.
final class AskpassBroker {
    /// Directory holding the helper + FIFOs (mode 0700, removed on cleanup).
    let directory: URL
    /// The askpass helper script path — this is what goes into `SUDO_ASKPASS`.
    var helperPath: String { directory.appendingPathComponent("askpass").path }
    /// FIFO the helper writes a byte to when sudo invokes it (BrewBar reads it to learn "asking now").
    private var requestPath: String { directory.appendingPathComponent("request").path }
    /// FIFO BrewBar writes the password to; the helper `cat`s it to sudo's stdin.
    private var responsePath: String { directory.appendingPathComponent("response").path }

    /// Called on the main queue each time sudo asks for the password (the helper signalled a request).
    private var onRequest: (() -> Void)?
    /// Dedicated serial queue for the blocking request WATCHER only. The response writes use the
    /// global concurrent queue instead — the watcher parks for long stretches inside a blocking
    /// FIFO `open`, so sharing one serial queue would deadlock a `sendPassword` behind it.
    private let watchQueue = DispatchQueue(label: "com.brewbar.askpass.watch", qos: .userInitiated)
    private var watching = false
    private var finished = false
    /// The password the user supplied for THIS command, cached (under `lock`) so repeated sudo
    /// prompts within the same cask operation are answered automatically without re-prompting.
    /// Lives only for the broker's lifetime (one command) and is cleared on cleanup.
    private var cachedPassword: String?

    /// Create the private directory, both FIFOs, and the helper script. Throws if anything can't be
    /// created securely. The directory name is random so it isn't predictable.
    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrewBar-askpass-\(UUID().uuidString)")
        self.directory = base
        try FileManager.default.createDirectory(at: base,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Self.makeFIFO(at: requestPath)
        try Self.makeFIFO(at: responsePath)
        let script = Self.helperScript(requestPath: requestPath, responsePath: responsePath)
        try script.write(toFile: helperPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helperPath)
    }

    deinit { cleanup() }

    /// Begin watching the request FIFO on a background queue. `onRequest` fires on the MAIN queue
    /// every time sudo invokes the helper (i.e. the user should be asked for the password now).
    func startWatching(onRequest: @escaping () -> Void) {
        guard !watching else { return }
        watching = true
        self.onRequest = onRequest
        watchQueue.async { [weak self] in self?.watchLoop() }
    }

    /// Blocking loop: open the request FIFO for reading (blocks until the helper opens it for
    /// writing), read its one-byte signal, then either auto-answer (if we already have the password
    /// for this command) or prompt the user. A single cask command can trigger `sudo` several times
    /// (e.g. uninstalling multiple launchctl services + pkg receipts); the first answer is cached so
    /// the user types their password ONCE and the rest are answered silently. Exits when finished.
    private func watchLoop() {
        while true {
            if isFinished() { return }
            // O_RDONLY on a FIFO blocks until a writer (the helper) opens it. When the helper has
            // signalled and closed, read() returns 0 (EOF); we then re-open for the next request.
            let fd = open(requestPath, O_RDONLY)
            if fd < 0 {
                if isFinished() { return }
                // Transient error (e.g. the FIFO was removed during cleanup): stop.
                return
            }
            var byte: UInt8 = 0
            // Drain the single signal byte (and any EOF).
            while read(fd, &byte, 1) > 0 { /* consume */ }
            close(fd)
            if isFinished() { return }
            // If the user already supplied the password for this command, answer this (repeat) sudo
            // prompt automatically instead of re-prompting. Otherwise ask the UI.
            lock.lock(); let cached = cachedPassword; lock.unlock()
            if let cached = cached {
                deliver(cached)
            } else {
                DispatchQueue.main.async { [weak self] in self?.onRequest?() }
            }
        }
    }

    /// Deliver the password to the waiting helper (its `cat` of the response FIFO). The password is
    /// cached so subsequent sudo prompts in the SAME command are answered automatically (see
    /// `watchLoop`). Called by the model when the user submits the secure field.
    func sendPassword(_ password: String) {
        lock.lock(); cachedPassword = password; lock.unlock()
        deliver(password)
    }

    /// Write `password` + newline to the response FIFO (what sudo reads), off the main queue.
    /// `O_WRONLY` on a FIFO blocks until the reader (the helper's `cat`) opens it.
    private func deliver(_ password: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self, !self.isFinished() else { return }
            let fd = open(self.responsePath, O_WRONLY)
            guard fd >= 0 else { return }
            var bytes = Array((password + "\n").utf8)
            bytes.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if n > 0 { offset += n }
                    else if n < 0 && errno == EINTR { continue }
                    else { break }
                }
            }
            close(fd)
            // Best-effort zero of our transient copy.
            for i in bytes.indices { bytes[i] = 0 }
        }
    }

    /// Decline the current prompt: write just a newline so the helper's `cat` yields an empty
    /// password and sudo's authentication fails (brew then aborts cleanly). Used when the user
    /// cancels the password prompt.
    func declineOnce() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self, !self.isFinished() else { return }
            let fd = open(self.responsePath, O_WRONLY)
            guard fd >= 0 else { return }
            let newline: [UInt8] = [0x0A]
            _ = newline.withUnsafeBytes { write(fd, $0.baseAddress!, 1) }
            close(fd)
        }
    }

    /// Stop watching and remove the directory (and the FIFOs + helper inside it). Idempotent.
    /// Unblocks a watcher parked in `open(O_RDONLY)` on the request FIFO, AND a helper `cat` parked
    /// in `open(O_RDONLY)` / reading the response FIFO, so neither lingers after the command ends.
    func cleanup() {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        cachedPassword = nil
        lock.unlock()
        // Nudge a blocked watcher: opening the request FIFO's write end lets its pending O_RDONLY
        // return. Nudge a parked helper `cat`: opening the response FIFO's write end and closing it
        // sends EOF, so `cat` finishes (sudo then gets an empty password and fails cleanly) instead
        // of blocking forever as an orphan — sudo's askpass child may be in a different process
        // group than brew, so `runner.cancel()`'s group signal might not reach it.
        let reqFD = open(requestPath, O_WRONLY | O_NONBLOCK)
        if reqFD >= 0 { close(reqFD) }
        let respFD = open(responsePath, O_WRONLY | O_NONBLOCK)
        if respFD >= 0 { close(respFD) }
        try? FileManager.default.removeItem(at: directory)
    }

    private let lock = NSLock()
    private func isFinished() -> Bool { lock.lock(); defer { lock.unlock() }; return finished }

    // MARK: - Pure helpers (unit-tested in RunnerTests)

    /// The helper script sudo executes. It must write the password to its STDOUT. Our helper first
    /// signals a request (one byte into the request FIFO), then streams the response FIFO to stdout.
    /// `exec cat` replaces the shell so sudo reads cat's stdout directly. Both paths are the broker's
    /// own randomly-named FIFOs, so no untrusted interpolation reaches the shell.
    static func helperScript(requestPath: String, responsePath: String) -> String {
        // `printf 'x'` writes exactly one byte to the request FIFO (blocks until BrewBar opens it to
        // read), announcing that sudo is asking. Then `exec cat` streams the password BrewBar writes
        // to the response FIFO. A single read/line is what sudo consumes.
        """
        #!/bin/sh
        printf 'x' > '\(shellSingleQuote(requestPath))'
        exec cat '\(shellSingleQuote(responsePath))'
        """
    }

    /// Escape a path for safe embedding inside a single-quoted shell string. The broker's own paths
    /// never contain quotes (they're under the temp dir with a UUID name), but escape defensively so
    /// the generated script can never break out of the quotes.
    static func shellSingleQuote(_ path: String) -> String {
        path.replacingOccurrences(of: "'", with: "'\\''")
    }

    /// Create a FIFO (named pipe) at `path` with mode 0600. Throws on failure.
    private static func makeFIFO(at path: String) throws {
        // Remove any stale node first (paranoia — the dir is fresh, but mkfifo fails on EEXIST).
        unlink(path)
        guard mkfifo(path, 0o600) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "Could not create askpass channel: \(String(cString: strerror(errno)))"])
        }
    }
}
