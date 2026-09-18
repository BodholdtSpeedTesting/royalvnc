#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - Entry Point for Handshaking Phase
extension VNCConnection {
	func handshake() async throws {
		try await receiveProtocolVersion()
	}
}

// MARK: - Handshaking Phase Implementation
private extension VNCConnection {
	func receiveProtocolVersion() async throws {
		let protocolVersion: VNCProtocol.ProtocolVersion

		do {
			protocolVersion = try await VNCProtocol.ProtocolVersion.receive(connection: connection)

			logger.logDebug("Received Server Protocol Version: \(protocolVersion.protocolVersion)")

			state.serverProtocolVersion = protocolVersion
		} catch {
			throw VNCError.ConnectionError.closedDuringHandshake(handshakingPhase: "Receive Protocol Version",
																 underlyingError: error)
		}

		try await sendProtocolVersion(serverProtocolVersion: protocolVersion)
	}

	func sendProtocolVersion(serverProtocolVersion: VNCProtocol.ProtocolVersion) async throws {
		do {
			let clientProtocolVersion: VNCProtocol.ProtocolVersion
			let maxSupportedProtocolVersion = maxSupportedProtocolVersion

			// The max. protocol version we currently support is 3.8, so check if the server is within those limits, otherwise downgrade to 3.8
			if serverProtocolVersion.majorVersion <= maxSupportedProtocolVersion.majorVersion,
			   serverProtocolVersion.minorVersion <= maxSupportedProtocolVersion.minorVersion {
				// Server reported a protocol version equal or lower to 3.8, use it
				clientProtocolVersion = serverProtocolVersion
			} else {
				// Server reported a protocol version higher than 3.8, so make sure we use 3.8 and not any higher protocol version that the server offered
				clientProtocolVersion = .init(majorVersion: maxSupportedProtocolVersion.majorVersion,
											  minorVersion: maxSupportedProtocolVersion.minorVersion)
			}

			try await VNCProtocol.ProtocolVersion.send(connection: connection,
													   protocolVersion: clientProtocolVersion)

			logger.logDebug("Sent Client Protocol Version: \(clientProtocolVersion.protocolVersion)")

			state.agreedProtocolVersion = clientProtocolVersion
		} catch {
			throw VNCError.ConnectionError.closedDuringHandshake(handshakingPhase: "Send Protocol Version",
																 underlyingError: error)
		}

		// RFC 6143 7.1.2 splits here. From 3.7 the server offers a list and the
		// client picks one; in 3.3 the server has already decided and sends a
		// single 32-bit word. Reading a 3.3 handshake with the 3.7 path consumes
		// the high byte of that word — always zero — and reports that the server
		// offered no security types at all, which is how a 3.3 server looked
		// before this.
		if state.agreedProtocolVersion?.is3Point3 == true {
			try await receiveServerChosenSecurityType()
		} else {
			try await receiveNumberOfSecurityTypes()
		}
	}

	/// The RFB 3.3 security handshake, in which the client does not get a say.
	func receiveServerChosenSecurityType() async throws {
		let chosen: VNCProtocol.ServerChosenSecurityType

		do {
			chosen = try await VNCProtocol.ServerChosenSecurityType.receive(connection: connection)
		} catch {
			throw VNCError.ConnectionError.closedDuringHandshake(handshakingPhase: "Receive Server Chosen Security Type",
																 underlyingError: error)
		}

		logger.logDebug("Received Server Chosen Security Type: \(chosen.value)")

		// One element, because on 3.3 the server states a single type and the
		// client has no say. An embedder explaining a refusal needs the same
		// answer here as on 3.7 and 3.8 -- arguably more, since the user could
		// not have influenced it.
		offeredSecurityTypes = [chosen.value]

		// Zero means the server refused outright and is about to say why. On 3.3
		// that reason is the only thing it will ever tell the user.
		guard chosen.value != 0 else {
			let reason = try? await VNCProtocol.ServerChosenSecurityType.receiveFailureReason(connection: connection)

			throw VNCError.authentication(.serverOfferedNoAuthTypes(reason: reason))
		}

		guard let securityType = chosen.securityType,
			  securityType != .invalid else {
			throw VNCError.authentication(.clientCouldNotDecideOnSecurityType)
		}

		// `announceChoice: false`: the client never sends a security type in 3.3,
		// and sending one would put a stray byte in front of the authentication
		// exchange — which the server would read as the first byte of a challenge
		// response.
		try await sendAuthenticationData(securityType: securityType, announceChoice: false)
	}

