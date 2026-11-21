// The episode filter language, kept identical to the server's and checked against test/examples.json, a copy of the server's examples.
library;

class FilterOption {
  const FilterOption(this.id, this.label);
  final String id;
  final String label;
}

/// Everything a filter needs besides the episode. [utc] chooses UTC days; otherwise the device's local time zone.
class FilterEnv {
  const FilterEnv({required this.now, this.utc = false, this.channels = const [], this.forbidDownloaded = false});
  final DateTime now;
  final bool utc;
  final List<FilterOption> channels;
  final bool forbidDownloaded;

  FilterEnv copyWith({bool? forbidDownloaded}) =>
      FilterEnv(now: now, utc: utc, channels: channels, forbidDownloaded: forbidDownloaded ?? this.forbidDownloaded);
}

/// One episode as the filter sees it; zero length, published, season and number mean missing.
class FilterItem {
  FilterItem({
    required this.title,
    required this.channel,
    required this.channelName,
    this.length = 0,
    this.published = 0,
    this.media = 'audio',
    this.season = 0,
    this.number = 0,
    this.type = 'full',
    this.inPlaylist = false,
    this.position = 0,
    this.played = false,
    this.starred = false,
    this.downloaded = false,
    this.tags = const [],
  });
  final String title;
  final String channel;
  final String channelName;
  final int length;
  final int published;
  final String media;
  final int season;
  final int number;
  final String type;
  bool inPlaylist;
  final int position;
  final bool played;
  final bool starred;
  final bool downloaded;
  final List<String> tags;
}

class FilterError {
  const FilterError(this.pos, this.msg);
  final int pos;
  final String msg;
  @override
  String toString() => '$msg (at ${pos + 1})';
}

class Span {
  const Span(this.start, this.end, this.kind, this.id);
  final int start;
  final int end;
  final String kind;
  final String id;
}

class Filter {
  _Node? _root;
  final List<Span> spans = [];
  bool usesPlaylist = false;
  bool usesDownloaded = false;

  bool match(FilterItem it) => _root == null || _root!.eval(it);
}

/// The result of [parseFilter]: exactly one of [filter] and [error] is set.
class ParseResult {
  const ParseResult.ok(Filter this.filter) : error = null;
  const ParseResult.err(FilterError this.error) : filter = null;
  final Filter? filter;
  final FilterError? error;
}

class _Fail implements Exception {
  _Fail(this.error);
  final FilterError error;
}

enum _Kind { text, choice, duration, dateTime, number }

class _Key {
  const _Key(this.name, this.kind, this.options);
  final String name;
  final _Kind kind;
  final List<FilterOption> options;
}

const _boolKeys = ['unplayed', 'played', 'inprogress', 'starred', 'downloaded', 'playlist'];
const _mediaOptions = [FilterOption('audio', 'audio'), FilterOption('video', 'video')];
const _typeOptions = [FilterOption('full', 'full'), FilterOption('trailer', 'trailer'), FilterOption('bonus', 'bonus')];

_Key? _key(FilterEnv e, String name) {
  switch (name) {
    case 'title':
      return const _Key('title', _Kind.text, []);
    case 'title.length' || 'season' || 'number':
      return _Key(name, _Kind.number, const []);
    case 'channel' || 'podcast':
      return _Key('channel', _Kind.choice, e.channels);
    case 'length' || 'left':
      return _Key(name, _Kind.duration, const []);
    case 'published':
      return const _Key('published', _Kind.dateTime, []);
    case 'media':
      return const _Key('media', _Kind.choice, _mediaOptions);
    case 'type':
      return const _Key('type', _Kind.choice, _typeOptions);
  }
  return null;
}

ParseResult parseFilter(String src, FilterEnv env) {
  final p = _Parser(src.runes.toList(), env);
  try {
    p.ws();
    if (p.eof) return ParseResult.ok(p.f);
    final n = p.or();
    p.ws();
    if (!p.eof) {
      if (p.peek == 0x29) throw p.fail(p.pos, 'unexpected )');
      throw p.fail(p.pos, 'expected AND or OR');
    }
    p.f._root = n;
    return ParseResult.ok(p.f);
  } on _Fail catch (e) {
    return ParseResult.err(e.error);
  }
}

