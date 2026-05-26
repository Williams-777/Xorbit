import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'models/app_state.dart';
import 'models/transfer_item.dart';
import 'server/embedded_server.dart';
import 'server/discovery.dart';

// ─────────────────────────────────────────────────────
//  GLOBALS
// ─────────────────────────────────────────────────────
const int kServerPort = 3000;
const int kChunkSize  = 4 * 1024 * 1024; // 4 MB — balance between speed and reliability

final AppState      appState      = AppState();
final ThemeNotifier themeNotifier = ThemeNotifier();

// ─────────────────────────────────────────────────────
//  MAIN
// ─────────────────────────────────────────────────────
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await appState.init();
  await themeNotifier.load();
  await PremiumGate.load();

  runApp(const XorbitApp());
}

// ─────────────────────────────────────────────────────
//  APP ROOT
// ─────────────────────────────────────────────────────
class XorbitApp extends StatelessWidget {
  const XorbitApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: themeNotifier,
      builder: (_, __) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Xorbit',
        themeMode: themeNotifier.mode,

        darkTheme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: const Color(0xFF080E1C),
          colorScheme: const ColorScheme.dark(
            primary:   Color(0xFF2979FF),
            secondary: Color(0xFF448AFF),
            surface:   Color(0xFF111827),
            onSurface: Colors.white,
          ),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFF080E1C),
            elevation: 0,
            titleTextStyle: TextStyle(
              color: Colors.white, fontSize: 20,
              fontWeight: FontWeight.bold, letterSpacing: 0.5),
            iconTheme: IconThemeData(color: Colors.white),
          ),
          cardTheme: CardThemeData(
            color: const Color(0xFF111827),
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16)),
          ),
          drawerTheme: const DrawerThemeData(
            backgroundColor: Color(0xFF0D1321)),
          elevatedButtonTheme: ElevatedButtonThemeData(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2979FF),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(
                horizontal: 24, vertical: 14),
            ),
          ),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: const Color(0xFF1E2A3A),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none),
          ),
        ),

        theme: ThemeData(
          brightness: Brightness.light,
          scaffoldBackgroundColor: const Color(0xFFF4F6FB),
          colorScheme: const ColorScheme.light(
            primary:   Color(0xFF1565C0),
            secondary: Color(0xFF1E88E5),
            surface:   Colors.white,
            onSurface: Color(0xFF1A1A2E),
          ),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFFF4F6FB),
            elevation: 0,
            titleTextStyle: TextStyle(
              color: Color(0xFF1A1A2E), fontSize: 20,
              fontWeight: FontWeight.bold, letterSpacing: 0.5),
            iconTheme: IconThemeData(color: Color(0xFF1A1A2E)),
          ),
          cardTheme: CardThemeData(
            color: Colors.white,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16)),
          ),
          drawerTheme: const DrawerThemeData(
            backgroundColor: Colors.white),
          elevatedButtonTheme: ElevatedButtonThemeData(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1565C0),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(
                horizontal: 24, vertical: 14),
            ),
          ),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: const Color(0xFFEEF2FA),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none),
          ),
        ),

        home: const DevicePage(),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════
//  DEVICE PAGE
// ═══════════════════════════════════════════════════════
class DevicePage extends StatefulWidget {
  const DevicePage({super.key});
  @override
  State<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage> {
  late EmbeddedServer _server;
  late XorbitDiscovery _discovery;

  bool _starting  = true;
  bool _editingName = false;
  late TextEditingController _nameCtrl;

  bool _connDialogShowing    = false;
  bool _incomingSheetShowing = false;

  Timer? _uiRefreshTimer;
  Timer? _pendingFilesTimer;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: appState.myName);
    appState.addListener(_onStateChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _uiRefreshTimer?.cancel();
    _pendingFilesTimer?.cancel();
    appState.removeListener(_onStateChanged);
    _nameCtrl.dispose();
    _server.stop();
    _discovery.stop();
    super.dispose();
  }

