// App wiring: services, sign-in, the tab shell and the mini player.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'data/api.dart';
import 'data/artwork.dart';
import 'data/db.dart';
import 'data/downloads.dart';
import 'data/library.dart';
import 'data/sync.dart';
import 'player/player.dart';
import 'ui/library_screens.dart';
import 'ui/parts.dart';
import 'ui/player_screen.dart';
import 'ui/podcast_screens.dart';
import 'ui/status_screens.dart';
import 'ui/theme.dart';
import 'ui/widgets.dart';

/// Everything a signed-in session needs; built once after sign-in.
class Services {
  Services({required this.db, required this.api, required this.lib, required this.sync, required this.downloads, required this.player, required this.art});
  final LocalDb db;
  final Api api;
  final Library lib;
  final SyncService sync;
  final Downloads downloads;
  final PlayerController player;
  final ArtCache art;

  /// Runs a server call, then syncs so the local copy shows its effect.
  Future<bool> act(BuildContext context, Future<Object?> Function(Api api) call, {String? done}) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await call(api);
      if (done != null) messenger.showSnackBar(SnackBar(content: Text(done)));
      await sync.syncNow();
      return true;
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
      return false;
    }
  }
}

class Scope extends InheritedWidget {
  const Scope({super.key, required this.services, required super.child});
  final Services services;
  static Services of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<Scope>()!.services;
  @override
  bool updateShouldNotify(Scope old) => old.services != services;
}

const _secure = FlutterSecureStorage();

/// The phone's own name, or the computer's host name.
Future<String> _deviceName() async {
  if (Platform.isAndroid || Platform.isIOS) {
    try {
      final n = await const MethodChannel('rpodcasts/device').invokeMethod<String>('name');
      if (n != null && n.trim().isNotEmpty) return n.trim();
    } catch (_) {}
    return Platform.isIOS ? 'iPhone' : 'Android';
  }
  final h = Platform.localHostname.replaceAll(RegExp(r'\.local$'), '');
  return h.isEmpty ? Platform.operatingSystem : h;
}

// The keyring when there is one; the local DB on desktops without a Secret Service.
Future<String?> _readToken(LocalDb db) async {
  try {
    return await _secure.read(key: 'token') ?? await db.get('token');
  } on PlatformException {
    return db.get('token');
  }
}

Future<void> _writeToken(LocalDb db, String token) async {
  try {
    await _secure.write(key: 'token', value: token);
  } on PlatformException {
    await db.put('token', token);
  }
}

Future<void> _deleteToken() async {
  try {
    await _secure.delete(key: 'token');
  } on PlatformException {
    return;
  }
}

/// The artwork worth holding before it is looked at: every podcast, and what is next in the playlists and the downloads.
Iterable<String> _offlineArt(Library lib) sync* {
  for (final c in lib.channels.values) {
    yield c.artwork;
  }
  final lists = [for (final p in lib.playlists) lib.playlistEpisodes(p).$1];
  for (final list in lists) {
    yield* list.where((e) => !lib.play(e.id).played).take(30).map((e) => e.artwork);
  }
  yield* lib.downloaded.keys.map((id) => lib.byId[id]?.artwork ?? '');
}

class PodcastsApp extends StatefulWidget {
  const PodcastsApp({super.key, required this.db});
  final LocalDb db;
  @override
  State<PodcastsApp> createState() => _PodcastsAppState();
}

