import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:podcasts/filter/filter.dart';

// Checks the shared examples that the Go implementation is also checked against.
void main() {
  final ex = jsonDecode(File('test/examples.json').readAsStringSync()) as Map<String, dynamic>;
  final envJ = ex['env'] as Map<String, dynamic>;
  final names = <String, String>{};
  final tags = <String, List<String>>{};
  final channels = <FilterOption>[];
  for (final c in envJ['channels'] as List) {
    channels.add(FilterOption(c['id'], c['label']));
    names[c['id']] = c['label'];
    tags[c['id']] = List<String>.from(c['tags']);
  }
  final env = FilterEnv(
    now: DateTime.parse(envJ['now']),
    utc: envJ['zone'] == 'UTC',
    channels: channels,
  );
  final ids = <String>[];
  final items = <FilterItem>[];
  for (final e in ex['episodes'] as List) {
    ids.add(e['id']);
    items.add(
      FilterItem(
        title: e['title'],
        channel: e['channel'],
        channelName: names[e['channel']]!,
        length: e['length'] ?? 0,
        published: e['published'] == null ? 0 : DateTime.parse(e['published']).millisecondsSinceEpoch ~/ 1000,
        media: e['media'] ?? 'audio',
        season: e['season'] ?? 0,
        number: e['number'] ?? 0,
        type: e['type'] ?? '',
        inPlaylist: e['inPlaylist'] ?? false,
        position: e['position'] ?? 0,
        played: e['played'] ?? false,
        starred: e['starred'] ?? false,
        downloaded: e['downloaded'] ?? false,
        tags: tags[e['channel']]!,
      ),
    );
  }
  for (final m in ex['matches'] as List) {
    test('match ${m['filter']}', () {
      final r = parseFilter(m['filter'], env);
      expect(r.error, isNull, reason: r.error.toString());
      final got = [
        for (var i = 0; i < items.length; i++)
          if (r.filter!.match(items[i])) ids[i],
      ];
      expect(got, List<String>.from(m['ids']));
    });
  }
  for (final e in ex['errors'] as List) {
    test('error ${e['filter']}', () {
      final r = parseFilter(e['filter'], env);
      expect(r.error?.msg, e['message']);
      expect(r.error?.pos, e['pos']);
    });
  }
  for (final s in ex['stored'] as List) {
    test('stored ${s['display']}', () {
      expect(toStored(s['display'], env).$1, s['stored']);
      expect(toDisplay(s['stored'], env), s['shown']);
    });
  }
}
