// Podcasts: following channels, their settings, tags and OPML.
library;

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../data/api.dart';
import '../data/models.dart';
import 'library_screens.dart';
import 'parts.dart';
import 'widgets.dart';

Future<void> _readBack(BuildContext context, Channel c) async {
  final s = Scope.of(context);
  final depth = TextEditingController(text: '1000');
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Read further back'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: depth,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'How many episodes (up to 5000)'),
          ),
          const SizedBox(height: 12),
          const Text(
            'Runs once as its own job. Episodes beyond "Keep in the database" are still dropped afterwards, so raise that first if you want them all.',
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Read')),
      ],
    ),
  );
  if (ok == true && context.mounted) {
    await s.act(
      context,
      (api) => api.post('/channels/${c.id}/readback', {'depth': int.tryParse(depth.text) ?? 1000}),
      done: 'Reading further back. See Status.',
    );
  }
}

/// Asks, then unfollows; true when the podcast is gone.
Future<bool> _unfollow(BuildContext context, Channel c) async {
  final s = Scope.of(context);
  if (!await confirm(context, 'Unfollow ${c.title}? Its episodes and play states are removed; playlists are kept.') || !context.mounted) return false;
  return s.act(context, (api) => api.delete('/channels/${c.id}'));
}

Future<void> _markAllPlayed(BuildContext context, Channel c) {
  final s = Scope.of(context);
  return s.player.setPlayed(s.lib.episodes.where((e) => e.channelId == c.id).map((e) => e.id), true);
}

/// Asks for the playlist's name, offering the tag's own, then creates it.
Future<void> _makeTagPlaylist(BuildContext context, String tag) async {
  final s = Scope.of(context);
  final suggested = tag[0].toUpperCase() + tag.substring(1);
  final name = TextEditingController(text: suggested)..selection = TextSelection(baseOffset: 0, extentOffset: suggested.length);
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Make a playlist'),
      content: TextField(
        controller: name,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(labelText: 'Name', helperText: 'Every episode tagged #$tag'),
        onSubmitted: (_) => Navigator.pop(c, true),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('OK')),
      ],
    ),
  );
  final chosen = name.text.trim();
  if (ok != true || chosen.isEmpty || !context.mounted) return;
  await s.act(context, (api) => api.post('/playlists', {'name': chosen, 'filter': '#$tag', 'sort': 'newest', 'hide_played': true}), done: 'Playlist created');
}

class PodcastsScreen extends StatefulWidget {
  const PodcastsScreen({super.key, required this.reset});
  final Listenable reset;
  @override
  State<PodcastsScreen> createState() => _PodcastsScreenState();
}

