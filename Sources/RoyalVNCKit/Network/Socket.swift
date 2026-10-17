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

final class Socket: Sendable {
    let addressInfo: AddressInfo

#if canImport(Glibc) || canImport(Darwin) || canImport(Android)
    private typealias NativeSocket = Int32
#elseif canImport(WinSDK)
    private typealias NativeSocket = SOCKET
#endif

    private let nativeSocket: NativeSocket

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
    /// where the read is refused. For the tests. Windows reads SO_KEEPALIVE back
    /// as a one-byte BOOL, so the value starts from zero.
    func intOption(level: Int32, name: Int32) -> Int32? {
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

    func connect() throws(Errors) {
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

        guard connectResult >= 0 else {
            throw .connectFailed(underlyingErrorCode: connectResult)
        }
    }

    /// What `recv(2)` returned and, when that was -1, the error it reported.
    ///
    /// The error is taken here, straight after the call and on the thread
    /// that made it. `errno` is per thread and the next call into the C
    /// library may overwrite it, so a caller cannot read it later. It used to
    /// be thrown away, and a connection reset on Linux reached the embedder as
    /// `VNCError.protocol(.noData)` -- "No Data was retrieved" -- which says
    /// neither that the network failed nor how.
    func receive(buffer: inout [UInt8]) -> (count: Int, errorCode: Int32) {
        let bufferSize = buffer.count
        var errorCode: Int32 = 0

        let bytesRead: Int = buffer.withUnsafeMutableBytes { bufferPtr in
            guard let bufferPtrAddr = bufferPtr.baseAddress else {
                return 0
            }

            let ret = recv(
                nativeSocket,
                bufferPtrAddr,
                .init(bufferSize),
                0
            )

            if ret < 0 {
                errorCode = Self.lastErrorCode()
            }

            return .init(ret)
        }

        return (bytesRead, errorCode)
    }

    /// What `send(2)` returned and, when that was -1, the error it reported.
    /// See `receive(buffer:)` for why the error is taken here.
    func send(buffer: [UInt8]) -> (count: Int, errorCode: Int32) {
        let bufferCount = buffer.count
        var errorCode: Int32 = 0

        let bytesSent: Int = buffer.withUnsafeBytes { bufferPtr in
            guard let bufferPtrAddr = bufferPtr.baseAddress else {
                return -1
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
                bufferPtrAddr,
                .init(bufferCount),
                Int32(MSG_NOSIGNAL)
            )
#elseif canImport(Android)
            let ret = Android.send(
                nativeSocket,
                bufferPtrAddr,
                .init(bufferCount),
                Int32(MSG_NOSIGNAL)
            )
#elseif canImport(Darwin)
            let ret = Darwin.send(
                nativeSocket,
                bufferPtrAddr,
                .init(bufferCount),
                0
            )
#elseif canImport(WinSDK)
            let ret = WinSDK.send(
                nativeSocket,
                bufferPtrAddr,
                .init(bufferCount),
                0
            )
#endif

            if ret < 0 {
                errorCode = Self.lastErrorCode()
            }

            return .init(ret)
        }

        return (bytesSent, errorCode)
    }

    /// The error the last failed socket call on this thread reported.
    private static func lastErrorCode() -> Int32 {
#if canImport(WinSDK)
        WSAGetLastError()
#else
        errno
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
#if canImport(Glibc) || canImport(Darwin) || canImport(Android)
        close(nativeSocket)
#elseif canImport(WinSDK)
        closesocket(nativeSocket)
#endif
    }
}

// MARK: - Errors
extension Socket {
    enum Errors: LocalizedError {
        case socketCreationFailed(underlyingErrorCode: Int32?)
        case connectFailed(underlyingErrorCode: Int32)

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
                    return "Connect failed (\(underlyingErrorCode))"
            }
        }
    }
}
