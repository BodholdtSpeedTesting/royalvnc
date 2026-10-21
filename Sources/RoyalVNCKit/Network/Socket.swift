#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

#if canImport(Glibc)
import Glibc
#elseif canImport(WinSDK)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#endif

/// A TCP connection the kit dials, which any thread may end at any moment (`cancel()`).
///
/// ENDING IT. `SocketNetworkConnection.cancel()` -- the kit's disconnect, an embedder ending a
/// session or abandoning an attempt -- used to do nothing, and the socket was closed only in
/// `deinit`, which a read waiting in `recv` for a server that sends nothing holds off: the read
/// holds this object. So a connection stayed open for as long as its server stayed silent.
/// Measured from the embedder, on Linux against its own server: a viewer whose session was closed
/// on a still screen was counted by the server as watching until the viewer exited, and every
/// attempt a reconnect run abandoned at a server that had stopped answering kept its connection.
/// Now `cancel()` ends the connection at once: the socket is shut down, so the peer is sent the
/// end of the stream then, and a connect, a receive or a send under way on another thread returns,
/// failed as cancelled, as does every call after it.
///
/// NO CALL WAITS IN THE KERNEL. A call blocked in the kernel cannot be ended safely from another
/// thread on every platform. On Windows a shutdown wakes neither a `recv` already blocked on
/// another thread nor a `send` blocked on a peer that has stopped reading (measured from the
/// embedder on GitHub's Windows runner). A close would, but "the socket descriptor passed in the s
/// parameter may immediately be reused by the system as soon as closesocket function is issued",
/// and "A Winsock client must never issue closesocket on s concurrently with another Winsock
/// function call" (Microsoft's closesocket page). On Linux a close does not end the call: "the
/// blocking I/O system call holds a reference to the underlying open file description ... Thus,
/// the blocking system call in the first thread may successfully complete after the close() in the
/// second thread" (close(2), "Multithreaded processes and close()"); nor a wait: "closing the file
/// descriptor in another thread has no effect on select()" (select(2), to which poll(2) refers). So
/// the socket does not block, and a connect, a receive or a send that has to wait does so in `poll`
/// -- WSAPoll on Windows, and select for a connect there -- a slice at a time
/// (`waitSliceMilliseconds`), looking between slices at whether it has been cancelled.
///
/// CLOSED ONCE, AND NEVER WHILE IN USE. The descriptor is closed by whichever comes last of the
/// cancel and the calls using it when it came (`users`): by `cancel()` itself when none was, else
/// by the last of them to return. After that nothing uses it again -- no call, no second cancel,
/// not `deinit` -- as the number may by then be another socket's of the process, whose connection a
/// stale shutdown, read, write or close would end or talk on: in the embedder, a transport that
/// shut down a number its reader had already closed ended the listen of whichever socket had been
/// given the number since. A socket never cancelled is closed by `deinit`, when no call can be
/// using it: each holds this object.
final class Socket: @unchecked Sendable {
    let addressInfo: AddressInfo

#if canImport(Glibc) || canImport(Darwin) || canImport(Android)
    typealias NativeSocket = Int32
#elseif canImport(WinSDK)
    typealias NativeSocket = SOCKET
#endif

    /// The descriptor. Internal, not private, for the tests, which have its number given to a
    /// socket of their own once it is closed, and see that nothing of this one's reaches that
    /// socket.
    let nativeSocket: NativeSocket

    /// How long one wait lasts -- for a connect to finish, for bytes to arrive, for room to send --
    /// before the call looks again at whether the socket has been cancelled.
    static let waitSliceMilliseconds: Int32 = 100

    // What `cancel()` and the calls share, under `lock`. Spinlock where Foundation has no NSLock,
    // as elsewhere in the kit.
#if canImport(Glibc) || canImport(Android) || canImport(WinSDK)
    private let lock = Spinlock()
#else
    private let lock = NSLock()
#endif

    /// The calls using the descriptor now: a connect, a receive, a send, an option read.
    private var users = 0