  void _onStateChanged() {
    if (!mounted) return;
    setState(() {});

    // Check for incoming connection request
    if (appState.pendingRequests.containsKey(appState.myId) &&
        !_connDialogShowing) {
      final fromId   = appState.pendingRequests[appState.myId]!;
      final fromName = appState.pendingFromName ?? 
                       appState.nearbyDevices[fromId]?.name ?? 'Unknown';
      final fromIp   = appState.pendingFromIp   ?? 
                       appState.nearbyDevices[fromId]?.ip   ?? '';
      final fromPort = appState.pendingFromPort ?? 
                       appState.nearbyDevices[fromId]?.port ?? kServerPort;

      // Clear immediately so _onStateChanged doesn't fire again
      appState.pendingRequests.remove(appState.myId);

      _showConnectionRequest(
        fromId:   fromId,
        fromName: fromName,
        fromIp:   fromIp,
        fromPort: fromPort,
      );
    }

    // Check if our request was accepted
    if (appState.acceptedByName != null) {
      final name = appState.acceptedByName!;
      appState.acceptedByName = null;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: Colors.green.shade700,
        content: Row(children: [
          const Icon(Icons.check_circle, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text('$name accepted your request!')),
        ]),
        duration: const Duration(seconds: 3),
      ));
    }

    // Check if our request was declined
    if (appState.declinedByName != null) {
      final name = appState.declinedByName!;
      appState.declinedByName = null;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: Colors.red.shade700,
        content: Row(children: [
          const Icon(Icons.cancel, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text('$name declined your connection request')),
        ]),
        duration: const Duration(seconds: 4),
      ));
    }

    // Check for pending files / clipboard
    if (appState.pendingFiles.isNotEmpty) {
      final files = List<Map<String, dynamic>>.from(appState.pendingFiles);
      appState.pendingFiles.clear();

      // Separate clipboard from files
      final clipItems = files.where((f) => f.containsKey('__clipboard__'));
      final fileItems = files.where((f) => !f.containsKey('__clipboard__'));

      for (final clip in clipItems) {
        Clipboard.setData(ClipboardData(text: clip['__clipboard__']));
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('📋 Clipboard synced!')));
      }

      if (fileItems.isNotEmpty && !_incomingSheetShowing) {
        _showIncomingSheet(fileItems.toList());
      }
    }
  }

  // ── INIT ───────────────────────────────────────────

  Future<void> _init() async {
    // If name not set, prompt first
    if (appState.myName.isEmpty) {
      final name = await _promptDeviceName();
      if (name != null && name.isNotEmpty) {
        await appState.saveDeviceName(name);
        _nameCtrl.text = name;
      }
    }

    // Start embedded server — wrap in timeout so Windows firewall issues
    // don't hang the UI forever. Try ports 3000-3005 in case one is blocked.
    bool serverStarted = false;
    for (int port = kServerPort; port < kServerPort + 5; port++) {
      try {
        _server = EmbeddedServer(state: appState, port: port);
        await _server.start().timeout(const Duration(seconds: 5));
        appState.myPort = port;
        debugPrint('Server started on port $port');
        serverStarted = true;
        break;
      } catch (e) {
        debugPrint('Port $port failed: $e — trying next');
      }
    }

    if (!serverStarted) {
      debugPrint('Could not start server on any port — UI will still work');
    }

    // Start mDNS discovery — also timeout-protected
    _discovery = XorbitDiscovery(appState);
    try {
      await _discovery.start().timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('mDNS start failed: $e — will retry in background');
      // Retry in background without blocking the UI
      Future.delayed(const Duration(seconds: 5), () {
        if (mounted) _discovery.start();
      });
    }

    // UI is ready regardless of whether server/mDNS succeeded
    if (mounted) setState(() => _starting = false);

    // Refresh UI periodically for device list updates
    _uiRefreshTimer = Timer.periodic(
      const Duration(seconds: 3), (_) {
        if (mounted) setState(() {});
      });
  }

  // ── DEVICE NAME ────────────────────────────────────

  Future<String?> _promptDeviceName() {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('Name this device'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(hintText: 'e.g. Williams-PC'),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveDeviceName(String name) async {
    if (name.isEmpty) return;
    await appState.saveDeviceName(name);
    setState(() => _editingName = false);
  }

  // ── CONNECTION ─────────────────────────────────────

  Future<void> _sendConnectRequest(XorbitDevice target) async {
    try {
      final dio = Dio();
      await dio.post(
        '${target.baseUrl}/connect-request',
        data: {
          'fromId':   appState.myId,
          'fromName': appState.myName,
          'fromIp':   _discovery.myIp ?? '',
          'fromPort': appState.myPort,
        },
        options: Options(
          sendTimeout:    const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 5),
        ),
      );
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Request sent to ${target.name}')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not reach ${target.name}')));
    }
  }

  void _showConnectionRequest({
    required String fromId,
    required String fromName,
    required String fromIp,
    required int fromPort,
  }) {
    if (_connDialogShowing) return;
    _connDialogShowing = true;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('Incoming Connection'),
        content: Text('$fromName wants to connect.'),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              _connDialogShowing = false;
              appState.pendingRequests.remove(appState.myId);
              try {
                final dio = Dio();
                // Notify the SENDER (fromIp) that we declined — 
                // this triggers a snackbar on their device
                await dio.post(
                  'http://$fromIp:$fromPort/notify-declined',
                  data: {'byName': appState.myName},
                );
              } catch (_) {}
            },
            child: const Text('Decline',
              style: TextStyle(color: Colors.red)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              _connDialogShowing = false;
              await _acceptConnection(
                fromId: fromId, fromName: fromName,
                fromIp: fromIp, fromPort: fromPort);
            },
            child: const Text('Accept'),
          ),
        ],
      ),
    ).then((_) => _connDialogShowing = false);
  }

  Future<void> _acceptConnection({
    required String fromId,
    required String fromName,
    required String fromIp,
    required int fromPort,
  }) async {
    // pendingRequests already cleared in _onStateChanged before dialog showed
    // Tell the sender they were accepted — they connect on their side
    try {
      final dio = Dio();
      await dio.post(
        'http://$fromIp:$fromPort/accept',
        data: {
          'peerId':   appState.myId,
          'peerName': appState.myName,
          'peerIp':   _discovery.myIp ?? '',
          'peerPort': appState.myPort,
        },
      );

      // Now connect on OUR side too — both sides are now connected
      final device = XorbitDevice(
        id:   fromId,
        name: fromName,
        ip:   fromIp,
        port: fromPort,
      );
      appState.connect(device);

      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('✅ Connected to $fromName')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connection failed — try again')));
    }
  }

  Future<void> _disconnect() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Disconnect'),
        content: const Text('Are you sure?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Disconnect')),
        ],
      ),
    );
    if (confirm != true) return;

    // Notify peer
    try {
      final dio = Dio();
      await dio.post('${appState.peerBaseUrl}/disconnect');
    } catch (_) {}

    appState.disconnect();
  }

  // ── CLIPBOARD ──────────────────────────────────────

  Future<void> _syncClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text == null || data!.text!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Clipboard is empty')));
      return;
    }
    try {
      final dio = Dio();
      await dio.post('${appState.peerBaseUrl}/clipboard',
        data: {'text': data.text});
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('📋 Clipboard synced!')));
    } catch (_) {}
  }

  // ── INCOMING FILE SHEET ────────────────────────────

  void _showIncomingSheet(List<Map<String, dynamic>> files) {
    if (_incomingSheetShowing) return;
    _incomingSheetShowing = true;

    // Auto-navigate to transfer page
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => TransferPage(
        targetName: appState.connectedToName ?? 'Unknown',
      ),
    ));

    _incomingSheetShowing = false;
  }

  // ── UI ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final scheme      = Theme.of(context).colorScheme;
    final isDark      = themeNotifier.isDark;
    final isConnected = appState.isConnected;

    final nearbyList = appState.nearbyDevices.values
        .where((d) => d.id != appState.myId)
        .toList();

    return Scaffold(
      drawer: _buildDrawer(context, scheme),
      appBar: AppBar(
        leading: Builder(builder: (ctx) => IconButton(
          icon: const Icon(Icons.menu_rounded),
          onPressed: () => Scaffold.of(ctx).openDrawer(),
        )),
        title: const Text('Xorbit'),
        actions: [
          // Clipboard button — always visible, only active when connected
          IconButton(
            icon: Icon(
              Icons.content_paste_rounded,
              color: appState.isConnected
                ? null
                : Theme.of(context).colorScheme.onSurface.withOpacity(0.25),
            ),
            tooltip: appState.isConnected
                ? 'Sync clipboard to other device'
                : 'Connect to a device first',
            onPressed: appState.isConnected ? _syncClipboard : null,
          ),
          IconButton(
            icon: Icon(isDark
              ? Icons.wb_sunny_rounded
              : Icons.nightlight_round),
            onPressed: () {
              themeNotifier.toggle();
              themeNotifier.save();
            },
          ),
        ],
      ),

      body: _starting
          ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text('Starting Xorbit...',
                style: TextStyle(
                  color: scheme.onSurface.withOpacity(0.5))),
            ]))
          : Column(children: [

              // ── MY DEVICE CARD ──────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: _myDeviceCard(scheme),
              ),

              // ── IP / NETWORK INFO ───────────────────
              if (_discovery.myIp != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                  child: Row(children: [
                    Icon(Icons.wifi, size: 13,
                      color: scheme.onSurface.withOpacity(0.4)),
                    const SizedBox(width: 4),
                    Text('${_discovery.myIp}:$kServerPort',
                      style: TextStyle(fontSize: 11,
                        color: scheme.onSurface.withOpacity(0.4))),
                  ]),
                ),

              // ── CONNECTION STATUS ───────────────────
              if (isConnected) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: Row(children: [
                    const Icon(Icons.circle, color: Colors.green, size: 8),
                    const SizedBox(width: 6),
                    Text('Connected to ${appState.connectedToName}',
                      style: const TextStyle(
                        color: Colors.green, fontSize: 13)),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: _disconnect,
                      icon: const Icon(Icons.link_off,
                        size: 14, color: Colors.red),
                      label: const Text('Disconnect',
                        style: TextStyle(
                          color: Colors.red, fontSize: 12)),
                    ),
                  ]),
                ),

                // ── BIG SEND BUTTON ───────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.send_rounded, size: 22),
                      label: const Text('Send',
                        style: TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold)),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18)),
                      ),
                      onPressed: () => Navigator.push(context,
                        MaterialPageRoute(
                          builder: (_) => TransferPage(
                            targetName: appState.connectedToName ?? 'Unknown',
                          ),
                        )),
                    ),
                  ),
                ),
              ],

              // ── NEARBY DEVICES LABEL ────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
                child: Row(children: [
                  Text('Nearby Devices',
                    style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600,
                      color: scheme.onSurface.withOpacity(0.6))),
                  const SizedBox(width: 8),
                  if (nearbyList.isEmpty)
                    SizedBox(
                      width: 12, height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: scheme.onSurface.withOpacity(0.3)),
                    ),
                ]),
              ),

              // ── DEVICE LIST ─────────────────────────
              Expanded(
                child: nearbyList.isEmpty
                    ? Center(child: Column(
                        mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.wifi_find_rounded, size: 56,
                          color: scheme.onSurface.withOpacity(0.15)),
                        const SizedBox(height: 10),
                        Text('Looking for devices...',
                          style: TextStyle(
                            color: scheme.onSurface.withOpacity(0.3),
                            fontSize: 13)),
                        const SizedBox(height: 6),
                        Text('Make sure both devices are on the same WiFi or hotspot',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: scheme.onSurface.withOpacity(0.2),
                            fontSize: 11)),
                      ]))
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: nearbyList.length,
                        itemBuilder: (_, i) =>
                            _deviceCard(nearbyList[i], scheme),
                      ),
              ),

              // ── GROUP / PREMIUM BUTTON ──────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
                child: OutlinedButton.icon(
                  icon: Icon(Icons.group_rounded,
                    color: PremiumGate.isPremium
                        ? scheme.primary : Colors.grey,
                    size: 20),
                  label: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text('Group Connect',
                      style: TextStyle(
                        color: PremiumGate.isPremium
                            ? scheme.primary : Colors.grey)),
                    if (!PremiumGate.isPremium) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.amber.shade700,
                          borderRadius: BorderRadius.circular(5)),
                        child: const Text('PRO',
                          style: TextStyle(
                            color: Colors.white, fontSize: 9,
                            fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ]),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(46),
                    side: BorderSide(
                      color: PremiumGate.isPremium
                          ? scheme.primary.withOpacity(0.4)
                          : Colors.grey.withOpacity(0.25)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: () {
                    if (!PremiumGate.isPremium) {
                      _showPremiumGate(context);
                      return;
                    }
                    Navigator.push(context, MaterialPageRoute(
                      builder: (_) => const GroupPage()));
                  },
                ),
              ),
            ]),
    );
  }

  Widget _myDeviceCard(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.primary.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.primary.withOpacity(0.25)),
      ),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: scheme.primary.withOpacity(0.2),
            shape: BoxShape.circle,
          ),
          child: Icon(
            Platform.isAndroid || Platform.isIOS
                ? Icons.smartphone : Icons.computer,
            color: scheme.primary, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _editingName
              ? TextField(
                  controller: _nameCtrl,
                  autofocus: true,
                  style: const TextStyle(
                    fontSize: 17, fontWeight: FontWeight.bold),
                  decoration: const InputDecoration(
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 8, vertical: 6)),
                  onSubmitted: _saveDeviceName,
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('This device',
                      style: TextStyle(fontSize: 11,
                        color: scheme.primary.withOpacity(0.7))),
                    Text(appState.myName,
                      style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.bold)),
                  ],
                ),
        ),
        IconButton(
          icon: Icon(
            _editingName ? Icons.check_rounded : Icons.edit_rounded,
            size: 18, color: scheme.primary),
          onPressed: () {
            if (_editingName) {
              _saveDeviceName(_nameCtrl.text.trim());
            } else {
              setState(() => _editingName = true);
            }
          },
        ),
      ]),
    );
  }

  Widget _deviceCard(XorbitDevice device, ColorScheme scheme) {
    final connectedToUs = appState.connectedToId == device.id;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: connectedToUs
                ? Colors.green.withOpacity(0.4)
                : scheme.onSurface.withOpacity(0.07)),
        ),
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16, vertical: 4),
          leading: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: (connectedToUs
                  ? Colors.green : scheme.primary).withOpacity(0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.devices_rounded,
              color: connectedToUs ? Colors.green : scheme.primary,
              size: 20),
          ),
          title: Text(device.name,
            style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(
            connectedToUs ? '✅ Connected' : '${device.ip}',
            style: TextStyle(
              fontSize: 11,
              color: connectedToUs
                  ? Colors.green
                  : scheme.onSurface.withOpacity(0.4))),
          trailing: connectedToUs
              ? null
              : ElevatedButton(
                  onPressed: () => _sendConnectRequest(device),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('Connect'),
                ),
        ),
      ),
    );
  }

  // ── DRAWER ─────────────────────────────────────────

  Widget _buildDrawer(BuildContext context, ColorScheme scheme) {
    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 48, height: 48,
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(14)),
                    child: const Icon(Icons.wifi_tethering_rounded,
                      color: Colors.white, size: 26),
                  ),
                  const SizedBox(height: 12),
                  const Text('Xorbit',
                    style: TextStyle(
                      fontSize: 22, fontWeight: FontWeight.bold)),
                  Text('Fast. Local. Private.',
                    style: TextStyle(fontSize: 12,
                      color: scheme.onSurface.withOpacity(0.4))),
                ],
              ),
            ),
            const Divider(height: 24),
            _drawerItem(Icons.history_rounded, 'Transfer History', () {
              Navigator.pop(context);
              Navigator.push(context, MaterialPageRoute(
                builder: (_) => const HistoryPage()));
            }),
            _drawerItem(Icons.settings_rounded, 'Settings', () {
              Navigator.pop(context);
              Navigator.push(context, MaterialPageRoute(
                builder: (_) => SettingsPage(
                  onNameChanged: (n) => setState(() {
                    _nameCtrl.text = n;
                  }),
                )));
            }),
            _drawerItem(Icons.info_outline_rounded, 'About', () {
              Navigator.pop(context);
              _showAbout(context, scheme);
            }),
            _drawerItem(Icons.help_outline_rounded, 'Help', () {
              Navigator.pop(context);
              _showHelp(context);
            }),
            const Spacer(),
            if (!PremiumGate.isPremium)
              Padding(
                padding: const EdgeInsets.all(16),
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    _showPremiumGate(context);
                  },
                  icon: const Icon(Icons.star_rounded),
                  label: const Text('Upgrade to Pro'),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size.fromHeight(46),
                    backgroundColor: Colors.amber.shade700),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _drawerItem(IconData icon, String label, VoidCallback onTap) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(icon, color: scheme.primary, size: 22),
      title: Text(label, style: const TextStyle(fontSize: 15)),
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: 20, vertical: 2),
    );
  }

  void _showAbout(BuildContext context, ColorScheme scheme) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Row(children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: scheme.primary,
              borderRadius: BorderRadius.circular(8)),
            child: const Icon(Icons.wifi_tethering_rounded,
              color: Colors.white, size: 18)),
          const SizedBox(width: 10),
          const Text('Xorbit'),
        ]),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Version 1.0.0'),
            SizedBox(height: 8),
            Text('Fast, local, ad-free file transfer.\n\n'
              '✓ No internet required\n'
              '✓ No accounts or sign-ups\n'
              '✓ No tracking or ads\n'
              '✓ Works on WiFi or hotspot\n'
              '✓ Your files never leave your network'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close')),
        ],
      ),
    );
  }

  void _showHelp(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('How to use Xorbit'),
        content: const SingleChildScrollView(
          child: Text(
            '1. Open Xorbit on both devices.\n\n'
            '2. Connect both to the same WiFi — or one device turns on a hotspot and the other connects to it.\n\n'
            '3. Your device appears automatically in the other device\'s list.\n\n'
            '4. Tap Connect, the other device accepts.\n\n'
            '5. Tap Send and pick your files.\n\n'
            '6. Files save to the right folder automatically.\n\n'
            'PRO: Create a Group to connect up to 20 devices.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Got it')),
        ],
      ),
    );
  }

  void _showPremiumGate(BuildContext context) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.star_rounded, size: 48, color: Colors.amber),
          const SizedBox(height: 12),
          const Text('Xorbit Pro',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text(
            'Connect up to 20 devices in a group.\nBroadcast files to everyone at once.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: () async {
              // TODO: real payment via in-app purchase
              await PremiumGate.unlock();
              if (context.mounted) {
                Navigator.pop(context);
                setState(() {});
              }
            },
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
              backgroundColor: Colors.amber.shade700),
            child: const Text('Unlock Pro — \$4.99',
              style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 10),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Maybe later')),
        ]),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════
