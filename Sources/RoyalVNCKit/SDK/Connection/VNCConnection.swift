#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch

#if canImport(Network)
import Network
#endif

#if canImport(ObjectiveC)
@objc(VNCConnection)
#endif
public final class VNCConnection: NSObjectOrAnyObject {
	// MARK: - Public Properties
#if canImport(ObjectiveC)
	@objc
#endif
	public let settings: Settings

    public let context: UnsafeMutableRawPointer?

#if canImport(ObjectiveC)
	@objc
#endif
	public weak var delegate: VNCConnectionDelegate?

#if canImport(ObjectiveC)
	@objc
#endif
	public var framebuffer: VNCFramebuffer?

#if canImport(ObjectiveC)
	@objc
#endif
	public internal(set) var connectionState = ConnectionState.disconnected

#if canImport(ObjectiveC)
	@objc
#endif
	public let logger: VNCLogger
    
    public let framebufferAllocator: VNCFramebufferAllocator?

	/// Supplies the transport this connection runs RFB over.
	///
	/// When `nil` (the default) the connection dials `settings.hostname` and
	/// `settings.port` itself, exactly as it always has.
	///
	/// When set, the returned transport is used as-is. It may be either not yet
	/// started, in which case this connection starts it, or already established,
	/// in which case this connection adopts it rather than starting it again.
	///
	/// That second form is the point of this hook. It lets an embedder complete a
	/// preamble the RFB handshake knows nothing about — a repeater exchange, say —
	/// and only then hand the stream over.
	///
	/// Typed to ``VNCTransport`` rather than to a concrete connection class,
	/// because a reverse connection arrives from `accept(2)` as a file descriptor
	/// and Network.framework has no constructor that takes one. An `NWConnection`
	/// conforms, so the ordinary case is unchanged.
	///
	/// Must be set before `connect()`. Setting it afterwards traps, because by
	/// then the transport has already been created and the provider would be
	/// silently ignored.
	public var transportProvider: ((_ host: String, _ port: UInt16) -> any VNCTransport)? {
		didSet {
			precondition(!hasCreatedConnection,
						 "transportProvider must be set before connect()")
		}
	}

	// MARK: - Private Properties
	private var hasCreatedConnection = false

	private let queue = DispatchQueue(label: "com.royalapps.royalvnc.connectionqueue",
									  attributes: .concurrent)

	private let sharedZStream: ZlibStream
    private let sharedZRLEZStream: ZlibStream

	// MARK: - Internal Properties
    let taskPriority = TaskPriority.high

	var receiveTask: Task<(), Error>?
	var sendTask: Task<(), Error>?

	let maxSupportedProtocolVersion = VNCProtocol.ProtocolVersion(majorVersion: 3,
																  minorVersion: 8)

	let state = State()
	let systemSound = VNCSystemSound()

	let clipboard: VNCClipboard
	let clipboardMonitor: VNCClipboardMonitor

	var clientToServerMessageQueue = Queue<VNCSendableMessage>()

    var mouseButtonState: VNCProtocol.MousePointerButton = [ ]

    lazy var connection: some NetworkConnection = {
        hasCreatedConnection = true

        let connectionSettings = NetworkConnectionSettings(connectionTimeout: 15,
                                                           host: settings.hostname,
                                                           port: settings.port)

        // Always the same concrete type, whether the transport was supplied or
        // dialled here. That is what lets this stay an opaque type rather than
        // an existential, which would otherwise ripple through every file that
        // takes a connection as a generic constraint.
        let connection: TransportNetworkConnection

        if let provided = transportProvider?(settings.hostname, settings.port) {
            connection = TransportNetworkConnection(transport: provided)
        } else {
            connection = TransportNetworkConnection(settings: connectionSettings)
        }

        connection.setStatusUpdateHandler(connectionStatusDidChange)

		return connection
	}()