    /// Whether `cancel()` has been called. No call takes the descriptor once it has.
    private var cancelled = false

    /// Whether the descriptor has been closed.
    private var closed = false

    init(addressInfo: AddressInfo) throws(Errors) {
        let nativeSocket = socket(
            addressInfo.family,
            addressInfo.socktype,
            addressInfo.protocol
        )

#if canImport(Glibc) || canImport(Darwin) || canImport(Android)
        guard nativeSocket >= 0 else {
            throw .socketCreationFailed(underlyingErrorCode: nil)
        }
#elseif canImport(WinSDK)
        guard nativeSocket != INVALID_SOCKET else {
            let lastError = WSAGetLastError()

            throw .socketCreationFailed(underlyingErrorCode: lastError)
        }
#endif

        // Non-blocking, so that no call waits in the kernel, where a cancel could not end it
        // (above). A socket that cannot be made so is closed, not used.
        guard Self.makeNonBlocking(nativeSocket) else {
            let errorCode = Self.lastErrorCode()

            Self.closeDescriptor(nativeSocket)

            throw .socketCreationFailed(underlyingErrorCode: errorCode)
        }

        self.addressInfo = addressInfo
        self.nativeSocket = nativeSocket

#if canImport(Darwin)
        // Writing to a peer that has hung up raises SIGPIPE, and the default
        // action ends the process -- the embedder's whole app, for a server
        // that went away. Not a failure a library gets to impose on its host;
        // the write should fail with EPIPE instead and be reported like any
        // other error. Darwin suppresses it per socket, here; Linux and Android
        // have no such option and suppress it per call, with MSG_NOSIGNAL in
        // `send` below. Windows has no SIGPIPE.
        //
        // (Apple platforms read and write through NWConnection, which handles
        // this itself, so on Darwin this socket is a fallback nothing takes
        // today. It is set anyway so the class is safe wherever it is used.)
        var on: Int32 = 1

        _ = setsockopt(nativeSocket, SOL_SOCKET, SO_NOSIGPIPE,
                       &on, socklen_t(MemoryLayout<Int32>.size))
#endif

        // Keepalive, on every platform, so that a server that goes away while
        // it has nothing to send -- a still screen -- is noticed
        // (TCPKeepalive). An option a platform refuses leaves its own setting
        // (two hours, by default): no connection fails for want of it.
        _ = Self.enableKeepalive(nativeSocket)
    }

    /// The options `TCPKeepalive` asks for, as this platform spells them:
    /// SO_KEEPALIVE on, then the idle time (TCP_KEEPIDLE; Darwin's
    /// TCP_KEEPALIVE), the interval and the count, in seconds. Windows takes the
    /// same three at IPPROTO_TCP from Windows 10 1709 (TCP_KEEPIDLE,
    /// TCP_KEEPINTVL and TCP_KEEPCNT; ws2ipdef.h numbers them 3, 17 and 16),
    /// literal here so as not to depend on the SDK's headers.
    static var keepaliveOptions: [(level: Int32, name: Int32, value: Int32)] {
        let idle = TCPKeepalive.idleSeconds
        let interval = TCPKeepalive.intervalSeconds
        let count = TCPKeepalive.probeCount

#if canImport(Glibc) || canImport(Android)
        let tcp = Int32(IPPROTO_TCP)

        return [(SOL_SOCKET, SO_KEEPALIVE, 1),
                (tcp, TCP_KEEPIDLE, idle),
                (tcp, TCP_KEEPINTVL, interval),
                (tcp, TCP_KEEPCNT, count)]
#elseif canImport(WinSDK)
        let tcp = Int32(IPPROTO_TCP.rawValue)

        return [(SOL_SOCKET, SO_KEEPALIVE, 1),
                (tcp, 3, idle),           // TCP_KEEPIDLE
                (tcp, 17, interval),      // TCP_KEEPINTVL
                (tcp, 16, count)]         // TCP_KEEPCNT
#elseif canImport(Darwin)
        let tcp: Int32 = IPPROTO_TCP

        return [(SOL_SOCKET, SO_KEEPALIVE, 1),
                (tcp, TCP_KEEPALIVE, idle),
                (tcp, TCP_KEEPINTVL, interval),
                (tcp, TCP_KEEPCNT, count)]
#endif
    }