	func receiveNumberOfSecurityTypes() async throws {
		let number: UInt8

		do {
			let numberOfSecurityTypes = try await VNCProtocol.NumberOfSecurityTypes.receive(connection: connection)
			number = numberOfSecurityTypes.number

			logger.logDebug("Reveived Number of Security Types: \(number)")
		} catch {
			throw VNCError.ConnectionError.closedDuringHandshake(handshakingPhase: "Receive Number of Security Types",
																 underlyingError: error)
		}

		guard number > 0 else {
			let reason = try? await VNCProtocol.NumberOfSecurityTypes.receiveFailureReason(connection: connection)

			throw VNCError.authentication(.serverOfferedNoAuthTypes(reason: reason))
		}

		try await receiveSecurityTypes(number: number)
	}

	func receiveSecurityTypes(number: UInt8) async throws {
		let securityTypes: VNCProtocol.SecurityTypes

		do {
			securityTypes = try await VNCProtocol.SecurityTypes.receive(connection: connection,
																		number: number)

			logger.logDebug("Received Security Types: \(securityTypes.securityTypes.map({ "\($0)" }))")

			// Recorded before anything is chosen, because the interesting case is
			// the one where nothing can be.
			offeredSecurityTypes = securityTypes.authTypes.map(UInt32.init)
		} catch {
			throw VNCError.ConnectionError.closedDuringHandshake(handshakingPhase: "Receive Security Types",
																 underlyingError: error)
		}

		try await decideSecurityType(supportedTypes: securityTypes)
	}

	func decideSecurityType(supportedTypes: VNCProtocol.SecurityTypes) async throws {
		let chosenSecurityType: VNCProtocol.SecurityType

		let supportedSecurityTypes = supportedTypes.securityTypes

		// The embedder's choice comes first, from the types the server actually
		// offered and that this client can complete. Anything it returns that was
		// not on that list is ignored rather than attempted: the guard below
		// would reject it anyway, and failing there would blame the server.
		if let chooser = securityTypeChooser {
			let offered = supportedSecurityTypes.compactMap(\.publicSecurityMethod)

			if let preferred = chooser(offered),
			   offered.contains(preferred) {
				logger.logDebug("Embedder chose Security Type: \(preferred)")

				try await sendAuthenticationData(securityType: preferred.protocolSecurityType)

				return
			}
		}

		if supportedSecurityTypes.contains(.none) {
			chosenSecurityType = .none
		} else if supportedSecurityTypes.contains(.diffieHellman) {
			chosenSecurityType = .diffieHellman
		} else if supportedSecurityTypes.contains(.ultraVNCMSLogonII) {
			chosenSecurityType = .ultraVNCMSLogonII
		} else if supportedSecurityTypes.contains(.vnc) {
			chosenSecurityType = .vnc
		//
		// `.tight` is deliberately NOT selectable while its sub-negotiation is
		// unimplemented (see the commented-out `case .tight:` in
		// `sendAuthenticationData` below).
		//
		// Choosing it desynchronises the stream silently: the client sends the
		// security type, skips the tunnel and auth-capability exchange Tight
		// requires, reads the server's 4-byte tunnel count as a SecurityResult,
		// concludes that authentication succeeded, and sends ClientInit into a
		// server still waiting for a 4-byte auth code. Both sides then block
		// until the server gives up, and the client reports "the connection was
		// closed during Receive Server Init" — which blames the network for a
		// protocol fault. Observed against a Tight-only stand-in.
		//
		// Falling through to `.invalid` instead fails immediately and honestly,
		// with `clientCouldNotDecideOnSecurityType`. TightVNC and TigerVNC both
		// ship servers that offer Tight, so this is reachable in practice.
		} else {
			chosenSecurityType = .invalid
		}

		guard chosenSecurityType != .invalid,
			  supportedTypes.securityTypes.contains(chosenSecurityType) else {
			throw VNCError.authentication(.clientCouldNotDecideOnSecurityType)
		}

		try await sendAuthenticationData(securityType: chosenSecurityType)
	}