class _PodcastsScreenState extends State<PodcastsScreen> {
  String tag = '';
  final find = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.reset.addListener(_reset);
  }

  @override
  void dispose() {
    widget.reset.removeListener(_reset);
    find.dispose();
    super.dispose();
  }

  void _reset() => setState(() {
    find.clear();
    tag = '';
  });

  Future<void> _opml(String v) async {
    final s = Scope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    if (v == 'export') {
      try {
        final r = await s.api.get('/opml') as Map;
        final text = '${r['opml']}';
        var saved = false;
        if (isDesktop) {
          final at = await getSaveLocation(suggestedName: 'podcasts.opml');
          if (at != null) {
            await File(at.path).writeAsString(text);
            saved = true;
          }
        } else {
          // Android and iOS show their own "save to" picker, so the file lands where the user chooses.
          saved = await const MethodChannel('rpodcasts/files').invokeMethod<bool>('save', {'name': 'podcasts.opml', 'text': text}) ?? false;
        }
        if (saved) messenger.showSnackBar(const SnackBar(content: Text('OPML exported')));
      } on Object catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('$e')));
      }
      return;
    }
    final text = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Import OPML'),
        content: TextField(
          controller: text,
          maxLines: 10,
          decoration: const InputDecoration(hintText: 'Paste the OPML file here'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Import')),
        ],
      ),
    );
    if (ok == true && mounted) {
      await s.act(context, (api) => api.post('/opml', {'opml': text.text}), done: 'Imported. The feeds are being read now.');
    }
  }

  void _menu(Channel c) {
    final s = Scope.of(context);
    final n = s.lib.unplayed(c.id);
    showActionSheet(
      context,
      header: ListTile(
        leading: Artwork(c.artwork, size: 52, video: c.kind == 'video'),
        title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleMedium),
        subtitle: Text(n == 0 ? 'All caught up' : '$n to play'),
      ),
      actions: [
        SheetAction(
          icon: Icons.refresh_rounded,
          label: 'Check now',
          run: () => s.act(context, (api) => api.post('/channels/${c.id}/check'), done: 'Checking now'),
        ),
        SheetAction(icon: Icons.done_all_rounded, label: 'Mark all played', run: () => _markAllPlayed(context, c)),
        SheetAction(
          icon: Icons.tune_rounded,
          label: 'Settings',
          run: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChannelSettingsScreen(c))),
        ),
        SheetAction(icon: Icons.history_rounded, label: 'Read further back', run: () => _readBack(context, c)),
        SheetAction(icon: Icons.remove_circle_outline_rounded, label: 'Unfollow', danger: true, run: () => _unfollow(context, c)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: s.lib,
      builder: (context, _) {
        final all = s.lib.channels.values.toList();
        final tags = s.lib.allTags;
        final q = find.text.trim().toLowerCase();
        final shown = all.where((c) => (tag.isEmpty || c.tags.contains(tag)) && (q.isEmpty || c.title.toLowerCase().contains(q))).toList()..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
        return Scaffold(
          appBar: rootBar(
            context,
            'Podcasts',
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh_rounded),
                tooltip: 'Check all now',
                onPressed: () => s.act(context, (api) => api.post('/checkall'), done: 'Checking every podcast. See Status.'),
              ),
              PopupMenuButton<String>(
                onSelected: (v) => v == 'tags' ? Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TagsScreen())) : _opml(v),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'tags', child: Text('Tags')),
                  PopupMenuItem(value: 'import', child: Text('Import OPML')),
                  PopupMenuItem(value: 'export', child: Text('Export OPML')),
                ],
              ),
              IconButton.filledTonal(
                icon: const Icon(Icons.add_rounded),
                tooltip: 'Add a podcast',
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => AddChannelScreen(tag: tag))),
              ),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: s.sync.syncNow,
            child: CustomScrollView(
              slivers: [
                if (all.isNotEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                      child: TextField(
                        controller: find,
                        onChanged: (_) => setState(() {}),
                        textInputAction: TextInputAction.search,
                        decoration: InputDecoration(
                          hintText: 'Find a podcast',
                          prefixIcon: const Icon(Icons.search_rounded),
                          suffixIcon: q.isEmpty
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.close_rounded),
                                  tooltip: 'Clear',
                                  onPressed: () => setState(find.clear),
                                ),
                          isDense: true,
                          border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(24))),
                        ),
                      ),
                    ),
                  ),
                if (tags.isNotEmpty)
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: 48,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        children: [
                          for (final t in ['', ...tags])
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              child: ChoiceChip(label: Text(t.isEmpty ? 'All' : '#$t'), selected: tag == t, onSelected: (_) => setState(() => tag = t)),
                            ),
                          if (tag.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              child: ActionChip(
                                avatar: const Icon(Icons.playlist_add_rounded, size: 18),
                                label: const Text('Make a playlist'),
                                onPressed: () => _makeTagPlaylist(context, tag),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                if (shown.isEmpty && q.isNotEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: EmptyState(icon: Icons.search_off_rounded, title: 'No podcast matches', body: 'Try fewer letters, or pick All.'),
                  )
                else if (shown.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: EmptyState(
                      icon: Icons.podcasts_rounded,
                      title: 'Nothing followed here yet',
                      body: 'Search for a podcast, or add one by its address, with the + button.',
                    ),
                  ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  sliver: SliverGrid(
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 180,
                      mainAxisSpacing: 16,
                      crossAxisSpacing: 14,
                      childAspectRatio: 0.76,
                    ),
                    delegate: SliverChildBuilderDelegate(childCount: shown.length, (context, i) {
                      final c = shown[i];
                      final n = s.lib.unplayed(c.id);
                      final note = c.retrieving ? 'Being retrieved…' : (c.lastError.isNotEmpty ? "Can't be read" : (n == 0 ? 'All caught up' : '$n to play'));
                      return InkWell(
                        borderRadius: BorderRadius.circular(18),
                        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChannelScreen(c.id))),
                        onLongPress: () => _menu(c),
                        onSecondaryTap: () => _menu(c),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // The artwork takes what the title leaves, so larger text never overflows the tile.
                            Expanded(
                              child: Align(
                                alignment: Alignment.topLeft,
                                child: AspectRatio(
                                  aspectRatio: 1,
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      LayoutBuilder(
                                        builder: (_, box) => Artwork(c.artwork, size: box.maxWidth, video: c.kind == 'video'),
                                      ),
                                      if (n > 0)
                                        Positioned(
                                          top: 8,
                                          right: 8,
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                            decoration: BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(12)),
                                            child: Text(
                                              '$n',
                                              style: text.labelSmall?.copyWith(color: cs.onPrimary, fontWeight: FontWeight.w700),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.titleSmall),
                            Text(
                              note,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: text.bodySmall?.copyWith(color: c.lastError.isNotEmpty ? cs.error : null),
                            ),
                          ],
                        ),
                      );
                    }),
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

class AddChannelScreen extends StatefulWidget {
  const AddChannelScreen({super.key, this.tag = ''});
  final String tag;
  @override
  State<AddChannelScreen> createState() => _AddChannelScreenState();
}

class _AddChannelScreenState extends State<AddChannelScreen> {
  final url = TextEditingController();
  late final tags = TextEditingController(text: widget.tag);
  final user = TextEditingController();
  final pass = TextEditingController();
  final term = TextEditingController();
  final name = TextEditingController();
  bool private = false;
  bool manual = false;
  bool busy = false;
  String error = '';

  /// The address being read for its preview, so its row can show it.
  String checking = '';

  /// Null until a search has answered.
  List<Map<String, dynamic>>? found;

  /// What the server found at the address; the page shows it with the tags until it is followed or closed.
  Map<String, dynamic>? preview;

  /// The address and sign-in the preview was read with, which Follow sends again.
  Map<String, String> asked = {};

  /// Reads an address on the server and shows what it holds; [known] is what a search already said about it.
  Future<void> _check(Map<String, String> address, {Map<String, dynamic>? known}) async {
    if (busy || address['url']!.trim().isEmpty) return;
    final api = Scope.of(context).api;
    setState(() {
      busy = true;
      error = '';
      checking = address['url']!;
    });
    try {
      Map<String, dynamic> p;
      try {
        p = (await api.post('/preview', address) as Map).cast<String, dynamic>();
      } on ApiError catch (e) {
        // A server from before previews: show what is known and follow the old way.
        if (e.status != 404 && e.status != 405) rethrow;
        p = {'title': address['url'], ...?known, 'url': address['url'], 'unchecked': true};
      }
      if (!mounted) return;
      setState(() {
        preview = p;
        asked = address;
        name.text = p['unchecked'] == true ? '' : '${p['title'] ?? ''}';
      });
    } on Object catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          checking = '';
        });
      }
    }
  }

  Future<void> _follow() async {
    final unchecked = preview?['unchecked'] == true;
    final ok = await Scope.of(context).act(
      context,
      (api) => api.post(unchecked ? '/channels' : '/follow', {...asked, 'title': name.text.trim(), 'tags': tags.text}),
      done: 'Following. The first read is running.',
    );
    if (ok && mounted) Navigator.pop(context);
  }

  Future<void> _search() async {
    final q = term.text.trim();
    if (q.isEmpty || busy) return;
    final api = Scope.of(context).api;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final r = await api.get('/directory', {'q': q}) as Map;
      if (!mounted) return;
      setState(() => found = [for (final f in r['results'] as List) (f as Map).cast<String, dynamic>()]);
    } on Object catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void _checkManual() => _check({'url': url.text, if (private) 'username': user.text, if (private) 'password': pass.text});

  static const _spinner = SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.5));

  List<Widget> _preview(BuildContext context, Map<String, dynamic> p) {
    final s = Scope.of(context);
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final episodes = p['episodes'] is int ? p['episodes'] as int : 0;
    final media = switch (p['media']) {
      'audio' => 'Audio',
      'video' => 'Video',
      'mixed' => 'Audio and video',
      _ => '',
    };
    final author = '${p['author'] ?? ''}';
    final description = '${p['description'] ?? ''}'.trim();
    final following = p['following'] is int && p['following'] != 0;
    return [
      Section(
        title: '',
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Artwork('${p['artwork'] ?? ''}', size: 88),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${p['title']}', maxLines: 3, overflow: TextOverflow.ellipsis, style: text.titleMedium),
                      const SizedBox(height: 4),
                      Text(
                        [if (author.isNotEmpty) author, if (episodes > 0) '$episodes episodes', if (media.isNotEmpty) media].join(' · '),
                        style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${p['url']}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(color: cs.outline),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text(
                description,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
        ],
      ),
      if (following)
        const Notice(icon: Icons.check_circle_outline_rounded, text: 'You already follow this podcast.', error: false)
      else
        FieldGroup(
          title: '',
          children: [
            if (p['unchecked'] != true)
              TextField(
                controller: name,
                textCapitalization: TextCapitalization.sentences,
                maxLength: 200,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  helperText: "Change it if the address's own name doesn't say what this is",
                  counterText: '',
                ),
              ),
            TagField(controller: tags, all: s.lib.allTags, helper: 'Pick one or type a new one'),
          ],
        ),
    ];
  }

  List<Widget> _manual() => [
    FieldGroup(
      title: '',
      children: [
        TextField(
          controller: url,
          autofocus: true,
          keyboardType: TextInputType.url,
          autocorrect: false,
          textInputAction: TextInputAction.next,
          onSubmitted: (_) => _checkManual(),
          decoration: const InputDecoration(
            labelText: 'Address',
            hintText: 'https://…',
            helperText: "A feed, a podcast's website or a page of videos",
            helperMaxLines: 2,
            prefixIcon: Icon(Icons.link_rounded),
          ),
        ),
      ],
    ),
    Section(
      title: '',
      children: [
        SwitchListTile(
          title: const Text('Private feed'),
          subtitle: const Text('Needs a user name and password'),
          value: private,
          onChanged: (v) => setState(() => private = v),
        ),
      ],
    ),
    if (private)
      FieldGroup(
        title: 'Sign-in for the feed',
        children: [
          TextField(
            controller: user,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'User name'),
          ),
          TextField(
            controller: pass,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Password'),
          ),
        ],
      ),
    if (error.isNotEmpty) Notice(icon: Icons.error_outline_rounded, text: error, error: true),
  ];

  List<Widget> _searchTab(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final results = found;
    return [
      TextField(
        controller: term,
        autofocus: true,
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => _search(),
        decoration: InputDecoration(
          labelText: 'Podcast',
          hintText: 'A title or an author',
          helperText: "Searches Apple's podcast directory through your server",
          prefixIcon: const Icon(Icons.search_rounded),
          suffixIcon: busy && checking.isEmpty
              ? const Padding(padding: EdgeInsets.all(14), child: _spinner)
              : IconButton(tooltip: 'Search', icon: const Icon(Icons.arrow_forward_rounded), onPressed: _search),
        ),
      ),
      const SizedBox(height: 20),
      if (error.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Notice(icon: Icons.error_outline_rounded, text: error, error: true),
        ),
      if (results != null && results.isEmpty)
        const EmptyState(icon: Icons.search_off_rounded, title: 'Nothing found', body: 'Try fewer words, or add it by its address under Manual.')
      else if (results != null)
        Section(
          title: '',
          children: [
            for (final f in results)
              ListTile(
                leading: Artwork('${f['artwork']}'),
                title: Text('${f['title']}', maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  [if ('${f['author']}'.isNotEmpty) '${f['author']}', if (f['episodes'] != 0) '${f['episodes']} episodes'].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall,
                ),
                trailing: checking == f['url'] ? _spinner : const Icon(Icons.chevron_right_rounded),
                enabled: !busy || checking == f['url'],
                onTap: () => _check({'url': '${f['url']}'}, known: f),
              ),
          ],
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final p = preview;
    final following = p != null && p['following'] is int && p['following'] != 0;
    return PopScope(
      canPop: p == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => preview = null);
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Add a podcast')),
        bottomNavigationBar: p != null
            ? (following ? null : SaveBar(label: 'Follow', onPressed: _follow))
            : (manual ? SaveBar(label: busy ? 'Reading the address…' : 'Next', onPressed: busy ? null : _checkManual) : null),
        body: Readable(
          builder: (context, inset) => ListView(
            padding: EdgeInsets.fromLTRB(16 + inset, 8, 16 + inset, 24),
            children: [
              if (p != null)
                ..._preview(context, p)
              else ...[
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: false, icon: Icon(Icons.search_rounded), label: Text('Search')),
                    ButtonSegment(value: true, icon: Icon(Icons.link_rounded), label: Text('Manual')),
                  ],
                  selected: {manual},
                  onSelectionChanged: busy
                      ? null
                      : (v) => setState(() {
                          manual = v.first;
                          error = '';
                        }),
                ),
                const SizedBox(height: 20),
                if (manual) ..._manual() else ..._searchTab(context),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class ChannelScreen extends StatefulWidget {
  const ChannelScreen(this.id, {super.key});
  final int id;
  @override
  State<ChannelScreen> createState() => _ChannelScreenState();
}

class _ChannelScreenState extends State<ChannelScreen> with EpisodePicker {
  bool more = false;

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: s.lib,
      builder: (context, _) {
        final c = s.lib.channels[widget.id];
        if (c == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const EmptyState(icon: Icons.podcasts_rounded, title: 'Not followed any more', body: 'This podcast was unfollowed.'),
          );
        }
        final eps = s.lib.episodes.where((e) => e.channelId == widget.id).toList();
        final n = s.lib.unplayed(widget.id);
        final page = Scaffold(
          appBar: picking
              ? pickingBar(eps.map((e) => e.id))
              : AppBar(
                  actions: [
                    IconButton(
                      icon: const Icon(Icons.refresh_rounded),
                      tooltip: 'Check now',
                      onPressed: () => s.act(context, (api) => api.post('/channels/${c.id}/check'), done: 'Checking now'),
                    ),
                    IconButton(
                      icon: const Icon(Icons.tune_rounded),
                      tooltip: 'Settings',
                      onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChannelSettingsScreen(c))),
                    ),
                    PopupMenuButton<String>(
                      onSelected: (v) async {
                        switch (v) {
                          case 'back':
                            await _readBack(context, c);
                          case 'select':
                            startPicking();
                          case 'played':
                            await _markAllPlayed(context, c);
                          case 'unfollow':
                            if (await _unfollow(context, c) && context.mounted) Navigator.pop(context);
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'select', child: Text('Select episodes')),
                        PopupMenuItem(value: 'back', child: Text('Read further back')),
                        PopupMenuItem(value: 'played', child: Text('Mark all played')),
                        PopupMenuItem(value: 'unfollow', child: Text('Unfollow')),
                      ],
                    ),
                  ],
                ),
          body: Readable(
            builder: (context, inset) => ListView.builder(
              padding: EdgeInsets.fromLTRB(inset, 0, inset, 24),
              itemCount: eps.length + 1,
              itemBuilder: (context, i) {
                if (i > 0) return pickTile(eps[i - 1], from: '', channelArt: false);
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Artwork(c.artwork, size: 112, video: c.kind == 'video'),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(c.title, style: text.headlineSmall?.copyWith(fontSize: 22, height: 1.15), maxLines: 3, overflow: TextOverflow.ellipsis),
                                if (c.author.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text(
                                      c.author,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: text.bodyMedium?.copyWith(color: cs.primary),
                                    ),
                                  ),
                                const SizedBox(height: 4),
                                Text('${eps.length} episodes · ${n == 0 ? 'all caught up' : '$n to play'}', style: text.bodySmall),
                              ],
                            ),
                          ),
                        ],
                      ),
                      if (c.tags.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final t in c.tags)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(color: cs.secondaryContainer, borderRadius: BorderRadius.circular(12)),
                                  child: Text('#$t', style: text.labelMedium?.copyWith(color: cs.onSecondaryContainer)),
                                ),
                            ],
                          ),
                        ),
                      if (c.retrieving)
                        const Padding(
                          padding: EdgeInsets.only(top: 12),
                          child: Notice(icon: Icons.sync_rounded, text: 'Being retrieved…', error: false),
                        ),
                      if (c.lastError.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Notice(icon: Icons.error_outline_rounded, text: 'The last read failed: ${c.lastError}', error: true),
                        ),
                      if (c.description.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            plainText(c.description),
                            maxLines: more ? null : 3,
                            overflow: more ? null : TextOverflow.ellipsis,
                            style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                          ),
                        ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                          onPressed: () => setState(() => more = !more),
                          child: Text(more ? 'Less' : 'More about this podcast'),
                        ),
                      ),
                      if (more)
                        Section(
                          title: '',
                          children: [
                            _fact('Address', c.url),
                            if (c.website.isNotEmpty) _fact('Website', c.website),
                            _fact('Last checked', ago(c.lastChecked)),
                            _fact('Next check', ago(c.nextCheck)),
                            _fact('Check every', c.checkEvery > 0 ? '${c.checkEvery} min' : 'server default'),
                            _fact('Fetch', c.fetchCount > 0 ? 'newest ${c.fetchCount}' : 'server default'),
                            _fact('Keep', c.keep > 0 ? 'newest ${c.keep}' : 'server default'),
                          ],
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        );
        return whilePicking(page);
      },
    );
  }

  Widget _fact(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 110, child: Text(k, style: Theme.of(context).textTheme.bodySmall)),
        Expanded(child: SelectableText(v, style: Theme.of(context).textTheme.bodyMedium)),
      ],
    ),
  );
}