final _space = RegExp(r'\s', unicode: true);
final _letter = RegExp(r'\p{L}', unicode: true);
final _digit = RegExp(r'\p{Nd}', unicode: true);
final _numberRe = RegExp(r'^[0-9]+(\.[0-9]+)?$');

bool _isSpace(int r) => _space.hasMatch(String.fromCharCode(r));
bool _isLetter(int r) => _letter.hasMatch(String.fromCharCode(r));
bool _isDigit(int r) => _digit.hasMatch(String.fromCharCode(r));
bool _isWordRune(int r) => !_isSpace(r) && r != 0x28 && r != 0x29 && r != 0x22;
bool _isNameRune(int r) => _isLetter(r) || _isDigit(r) || r == 0x5f || r == 0x2d;

const _operators = ['!=', '>=', '<=', '^:', r'$:', '=', ':', '>', '<', '~'];

const _allowed = {
  _Kind.text: '= != > < >= <= ~ ^: \$:',
  _Kind.choice: '= != > < >= <=',
  _Kind.number: '= != > < >= <=',
  _Kind.duration: '= != > < >= <=',
  _Kind.dateTime: '= != > < >= <=',
};

enum _T { num, dur, date, time }

const _typeNames = {_T.num: 'number', _T.dur: 'duration', _T.date: 'date', _T.time: 'date'};

class _Value {
  const _Value(this.t, this.a, [this.b = 0]);
  final _T t;
  final double a;
  final double b;
}

const _units = <String, double>{
  's': 1,
  'sec': 1,
  'secs': 1,
  'second': 1,
  'seconds': 1,
  'min': 60,
  'mins': 60,
  'minute': 60,
  'minutes': 60,
  'h': 3600,
  'hr': 3600,
  'hrs': 3600,
  'hour': 3600,
  'hours': 3600,
  'd': 86400,
  'day': 86400,
  'days': 86400,
  'w': 604800,
  'wk': 604800,
  'week': 604800,
  'weeks': 604800,
  'mo': 2592000,
  'month': 2592000,
  'months': 2592000,
  'y': 31536000,
  'yr': 31536000,
  'year': 31536000,
  'years': 31536000,
};

const _months = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
const _weekdays = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];
const _full = {
  'jan': 'january',
  'feb': 'february',
  'mar': 'march',
  'apr': 'april',
  'may': 'may',
  'jun': 'june',
  'jul': 'july',
  'aug': 'august',
  'sep': 'september',
  'oct': 'october',
  'nov': 'november',
  'dec': 'december',
  'sun': 'sunday',
  'mon': 'monday',
  'tue': 'tuesday',
  'wed': 'wednesday',
  'thu': 'thursday',
  'fri': 'friday',
  'sat': 'saturday',
};

int _prefixIndex(List<String> list, String w) {
  if (w.length < 3) return -1;
  for (var i = 0; i < list.length; i++) {
    final x = list[i];
    if (w.startsWith(x)) {
      final full = _full[x]!;
      if (full.startsWith(w) || (x == 'sep' && w == 'sept') || (x == 'tue' && w == 'tues') || (x == 'thu' && (w == 'thur' || w == 'thurs'))) {
        return i;
      }
    }
  }
  return -1;
}

class _Parser {
  _Parser(this.src, this.env);
  final List<int> src;
  final FilterEnv env;
  final Filter f = Filter();
  int pos = 0;

  bool get eof => pos >= src.length;
  int get peek => src[pos];
  String slice(int a, int b) => String.fromCharCodes(src.sublist(a, b));

  void ws() {
    while (!eof && _isSpace(peek)) {
      pos++;
    }
  }

  _Fail fail(int at, String msg) => _Fail(FilterError(at, msg));

  bool keyword(String kw) {
    final end = pos + kw.length;
    if (end > src.length || slice(pos, end).toUpperCase() != kw) return false;
    return end == src.length || _isSpace(src[end]) || src[end] == 0x28 || src[end] == 0x29;
  }

  _Node or() {
    var left = and();
    while (true) {
      ws();
      if (!keyword('OR')) return left;
      pos += 2;
      left = _Or(left, and());
    }
  }

