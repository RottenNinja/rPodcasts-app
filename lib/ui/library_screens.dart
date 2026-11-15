// Playlists, Episodes and show notes; all of them work offline.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app.dart';
import '../data/models.dart';
import '../filter/filter.dart';
import 'parts.dart';
import 'podcast_screens.dart';
import 'widgets.dart';

class PlaylistsScreen extends StatelessWidget {
  const PlaylistsScreen({super.key});

  void _menu(BuildContext context, Playlist p, Episode? start) {
    final s = Scope.of(context);
    final list = s.lib.playlists;
    final i = list.indexWhere((x) => x.id == p.id);
    void move(int to) => s.act(context, (api) => api.post('/playlists/move', {'id': p.id, 'target': list[to].id, 'place': to > i ? 'after' : 'before'}));
    showActionSheet(
      context,
      header: ListTile(
        title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleMedium),
        subtitle: Text(p.filter.isEmpty ? 'Every episode' : toDisplayFilter(s, p.filter), maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      actions: [
        if (start != null)
          SheetAction(
            icon: Icons.play_arrow_rounded,
            label: 'Play',
            run: () => s.player.start(start, from: 'playlist:${p.id}', reveal: true),
          ),
        SheetAction(
          icon: Icons.edit_outlined,
          label: 'Edit playlist',
          run: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlaylistEditScreen(playlist: p))),
        ),
        SheetAction(
          icon: Icons.download_for_offline_outlined,
          label: 'On this device',
          run: () => showModalBottomSheet<void>(context: context, isScrollControlled: true, builder: (_) => _PlaylistDeviceSheet(p)),
        ),
        if (i > 0) SheetAction(icon: Icons.arrow_upward_rounded, label: 'Move earlier', run: () => move(i - 1)),
        if (i >= 0 && i < list.length - 1) SheetAction(icon: Icons.arrow_downward_rounded, label: 'Move later', run: () => move(i + 1)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: rootBar(
        context,
        'Playlists',
        actions: [
          IconButton.filledTonal(
            icon: const Icon(Icons.add_rounded),
            tooltip: 'New playlist',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PlaylistEditScreen())),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: s.lib,
        builder: (context, _) {
          final lib = s.lib;
          return RefreshIndicator(
            onRefresh: s.sync.syncNow,
            child: Readable(
              builder: (context, inset) => CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(16 + inset, 4, 16 + inset, 0),
                    sliver: SliverList.list(
                      children: [
                        if (lib.channels.isEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Card(
                              color: cs.primaryContainer,
                              child: ListTile(
                                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                leading: Icon(Icons.podcasts_rounded, color: cs.onPrimaryContainer),
                                title: const Text('Nothing followed yet'),
                                subtitle: const Text('Add a podcast by its URL.'),
                                trailing: const Icon(Icons.chevron_right_rounded),
                                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AddChannelScreen())),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(16 + inset, 0, 16 + inset, 24),
                    sliver: SliverLayoutBuilder(
                      builder: (context, box) {
                        const gap = 12.0;
                        final columns = ((box.crossAxisExtent + gap) / (180 + gap)).ceil();
                        final width = (box.crossAxisExtent - gap * (columns - 1)) / columns;
                        final text = MediaQuery.textScalerOf(context).scale(38);
                        return SliverGrid(
                          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: columns,
                            mainAxisSpacing: gap,
                            crossAxisSpacing: gap,
                            mainAxisExtent: _PlaylistPoster.height(width, text),
                          ),
                          delegate: SliverChildBuilderDelegate(childCount: lib.playlists.length, (context, i) {
                            final p = lib.playlists[i];
                            final (eps, err) = lib.playlistEpisodes(p);
                            final open = eps.where((e) => !lib.play(e.id).played).toList();
                            final start = lib.startOf(eps);
                            // The poster shows whose episodes are waiting, or failing that, whose are in it at all.
                            final covers = <String>{};
                            for (final e in open.isEmpty ? eps : open) {
                              final art = lib.channelOf(e)?.artwork ?? '';
                              if (art.isNotEmpty && covers.add(art) && covers.length == _PlaylistPoster.most) break;
                            }
                            return _PlaylistPoster(
                              playlist: p,
                              covers: covers.toList(),
                              toPlay: open.length,
                              problem: err != null,
                              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlaylistScreen(p.id))),
                              onMenu: () => _menu(context, p, start),
                            );
                          }),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A playlist on the first page: one card with its name, the covers of the podcasts in it and how much is waiting.
class _PlaylistPoster extends StatelessWidget {
  const _PlaylistPoster({required this.playlist, required this.covers, required this.toPlay, required this.problem, required this.onTap, required this.onMenu});
  final Playlist playlist;
  final List<String> covers;
  final int toPlay;
  final bool problem;
  final VoidCallback onTap;
  final VoidCallback onMenu;

  /// The most covers a poster shows.
  static const most = 6;

  /// The height of the fan of covers, as a share of its width.
  static const fan = 0.56;

  /// The space between the covers and the text above and under them.
  static const gap = 8.0;

  /// How tall a poster of this width is, given the height of its two lines of text.
  static double height(double width, double text) => 20 + (width - 20) * fan + 2 * gap + text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Material(
      color: cs.surfaceContainer,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onMenu,
        onSecondaryTap: onMenu,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            children: [
              Text(playlist.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.titleSmall),
              const SizedBox(height: gap),
              AspectRatio(
                aspectRatio: 1 / fan,
                child: LayoutBuilder(
                  builder: (context, box) {
                    final w = box.maxWidth;
                    final n = covers.length;
                    if (n == 0) return Icon(Icons.queue_music_rounded, size: w * 0.36, color: cs.onSurfaceVariant.withValues(alpha: 0.5));
                    // Each cover behind the first is smaller, further right, more tilted and more washed out.
                    final sizes = [for (var i = 0; i < n; i++) w * (n == 1 ? 0.5 : 0.42) * math.pow(0.93, i)];
                    final centres = [sizes.first / 2];
                    for (var i = 1; i < n; i++) {
                      centres.add(centres.last + w * 0.145 * math.pow(0.95, i));
                    }
                    final shift = (w - (centres.last + sizes.last / 2)) / 2;
                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        for (var i = n - 1; i >= 0; i--)
                          Positioned(
                            left: shift + centres[i] - sizes[i] / 2,
                            top: (box.maxHeight - sizes[i]) / 2,
                            child: Transform.rotate(
                              angle: i * 0.045,
                              child: Container(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular((sizes[i] * 0.16).clamp(6, 22)),
                                  boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(-1, 1))],
                                ),
                                foregroundDecoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular((sizes[i] * 0.16).clamp(6, 22)),
                                  border: Border.all(color: cs.outline.withValues(alpha: 0.55), width: 1.5),
                                  color: cs.surfaceContainer.withValues(alpha: i * 0.11),
                                ),
                                child: Artwork(covers[i], size: sizes[i]),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: gap),
              Text(
                problem ? 'Filter needs fixing' : (toPlay == 0 ? 'All caught up' : '$toPlay to play'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall?.copyWith(
                  color: problem ? cs.error : (toPlay == 0 ? null : cs.primary),
                  fontWeight: toPlay == 0 ? null : FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class PlaylistScreen extends StatefulWidget {
  const PlaylistScreen(this.id, {super.key});
  final int id;
  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen> with EpisodePicker {
  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: s.lib,
      builder: (context, _) {
        final p = s.lib.playlists.where((x) => x.id == widget.id).firstOrNull;
        if (p == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const EmptyState(icon: Icons.playlist_remove_rounded, title: 'This playlist was deleted', body: 'It was removed on another device.'),
          );
        }
        final (eps, err) = s.lib.playlistEpisodes(p);
        final start = s.lib.startOf(eps);
        final from = 'playlist:${p.id}';
        final offline = s.lib.device.forPlaylist(p.id).download;
        final page = Scaffold(
          appBar: picking
              ? pickingBar(eps.map((e) => e.id))
              : AppBar(
                  actions: [
                    if (p.sort == 'shuffle')
                      IconButton(
                        icon: const Icon(Icons.shuffle_rounded),
                        tooltip: 'Reshuffle',
                        onPressed: () async {
                          final ok = await confirm(context, "Reshuffle this playlist? The current order can't be brought back.");
                          if (!ok || !context.mounted) return;
                          await s.act(context, (api) => api.post('/playlists/${p.id}/reshuffle'), done: 'Reshuffled');
                        },
                      ),
                    IconButton(
                      icon: Icon(offline ? Icons.download_for_offline_rounded : Icons.download_for_offline_outlined, color: offline ? cs.primary : null),
                      tooltip: 'On this device',
                      onPressed: () => showModalBottomSheet<void>(context: context, isScrollControlled: true, builder: (_) => _PlaylistDeviceSheet(p)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.edit_outlined),
                      tooltip: 'Edit playlist',
                      onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlaylistEditScreen(playlist: p))),
                    ),
                    PopupMenuButton<String>(
                      onSelected: (v) async {
                        if (v == 'played' || v == 'unplayed') {
                          await s.player.setPlayed(eps.map((e) => e.id), v == 'played');
                        } else if (v == 'select') {
                          startPicking();
                        } else if (v == 'dates') {
                          await s.act(context, (api) => api.post('/playlists/${p.id}/fix-dates'), done: 'Fixing dates; progress is on the Status page');
                        } else if (v == 'delete') {
                          final ok = await confirm(context, 'Delete this playlist? Episodes are not affected.');
                          if (!ok || !context.mounted) return;
                          if (await s.act(context, (api) => api.delete('/playlists/${p.id}')) && context.mounted) Navigator.pop(context);
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'select', child: Text('Select episodes')),
                        PopupMenuItem(value: 'played', child: Text('Mark all played')),
                        PopupMenuItem(value: 'unplayed', child: Text('Mark all unplayed')),
                        PopupMenuItem(value: 'dates', child: Text('Fix dates')),
                        PopupMenuItem(value: 'delete', child: Text('Delete')),
                      ],
                    ),
                  ],
                ),
          body: Readable(
            builder: (context, inset) {
              final head = Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(p.name, style: text.headlineSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                              const SizedBox(height: 2),
                              Text('${s.lib.notDone(eps)} to play · ${eps.length} episodes${offline ? ' · kept offline' : ''}', style: text.bodySmall),
                            ],
                          ),
                        ),
                        if (start != null)
                          FilledButton.icon(
                            icon: const Icon(Icons.play_arrow_rounded),
                            label: const Text('Play'),
                            onPressed: () => s.player.start(start, from: from, reveal: true),
                          ),
                      ],
                    ),
                  ),
                  if (err != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Notice(icon: Icons.error_outline_rounded, text: err.msg, error: true),
                    ),
                ],
              );
              final pad = EdgeInsets.fromLTRB(inset, 0, inset, 24);
              // A long-press drags in a hand-ordered playlist, so there picking starts from the menu.
              if (p.sort != 'manual' || picking) {
                return ListView.builder(
                  padding: pad,
                  itemCount: eps.length + 1,
                  itemBuilder: (_, i) => i == 0 ? head : pickTile(eps[i - 1], from: from, channelArt: true),
                );
              }
              return ReorderableListView.builder(
                padding: pad,
                header: head,
                buildDefaultDragHandles: false,
                onReorderItem: (a, b) {
                  if (a == b) return;
                  s.act(context, (api) => api.post('/playlists/${p.id}/order', {'id': eps[a].id, 'target': eps[b].id, 'place': b > a ? 'after' : 'before'}));
                },
                itemCount: eps.length,
                itemBuilder: (_, i) => ReorderableDelayedDragStartListener(
                  key: ValueKey(eps[i].id),
                  index: i,
                  child: Material(
                    color: cs.surface,
                    child: EpisodeTile(eps[i], from: from),
                  ),
                ),
              );
            },
          ),
        );
        return whilePicking(page);
      },
    );
  }
}

/// Picking several episodes on a page that lists them, and what can be done to the ones picked.
mixin EpisodePicker<T extends StatefulWidget> on State<T> {
  final Set<int> selected = {};
  bool picking = false;

  void startPicking() => setState(() => picking = true);

  void stopPicking() => setState(() {
    picking = false;
    selected.clear();
  });

  void _tick(int id, bool on) => setState(() {
    picking = true;
    on ? selected.add(id) : selected.remove(id);
  });

  Future<void> _apply(String action) async {
    final s = Scope.of(context);
    final ids = selected.toList();
    stopPicking();
    final (field, value) = switch (action) {
      'played' => ('played', true),
      'unplayed' => ('played', false),
      'star' => ('starred', true),
      _ => ('starred', false),
    };
    if (field == 'played') return s.player.setPlayed(ids, value);
    await s.lib.markMany(ids, field, value);
  }

  /// An episode row that a long-press starts picking from, and a tap ticks while picking.
  Widget pickTile(Episode e, {required String from, required bool channelArt}) => EpisodeTile(
    e,
    from: from,
    channelArt: channelArt,
    selected: selected.contains(e.id),
    onSelect: picking ? (v) => _tick(e.id, v) : null,
    onLongPress: () => _tick(e.id, !selected.contains(e.id)),
  );

  /// Back stops picking before it leaves the page.
  Widget whilePicking(Widget page) => PopScope(
    canPop: !picking,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) stopPicking();
    },
    child: page,
  );

  /// The top bar while picking; [all] is what Select all ticks.
  AppBar pickingBar(Iterable<int> all) {
    final some = selected.isNotEmpty;
    return AppBar(
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      leading: IconButton(icon: const Icon(Icons.close_rounded), tooltip: 'Stop selecting', onPressed: stopPicking),
      title: Text(some ? '${selected.length} selected' : 'Select episodes'),
      actions: [
        IconButton(icon: const Icon(Icons.check_circle_outline_rounded), tooltip: 'Mark played', onPressed: some ? () => _apply('played') : null),
        IconButton(icon: const Icon(Icons.restart_alt_rounded), tooltip: 'Reset progress (mark unplayed)', onPressed: some ? () => _apply('unplayed') : null),
        IconButton(icon: const Icon(Icons.star_outline_rounded), tooltip: 'Star', onPressed: some ? () => _apply('star') : null),
        PopupMenuButton<String>(
          onSelected: (v) => v == 'all' ? setState(() => selected.addAll(all)) : _apply(v),
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'all', child: Text('Select all')),
            PopupMenuItem(value: 'unstar', enabled: some, child: const Text('Unstar')),
          ],
        ),
      ],
    );
  }
}

/// What this device does with a playlist: stream it, or keep some of it downloaded.
class _PlaylistDeviceSheet extends StatefulWidget {
  const _PlaylistDeviceSheet(this.playlist);
  final Playlist playlist;
  @override
  State<_PlaylistDeviceSheet> createState() => _PlaylistDeviceSheetState();
}

class _PlaylistDeviceSheetState extends State<_PlaylistDeviceSheet> {
  bool? _download;
  bool? _oldest;
  int? _count;

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    final text = Theme.of(context).textTheme;
    final saved = s.lib.device.forPlaylist(widget.playlist.id);
    final why = s.lib.downloadError(widget.playlist.filter);
    final download = why == null && (_download ?? saved.download);
    final oldest = _oldest ?? saved.oldest;
    final count = _count ?? (saved.download ? saved.count : 3);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('On this device', style: text.titleLarge),
            const SizedBox(height: 4),
            Text('How ${widget.playlist.name} plays here. Other devices keep their own choice.', style: text.bodySmall),
            const SizedBox(height: 16),
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: [
                const ButtonSegment(value: false, icon: Icon(Icons.wifi_tethering_rounded), label: Text('Stream')),
                ButtonSegment(value: true, enabled: why == null, icon: const Icon(Icons.download_rounded), label: const Text('Download')),
              ],
              selected: {download},
              onSelectionChanged: (v) => setState(() => _download = v.first),
            ),
            if (download) ...[
              const SizedBox(height: 16),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      title: const Text('Episodes to keep'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.remove_circle_outline_rounded),
                            tooltip: 'Fewer',
                            onPressed: count > 1 ? () => setState(() => _count = count - 1) : null,
                          ),
                          SizedBox(
                            width: 32,
                            child: Text('$count', textAlign: TextAlign.center, style: text.titleMedium),
                          ),
                          IconButton(
                            icon: const Icon(Icons.add_circle_outline_rounded),
                            tooltip: 'More',
                            onPressed: count < 100 ? () => setState(() => _count = count + 1) : null,
                          ),
                        ],
                      ),
                    ),
                    const Divider(indent: 16, endIndent: 16),
                    ChoiceRow<bool>(
                      label: 'Starting from',
                      value: oldest,
                      options: const [(false, 'Newest unplayed'), (true, 'Oldest unplayed')],
                      onChanged: (v) => setState(() => _oldest = v),
                    ),
                  ],
                ),
              ),
            ],
            if (why != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Notice(
                  icon: Icons.block_rounded,
                  text: s.lib.usesDownloaded(widget.playlist.filter)
                      ? "This playlist can't be kept on this device: its filter uses \$downloaded, so downloading would change what it holds and it would never settle. Take \$downloaded out of the filter to download it."
                      : "This playlist can't be kept on this device: $why.",
                  error: false,
                ),
              ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () async {
                final nav = Navigator.of(context);
                await s.lib.saveDevice(
                  s.lib.device.withPlaylist(widget.playlist.id, PlaylistDevice(download: download, count: download ? count : 0, oldest: oldest)),
                );
                s.downloads.reconcile();
                nav.pop();
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}

Future<bool> confirm(BuildContext context, String text) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        content: Text(text),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('OK')),
        ],
      ),
    ) ??
    false;

