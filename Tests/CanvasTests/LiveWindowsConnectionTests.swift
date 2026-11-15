import XCTest
import Darwin
@testable import Canvas

/// A value a fake add-on's thread and the test share; the expectations order their accesses.
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

final class LiveWindowsConnectionTests: XCTestCase {
    private func withServer(_ response: @escaping @Sendable (Int32) -> Void, check: (String) throws -> Void) throws {
        let path = "/tmp/sunbeam-test-\(UUID().uuidString).sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        defer { Darwin.close(listener); unlink(path) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let encoded = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: encoded) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(listener, 1), 0)
        let done = expectation(description: "server closed")
        DispatchQueue.global().async {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { done.fulfill(); return }
            var yes: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            var request = [UInt8](repeating: 0, count: 3)
            let count = recv(client, &request, 3, MSG_WAITALL)
            XCTAssertEqual(count, 3)
            XCTAssertEqual(request, [1, 0, 0x70])
            response(client)
            Darwin.close(client)
            done.fulfill()
        }
        try check(path)
        wait(for: [done], timeout: 2)
    }

    func testFragmentedCapabilityResponse() throws {
        try withServer({ fd in
            for var byte in LiveWindowsWire.magic {
                XCTAssertEqual(Darwin.send(fd, &byte, 1, 0), 1)
                usleep(2_000)
            }
        }, check: { XCTAssertTrue(LiveWindowsConnection.probe(path: $0)) })
    }

    func testStockAdditionClosesUnknownOpcode() throws {
        try withServer({ _ in }, check: { XCTAssertFalse(LiveWindowsConnection.probe(path: $0)) })
    }

    func testWrongProtocolDoesNotEnableRealWindows() throws {
        try withServer({ fd in
            let bytes = Array("SUNBEAM2\n".utf8)
            _ = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        }, check: { XCTAssertFalse(LiveWindowsConnection.probe(path: $0)) })
    }

