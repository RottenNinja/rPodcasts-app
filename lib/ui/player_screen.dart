// The episode page, which is also the player: artwork and transport for audio, and a video surface with its own controls and a full screen.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../app.dart';
import '../data/artwork.dart';
import '../data/models.dart';
import '../player/player.dart';
import 'library_screens.dart';
import 'parts.dart';
import 'podcast_screens.dart';
import 'widgets.dart';

const _speeds = [50, 75, 90, 100, 110, 125, 150, 175, 200, 250, 300];
const _sleeps = [('', 'Sleep timer off'), ('15', '15 min'), ('30', '30 min'), ('45', '45 min'), ('60', '60 min'), ('end', 'End of episode')];

String _times(int percent) => '${(percent / 100).toStringAsFixed(percent % 10 == 0 ? 1 : 2)}×';

/// Space plays and pauses, the arrows skip, F is full screen and Esc leaves, as in the browser player.
Widget _keys({required PlayerController player, required VoidCallback? onFullscreen, required VoidCallback onLeave, required Widget child}) =>
    CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.space): player.toggle,
        const SingleActivator(LogicalKeyboardKey.arrowLeft): player.skipBack,
        const SingleActivator(LogicalKeyboardKey.arrowRight): player.skipForward,
        const SingleActivator(LogicalKeyboardKey.keyF): ?onFullscreen,
        const SingleActivator(LogicalKeyboardKey.escape): onLeave,
      },
      child: Focus(autofocus: true, child: child),
    );

/// Opens the player over everything, the tabs and the mini player included; with no [id] it shows whatever is playing.
Future<void> openEpisode(BuildContext context, {required int? id, required String from}) {
  final s = Scope.of(context);
  return Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => Scope(
        services: s,
        child: _EpisodePages(id: id, from: from),
      ),
    ),
  );
}

/// The player in a navigator of its own, so the pages opened from it stay over the tabs and inside the scope.
class _EpisodePages extends StatefulWidget {
  const _EpisodePages({required this.id, required this.from});
  final int? id;
  final String from;
  @override
  State<_EpisodePages> createState() => _EpisodePagesState();
}

class _EpisodePagesState extends State<_EpisodePages> {
  final nav = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) => NavigatorPopHandler(
    onPopWithResult: (_) => nav.currentState?.maybePop(),
    child: Navigator(
      key: nav,
      onGenerateRoute: (_) => MaterialPageRoute<void>(
        builder: (_) => _EpisodeScreen(id: widget.id, from: widget.from),
      ),
    ),
  );
}

/// One episode: what it is, the player for it, and its chapters, show notes and what follows.
class _EpisodeScreen extends StatefulWidget {
  const _EpisodeScreen({required this.id, required this.from});

  /// Null follows the player on to each next episode.
  final int? id;

  /// The list the episode was opened from, which decides what plays after it.
  final String from;
  @override
  State<_EpisodeScreen> createState() => _EpisodeScreenState();
}

class _EpisodeScreenState extends State<_EpisodeScreen> {
  String tab = '';

  /// The episode shown; null follows the player.
  late int? _id = widget.id;
  int? _wasPlaying;
  int? _chaptersOf;
  List<Chapter> _chapters = const [];

  // The page shows an episode's chapters before it plays, so it reads them itself when the episode changes.
  void _loadChapters(Episode e) {
    if (_chaptersOf == e.id) return;
    _chaptersOf = e.id;
    _chapters = const [];
    fetchChapters(e).then((found) {
      if (mounted && _chaptersOf == e.id) setState(() => _chapters = found);
    });
  }

