import 'net_probe_types.dart';

export 'net_probe_types.dart';

/// Web-target mirror of `net_probe_io.dart` (chosen by the conditional
/// import). Browsers own all networking, and unlike native there is no raw
/// socket API, so the probe cannot run: every failure we see was already
/// surfaced by the browser itself. Return [HostReachability.unknown] and let
/// the caller fall back to exception-driven classification.
Future<HostProbeResult> probeHostReachability(
  Uri baseUri, {
  Duration timeout = const Duration(seconds: 6),
}) async {
  return const HostProbeResult(
    HostReachability.unknown,
    'Web platform manages its own networking.',
  );
}