import Foundation
import Darwin

@main
struct ScriptRunnerTests {
    static func main() throws {
        let runner = ScriptRunner(label: "test", deadline: 3)
        let text = try runner.string("""
        return "  キッズリターン! 🎵" & linefeed & "あかねさす頃" & (character id 30) & "末尾  " & linefeed
        """)
        assert(text == "  キッズリターン! 🎵\nあかねさす頃\u{1E}末尾  \n",
               "metadata whitespace, Unicode and separators must be preserved: \(text.debugDescription)")
        let descriptor = try runner.run("return \"ok\"")
        assert(descriptor.stringValue == "ok")
        print("PASS: Unicode, record separators and metadata newlines survive output decoding")

        let large = try runner.string("""
        set mqText to "猫"
        repeat 18 times
            set mqText to mqText & mqText
        end repeat
        return mqText
        """)
        assert(large == String(repeating: "猫", count: 262_144),
               "output larger than a pipe buffer must complete without truncation")
        print("PASS: 786 KB output completes without blocking on a pipe")

        var children: [Process] = []
        let slow = ScriptRunner(label: "test-slow", deadline: 0.7, makeProcess: {
            let child = Process()
            children.append(child)
            return child
        })
        let started = Date()
        do {
            _ = try slow.string("delay 60\nreturn \"never\"")
            assertionFailure("a stalled subprocess must time out")
        } catch let error as ScriptRunner.ScriptError {
            assert(error.message.contains("応答"), error.message)
        }
        let elapsed = Date().timeIntervalSince(started)
        assert(elapsed < 1.5, "deadline did not stop the child: \(elapsed)")
        let child = children[0]
        let pid = child.processIdentifier
        assert(!child.isRunning && child.terminationReason == .uncaughtSignal
               && child.terminationStatus == SIGKILL, "deadline must forcibly stop the child")
        errno = 0
        assert(kill(pid, 0) == -1 && errno == ESRCH, "timed-out child must be killed and reaped")
        assert(slow.stalledSeconds == 0)
        let recovered = try slow.string("return \"recovered\"")
        assert(recovered == "recovered",
               "a later command must run after a timeout")
        print(String(format: "PASS: timed-out child is killed and reaped after %.3f s; next call recovers", elapsed))

        let blocked = ScriptRunner(label: "test-state", deadline: 0.7)
        let action = ScriptRunner(label: "test-action", deadline: 2)
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? blocked.string("delay 60")
            completed.signal()
        }
        while blocked.stalledSeconds == 0 { usleep(1_000) }
        let actionStart = Date()
        let actionResult = try action.string("return \"next\"")
        assert(actionResult == "next")
        assert(Date().timeIntervalSince(actionStart) < 0.5,
               "a stalled read must not delay a transport command in its own lane")
        assert(completed.wait(timeout: .now() + 2) == .success)
        print("PASS: transport runs while another read lane is blocked")

        do {
            _ = try runner.string("error \"script failed\" number 42")
            assertionFailure("script execution failure must be reported")
        } catch let error as ScriptRunner.ScriptError {
            assert(error.message.contains("script failed") && error.message.contains("42"))
        }
        print("PASS: execution errors preserve the error message and number")

        let samples = (0..<10).map { _ -> Double in
            let at = Date()
            _ = try? runner.string("return \"ok\"")
            return Date().timeIntervalSince(at)
        }.sorted()
        print(String(format: "MEASURE: fresh osascript startup median %.1f ms", samples[samples.count / 2] * 1000))
    }
}
