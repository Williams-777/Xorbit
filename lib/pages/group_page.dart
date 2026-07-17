import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:xorbit/models/app_state.dart';
import 'package:xorbit/pages/transfer_page.dart';

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
              ? _nameCtrl.text
              : "${appState.myName}'s Room",
        },
      );
      final room = res.data['room'];
      appState.joinedRoom(
        code: res.data['code'],
        name: room['name'],
        creatorId: room['creatorId'],
        members: [
          {'id': appState.myId, 'name': appState.myName}
        ],
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e')),
        );
      }
    }
    setState(() => _loading = false);
  }

  Future<void> _joinRoom() async {
    final code = _codeCtrl.text.trim().toUpperCase();
    if (code.length != 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter 6-character code')),
      );
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
            sendTimeout: const Duration(seconds: 3),
            receiveTimeout: const Duration(seconds: 3),
          ),
        );
        final room = res.data['room'];
        final members = List<Map<String, dynamic>>.from(
          (room['members'] as List).map(
            (m) => Map<String, dynamic>.from(m),
          ),
        );
        appState.joinedRoom(
          code: code,
          name: room['name'],
          creatorId: room['creatorId'],
          members: members,
        );
        joined = true;
        break;
      } catch (_) {
        continue;
      }
    }
    if (!joined && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Room not found — check the code')),
      );
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
      await dio.post(
        'http://127.0.0.1:$kServerPort/room/kick',
        data: {'targetId': targetId},
      );
      final updated =
          appState.roomMembers.where((m) => m['id'] != targetId).toList();
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
          title: Text(
            appState.inRoom
                ? (appState.roomName ?? 'Group')
                : 'Group Connect',
          ),
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
          const Text(
            'Create a Room',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
              hintText: 'Room name (optional)',
              prefixIcon: Icon(Icons.group),
            ),
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: _createRoom,
            icon: const Icon(Icons.add_rounded),
            label: const Text('Create Room'),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
            ),
          ),
          const SizedBox(height: 32),
          const Text(
            'Join a Room',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _codeCtrl,
            maxLength: 6,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              hintText: 'Enter 6-character code',
              prefixIcon: Icon(Icons.vpn_key_rounded),
              counterText: '',
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _joinRoom,
            icon: const Icon(Icons.login_rounded),
            label: const Text('Join Room'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
            ),
          ),
        ],
      ),
    );
  }

  Widget _roomView(ColorScheme scheme) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: scheme.primary.withOpacity(0.1),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: scheme.primary.withOpacity(0.3)),
            ),
            child: Column(
              children: [
                Text(
                  appState.roomName ?? 'Group',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                const Text('Room Code',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
                const SizedBox(height: 4),
                Text(
                  appState.roomCode ?? '',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: scheme.primary,
                    letterSpacing: 6,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Share this code with others to join',
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurface.withOpacity(0.4),
                  ),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Text(
                'Members (${appState.roomMembers.length}/20)',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: appState.roomMembers.length,
            itemBuilder: (_, i) {
              final m = appState.roomMembers[i];
              final isMe = m['id'] == appState.myId;
              final isCreator = m['id'] == appState.roomCreatorId;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Container(
                  decoration: BoxDecoration(
                    color: scheme.surface,
                    borderRadius: BorderRadius.circular(12),
                    border:
                        Border.all(color: scheme.onSurface.withOpacity(0.07)),
                  ),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: scheme.primary.withOpacity(0.15),
                      child: Text(
                        (m['name'] as String).substring(0, 1).toUpperCase(),
                        style: TextStyle(
                          color: scheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    title: Text(m['name'] ?? 'Unknown'),
                    subtitle: isCreator
                        ? const Text('Creator', style: TextStyle(fontSize: 11))
                        : isMe
                            ? const Text('You', style: TextStyle(fontSize: 11))
                            : null,
                    trailing: appState.isRoomCreator && !isMe
                        ? IconButton(
                            icon: const Icon(
                              Icons.remove_circle_outline,
                              color: Colors.red,
                              size: 20,
                            ),
                            onPressed: () => _kickMember(m['id']),
                          )
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
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => TransferPage(
                  targetName: appState.roomName ?? 'Group',
                ),
              ),
            ),
            icon: const Icon(Icons.send_rounded),
            label: const Text('Send to Room'),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          child: OutlinedButton.icon(
            onPressed: _leaveRoom,
            icon: const Icon(Icons.exit_to_app, color: Colors.red),
            label: const Text(
              'Leave Room',
              style: TextStyle(color: Colors.red),
            ),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
              side: const BorderSide(color: Colors.red),
            ),
          ),
        ),
      ],
    );
  }
}
