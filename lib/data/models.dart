// The library as the server sends it, kept the same in the local database.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

/// Desktops always download and have no Wi-Fi rule; streaming and Wi-Fi are phone settings.
final bool isDesktop = !kIsWeb && (Platform.isLinux || Platform.isWindows || Platform.isMacOS);

int _i(Object? v) => v is int ? v : (v is num ? v.toInt() : int.tryParse('$v') ?? 0);
double _d(Object? v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
bool _b(Object? v) => v == true || v == 1;
String _s(Object? v) => v is String ? v : (v == null ? '' : '$v');

class Channel {
  Channel(this.json);
  final Map<String, dynamic> json;
  int get id => _i(json['id']);
  String get url => _s(json['url']);
  String get kind => _s(json['kind']);
  String get title => _s(json['title']).isEmpty ? url : _s(json['title']);
  String get author => _s(json['author']);
  String get website => _s(json['website']);
  String get description => _s(json['description']);
  String get artwork => _s(json['artwork']);
  List<String> get tags => [for (final t in (json['tags'] as List? ?? const [])) '$t'];
  int get speed => _i(json['speed']) == 0 ? 100 : _i(json['speed']);
  int get skipStart => _i(json['skip_start']);
  int get skipEnd => _i(json['skip_end']);

  /// Empty follows the server's default.
  String get quality => _s(json['quality']);
  int get checkEvery => _i(json['check_every']);
  int get fetchCount => _i(json['fetch_count']);
  int get keep => _i(json['keep']);
  String get username => _s(json['username']);
  bool get private => _b(json['private']);
  DateTime? get lastChecked => _time(json['last_checked']);
  DateTime? get nextCheck => _time(json['next_check']);
  String get lastError => _s(json['last_error']);
  bool get retrieving => _b(json['retrieving']);
}

DateTime? _time(Object? v) {
  final n = _i(v);
  return n == 0 ? null : DateTime.fromMillisecondsSinceEpoch(n * 1000);
}

class Episode {
  Episode(this.json);
  final Map<String, dynamic> json;
  int get id => _i(json['id']);
  int get channelId => _i(json['channel']);
  String get mediaUrl => _s(json['media_url']);
  String get pageUrl => _s(json['page_url']);
  String get title => _s(json['title']);
  String get notes => _s(json['notes']);
  int get publishedUnix => _i(json['published']);
  DateTime? get published => _time(json['published']);
  int get duration => _i(json['duration']);
  String get media => _s(json['media']).isEmpty ? 'audio' : _s(json['media']);
  String get mime => _s(json['mime']);
  int get size => _i(json['size']);
  int get season => _i(json['season']);
  int get number => _i(json['number']);
  String get type => _s(json['type']).isEmpty ? 'full' : _s(json['type']);
  String get artwork => _s(json['artwork']);
  String get chaptersUrl => _s(json['chapters_url']);
  String get transcriptUrl => _s(json['transcript_url']);
  bool get direct => mediaUrl.isNotEmpty;

  /// Played and downloaded through the server: videos, re-encoded to the podcast's quality, and anything without its own enclosure.
  bool get streamed => !direct || media == 'video';
}

/// The listener's state of one episode, with the time each field last changed (unix ms).
class Play {
  Play(this.episode);
  Play.fromJson(Map<String, dynamic> j)
    : episode = _i(j['episode']),
      position = _i(j['position']),
      played = _b(j['played']),
      starred = _b(j['starred']),
      positionAt = _i(j['position_at']),
      playedAt = _i(j['played_at']),
      starredAt = _i(j['starred_at']);

  final int episode;
  int position = 0;
  bool played = false;
  bool starred = false;
  int positionAt = 0, playedAt = 0, starredAt = 0;

  bool get inProgress => position > 0 && !played;

  Map<String, dynamic> toJson() => {
    'episode': episode,
    'position': position,
    'played': played,
    'starred': starred,
    'position_at': positionAt,
    'played_at': playedAt,
    'starred_at': starredAt,
  };

  /// Applies one change the same way the server does: latest wins per field, and a played or unplayed mark wipes the position.
  bool apply(PlayChange c) {
    switch (c.field) {
      case 'position':
        if (c.at <= positionAt || (played && c.at <= playedAt)) return false;
        position = c.position;
        positionAt = c.at;
        if (played && c.position > 0) {
          played = false;
          playedAt = c.at;
        }
      case 'played':
        if (c.at <= playedAt) return false;
        played = c.value;
        playedAt = c.at;
        position = 0;
        positionAt = c.at;
      case 'starred':
        if (c.at <= starredAt) return false;
        starred = c.value;
        starredAt = c.at;
      default:
        return false;
    }
    return true;
  }
}

class PlayChange {
  PlayChange({required this.episode, required this.field, this.position = 0, this.value = false, required this.at});
  PlayChange.fromJson(Map<String, dynamic> j)
    : episode = _i(j['episode']),
      field = _s(j['field']),
      position = _i(j['position']),
      value = _b(j['value']),
      at = _i(j['at']);
  final int episode;
  final String field;
  final int position;
  final bool value;
  final int at;
  Map<String, dynamic> toJson() => {'episode': episode, 'field': field, 'position': position, 'value': value, 'at': at};
}

class Playlist {
  Playlist(this.json);
  final Map<String, dynamic> json;
  int get id => _i(json['id']);
  String get name => _s(json['name']);
  String get filter => _s(json['filter']);
  String get sort => _s(json['sort']).isEmpty ? 'newest' : _s(json['sort']);
  double get pos => _d(json['pos']);
  String get builtin => _s(json['builtin']);
  bool get autoplay => _b(json['autoplay']);

  /// Lists only unplayed episodes; the played ones are still in the playlist.
  bool get hidePlayed => _b(json['hide_played']);

  /// Fixes the shuffled order: the playlist's own id until it is reshuffled.
  int get seed => _i(json['seed']) == 0 ? id : _i(json['seed']);
}

class Prefs {
  Prefs(this.json);
  final Map<String, dynamic> json;
  String get timeZone => _s(json['time_zone']);
  int get skipBack => _i(json['skip_back']) == 0 ? 10 : _i(json['skip_back']);
  int get skipForward => _i(json['skip_forward']) == 0 ? 30 : _i(json['skip_forward']);
  int get nextAt => _i(json['next_at']) == 0 ? 5 : _i(json['next_at']);
  String get theme => _s(json['theme']).isEmpty ? 'system' : _s(json['theme']);

  /// A speed changed while playing becomes the podcast's own, on every device.
  bool get rememberSpeed => _b(json['remember_speed']);
}

class PlaylistDevice {
  const PlaylistDevice({required this.download, required this.count, required this.oldest});
  final bool download;
  final int count;
  final bool oldest;
}

/// This device's download settings, kept only in its own database.
class DeviceSettings {
  DeviceSettings(this.json);
  final Map<String, dynamic> json;
  int get storageMb => _i(json['storage_mb']);
  bool get wifiOnly => !isDesktop && (json['wifi_only'] == null || _b(json['wifi_only']));
  bool get wifiOnlySaved => json['wifi_only'] == null || _b(json['wifi_only']);
  String get deleteAfter => _s(json['delete_after']).isEmpty ? '1d' : _s(json['delete_after']);

  /// Nothing downloads by itself, for a hotspot or roaming; a tap on Download still does.
  bool get downloadsPaused => _b(json['downloads_paused']);

  DeviceSettings withPaused(bool paused) => DeviceSettings({...json, 'downloads_paused': paused});

  /// A video plays on, as sound, when the app goes to the background.
  bool get videoInBackground => _b(json['video_background']);

  /// Full screen turns the phone sideways for a video wider than it is tall.
  bool get videoLandscape => _b(json['video_landscape']);

  DeviceSettings withVideo({required bool background, required bool landscape}) =>
      DeviceSettings({...json, 'video_background': background, 'video_landscape': landscape});

  /// Playlists not set to download are streamed.
  PlaylistDevice forPlaylist(int id) {
    final m = (json['playlists'] as Map?)?['$id'];
    if (m is! Map) return const PlaylistDevice(download: false, count: 0, oldest: false);
    final count = _i(m['count']);
    return PlaylistDevice(download: m['mode'] == 'download' && count > 0, count: count, oldest: m['from'] == 'oldest');
  }

  DeviceSettings withGeneral({required int storageMb, required bool wifiOnly, required String deleteAfter}) =>
      DeviceSettings({...json, 'storage_mb': storageMb, 'wifi_only': wifiOnly, 'delete_after': deleteAfter});

  DeviceSettings withPlaylist(int id, PlaylistDevice pd) => DeviceSettings({
    ...json,
    'playlists': {
      ...?(json['playlists'] as Map?),
      '$id': {'mode': pd.download ? 'download' : 'stream', 'count': pd.count, 'from': pd.oldest ? 'oldest' : 'newest'},
    },
  });
}
