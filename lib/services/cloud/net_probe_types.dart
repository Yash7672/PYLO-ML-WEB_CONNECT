/// Result of an out-of-band reachability probe. Shared by the native
/// (`net_probe_io.dart`) and web (`net_probe_web.dart`) probe implementations
/// selected at compile time via a conditional import.
enum HostReachability {
  /// The configured cloud host answered a real TLS connection.
  reachable,

  /// The device is online (a control endpoint responded) but the configured
  /// cloud host did not — DNS/socket/TCP failure specific to that host.
  cloudUnreachable,

  /// No usable internet at all: the cloud host AND a public control endpoint
  /// both failed at the network layer.
  noInternet,

  /// TCP reached the cloud host but the TLS handshake was rejected
  /// (certificate/trust issue, MITM, or broken filtering proxy).
  tlsIssue,

  /// Could not determine reachability on this platform (e.g. web, where
  /// browsers own networking).
  unknown,
}

/// Probe verdict plus a short human-readable detail describing WHICH layer
/// failed and why. The detail is surfaced verbatim to the user so an
/// environment-specific failure (DNS block, wrong project URL, IPv6 issue,
/// certificate interception, …) is never hidden behind a generic message.
class HostProbeResult {
  final HostReachability status;
  final String detail;

  const HostProbeResult(this.status, this.detail);
}