    /// Sets `keepaliveOptions` on `socket`; false where any is refused.
    private static func enableKeepalive(_ socket: NativeSocket) -> Bool {
        var all = true

        for option in keepaliveOptions {
            var value = option.value

#if canImport(WinSDK)
            let result = withUnsafeBytes(of: &value) { raw in
                setsockopt(socket, option.level, option.name,
                           raw.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(raw.count))
            }
#else
            let result = setsockopt(socket, option.level, option.name,
                                    &value, socklen_t(MemoryLayout<Int32>.size))
#endif

            all = result == 0 && all
        }

        return all
    }

    /// An integer option of this socket, as `getsockopt` reads it back; nil
    /// where the read is refused, or once the socket has been cancelled. For the
    /// tests. Windows reads SO_KEEPALIVE back as a one-byte BOOL, so the value
    /// starts from zero.
    func intOption(level: Int32, name: Int32) -> Int32? {
        guard enter() else {
            return nil
        }

        defer { leave() }

        var value: Int32 = 0

#if canImport(WinSDK)
        var size = Int32(MemoryLayout<Int32>.size)

        let result = withUnsafeMutableBytes(of: &value) { raw in
            getsockopt(nativeSocket, level, name,
                       raw.baseAddress?.assumingMemoryBound(to: CChar.self), &size)
        }
#else
        var size = socklen_t(MemoryLayout<Int32>.size)

        let result = getsockopt(nativeSocket, level, name, &value, &size)
#endif

        return result == 0 ? value : nil
    }

    /// Connects, and returns once connected; throws if the connection cannot be
    /// made, or the socket is cancelled first.
    ///
    /// The socket does not block, so `connect` sets the connection going and
    /// returns -- EINPROGRESS; WSAEWOULDBLOCK on Windows -- and its outcome is
    /// waited for a slice at a time: "It is possible to select(2) or poll(2) for
    /// completion by selecting the socket for writing. After select(2) indicates
    /// writability, use getsockopt(2) to read the SO_ERROR option at level
    /// SOL_SOCKET to determine whether connect() completed successfully (SO_ERROR
    /// is zero) or unsuccessfully" (connect(2)). The system's own bound on a
    /// connect that nothing answers -- its SYN retries -- holds as it did when
    /// this blocked, and a cancel ends the connect sooner.
    func connect() throws(Errors) {
        guard enter() else {
            throw .cancelled
        }

        defer { leave() }

        let connectResult: Int32

#if canImport(Glibc)
        connectResult = Glibc.connect(
            nativeSocket,
            addressInfo.addr,
            addressInfo.addrlen
        )
#elseif canImport(Android)
        connectResult = Android.connect(
            nativeSocket,
            addressInfo.addr!, // TODO: Get rid of force unwrap
            addressInfo.addrlen
        )
#elseif canImport(Darwin)
        connectResult = Darwin.connect(
            nativeSocket,
            addressInfo.addr,
            addressInfo.addrlen
        )
#elseif canImport(WinSDK)
        connectResult = WinSDK.connect(
            nativeSocket,
            addressInfo.addr,
            .init(addressInfo.addrlen)
        )
#endif

        guard connectResult != 0 else {
            return
        }

        // The error, not the -1 `connect` returns, which this used to throw:
        // "Connect failed (-1)" said nothing of why.
        let errorCode = Self.lastErrorCode()

        guard Self.isConnecting(errorCode) else {
            throw .connectFailed(underlyingErrorCode: errorCode)
        }

        while !isCancelled {
            guard waitForConnection() else {
                continue
            }

            // A cancel's shutdown may end the wait too, with nothing to say of
            // the connect: it is the cancel.
            guard !isCancelled else {
                break
            }

            let outcome = pendingError()

            guard outcome == 0 else {
                throw .connectFailed(underlyingErrorCode: outcome)
            }

            return
        }

        throw .cancelled
    }

