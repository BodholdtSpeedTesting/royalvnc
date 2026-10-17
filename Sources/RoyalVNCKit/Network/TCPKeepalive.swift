#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// TCP keepalive on every connection the kit dials (`NWConnection(settings:)` on
/// Apple platforms, `Socket` elsewhere): probes after 30 s with nothing from the
/// server, every 5 s, given up after 3 -- about 45 s from the server's last word to
/// the connection's failure.
///
/// A server may send nothing for as long as its screen is still. RFC 6143 §7.5.3
/// lets it hold an incremental FramebufferUpdateRequest until something changes
/// ("there may be an indefinite period between the FramebufferUpdateRequest and
/// the FramebufferUpdate"), and the kit asks again only once an update has come.
/// Its request acknowledged, a viewer of such a server has nothing in flight; when
/// the server's machine goes away without closing -- it loses power, or its
/// network -- no retransmission ever times out, and the connection stayed up with
/// the last frame shown as live, for good. Keepalive probes only a connection on
/// which nothing has come for the idle time (RFC 1122 §4.2.3.6: keep-alives "MUST
/// only be sent when no data or acknowledgement packets have been received for
/// the connection within an interval"), so a busy connection is as it was, and a
/// server that is there answers each probe. The numbers are the Bodholdt servers'
/// own for their viewers.
enum TCPKeepalive {
    /// Seconds with nothing from the server before the first probe.
    static let idleSeconds: Int32 = 30

    /// Seconds between probes.
    static let intervalSeconds: Int32 = 5

    /// Probes unanswered before the connection fails.
    static let probeCount: Int32 = 3
}