  _Node and() {
    var left = unary();
    while (true) {
      ws();
      if (eof || peek == 0x29 || keyword('OR')) return left;
      if (keyword('AND')) pos += 3;
      left = _And(left, unary());
    }
  }

  _Node unary() {
    ws();
    if (!eof && peek == 0x21) {
      pos++;
      return _Not(unary());
    }
    return primary();
  }

  _Node primary() {
    ws();
    if (eof) throw fail(pos, 'expected a filter term');
    final start = pos;
    final c = peek;
    if (c == 0x28) {
      pos++;
      ws();
      if (!eof && peek == 0x29) throw fail(pos, 'expected a filter term');
      final n = or();
      ws();
      if (eof || peek != 0x29) throw fail(pos, 'expected )');
      pos++;
      return n;
    }
    if (c == 0x29) throw fail(pos, 'expected a filter term');
    if (c == 0x24) return comparison();
    if (c == 0x23) {
      pos++;
      final ns = pos;
      while (!eof && (_isNameRune(peek) || peek == 0x2e)) {
        pos++;
      }
      final name = slice(ns, pos).toLowerCase();
      if (name.isEmpty) throw fail(start, 'expected a name after #');
      f.spans.add(Span(ns, pos, 'tag', name));
      return _Tag(name);
    }
    if (keyword('AND') || keyword('OR')) throw fail(start, 'expected a filter term');
    throw fail(start, r'expected $key, #tag, ! or ( (text goes in $title ~ "words")');
  }

  String quoted() {
    final start = pos;
    pos++;
    while (!eof && peek != 0x22) {
      pos++;
    }
    if (eof) throw fail(start, 'unclosed quote');
    final s = slice(start + 1, pos);
    pos++;
    return s;
  }

  _Node comparison() {
    final start = pos;
    pos++;
    final ns = pos;
    while (!eof && (_isNameRune(peek) || peek == 0x2e)) {
      pos++;
    }
    final name = slice(ns, pos).toLowerCase();
    if (name.isEmpty) throw fail(start, r'expected a name after $');
    final flag = _boolKeys.contains(name);
    final k = _key(env, name);
    if (k == null && !flag) throw fail(start, 'unknown key \$$name');
    // $podcast is saved as $channel, the only name older apps read.
    if (name == 'podcast') f.spans.add(Span(ns, pos, 'alias', 'channel'));
    final nameEnd = pos;
    ws();
    final opPos = pos;
    var op = '';
    for (final o in _operators) {
      final end = pos + o.length;
      if (end <= src.length && slice(pos, end) == o) {
        op = o;
        pos = end;
        break;
      }
    }
    if (k == null) {
      if (op.isNotEmpty) throw fail(opPos, '\$$name is yes or no: write \$$name or !\$$name');
      pos = nameEnd;
      if (name == 'downloaded') {
        f.usesDownloaded = true;
        if (env.forbidDownloaded) throw fail(start, "a playlist this device downloads can't use \$downloaded");
      }
      if (name == 'playlist') f.usesPlaylist = true;
      return _Bool(name);
    }
    if (op.isEmpty) {
      pos = nameEnd;
      return _Has(k.name);
    }
    if (op == ':') op = '=';
    if (!' ${_allowed[k.kind]} '.contains(' $op ')) throw fail(opPos, "$op can't be used with \$$name");
    ws();
    if (eof || peek == 0x29) throw fail(pos, 'expected a value after $op');
    switch (k.kind) {
      case _Kind.text:
        final valPos = pos;
        String s;
        if (peek == 0x22) {
          s = quoted();
        } else {
          while (!eof && _isWordRune(peek)) {
            pos++;
          }
          s = slice(valPos, pos);
        }
        return _TextCmp(op, s.toLowerCase());
      case _Kind.choice:
        final vals = <int>[];
        while (true) {
          ws();
          vals.add(choice(k));
          final save = pos;
          ws();
          if (eof || peek != 0x2c) {
            pos = save;
            break;
          }
          pos++;
        }
        if (vals.length > 1 && op != '=' && op != '!=') throw fail(opPos, 'use one value with $op');
        return _ChoiceCmp(k.name, op, vals, k.options);
      default:
    }
    final valPos = pos;
    var v = expr();
    if (k.kind == _Kind.number) {
      if (v.t != _T.num) throw fail(valPos, 'expected a number');
      return _NumCmp(k.name, op, v.a, v.a, false);
    }
    if (k.kind == _Kind.duration) {
      if (v.t != _T.dur) throw fail(valPos, 'expected a duration like 30min');
      return _NumCmp(k.name, op, v.a, v.a, false);
    }
    if (v.t == _T.dur) v = addDur(today(), v.a);
    if (v.t == _T.num) throw fail(valPos, 'expected a date like 2026-10-07, today or -7d');
    if (v.t == _T.date) return _NumCmp(k.name, op, v.a, v.b, true);
    return _NumCmp(k.name, op, v.a, v.a, false);
  }