class ChannelSettingsScreen extends StatefulWidget {
  const ChannelSettingsScreen(this.c, {super.key});
  final Channel c;
  @override
  State<ChannelSettingsScreen> createState() => _ChannelSettingsScreenState();
}

class _ChannelSettingsScreenState extends State<ChannelSettingsScreen> {
  late final c = widget.c;
  late final title = TextEditingController(text: c.title);
  late final tags = TextEditingController(text: c.tags.join(' '));
  late final speed = TextEditingController(text: '${c.speed}');
  late final skipStart = TextEditingController(text: '${c.skipStart}');
  late final skipEnd = TextEditingController(text: '${c.skipEnd}');
  late final every = TextEditingController(text: c.checkEvery > 0 ? '${c.checkEvery}' : '');
  late final fetch = TextEditingController(text: c.fetchCount > 0 ? '${c.fetchCount}' : '');
  late final keep = TextEditingController(text: c.keep > 0 ? '${c.keep}' : '');
  late final user = TextEditingController(text: c.username);
  final pass = TextEditingController();
  late String quality = c.quality;

  Future<void> _save() async {
    final ok = await Scope.of(context).act(
      context,
      (api) => api.post('/channels/${c.id}/settings', {
        'title': title.text,
        'tags': tags.text,
        'speed': speed.text,
        'skip_start': skipStart.text,
        'skip_end': skipEnd.text,
        'quality': quality,
        'check_every': every.text,
        'fetch_count': fetch.text,
        'keep': keep.text,
        'username': user.text,
        'password': pass.text,
      }),
      done: 'Saved',
    );
    if (ok && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Podcast settings')),
      bottomNavigationBar: SaveBar(label: 'Save', onPressed: _save),
      body: Readable(
        builder: (context, inset) => ListView(
          padding: EdgeInsets.fromLTRB(16 + inset, 8, 16 + inset, 24),
          children: [
            FieldGroup(
              title: '',
              children: [
                TextField(
                  controller: title,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                TagField(controller: tags, all: s.lib.allTags, helper: 'Pick one or type a new one'),
              ],
            ),
            Section(
              title: 'Playback',
              children: [
                NumberRow(label: 'Speed', controller: speed, unit: '%', hint: '100', enabled: true),
                NumberRow(label: 'Skip the first', controller: skipStart, unit: 's', hint: '0', enabled: true),
                NumberRow(label: 'Skip the last', controller: skipEnd, unit: 's', hint: '0', enabled: true),
                if (c.kind == 'video' || s.lib.episodes.any((e) => e.channelId == c.id && e.media == 'video'))
                  ChoiceRow<String>(
                    label: 'Quality',
                    value: quality,
                    options: const [('', 'Default'), ('audio', 'Audio only'), ('480', '480p'), ('720', '720p'), ('1080', '1080p')],
                    onChanged: (v) => setState(() => quality = v),
                  ),
              ],
            ),
            Section(
              title: 'Reading the feed',
              footer: 'Empty uses the default from Settings → Server defaults.',
              children: [
                NumberRow(label: 'Check every', controller: every, unit: 'min', hint: 'default', enabled: true),
                NumberRow(label: 'How many to fetch', controller: fetch, unit: '', hint: 'default', enabled: true),
                NumberRow(label: 'Keep in the database', controller: keep, unit: '', hint: 'default', enabled: true),
              ],
            ),
            FieldGroup(
              title: 'Private feed',
              children: [
                TextField(
                  controller: user,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: 'User name'),
                ),
                TextField(
                  controller: pass,
                  obscureText: true,
                  decoration: InputDecoration(labelText: 'Password', hintText: c.private ? 'unchanged' : ''),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class TagsScreen extends StatelessWidget {
  const TagsScreen({super.key});

  Future<void> _rename(BuildContext context, String t) async {
    final s = Scope.of(context);
    final to = TextEditingController(text: t);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Rename #$t'),
        content: TextField(controller: to, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Rename')),
        ],
      ),
    );
    if (ok == true && context.mounted) await s.act(context, (api) => api.post('/tags/rename', {'from': t, 'to': to.text}), done: 'Renamed');
  }

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: s.lib,
      builder: (context, _) {
        final tags = <String, List<Channel>>{};
        for (final c in s.lib.channels.values) {
          for (final t in c.tags) {
            tags.putIfAbsent(t, () => []).add(c);
          }
        }
        final names = tags.keys.toList()..sort();
        return Scaffold(
          appBar: AppBar(title: const Text('Tags')),
          body: names.isEmpty
              ? const EmptyState(icon: Icons.sell_outlined, title: 'No tags yet', body: 'Add them when following a podcast, or in its settings.')
              : Readable(
                  builder: (context, inset) => ListView(
                    padding: EdgeInsets.fromLTRB(16 + inset, 8, 16 + inset, 24),
                    children: [
                      Section(
                        title: '',
                        children: [
                          for (final t in names)
                            ListTile(
                              leading: CircleAvatar(
                                backgroundColor: cs.secondaryContainer,
                                child: Icon(Icons.sell_outlined, size: 18, color: cs.onSecondaryContainer),
                              ),
                              title: Text('#$t'),
                              subtitle: Text(
                                [
                                  tags[t]!.map((c) => c.title).join(', '),
                                  s.lib.playlists.where((p) => RegExp('#${RegExp.escape(t)}\\b').hasMatch(p.filter)).map((p) => '▸ ${p.name}').join(', '),
                                ].where((x) => x.isNotEmpty).join('\n'),
                              ),
                              trailing: PopupMenuButton<String>(
                                onSelected: (v) => v == 'playlist' ? _makeTagPlaylist(context, t) : _rename(context, t),
                                itemBuilder: (_) => const [
                                  PopupMenuItem(value: 'rename', child: Text('Rename')),
                                  PopupMenuItem(value: 'playlist', child: Text('Make a playlist')),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
        );
      },
    );
  }
}
