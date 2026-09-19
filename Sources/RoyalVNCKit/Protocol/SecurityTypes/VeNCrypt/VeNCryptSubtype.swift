#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension VNCProtocol {
	/// The authentication methods VeNCrypt can encapsulate.
	///
	/// rfbproto.rst, "VeNCrypt". Numbers at or above 256 are VeNCrypt's own; a
	/// server may also offer any ordinary RFB security type below 256, which is
	/// why this is not an exhaustive enum over the wire values.
	enum VeNCryptSubtype: UInt32 {
		case plain = 256
		case tlsNone = 257
		case tlsVnc = 258
		case tlsPlain = 259
		case x509None = 260
		case x509Vnc = 261
		case x509Plain = 262
		case tlsSASL = 263
		case x509SASL = 264
		case ident = 265
		case tlsIdent = 266
		case x509Ident = 267

		/// Whether the stream is wrapped in TLS before authentication continues.
		///
		/// Both prefixes mean TLS; they differ in what the server's certificate
		/// is expected to be. rfbproto.rst: the TLS prefix means "anonymous X509
		/// certificate", the X509 prefix means "valid X509 certificate".
		var usesTLS: Bool {
			switch self {
				case .plain, .ident:
					return false
				case .tlsNone, .tlsVnc, .tlsPlain, .tlsSASL, .tlsIdent,
					 .x509None, .x509Vnc, .x509Plain, .x509SASL, .x509Ident:
					return true
			}
		}

		/// Whether the server is expected to present an anonymous certificate.
		///
		/// THIS IS WHY THE TLS-PREFIXED SUBTYPES ARE NOT USABLE. An anonymous
		/// certificate means an anonymous key exchange -- the TLS_DH_anon family
		/// -- which offers no authentication of the server at all and is
		/// therefore trivially machine-in-the-middled. TLS 1.3 removed those
		/// ciphersuites outright, and OpenSSL and BoringSSL disable them by
		/// default in every version that still has them.
		///
		/// So this is not an omission that a later version fixes. A client
		/// cannot complete these subtypes with any modern TLS implementation,
		/// and would not want to.
		var expectsAnonymousCertificate: Bool {
			switch self {
				case .tlsNone, .tlsVnc, .tlsPlain, .tlsSASL, .tlsIdent:
					return true
				default:
					return false
			}
		}

		/// What happens once any TLS is in place.
		enum Inner {
			/// Nothing further; go straight to SecurityResult.
			case none

			/// Ordinary VNC authentication, inside the tunnel.
			case vnc

			/// A user name and password, length-prefixed.
			case plain

			/// A user name only. Not authentication; an identification step.
			case ident

			/// SASL, which this kit does not implement.
			case sasl
		}

		var inner: Inner {
			switch self {
				case .tlsNone, .x509None: return .none
				case .tlsVnc, .x509Vnc: return .vnc
				case .plain, .tlsPlain, .x509Plain: return .plain
				case .ident, .tlsIdent, .x509Ident: return .ident
				case .tlsSASL, .x509SASL: return .sasl
			}
		}
	}
}