//  TRANSFER PAGE
// ═══════════════════════════════════════════════════════
class TransferPage extends StatefulWidget {
  final String targetName;
  const TransferPage({super.key, required this.targetName});
  @override
  State<TransferPage> createState() => _TransferPageState();
}

class _TransferPageState extends State<TransferPage> {
  final Dio dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: Duration.zero, // no timeout — large chunks take time
    sendTimeout:    Duration.zero, // no timeout on sending
  ));

  bool   _isRunning = false;
  String _filter    = 'all'; // all / sending / receiving

  List<TransferItem> get _filtered {
    switch (_filter) {
      case 'sending':
        return appState.transfers
            .where((t) => t.direction == TransferDirection.sending).toList();
      case 'receiving':
        return appState.transfers
            .where((t) => t.direction == TransferDirection.receiving).toList();
      default:
        return appState.transfers;
    }
  }

  // ── FILE PICK ──────────────────────────────────────

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple:  true,
      withData:       false,
      withReadStream: true,
    );
    if (result == null) return;

    final valid = result.files.where(
      (f) => f.path != null || f.readStream != null).toList();
    if (valid.isEmpty) return;

    for (final f in valid) {
      final item = TransferItem.sending(
        transferId: const Uuid().v4(), file: f);
      appState.addTransfer(item);
    }

    if (!_isRunning) _runQueue();
  }

  Future<void> _runQueue() async {
    _isRunning = true;
    for (final item in appState.transfers) {
      if (item.direction != TransferDirection.sending) continue;
      if (item.status == TransferStatus.cancelled) continue;
      if (item.status == TransferStatus.done) continue;
      await _uploadFile(item);
    }
    _isRunning = false;
  }

  // ── CHUNKED UPLOAD ─────────────────────────────────
  // Sends directly to the receiver's embedded server

  Future<void> _uploadFile(TransferItem item) async {
    if (item.status == TransferStatus.cancelled) return;
    if (appState.peerBaseUrl == null) {
      appState.updateTransfer(item.transferId,
        status: TransferStatus.failed);
      return;
    }

    appState.updateTransfer(item.transferId,
      status: TransferStatus.transferring);

    final totalSize   = item.file.size;
    final totalChunks = (totalSize / kChunkSize).ceil();
    final hasPath     = item.file.path != null;

    int sentBytes      = item.currentChunk * kChunkSize;
    int lastSpeedBytes = sentBytes;
    int lastSpeedTime  = DateTime.now().millisecondsSinceEpoch;

    RandomAccessFile? raf;
    List<Uint8List> streamChunks = [];

    if (hasPath) {
      try { raf = await File(item.file.path!).open(); }
      catch (_) {
        appState.updateTransfer(item.transferId,
          status: TransferStatus.failed);
        return;
      }
    } else {
      // For stream-based files (Android media store), buffer chunk by chunk
      // rather than loading the entire file into memory at once.
      // We collect into streamChunks lazily during the upload loop below.
      try {
        final all = <int>[];
        await for (final chunk in item.file.readStream!) {
          all.addAll(chunk);
          // Free memory as we go by chunking immediately
          if (all.length >= kChunkSize) {
            streamChunks.add(Uint8List.fromList(all.sublist(0, kChunkSize)));
            all.removeRange(0, kChunkSize);
          }
        }
        // Remaining bytes
        if (all.isNotEmpty) {
          streamChunks.add(Uint8List.fromList(all));
        }
      } catch (_) {
        appState.updateTransfer(item.transferId,
          status: TransferStatus.failed);
        return;
      }
    }

    try {
      for (int i = item.currentChunk; i < totalChunks; i++) {
        if (item.status == TransferStatus.cancelled) return;

        Uint8List chunkBytes;
        if (hasPath) {
          final len = ((i + 1) * kChunkSize > totalSize)
              ? totalSize - (i * kChunkSize) : kChunkSize;
          await raf!.setPosition(i * kChunkSize);
          chunkBytes = await raf.read(len);
        } else {
          chunkBytes = streamChunks[i];
        }

        if (item.status == TransferStatus.cancelled) return;

        try {
          final formData = FormData.fromMap({
            'transferId':  item.transferId,
            'chunkIndex':  i.toString(),
            'totalChunks': totalChunks.toString(),
            'totalSize':   totalSize.toString(),
            'filename':    item.file.name,
            'fromId':      appState.myId,
            'fromName':    appState.myName,
            'file': MultipartFile.fromBytes(
              chunkBytes, filename: item.file.name),
          });

          await dio.post(
            '${appState.peerBaseUrl}/chunk', data: formData);

          sentBytes         += chunkBytes.length;
          item.currentChunk  = i + 1;

          final now = DateTime.now().millisecondsSinceEpoch;
          if (now - lastSpeedTime >= 500) {
            final bps = (sentBytes - lastSpeedBytes) /
                ((now - lastSpeedTime) / 1000);
            lastSpeedBytes = sentBytes;
            lastSpeedTime  = now;
            appState.updateTransfer(item.transferId,
              speed: '${_fmtSize(bps.toInt())}/s');
          }

          appState.updateTransfer(item.transferId,
            progress:     item.currentChunk / totalChunks,
            currentChunk: item.currentChunk);

        } on DioException catch (e) {
          debugPrint('Chunk $i failed: ${e.message} — retrying in 2s');
          await Future.delayed(const Duration(seconds: 2));
          if (item.status == TransferStatus.cancelled) return;
          // Rebuild FormData — cannot reuse after Dio consumes it
          try {
            final retryData = FormData.fromMap({
              'transferId':  item.transferId,
              'chunkIndex':  i.toString(),
              'totalChunks': totalChunks.toString(),
              'totalSize':   totalSize.toString(),
              'filename':    item.file!.name,
              'fromId':      appState.myId,
              'fromName':    appState.myName,
              'file': MultipartFile.fromBytes(
                chunkBytes, filename: item.file!.name),
            });
            await dio.post('${appState.peerBaseUrl}/chunk', data: retryData);
            sentBytes         += chunkBytes.length;
            item.currentChunk  = i + 1;
            appState.updateTransfer(item.transferId,
              progress:     item.currentChunk / totalChunks,
              currentChunk: item.currentChunk);
          } catch (e2) {
            debugPrint('Chunk $i retry failed: $e2');
            if (item.status != TransferStatus.cancelled) {
              appState.updateTransfer(item.transferId,
                status: TransferStatus.failed);
            }
            return;
          }
        }
      }
    } finally {
      await raf?.close();
    }

    if (item.status != TransferStatus.cancelled) {
      appState.updateTransfer(item.transferId,
        status: TransferStatus.done, progress: 1.0, speed: '');
    }
  }

  Future<void> _cancel(TransferItem item) async {
    appState.updateTransfer(item.transferId,
      status: TransferStatus.cancelled);
    try {
      await dio.post('${appState.peerBaseUrl}/transfer/cancel',
        data: {'transferId': item.transferId});
    } catch (_) {}
  }

  Future<void> _retry(TransferItem item) async {
    appState.updateTransfer(item.transferId,
      status:       TransferStatus.waiting,
      currentChunk: 0,
      progress:     0);
    if (!_isRunning) _runQueue();
  }

  // ── HELPERS ────────────────────────────────────────

  String _fmtSize(dynamic bytes) {
    final b = (bytes is int) ? bytes : int.tryParse(bytes.toString()) ?? 0;
    if (b < 1024)             return '${b}B';
    if (b < 1024 * 1024)      return '${(b / 1024).toStringAsFixed(1)}KB';
    if (b < 1024 * 1024 * 1024)
      return '${(b / (1024 * 1024)).toStringAsFixed(1)}MB';
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)}GB';
  }

  String _fileIcon(String name) {
    final ext = p.extension(name).toLowerCase().replaceFirst('.', '');
    if (['jpg','jpeg','png','gif','webp'].contains(ext)) return '🖼️';
    if (['mp4','mov','avi','mkv','webm'].contains(ext))  return '🎬';
    if (['mp3','wav','aac','flac','m4a'].contains(ext))  return '🎵';
    if (['pdf'].contains(ext))                            return '📄';
    if (['zip','rar','7z','tar'].contains(ext))           return '🗜️';
    if (['doc','docx'].contains(ext))                     return '📝';
    if (['apk'].contains(ext))                            return '📦';
    return '📁';
  }

  Color _statusColor(TransferStatus s) {
    switch (s) {
      case TransferStatus.done:         return Colors.green;
      case TransferStatus.failed:       return Colors.red;
      case TransferStatus.cancelled:    return Colors.grey;
      case TransferStatus.transferring: return Colors.blue;
      default:                          return Colors.grey;
    }
  }

  String _statusLabel(TransferItem item) {
    if (item.direction == TransferDirection.receiving) {
      return item.status == TransferStatus.done ? 'Received' : 'Receiving';
    }
    switch (item.status) {
      case TransferStatus.waiting:      return 'Waiting';
      case TransferStatus.transferring: return 'Sending';
      case TransferStatus.done:         return 'Sent';
      case TransferStatus.cancelled:    return 'Cancelled';
      case TransferStatus.failed:       return 'Failed';
    }
  }

  // ── UI ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final scheme   = Theme.of(context).colorScheme;
    final filtered = _filtered;

    return AnimatedBuilder(
      animation: appState,
      builder: (_, __) => Scaffold(
        appBar: AppBar(
          title: Text('Transfer · ${widget.targetName}'),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _filter,
                  icon: const Icon(Icons.filter_list_rounded, size: 20),
                  items: const [
                    DropdownMenuItem(value: 'all',
                      child: Text('All')),
                    DropdownMenuItem(value: 'sending',
                      child: Text('Sending')),
                    DropdownMenuItem(value: 'receiving',
                      child: Text('Receiving')),
                  ],
                  onChanged: (v) => setState(() => _filter = v ?? 'all'),
                ),
              ),
            ),
          ],
        ),
        body: Column(children: [
          Expanded(
            child: filtered.isEmpty
                ? Center(child: Column(
                    mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.swap_horiz_rounded, size: 64,
                      color: scheme.onSurface.withOpacity(0.15)),
                    const SizedBox(height: 12),
                    Text('No transfers yet',
                      style: TextStyle(
                        color: scheme.onSurface.withOpacity(0.3))),
                    const SizedBox(height: 20),
                    ElevatedButton.icon(
                      onPressed: _pickFiles,
                      icon: const Icon(Icons.add),
                      label: const Text('Add Files')),
                  ]))
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: filtered.length,
                    itemBuilder: (_, i) {
                      final item     = filtered[i];
                      final isSending =
                          item.direction == TransferDirection.sending;

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Container(
                          decoration: BoxDecoration(
                            color: scheme.surface,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: scheme.onSurface.withOpacity(0.07))),
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                Text(_fileIcon(item.filename),
                                  style: const TextStyle(fontSize: 22)),
                                const SizedBox(width: 10),
                                Expanded(child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(item.filename,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 14)),
                                    Text(_fmtSize(item.totalSize),
                                      style: TextStyle(fontSize: 11,
                                        color: scheme.onSurface
                                            .withOpacity(0.5))),
                                  ],
                                )),
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: _statusColor(item.status)
                                        .withOpacity(0.12),
                                    borderRadius: BorderRadius.circular(6)),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        isSending
                                          ? Icons.upload_rounded
                                          : Icons.download_rounded,
                                        size: 11,
                                        color: _statusColor(item.status)),
                                      const SizedBox(width: 3),
                                      Text(_statusLabel(item),
                                        style: TextStyle(fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                          color: _statusColor(item.status))),
                                    ],
                                  ),
                                ),
                              ]),

                              if (item.status == TransferStatus.transferring ||
                                  item.status == TransferStatus.done) ...[
                                const SizedBox(height: 10),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: LinearProgressIndicator(
                                    value: item.progress,
                                    minHeight: 6,
                                    backgroundColor: scheme.onSurface
                                        .withOpacity(0.08),
                                    color: _statusColor(item.status),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Row(children: [
                                  Text(
                                    '${(item.progress * 100).toStringAsFixed(0)}%',
                                    style: TextStyle(fontSize: 11,
                                      color: scheme.onSurface
                                          .withOpacity(0.5))),
                                  const Spacer(),
                                  if (item.speed.isNotEmpty)
                                    Text(item.speed,
                                      style: TextStyle(fontSize: 11,
                                        color: scheme.onSurface
                                            .withOpacity(0.4))),
                                ]),
                              ],

                              if (isSending &&
                                  item.status != TransferStatus.done &&
                                  item.status != TransferStatus.cancelled)
                                Row(children: [
                                  if (item.status == TransferStatus.failed)
                                    TextButton.icon(
                                      onPressed: () => _retry(item),
                                      icon: const Icon(Icons.refresh, size: 14),
                                      label: const Text('Retry',
                                        style: TextStyle(fontSize: 12))),
                                  const Spacer(),
                                  TextButton.icon(
                                    onPressed: () => _cancel(item),
                                    icon: const Icon(Icons.close, size: 14,
                                      color: Colors.red),
                                    label: const Text('Cancel',
                                      style: TextStyle(
                                        color: Colors.red, fontSize: 12))),
                                ]),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
            child: ElevatedButton.icon(
              onPressed: _pickFiles,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add Files'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(50)),
            ),
          ),
        ]),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════
