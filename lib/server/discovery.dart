import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/app_state.dart';

const int kDiscoveryPort = 4210;
const String kDiscoveryMagic = 'XORBIT_DISCOVER_V1';

/// Hybrid discovery — tries three methods in parallel:
/// 1. UDP broadcast (works on hotspot/home WiFi)
/// 2. UDP subnet scan (works on enterprise WiFi that blocks broadcast)
/// 3. Direct HTTP ping to known IPs (most reliable fallback)
class XorbitDiscovery {
  final AppState state;

  final List<RawDatagramSocket> _sockets = [];
  RawDatagramSocket? _listenSocket;
  Timer? _broadcastTimer;
  Timer? _scanTimer;
  Timer? _pruneTimer;
  List<String> _myIps = [];

  XorbitDiscovery(this.state);

  String? get myIp {
    if (_myIps.isEmpty) return null;
    for (final ip in _myIps) {
      if (ip.startsWith('192.168.') ||
          ip.startsWith('10.')      ||
          ip.startsWith('172.')) return ip;
    }
    return _myIps.first;
  }

  // ── GET ALL LOCAL IPs ─────────────────────────────────

  static Future<List<String>> getAllLocalIps() async {
    final result = <String>[];
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (ip.startsWith('127.') || ip.startsWith('169.254.')) continue;
          result.add(ip);
          debugPrint('Interface: ${iface.name} → $ip');
        }
      }
    } catch (e) {
      debugPrint('getAllLocalIps error: $e');
    }
    return result;
  }

  static String _broadcastAddr(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return '255.255.255.255';
    return '${parts[0]}.${parts[1]}.${parts[2]}.255';
  }

  static String _subnet(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return '';
    return '${parts[0]}.${parts[1]}.${parts[2]}';
  }

  // ── START ─────────────────────────────────────────────

  Future<void> start() async {
    _myIps = await getAllLocalIps();
    if (_myIps.isEmpty) {
      await Future.delayed(const Duration(seconds: 5));
      return start();
    }
    debugPrint('My IPs: $_myIps');
    await _openSockets();
    _startSubnetScan();
  }

  Future<void> _openSockets() async {
    for (final s in _sockets) { try { s.close(); } catch (_) {} }
    _sockets.clear();
    try { _listenSocket?.close(); } catch (_) {}

    // Listen socket — receives broadcasts from any interface
    try {
      _listenSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        kDiscoveryPort,
        reuseAddress: true,
      );
      _listenSocket!.broadcastEnabled = true;
      _listenSocket!.listen(_onPacket,
        onError: (e) { debugPrint('Listen error: $e'); _restart(); },
        onDone: _restart);
      debugPrint('Listen socket on 0.0.0.0:$kDiscoveryPort');
    } catch (e) {
      debugPrint('Listen socket failed: $e');
    }

    // Send socket per interface
    for (final ip in _myIps) {
      try {
        final sock = await RawDatagramSocket.bind(
          InternetAddress(ip), 0, reuseAddress: true);
        sock.broadcastEnabled = true;
        _sockets.add(sock);
      } catch (e) {
        debugPrint('Send socket failed for $ip: $e');
      }
    }

    _broadcast();
    _broadcastTimer?.cancel();
    _broadcastTimer = Timer.periodic(
      const Duration(seconds: 4), (_) async {
        final fresh = await getAllLocalIps();
        if (fresh.length != _myIps.length ||
            !fresh.every((ip) => _myIps.contains(ip))) {
          _myIps = fresh;
          await _openSockets();
          return;
        }
        _broadcast();
      });

    _pruneTimer?.cancel();
    _pruneTimer = Timer.periodic(
      const Duration(seconds: 10), (_) => state.pruneOfflineDevices());
  }

  void _restart() async {
    await Future.delayed(const Duration(seconds: 3));
    _myIps = await getAllLocalIps();
    await _openSockets();
  }

  // ── BROADCAST ────────────────────────────────────────

  void _broadcast() {
    if (state.myId.isEmpty || state.myName.isEmpty) return;
    for (int i = 0; i < _myIps.length; i++) {
      final ip   = _myIps[i];
      final sock = i < _sockets.length ? _sockets[i] : null;
      if (sock == null) continue;
      final msg  = '$kDiscoveryMagic|${state.myId}|${state.myName}|${state.myPort}|$ip';
      final data = utf8.encode(msg);
      try {
        sock.send(data, InternetAddress(_broadcastAddr(ip)), kDiscoveryPort);
      } catch (e) {
        debugPrint('Broadcast error on $ip: $e');
      }
    }
  }

  // ── SUBNET SCAN ───────────────────────────────────────
  // For enterprise WiFi that blocks UDP broadcast between clients.
  // Scans the subnet by HTTP-pinging /info on each IP.
  // Scans 10 IPs at a time concurrently to keep it fast.

  void _startSubnetScan() {
    _scanTimer?.cancel();
    // First scan after 2s, then every 15s (scanning is heavier than broadcast)
    _scanTimer = Timer.periodic(const Duration(seconds: 15), (_) => _scanSubnet());
    Future.delayed(const Duration(seconds: 2), _scanSubnet);
  }

  Future<void> _scanSubnet() async {
    if (_myIps.isEmpty) return;

    for (final myIp in _myIps) {
      final subnet = _subnet(myIp);
      if (subnet.isEmpty) continue;

      debugPrint('Scanning subnet $subnet.1-254...');

      // Scan in batches of 20 concurrent pings
      for (int base = 1; base <= 254; base += 20) {
        final futures = <Future>[];
        for (int i = base; i < base + 20 && i <= 254; i++) {
          final targetIp = '$subnet.$i';
          if (targetIp == myIp) continue; // skip self
          futures.add(_pingDevice(targetIp));
        }
        await Future.wait(futures);

        // Small pause between batches so we don't flood the network
        await Future.delayed(const Duration(milliseconds: 50));
      }
    }
  }

  Future<void> _pingDevice(String ip) async {
    // Quick HTTP GET to /info — times out in 300ms so scan stays fast
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(milliseconds: 300);

      final request = await client.getUrl(
        Uri.parse('http://$ip:$kServerPort/info'));
      final response = await request.close()
        .timeout(const Duration(milliseconds: 300));

      if (response.statusCode == 200) {
        final body = await response.transform(utf8.decoder).join();
        final data = jsonDecode(body) as Map<String, dynamic>;
        final id   = data['id']   as String? ?? '';
        final name = data['name'] as String? ?? 'Unknown';

        if (id.isNotEmpty && id != state.myId) {
          debugPrint('Found via scan: $name @ $ip');
          state.upsertDevice(XorbitDevice(
            id: id, name: name, ip: ip, port: kServerPort));
        }
      }
      client.close();
    } catch (_) {
      // Most IPs won't have Xorbit — silently ignore timeouts
    }
  }

  // ── RECEIVE BROADCAST ────────────────────────────────

  void _onPacket(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final dg = _listenSocket?.receive();
    if (dg == null) return;
    try {
      final msg = utf8.decode(dg.data);
      if (!msg.startsWith(kDiscoveryMagic)) return;

      final parts = msg.split('|');
      if (parts.length < 5) return;

      final id   = parts[1];
      final name = parts[2];
      final port = int.tryParse(parts[3]) ?? kServerPort;
      final ip   = parts[4];

      if (id == state.myId) return;

      debugPrint('Discovered via broadcast: $name @ $ip');
      state.upsertDevice(XorbitDevice(id: id, name: name, ip: ip, port: port));
    } catch (e) {
      debugPrint('Packet parse error: $e');
    }
  }

  // ── STOP ─────────────────────────────────────────────

  void stop() {
    _broadcastTimer?.cancel();
    _scanTimer?.cancel();
    _pruneTimer?.cancel();
    _listenSocket?.close();
    for (final s in _sockets) { try { s.close(); } catch (_) {} }
    _sockets.clear();
  }
}