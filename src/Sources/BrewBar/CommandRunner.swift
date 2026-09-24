import Foundation
import Darwin

/// A dedicated process group makes cancellation reach brew and its child processes.
/// All callbacks arrive on the main queue. stdout and stderr share one ordered pipe.
final class CommandRunner {
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var cancelled = false

    func run(executable: String, arguments: [String], environment: [String: String],
             standardOutputFile: URL? = nil, output: @escaping (Data) -> Void, completion: @escaping (Int32, Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else {
                DispatchQueue.main.async { completion(127, false) }; return
            }
            var actions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
            posix_spawn_file_actions_init(&actions)
            posix_spawnattr_init(&attributes)
            defer {
                posix_spawn_file_actions_destroy(&actions)
                posix_spawnattr_destroy(&attributes)
            }
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
            if let file = standardOutputFile {
                posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, file.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
            } else {
                posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO)
            }
            posix_spawn_file_actions_adddup2(&actions, fds[1], STDERR_FILENO)
            posix_spawn_file_actions_addclose(&actions, fds[0])
            posix_spawn_file_actions_addclose(&actions, fds[1])
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
            posix_spawnattr_setpgroup(&attributes, 0)
            let argv = ([executable] + arguments).map { strdup($0) } + [nil]
            let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
            var child: pid_t = 0
            self.lock.lock()
            let error = posix_spawn(&child, executable, &actions, &attributes, argv, envp)
            if error == 0 { self.pid = child }
            let wasCancelled = self.cancelled
            self.lock.unlock()
            close(fds[1])
            guard error == 0 else {
                close(fds[0])
                let message = Data("Could not launch: \(String(cString: strerror(error)))\n".utf8)
                DispatchQueue.main.async { output(message); completion(127, wasCancelled) }
                return
            }
            if wasCancelled { self.cancel() }
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = read(fds[0], &buffer, buffer.count)
                if count > 0 {
                    let data = Data(buffer.prefix(count))
                    DispatchQueue.main.async { output(data) }
                } else if count < 0 && errno == EINTR { continue }
                else { break }
            }
            close(fds[0])
            var status: Int32 = 0
            while waitpid(child, &status, 0) < 0 && errno == EINTR {}
            self.lock.lock()
            self.pid = 0
            let stopped = self.cancelled
            self.lock.unlock()
            let signal = status & 0x7f
            let code = signal == 0 ? (status >> 8) & 0xff : 128 + signal
            DispatchQueue.main.async { completion(code, stopped) }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let target = pid
        if target > 0 { kill(-target, SIGINT) }
        lock.unlock()
        guard target > 0 else { return }
        for (delay, signal) in [(3.0, SIGTERM), (6.0, SIGKILL)] {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self else { return }
                self.lock.lock()
                defer { self.lock.unlock() }
                if self.pid == target { kill(-target, signal) }
            }
        }
    }
}

struct BrewEnvironment {
    static func resolve(_ environment: [String: String]) -> (String?, [String: String]) {
        var env = environment
        let original = env["PATH", default: ""].split(separator: ":").map(String.init)
        let paths = ["/opt/homebrew/bin", "/opt/homebrew/sbin"] + original +
            ["/usr/local/bin", "/usr/local/sbin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        let unique = paths.filter { !$0.isEmpty && seen.insert($0).inserted }
        env["PATH"] = unique.joined(separator: ":")
        env["TERM"] = "dumb"
        env["NO_COLOR"] = "1"
        env["HOMEBREW_NO_COLOR"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["NONINTERACTIVE"] = "1"
        // Casks requiring administrator authentication must fail instead of waiting for a hidden prompt.
        env["SUDO_ASKPASS"] = "/usr/bin/false"
        let candidates = ["/opt/homebrew/bin/brew"] + unique.map { $0 + "/brew" }
        return (candidates.first { FileManager.default.isExecutableFile(atPath: $0) }, env)
    }
}