  void _fullscreen() {
    final s = Scope.of(context);
    Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder<void>(
        pageBuilder: (_, _, _) => Scope(services: s, child: const _FullscreenVideo()),
        transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
      ),
    );
  }

  void _leave() => Navigator.of(context, rootNavigator: true).pop();

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    final pl = s.player;
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final back = IconButton(icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 30), tooltip: 'Back', onPressed: _leave);
    return ListenableBuilder(
      listenable: Listenable.merge([s.lib, s.downloads, pl]),
      builder: (context, _) {
        // A page opened on one episode moves on with the player when that episode gives way to the next.
        final playing = pl.episode?.id;
        if (_id != null && _id == _wasPlaying && playing != null && playing != _id) _id = playing;
        _wasPlaying = playing;
        final following = _id == null;
        final e = s.lib.byId[_id ?? playing];
        if (e == null) {
          return Scaffold(
            appBar: AppBar(leading: back),
            body: following
                ? const EmptyState(icon: Icons.headphones_rounded, title: 'Nothing playing', body: 'Pick an episode to start listening.')
                : const EmptyState(icon: Icons.podcasts_rounded, title: 'This episode is gone', body: 'Its podcast no longer holds it.'),
          );
        }
        final from = following ? pl.from : widget.from;
        final ch = s.lib.channelOf(e);
        final p = s.lib.play(e.id);
        final current = pl.episode?.id == e.id;
        final video = current ? pl.video : null;
        // A video's page is laid out the same before it plays as while it plays.
        final isVideo = e.media == 'video';
        void play() => pl.start(e, from: from, reveal: false);
        final held = s.lib.downloaded.containsKey(e.id);
        final downloading = s.downloads.active[e.id];
        final position = current ? pl.position : p.position;
        // Pressing play on this page plays here, so the app has no player to bring up.
        void seekTo(int t) => current ? pl.seek(t) : pl.start(e, from: from, at: t, reveal: false);
        _loadChapters(e);
        final chapters = _chapters;
        // Both tabs are always there; one with nothing in it is greyed out.
        final has = {'Show notes': e.notes.isNotEmpty, 'Chapters': chapters.isNotEmpty};
        final shown = has[tab] == true ? tab : has.keys.where((t) => has[t]!).firstOrNull;
        final facts = [
          date(e.published),
          length(e.duration),
          if (e.media == 'video') 'video',
          if (e.season > 0) 'season ${e.season}',
          if (e.number > 0) 'episode ${e.number}',
          if (e.type != 'full') e.type,
          if (p.played) 'played' else if (!current && p.position > 0) 'stopped at ${clock(p.position)}',
        ].where((x) => x.isNotEmpty).join(' · ');
        final align = isVideo ? TextAlign.start : TextAlign.center;
        final art = e.artwork.isNotEmpty ? e.artwork : ch?.artwork ?? '';
        final page = Scaffold(
          appBar: AppBar(
            leading: back,
            actions: [
              IconButton(
                isSelected: p.starred,
                icon: const Icon(Icons.star_outline_rounded),
                selectedIcon: const Icon(Icons.star_rounded, color: Color(0xFFF59E0B)),
                tooltip: p.starred ? 'Unstar' : 'Star',
                onPressed: () => s.lib.mark(e.id, 'starred', !p.starred),
              ),
              if (held)
                IconButton(
                  icon: Icon(isDesktop ? Icons.computer_rounded : Icons.smartphone_rounded, color: cs.primary),
                  tooltip: 'On this device; delete the download',
                  onPressed: () => s.downloads.remove(e.id, 'you deleted it'),
                )
              else if (downloading != null)
                IconButton(
                  icon: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.5, value: downloading.progress > 0 ? downloading.progress : null),
                  ),
                  tooltip: 'Downloading ${(downloading.progress * 100).round()}%; cancel',
                  onPressed: () => s.downloads.cancel(e.id),
                )
              else
                IconButton(icon: const Icon(Icons.download_rounded), tooltip: 'Download', onPressed: () => s.downloads.pin(e)),
              PopupMenuButton<String>(
                onSelected: (v) async {
                  final messenger = ScaffoldMessenger.of(context);
                  switch (v) {
                    case 'played' || 'unplayed':
                      await pl.setPlayed([e.id], v == 'played');
                      if (current && following) _leave();
                    case 'older':
                      await s.lib.markOlderPlayed(e);
                    case 'page' || 'transcript':
                      await Clipboard.setData(ClipboardData(text: v == 'page' ? e.pageUrl : e.transcriptUrl));
                      messenger.showSnackBar(const SnackBar(content: Text('Address copied')));
                    case 'link':
                      await Clipboard.setData(ClipboardData(text: '${s.api.base}/episodes/${e.id}${current && position > 0 ? '?t=$position' : ''}'));
                      messenger.showSnackBar(const SnackBar(content: Text('Link copied')));
                    case 'sleep':
                      await showActionSheet(
                        context,
                        header: const ListTile(title: Text('Sleep timer')),
                        actions: [
                          for (final (v, l) in _sleeps)
                            SheetAction(icon: v == pl.sleep ? Icons.check_rounded : Icons.bedtime_outlined, label: l, run: () => pl.setSleep(v)),
                        ],
                      );
                    case 'stop':
                      pl.close();
                      if (following) _leave();
                  }
                },
                itemBuilder: (_) => [
                  if (!p.played) const PopupMenuItem(value: 'played', child: Text('Mark played')),
                  if (p.played)
                    const PopupMenuItem(value: 'unplayed', child: Text('Mark unplayed'))
                  else if (current || p.position > 0)
                    const PopupMenuItem(value: 'unplayed', child: Text('Reset progress')),
                  const PopupMenuItem(value: 'older', child: Text('Mark older played')),
                  if (e.pageUrl.isNotEmpty) const PopupMenuItem(value: 'page', child: Text('Web page (copy address)')),
                  if (e.transcriptUrl.isNotEmpty) const PopupMenuItem(value: 'transcript', child: Text('Transcript (copy address)')),
                  const PopupMenuItem(value: 'link', child: Text('Copy link at current time')),
                  if (current) const PopupMenuItem(value: 'sleep', child: Text('Sleep timer')),
                  if (current) const PopupMenuItem(value: 'stop', child: Text('Stop playing')),
                ],
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: LayoutBuilder(
            builder: (context, box) => CustomScrollView(
              slivers: [
                // Pinned, so the picture stays in view while the show notes scroll under it.
                if (isVideo)
                  PinnedHeaderSliver(
                    child: ColoredBox(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      child: Center(
                        child: ConstrainedBox(
                          // The picture never pushes the title off the screen.
                          constraints: BoxConstraints(maxWidth: 1100, maxHeight: box.maxHeight * 0.62),
                          child: AspectRatio(
                            aspectRatio: 16 / 9,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(box.maxWidth > 700 ? 18 : 0),
                              child: video != null
                                  ? VideoStage(fullscreen: false, onFullscreen: _fullscreen)
                                  : Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        const ColoredBox(color: Colors.black),
                                        if (art.isNotEmpty)
                                          Image(image: CachedArt(art, s.art), fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox.shrink()),
                                        Center(
                                          child: IconButton(
                                            style: IconButton.styleFrom(backgroundColor: Colors.black45, foregroundColor: Colors.white),
                                            iconSize: 48,
                                            icon: const Icon(Icons.play_arrow_rounded),
                                            tooltip: p.inProgress ? 'Resume' : 'Play',
                                            onPressed: play,
                                          ),
                                        ),
                                      ],
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                SliverToBoxAdapter(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(24, isVideo ? 20 : 8, 24, 0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (!isVideo) ...[
                              Center(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(22),
                                    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 32, offset: const Offset(0, 14))],
                                  ),
                                  // Small enough on a short screen that the controls and the tabs under them are in view.
                                  child: Artwork(art, size: (box.maxWidth - 48).clamp(120.0, (box.maxHeight * 0.38).clamp(120.0, 320.0))),
                                ),
                              ),
                              const SizedBox(height: 24),
                            ],
                            Text(e.title, style: text.titleLarge, textAlign: align, maxLines: 3, overflow: TextOverflow.ellipsis),
                            const SizedBox(height: 4),
                            if (ch != null)
                              Align(
                                alignment: isVideo ? Alignment.centerLeft : Alignment.center,
                                child: InkWell(
                                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChannelScreen(ch.id))),
                                  child: Text(
                                    ch.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: text.bodyMedium?.copyWith(color: cs.primary, fontWeight: FontWeight.w600),
                                  ),
                                ),
                              ),
                            const SizedBox(height: 4),
                            Text(facts, style: text.bodySmall, textAlign: align),
                            if (current && pl.error.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: Notice(icon: Icons.error_outline_rounded, text: pl.error, error: true),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                // A video carries these on its picture; audio pins them while the show notes scroll.
                if (!isVideo)
                  PinnedHeaderSliver(
                    child: ColoredBox(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 560),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                SeekBar.stacked(
                                  position: position,
                                  duration: current ? pl.duration : e.duration,
                                  onSeek: seekTo,
                                  between: Opacity(
                                    opacity: current ? 1 : 0.5,
                                    child: PopupMenuButton<int>(
                                      tooltip: 'Speed',
                                      enabled: current,
                                      initialValue: pl.speed,
                                      onSelected: pl.setSpeed,
                                      itemBuilder: (_) => [for (final v in _speeds) PopupMenuItem(value: v, child: Text(_times(v)))],
                                      child: Pill(text: _times(current ? pl.speed : ch?.speed ?? 100), icon: Icons.speed_rounded),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    if (chapters.isNotEmpty)
                                      IconButton(
                                        icon: const Icon(Icons.skip_previous_rounded),
                                        tooltip: 'Previous chapter',
                                        onPressed: current ? () => pl.chapter(-1) : null,
                                      ),
                                    IconButton(
                                      iconSize: 38,
                                      icon: Icon(skipIcon(s.lib.prefs.skipBack, back: true)),
                                      tooltip: 'Skip back',
                                      onPressed: current ? pl.skipBack : null,
                                    ),
                                    const SizedBox(width: 12),
                                    IconButton.filled(
                                      iconSize: 44,
                                      padding: const EdgeInsets.all(14),
                                      icon: current && pl.loading
                                          ? const SizedBox(
                                              width: 44,
                                              height: 44,
                                              child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator(strokeWidth: 3)),
                                            )
                                          : Icon(current && pl.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                                      tooltip: !current
                                          ? (p.inProgress ? 'Resume' : 'Play')
                                          : (pl.loading ? 'Loading' : (pl.playing ? 'Pause' : 'Play')),
                                      onPressed: !current ? play : (pl.loading ? null : pl.toggle),
                                    ),
                                    const SizedBox(width: 12),
                                    IconButton(
                                      iconSize: 38,
                                      icon: Icon(skipIcon(s.lib.prefs.skipForward, back: false)),
                                      tooltip: 'Skip forward',
                                      onPressed: current ? pl.skipForward : null,
                                    ),
                                    if (chapters.isNotEmpty)
                                      IconButton(
                                        icon: const Icon(Icons.skip_next_rounded),
                                        tooltip: 'Next chapter',
                                        onPressed: current ? () => pl.chapter(1) : null,
                                      ),
                                  ],
                                ),
                                if (current && pl.offerNext)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 12),
                                    child: Center(
                                      child: FilledButton.tonalIcon(
                                        onPressed: pl.finishToNext,
                                        icon: const Icon(Icons.skip_next_rounded),
                                        label: Text('Next: ${pl.next!.title}', maxLines: 1, overflow: TextOverflow.ellipsis),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                SliverPadding(
                  padding: const EdgeInsets.only(bottom: 32),
                  sliver: SliverToBoxAdapter(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 640),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(8, 28, 8, 0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                                child: SegmentedButton<String>(
                                  showSelectedIcon: false,
                                  emptySelectionAllowed: true,
                                  segments: [
                                    ButtonSegment(
                                      value: 'Show notes',
                                      icon: const Icon(Icons.notes_rounded),
                                      label: const Text('Show notes'),
                                      enabled: has['Show notes']!,
                                    ),
                                    ButtonSegment(
                                      value: 'Chapters',
                                      icon: const Icon(Icons.format_list_numbered_rounded),
                                      label: const Text('Chapters'),
                                      enabled: has['Chapters']!,
                                    ),
                                  ],
                                  selected: {?shown},
                                  onSelectionChanged: (v) => setState(() => tab = v.firstOrNull ?? tab),
                                ),
                              ),
                              switch (shown) {
                                'Chapters' => Section(
                                  title: '',
                                  children: [
                                    for (final (i, c) in chapters.indexed)
                                      ListTile(
                                        dense: true,
                                        selected: current && c.start <= position && (i + 1 == chapters.length || chapters[i + 1].start > position),
                                        leading: Text(
                                          clock(c.start),
                                          style: text.labelMedium?.copyWith(color: cs.primary, fontFeatures: const [FontFeature.tabularFigures()]),
                                        ),
                                        title: Text(c.title),
                                        onTap: () => seekTo(c.start),
                                      ),
                                  ],
                                ),
                                null => const SizedBox.shrink(),
                                _ => Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 16),
                                  child: ShowNotes(e.notes, onSeek: seekTo),
                                ),
                              },
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        // The keys drive the player, so they are this page's only while it shows what is playing.
        return current ? _keys(player: pl, onFullscreen: video == null ? null : _fullscreen, onLeave: _leave, child: page) : page;
      },
    );
  }
}

/// The seek bar; the thumb follows the finger and the player seeks on release.
class SeekBar extends StatefulWidget {
  /// One white line with the times at its ends, for laying over a picture.
  const SeekBar.overVideo({super.key, required this.position, required this.duration, required this.onSeek}) : between = null;

  /// The times sit under the line with [between] centred in the gap.
  const SeekBar.stacked({super.key, required this.position, required this.duration, required this.onSeek, required Widget this.between});
  final int position;
  final int duration;
  final void Function(int secs) onSeek;
  final Widget? between;
  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  double? drag;

  @override
  Widget build(BuildContext context) {
    final max = widget.duration > 0 ? widget.duration.toDouble() : 1.0;
    final between = widget.between, overVideo = between == null;
    final at = drag ?? widget.position.clamp(0, max).toDouble();
    final style = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()], color: overVideo ? Colors.white : null);
    final slider = Slider(
      value: at,
      max: max,
      activeColor: overVideo ? Colors.white : null,
      inactiveColor: overVideo ? Colors.white30 : null,
      onChanged: widget.duration > 0 ? (v) => setState(() => drag = v) : null,
      onChangeEnd: (v) {
        widget.onSeek(v.toInt());
        setState(() => drag = null);
      },
    );
    final now = Text(clock(at.toInt()), style: style), left = Text('-${clock(widget.duration - at.toInt())}', style: style);
    if (overVideo) {
      return Row(
        children: [
          now,
          Expanded(child: slider),
          left,
        ],
      );
    }
    return Column(
      children: [
        slider,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Expanded(
                child: Align(alignment: Alignment.centerLeft, child: now),
              ),
              between,
              Expanded(
                child: Align(alignment: Alignment.centerRight, child: left),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The picture with its controls laid over it. A tap shows or hides them; a double tap on a side skips, in the middle goes full screen.
class VideoStage extends StatefulWidget {
  const VideoStage({super.key, required this.fullscreen, required this.onFullscreen});
  final bool fullscreen;

  /// Enters full screen, or leaves it when [fullscreen].
  final VoidCallback onFullscreen;
  @override
  State<VideoStage> createState() => _VideoStageState();
}

class _VideoStageState extends State<VideoStage> {
  bool shown = true;
  Timer? _hide;
  Timer? _unflash;
  String flash = '';
  bool flashLeft = true;
  Offset _doubleTapAt = Offset.zero;

  @override
  void initState() {
    super.initState();
    _wake();
  }

  @override
  void dispose() {
    _hide?.cancel();
    _unflash?.cancel();
    super.dispose();
  }

  // Controls stay while paused and fade a few seconds after the last touch or mouse move while playing.
  void _wake() {
    _hide?.cancel();
    _hide = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => shown = false);
    });
    if (!shown) setState(() => shown = true);
  }

  void _skip({required bool back}) {
    final s = Scope.of(context);
    back ? s.player.skipBack() : s.player.skipForward();
    _unflash?.cancel();
    _unflash = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => flash = '');
    });
    setState(() {
      flashLeft = back;
      flash = back ? '−${s.lib.prefs.skipBack} s' : '+${s.lib.prefs.skipForward} s';
    });
    _wake();
  }

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    final p = s.player;
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) {
        final video = p.video;
        final e = p.episode;
        if (video == null || e == null) return const ColoredBox(color: Colors.black);
        final visible = shown || (!p.playing && !p.loading);
        Widget button(IconData icon, String tip, VoidCallback onTap, {double size = 28}) => IconButton(
          icon: Icon(icon),
          iconSize: size,
          color: Colors.white,
          tooltip: tip,
          onPressed: () {
            onTap();
            _wake();
          },
        );
        return MouseRegion(
          onHover: (_) => _wake(),
          cursor: visible ? MouseCursor.defer : SystemMouseCursors.none,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (!shown) return _wake();
              _hide?.cancel();
              setState(() => shown = false);
            },
            onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
            onDoubleTap: () {
              final w = context.size?.width ?? 0;
              if (_doubleTapAt.dx < w / 3) {
                _skip(back: true);
              } else if (_doubleTapAt.dx > w * 2 / 3) {
                _skip(back: false);
              } else {
                widget.onFullscreen();
              }
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Keyed, as Video only watches its first controller, so the next episode would lose the wakelock.
                Video(key: ObjectKey(video), controller: video, controls: NoVideoControls, wakelock: true),
                if (p.buffering)
                  const Center(
                    child: SizedBox(width: 44, height: 44, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3)),
                  ),
                if (p.error.isNotEmpty)
                  Align(
                    alignment: const Alignment(0, 0.55),
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 24),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(12)),
                      child: Text(p.error, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
                    ),
                  ),
                if (flash.isNotEmpty)
                  Align(
                    alignment: flashLeft ? const Alignment(-0.7, 0) : const Alignment(0.7, 0),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(24)),
                      child: Text(
                        flash,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16),
                      ),
                    ),
                  ),
                IgnorePointer(
                  ignoring: !visible,
                  child: AnimatedOpacity(
                    opacity: visible ? 1 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: DecoratedBox(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.black54, Colors.transparent, Colors.transparent, Colors.black87],
                          stops: [0, 0.3, 0.6, 1],
                        ),
                      ),
                      child: Stack(
                        children: [
                          if (widget.fullscreen)
                            Positioned(
                              top: 8,
                              left: 8,
                              right: 16,
                              child: SafeArea(
                                child: Row(
                                  children: [
                                    button(Icons.arrow_back_rounded, 'Leave full screen', widget.onFullscreen),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        e.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          if (flash.isEmpty && !p.buffering)
                            Center(
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  button(skipIcon(s.lib.prefs.skipBack, back: true), 'Skip back', p.skipBack, size: 36),
                                  const SizedBox(width: 20),
                                  Container(
                                    decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                                    child: button(
                                      p.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                      p.playing ? 'Pause' : 'Play',
                                      p.toggle,
                                      size: 48,
                                    ),
                                  ),
                                  const SizedBox(width: 20),
                                  button(skipIcon(s.lib.prefs.skipForward, back: false), 'Skip forward', p.skipForward, size: 36),
                                ],
                              ),
                            ),
                          Positioned(
                            left: 14,
                            right: 4,
                            bottom: 0,
                            child: SafeArea(
                              top: false,
                              child: Row(
                                children: [
                                  Expanded(
                                    child: SeekBar.overVideo(
                                      position: p.position,
                                      duration: p.duration,
                                      onSeek: (t) {
                                        p.seek(t);
                                        _wake();
                                      },
                                    ),
                                  ),
                                  PopupMenuButton<int>(
                                    tooltip: 'Speed',
                                    initialValue: p.speed,
                                    onSelected: p.setSpeed,
                                    itemBuilder: (_) => [for (final v in _speeds) PopupMenuItem(value: v, child: Text(_times(v)))],
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                                      child: Text(
                                        _times(p.speed),
                                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                                      ),
                                    ),
                                  ),
                                  button(
                                    widget.fullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
                                    widget.fullscreen ? 'Leave full screen' : 'Full screen',
                                    widget.onFullscreen,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                // Offered whether or not the controls are showing, like the end of an episode on a streaming service.
                if (p.offerNext)
                  Positioned(
                    right: 16,
                    bottom: 64,
                    child: SafeArea(
                      top: false,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
                        onPressed: p.finishToNext,
                        icon: const Icon(Icons.skip_next_rounded),
                        label: const Text('Next episode'),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// Hides the system bars on a phone and fills the monitor on a desktop; turning the phone is left to its owner.
Future<void> _nativeFullscreen({required bool on}) {
  if (isDesktop) return on ? defaultEnterNativeFullscreen() : defaultExitNativeFullscreen();
  return on
      ? SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky)
      : SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: SystemUiOverlay.values);
}

/// The picture alone on a black screen, whichever way up the device is held.
class _FullscreenVideo extends StatefulWidget {
  const _FullscreenVideo();
  @override
  State<_FullscreenVideo> createState() => _FullscreenVideoState();
}

class _FullscreenVideoState extends State<_FullscreenVideo> {
  bool leaving = false;

  /// How far the picture has been pulled down; far enough leaves full screen.
  double pull = 0;

  @override
  void initState() {
    super.initState();
    _nativeFullscreen(on: true);
  }

  @override
  void dispose() {
    _nativeFullscreen(on: false);
    super.dispose();
  }

  void _leave() {
    if (leaving) return;
    leaving = true;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final p = Scope.of(context).player;
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) {
        // What follows may be audio, or nothing: then there is no picture to stay for.
        if (p.video == null) WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _leave() : null);
        return _keys(
          player: p,
          onFullscreen: _leave,
          onLeave: _leave,
          child: Scaffold(
            backgroundColor: Colors.black,
            body: GestureDetector(
              onVerticalDragUpdate: (d) => setState(() => pull = (pull + d.delta.dy).clamp(0, double.infinity)),
              onVerticalDragEnd: (d) {
                if (pull > 80 || (pull > 20 && (d.primaryVelocity ?? 0) > 700)) return _leave();
                setState(() => pull = 0);
              },
              onVerticalDragCancel: () => setState(() => pull = 0),
              child: Transform.translate(
                offset: Offset(0, pull),
                child: VideoStage(fullscreen: true, onFullscreen: _leave),
              ),
            ),
          ),
        );
      },
    );
  }
}