  int choice(_Key k) {
    final start = pos;
    if (eof || peek == 0x29 || peek == 0x2c) throw fail(pos, 'expected a value');
    String word;
    if (peek == 0x22) {
      word = quoted();
    } else {
      while (!eof && _isWordRune(peek) && peek != 0x2c) {
        pos++;
      }
      word = slice(start, pos);
    }
    final dynamic_ = k.name == 'channel';
    if (dynamic_ && word.startsWith('@') && src[start] == 0x40) {
      final id = word.substring(1);
      f.spans.add(Span(start, pos, k.name, id));
      return k.options.indexWhere((o) => o.id == id);
    }
    final lw = word.toLowerCase();
    var exact = -1, prefix = -1, exactN = 0, prefixN = 0;
    for (var i = 0; i < k.options.length; i++) {
      final ll = k.options[i].label.toLowerCase();
      if (ll == lw) {
        exact = i;
        exactN++;
      } else if (ll.startsWith(lw)) {
        prefix = i;
        prefixN++;
      }
    }
    int idx;
    if (exactN > 1 || (exactN == 0 && prefixN > 1)) {
      throw fail(start, '"$word" matches more than one option: pick one from the list');
    } else if (exactN == 1) {
      idx = exact;
    } else if (prefixN == 1) {
      idx = prefix;
    } else {
      throw fail(start, 'no option "$word" for \$${k.name}');
    }
    if (dynamic_) f.spans.add(Span(start, pos, k.name, k.options[idx].id));
    return idx;
  }

  _Value expr() {
    var left = term();
    while (true) {
      final save = pos;
      ws();
      if (eof || (peek != 0x2b && peek != 0x2d) || pos + 1 >= src.length || !_isSpace(src[pos + 1])) {
        pos = save;
        return left;
      }
      final opPos = pos;
      final op = String.fromCharCode(peek);
      pos++;
      left = arith(opPos, op, left, term());
    }
  }

  _Value term() {
    var left = factor();
    while (true) {
      final save = pos;
      ws();
      if (eof || (peek != 0x2a && peek != 0x2f)) {
        pos = save;
        return left;
      }
      final opPos = pos;
      final op = String.fromCharCode(peek);
      pos++;
      left = arith(opPos, op, left, factor());
    }
  }

  _Value factor() {
    ws();
    if (!eof && (peek == 0x2d || peek == 0x2b)) {
      final opPos = pos;
      final neg = peek == 0x2d;
      pos++;
      final v = factor();
      if (v.t != _T.num && v.t != _T.dur) throw fail(opPos, 'expected a number or a duration');
      return neg ? _Value(v.t, -v.a, v.b) : v;
    }
    return literal();
  }

