import 'dart:async';
import 'dart:io';

import 'net_probe_types.dart';

export 'net_probe_types.dart';

/// Opens real sockets against the configured Supabase host AND a second,
/// independent control endpoint so "device offline" is never confused with
/// "device online but this particular Supabase host is unreachable".
///
/// The previous implementation ran a single probe against Supabase only:
/// when that one domain failed (wrong project URL, carrier DNS filtering,
/// blocked/broken path to *.supabase.co, IPv6 issues, …), the app wrongly
/// blamed the phone's internet. This version walks each layer — DNS lookup,
/// raw TCP connect, then TLS handshake — and compares the cloud host against
/// a public endpoint to tell the truth.
Future<HostProbeResult> probeHostReachability(
  Uri baseUri, {
  Duration timeout = const Duration(seconds: 6),
}) async {
  const controlHost = 'example.com';
  final port = baseUri.hasPort ? baseUri.port : 443;
  final host = baseUri.host;

  final cloud = await _probeHost(host, port: port, timeout: timeout);
  if (cloud.stage == _Stage.ok) {
    return const HostProbeResult(HostReachability.reachable, '');
  }

  // Second opinion: a stable public endpoint. If IT responds, the phone has
  // internet and the failure is specific to the Supabase host.
  final control = await _probeHost(controlHost, port: 443, timeout: timeout);
  final deviceOnline = control.stage == _Stage.ok;

  final cloudDetail = cloud.detail.isEmpty ? '' : ' — ${cloud.detail}';
  final controlDetail =
      control.detail.isEmpty ? '' : ' (control: ${control.detail})';

  if (cloud.stage == _Stage.tlsFail) {
    if (deviceOnline) {
      return HostProbeResult(
        HostReachability.tlsIssue,
        'Your device is online, but a secure (TLS) connection to "$host" was '
        'rejected by the network$cloudDetail. This is usually certificate '
        'interception, an aggressive firewall, or a filtering proxy.',
      );
    }
    return HostProbeResult(
      HostReachability.noInternet,
      'No usable internet connection. TLS to "$host" failed$cloudDetail'
      '$controlDetail.',
    );
  }

  if (deviceOnline) {
    return HostProbeResult(
      HostReachability.cloudUnreachable,
      'Your device has internet (a public endpoint responded), but the '
      'configured server "$host" could not be reached$cloudDetail. This '
      'usually means the project URL is wrong or blocked, or DNS for that '
      'domain is unavailable on this network.',
    );
  }
  return HostProbeResult(
    HostReachability.noInternet,
    'No internet connection. Neither "$host"$cloudDetail nor the public '
    'endpoint responded$controlDetail.',
  );
}

enum _Stage { ok, dnsFail, tcpFail, tlsFail }

class _HostProbe {
  final _Stage stage;
  final String detail;

  const _HostProbe.ok() : stage = _Stage.ok, detail = '';
  const _HostProbe.dnsFail(this.detail) : stage = _Stage.dnsFail;
  const _HostProbe.tcpFail(this.detail) : stage = _Stage.tcpFail;
  const _HostProbe.tlsFail(this.detail) : stage = _Stage.tlsFail;
}

Future<_HostProbe> _probeHost(
  String host, {
  required int port,
  required Duration timeout,
}) async {
  // ── Layer 1: DNS lookup (catches wrong project URLs & DNS blocks) ──────
  final List<InternetAddress> addresses;
  try {
    addresses = await InternetAddress.lookup(host).timeout(timeout);
  } on TimeoutException {
    return _HostProbe.dnsFail('DNS lookup for "$host" timed out');
  } on SocketException catch (e) {
    return _HostProbe.dnsFail('DNS lookup failed: ${_brief(e)}');
  } catch (e) {
    return _HostProbe.dnsFail('lookup error: ${_brief(e)}');
  }
  if (addresses.isEmpty) {
    return _HostProbe.dnsFail('DNS for "$host" returned no addresses');
  }

  // ── Layer 2: raw TCP connect (IPv4 first — many mobile/ISP networks have
  //    broken IPv6 routes that make IPv6-first attempts hang and fail) ────
  final Socket raw;
  try {
    raw = await _tcpConnect(addresses, port, timeout);
  } on SocketException catch (e) {
    return _HostProbe.tcpFail('TCP connect to "$host:$port" failed: ${_brief(e)}');
  } catch (e) {
    return _HostProbe.tcpFail('TCP connect failed: ${_brief(e)}');
  }

  // ── Layer 3: TLS handshake (catches certificate interception / proxies) ─
  try {
    final tls =
        await SecureSocket.secure(raw, host: host).timeout(timeout);
    await tls.close();
    return const _HostProbe.ok();
  } on HandshakeException catch (e) {
    raw.destroy();
    return _HostProbe.tlsFail(_brief(e));
  } on TimeoutException catch (_) {
    raw.destroy();
    return const _HostProbe.tlsFail('TLS handshake timed out');
  } catch (e) {
    raw.destroy();
    return _HostProbe.tlsFail(_brief(e));
  }
}

/// Connects to the first reachable address, preferring IPv4, so a broken IPv6
/// route does not swallow the whole attempt.
Future<Socket> _tcpConnect(
  List<InternetAddress> addresses,
  int port,
  Duration timeout,
) async {
  final v4 = [
    for (final a in addresses)
      if (a.type == InternetAddressType.IPv4) a,
  ];
  final ordered = [
    ...v4,
    for (final a in addresses)
      if (a.type != InternetAddressType.IPv4) a,
  ];
  SocketException? lastErr;
  for (final a in ordered) {
    try {
      final s = await Socket.connect(a, port, timeout: timeout);
      s.setOption(SocketOption.tcpNoDelay, true);
      return s;
    } on SocketException catch (e) {
      lastErr = e;
    }
  }
  throw lastErr ?? const SocketException('no reachable address');
}

String _brief(Object e) {
  String msg;
  if (e is SocketException) {
    msg = e.message;
    final os = e.osError;
    if (os != null && os.message.isNotEmpty) msg = '$msg (${os.message})';
  } else {
    msg = e.toString();
  }
  if (msg.length > 110) msg = '${msg.substring(0, 107).trimRight()}...';
  return msg;
}