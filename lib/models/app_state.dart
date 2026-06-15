import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'transfer_item.dart';

// ── Discovered peer device ──────────────────────────
class XorbitDevice {
  final String id;
  final String name;
  final String ip;
  final int port;
  String? connectedTo; // deviceId this peer is connected to
  DateTime lastSeen;

  XorbitDevice({
    required this.id,
    required this.name,
    required this.ip,
    required this.port,
    this.connectedTo,
  }) : lastSeen = DateTime.now();

  String get baseUrl => 'http://$ip:$port';

  bool get isOnline =>
      DateTime.now().difference(lastSeen).inSeconds < 15;
}

// ── Theme notifier ───────────────────────────────────
class ThemeNotifier extends ChangeNotifier {
  ThemeMode _mode = ThemeMode.dark;
  ThemeMode get mode => _mode;
  bool get isDark => _mode == ThemeMode.dark;

  void toggle() {
    _mode = isDark ? ThemeMode.light : ThemeMode.dark;
    notifyListeners();
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _mode = (prefs.getBool('dark_mode') ?? true)
        ? ThemeMode.dark
        : ThemeMode.light;
    notifyListeners();
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('dark_mode', isDark);
  }
}

// ── Premium gate ─────────────────────────────────────
class PremiumGate {
  static bool _isPremium = false;
  static bool get isPremium => _isPremium;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _isPremium = prefs.getBool('is_premium') ?? false;
  }

  static Future<void> unlock() async {
    _isPremium = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_premium', true);
  }
}

// ── Global app state ─────────────────────────────────
class AppState extends ChangeNotifier {
  // My identity
  String myId   = '';
  String myName = '';
  int    myPort = 3000;

  // 1-to-1 connection
  String? connectedToId;
  String? connectedToName;
  String? connectedToIp;
  int?    connectedToPort;
  bool get isConnected => connectedToId != null;
  String? get peerBaseUrl => isConnected
      ? 'http://$connectedToIp:$connectedToPort'
      : null;

  // Room (premium)
  String? roomCode;
  String? roomName;
  String? roomCreatorId;
  List<Map<String, dynamic>> roomMembers = [];
  bool get inRoom => roomCode != null;
  bool get isRoomCreator => roomCreatorId == myId;

  // Discovered devices (from mDNS)
  Map<String, XorbitDevice> nearbyDevices = {};

  // All transfers (sent + received)
  List<TransferItem> transfers = [];

  // Pending connection requests
  // targetId → fromId
  Map<String, String> pendingRequests = {};

  // Pending files for this device
  List<Map<String, dynamic>> pendingFiles = [];

  // Set when remote device declines our connection request
  String? declinedByName;

  // Info about the device currently requesting to connect to us
  String? pendingFromIp;
  int?    pendingFromPort;
  String? pendingFromName;
  // Set when remote device accepts our connection request
  String? acceptedByName;

  // Files shared from other apps, waiting to be sent once connected
  List<String> pendingSharedPaths = [];

  // ── Init ─────────────────────────────────────────

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();

    // Load or create device ID
    String? id = prefs.getString('device_id');
    if (id == null) {
      id = const Uuid().v4();
      await prefs.setString('device_id', id);
    }
    myId = id;

    // Load device name
    myName = prefs.getString('device_name') ?? '';
  }

  Future<void> saveDeviceName(String name) async {
    myName = name;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('device_name', name);
    notifyListeners();
  }

  // ── Device discovery updates ──────────────────────

  void upsertDevice(XorbitDevice device) {
    nearbyDevices[device.id] = device;
    notifyListeners();
  }

  void removeDevice(String id) {
  nearbyDevices.remove(id);
  // Never auto-disconnect a peer that has active transfers
  if (connectedToId == id) {
    final hasActiveTransfer = transfers.any((t) =>
      t.direction == TransferDirection.sending &&
      (t.status == TransferStatus.transferring ||
       t.status == TransferStatus.waiting));
    if (!hasActiveTransfer) disconnect();
  }
  notifyListeners();
}

void pruneOfflineDevices() {
  final stale = nearbyDevices.entries
      .where((e) => !e.value.isOnline && e.key != connectedToId)
      .map((e) => e.key)
      .toList();
  for (final id in stale) removeDevice(id);
}

  // ── Connection state ──────────────────────────────

  void connect(XorbitDevice device) {
    connectedToId   = device.id;
    connectedToName = device.name;
    connectedToIp   = device.ip;
    connectedToPort = device.port;
    notifyListeners();
    // pendingSharedPaths handled by DevicePage._onStateChanged
  }

  void disconnect() {
    connectedToId   = null;
    connectedToName = null;
    connectedToIp   = null;
    connectedToPort = null;
    notifyListeners();
  }

  // ── Room state ────────────────────────────────────

  void joinedRoom({
    required String code,
    required String name,
    required String creatorId,
    required List<Map<String, dynamic>> members,
  }) {
    roomCode      = code;
    roomName      = name;
    roomCreatorId = creatorId;
    roomMembers   = members;
    notifyListeners();
  }

  void leftRoom() {
    roomCode      = null;
    roomName      = null;
    roomCreatorId = null;
    roomMembers   = [];
    notifyListeners();
  }

  void updateRoomMembers(List<Map<String, dynamic>> members) {
    roomMembers = members;
    notifyListeners();
  }

  // ── Transfers ─────────────────────────────────────

  void addTransfer(TransferItem item) {
    transfers.add(item);
    notifyListeners();
  }

  void updateTransfer(String transferId, {
    TransferStatus? status,
    double? progress,
    String? speed,
    String? eta,
    int? currentChunk,
  }) {
    final t = transfers.where((t) => t.transferId == transferId).firstOrNull;
    if (t == null) return;
    if (status       != null) t.status       = status;
    if (progress     != null) t.progress     = progress;
    if (speed        != null) t.speed        = speed;
    if (eta          != null) t.eta          = eta;
    if (currentChunk != null) t.currentChunk = currentChunk;
    notifyListeners();
  }
}