  _Value arith(int at, String op, _Value l, _Value r) {
    _Fail bad() => fail(at, "can't combine ${_typeNames[l.t]} and ${_typeNames[r.t]} with $op");
    if (op == '+' || op == '-') {
      final sign = op == '-' ? -1.0 : 1.0;
      if ((l.t == _T.num && r.t == _T.num) || (l.t == _T.dur && r.t == _T.dur)) return _Value(l.t, l.a + sign * r.a);
      if (l.t == _T.date && r.t == _T.dur) return addDur(l, sign * r.a);
      if (l.t == _T.time && r.t == _T.dur) return _Value(_T.time, l.a + sign * r.a);
      if (l.t == _T.dur && r.t == _T.date && op == '+') return addDur(r, l.a);
      throw bad();
    }
    if (op == '*') {
      if ((l.t == _T.num && r.t == _T.num) || (l.t == _T.dur && r.t == _T.num)) return _Value(l.t, l.a * r.a);
      if (l.t == _T.num && r.t == _T.dur) return _Value(_T.dur, l.a * r.a);
      throw bad();
    }
    if (r.t != _T.num || (l.t != _T.num && l.t != _T.dur)) throw bad();
    if (r.a == 0) throw fail(at, 'division by zero');
    return _Value(l.t, l.a / r.a);
  }

  DateTime _date(int y, int m, int d) => env.utc ? DateTime.utc(y, m, d) : DateTime(y, m, d);
  DateTime get _now => env.utc ? env.now.toUtc() : env.now.toLocal();

  _Value addDur(_Value d, double secs) {
    if (secs % 86400 == 0) {
      final t = DateTime.fromMillisecondsSinceEpoch((d.a * 1000).toInt(), isUtc: env.utc);
      return day(t.year, t.month, t.day + (secs / 86400).truncate());
    }
    return _Value(_T.time, d.a + secs);
  }

  _Value day(int y, int m, int d) {
    final s = _date(y, m, d), e = _date(y, m, d + 1);
    return _Value(_T.date, (s.millisecondsSinceEpoch ~/ 1000).toDouble(), (e.millisecondsSinceEpoch ~/ 1000).toDouble());
  }

  _Value today() {
    final n = _now;
    return day(n.year, n.month, n.day);
  }

  String word() {
    final start = pos;
    while (!eof && (_isLetter(peek) || _isDigit(peek) || peek == 0x3a || peek == 0x2e || peek == 0x5f || (peek == 0x2d && pos > start))) {
      pos++;
    }
    return slice(start, pos);
  }

  (String, int) peekWord() {
    final save = pos;
    ws();
    final w = word();
    final end = pos;
    pos = save;
    return (w.toLowerCase(), end);
  }

  _Value literal() {
    ws();
    final start = pos;
    final w = word().toLowerCase();
    if (w.isEmpty) throw fail(start, 'expected a value');
    final n = double.tryParse(w);
    if (n != null && _numberRe.hasMatch(w)) {
      final (next, end) = peekWord();
      final u = _units[next];
      if (u != null) {
        pos = end;
        return ago(_Value(_T.dur, n * u));
      }
      if (next == 'm') throw fail(start, '"m" is ambiguous: use min or mo');
      final mi = _prefixIndex(_months, next);
      if (mi >= 0 && n == n.truncateToDouble() && n >= 1 && n <= 31) {
        pos = end;
        return day(_now.year, mi + 1, n.toInt());
      }
      return _Value(_T.num, n);
    }
    final cd = _compactDuration(w);
    if (cd.ambiguous) throw fail(start, '"m" is ambiguous: use min or mo');
    if (cd.ok) return ago(_Value(_T.dur, cd.secs));
    final now = _now;
    final wd0 = now.weekday % 7;
    switch (w) {
      case 'today':
        return today();
      case 'yesterday':
        return day(now.year, now.month, now.day - 1);
      case 'tomorrow':
        return day(now.year, now.month, now.day + 1);
      case 'now':
        return _Value(_T.time, (env.now.millisecondsSinceEpoch ~/ 1000).toDouble());
      case 'next' || 'last':
        final (next, end) = peekWord();
        final wd = _prefixIndex(_weekdays, next);
        if (wd >= 0) {
          pos = end;
          var delta = (wd - wd0 + 7) % 7;
          if (w == 'next') {
            if (delta == 0) delta = 7;
          } else {
            delta -= 7;
          }
          return day(now.year, now.month, now.day + delta);
        }
        throw fail(start, 'expected a value');
    }
    final wd = _prefixIndex(_weekdays, w);
    if (wd >= 0) {
      final delta = (wd0 - wd + 7) % 7;
      return day(now.year, now.month, now.day - delta);
    }
    final mi = _prefixIndex(_months, w);
    if (mi >= 0) {
      final (next, end) = peekWord();
      final d = int.tryParse(next);
      if (d != null && RegExp(r'^\d+$').hasMatch(next) && d >= 1 && d <= 31) {
        pos = end;
        return day(now.year, mi + 1, d);
      }
    }
    final dm = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(w);
    if (dm != null) {
      final y = int.parse(dm[1]!), m = int.parse(dm[2]!), d = int.parse(dm[3]!);
      final t = _date(y, m, d);
      if (t.year == y && t.month == m && t.day == d) return day(y, m, d);
    }
    final tm = RegExp(r'^(\d{4})-(\d{2})-(\d{2})t(\d{2}):(\d{2})(?::(\d{2}))?$').firstMatch(w);
    if (tm != null) {
      final p = [for (var i = 1; i <= 6; i++) int.tryParse(tm[i] ?? '0') ?? 0];
      final t = env.utc ? DateTime.utc(p[0], p[1], p[2], p[3], p[4], p[5]) : DateTime(p[0], p[1], p[2], p[3], p[4], p[5]);
      if (t.month == p[1] && t.day == p[2] && t.hour == p[3] && t.minute == p[4] && t.second == p[5]) {
        return _Value(_T.time, (t.millisecondsSinceEpoch ~/ 1000).toDouble());
      }
    }
    throw fail(start, '"$w" is not a number, duration or date');
  }