//  GROUP PAGE  (premium)
// ═══════════════════════════════════════════════════════
class GroupPage extends StatefulWidget {
  const GroupPage({super.key});
  @override
  State<GroupPage> createState() => _GroupPageState();
}

class _GroupPageState extends State<GroupPage> {
  final Dio dio = Dio();
  bool _loading = false;
  final _codeCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();

  Future<void> _createRoom() async {
    setState(() => _loading = true);
    try {
      // Create room on our own embedded server
      final res = await dio.post(
        'http://127.0.0.1:$kServerPort/room/create',
        data: {
          'roomName': _nameCtrl.text.isNotEmpty
              ? _nameCtrl.text : "${appState.myName}'s Room",
        },
      );
      final room = res.data['room'];
      appState.joinedRoom(
        code:      res.data['code'],
        name:      room['name'],
        creatorId: room['creatorId'],
        members:   [{'id': appState.myId, 'name': appState.myName}],
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed: $e')));
    }
    setState(() => _loading = false);
  }

  Future<void> _joinRoom() async {
    final code = _codeCtrl.text.trim().toUpperCase();
    if (code.length != 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter 6-character code')));
      return;
    }
    // To join someone else's room, we need to reach their server.
    // Find the device in nearby list that has this room code.
    // For now, we try all nearby devices until one responds.
    setState(() => _loading = true);
    bool joined = false;
    for (final device in appState.nearbyDevices.values) {
      try {
        final res = await dio.post(
          '${device.baseUrl}/room/join',
          data: {'code': code},
          options: Options(
            sendTimeout:    const Duration(seconds: 3),
            receiveTimeout: const Duration(seconds: 3)),
        );
        final room = res.data['room'];
        final members = List<Map<String, dynamic>>.from(
          (room['members'] as List).map((m) => Map<String, dynamic>.from(m)));
        appState.joinedRoom(
          code:      code,
          name:      room['name'],
          creatorId: room['creatorId'],
          members:   members,
        );
        joined = true;
        break;
      } catch (_) { continue; }
    }
    if (!joined && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Room not found — check the code')));
    }
    setState(() => _loading = false);
  }

  Future<void> _leaveRoom() async {
    try {
      await dio.post('http://127.0.0.1:$kServerPort/room/leave');
    } catch (_) {}
    appState.leftRoom();
  }

  Future<void> _kickMember(String targetId) async {
    try {
      await dio.post('http://127.0.0.1:$kServerPort/room/kick',
        data: {'targetId': targetId});
      final updated = appState.roomMembers
          .where((m) => m['id'] != targetId).toList();
      appState.updateRoomMembers(updated);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: appState,
      builder: (_, __) => Scaffold(
        appBar: AppBar(
          title: Text(appState.inRoom
              ? (appState.roomName ?? 'Group') : 'Group Connect'),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : appState.inRoom
                ? _roomView(scheme)
                : _joinCreateView(),
      ),
    );
  }

  Widget _joinCreateView() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Create a Room',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
              hintText: 'Room name (optional)',
              prefixIcon: Icon(Icons.group))),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: _createRoom,
            icon: const Icon(Icons.add_rounded),
            label: const Text('Create Room'),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(50))),
          const SizedBox(height: 32),
          const Text('Join a Room',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          TextField(
            controller: _codeCtrl,
            maxLength: 6,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              hintText: 'Enter 6-character code',
              prefixIcon: Icon(Icons.vpn_key_rounded),
              counterText: '')),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _joinRoom,
            icon: const Icon(Icons.login_rounded),
            label: const Text('Join Room'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(50))),
        ],
      ),
    );
  }

  Widget _roomView(ColorScheme scheme) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: scheme.primary.withOpacity(0.1),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: scheme.primary.withOpacity(0.3))),
          child: Column(children: [
            Text(appState.roomName ?? 'Group',
              style: const TextStyle(
                fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('Room Code',
              style: TextStyle(fontSize: 11, color: Colors.grey)),
            const SizedBox(height: 4),
            Text(appState.roomCode ?? '',
              style: TextStyle(
                fontSize: 32, fontWeight: FontWeight.bold,
                color: scheme.primary, letterSpacing: 6)),
            const SizedBox(height: 4),
            Text('Share this code with others to join',
              style: TextStyle(fontSize: 11,
                color: scheme.onSurface.withOpacity(0.4))),
          ]),
        ),
      ),

      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          Text('Members (${appState.roomMembers.length}/20)',
            style: const TextStyle(fontWeight: FontWeight.bold)),
        ]),
      ),
      const SizedBox(height: 8),

      Expanded(
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: appState.roomMembers.length,
          itemBuilder: (_, i) {
            final m = appState.roomMembers[i];
            final isMe      = m['id'] == appState.myId;
            final isCreator = m['id'] == appState.roomCreatorId;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Container(
                decoration: BoxDecoration(
                  color: scheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: scheme.onSurface.withOpacity(0.07))),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: scheme.primary.withOpacity(0.15),
                    child: Text(
                      (m['name'] as String).substring(0, 1).toUpperCase(),
                      style: TextStyle(color: scheme.primary,
                        fontWeight: FontWeight.bold)),
                  ),
                  title: Text(m['name'] ?? 'Unknown'),
                  subtitle: isCreator
                      ? const Text('Creator',
                          style: TextStyle(fontSize: 11))
                      : isMe
                          ? const Text('You',
                              style: TextStyle(fontSize: 11))
                          : null,
                  trailing: appState.isRoomCreator && !isMe
                      ? IconButton(
                          icon: const Icon(Icons.remove_circle_outline,
                            color: Colors.red, size: 20),
                          onPressed: () => _kickMember(m['id']))
                      : null,
                ),
              ),
            );
          },
        ),
      ),

      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: ElevatedButton.icon(
          onPressed: () => Navigator.push(context, MaterialPageRoute(
            builder: (_) => TransferPage(
              targetName: appState.roomName ?? 'Group'))),
          icon: const Icon(Icons.send_rounded),
          label: const Text('Send to Room'),
          style: ElevatedButton.styleFrom(
            minimumSize: const Size.fromHeight(50))),
      ),

      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        child: OutlinedButton.icon(
          onPressed: _leaveRoom,
          icon: const Icon(Icons.exit_to_app, color: Colors.red),
          label: const Text('Leave Room',
            style: TextStyle(color: Colors.red)),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(46),
            side: const BorderSide(color: Colors.red))),
      ),
    ]);
  }
}