class _PodcastsAppState extends State<PodcastsApp> {
  Services? services;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    try {
      final base = await widget.db.get('server');
      final token = base == null ? null : await _readToken(widget.db);
      if (base != null && token != null) await _open(base, token);
    } on Object catch (e) {
      debugPrint('restore failed: $e');
    } finally {
      setState(() => loading = false);
    }
  }

  Future<void> _open(String base, String token) async {
    final api = Api(base: base, token: token);
    final lib = Library(widget.db);
    await lib.load();
    final player = PlayerController(lib: lib, api: api);
    await attachSystemControls(player);
    final downloads = Downloads(api: api, db: widget.db, lib: lib);
    final sync = SyncService(api: api, db: widget.db, lib: lib, onSignedOut: _signOut);
    final art = await ArtCache.open(widget.db);
    sync.afterSync = () async {
      await downloads.reconcile();
      await art.keep(_offlineArt(lib));
    };
    setState(() => services = Services(db: widget.db, api: api, lib: lib, sync: sync, downloads: downloads, player: player, art: art));
    await sync.start();
    unawaited(downloads.start().then((_) => downloads.reconcile()));
  }

  Future<void> _signIn(String base, String password) async {
    final (token, _) = await Api.signIn(base, password, await _deviceName());
    await widget.db.wipe();
    await _writeToken(widget.db, token);
    await widget.db.put('server', base);
    await _open(base, token);
  }

  Future<void> _signOut() async {
    final s = services;
    if (s == null) return;
    await s.player.close();
    s.sync.dispose();
    await s.art.clear();
    await _deleteToken();
    await widget.db.wipe();
    setState(() => services = null);
  }

  @override
  Widget build(BuildContext context) {
    final s = services;
    return ListenableBuilder(
      listenable: s?.lib ?? ValueNotifier(0),
      builder: (context, _) {
        final theme = s?.lib.prefs.theme ?? 'system';
        return MaterialApp(
          title: 'Podcasts',
          debugShowCheckedModeBanner: false,
          themeMode: theme == 'dark' ? ThemeMode.dark : (theme == 'light' ? ThemeMode.light : ThemeMode.system),
          theme: lightTheme,
          darkTheme: darkTheme,
          home: loading
              ? const Scaffold(body: Center(child: CircularProgressIndicator()))
              : s == null
              ? SignInScreen(onSignIn: _signIn)
              : Scope(
                  services: s,
                  child: Shell(onSignOut: _signOut),
                ),
        );
      },
    );
  }
}

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, required this.onSignIn});
  final Future<void> Function(String base, String password) onSignIn;
  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final server = TextEditingController();
  final password = TextEditingController();
  String error = '';
  bool busy = false;

  Future<void> _submit() async {
    var base = server.text.trim();
    if (base.isEmpty) return setState(() => error = 'Enter the server address');
    if (!base.startsWith('http')) base = 'https://$base';
    base = base.replaceAll(RegExp(r'/+$'), '');
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await widget.onSignIn(base, password.text);
    } on Object catch (e) {
      setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(24),
            children: [
              Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  child: Image.asset('assets/logo/logo-1024.png', width: 96, height: 96, cacheWidth: 288),
                ),
              ),
              const SizedBox(height: 20),
              Text('rPodcasts', style: text.headlineMedium, textAlign: TextAlign.center),
              const SizedBox(height: 6),
              Text(
                'Sign in to your podcast server.',
                style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 28),
              TextField(
                controller: server,
                decoration: const InputDecoration(labelText: 'Server address', hintText: 'https://podcasts.example.com', prefixIcon: Icon(Icons.dns_outlined)),
                keyboardType: TextInputType.url,
                autocorrect: false,
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: password,
                decoration: const InputDecoration(labelText: 'Password', prefixIcon: Icon(Icons.lock_outline_rounded)),
                obscureText: true,
                onSubmitted: (_) => _submit(),
              ),
              if (error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Notice(icon: Icons.error_outline_rounded, text: error, error: true),
                ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: busy ? null : _submit,
                child: busy ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Sign in'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class Shell extends StatefulWidget {
  const Shell({super.key, required this.onSignOut});
  final Future<void> Function() onSignOut;
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int tab = 0;
  final keys = List.generate(5, (_) => GlobalKey<NavigatorState>());
  PlayerController? _player;
  int _asked = 0;
  bool _playerOpen = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final p = Scope.of(context).player;
    if (p == _player) return;
    _player?.removeListener(_onPlayer);
    _player = p..addListener(_onPlayer);
    _asked = p.asked;
  }

  @override
  void dispose() {
    _player?.removeListener(_onPlayer);
    super.dispose();
  }

  // A video started from a list goes straight to the player; audio stays in the mini player.
  void _onPlayer() {
    final p = _player!;
    if (p.asked == _asked) return;
    _asked = p.asked;
    if (p.episode?.media == 'video') _openPlayer();
  }

  Future<void> _openPlayer() async {
    if (_playerOpen) return;
    _playerOpen = true;
    await openEpisode(context, id: null, from: '');
    _playerOpen = false;
  }

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    final roots = <Widget>[
      const PlaylistsScreen(),
      const PodcastsScreen(),
      const EpisodesScreen(),
      const StatusScreen(),
      SettingsScreen(onSignOut: widget.onSignOut),
    ];
    final stack = IndexedStack(
      index: tab,
      children: [
        for (var i = 0; i < roots.length; i++)
          Navigator(
            key: keys[i],
            onGenerateRoute: (_) => MaterialPageRoute(builder: (_) => roots[i]),
          ),
      ],
    );
    void select(int i) {
      if (i == tab) keys[i].currentState?.popUntil((r) => r.isFirst);
      setState(() => tab = i);
    }

    final destinations = [
      (Icons.queue_music_outlined, Icons.queue_music_rounded, 'Playlists'),
      (Icons.grid_view_outlined, Icons.grid_view_rounded, 'Podcasts'),
      (Icons.search_rounded, Icons.manage_search_rounded, 'Episodes'),
      (Icons.monitor_heart_outlined, Icons.monitor_heart_rounded, 'Status'),
      (Icons.settings_outlined, Icons.settings_rounded, 'Settings'),
    ];
    final wide = MediaQuery.sizeOf(context).width > 840;
    final body = Column(
      children: [
        Expanded(child: stack),
        MiniPlayer(onOpen: _openPlayer),
      ],
    );
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) keys[tab].currentState?.maybePop();
      },
      child: Scaffold(
        body: wide
            ? Row(
                children: [
                  NavigationRail(
                    selectedIndex: tab,
                    onDestinationSelected: select,
                    labelType: NavigationRailLabelType.all,
                    destinations: [
                      for (final (i, d) in destinations.indexed)
                        NavigationRailDestination(
                          icon: i == 3 ? StatusBadge(child: Icon(d.$1)) : Icon(d.$1),
                          selectedIcon: i == 3 ? StatusBadge(child: Icon(d.$2)) : Icon(d.$2),
                          label: Text(d.$3),
                        ),
                    ],
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(child: body),
                ],
              )
            : body,
        bottomNavigationBar: wide
            ? null
            : ListenableBuilder(
                listenable: s.sync,
                builder: (context, _) => NavigationBar(
                  selectedIndex: tab,
                  onDestinationSelected: select,
                  destinations: [
                    for (final (i, d) in destinations.indexed)
                      NavigationDestination(
                        icon: i == 3 ? StatusBadge(child: Icon(d.$1)) : Icon(d.$1),
                        selectedIcon: i == 3 ? StatusBadge(child: Icon(d.$2)) : Icon(d.$2),
                        label: d.$3,
                      ),
                  ],
                ),
              ),
      ),
    );
  }
}