  _Value ago(_Value v) {
    final (next, end) = peekWord();
    if (next == 'ago') {
      pos = end;
      return _Value(v.t, -v.a);
    }
    return v;
  }
}

({double secs, bool ok, bool ambiguous}) _compactDuration(String w) {
  var i = 0, parts = 0;
  var secs = 0.0;
  bool isDigitOrDot(int c) => (c >= 0x30 && c <= 0x39) || c == 0x2e;
  bool isLower(int c) => c >= 0x61 && c <= 0x7a;
  final c = w.codeUnits;
  while (i < c.length) {
    var j = i;
    while (j < c.length && isDigitOrDot(c[j])) {
      j++;
    }
    if (j == i) return (secs: 0, ok: false, ambiguous: false);
    final n = double.tryParse(w.substring(i, j));
    if (n == null) return (secs: 0, ok: false, ambiguous: false);
    var k = j;
    while (k < c.length && isLower(c[k])) {
      k++;
    }
    final u = w.substring(j, k);
    if (u == 'm') return (secs: 0, ok: false, ambiguous: true);
    final mult = _units[u];
    if (mult == null) return (secs: 0, ok: false, ambiguous: false);
    secs += n * mult;
    parts++;
    i = k;
  }
  return (secs: secs, ok: parts > 0, ambiguous: false);
}

abstract class _Node {
  bool eval(FilterItem it);
}

class _And implements _Node {
  _And(this.a, this.b);
  final _Node a, b;
  @override
  bool eval(FilterItem it) => a.eval(it) && b.eval(it);
}

class _Or implements _Node {
  _Or(this.a, this.b);
  final _Node a, b;
  @override
  bool eval(FilterItem it) => a.eval(it) || b.eval(it);
}

class _Not implements _Node {
  _Not(this.n);
  final _Node n;
  @override
  bool eval(FilterItem it) => !n.eval(it);
}

class _Tag implements _Node {
  _Tag(this.name);
  final String name;
  @override
  bool eval(FilterItem it) => it.tags.contains(name);
}

class _Bool implements _Node {
  _Bool(this.name);
  final String name;
  @override
  bool eval(FilterItem it) => switch (name) {
    'unplayed' => !it.played,
    'played' => it.played,
    'inprogress' => it.position > 0 && !it.played,
    'starred' => it.starred,
    'playlist' => it.inPlaylist,
    _ => it.downloaded,
  };
}

(double, bool) _numberOf(String key, FilterItem it) => switch (key) {
  'title.length' => (it.title.runes.length.toDouble(), true),
  'season' => (it.season.toDouble(), it.season != 0),
  'number' => (it.number.toDouble(), it.number != 0),
  'length' => (it.length.toDouble(), it.length > 0),
  'left' => ((it.length - it.position).clamp(0, 1 << 52).toDouble(), it.length > 0),
  'published' => (it.published.toDouble(), it.published != 0),
  _ => (0.0, false),
};