    /// What a `receive` or a `send` came to.
    enum Outcome: Equatable {
        /// That many bytes: received -- 0 for the peer's end of its stream --
        /// or sent, which is all of them.
        case transferred(Int)

        /// The call failed, with the error it reported.
        case failed(errorCode: Int32)

        /// `cancel()` came first, or ended the call.
        case cancelled
    }

    /// Up to `buffer.count` bytes, once there are some: waits for them, a slice
    /// at a time, until they come, the peer ends its stream, the call fails, or
    /// the socket is cancelled.
    ///
    /// The error is taken here, straight after the call and on the thread
    /// that made it. `errno` is per thread and the next call into the C
    /// library may overwrite it, so a caller cannot read it later. It used to
    /// be thrown away, and a connection reset on Linux reached the embedder as
    /// `VNCError.protocol(.noData)` -- "No Data was retrieved" -- which says
    /// neither that the network failed nor how.
    func receive(buffer: inout [UInt8]) -> Outcome {
        guard enter() else {
            return .cancelled
        }

        defer { leave() }

        let bufferSize = buffer.count

        return buffer.withUnsafeMutableBytes { bufferPtr -> Outcome in
            guard let bufferPtrAddr = bufferPtr.baseAddress else {
                return .transferred(0)
            }

            while !isCancelled {
                let ret = recv(
                    nativeSocket,
                    bufferPtrAddr,
                    .init(bufferSize),
                    0
                )

                if ret > 0 {
                    return .transferred(.init(ret))
                }

                // A cancel's shutdown ends the stream on this side too: what the
                // call says then is said as the cancel it is.
                if ret == 0 {
                    return isCancelled ? .cancelled : .transferred(0)
                }

                let errorCode = Self.lastErrorCode()

                if Self.isInterrupted(errorCode) {
                    continue
                }

                guard Self.wouldBlock(errorCode) else {
                    return isCancelled ? .cancelled : .failed(errorCode: errorCode)
                }

                // Nothing has arrived: wait for it, a slice at a time.
                waitUntil(readable: true)
            }

            return .cancelled
        }
    }

    /// All of `buffer`: waits for room, a slice at a time, while the peer reads
    /// more slowly than this sends, until all of it is sent, the call fails, or
    /// the socket is cancelled. See `receive(buffer:)` for why the error is
    /// taken here.
    func send(buffer: [UInt8]) -> Outcome {
        guard enter() else {
            return .cancelled
        }

        defer { leave() }

        let bufferCount = buffer.count

        return buffer.withUnsafeBytes { bufferPtr -> Outcome in
            guard bufferCount > 0,
                  let bufferPtrAddr = bufferPtr.baseAddress else {
                return .transferred(0)
            }

            var sent = 0

            while sent < bufferCount {
                guard !isCancelled else {
                    return .cancelled
                }

                // MSG_NOSIGNAL on Linux and Android: without it a send to a peer
                // that has already reset the connection raises SIGPIPE, whose
                // default action kills the process, before `send` can return the
                // EPIPE the caller would have reported. Measured from the
                // embedder: a suite whose servers die mid-handshake, run on its
                // own on Linux with nothing else in the process ignoring SIGPIPE,
                // died with "unexpected signal code 13" in every run. Darwin sets
                // SO_NOSIGPIPE on the socket in `init` instead, and has no
                // MSG_NOSIGNAL.
#if canImport(Glibc)
                let ret = Glibc.send(
                    nativeSocket,
                    bufferPtrAddr.advanced(by: sent),
                    .init(bufferCount - sent),
                    Int32(MSG_NOSIGNAL)
                )
#elseif canImport(Android)
                let ret = Android.send(
                    nativeSocket,
                    bufferPtrAddr.advanced(by: sent),
                    .init(bufferCount - sent),
                    Int32(MSG_NOSIGNAL)
                )
#elseif canImport(Darwin)
                let ret = Darwin.send(
                    nativeSocket,
                    bufferPtrAddr.advanced(by: sent),
                    .init(bufferCount - sent),
                    0
                )
#elseif canImport(WinSDK)
                let ret = WinSDK.send(
                    nativeSocket,
                    bufferPtrAddr.advanced(by: sent),
                    .init(bufferCount - sent),
                    0
                )
#endif

                if ret > 0 {
                    sent += .init(ret)

                    continue
                }

                // No room -- or nothing taken, which a stream socket should not
                // do -- so wait for some, a slice at a time.
                if ret == 0 {
                    waitUntil(readable: false)

                    continue
                }

                let errorCode = Self.lastErrorCode()

                if Self.isInterrupted(errorCode) {
                    continue
                }

                guard Self.wouldBlock(errorCode) else {
                    return isCancelled ? .cancelled : .failed(errorCode: errorCode)
                }

                waitUntil(readable: false)
            }

            return .transferred(sent)
        }
    }