    func testStockCommandWaitsForTheAdditionToClose() throws {
        let path = "/tmp/sunbeam-test-\(UUID().uuidString).sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { Darwin.close(listener); unlink(path) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let encoded = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: encoded) }
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(listen(listener, 1), 0)
        let message = LiveWindowsWire.order(7, relativeTo: 3, order: 1)
        let received = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: message.count)
        defer { received.deallocate() }
        let closed = expectation(description: "addition closed")
        DispatchQueue.global().async {
            let client = accept(listener, nil, nil)
            XCTAssertEqual(recv(client, received.baseAddress, message.count, MSG_WAITALL), message.count)
            usleep(50_000)   // the order is being carried out; the client must still be waiting
            Darwin.close(client)
            closed.fulfill()
        }
        let start = Date()
        XCTAssertTrue(LiveWindowsConnection.command(message, path: path))
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 0.045)
        wait(for: [closed], timeout: 2)
        XCTAssertEqual(Data(received), message)
    }

    func testStockCommandWithoutAnAdditionFails() {
        XCTAssertFalse(LiveWindowsConnection.command(LiveWindowsWire.message(1), path: "/tmp/sunbeam-test-missing.sock"))
    }

    /// A slow acknowledgement is waited for past one socket timeout when the connection is given the
    /// patience to: a leased session doesn't give the windows up over a window server's slow moment.
    func testPatientConnectionOutlastsOneSocketTimeout() throws {
        try withServer({ fd in
            usleep(600_000)
            _ = LiveWindowsWire.magic.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        }, check: { path in
            let start = Date()
            let socket = try LiveWindowsConnection(path: path, patience: 1.5)
            defer { socket.close() }
            try socket.send(LiveWindowsWire.message(LiveWindowsWire.capability))
            XCTAssertEqual(try socket.receive(LiveWindowsWire.magic.count), LiveWindowsWire.magic)
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertGreaterThan(elapsed, 0.55)
            XCTAssertLessThan(elapsed, 1.4)
        })
    }

    /// A session the Dock drops (it ends one itself after three idle seconds) is leased again for the
    /// frame in hand, and only a lease that can't be had at all is a failure.
    func testDriverTakesANewLeaseWhenTheSessionDrops() throws {
        let path = "/tmp/sunbeam-test-\(UUID().uuidString).sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { Darwin.close(listener); unlink(path) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let encoded = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: encoded) }
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(listen(listener, 2), 0)
        let frame = try LiveWindowsWire.snapshot([], backdrop: 0, overlay: 0)
        let first = expectation(description: "the first lease acknowledged a frame")
        let acknowledged = expectation(description: "the second lease acknowledged the frame")
        let leases = Box(0)
        DispatchQueue.global().async {
            while leases.value < 2 {
                let lease = leases.value
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                var yes: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
                var request = [UInt8](repeating: 0, count: 3)
                XCTAssertEqual(recv(client, &request, 3, MSG_WAITALL), 3)
                if request == [1, 0, 1] {
                    // The version the driver asks for before each lease, as the stock listener answers it.
                    let version = Array("sunlight-3\n".utf8)
                    _ = version.withUnsafeBytes { Darwin.send(client, $0.baseAddress, $0.count, 0) }
                    Darwin.close(client)
                    continue
                }
                leases.value += 1
                XCTAssertEqual(request, [1, 0, LiveWindowsWire.session])
                _ = LiveWindowsWire.magic.withUnsafeBytes { Darwin.send(client, $0.baseAddress, $0.count, 0) }
                var received = [UInt8](repeating: 0, count: frame.count)
                XCTAssertEqual(recv(client, &received, frame.count, MSG_WAITALL), frame.count)
                XCTAssertEqual(Data(received), frame)
                var ok: UInt8 = 0
                XCTAssertEqual(Darwin.send(client, &ok, 1, 0), 1)
                (lease == 0 ? first : acknowledged).fulfill()
                if lease == 1 {
                    // The restore puts every window back with an empty frame on the same lease.
                    XCTAssertEqual(recv(client, &received, frame.count, MSG_WAITALL), frame.count)
                    XCTAssertEqual(Darwin.send(client, &ok, 1, 0), 1)
                }
                // The first lease is dropped, as the Dock drops an idle session.
                Darwin.close(client)
            }
        }
        let failed = expectation(description: "the driver reported a failure")
        failed.isInverted = true
        let driver = RealWindowDriver(socketPath: path)
        driver.onFailure = { _ in failed.fulfill() }
        driver.submit(frame)
        wait(for: [first], timeout: 3)
        // The next frame finds the session gone and is carried by a new lease.
        driver.submit(frame)
        wait(for: [acknowledged], timeout: 3)
        wait(for: [failed], timeout: 0.3)
        XCTAssertTrue(driver.restore())
    }

    /// A fake add-on that takes `wanted` leases one after the other and answers every frame on them.
    /// `seen` gets the frames of each lease. `beforeAnswer` is called on the add-on's thread with the
    /// lease's number and its frames so far, before the last of them is answered, and says whether the
    /// lease is dropped once it has been (as the Dock drops a session). `finished` is fulfilled when the
    /// last lease has ended.
    private func fakeAddOn(leases wanted: Int, seen: Box<[[Data]]>, finished: XCTestExpectation,
                           beforeAnswer: @escaping @Sendable (_ lease: Int, _ frames: [Data]) -> Bool) -> (path: String, listener: Int32) {
        let path = "/tmp/sunbeam-test-\(UUID().uuidString).sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let encoded = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: encoded) }
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(listen(listener, 4), 0)
        DispatchQueue.global().async {
            var lease = 0
            while lease < wanted {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { break }
                var yes: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
                // One request: its two-byte length, then that many bytes.
                let message: () -> Data? = {
                    var header = [UInt8](repeating: 0, count: 2)
                    guard recv(client, &header, 2, MSG_WAITALL) == 2 else { return nil }
                    var body = [UInt8](repeating: 0, count: Int(header[0]) | Int(header[1]) << 8)
                    guard recv(client, &body, body.count, MSG_WAITALL) == body.count else { return nil }
                    return Data(header + body)
                }
                guard let hello = message() else { Darwin.close(client); continue }
                if hello == Data([1, 0, 1]) {
                    // The version the driver asks for before each lease, as the stock listener answers it.
                    let version = Array("sunlight-57\n".utf8)
                    _ = version.withUnsafeBytes { Darwin.send(client, $0.baseAddress, $0.count, 0) }
                    Darwin.close(client)
                    continue
                }
                XCTAssertEqual(hello, Data([1, 0, LiveWindowsWire.session]))
                _ = LiveWindowsWire.magic.withUnsafeBytes { Darwin.send(client, $0.baseAddress, $0.count, 0) }
                seen.value.append([])
                while let frame = message() {
                    seen.value[lease].append(frame)
                    let drop = beforeAnswer(lease, seen.value[lease])
                    var ok: UInt8 = 0
                    _ = Darwin.send(client, &ok, 1, 0)
                    if drop { break }
                }
                Darwin.close(client)
                lease += 1
            }
            finished.fulfill()
        }
        return (path, listener)
    }

    /// A frame of `ids`, each a 400 × 300 window at `x`, for a canvas whose windows are 7 and 5.
    private func frame(_ ids: [CGWindowID], _ kind: LiveWindowsWire.FrameKind, x: CGFloat) throws -> Data {
        let windows = ids.map { LiveWindowsWire.Window(id: $0, worldRect: CGRect(x: x, y: 50, width: 400, height: 300), inset: 0, camera: Camera()) }
        return try LiveWindowsWire.snapshot(windows, backdrop: 5, overlay: 7, kind: kind)
    }

    /// A window is parked or woken without a full frame, so the last full frame sent no longer says
    /// which windows are where. A lease taken after the Dock dropped one starts from the base handed
    /// over with the partial frame instead, and the partial frame follows it.
    func testAFreshLeaseStartsFromTheBaseHandedOverSince() throws {
        let full = try frame([11, 12], .full, x: 100)
        let base = try frame([11, 12], .full, x: 200)
        let partial = try frame([11], .partial, x: 300)
        XCTAssertNotEqual(full, base)
        let seen = Box<[[Data]]>([])
        let first = expectation(description: "the first lease had the full frame")
        let replayed = expectation(description: "the second lease had two frames")
        let finished = expectation(description: "both leases ended")
        let addOn = fakeAddOn(leases: 2, seen: seen, finished: finished) { lease, frames in
            if lease == 0 { first.fulfill(); return true }
            if frames.count == 2 { replayed.fulfill() }
            return false
        }
        defer { Darwin.close(addOn.listener); unlink(addOn.path) }
        let failed = expectation(description: "the driver reported a failure")
        failed.isInverted = true
        let driver = RealWindowDriver(socketPath: addOn.path)
        driver.onFailure = { _ in failed.fulfill() }
        driver.submit(full)
        wait(for: [first], timeout: 3)
        driver.submit(partial, full: false, base: base)
        wait(for: [replayed], timeout: 3)
        wait(for: [failed], timeout: 0.3)
        XCTAssertTrue(driver.restore())
        wait(for: [finished], timeout: 3)
        XCTAssertEqual(seen.value.count, 2)
        XCTAssertEqual(seen.value.first, [full])
        XCTAssertEqual(Array(seen.value.last?.prefix(2) ?? []), [base, partial], "the set as it stands, then the frame in hand")
    }

    /// A full frame still waiting when a partial one takes its place in the mailbox is never sent. It is
    /// the newest account of the whole set all the same, and what a fresh lease starts from.
    func testAFullFrameNeverSentIsWhatAFreshLeaseStartsFrom() throws {
        let sent = try frame([11, 12], .full, x: 100)
        let unsent = try frame([11, 12, 13], .full, x: 200)
        let partial = try frame([11], .partial, x: 300)
        let seen = Box<[[Data]]>([])
        let received = expectation(description: "the first frame reached the add-on")
        let replayed = expectation(description: "the second lease had two frames")
        let finished = expectation(description: "both leases ended")
        let answer = DispatchSemaphore(value: 0)
        let addOn = fakeAddOn(leases: 2, seen: seen, finished: finished) { lease, frames in
            if lease == 0 {
                // Held unanswered while the next two frames are submitted, then answered and dropped.
                received.fulfill()
                _ = answer.wait(timeout: .now() + 2)
                return true
            }
            if frames.count == 2 { replayed.fulfill() }
            return false
        }
        defer { Darwin.close(addOn.listener); unlink(addOn.path) }
        let driver = RealWindowDriver(socketPath: addOn.path)
        driver.submit(sent)
        wait(for: [received], timeout: 3)
        driver.submit(unsent)
        driver.submit(partial, full: false)
        answer.signal()
        wait(for: [replayed], timeout: 3)
        XCTAssertTrue(driver.restore())
        wait(for: [finished], timeout: 3)
        XCTAssertEqual(seen.value.first, [sent])
        XCTAssertEqual(Array(seen.value.last?.prefix(2) ?? []), [unsent, partial])
    }

    func testStalledAdditionTimesOut() throws {
        try withServer({ _ in usleep(600_000) }, check: { path in
            let start = Date()
            XCTAssertFalse(LiveWindowsConnection.probe(path: path))
            XCTAssertLessThan(Date().timeIntervalSince(start), 0.55)
        })
    }

    /// A fake add-on answering the stock version request, then one lease, every request on it with
    /// status 0 — a shadow request with `shadowStatus`. `exercise` drives a driver at it, and may wait for the lease's first
    /// request with `awaitFramed`; the requests the lease saw are returned once it has ended (the driver
    /// closing it, or `restore`). `version` nil: nothing answers the version request (a stock yabai
    /// would close).
    private func leaseSeen(by version: String?, shadowStatus: UInt8 = 0,
                           exercise: (RealWindowDriver, _ awaitFramed: () -> Void) throws -> Void) throws -> [Data] {
        let path = "/tmp/sunbeam-test-\(UUID().uuidString).sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { Darwin.close(listener); unlink(path) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let encoded = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: encoded) }
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(listen(listener, 4), 0)
        let done = expectation(description: "the lease ended")
        let framed = expectation(description: "the lease took its first frame")
        framed.assertForOverFulfill = false
        let requests = Box<[Data]>([])
        let leased = Box(false)
        DispatchQueue.global().async {
            while !leased.value {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                var yes: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
                var header = [UInt8](repeating: 0, count: 2)
                XCTAssertEqual(recv(client, &header, 2, MSG_WAITALL), 2)
                var body = [UInt8](repeating: 0, count: Int(header[0]) | Int(header[1]) << 8)
                XCTAssertEqual(recv(client, &body, body.count, MSG_WAITALL), body.count)
                if body == [1] {
                    if let version {
                        let reply = Array((version + "\n").utf8)
                        _ = reply.withUnsafeBytes { Darwin.send(client, $0.baseAddress, $0.count, 0) }
                    }
                    Darwin.close(client)
                    continue
                }
                if body == [LiveWindowsWire.session] {
                    leased.value = true
                    _ = LiveWindowsWire.magic.withUnsafeBytes { Darwin.send(client, $0.baseAddress, $0.count, 0) }
                    while true {
                        var h = [UInt8](repeating: 0, count: 2)
                        guard recv(client, &h, 2, MSG_WAITALL) == 2 else { break }
                        var b = [UInt8](repeating: 0, count: Int(h[0]) | Int(h[1]) << 8)
                        guard recv(client, &b, b.count, MSG_WAITALL) == b.count else { break }
                        requests.value.append(Data(h + b))
                        var status: UInt8 = b[0] == LiveWindowsWire.shadow ? shadowStatus : 0
                        _ = Darwin.send(client, &status, 1, 0)
                        // The first frame (or handoff), not a shadow: a test that eases shadows first then
                        // submits a frame waits for that frame to be served before it restores, or the
                        // restore's new generation drops the frame unsent.
                        if b[0] != LiveWindowsWire.shadow { framed.fulfill() }
                    }
                    Darwin.close(client)
                    // A stock request the driver sent while the lease was still open (the old-style
                    // raise) is waiting on the listener: served now, as the stock thread would.
                    var waiting = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                    while poll(&waiting, 1, 300) > 0 {
                        let stock = accept(listener, nil, nil)
                        guard stock >= 0 else { break }
                        var h = [UInt8](repeating: 0, count: 2)
                        if recv(stock, &h, 2, MSG_WAITALL) == 2 {
                            var b = [UInt8](repeating: 0, count: Int(h[0]) | Int(h[1]) << 8)
                            if recv(stock, &b, b.count, MSG_WAITALL) == b.count { requests.value.append(Data(h + b)) }
                        }
                        Darwin.close(stock)
                    }
                    done.fulfill()
                }
            }
        }
        let driver = RealWindowDriver(socketPath: path)
        let framedWaited = Box(false)
        let awaitFramed = { [self] in
            guard !framedWaited.value else { return }
            framedWaited.value = true
            self.wait(for: [framed], timeout: 3)
        }
        try exercise(driver, awaitFramed)
        if leased.value {
            awaitFramed()
            wait(for: [done], timeout: 3)
        } else {
            // No lease was taken, so none ends and nothing was framed.
            framed.isInverted = true
            done.isInverted = true
            wait(for: [framed, done], timeout: 0.3)
        }
        return requests.value
    }

    /// A handoff at a fake add-on: the requests its lease saw, and what `restore` returned. `afterFrame`:
    /// a frame goes out first (with `frameShadow` after it), so the handoff finds a lease in hand;
    /// otherwise the driver has to take one for the handoff. `shadow` goes with the handoff.
    private func handoffSeen(by version: String?, overlay: CGWindowID, backdrop: CGWindowID,
                             afterFrame: Bool = true, frameShadow: Data? = nil, shadow: Data? = nil,
                             keeping: [(CGWindowID, CGPoint)] = []) throws -> (requests: [Data], restored: Bool, kept: Bool) {
        let frame = try LiveWindowsWire.snapshot([], backdrop: 0, overlay: 0)
        let restored = Box(false), kept = Box(false)
        let requests = try leaseSeen(by: version) { driver, awaitFramed in
            if afterFrame {
                driver.submit(frame, shadow: frameShadow)
                awaitFramed()   // a restore drops a frame still pending, and needs the lease
            }
            restored.value = driver.restore(handoff: (42, CGPoint(x: 10, y: 20)), overlay: overlay, backdrop: backdrop,
                                            shadow: shadow, keeping: keeping)
            kept.value = driver.lastRestoreKept
            if !restored.value { XCTAssertNotNil(driver.lastRestoreFailure) }
        }
        return (requests, restored.value, kept.value)
    }

    func testHandoffKeepsTheWindowsInViewWithAnAddOnThatCan() throws {
        let frame = try LiveWindowsWire.snapshot([], backdrop: 0, overlay: 0)
        let around: [(CGWindowID, CGPoint)] = [(43, CGPoint(x: 600, y: 30)), (44, CGPoint(x: 0, y: 400))]
        let seen = try handoffSeen(by: "sunlight-10", overlay: 7, backdrop: 5, keeping: around)
        XCTAssertTrue(seen.restored)
        XCTAssertTrue(seen.kept)
        XCTAssertEqual(seen.requests, [frame, LiveWindowsWire.handoff(42, at: CGPoint(x: 10, y: 20), overlay: 7, backdrop: 5, keeping: around)])
        // An older add-on gets the plain handoff and puts them back with the rest.
        let older = try handoffSeen(by: "sunlight-9", overlay: 7, backdrop: 5, keeping: around)
        XCTAssertTrue(older.restored)
        XCTAssertFalse(older.kept)
        XCTAssertEqual(older.requests, [frame, LiveWindowsWire.handoff(42, at: CGPoint(x: 10, y: 20), overlay: 7, backdrop: 5)])
    }

    func testHandoffCarriesTheCanvasToAnAddOnThatRaisesInTheDock() throws {
        let frame = try LiveWindowsWire.snapshot([], backdrop: 0, overlay: 0)
        let seen = try handoffSeen(by: "sunlight-3", overlay: 7, backdrop: 5)
        XCTAssertTrue(seen.restored)
        XCTAssertEqual(seen.requests, [frame, LiveWindowsWire.handoff(42, at: CGPoint(x: 10, y: 20), overlay: 7, backdrop: 5)])
    }

    func testHandoffWithoutALeaseTakesOne() throws {
        // No frame since the canvas came back: a sunlight-5 add-on takes the window from wherever it
        // is, so the driver leases just for the handoff.
        let seen = try handoffSeen(by: "sunlight-5", overlay: 7, backdrop: 5, afterFrame: false)
        XCTAssertTrue(seen.restored)
        XCTAssertEqual(seen.requests, [LiveWindowsWire.handoff(42, at: CGPoint(x: 10, y: 20), overlay: 7, backdrop: 5)])
    }

    func testHandoffWithoutALeaseToAnOlderAddOnFails() throws {
        // sunlight-4 hands off only windows its frames transformed: nothing to send, and the reason is kept.
        let seen = try handoffSeen(by: "sunlight-4", overlay: 7, backdrop: 5, afterFrame: false)
        XCTAssertFalse(seen.restored)
        XCTAssertEqual(seen.requests, [])
    }

    func testFlightShadowFollowsTheFrameAndTheLastGoesBeforeTheHandoff() throws {
        let frame = try LiveWindowsWire.snapshot([], backdrop: 0, overlay: 0)
        let halfway = LiveWindowsWire.shadow(42, inactiveWeight: 0.5, activeWeight: 1)
        let active = LiveWindowsWire.shadow(42, inactiveWeight: 1, activeWeight: 1)
        let seen = try handoffSeen(by: "sunlight-7", overlay: 7, backdrop: 5, frameShadow: halfway, shadow: active)
        XCTAssertTrue(seen.restored)
        XCTAssertEqual(seen.requests, [frame, halfway, active, LiveWindowsWire.handoff(42, at: CGPoint(x: 10, y: 20), overlay: 7, backdrop: 5)])
    }

    func testShadowsAreNotSentToAnAddOnWithoutThem() throws {
        let frame = try LiveWindowsWire.snapshot([], backdrop: 0, overlay: 0)
        let shadow = LiveWindowsWire.shadow(42, inactiveWeight: 1, activeWeight: 1)
        let seen = try handoffSeen(by: "sunlight-6", overlay: 7, backdrop: 5, frameShadow: shadow, shadow: shadow)
        XCTAssertTrue(seen.restored)
        XCTAssertEqual(seen.requests, [frame, LiveWindowsWire.handoff(42, at: CGPoint(x: 10, y: 20), overlay: 7, backdrop: 5)])
    }

    /// Before the canvas activates itself from an entered window, the shadow requests go one after the
    /// other on a lease taken for them, which the frames after use.
    func testEasingBackSendsEveryRequestAndKeepsTheLease() throws {
        let frame = try LiveWindowsWire.snapshot([], backdrop: 0, overlay: 0)
        let steps = [0.8, 0.6, 0.4, 0.2, 0].map { LiveWindowsWire.shadow(42, inactiveWeight: 0, activeWeight: Float($0)) }
        let requests = try leaseSeen(by: "sunlight-7") { driver, _ in
            let eased = expectation(description: "eased back")
            let start = Date()
            driver.ease(shadows: steps, interval: 0.01) { eased.fulfill() }
            wait(for: [eased], timeout: 3)
            XCTAssertGreaterThan(Date().timeIntervalSince(start), 0.035)
            XCTAssertTrue(driver.restore())   // the empty frame goes on the same lease
        }
        XCTAssertEqual(requests, steps + [frame])
    }

    /// A shadow request the add-on declines stops the rest on that lease, and nothing else: the frames
    /// go on, and the ease completes.
    func testADeclinedShadowStopsTheRestOnTheLeaseOnly() throws {
        let frame = try LiveWindowsWire.snapshot([], backdrop: 0, overlay: 0)
        let steps = [0.8, 0.4, 0].map { LiveWindowsWire.shadow(42, inactiveWeight: 0, activeWeight: Float($0)) }
        let requests = try leaseSeen(by: "sunlight-7", shadowStatus: 9) { driver, awaitFramed in
            let eased = expectation(description: "eased back")
            driver.ease(shadows: steps, interval: 0.01) { eased.fulfill() }
            wait(for: [eased], timeout: 3)
            driver.submit(frame, shadow: steps[0])
            awaitFramed()
            XCTAssertTrue(driver.restore())
        }
        XCTAssertEqual(requests, [steps[0], frame, frame])
    }

    func testHandoffToAnOlderAddOnRaisesWithASecondRequest() throws {
        let frame = try LiveWindowsWire.snapshot([], backdrop: 0, overlay: 0)
        for version in ["sunlight-2", nil] {
            let seen = try handoffSeen(by: version, overlay: 7, backdrop: 5)
            // The old 13-byte handoff on the lease, then the stock order on its own connection.
            XCTAssertTrue(seen.restored)
            XCTAssertEqual(seen.requests, [frame, LiveWindowsWire.handoff(42, at: CGPoint(x: 10, y: 20)),
                                           LiveWindowsWire.order(42, relativeTo: 7, order: 1)])
        }
    }
}