	lazy var encodings: Encodings = {
		let rawEncoding = VNCProtocol.RawEncoding()
		let hextileEncoding = VNCProtocol.HextileEncoding(rawEncoding: rawEncoding)

		let compressionLevelEncodingType = VNCPseudoEncodingType.compressionLevel6.rawValue
		let compressionLevelEncoding = VNCProtocol.CompressionLevelEncoding(encodingType: compressionLevelEncodingType)

		let jpegQualityLevelEncodingType = VNCPseudoEncodingType.jpegQualityLevel6.rawValue
		let jpegQualityLevelEncoding = VNCProtocol.JPEGQualityLevelEncoding(encodingType: jpegQualityLevelEncodingType)

		let encs: Encodings = [
			// Frame Encodings
			VNCFrameEncodingType.copyRect.rawValue: VNCProtocol.CopyRectEncoding(),
            VNCFrameEncodingType.tight.rawValue: VNCProtocol.TightEncoding(),
            VNCFrameEncodingType.zlib.rawValue: VNCProtocol.ZlibEncoding(zStream: sharedZStream),
			VNCFrameEncodingType.zrle.rawValue: VNCProtocol.ZRLEEncoding(zStream: sharedZRLEZStream),
			VNCFrameEncodingType.hextile.rawValue: hextileEncoding,
			VNCFrameEncodingType.coRRE.rawValue: VNCProtocol.RREEncoding(),
			VNCFrameEncodingType.rre.rawValue: VNCProtocol.RREEncoding(),
			VNCFrameEncodingType.raw.rawValue: rawEncoding,

			// Pseudo Encodings
			VNCPseudoEncodingType.lastRect.rawValue: VNCProtocol.LastRectEncoding(),
			VNCPseudoEncodingType.continuousUpdates.rawValue: VNCProtocol.ContinuousUpdatesEncoding(),
			VNCPseudoEncodingType.extendedDesktopSize.rawValue: VNCProtocol.ExtendedDesktopSizeEncoding(),
			VNCPseudoEncodingType.desktopSize.rawValue: VNCProtocol.DesktopSizeEncoding(),
			VNCPseudoEncodingType.desktopName.rawValue: VNCProtocol.DesktopNameEncoding(),
			VNCPseudoEncodingType.cursor.rawValue: VNCProtocol.CursorEncoding(),
			compressionLevelEncodingType: compressionLevelEncoding,
			jpegQualityLevelEncodingType: jpegQualityLevelEncoding
		]

		// Sanity Check
		do {
			let encodingTypes = encs.values.map({ $0.encodingType })

			try encodingTypes.validate()
		} catch {
            // If the sanity check fails here, it's a programming error
			fatalError(error.debugDescription)
		}

		return encs
	}()

	func orderedEncodingTypes() throws -> [VNCEncodingType] {
		// Frame Encodings (Required)
		var encs: [VNCEncodingType] = [
			VNCFrameEncodingType.copyRect.rawValue
		]

		// Frame Encodings (Customizable)
		var customizedFrameEncodings = settings.frameEncodings.map({ $0.rawValue })

		// TODO: Remove once we support ZRLE for non-24-bit pixel formats
		if let pixelFormat = state.pixelFormat,
		   customizedFrameEncodings.contains(VNCFrameEncodingType.zrle.rawValue),
		   !VNCProtocol.ZRLEEncoding.supportsPixelFormat(pixelFormat) {
			customizedFrameEncodings.removeAll(where: { $0 == VNCFrameEncodingType.zrle.rawValue })
		}

		if let pixelFormat = state.pixelFormat,
		   customizedFrameEncodings.contains(VNCFrameEncodingType.tight.rawValue),
		   !VNCProtocol.TightEncoding.supportsPixelFormat(pixelFormat) {
			customizedFrameEncodings.removeAll(where: { $0 == VNCFrameEncodingType.tight.rawValue })
		}

		let usesTightEncoding = customizedFrameEncodings.contains(VNCFrameEncodingType.tight.rawValue)

		encs.append(contentsOf: customizedFrameEncodings)

		// Frame Encodings (Required)
		encs.append(VNCFrameEncodingType.raw.rawValue)

		// Pseudo Encodings
		encs.append(contentsOf: [
			VNCPseudoEncodingType.lastRect.rawValue,
			VNCPseudoEncodingType.continuousUpdates.rawValue,
			VNCPseudoEncodingType.extendedDesktopSize.rawValue,
			VNCPseudoEncodingType.desktopSize.rawValue,
			VNCPseudoEncodingType.desktopName.rawValue,
			VNCPseudoEncodingType.cursor.rawValue,
			// TODO: Implement
//			VNCPseudoEncodingType.extendedClipboard.rawValue,
            
            // TODO: Make configurable
			VNCPseudoEncodingType.compressionLevel6.rawValue
		])

		if usesTightEncoding {
            // TODO: Make configurable
			encs.append(VNCPseudoEncodingType.jpegQualityLevel6.rawValue)
		}

		let uniqueEncs = encs.uniqued()

		// Sanity Check
        // If the sanity check fails here, it could be a programming error, but it could also be an error by the SDK user if he/she specified encodings with invalid values in settings. So we bubble the error up but don't crash.
		try uniqueEncs.validate()

		return uniqueEncs
	}