// ═══════════════════════════════════════════════════════
//  SETTINGS PAGE
// ═══════════════════════════════════════════════════════
class SettingsPage extends StatefulWidget {
  final Function(String) onNameChanged;
  const SettingsPage({super.key, required this.onNameChanged});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: appState.myName);
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  Future<void> _save() async {
    final name = _ctrl.text.trim();
    if (name.isEmpty) return;
    await appState.saveDeviceName(name);
    widget.onNameChanged(name);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Device name saved')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        const Text('Device Name',
          style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: TextField(controller: _ctrl,
            decoration: const InputDecoration(
              hintText: 'Enter device name'))),
          const SizedBox(width: 8),
          ElevatedButton(onPressed: _save, child: const Text('Save')),
        ]),
        const SizedBox(height: 28),
        const Text('Appearance',
          style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        AnimatedBuilder(
          animation: themeNotifier,
          builder: (_, __) => SwitchListTile(
            title: const Text('Dark Mode'),
            value: themeNotifier.isDark,
            onChanged: (_) {
              themeNotifier.toggle();
              themeNotifier.save();
            },
            secondary: Icon(themeNotifier.isDark
              ? Icons.nightlight_round : Icons.wb_sunny_rounded),
          ),
        ),
        const SizedBox(height: 28),
        const Text('Device ID',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        const SizedBox(height: 4),
        Text(appState.myId,
          style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ]),
    );
  }
}