    /// Ends the connection now, from any thread. Once: a second call does
    /// nothing.
    ///
    /// The socket is shut down at once -- the peer is sent the end of this
    /// side's stream, and nothing more is read -- and closed once no call uses
    /// it: here, or by the last call under way (`leave()`), which returns,
    /// cancelled, at the end of its slice at the latest. The shutdown is a use
    /// of the descriptor as a call's is, counted in `users` in the step that
    /// marks the socket cancelled, so nothing can close the descriptor under
    /// it: it is only ever of this socket's descriptor, never of a number
    /// closed and given out again. Every call after this fails as cancelled
    /// without using the descriptor.
    func cancel() {
        lock.lock()

        guard !cancelled else {
            lock.unlock()

            return
        }

        cancelled = true
        users += 1

        lock.unlock()

        Self.shutDown(nativeSocket)

        leave()
    }

    /// Whether `cancel()` has been called.
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }

        return cancelled
    }

    /// Takes the descriptor for a call; false, and not taken, once cancelled.
    private func enter() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !cancelled else {
            return false
        }

        users += 1

        return true
    }

    /// Gives the descriptor back after a call, or after the cancel's shutdown.
    /// The last out after a cancel closes it.
    private func leave() {
        lock.lock()

        users -= 1

        let closeNow = cancelled && users == 0 && !closed

        if closeNow {
            closed = true
        }

        lock.unlock()

        if closeNow {
            Self.closeDescriptor(nativeSocket)
        }
    }

#if DEBUG
    /// For the tests alone: called by a receive or a send of any socket that has
    /// found nothing to read, or no room, as it is about to wait, with the
    /// socket -- so that a test can hold that call there, the descriptor in use,
    /// while it cancels the socket and looks at the descriptor. Nil but in a
    /// test that sets it, and set only while that test runs.
    nonisolated(unsafe) static var beforeWaitingForTests: ((Socket) -> Void)?