	// MARK: - Public Initializers
    public init(settings: Settings,
                logger: VNCLogger,
                framebufferAllocator: VNCFramebufferAllocator?,
                context: UnsafeMutableRawPointer?) {
        self.settings = settings

        logger.isDebugLoggingEnabled = settings.isDebugLoggingEnabled

        self.logger = logger
        self.context = context
        
        self.sharedZStream = .init()
        self.sharedZRLEZStream = .init()

        let clipboard = VNCClipboard()

        let clipboardMonitor = VNCClipboardMonitor(clipboard: clipboard,
                                                   monitoringInterval: 0.5,
                                                   tolerance: 0.15)

        self.clipboard = clipboard
        self.clipboardMonitor = clipboardMonitor
        self.framebufferAllocator = framebufferAllocator

        super.init()

        self.clipboardMonitor.delegate = self
    }

#if canImport(ObjectiveC)
	@objc
#endif
    public convenience init(settings: Settings,
                            logger: VNCLogger) {
        self.init(settings: settings,
                  logger: logger,
                  framebufferAllocator: nil,
                  context: nil)
	}

#if canImport(ObjectiveC)
	@objc
#endif
	public convenience init(settings: Settings) {
        self.init(settings: settings,
                  context: nil)
	}
    
    public convenience init(settings: Settings,
                            framebufferAllocator: VNCFramebufferAllocator?) {
        self.init(settings: settings,
                  framebufferAllocator: framebufferAllocator,
                  context: nil)
    }

    public convenience init(settings: Settings,
                            framebufferAllocator: VNCFramebufferAllocator?,
                            context: UnsafeMutableRawPointer?) {
#if canImport(OSLog)
        let logger = VNCOSLogLogger()
#else
        let logger = VNCPrintLogger()
#endif

        self.init(settings: settings,
                  logger: logger,
                  framebufferAllocator: framebufferAllocator,
                  context: context)
    }
    
    public convenience init(settings: Settings,
                            context: UnsafeMutableRawPointer?) {
        self.init(settings: settings,
                  framebufferAllocator: nil,
                  context: context)
    }

	deinit {
		let _self = self

		_self.clipboardMonitor.delegate = nil

		stopMonitoringClipboard()
	}
}

// MARK: - Internal Connection State API
extension VNCConnection {
	func beginConnecting() {
		updateConnectionState(.connecting)

		// A transport handed over by `transportProvider` may already be
		// established, because the embedder had to talk on it first.
		// Network.framework does not replay `.ready` to a status handler
		// installed after the fact, so such a transport is adopted here rather
		// than started a second time, which would be a programmer error.
		switch connection.status {
			case .ready:
				connectionStatusDidChange(.ready)

			case .preparing, .waiting:
				// Already in flight; the handler installed when the transport was
				// created will deliver the outcome.
				break

			case .failed, .cancelled:
				// Dead on arrival. Route it through the normal failure funnel.
				connectionStatusDidChange(connection.status)

			case .setup, .unknown:
				// NWConnection reports `.setup` before it is started;
				// SocketNetworkConnection reports `.unknown`. Both mean "not
				// started yet", which is the default, no-provider path.
				connection.start(queue: queue)
		}
	}

	func beginDisconnecting(error: Error? = nil) {
		guard !state.disconnectRequested else { return }

		state.disconnectRequested = true
		updateConnectionState(.disconnecting)

		connection.setStatusUpdateHandler(nil)
		connection.cancel()

		if let error = error {
			updateConnectionState(.disconnected(error: error))
		} else {
			updateConnectionState(.disconnected)
		}
	}

	func handleBreakingError(_ error: Error) {
		beginDisconnecting(error: error)
	}

	func updateConnectionState(_ newConnectionState: ConnectionState) {
		self.connectionState = newConnectionState

		switch newConnectionState.status {
			case .connecting:
				break

			case .connected:
				startMonitoringClipboard()

			case .disconnecting:
				stopMonitoringClipboard()

			case .disconnected:
				stopMonitoringClipboard()
		}

		notifyDelegateAboutConnectionStateChange(newConnectionState)
	}
}

// MARK: - Connection State Change Handling
private extension VNCConnection {
	func connectionStatusDidChange(_ newState: NetworkConnectionStatus) {
		switch newState {
			case .setup:
				logger.logDebug("Connection State - Setup")

			case .preparing:
				logger.logDebug("Connection State - Preparing")

			case .ready:
				logger.logDebug("Connection State - Ready")

				connectionDidBecomeReady()

			case .waiting(let error):
				logger.logDebug("Connection State - Waiting with error: \(error)")

				connectionDidFail(error: .connection(.failed(error)))

			case .failed(let error):
				logger.logDebug("Connection State - Failed with error: \(error)")

				connectionDidFail(error: .connection(.failed(error)))

			case .cancelled:
				logger.logDebug("Connection State - Cancelled")

				connectionDidFail(error: .connection(.cancelled))

            case .unknown(let underlyingState):
				logger.logDebug("Connection State - Unknown (\(underlyingState))")
		}
	}

	func connectionDidBecomeReady() {
		Task {
			do {
				try await handshake()
				try await sendFramebufferUpdateRequest()
			} catch {
				handleBreakingError(error)

                return
			}

			updateConnectionState(.connected)

			startReceiveLoop()
			startSendLoop()
		}
	}

	func connectionDidFail(error: VNCError) {
		handleBreakingError(error)
	}
}
