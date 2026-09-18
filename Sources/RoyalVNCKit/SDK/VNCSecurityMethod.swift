#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A security type, numbered as RFC 6143 §7.1.2 numbers it, limited to the ones
/// this client can actually complete.
///
/// Called a *method* rather than a *type* only because `VNCSecurityType` is
/// already taken, by the internal protocol the security-type implementations
/// conform to. Renaming that would touch every conformer for a cosmetic gain,
/// and every extra change here is another commit to replay when this fork is
/// rebased onto a newer upstream.
///
/// Distinct from ``VNCAuthenticationType``, which describes *a credential being
/// asked for* and therefore has no case for `none`: there is no credential to
/// ask for when the server wants no authentication. Both jobs this type exists
/// for need to be able to say "none" — an embedder choosing which type to accept
/// has to be able to refuse it, and one reporting which type was used has to be
/// able to report it. It is the most important one to be able to say.
public enum VNCSecurityMethod: UInt8, Sendable, CaseIterable {
	/// Type 1. No authentication at all. RFC 6143 §7.2.1.
	///
	/// Spelled `noAuthentication` rather than `none`, which is what the RFC calls
	/// it. A case named `none` on a type that will routinely be held in an
	/// `Optional` is shadowed by `Optional.none` in every `switch`: the obvious
	/// `case .none:` silently matches "no value" instead, and the real case falls
	/// through to whatever is left. The compiler catches it only when the switch
	/// happens to be exhaustive, which is not something to rely on in API other
	/// people will write switches over.
	case noAuthentication = 1

	/// Type 2. Challenge-response; the password never crosses the wire.
	/// RFC 6143 §7.2.2.
	case vnc = 2

	/// Type 30. Apple's Diffie-Hellman authentication.
	case appleRemoteDesktop = 30

	/// Type 113. UltraVNC's MS-Logon II, which authenticates against a Windows
	/// account and sends the user name and password encrypted under a key
	/// agreed by a 64-bit Diffie-Hellman exchange.
	case ultraVNCMSLogonII = 113
}

public extension VNCSecurityMethod {
	/// Whether completing this type needs a user name as well as a password.
	///
	/// The reason an embedder can decide better than the built-in order can: a
	/// server offering both type 2 and type 113 will accept either, but they
	/// authenticate against *different* credential stores, and only the embedder
	/// knows which credential it holds.
	var requiresUsername: Bool {
		switch self {
			case .noAuthentication: false
			case .vnc: false
			case .appleRemoteDesktop: true
			case .ultraVNCMSLogonII: true
		}
	}

	/// Whether the password reaches the wire, in any form, when this type is used.
	///
	/// `false` for ``vnc``, which is challenge-response: an observer sees a
	/// challenge and a response and has to break DES to recover anything.
	///
	/// `true` for ``ultraVNCMSLogonII``, which sends the user name and password
	/// encrypted under a key agreed by a Diffie-Hellman exchange whose modulus is
	/// eight bytes. A 64-bit discrete log is not a meaningful obstacle, so an
	/// observer recovers both in plaintext. That is a property of the security
	/// type as specified, not of this implementation, and no amount of care here
	/// changes it — which is precisely why an embedder should be told.
	var transmitsPassword: Bool {
		switch self {
			case .noAuthentication: false
			case .vnc: false
			case .appleRemoteDesktop: false
			case .ultraVNCMSLogonII: true
		}
	}
}