#endif

    /// Waits up to a slice for the socket to be readable (`readable`) or to
    /// have room to send, or for what a wait reports unasked: an error, the
    /// peer's end of its stream, a cancel's shutdown. The call is made again
    /// after it, whatever ended the wait.
    private func waitUntil(readable: Bool) {
#if DEBUG
        Self.beforeWaitingForTests?(self)
#endif

#if canImport(WinSDK)
        let asked = SHORT(readable ? POLLRDNORM : POLLWRNORM)
        let failure = SHORT(POLLERR | POLLNVAL)
        var entry = WSAPOLLFD(fd: nativeSocket, events: asked, revents: 0)
        let ready = WSAPoll(&entry, 1, INT(Self.waitSliceMilliseconds))
#else
        let asked = Int16(readable ? POLLIN : POLLOUT)
        let failure = Int16(POLLERR | POLLNVAL)
        var entry = pollfd(fd: nativeSocket, events: asked, revents: 0)
        let ready = poll(&entry, 1, Self.waitSliceMilliseconds)
#endif

        // The wait itself failed, and not for a signal: the slice is waited out,
        // so that the call made again cannot spin.
        if ready < 0 {
            if !Self.isInterrupted(Self.lastErrorCode()) {
                Self.sleepOneSlice()
            }

            return
        }

        // Woken while waiting for room by something it did not ask for and that
        // no send meets -- the peer's end of its stream, which WSAPoll reports at
        // once on every call, room or not, though a peer that has ended its side
        // may still read -- so the slice is waited out rather than spun through.
        // (The end, or bytes to read, a receive takes.)
        if !readable, ready > 0, entry.revents & asked == 0, entry.revents & failure == 0, !isCancelled {
            Self.sleepOneSlice()
        }
    }

    /// Waits up to a slice for a connect under way to finish; true once it has,
    /// well or not -- `pendingError()` says which -- or something else ended the
    /// wait (a cancel's shutdown).
    private func waitForConnection() -> Bool {
#if canImport(WinSDK)
        // select, not WSAPoll, whose page says only that a TCP socket that
        // fails to connect is indicated "As of Windows 10 version 2004"; with
        // select, "success is reported in the writefds set and failure is
        // reported in the exceptfds set" (connect's page), and the failure's
        // reason is read with getsockopt SO_ERROR (select's page).
        var connected = fd_set()

        connected.fd_count = 1
        connected.fd_array.0 = nativeSocket

        var failed = connected
        var slice = timeval(tv_sec: 0, tv_usec: Self.waitSliceMilliseconds * 1000)

        let ready = select(0, nil, &connected, &failed, &slice)
#else
        var entry = pollfd(fd: nativeSocket, events: Int16(POLLOUT), revents: 0)

        let ready = poll(&entry, 1, Self.waitSliceMilliseconds)
#endif

        if ready < 0, !Self.isInterrupted(Self.lastErrorCode()) {
            Self.sleepOneSlice()
        }

        return ready > 0
    }

    /// The socket's pending error, read and so cleared (SO_ERROR): 0 once a
    /// connect has succeeded, else why it failed.
    private func pendingError() -> Int32 {
        var value: Int32 = 0

#if canImport(WinSDK)
        var size = Int32(MemoryLayout<Int32>.size)

        let result = withUnsafeMutableBytes(of: &value) { raw in
            getsockopt(nativeSocket, SOL_SOCKET, SO_ERROR,
                       raw.baseAddress?.assumingMemoryBound(to: CChar.self), &size)
        }
#else
        var size = socklen_t(MemoryLayout<Int32>.size)

        let result = getsockopt(nativeSocket, SOL_SOCKET, SO_ERROR, &value, &size)
#endif

        return result == 0 ? value : Self.lastErrorCode()
    }

    /// The error the last failed socket call on this thread reported.
    private static func lastErrorCode() -> Int32 {
#if canImport(WinSDK)
        WSAGetLastError()
#else
        errno
#endif
    }

    /// Whether a `connect` of a socket that does not block has set the
    /// connection going rather than failed: EINPROGRESS; or EINTR, after which
    /// "the connection request shall not be aborted, and the connection shall be
    /// established asynchronously" (POSIX, connect()); WSAEWOULDBLOCK on
    /// Windows (connect's page).
    private static func isConnecting(_ errorCode: Int32) -> Bool {
#if canImport(WinSDK)
        errorCode == WSAEWOULDBLOCK
#else
        errorCode == EINPROGRESS || errorCode == EINTR
#endif
    }

    /// Whether a call of a socket that does not block found nothing to read, or
    /// no room to send.
    private static func wouldBlock(_ errorCode: Int32) -> Bool {
#if canImport(WinSDK)
        errorCode == WSAEWOULDBLOCK
#else
        errorCode == EAGAIN || errorCode == EWOULDBLOCK
#endif
    }

    /// Whether a call was interrupted by a signal, to be made again.
    private static func isInterrupted(_ errorCode: Int32) -> Bool {
#if canImport(WinSDK)
        errorCode == WSAEINTR
#else
        errorCode == EINTR
#endif
    }