// ═══════════════════════════════════════════════════════
//  HISTORY PAGE
// ═══════════════════════════════════════════════════════
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});
  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  final Dio dio = Dio();
  List<dynamic> history = [];
  bool loading = true;

  @override
  void initState() { super.initState(); _fetch(); }

  Future<void> _fetch() async {
    setState(() => loading = true);
    try {
      final res = await dio.get(
        'http://127.0.0.1:$kServerPort/history');
      setState(() {
        history = List<dynamic>.from(res.data['history'] ?? []);
        loading = false;
      });
    } catch (_) {
      setState(() => loading = false);
    }
  }

  String _fmtTime(int ts) {
    final dt   = DateTime.fromMillisecondsSinceEpoch(ts);
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24)   return '${diff.inHours}h ago';
    return '${dt.day}/${dt.month}/${dt.year}';
  }

  String _fmtSize(dynamic bytes) {
    final b = (bytes is int) ? bytes : int.tryParse(bytes.toString()) ?? 0;
    if (b < 1024)             return '${b}B';
    if (b < 1024 * 1024)      return '${(b / 1024).toStringAsFixed(1)}KB';
    if (b < 1024 * 1024 * 1024)
      return '${(b / (1024 * 1024)).toStringAsFixed(1)}MB';
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)}GB';
  }

  String _fileIcon(String name) {
    final ext = p.extension(name).toLowerCase().replaceFirst('.', '');
    if (['jpg','jpeg','png','gif','webp'].contains(ext)) return '🖼️';
    if (['mp4','mov','avi','mkv','webm'].contains(ext))  return '🎬';
    if (['mp3','wav','aac','flac'].contains(ext))         return '🎵';
    if (['pdf'].contains(ext))                            return '📄';
    if (['zip','rar','7z','tar'].contains(ext))           return '🗜️';
    if (['doc','docx'].contains(ext))                     return '📝';
    if (['apk'].contains(ext))                            return '📦';
    return '📁';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Transfer History'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetch),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : history.isEmpty
              ? Center(child: Column(
                  mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.history, size: 64,
                    color: scheme.onSurface.withOpacity(0.15)),
                  const SizedBox(height: 12),
                  Text('No transfers yet',
                    style: TextStyle(
                      color: scheme.onSurface.withOpacity(0.3))),
                ]))
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: history.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final entry    = history[i];
                    final isSent   = entry['from'] == appState.myId;
                    final fromName = entry['fromName'] ?? 'Unknown';
                    final toName   = entry['toName']   ?? 'Unknown';
                    final files    =
                        List<dynamic>.from(entry['files'] ?? []);
                    final ts = entry['timestamp'] as int;

                    return Container(
                      decoration: BoxDecoration(
                        color: scheme.surface,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: scheme.onSurface.withOpacity(0.07))),
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: (isSent
                                    ? scheme.primary
                                    : Colors.green).withOpacity(0.12),
                                borderRadius: BorderRadius.circular(6)),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    isSent
                                      ? Icons.upload_rounded
                                      : Icons.download_rounded,
                                    size: 12,
                                    color: isSent
                                      ? scheme.primary : Colors.green),
                                  const SizedBox(width: 3),
                                  Text(isSent ? 'SENT' : 'RECEIVED',
                                    style: TextStyle(fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: isSent
                                        ? scheme.primary : Colors.green)),
                                ],
                              ),
                            ),
                            const Spacer(),
                            Text(_fmtTime(ts),
                              style: TextStyle(fontSize: 11,
                                color: scheme.onSurface.withOpacity(0.4))),
                          ]),
                          const SizedBox(height: 10),
                          Row(children: [
                            Icon(Icons.devices, size: 13,
                              color: scheme.onSurface.withOpacity(0.4)),
                            const SizedBox(width: 4),
                            Expanded(child: RichText(text: TextSpan(
                              style: TextStyle(fontSize: 13,
                                color: scheme.onSurface),
                              children: [
                                TextSpan(text: fromName,
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: isSent
                                      ? scheme.primary : scheme.onSurface)),
                                TextSpan(text: '  →  ',
                                  style: TextStyle(
                                    color: scheme.onSurface.withOpacity(0.3))),
                                TextSpan(text: toName,
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: !isSent
                                      ? Colors.green : scheme.onSurface)),
                              ],
                            ))),
                          ]),
                          const SizedBox(height: 10),
                          Divider(height: 1,
                            color: scheme.onSurface.withOpacity(0.07)),
                          const SizedBox(height: 10),
                          ...files.map((f) {
                            final name    = f['original'] ?? f['name'] ?? 'file';
                            final size    = f['size'] != null ? _fmtSize(f['size']) : '';
                            final savedTo = f['savedTo']?.toString() ?? '';
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Row(children: [
                                Text(_fileIcon(name),
                                  style: const TextStyle(fontSize: 18)),
                                const SizedBox(width: 8),
                                Expanded(child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(name,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 13)),
                                    if (savedTo.isNotEmpty)
                                      Text(savedTo,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(fontSize: 10,
                                          color: scheme.onSurface.withOpacity(0.4))),
                                  ],
                                )),
                                if (size.isNotEmpty)
                                  Text(size, style: TextStyle(
                                    fontSize: 11,
                                    color: scheme.onSurface.withOpacity(0.4))),
                                if (savedTo.isNotEmpty)
                                  IconButton(
                                    icon: Icon(Icons.open_in_new_rounded,
                                      size: 16,
                                      color: scheme.primary.withOpacity(0.7)),
                                    tooltip: 'Open file',
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                    onPressed: () async {
                                      final result = await OpenFilex.open(savedTo);
                                      if (result.type != ResultType.done && context.mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(content: Text(
                                            'Cannot open: \${result.message}')));
                                      }
                                    },
                                  ),
                              ]),
                            );
                          }),
                          if (files.length > 1)
                            Text('${files.length} files',
                              style: TextStyle(fontSize: 11,
                                color: scheme.onSurface.withOpacity(0.3))),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}