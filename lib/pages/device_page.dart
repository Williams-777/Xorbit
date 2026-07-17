import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dio/dio.dart';
import 'package:xorbit/models/app_state.dart';
import 'package:xorbit/widgets/reusable/orbital_background.dart';
import 'package:xorbit/widgets/reusable/orbital_loading_screen.dart';
import 'package:xorbit/widgets/reusable/my_device_card.dart';
import 'package:xorbit/widgets/reusable/device_card.dart';
import 'package:xorbit/widgets/reusable/main_drawer.dart';
import 'package:xorbit/pages/transfer_page.dart';
import 'package:xorbit/pages/group_page.dart';
import 'package:xorbit/pages/history_page.dart';
import 'package:xorbit/pages/settings_page.dart';
import 'package:xorbit/server/embedded_server.dart';
import 'package:xorbit/server/discovery.dart';

class DevicePage extends StatefulWidget {
  const DevicePage({super.key});

  @override
  State<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage> {
  void _goToTransferPage() {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => TransferPage(
          targetName: appState.connectedToName ?? 'Unknown',
        ),
      ),
      (route) => route.isFirst,
    );
  }

  late EmbeddedServer _server;
  late XorbitDiscovery _discovery;

  bool _starting = true;
  bool _editingName = false;
  late TextEditingController _nameCtrl;

  bool _connDialogShowing = false;
  bool _incomingSheetShowing = false;

  Timer? _uiRefreshTimer;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: appState.myName);
    appState.addListener(_onStateChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<String> _getLocalIp() async {
    if (_discovery.myIp != null && _discovery.myIp!.isNotEmpty) {
      return _discovery.myIp!;
    }
    try {
      for (final iface in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      )) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (ip.startsWith('192.168.') ||
              ip.startsWith('10.') ||
              ip.startsWith('172.')) {
            return ip;
          }
        }
      }
    } catch (_) {}
    return '127.0.0.1';
  }

  @override
  void dispose() {
    _uiRefreshTimer?.cancel();
    appState.removeListener(_onStateChanged);
    _nameCtrl.dispose();
    _server.stop();
    _discovery.stop();
    super.dispose();
  }

  void _onStateChanged() {
    if (!mounted) return;
    setState(() {});

    if (appState.peerWentOffline) {
      appState.peerWentOffline = false;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.red,
          content: Text('Connection lost — other device went offline'),
          duration: Duration(seconds: 4),
        ),
      );
    }

    if (appState.isConnected && appState.pendingSharedPaths.isNotEmpty) {
      final paths = List<String>.from(appState.pendingSharedPaths);
      appState.pendingSharedPaths.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _sendSharedFiles(paths);
      });
    }

    if (appState.pendingRequests.containsKey(appState.myId) &&
        !_connDialogShowing) {
      final fromId = appState.pendingRequests[appState.myId]!;
      final fromName = appState.pendingFromName ??
          appState.nearbyDevices[fromId]?.name ??
          'Unknown';
      final fromIp = appState.pendingFromIp ??
          appState.nearbyDevices[fromId]?.ip ??
          '';
      final fromPort = appState.pendingFromPort ??
          appState.nearbyDevices[fromId]?.port ??
          kServerPort;

      appState.pendingRequests.remove(appState.myId);

      _showConnectionRequest(
        fromId: fromId,
        fromName: fromName,
        fromIp: fromIp,
        fromPort: fromPort,
      );
    }

    if (appState.acceptedByName != null) {
      final name = appState.acceptedByName!;
      appState.acceptedByName = null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.green.shade700,
          content: Row(
            children: [
              const Icon(Icons.check_circle, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text('$name accepted your request!')),
            ],
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    }

    if (appState.declinedByName != null) {
      final name = appState.declinedByName!;
      appState.declinedByName = null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.red.shade700,
          content: Row(
            children: [
              const Icon(Icons.cancel, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text('$name declined your connection request')),
            ],
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    }

    if (appState.pendingFiles.isNotEmpty) {
      final files = List<Map<String, dynamic>>.from(appState.pendingFiles);
      appState.pendingFiles.clear();

      final clipItems = files.where((f) => f.containsKey('__clipboard__'));
      final fileItems = files.where((f) => !f.containsKey('__clipboard__'));

      for (final clip in clipItems) {
        Clipboard.setData(ClipboardData(text: clip['__clipboard__']));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('📋 Clipboard synced!')),
          );
        }
      }

      if (fileItems.isNotEmpty && !_incomingSheetShowing) {
        _showIncomingSheet(fileItems.toList());
      }
    }
  }

  Future<void> _init() async {
    _handleSharedIntent();

    if (appState.myName.isEmpty) {
      final name = await _promptDeviceName();
      if (name != null && name.isNotEmpty) {
        await appState.saveDeviceName(name);
        _nameCtrl.text = name;
      }
    }

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

    _discovery = XorbitDiscovery(appState);
    try {
      await _discovery.start().timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('mDNS start failed: $e — will retry in background');
      Future.delayed(const Duration(seconds: 5), () {
        if (mounted) _discovery.start();
      });
    }

    if (mounted) setState(() => _starting = false);

    await _checkSharedContent();

    _uiRefreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _checkSharedContent() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;

    try {
      const channel = MethodChannel('com.williams.xorbit/share');
      final shared = await channel.invokeMethod<Map>('getSharedContent');
      if (shared == null) return;

      final text = shared['text'] as String?;
      final files = shared['files'] as List?;

      if (text != null && text.isNotEmpty && appState.isConnected) {
        await Dio().post(
          '${appState.peerBaseUrl}/clipboard',
          data: {'text': text},
        );

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('📋 Shared text sent to connected device'),
            ),
          );
        }
      }

      if (files != null && files.isNotEmpty) {
        if (mounted && appState.isConnected) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => TransferPage(
                targetName: appState.connectedToName ?? 'Unknown',
                sharedPaths: List<String>.from(files),
              ),
            ),
          );
        }
      }
    } catch (_) {}
  }

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

  void _handleSharedIntent() async {
    try {
      const channel = MethodChannel('com.williams.xorbit/share');
      final data = await channel.invokeMethod<Map>('getSharedData');
      if (data == null) return;

      if (data['type'] == 'text') {
        final text = data['text'] as String? ?? '';
        if (text.isNotEmpty && mounted) {
          await Clipboard.setData(ClipboardData(text: text));
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Shared text ready to sync'),
              action: SnackBarAction(
                label: 'Sync now',
                onPressed: _syncClipboard,
              ),
            ),
          );
        }
      } else if (data['type'] == 'files') {
        final paths = List<String>.from(data['paths'] ?? []);
        if (paths.isNotEmpty) {
          if (!appState.isConnected) {
            appState.pendingSharedPaths = paths;
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Files ready — connect to a device to send them',
                  ),
                  duration: Duration(seconds: 5),
                ),
              );
            }
          } else {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _sendSharedFiles(paths);
            });
          }
        }
      }
    } catch (e) {
      debugPrint('Share handler: $e');
    }
  }

  void _sendSharedFiles(List<String> paths) {
    if (!appState.isConnected) return;
    _goToTransferPage();
  }

  Future<void> _sendConnectRequest(XorbitDevice target) async {
    try {
      final dio = Dio();
      await dio.post(
        '${target.baseUrl}/connect-request',
        data: {
          'fromId': appState.myId,
          'fromName': appState.myName,
          'fromIp': await _getLocalIp(),
          'fromPort': appState.myPort,
        },
        options: Options(
          sendTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 5),
        ),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Request sent to ${target.name}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not reach ${target.name}')),
        );
      }
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
                await dio.post(
                  'http://$fromIp:$fromPort/notify-declined',
                  data: {'byName': appState.myName},
                );
              } catch (_) {}
            },
            child: const Text('Decline', style: TextStyle(color: Colors.red)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              _connDialogShowing = false;
              await _acceptConnection(
                fromId: fromId,
                fromName: fromName,
                fromIp: fromIp,
                fromPort: fromPort,
              );
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
    try {
      final dio = Dio();
      await dio.post(
        'http://$fromIp:$fromPort/accept',
        data: {
          'peerId': appState.myId,
          'peerName': appState.myName,
          'peerIp': await _getLocalIp(),
          'peerPort': appState.myPort,
        },
      );

      final device = XorbitDevice(
        id: fromId,
        name: fromName,
        ip: fromIp,
        port: fromPort,
      );
      appState.connect(device);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('✅ Connected to $fromName')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Connection failed — try again')),
        );
      }
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
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      final dio = Dio();
      await dio.post('${appState.peerBaseUrl}/disconnect');
    } catch (_) {}

    appState.disconnect();
  }

  Future<void> _syncClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text == null || data!.text!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Clipboard is empty')),
      );
      return;
    }
    try {
      final dio = Dio();
      await dio.post(
        '${appState.peerBaseUrl}/clipboard',
        data: {'text': data.text},
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('📋 Clipboard synced!')),
        );
      }
    } catch (_) {}
  }

  void _showIncomingSheet(List<Map<String, dynamic>> files) {
    if (_incomingSheetShowing) return;
    _incomingSheetShowing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _goToTransferPage();
      _incomingSheetShowing = false;
    });
  }

  void _showAbout(BuildContext context, ColorScheme scheme) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.wifi_tethering_rounded,
                color: Colors.white,
                size: 18,
              ),
            ),
            const SizedBox(width: 10),
            const Text('Xorbit'),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Version 1.0.0'),
            SizedBox(height: 8),
            Text(
              'Fast, local, ad-free file transfer.\n\n'
              '✓ No internet required\n'
              '✓ No accounts or sign-ups\n'
              '✓ No tracking or ads\n'
              '✓ Works on WiFi or hotspot\n'
              '✓ Your files never leave your network',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
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
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  void _showPremiumGate(BuildContext context) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.star_rounded, size: 48, color: Colors.amber),
            const SizedBox(height: 12),
            const Text(
              'Xorbit Pro',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Connect up to 20 devices in a group.\nBroadcast files to everyone at once.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () async {
                await PremiumGate.unlock();
                if (context.mounted) {
                  Navigator.pop(context);
                  setState(() {});
                }
              },
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
                backgroundColor: Colors.amber.shade700,
              ),
              child: const Text(
                'Unlock Pro — \$4.99',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Maybe later'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = themeNotifier.isDark;
    final isConnected = appState.isConnected;

    final nearbyList = appState.nearbyDevices.values
        .where((d) => d.id != appState.myId)
        .toList();

    return Scaffold(
      drawer: MainDrawer(
        isPremium: PremiumGate.isPremium,
        onHistoryTap: () {
          Navigator.pop(context);
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const HistoryPage()),
          );
        },
        onSettingsTap: () {
          Navigator.pop(context);
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => SettingsPage(
                onNameChanged: (n) => setState(() {
                  _nameCtrl.text = n;
                }),
              ),
            ),
          );
        },
        onAboutTap: () {
          Navigator.pop(context);
          _showAbout(context, scheme);
        },
        onHelpTap: () {
          Navigator.pop(context);
          _showHelp(context);
        },
        onUpgradeTap: () {
          Navigator.pop(context);
          _showPremiumGate(context);
        },
      ),
      appBar: AppBar(
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: const Icon(Icons.menu_rounded),
            onPressed: () => Scaffold.of(ctx).openDrawer(),
          ),
        ),
        title: const Text('Xorbit'),
        actions: [
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
            icon: Icon(isDark ? Icons.wb_sunny_rounded : Icons.nightlight_round),
            onPressed: () {
              themeNotifier.toggle();
              themeNotifier.save();
            },
          ),
        ],
      ),
      body: _starting
          ? const OrbitalLoadingScreen()
          : Stack(
              children: [
                const Positioned.fill(child: OrbitalBackground()),
                Positioned.fill(
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                        child: MyDeviceCard(
                          editingName: _editingName,
                          nameCtrl: _nameCtrl,
                          myName: appState.myName,
                          onSave: _saveDeviceName,
                          onEditToggle: () => setState(() => _editingName = true),
                        ),
                      ),
                      if (_discovery.myIp != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                          child: Row(
                            children: [
                              Icon(
                                Icons.wifi,
                                size: 13,
                                color: scheme.onSurface.withOpacity(0.4),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '${_discovery.myIp}:$kServerPort',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: scheme.onSurface.withOpacity(0.4),
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (isConnected) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                          child: Row(
                            children: [
                              const Icon(Icons.circle, color: Colors.green, size: 8),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  'Connected to ${appState.connectedToName}',
                                  style: const TextStyle(
                                    color: Colors.green,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                              TextButton.icon(
                                onPressed: _disconnect,
                                icon: const Icon(Icons.link_off, size: 14, color: Colors.red),
                                label: const Text(
                                  'Disconnect',
                                  style: TextStyle(color: Colors.red, fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                          child: SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              icon: const Icon(Icons.send_rounded, size: 22),
                              label: const Text(
                                'Send',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 20),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(18),
                                ),
                              ),
                              onPressed: _goToTransferPage,
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                          child: SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              icon: Icon(Icons.swap_horiz_rounded, color: scheme.primary),
                              label: Text(
                                'View Transfers',
                                style: TextStyle(color: scheme.primary),
                              ),
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size.fromHeight(44),
                                side: BorderSide(
                                  color: scheme.primary.withOpacity(0.4),
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              onPressed: _goToTransferPage,
                            ),
                          ),
                        ),
                      ],
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
                        child: Row(
                          children: [
                            Text(
                              'Nearby Devices',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: scheme.onSurface.withOpacity(0.6),
                              ),
                            ),
                            const SizedBox(width: 8),
                            if (nearbyList.isEmpty)
                              SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.5,
                                  color: scheme.onSurface.withOpacity(0.3),
                                ),
                              ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: nearbyList.isEmpty
                            ? Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.wifi_find_rounded,
                                      size: 56,
                                      color: scheme.onSurface.withOpacity(0.15),
                                    ),
                                    const SizedBox(height: 10),
                                    Text(
                                      'Looking for devices...',
                                      style: TextStyle(
                                        color: scheme.onSurface.withOpacity(0.3),
                                        fontSize: 13,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      'Make sure both devices are on the same WiFi or hotspot',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: scheme.onSurface.withOpacity(0.2),
                                        fontSize: 11,
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            : ListView.builder(
                                padding: const EdgeInsets.symmetric(horizontal: 16),
                                itemCount: nearbyList.length,
                                itemBuilder: (_, i) => DeviceCard(
                                  device: nearbyList[i],
                                  connectedToUs: appState.connectedToId == nearbyList[i].id,
                                  onConnectPressed: () => _sendConnectRequest(nearbyList[i]),
                                ),
                              ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
                        child: OutlinedButton.icon(
                          icon: Icon(
                            Icons.group_rounded,
                            color: PremiumGate.isPremium ? scheme.primary : Colors.grey,
                            size: 20,
                          ),
                          label: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'Group Connect',
                                style: TextStyle(
                                  color: PremiumGate.isPremium ? scheme.primary : Colors.grey,
                                ),
                              ),
                              if (!PremiumGate.isPremium) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.amber.shade700,
                                    borderRadius: BorderRadius.circular(5),
                                  ),
                                  child: const Text(
                                    'PRO',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 9,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(46),
                            side: BorderSide(
                              color: PremiumGate.isPremium
                                  ? scheme.primary.withOpacity(0.4)
                                  : Colors.grey.withOpacity(0.25),
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          onPressed: () {
                            if (!PremiumGate.isPremium) {
                              _showPremiumGate(context);
                              return;
                            }
                            Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => const GroupPage()),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}