const sorts = [('newest', 'Newest first'), ('oldest', 'Oldest first'), ('shortest', 'Shortest first'), ('longest', 'Longest first'), ('manual', 'In my order'), ('shuffle', 'Shuffled')];

class PlaylistEditScreen extends StatefulWidget {
  const PlaylistEditScreen({super.key, this.playlist, this.filter = ''});
  final Playlist? playlist;
  final String filter;
  @override
  State<PlaylistEditScreen> createState() => _PlaylistEditScreenState();
}

class _PlaylistEditScreenState extends State<PlaylistEditScreen> {
  late final name = TextEditingController(text: widget.playlist?.name ?? '');
  final filter = TextEditingController();
  late String sort = widget.playlist?.sort ?? 'newest';
  late bool autoplay = widget.playlist?.autoplay ?? false;
  bool init = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (init) return;
    init = true;
    filter.text = widget.playlist == null ? widget.filter : toDisplayFilter(Scope.of(context), widget.playlist!.filter);
  }

  Future<void> _save() async {
    final s = Scope.of(context);
    final p = widget.playlist;
    final body = {'name': name.text, 'filter': filter.text, 'sort': sort, 'autoplay': autoplay};
    final ok = await s.act(context, (api) => api.post(p == null ? '/playlists' : '/playlists/${p.id}', body));
    if (ok && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.playlist == null ? 'New playlist' : 'Edit playlist')),
      bottomNavigationBar: SaveBar(label: widget.playlist == null ? 'Create playlist' : 'Save', onPressed: _save),
      body: Readable(
        builder: (context, inset) => ListView(
          padding: EdgeInsets.fromLTRB(16 + inset, 8, 16 + inset, 24),
          children: [
            TextField(
              controller: name,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 24),
            const SectionTitle('Which episodes'),
            FilterField(controller: filter),
            ListenableBuilder(
              listenable: Listenable.merge([filter, s.lib]),
              builder: (context, _) {
                final r = s.lib.parse(filter.text);
                if (r.filter == null) return const SizedBox(height: 24);
                final n = s.lib.match(r.filter!).length;
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  child: Text(
                    filter.text.trim().isEmpty ? 'Every episode: $n. Narrow it with a filter.' : '$n episode${n == 1 ? '' : 's'} match',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                );
              },
            ),
            Section(
              title: 'Order',
              children: [ChoiceRow<String>(label: 'Show', value: sort, options: sorts, onChanged: (v) => setState(() => sort = v))],
            ),
            Section(
              title: 'Playback',
              children: [
                SwitchListTile(
                  title: const Text('Automatically play next episode'),
                  subtitle: const Text('When one ends, carry on with the next one not played'),
                  value: autoplay,
                  onChanged: (v) => setState(() => autoplay = v),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String toDisplayFilter(Services s, String stored) => toDisplay(stored, s.lib.env);

class EpisodesScreen extends StatefulWidget {
  const EpisodesScreen({super.key});
  @override
  State<EpisodesScreen> createState() => _EpisodesScreenState();
}

class _EpisodesScreenState extends State<EpisodesScreen> with EpisodePicker {
  final filter = TextEditingController();
  String sort = 'newest';
  int shown = 100;

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([s.lib, filter]),
      builder: (context, _) {
        final r = s.lib.parse(filter.text);
        final eps = r.filter == null ? <Episode>[] : s.lib.match(r.filter!);
        s.lib.sortEpisodes(eps, sort);
        final visible = eps.take(shown);
        return whilePicking(
          Scaffold(
            appBar: picking
                ? pickingBar(visible.map((e) => e.id))
                : rootBar(
                    context,
                    'Episodes',
                    note: '${eps.length}',
                    actions: [
                      IconButton(icon: const Icon(Icons.checklist_rounded), tooltip: 'Select several', onPressed: startPicking),
                      PopupMenuButton<String>(
                        icon: const Icon(Icons.swap_vert_rounded),
                        tooltip: 'Sort',
                        initialValue: sort,
                        onSelected: (v) => setState(() => sort = v),
                        itemBuilder: (_) => [for (final (k, l) in sorts.take(4)) PopupMenuItem(value: k, child: Text(l))],
                      ),
                      IconButton(
                        icon: const Icon(Icons.bookmark_add_outlined),
                        tooltip: 'Save as playlist',
                        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlaylistEditScreen(filter: filter.text))),
                      ),
                    ],
                  ),
            body: Readable(
              builder: (context, inset) => CustomScrollView(
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                slivers: [
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(16 + inset, 0, 16 + inset, 0),
                    sliver: SliverToBoxAdapter(child: FilterField(controller: filter)),
                  ),
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: 52,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: EdgeInsets.symmetric(horizontal: 12 + inset),
                        children: [
                          for (final (l, f) in const [('Every episode', ''), ('Unplayed', r'$unplayed'), ('In progress', r'$inprogress')])
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              child: ChoiceChip(label: Text(l), selected: filter.text == f, onSelected: (_) => filter.text = f),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (eps.isEmpty && r.filter != null)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: EmptyState(
                        icon: Icons.search_off_rounded,
                        title: 'Nothing matches',
                        body: 'Try a wider filter, or clear it to see every episode.',
                      ),
                    ),
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(inset, 0, inset, 24),
                    sliver: SliverList.builder(
                      itemCount: visible.length + (eps.length > shown ? 1 : 0),
                      itemBuilder: (_, i) {
                        if (i == shown) {
                          return Padding(
                            padding: const EdgeInsets.all(12),
                            child: Center(
                              child: FilledButton.tonal(onPressed: () => setState(() => shown += 100), child: const Text('Show more')),
                            ),
                          );
                        }
                        return pickTile(eps[i], from: '', channelArt: true);
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

final _tags = RegExp(r'<(br|/p|/li|/h\d)[^>]*>', caseSensitive: false);
final _anyTag = RegExp(r'<[^>]+>');
final _timestamp = RegExp(r'\b(?:(\d{1,2}):)?([0-5]?\d):([0-5]\d)\b');

final _scripts = RegExp(r'<(script|style)[\s\S]*?</\1>', caseSensitive: false);
final _blankLines = RegExp(r'\n{3,}');

/// What a feed's HTML says, without the markup.
String plainText(String html) => html
    .replaceAll(_scripts, '')
    .replaceAll(_tags, '\n')
    .replaceAll(_anyTag, '')
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&nbsp;', ' ')
    .replaceAll(_blankLines, '\n\n')
    .trim();

/// Show notes as plain text, with timestamps that seek the player.
class ShowNotes extends StatelessWidget {
  const ShowNotes(this.html, {super.key, required this.onSeek});
  final String html;
  final void Function(int secs) onSeek;

  @override
  Widget build(BuildContext context) {
    final text = plainText(html);
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in _timestamp.allMatches(text)) {
      spans.add(TextSpan(text: text.substring(last, m.start)));
      final secs = (int.tryParse(m[1] ?? '0') ?? 0) * 3600 + int.parse(m[2]!) * 60 + int.parse(m[3]!);
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: InkWell(
            onTap: () => onSeek(secs),
            child: Text(
              m[0]!,
              style: TextStyle(color: Theme.of(context).colorScheme.primary, fontFamily: 'monospace'),
            ),
          ),
        ),
      );
      last = m.end;
    }
    spans.add(TextSpan(text: text.substring(last)));
    return SelectableText.rich(TextSpan(children: spans, style: Theme.of(context).textTheme.bodyMedium));
  }
}
