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

    func receive(buffer: inout [UInt8]) -> Int {
        let bufferSize = buffer.count

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

            return .init(ret)
        }

        return bytesRead
    }

    func send(buffer: [UInt8]) -> Int {
        let bufferCount = buffer.count

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

            return .init(ret)
        }

        return bytesSent
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