	func sendAuthenticationData(securityType: VNCProtocol.SecurityType,
								announceChoice: Bool = true) async throws {
		guard announceChoice else {
			logger.logDebug("Server Chose Security Type: \(securityType)")

			try await performAuthentication(securityType: securityType)

			return
		}

		do {
			try await VNCProtocol.SecurityTypes.send(connection: connection,
													 securityType: securityType.rawValue)
		} catch {
			throw VNCError.ConnectionError.closedDuringHandshake(handshakingPhase: "Send Authentication Data",
																 underlyingError: error)
		}

		logger.logDebug("Sent Security Type: \(securityType)")

		try await performAuthentication(securityType: securityType)
	}

	/// Everything after the security type is settled, which 3.3 and 3.7 share.
	func performAuthentication(securityType: VNCProtocol.SecurityType) async throws {
		// Recorded here rather than where the choice is made, because this is the
		// one point every path passes through: 3.7 and 3.8 come from
		// `decideSecurityType`, 3.3 from the server stating a type the client
		// never chose, and the embedder's hook from a fourth place again.
		negotiatedSecurityMethod = securityType.publicSecurityMethod


		let shouldRequestSecurityTypeResult: Bool

		switch securityType {
			case .none:
				if let protocolVersion = state.agreedProtocolVersion {
					// Only servers 3.8+ send a security result when no authentication is configured
					shouldRequestSecurityTypeResult = protocolVersion.is3Point8OrHigher
				} else {
					shouldRequestSecurityTypeResult = true
				}
			case .vnc:
				shouldRequestSecurityTypeResult = true

				try await performVNCAuthentication()
			case .diffieHellman:
				shouldRequestSecurityTypeResult = true

				try await performARDAuthentication()
			case .ultraVNCMSLogonII:
				shouldRequestSecurityTypeResult = true

				try await performUltraVNCMSLogonIIAuthentication()
//			case .tight:
//				shouldRequestSecurityTypeResult = true
//				isTightSecurityEnabled = true
//
//				// TODO: Implement
			default:
				shouldRequestSecurityTypeResult = true
		}

		if shouldRequestSecurityTypeResult {
			try await receiveSecurityTypeResult()
		}

		try await sendClientInit()
	}

	func performVNCAuthentication() async throws {
		let auth = try await VNCProtocol.VNCAuthentication.receive(connection: connection)

		let credential = try await askDelegateForPasswordCredential(authenticationType: auth.authenticationType)

		try await auth.send(connection: connection,
							credential: credential)
	}

	func performARDAuthentication() async throws {
		let auth = try await VNCProtocol.ARDAuthentication.receive(connection: connection)

		let credential = try await askDelegateForUsernamePasswordCredential(authenticationType: auth.authenticationType)

		try await auth.send(connection: connection,
							credential: credential)
	}

	func performUltraVNCMSLogonIIAuthentication() async throws {
		let auth = try await VNCProtocol.UltraVNCMSLogonIIAuthentication.receive(connection: connection)

		let credential = try await askDelegateForUsernamePasswordCredential(authenticationType: auth.authenticationType)

		try await auth.send(connection: connection,
							credential: credential)
	}

