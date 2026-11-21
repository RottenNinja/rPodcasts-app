// Shared pieces: episode rows, artwork, the filter field and the mini player.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../app.dart';
import '../data/artwork.dart';
import '../data/models.dart';
import '../filter/filter.dart';
import 'parts.dart';
import 'player_screen.dart';

String clock(int s) {
  s = s < 0 ? 0 : s;
  final h = s ~/ 3600, m = (s ~/ 60) % 60, x = (s % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$x' : '$m:$x';
}

String length(int secs) {
  if (secs <= 0) return '';
  if (secs < 3600) return '${(secs + 30) ~/ 60} min';
  return '${secs ~/ 3600}h ${((secs ~/ 60) % 60).toString().padLeft(2, '0')}m';
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
String date(DateTime? t) => t == null ? '—' : '${t.day} ${_months[t.month - 1]} ${t.year}';

String ago(DateTime? t) {
  if (t == null) return 'never';
  var d = DateTime.now().difference(t);
  final future = d.isNegative;
  d = d.abs();
  String s;
  if (d.inSeconds < 10) return 'just now';
  if (d.inMinutes < 1) {
    s = '${d.inSeconds}s';
  } else if (d.inHours < 1) {
    s = '${d.inMinutes}m';
  } else if (d.inHours < 48) {
    s = '${d.inHours}h';
  } else {
    s = '${d.inDays}d';
  }
  return future ? 'in $s' : '$s ago';
}

String shortDate(DateTime? t) => t == null ? '' : (t.year == DateTime.now().year ? '${t.day} ${_months[t.month - 1]}' : date(t));

class Artwork extends StatelessWidget {
  const Artwork(this.url, {super.key, this.size = 48, this.video = false, this.rounded = true, this.fallback = ''});
  final String url;

  /// Shown instead when [url] can't be loaded, such as an episode's picture that has gone from its host.
  final String fallback;
  final double size;
  final bool video;
  final bool rounded;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ph = Container(
      width: size,
      height: size,
      color: cs.surfaceContainerHighest,
      child: Icon(video ? Icons.videocam_rounded : Icons.podcasts_rounded, size: size / 2.4, color: cs.onSurfaceVariant),
    );
    final px = (size * MediaQuery.devicePixelRatioOf(context)).round();
    return ClipRRect(
      borderRadius: BorderRadius.circular(rounded ? (size * 0.16).clamp(6, 22) : 0),
      child: url.isEmpty
          ? ph
          : ColoredBox(
              color: cs.surfaceContainerHighest,
              child: Image(
                // A tile reused for another podcast must not go on showing the last one's picture.
                key: ValueKey(url),
                image: ResizeImage(CachedArt(url, Scope.of(context).art), width: px, height: px, policy: ResizeImagePolicy.fit),
                width: size,
                height: size,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => fallback.isEmpty || fallback == url ? ph : Artwork(fallback, size: size, video: video, rounded: false),
              ),
            ),
    );
  }
}

/// One episode in a list. With [onSelect] the row is being picked from, and a tap ticks it instead of opening it.
class EpisodeTile extends StatelessWidget {
  const EpisodeTile(this.e, {super.key, this.from = '', this.selected = false, this.onSelect, this.onLongPress, this.channelArt = true});
  final Episode e;

  /// Shows the podcast's own picture beside its name; off on a podcast's own page, where every row is the same podcast.
  final bool channelArt;
  final String from;
  final bool selected;
  final ValueChanged<bool>? onSelect;
  final VoidCallback? onLongPress;

  Widget _swipeHint(BuildContext context, {required IconData icon, required String label, required bool start}) {
    final cs = Theme.of(context).colorScheme;
    final parts = [
      Icon(icon, color: cs.onPrimaryContainer),
      const SizedBox(width: 8),
      Text(
        label,
        style: TextStyle(color: cs.onPrimaryContainer, fontWeight: FontWeight.w600),
      ),
    ];
    return Container(
      color: cs.primaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(mainAxisAlignment: start ? MainAxisAlignment.start : MainAxisAlignment.end, children: start ? parts : parts.reversed.toList()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    final p = s.lib.play(e.id);
    final row = _row(context);
    // Only a swipe right, to mark played or unplayed: a swipe in from the right edge is Android's Back.
    if (onSelect != null) return row;
    return Dismissible(
      key: ValueKey('swipe-${e.id}'),
      direction: DismissDirection.startToEnd,
      dismissThresholds: const {DismissDirection.startToEnd: 0.25},
      // The row stays; the swipe only carries out the action.
      confirmDismiss: (_) async {
        HapticFeedback.selectionClick();
        await s.player.setPlayed([e.id], !p.played);
        return false;
      },
      background: _swipeHint(
        context,
        icon: p.played ? Icons.remove_done_rounded : Icons.check_circle_rounded,
        label: p.played ? 'Unplayed' : 'Played',
        start: true,
      ),
      child: Material(color: Theme.of(context).colorScheme.surface, child: row),
    );
  }

  Widget _row(BuildContext context) {
    final s = Scope.of(context);
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final ch = s.lib.channelOf(e);
    final p = s.lib.play(e.id);
    final left = p.inProgress && e.duration > 0;
    final sub = [
      ch?.title ?? '',
      shortDate(e.published),
      if (left) '${length(e.duration - p.position)} left' else length(e.duration),
    ].where((x) => x.isNotEmpty).join(' · ');
    // Every row starts with what it is and where it is, so the rows line up; the rest only show when set.
    final marks = [
      (e.media == 'video' ? Icons.videocam_outlined : Icons.headphones_outlined, cs.onSurfaceVariant),
      if (s.lib.downloaded.containsKey(e.id))
        (isDesktop ? Icons.computer_rounded : Icons.smartphone_rounded, cs.primary)
      else
        (Icons.cloud_outlined, cs.onSurfaceVariant),
      if (p.starred) (Icons.star_rounded, const Color(0xFFF59E0B)),
      if (p.played) (Icons.check_circle_rounded, cs.primary),
    ];
    final picking = onSelect != null;
    return ListenableBuilder(
      listenable: s.player,
      builder: (context, _) {
        final current = s.player.episode?.id == e.id;
        return InkWell(
          onTap: picking ? () => onSelect!(!selected) : () => openEpisode(context, id: e.id, from: from),
          onLongPress: onLongPress,
          child: Container(
            color: selected ? cs.primary.withValues(alpha: 0.12) : null,
            padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
            child: Row(
              children: [
                Stack(
                  alignment: Alignment.center,
                  children: [
                    Opacity(
                      opacity: p.played && !selected ? 0.55 : 1,
                      child: Artwork(e.artwork.isNotEmpty ? e.artwork : ch?.artwork ?? '', size: 56, video: e.media == 'video', fallback: ch?.artwork ?? ''),
                    ),
                    if (selected)
                      CircleAvatar(
                        radius: 16,
                        backgroundColor: cs.primary,
                        child: Icon(Icons.check_rounded, size: 20, color: cs.onPrimary),
                      ),
                  ],
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        e.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleSmall?.copyWith(fontSize: 15, height: 1.25, color: current ? cs.primary : (p.played ? cs.onSurfaceVariant : null)),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          for (final (icon, color) in marks)
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: Icon(icon, size: 15, color: color),
                            ),
                          if (channelArt) Padding(padding: const EdgeInsets.only(left: 2, right: 6), child: Artwork(ch?.artwork ?? '', size: 18)),
                          Expanded(
                            child: Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall),
                          ),
                        ],
                      ),
                      if (left)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: SizedBox(
                            width: 120,
                            child: LinearProgressIndicator(value: (p.position / e.duration).clamp(0, 1), minHeight: 3, borderRadius: BorderRadius.circular(2)),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                if (!picking)
                  IconButton.filledTonal(
                    icon: Icon(current && s.player.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                    tooltip: current && s.player.playing ? 'Pause' : 'Play',
                    onPressed: () => current ? s.player.toggle() : s.player.start(e, from: from, reveal: true),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The filter line: one search-style box, with the error pointed to by position, all worked out on the device.
class FilterField extends StatefulWidget {
  const FilterField({super.key, required this.controller});
  final TextEditingController controller;
  @override
  State<FilterField> createState() => _FilterFieldState();
}

class _FilterFieldState extends State<FilterField> {
  final focus = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    focus.dispose();
    super.dispose();
  }

  void _changed() => setState(() {});

  // What the + button offers, each with the filter text it puts in.
  static const _fixed = <String, List<(String, String)>>{
    'length': [
      ('Over a minute', r'$length > 1min'),
      ('Under 10 minutes', r'$length < 10min'),
      ('Under 30 minutes', r'$length < 30min'),
      ('Under an hour', r'$length < 1h'),
      ('An hour or more', r'$length >= 1h'),
      ('Two hours or more', r'$length >= 2h'),
    ],
    'media': [('Audio', r'$media = audio'), ('Video', r'$media = video')],
    'status': [('Not played', r'$unplayed'), ('Played', r'$played'), ('In progress', r'$inprogress'), ('Starred', r'$starred')],
    'downloaded': [('On this device', r'$downloaded'), ('Not on this device', r'!$downloaded')],
    'date': [
      ('In the last day', r'$published >= -1d'),
      ('In the last week', r'$published >= -7d'),
      ('In the last month', r'$published >= -1mo'),
      ('In the last year', r'$published >= -1y'),
      ('More than a year ago', r'$published < -1y'),
    ],
  };

  Future<void> _insert(String key) async {
    if (key == 'playlist') return _append(r'!$playlist');
    final s = Scope.of(context);
    final seasons = {
      for (final e in s.lib.episodes)
        if (e.season > 0) e.season,
    }.toList()..sort();
    final options = switch (key) {
      'title' => null,
      'season' => [for (final n in seasons) ('Season $n', '\$season = $n')],
      'tag' => [for (final t in s.lib.allTags) ('#$t', '#$t')],
      'channel' => [for (final o in s.lib.env.channels) (o.label, '\$channel = ${quoteLabel(o.label)}')],
      _ => _fixed[key]!,
    };
    final pick = options == null ? await _askTitle(context) : await _choose(context, options);
    if (pick != null) _append(pick);
  }

  void _append(String pick) {
    final c = widget.controller;
    final head = '${c.text.trimRight()}${c.text.trim().isEmpty ? '' : ' '}$pick';
    c.text = head;
    focus.requestFocus();
    // Set after the focus lands, as a desktop selects the whole line then.
    WidgetsBinding.instance.addPostFrameCallback((_) => c.selection = TextSelection.collapsed(offset: head.length));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = widget.controller.text;
    final err = Scope.of(context).lib.parse(text).error;
    final runes = text.runes.toList();
    final at = err == null ? 0 : err.pos.clamp(0, runes.length);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: widget.controller,
          focusNode: focus,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: r'#news AND $length < 1h',
            hintStyle: TextStyle(fontFamily: 'monospace', fontSize: 14, color: cs.onSurfaceVariant.withValues(alpha: 0.7)),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(28), borderSide: BorderSide.none),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(28), borderSide: BorderSide.none),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(28),
              borderSide: BorderSide(color: err == null ? cs.primary : cs.error, width: 1.5),
            ),
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (text.isNotEmpty) IconButton(icon: const Icon(Icons.close_rounded, size: 20), tooltip: 'Clear', onPressed: widget.controller.clear),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.add_circle_outline_rounded),
                  tooltip: 'Add to the filter',
                  onSelected: _insert,
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'channel', child: Text('A podcast…')),
                    PopupMenuItem(value: 'playlist', child: Text('Not in a playlist')),
                    PopupMenuItem(value: 'tag', child: Text('A tag…')),
                    PopupMenuItem(value: 'title', child: Text('Title…')),
                    PopupMenuItem(value: 'status', child: Text('Played status…')),
                    PopupMenuItem(value: 'downloaded', child: Text('Downloaded…')),
                    PopupMenuItem(value: 'media', child: Text('Audio or video…')),
                    PopupMenuItem(value: 'length', child: Text('Length…')),
                    PopupMenuItem(value: 'season', child: Text('Season…')),
                    PopupMenuItem(value: 'date', child: Text('Date…')),
                  ],
                ),
                const SizedBox(width: 4),
              ],
            ),
          ),
        ),
        if (err != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(err.msg, style: TextStyle(color: cs.error, fontSize: 13)),
                Text.rich(
                  TextSpan(
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                    children: [
                      TextSpan(text: String.fromCharCodes(runes.sublist(0, at))),
                      TextSpan(
                        text: at < runes.length ? String.fromCharCode(runes[at]) : ' ',
                        style: TextStyle(backgroundColor: cs.errorContainer, decoration: TextDecoration.underline),
                      ),
                      if (at + 1 < runes.length) TextSpan(text: String.fromCharCodes(runes.sublist(at + 1))),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Asks how the title should match and for the words; gives the filter text for it.
Future<String?> _askTitle(BuildContext context) => showDialog<String>(
  context: context,
  builder: (context) {
    var op = '~';
    var words = '';
    // A quote can't be written inside a quoted filter value.
    String? result() => words.trim().isEmpty ? null : '\$title $op "${words.trim().replaceAll('"', '')}"';
    return StatefulBuilder(
      builder: (context, set) => AlertDialog(
        title: const Text('Title'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: '~', label: Text('Contains')),
                ButtonSegment(value: '^:', label: Text('Starts with')),
                ButtonSegment(value: r'$:', label: Text('Ends with')),
              ],
              selected: {op},
              onSelectionChanged: (v) => set(() => op = v.first),
            ),
            const SizedBox(height: 16),
            TextField(
              autofocus: true,
              decoration: const InputDecoration(hintText: 'Words'),
              onChanged: (v) => set(() => words = v),
              onSubmitted: (_) => Navigator.pop(context, result()),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: words.trim().isEmpty ? null : () => Navigator.pop(context, result()), child: const Text('Add')),
        ],
      ),
    );
  },
);

/// A searchable, paged list of (label, value) options; gives the value of the one picked.
Future<String?> _choose(BuildContext context, List<(String, String)> options) => showDialog<String>(
  context: context,
  builder: (context) {
    var q = '';
    var shown = 30;
    return StatefulBuilder(
      builder: (context, set) {
        final hits = options.where((o) => o.$1.toLowerCase().contains(q.toLowerCase())).toList();
        return AlertDialog(
          content: SizedBox(
            width: 400,
            height: 420,
            child: Column(
              children: [
                TextField(
                  autofocus: true,
                  decoration: const InputDecoration(hintText: 'Search'),
                  onChanged: (v) => set(() => q = v),
                ),
                Expanded(
                  child: ListView(
                    children: [
                      for (final o in hits.take(shown)) ListTile(dense: true, title: Text(o.$1), onTap: () => Navigator.pop(context, o.$2)),
                      if (hits.length > shown) TextButton(onPressed: () => set(() => shown += 30), child: const Text('More')),
                      if (hits.isEmpty) const ListTile(title: Text('Nothing found')),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  },
);

/// Running background work at a glance: sync and downloads on this device plus the server's jobs.
class StatusBadge extends StatefulWidget {
  const StatusBadge({super.key, required this.child});
  final Widget child;
  @override
  State<StatusBadge> createState() => _StatusBadgeState();
}

class _StatusBadgeState extends State<StatusBadge> {
  int server = 0;
  bool failed = false;
  Timer? timer;
  bool _asking = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    timer ??= Timer.periodic(const Duration(seconds: 10), (_) => _poll());
    _poll();
  }

  Future<void> _poll() async {
    if (_asking) return;
    _asking = true;
    try {
      final st = await Scope.of(context).api.get('/status') as Map;
      final hist = st['history'] as List;
      final last = hist.where((h) => h['state'] == 'done' || h['state'] == 'failed').firstOrNull;
      if (mounted) {
        setState(() {
          server = (st['running'] as List).length + (st['queued'] as List).length + (st['streams'] as List).length;
          failed = last != null && last['state'] == 'failed';
        });
      }
    } catch (_) {
    } finally {
      _asking = false;
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([s.sync, s.downloads]),
      builder: (context, _) {
        final n = server + (s.sync.running ? 1 : 0) + s.downloads.active.length;
        return Badge(
          isLabelVisible: n > 0 || failed || s.sync.lastError.isNotEmpty,
          label: n > 0 ? Text('$n') : null,
          backgroundColor: (failed || s.sync.lastError.isNotEmpty) && n == 0 ? Colors.red : null,
          child: widget.child,
        );
      },
    );
  }
}

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key, required this.onOpen});

  /// Opens the full player.
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    final p = s.player;
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) {
        final e = p.episode;
        if (e == null) return const SizedBox.shrink();
        final ch = s.lib.channelOf(e);
        // A phone has no room for both skips beside the title once there is a close button.
        final roomy = MediaQuery.sizeOf(context).width >= 480;
        return SafeArea(
          top: false,
          child: Readable(
            builder: (context, inset) => Padding(
              padding: EdgeInsets.fromLTRB(8 + inset, 4, 8 + inset, 8),
              child: Material(
                color: cs.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(18),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: onOpen,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (p.error.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                          child: Text(
                            p.error,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: cs.error, fontSize: 13),
                          ),
                        ),
                      if (p.showNotice && p.next != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text('Up next: ${p.next!.title}', maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall),
                              ),
                              TextButton(onPressed: p.playNext, child: const Text('Play now')),
                              TextButton(onPressed: p.dontPlayNext, child: const Text("Don't play it")),
                            ],
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 8, 6, 8),
                        child: Row(
                          children: [
                            if (p.video != null)
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: SizedBox(
                                  width: 78,
                                  height: 44,
                                  child: Video(
                                    controller: p.video!,
                                    controls: NoVideoControls,
                                    wakelock: false,
                                    pauseUponEnteringBackgroundMode: !s.lib.device.videoInBackground,
                                  ),
                                ),
                              )
                            else
                              Artwork(e.artwork.isNotEmpty ? e.artwork : ch?.artwork ?? '', size: 44, video: e.media == 'video', fallback: ch?.artwork ?? ''),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.titleSmall),
                                  Text(
                                    [ch?.title ?? '', '${clock(p.position)} / ${clock(p.duration)}'].where((x) => x.isNotEmpty).join(' · '),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: text.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                            if (roomy) IconButton(icon: Icon(skipIcon(s.lib.prefs.skipBack, back: true)), tooltip: 'Skip back', onPressed: p.skipBack),
                            IconButton.filled(
                              icon: p.loading
                                  ? const SizedBox(
                                      width: 24,
                                      height: 24,
                                      child: Padding(padding: EdgeInsets.all(3), child: CircularProgressIndicator(strokeWidth: 2.5)),
                                    )
                                  : Icon(p.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                              tooltip: p.loading ? 'Loading' : (p.playing ? 'Pause' : 'Play'),
                              onPressed: p.loading ? null : p.toggle,
                            ),
                            IconButton(icon: Icon(skipIcon(s.lib.prefs.skipForward, back: false)), tooltip: 'Skip forward', onPressed: p.skipForward),
                            IconButton(
                              icon: const Icon(Icons.close_rounded),
                              tooltip: 'Close player',
                              visualDensity: VisualDensity.compact,
                              onPressed: p.close,
                            ),
                          ],
                        ),
                      ),
                      LinearProgressIndicator(value: p.duration > 0 ? (p.position / p.duration).clamp(0, 1) : 0, minHeight: 3),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The skip button's icon, with the seconds on it when there is one for that many.
IconData skipIcon(int secs, {required bool back}) => switch (secs) {
  5 => back ? Icons.replay_5_rounded : Icons.forward_5_rounded,
  10 => back ? Icons.replay_10_rounded : Icons.forward_10_rounded,
  30 => back ? Icons.replay_30_rounded : Icons.forward_30_rounded,
  _ => back ? Icons.fast_rewind_rounded : Icons.fast_forward_rounded,
};

/// A tags text field that lower-cases input and offers existing tags while focused.
class TagField extends StatefulWidget {
  const TagField({super.key, required this.controller, required this.all, required this.helper});
  final TextEditingController controller;
  final List<String> all;
  final String helper;
  @override
  State<TagField> createState() => _TagFieldState();
}

class _TagFieldState extends State<TagField> {
  final focus = FocusNode();

  @override
  void initState() {
    super.initState();
    focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    focus.dispose();
    super.dispose();
  }

  bool get _endsWithGap => RegExp(r'[\s,]$').hasMatch(widget.controller.text);

  List<String> get _words => widget.controller.text.split(RegExp(r'[\s,]+')).where((w) => w.isNotEmpty).map((w) => w.replaceFirst('#', '')).toList();

  void _pick(String tag) {
    final words = _words;
    if (!_endsWithGap && words.isNotEmpty) words.removeLast();
    final text = '${[...words, tag].join(' ')} ';
    widget.controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final words = _words;
    final partial = _endsWithGap || words.isEmpty ? '' : words.removeLast();
    final have = words.toSet();
    final offered = focus.hasFocus ? widget.all.where((t) => !have.contains(t) && t.contains(partial)).toList() : const <String>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: widget.controller,
          focusNode: focus,
          autocorrect: false,
          enableSuggestions: false,
          textCapitalization: TextCapitalization.none,
          inputFormatters: [TextInputFormatter.withFunction((_, v) => v.copyWith(text: v.text.toLowerCase()))],
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(labelText: 'Tags', helperText: widget.helper),
        ),
        if (offered.isNotEmpty)
          TextFieldTapRegion(
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [for (final t in offered) ActionChip(label: Text('#$t'), onPressed: () => _pick(t))],
              ),
            ),
          ),
      ],
    );
  }
}