#if canImport(WinSDK)
    /// FIONBIO, which WinSDK's headers define by a macro Swift cannot import.
    private static let nonBlockingIO = Int32(bitPattern: 0x8004_667E)
#endif

    /// Makes `socket` not block: O_NONBLOCK (fcntl); FIONBIO (ioctlsocket) on
    /// Windows.
    private static func makeNonBlocking(_ socket: NativeSocket) -> Bool {
#if canImport(WinSDK)
        var nonBlocking: u_long = 1

        return ioctlsocket(socket, nonBlockingIO, &nonBlocking) == 0
#else
        let flags = fcntl(socket, F_GETFL)

        return flags >= 0 && fcntl(socket, F_SETFL, flags | O_NONBLOCK) == 0
#endif
    }

    /// Shuts both halves of `socket` down: the peer is sent the end of this
    /// side's stream, and nothing more is read. A half at a time on Linux and
    /// macOS: on macOS, once the peer has ended its own stream, a shutdown of
    /// both at once fails at the read half and leaves the write half open
    /// (measured in the embedder). "The shutdown function does not close the
    /// socket" (Microsoft's shutdown page), nor does shutdown(2).
    private static func shutDown(_ socket: NativeSocket) {
#if canImport(Glibc)
        _ = Glibc.shutdown(socket, Int32(SHUT_WR))
        _ = Glibc.shutdown(socket, Int32(SHUT_RD))
#elseif canImport(Android)
        _ = Android.shutdown(socket, Int32(SHUT_WR))
        _ = Android.shutdown(socket, Int32(SHUT_RD))
#elseif canImport(Darwin)
        _ = Darwin.shutdown(socket, SHUT_WR)
        _ = Darwin.shutdown(socket, SHUT_RD)
#elseif canImport(WinSDK)
        _ = WinSDK.shutdown(socket, SD_BOTH)
#endif
    }

    private static func closeDescriptor(_ socket: NativeSocket) {
#if canImport(Glibc)
        _ = Glibc.close(socket)
#elseif canImport(Android)
        _ = Android.close(socket)
#elseif canImport(Darwin)
        _ = Darwin.close(socket)
#elseif canImport(WinSDK)
        _ = closesocket(socket)
#endif
    }

    /// A slice's wait, with nothing to wait on.
    private static func sleepOneSlice() {
#if canImport(WinSDK)
        Sleep(DWORD(waitSliceMilliseconds))
#else
        _ = usleep(useconds_t(waitSliceMilliseconds) * 1000)
#endif
    }

    /// A socket error code as a person would want to read it, for example
    /// "Connection reset by peer (errno 104)".
    static func describe(errorCode: Int32) -> String {
#if canImport(WinSDK)
        // Windows Sockets codes are not errno values, and `strerror` does not
        // know them.
        "Windows Sockets error \(errorCode)"
#else
        "\(String(cString: strerror(errorCode))) (errno \(errorCode))"
#endif
    }

    deinit {
        // Unless a cancel, or the last call after it, has closed it already. No
        // call can be using it now: each holds this object.
        lock.lock()

        let closeNow = !closed

        closed = true

        lock.unlock()

        if closeNow {
            Self.closeDescriptor(nativeSocket)
        }
    }
}

// MARK: - Errors
extension Socket {
    enum Errors: LocalizedError {
        case socketCreationFailed(underlyingErrorCode: Int32?)
        case connectFailed(underlyingErrorCode: Int32)
        case cancelled

        var errorDescription: String? {
            switch self {
                case .socketCreationFailed(let underlyingErrorCode):
                    let underlyingErrorCodeStr: String

                    if let underlyingErrorCode {
                        underlyingErrorCodeStr = "\(underlyingErrorCode)"
                    } else {
                        underlyingErrorCodeStr = "N/A"
                    }

                    return "Socket creation failed (\(underlyingErrorCodeStr))"
                case .connectFailed(let underlyingErrorCode):
                    return "Connect failed: \(Socket.describe(errorCode: underlyingErrorCode))"
                case .cancelled:
                    return "Cancelled"
            }
        }
    }
}