class _Has implements _Node {
  _Has(this.key);
  final String key;
  @override
  bool eval(FilterItem it) {
    if (const ['title', 'channel', 'media', 'type', 'title.length'].contains(key)) return true;
    return _numberOf(key, it).$2;
  }
}

bool _compare(String op, int c) => switch (op) {
  '=' => c == 0,
  '!=' => c != 0,
  '>' => c > 0,
  '<' => c < 0,
  '>=' => c >= 0,
  _ => c <= 0,
};

class _TextCmp implements _Node {
  _TextCmp(this.op, this.val);
  final String op, val;
  @override
  bool eval(FilterItem it) {
    final t = it.title.toLowerCase();
    return switch (op) {
      '~' => t.contains(val),
      '^:' => t.startsWith(val),
      r'$:' => t.endsWith(val),
      _ => _compare(op, t.compareTo(val).sign),
    };
  }
}

class _ChoiceCmp implements _Node {
  _ChoiceCmp(this.key, this.op, this.vals, this.options);
  final String key, op;
  final List<int> vals;
  final List<FilterOption> options;
  @override
  bool eval(FilterItem it) {
    var cur = switch (key) {
      'channel' => it.channel,
      'media' => it.media,
      _ => it.type,
    };
    if (key == 'type' && cur.isEmpty) cur = 'full';
    final ci = options.indexWhere((o) => o.id == cur);
    if (op == '=' || op == '!=') {
      final hit = vals.any((v) => v >= 0 && v == ci);
      return hit == (op == '=');
    }
    if (ci < 0 || vals[0] < 0) return false;
    return _compare(op, (ci - vals[0]).sign);
  }
}

class _NumCmp implements _Node {
  _NumCmp(this.key, this.op, this.lo, this.hi, this.day);
  final String key, op;
  final double lo, hi;
  final bool day;
  @override
  bool eval(FilterItem it) {
    final (v, ok) = _numberOf(key, it);
    if (!ok) return false;
    if (day) {
      return switch (op) {
        '=' => v >= lo && v < hi,
        '!=' => v < lo || v >= hi,
        '>' => v >= hi,
        '>=' => v >= lo,
        '<' => v < lo,
        _ => v < hi,
      };
    }
    return _compare(op, v < lo ? -1 : (v > lo ? 1 : 0));
  }
}

String rewrite(String src, List<Span> spans, String? Function(Span) fn) {
  final r = src.runes.toList();
  final b = StringBuffer();
  var last = 0;
  for (final s in spans) {
    final repl = fn(s);
    if (repl == null || s.start < last) continue;
    b.write(String.fromCharCodes(r.sublist(last, s.start)));
    b.write(repl);
    last = s.end;
  }
  b.write(String.fromCharCodes(r.sublist(last)));
  return b.toString();
}

String quoteLabel(String label) {
  for (final c in label.runes) {
    if (!_isNameRune(c)) return '"${label.replaceAll('"', '')}"';
  }
  if (label.isEmpty || const ['AND', 'OR'].contains(label.toUpperCase())) return '"$label"';
  return label;
}

/// Swaps channel labels for ids, so renames never break the filter, and $podcast for $channel.
(String?, FilterError?) toStored(String src, FilterEnv env) {
  final r = parseFilter(src, env);
  if (r.error != null) return (null, r.error);
  return (rewrite(src, r.filter!.spans, (s) => s.kind == 'tag' ? null : (s.kind == 'alias' ? s.id : '@${s.id}')), null);
}

/// Swaps stored ids back for their current labels.
String toDisplay(String stored, FilterEnv env) {
  final r = parseFilter(stored, env);
  if (r.error != null) return stored;
  final labels = {for (final o in env.channels) o.id: o.label};
  return rewrite(stored, r.filter!.spans, (s) {
    if (s.kind == 'tag' || s.kind == 'alias') return null;
    final l = labels[s.id];
    return l == null ? null : quoteLabel(l);
  });
}
