// Tests/AppLogTests/PrivacyEnforcementTests.swift
//
// Guard B: compile-time privacy enforcement.
//
// The #if false block below must FAIL to compile when flipped to #if true.
// Scripts/check-privacy-enforcement.sh automates this verification.

import AppLog
import Testing

#if false
// Flip to #if true and run `swift build` to confirm the compiler rejects unannotated interpolation.
func shouldNotCompile() {
    let log = AppLog.make(category: "Test")
    let name = "alice"
    // The line below must NOT compile: missing required privacy: argument.
    log.info("session.created name=\(name)")
}
#endif

@Suite("AppLog")
struct AppLogTests {
    @Test("bootstrap is idempotent")
    func bootstrapIdempotent() {
        AppLog.bootstrap(subsystem: "io.goodkind.fan.test")
        AppLog.bootstrap(subsystem: "io.goodkind.fan.test")
    }

    @Test("make returns a usable channel")
    func makeChannel() {
        AppLog.bootstrap(subsystem: "io.goodkind.fan.test")
        let log = AppLog.make(category: "Test")
        log.info("test.event value=\("hello", privacy: .public)")
        log.debug("test.debug count=\(42, privacy: .public)")
        log.notice("test.notice")
        log.error("test.error")
    }

    @Test("privacy public renders plaintext")
    func privacyPublicRendersPlaintext() {
        let msg: AppLogMessage = "x=\("hello", privacy: .public)"
        #expect(msg.rendered == "x=hello")
    }

    @Test("privacy private renders redacted")
    func privacyPrivateRendersRedacted() {
        let msg: AppLogMessage = "x=\("secret", privacy: .private)"
        #expect(msg.rendered == "x=<private>")
    }

    @Test("privacy privateHash renders stable hash prefix")
    func privacyHashRendersHash() {
        let msg1: AppLogMessage = "x=\("alice", privacy: .private(mask: .hash))"
        let msg2: AppLogMessage = "x=\("alice", privacy: .private(mask: .hash))"
        #expect(msg1.rendered == msg2.rendered)
        #expect(msg1.rendered.hasPrefix("x=<private:"))
    }
}