	func receiveSecurityTypeResult() async throws {
		let result: VNCProtocol.SecurityResult

		do {
			result = try await VNCProtocol.SecurityResult.receive(connection: connection)
		} catch {
			throw VNCError.ConnectionError.closedDuringHandshake(handshakingPhase: "Receive Security Type Result",
																 underlyingError: error)
		}

		guard let actualResult = result.result else {
			throw VNCError.protocol(.invalidData)
		}

		logger.logDebug("Received Security Type Result: \(actualResult)")

		guard actualResult == .ok else {
			let reason: String?

			// Only servers 3.8+ send a reason
			if let protocolVersion = state.agreedProtocolVersion,
			   protocolVersion.is3Point8OrHigher {
				reason = try? await VNCProtocol.SecurityResult.receiveFailureReason(connection: connection)
			} else {
				reason = nil
			}

			throw VNCError.authentication(.securityHandshakingFailed(reason: reason))
		}
	}

	func sendClientInit() async throws {
		let isShared = settings.isShared

		do {
			try await VNCProtocol.ClientInit.send(connection: connection,
												  isShared: isShared)
		} catch {
			throw VNCError.ConnectionError.closedDuringHandshake(handshakingPhase: "Send Client Init",
																 underlyingError: error)
		}

		logger.logDebug("Sent Client Init")

		try await receiveServerInit()
	}

	func receiveServerInit() async throws {
		let serverInit: VNCProtocol.ServerInit

		do {
			serverInit = try await VNCProtocol.ServerInit.receive(connection: connection,
																  isTightSecurityEnabled: state.isTightSecurityEnabled)
		} catch {
			throw VNCError.ConnectionError.closedDuringHandshake(handshakingPhase: "Receive Server Init",
																 underlyingError: error)
		}

		logger.logDebug("Received Server Init \(serverInit)")

		state.framebufferWidth = serverInit.framebufferWidth
		state.framebufferHeight = serverInit.framebufferHeight
		state.desktopName = serverInit.name

		let serverPixelFormat = serverInit.pixelFormat

		// Force our own pixel format
		let clientPixelFormat = VNCProtocol.PixelFormat(depth: settings.colorDepth.rawValue)

		logger.logDebug("Forcing pixel format: \(clientPixelFormat)")

		// Use server pixel format
//		let clientPixelFormat = serverPixelFormat

		state.serverPixelFormat = serverPixelFormat
		state.pixelFormat = clientPixelFormat

		do {
			try await sendSetPixelFormat(clientPixelFormat)
		} catch {
			throw VNCError.ConnectionError.closedDuringHandshake(handshakingPhase: "Send Set Pixel Format",
																 underlyingError: error)
		}

		let supportedEncodingTypes = try orderedEncodingTypes()

		do {
			try await sendSetEncodings(supportedEncodingTypes)
		} catch {
			throw VNCError.ConnectionError.closedDuringHandshake(handshakingPhase: "Send Set Encodings",
																 underlyingError: error)
		}

		let framebufferSize = VNCSize(width: serverInit.framebufferWidth,
									  height: serverInit.framebufferHeight)

        let newFramebuffer = try VNCFramebuffer(logger: logger,
                                                size: framebufferSize,
                                                screens: [ ],
                                                pixelFormat: clientPixelFormat,
                                                allocator: framebufferAllocator)

		newFramebuffer.delegate = self

		self.framebuffer = newFramebuffer

		clientToServerMessageQueue.clear()

		notifyDelegateAboutFramebufferCreation(newFramebuffer)
	}

	func sendSetPixelFormat(_ pixelFormat: VNCProtocol.PixelFormat) async throws {
		let sendPixelFormatMessage = VNCProtocol.SetPixelFormat(pixelFormat: pixelFormat)

		try await sendPixelFormatMessage.send(connection: connection)
	}

	func sendSetEncodings(_ encodings: [VNCEncodingType]) async throws {
		let setEncodingsMessage = VNCProtocol.SetEncodings(encodingTypes: encodings)

		try await setEncodingsMessage.send(connection: connection)
	}
}
