// Status (the server's background work and this device's sync and downloads) and Settings.
library;

import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../app.dart';
import '../data/api.dart';
import '../data/models.dart';
import 'parts.dart';
import 'theme.dart';
import 'widgets.dart';

class StatusScreen extends StatefulWidget {
  const StatusScreen({super.key});
  @override
  State<StatusScreen> createState() => _StatusScreenState();
}

class _StatusScreenState extends State<StatusScreen> {
  Map<String, dynamic>? server;
  String error = '';
  Timer? timer;
  bool failuresOnly = false;
  bool onServer = false;
  List<Map<String, Object?>> events = [];
  final Set<String> expanded = {};
  bool _asking = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (timer == null) {
      _load();
      timer = Timer.periodic(const Duration(seconds: 2), (_) => _load());
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  // An offline request can take seconds to fail, so polls never pile up.
  Future<void> _load() async {
    if (_asking) return;
    _asking = true;
    final s = Scope.of(context);
    try {
      final ev = await s.db.events();
      try {
        final st = (await s.api.get('/status') as Map).cast<String, dynamic>();
        if (mounted) {
          setState(() {
            server = st;
            error = '';
            events = ev;
          });
        }
      } on Unreachable {
        if (mounted) setState(() => events = ev);
      } on Object catch (e) {
        if (mounted) {
          setState(() {
            error = '$e';
            events = ev;
          });
        }
      }
    } finally {
      _asking = false;
    }
  }

  /// One piece of work: what it is, how it is going, and the one thing that can be done to it.
  Widget _row({required Widget leading, required String title, required String detail, String problem = '', Widget? below, Widget? action}) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        children: [
          SizedBox(width: 24, height: 24, child: Center(child: leading)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                if (detail.isNotEmpty) Text(detail, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.bodySmall),
                if (problem.isNotEmpty)
                  Text(
                    problem,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(color: cs.error),
                  ),
                if (below != null) Padding(padding: const EdgeInsets.only(top: 6), child: below),
              ],
            ),
          ),
          if (action != null) action else const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _quiet(String text) => Padding(
    padding: const EdgeInsets.all(16),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(text, style: Theme.of(context).textTheme.bodySmall),
    ),
  );

  /// A list that grows: the first few rows, and a row that shows or hides the rest.
  List<Widget> _few<T>(String list, List<T> items, Widget Function(T) row) {
    const few = 4;
    final open = expanded.contains(list);
    return [
      for (final item in open ? items : items.take(few)) row(item),
      if (items.length > few)
        ListTile(
          dense: true,
          title: Text(
            open ? 'Show fewer' : 'Show more',
            style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600),
          ),
          trailing: Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded),
          onTap: () => setState(() => open ? expanded.remove(list) : expanded.add(list)),
        ),
    ];
  }

  Widget _storage({required String held, required String against, required String note, double? full}) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(held, style: text.titleLarge),
              const SizedBox(width: 6),
              Expanded(child: Text(against, style: text.bodySmall)),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(note, style: text.bodySmall),
          ),
          if (full != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: LinearProgressIndicator(value: full.clamp(0, 1), minHeight: 6, borderRadius: BorderRadius.circular(3)),
            ),
        ],
      ),
    );
  }

  static const _spinner = SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.5));

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    final st = server;
    final busy = st == null ? 0 : (st['running'] as List).length + (st['queued'] as List).length + (st['streams'] as List).length;
    return Scaffold(
      appBar: rootBar(context, 'Status'),
      body: ListenableBuilder(
        listenable: Listenable.merge([s.sync, s.downloads]),
        builder: (context, _) => Readable(
          builder: (context, inset) => ListView(
            padding: EdgeInsets.fromLTRB(16 + inset, 4, 16 + inset, 32),
            children: [
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(
                    value: false,
                    icon: const Icon(Icons.smartphone_rounded),
                    label: Text(s.downloads.active.isEmpty ? 'This device' : 'This device · ${s.downloads.active.length}'),
                  ),
                  ButtonSegment(value: true, icon: const Icon(Icons.dns_outlined), label: Text(busy == 0 ? 'Server' : 'Server · $busy')),
                ],
                selected: {onServer},
                onSelectionChanged: (v) => setState(() => onServer = v.first),
              ),
              const SizedBox(height: 20),
              if (!onServer) ..._device(s),
              if (onServer && (s.sync.offline || error.isNotEmpty))
                Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: Notice(
                    icon: Icons.cloud_off_rounded,
                    text: s.sync.offline ? "Can't reach the server${st == null ? '' : ', so this is how it was when it last answered'}." : error,
                    error: true,
                  ),
                ),
              if (onServer && st != null) ..._server(st, s),
              if (onServer && st == null && error.isEmpty && !s.sync.offline)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _device(Services s) {
    final cs = Theme.of(context).colorScheme;
    final d = s.downloads;
    final limit = s.lib.device.storageMb * 1048576;
    String title(int id) => s.lib.byId[id]?.title ?? 'Episode $id';
    return [
      Section(
        title: 'Sync',
        children: [
          _row(
            leading: s.sync.running
                ? _spinner
                : Icon(s.sync.lastError.isEmpty ? Icons.cloud_done_outlined : Icons.cloud_off_rounded, color: s.sync.lastError.isEmpty ? cs.primary : cs.error),
            title: s.sync.running && s.sync.offline
                ? '${s.sync.noNetwork ? 'Offline' : 'Server unreachable'} · trying to reach the server…'
                : s.sync.running
                ? 'Syncing…'
                : s.sync.offline
                ? '${s.sync.noNetwork ? 'Offline' : 'Server unreachable'} · synced ${ago(s.sync.lastSync)}'
                : 'Synced ${ago(s.sync.lastSync)}',
            detail: s.sync.pending == 0 ? 'Everything is sent' : '${s.sync.pending} change${s.sync.pending == 1 ? '' : 's'} waiting to be sent',
            problem: s.sync.noNetwork
                ? 'This device has no internet, so only downloaded episodes play. It syncs by itself as soon as the server answers.'
                : s.sync.offline
                ? "Can't reach the server, but this device is online: podcasts still stream from their own sites, while videos need the server. It syncs by itself as soon as the server answers."
                : s.sync.lastError.isEmpty
                ? ''
                : 'Last error: ${s.sync.lastError}',
            action: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton.tonal(onPressed: s.sync.running ? null : s.sync.syncNow, child: const Text('Sync now')),
            ),
          ),
        ],
      ),
      if (s.lib.device.downloadsPaused || d.active.isNotEmpty || d.waiting.isNotEmpty || d.skipped.isNotEmpty || d.failed.isNotEmpty)
        Section(
          title: 'Downloads',
          children: [
            if (s.lib.device.downloadsPaused)
              _row(
                leading: Icon(Icons.pause_circle_outline_rounded, color: cs.primary),
                title: 'Downloads paused',
                detail: 'Nothing downloads by itself until you resume. Download on an episode still does.',
                action: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilledButton.tonal(onPressed: () => d.setPaused(false), child: const Text('Resume')),
                ),
              ),
            for (final a in d.active.values)
              _row(
                leading: Icon(Icons.downloading_rounded, color: cs.primary),
                title: title(a.episode),
                detail: [
                  if (a.progress > 0) '${(a.progress * 100).round()}%',
                  if (a.expectedBytes > 0) '${megabytes(a.progress * a.expectedBytes)} of ${megabytes(a.expectedBytes)}',
                  if (a.progress == 0 && a.waiting.isEmpty) 'starting',
                  if (a.speedMBps > 0) '${a.speedMBps.toStringAsFixed(1)} MB/s',
                  if (a.waiting.isNotEmpty) a.waiting,
                ].join(' · '),
                below: LinearProgressIndicator(value: a.progress > 0 ? a.progress : null, minHeight: 4, borderRadius: BorderRadius.circular(2)),
                action: IconButton(icon: const Icon(Icons.close_rounded), tooltip: 'Cancel', onPressed: () => d.cancel(a.episode)),
              ),
            for (final w in d.waiting.values) _row(leading: const Icon(Icons.hourglass_empty_rounded), title: title(w.episode), detail: w.waiting),
            for (final MapEntry(key: id, value: why) in d.skipped.entries)
              _row(
                leading: Icon(Icons.block_rounded, color: cs.error),
                title: 'Not downloading ${s.lib.playlists.where((p) => p.id == id).firstOrNull?.name ?? 'playlist $id'}',
                detail: '',
                problem: why,
              ),
            for (final f in d.failed.values)
              _row(
                leading: Icon(Icons.error_outline_rounded, color: cs.error),
                title: title(f.episode),
                detail: d.retriesItself(f.episode)
                    ? 'Stopped at ${(f.progress * 100).round()}%. Tried again by itself after the next sync.'
                    : 'Gave up after several tries.',
                problem: f.error,
                action: IconButton(icon: const Icon(Icons.refresh_rounded), tooltip: 'Retry now', onPressed: () => d.retry(f.episode)),
              ),
          ],
        ),
      Section(
        title: 'Storage',
        children: [
          _storage(
            held: megabytes(d.used),
            against: '${limit > 0 ? 'of ${megabytes(limit)} · ' : ''}${d.sizes.length} file${d.sizes.length == 1 ? '' : 's'} held',
            note: 'Plus ${megabytes(s.art.used)} of artwork kept for offline use',
            full: limit > 0 ? d.used / limit : null,
          ),
          if (d.sizes.isNotEmpty)
            ExpansionTile(
              shape: const Border(),
              title: const Text('Files'),
              children: [
                for (final id in d.sizes.keys)
                  _row(
                    leading: const Icon(Icons.audio_file_outlined),
                    title: title(id),
                    detail: '${megabytes(d.sizes[id]!)}${d.pinned.contains(id) ? ' · kept until played' : ''}',
                    action: IconButton(icon: const Icon(Icons.delete_outline_rounded), tooltip: 'Delete', onPressed: () => d.remove(id, 'you deleted it')),
                  ),
              ],
            ),
        ],
      ),
      Section(
        title: 'History',
        children: [
          if (events.isEmpty) _quiet('Nothing has happened on this device yet.'),
          ..._few(
            'events',
            events,
            (e) => _row(
              leading: Icon(switch (e['kind']) {
                'sync' => Icons.sync_rounded,
                'player' => Icons.play_circle_outline_rounded,
                _ => Icons.download_outlined,
              }, size: 20),
              title: '${e['text']}',
              detail: '${e['kind']} · ${ago(DateTime.fromMillisecondsSinceEpoch(e['at'] as int))}',
            ),
          ),
        ],
      ),
    ];
  }

  List<Widget> _server(Map<String, dynamic> st, Services s) {
    final cs = Theme.of(context).colorScheme;
    final running = st['running'] as List, streams = st['streams'] as List, queued = st['queued'] as List;
    final ended = st['ended_streams'] as List? ?? const [];
    final cache = st['cache'] as Map?;
    final history = (st['history'] as List).where((h) => !failuresOnly || h['state'] == 'failed').toList();
    final due = (st['due'] as List).toList()..sort((a, b) => (a['next_check'] as int).compareTo(b['next_check'] as int));
    DateTime? t(Object? v) => (v as int? ?? 0) == 0 ? null : DateTime.fromMillisecondsSinceEpoch((v as int) * 1000);
    String sent(Object? bytes) => megabytes(bytes as int);
    Widget cancel(Object? id) =>
        IconButton(icon: const Icon(Icons.close_rounded), tooltip: 'Cancel', onPressed: () => s.act(context, (api) => api.post('/status/jobs/$id/cancel')));
    return [
      Section(
        title: 'Now',
        children: [
          if (running.isEmpty) _quiet('Nothing running on the server.'),
          for (final r in running)
            _row(
              leading: _spinner,
              title: '${r['label']}',
              detail:
                  '${r['kind']} · ${r['reason']} · started ${ago(t(r['started']))}\n${r['stage']}${(r['total'] as int) > 0 ? ' ${r['done']}/${r['total']}' : ''}',
              below: (r['total'] as int) > 0
                  ? LinearProgressIndicator(value: (r['done'] as int) / (r['total'] as int), minHeight: 4, borderRadius: BorderRadius.circular(2))
                  : null,
              action: cancel(r['job']),
            ),
        ],
      ),
      Section(
        title: 'Streams',
        children: [
          if (streams.isEmpty) _quiet('No streams.'),
          for (final x in streams)
            _row(
              leading: Icon(Icons.play_circle_outline_rounded, color: cs.primary),
              title: '${x['title']}',
              detail: '${x['mode']} · ${x['client']} · ${sent(x['bytes'])} · ${ago(t(x['started']))}',
            ),
        ],
      ),
      if (ended.isNotEmpty)
        Section(
          title: 'Recent streams',
          children: _few(
            'ended',
            ended,
            (x) => _row(
              leading: Icon(
                x['error'] == '' ? Icons.check_circle_outline_rounded : Icons.error_outline_rounded,
                size: 20,
                color: x['error'] == '' ? null : cs.error,
              ),
              title: '${x['title']}',
              detail:
                  '${x['mode']}${(x['offset'] as int) > 0 ? ' from ${x['offset']}s' : ''} · ${x['client']} · ${sent(x['bytes'])} · ended ${ago(t(x['ended']))}',
              problem: '${x['error']}',
            ),
          ),
        ),
      if (queued.isNotEmpty)
        Section(
          title: 'Queued',
          children: _few(
            'queued',
            queued,
            (q) => _row(
              leading: const Icon(Icons.hourglass_empty_rounded),
              title: '${q['label']}',
              detail: '${q['kind']} · ${q['reason']} · waiting since ${ago(t(q['queued']))}',
              action: cancel(q['id']),
            ),
          ),
        ),
      if (cache != null)
        Section(
          title: 'Storage',
          children: [
            _storage(
              held: megabytes(cache['bytes'] as int),
              against: 'of ${cache['limit_gb']} GB · ${cache['files']} file${cache['files'] == 1 ? '' : 's'} held in the media cache',
              note: 'Kept ${cache['hours']} h after last use',
              full: (cache['bytes'] as int) / ((cache['limit_gb'] as int).clamp(1, 1 << 20) * 1073741824),
            ),
          ],
        ),
      if (due.isNotEmpty)
        Section(
          title: 'Up next',
          children: _few(
            'due',
            due,
            (c) => _row(
              leading: const Icon(Icons.schedule_rounded, size: 20),
              title: '${c['title']}',
              detail: 'Next check ${ago(t(c['next_check']))}',
              action: IconButton(
                icon: const Icon(Icons.refresh_rounded),
                tooltip: 'Check now',
                onPressed: () => s.act(context, (api) => api.post('/channels/${c['channel']}/check')),
              ),
            ),
          ),
        ),
      Row(
        children: [
          const Expanded(child: SectionTitle('History')),
          FilterChip(label: const Text('Failures only'), selected: failuresOnly, onSelected: (v) => setState(() => failuresOnly = v)),
        ],
      ),
      Section(
        title: '',
        children: [
          if (history.isEmpty) _quiet(failuresOnly ? 'Nothing has failed.' : 'Nothing has run yet.'),
          ..._few(
            'history',
            history,
            (h) => _row(
              leading: Icon(
                h['state'] == 'failed' ? Icons.error_outline_rounded : (h['state'] == 'done' ? Icons.check_circle_outline_rounded : Icons.cancel_outlined),
                size: 20,
                color: h['state'] == 'failed' ? cs.error : (h['state'] == 'done' ? cs.primary : null),
              ),
              title: '${h['label']}',
              detail: [
                '${h['kind']} · ${h['reason']} · ${ago(t(h['finished']))}',
                if ((h['started'] as int) > 0) 'took ${(h['finished'] as int) - (h['started'] as int)}s',
                if ('${h['summary']}'.isNotEmpty) '${h['summary']}',
              ].join(' · '),
              problem: '${h['error']}',
              action: h['state'] == 'failed'
                  ? IconButton(
                      icon: const Icon(Icons.refresh_rounded),
                      tooltip: 'Retry',
                      onPressed: () => s.act(context, (api) => api.post('/status/jobs/${h['id']}/retry')),
                    )
                  : null,
            ),
          ),
        ],
      ),
    ];
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.onSignOut});
  final Future<void> Function() onSignOut;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Map<String, dynamic>? server;
  bool serverLocked = false;
  List<dynamic> devices = [];
  Link? _watched;
  bool _loading = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final link = Scope.of(context).api.link;
    if (link == _watched) return;
    _watched?.removeListener(_onLink);
    _watched = link..addListener(_onLink);
    _load();
  }

  @override
  void dispose() {
    _watched?.removeListener(_onLink);
    super.dispose();
  }

  // Ask again each time the server answers after being offline, so nothing shown is stale.
  Reach _was = Reach.unknown;
  void _onLink() {
    final now = _watched!.reach;
    if (now == Reach.online && (_was == Reach.offline || server == null)) _load();
    _was = now;
  }

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    final s = Scope.of(context);
    try {
      final r = (await s.api.get('/settings') as Map).cast<String, dynamic>();
      final d = await s.api.get('/devices') as List;
      if (mounted) {
        setState(() {
          server = (r['server'] as Map).cast<String, dynamic>();
          serverLocked = r['server_locked'] == true;
          devices = d;
        });
      }
    } catch (_) {
    } finally {
      _loading = false;
    }
  }

  Future<void> _open(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    await _load();
  }

  Widget _link({required IconData icon, required String title, required String detail, required VoidCallback? onTap}) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    leading: IconTile(icon: icon, color: brand, size: 38),
    title: Text(title),
    subtitle: Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis),
    trailing: const Icon(Icons.chevron_right_rounded),
    enabled: onTap != null,
    onTap: onTap,
  );

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    final cs = Theme.of(context).colorScheme;
    final sv = server;
    return Scaffold(
      appBar: rootBar(context, 'Settings'),
      body: ListenableBuilder(
        listenable: Listenable.merge([s.lib, s.downloads, s.api.link]),
        builder: (context, _) {
          final prefs = s.lib.prefs;
          final offline = s.api.link.offline;
          final missing = offline ? 'Not reachable right now' : 'Loading…';
          final dev = s.lib.device;
          return Readable(
            builder: (context, inset) => ListView(
              padding: EdgeInsets.fromLTRB(16 + inset, 4, 16 + inset, 32),
              children: [
                Section(
                  title: 'Listening',
                  footer: 'The same on every device you sign in on.',
                  children: [
                    _link(
                      icon: Icons.headphones_rounded,
                      title: 'Playback and theme',
                      detail: 'Skip ${prefs.skipBack}s back, ${prefs.skipForward}s forward · ${prefs.theme} theme',
                      onTap: () => _open(const _PrefsScreen()),
                    ),
                  ],
                ),
                Section(
                  title: 'This device',
                  footer: 'Kept on this device only. Each playlist chooses whether to download, from Keep offline on its page.',
                  children: [
                    SwitchListTile(
                      secondary: IconTile(icon: Icons.pause_rounded, color: brand, size: 38),
                      title: const Text('Pause downloads'),
                      subtitle: const Text('For a hotspot or roaming. Download on an episode still works.'),
                      value: dev.downloadsPaused,
                      onChanged: (v) => s.downloads.setPaused(v),
                    ),
                    _link(
                      icon: Icons.download_rounded,
                      title: 'Downloads and storage',
                      detail:
                          '${megabytes(s.downloads.used)} used${dev.storageMb > 0 ? ' of ${megabytes(dev.storageMb * 1048576)}' : ''}${dev.wifiOnly ? ' · Wi-Fi only' : ''}${dev.downloadsPaused ? ' · Paused' : ''}',
                      onTap: () => _open(const _DeviceScreen()),
                    ),
                  ],
                ),
                Section(
                  title: 'Server',
                  footer: Uri.tryParse(s.api.base)?.host ?? s.api.base,
                  children: [
                    _link(
                      icon: Icons.dns_rounded,
                      title: 'Server defaults',
                      detail: sv == null || offline
                          ? missing
                          : serverLocked
                          ? 'Locked on this server'
                          : 'For every podcast that leaves a setting empty',
                      onTap: sv == null || offline ? null : () => _open(_ServerScreen(sv, locked: serverLocked)),
                    ),
                    _link(
                      icon: Icons.devices_rounded,
                      title: 'Devices',
                      detail: sv == null || offline ? missing : '${devices.length} signed in',
                      onTap: sv == null || offline ? null : () => _open(_DevicesScreen(devices)),
                    ),
                  ],
                ),
                Section(
                  title: '',
                  children: [
                    ListTile(
                      leading: Icon(Icons.logout_rounded, color: cs.error),
                      title: Text('Sign out and forget this device', style: TextStyle(color: cs.error)),
                      onTap: () async {
                        try {
                          await s.api.post('/device/forget');
                        } catch (_) {}
                        await widget.onSignOut();
                      },
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// A settings page: sections above, Save pinned below.
class _Form extends StatelessWidget {
  const _Form({required this.title, required this.onSave, required this.children});
  final String title;
  final VoidCallback? onSave;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    bottomNavigationBar: SaveBar(label: 'Save', onPressed: onSave),
    body: Readable(
      builder: (context, inset) => ListView(padding: EdgeInsets.fromLTRB(16 + inset, 8, 16 + inset, 24), children: children),
    ),
  );
}

class _PrefsScreen extends StatefulWidget {
  const _PrefsScreen();
  @override
  State<_PrefsScreen> createState() => _PrefsScreenState();
}

class _PrefsScreenState extends State<_PrefsScreen> {
  TextEditingController? _back, _forward, _next, _zone;
  String? _theme;
  bool? _remember, _background, _landscape;

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    final prefs = s.lib.prefs;
    final back = _back ??= TextEditingController(text: '${prefs.skipBack}');
    final forward = _forward ??= TextEditingController(text: '${prefs.skipForward}');
    final next = _next ??= TextEditingController(text: '${prefs.nextAt}');
    final zone = _zone ??= TextEditingController(text: prefs.timeZone);
    final theme = _theme ?? prefs.theme;
    final remember = _remember ?? prefs.rememberSpeed;
    final background = _background ?? s.lib.device.videoInBackground;
    final landscape = _landscape ?? s.lib.device.videoLandscape;
    return _Form(
      title: 'Playback and theme',
      onSave: () async {
        await s.lib.saveDevice(s.lib.device.withVideo(background: background, landscape: landscape));
        if (!context.mounted) return;
        final ok = await s.act(
          context,
          (api) => api.post('/settings/prefs', {
            'time_zone': zone.text.isEmpty ? 'UTC' : zone.text,
            'skip_back': back.text,
            'skip_forward': forward.text,
            'next_at': next.text,
            'theme': theme,
            'remember_speed': remember ? '1' : '0',
          }),
          done: 'Saved',
        );
        if (ok && context.mounted) Navigator.pop(context);
      },
      children: [
        const SectionTitle('Theme'),
        Padding(
          padding: const EdgeInsets.only(bottom: 24),
          child: SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'system', icon: Icon(Icons.brightness_auto_outlined), label: Text('System')),
              ButtonSegment(value: 'light', icon: Icon(Icons.light_mode_outlined), label: Text('Light')),
              ButtonSegment(value: 'dark', icon: Icon(Icons.dark_mode_outlined), label: Text('Dark')),
            ],
            selected: {theme},
            onSelectionChanged: (v) => setState(() => _theme = v.first),
          ),
        ),
        Section(
          title: 'Skip buttons',
          children: [
            NumberRow(label: 'Skip back', controller: back, unit: 's', hint: '10', enabled: true),
            NumberRow(label: 'Skip forward', controller: forward, unit: 's', hint: '30', enabled: true),
          ],
        ),
        Section(
          title: 'Speed',
          footer: 'Changing the speed while an episode plays saves it as that podcast’s speed, on every device.',
          children: [SwitchListTile(title: const Text('Remember speed for each podcast'), value: remember, onChanged: (v) => setState(() => _remember = v))],
        ),
        if (!isDesktop)
          Section(
            title: 'Video',
            footer: 'On this device only.',
            children: [
              SwitchListTile(
                title: const Text('Keep playing in the background'),
                subtitle: const Text('The sound plays on when you leave the app.'),
                value: background,
                onChanged: (v) => setState(() => _background = v),
              ),
              SwitchListTile(
                title: const Text('Full screen in landscape'),
                subtitle: const Text('Full screen turns the picture sideways.'),
                value: landscape,
                onChanged: (v) => setState(() => _landscape = v),
              ),
            ],
          ),
        Section(
          title: 'Next episode',
          footer: 'In a playlist, a Next button shows in this last part of an episode. It marks the episode played and starts the next one.',
          children: [NumberRow(label: 'Offer Next in the last', controller: next, unit: '%', hint: '10', enabled: true)],
        ),
        FieldGroup(
          title: 'Time zone',
          children: [
            TextField(
              controller: zone,
              autocorrect: false,
              decoration: const InputDecoration(hintText: 'UTC', helperText: 'For the web pages; the app uses this device’s.'),
            ),
          ],
        ),
      ],
    );
  }
}

class _DeviceScreen extends StatefulWidget {
  const _DeviceScreen();
  @override
  State<_DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<_DeviceScreen> {
  TextEditingController? _storage, _folder;
  bool? _wifi;
  String? _after;

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    final dev = s.lib.device;
    final storage = _storage ??= TextEditingController(text: dev.storageMb > 0 ? '${dev.storageMb}' : '');
    final folder = _folder ??= TextEditingController(text: s.downloads.folder);
    final wifi = _wifi ?? dev.wifiOnlySaved;
    final after = _after ?? dev.deleteAfter;
    return _Form(
      title: 'Downloads and storage',
      onSave: () async {
        final messenger = ScaffoldMessenger.of(context);
        final nav = Navigator.of(context);
        final mb = int.tryParse(storage.text.trim().isEmpty ? '0' : storage.text.trim());
        if (mb == null || mb < 0) {
          messenger.showSnackBar(const SnackBar(content: Text('Storage limit: a whole number of MB')));
          return;
        }
        if (isDesktop && folder.text != s.downloads.folder) {
          final err = await s.downloads.setFolder(folder.text);
          if (err != null) {
            messenger.showSnackBar(SnackBar(content: Text(err)));
            return;
          }
        }
        await s.lib.saveDevice(dev.withGeneral(storageMb: mb, wifiOnly: wifi, deleteAfter: after));
        unawaited(s.downloads.reconcile());
        messenger.showSnackBar(const SnackBar(content: Text('Saved')));
        nav.pop();
      },
      children: [
        Section(
          title: 'Storage',
          footer: 'Nothing downloads unless a playlist is kept offline, from Keep offline on its page.',
          children: [
            NumberRow(label: 'Storage limit', controller: storage, unit: 'MB', hint: 'none', enabled: true),
            if (!isDesktop) SwitchListTile(title: const Text('Download on Wi-Fi only'), value: wifi, onChanged: (v) => setState(() => _wifi = v)),
          ],
        ),
        Section(
          title: 'After playing',
          footer: 'Starred episodes are kept.',
          children: [
            ChoiceRow<String>(
              label: 'Delete the download',
              value: after,
              options: const [('now', 'At once'), ('1d', 'After 1 day'), ('never', 'Never')],
              onChanged: (v) => setState(() => _after = v),
            ),
          ],
        ),
        if (isDesktop)
          FieldGroup(
            title: 'Download folder',
            children: [
              TextField(
                controller: folder,
                autocorrect: false,
                decoration: InputDecoration(
                  helperText: 'New downloads go here.',
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.folder_open_rounded),
                    tooltip: 'Browse…',
                    onPressed: () async {
                      final picked = await getDirectoryPath(initialDirectory: s.downloads.folder, confirmButtonText: 'Use this folder');
                      if (picked != null) folder.text = picked;
                    },
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }
}

const _qualities = [('audio', 'Audio only'), ('480', '480p'), ('720', '720p'), ('1080', '1080p')];

class _ServerScreen extends StatefulWidget {
  const _ServerScreen(this.server, {required this.locked});
  final Map<String, dynamic> server;
  final bool locked;
  @override
  State<_ServerScreen> createState() => _ServerScreenState();
}

class _ServerScreenState extends State<_ServerScreen> {
  late final ctrls = {
    for (final k in const ['check_every', 'fetch_count', 'keep', 'deep_depth', 'refreshes', 'streams', 'history_days', 'cache_gb', 'cache_hours'])
      k: TextEditingController(text: widget.server[k] == null || widget.server[k] == 0 ? '' : '${widget.server[k]}'),
  };
  late String quality = '${widget.server['quality'] ?? '720'}';

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    NumberRow row(String key, String label, {String unit = '', String hint = ''}) =>
        NumberRow(label: label, controller: ctrls[key]!, unit: unit, hint: hint, enabled: !widget.locked);
    return _Form(
      title: 'Server defaults',
      onSave: widget.locked
          ? null
          : () async {
              final ok = await s.act(
                context,
                (api) => api.post('/settings/server', {for (final e in ctrls.entries) e.key: e.value.text, 'quality': quality}),
                done: 'Saved',
              );
              if (ok && context.mounted) Navigator.pop(context);
            },
      children: [
        Section(
          title: 'Reading podcasts',
          footer: widget.locked ? 'These are locked on this server.' : 'For every podcast that leaves a setting empty.',
          children: [
            row('check_every', 'Check every', unit: 'min'),
            row('fetch_count', 'Fetch on each refresh', hint: 'whole feed'),
            row('keep', 'Keep in the database', hint: 'everything'),
            row('deep_depth', 'Read further back', unit: 'eps'),
          ],
        ),
        Section(
          title: 'Video',
          footer: 'For streaming and downloads, unless a podcast sets its own.',
          children: [
            if (widget.locked)
              ListTile(title: const Text('Quality'), enabled: false, trailing: Text(_qualities.where((q) => q.$1 == quality).firstOrNull?.$2 ?? quality))
            else
              ChoiceRow<String>(label: 'Quality', value: quality, options: _qualities, onChanged: (v) => setState(() => quality = v)),
          ],
        ),
        Section(
          title: 'Capacity',
          footer: 'Streams at once is also how many downloads each device runs at a time.',
          children: [
            row('refreshes', 'Refreshes at once'),
            row('streams', 'Streams at once'),
            row('history_days', 'Status history kept', unit: 'days'),
          ],
        ),
        Section(
          title: 'Media cache',
          footer:
              'Videos are fetched to the server as they are played or downloaded, so seeking is quick, a download can resume and other devices get the same file. Whichever limit is reached first drops the files used longest ago, and a played episode is dropped too.',
          children: [
            row('cache_gb', 'Size', unit: 'GB'),
            row('cache_hours', 'Kept after last use', unit: 'hours'),
          ],
        ),
      ],
    );
  }
}

class _DevicesScreen extends StatelessWidget {
  const _DevicesScreen(this.devices);
  final List<dynamic> devices;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Devices')),
      body: Readable(
        builder: (context, inset) => ListView(
          padding: EdgeInsets.fromLTRB(16 + inset, 8, 16 + inset, 24),
          children: [
            Section(
              title: '',
              footer: 'Forget other devices from the web UI.',
              children: [
                for (final d in devices)
                  ListTile(
                    leading: Icon(Icons.devices_rounded, color: d['this'] == true ? cs.primary : null),
                    title: Text('${d['name']}'),
                    subtitle: Text(
                      '${d['this'] == true ? 'This device · ' : ''}synced ${ago((d['last_sync'] as int) == 0 ? null : DateTime.fromMillisecondsSinceEpoch((d['last_sync'] as int) * 1000))}',
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
