// Not a test: signs in to SERVER and walks the screens the App Store shows, for tools/ios/tart-screenshots.sh.
// Without SERVER only the sign-in screen is taken. SHOW names the podcast to open; FILTER is typed on Episodes.
// With CAPTURE (the driver's address) the simulator or the desktop window itself is captured, so the iOS status bar shows.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:podcasts/main.dart' as app;
import 'package:podcasts/ui/widgets.dart';

const server = String.fromEnvironment('SERVER');
const password = String.fromEnvironment('PASSWORD');
const show = String.fromEnvironment('SHOW', defaultValue: 'Self-Hosted');
const capture = String.fromEnvironment('CAPTURE');
const filter = String.fromEnvironment('FILTER', defaultValue: r'#linux $unplayed $length < 1h');

// Waits a fixed time rather than for the app to settle, since loading indicators keep animating.
Future<void> wait(WidgetTester tester, [int tenths = 20]) async {
  for (var i = 0; i < tenths; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('App Store screenshots', (tester) async {
    var n = 0;
    Future<void> shot(String name) async {
      n++;
      final file = '${n.toString().padLeft(2, '0')}-$name';
      if (capture.isEmpty) {
        await binding.takeScreenshot(file);
        return;
      }
      await tester.pump();
      final r = await http.get(Uri.parse('$capture/shot?name=$file'));
      if (r.statusCode != 200) throw Exception('capture $file: ${r.body}');
    }

    // Types into a field, or sets it directly where a desktop build takes no test typing; true when it had to.
    Future<bool> type(Finder field, String text) async {
      await tester.enterText(field, text);
      final editable = tester.widget<EditableText>(find.descendant(of: field, matching: find.byType(EditableText)));
      if (editable.controller.text == text) return false;
      editable.controller.text = text;
      await tester.pump();
      return true;
    }

    await app.main();
    await wait(tester, 30);
    if (server.isEmpty) {
      await shot('sign-in');
      return;
    }
    final signIn = find.widgetWithText(FilledButton, 'Sign in');
    if (signIn.evaluate().isNotEmpty) {
      await type(find.widgetWithText(TextField, 'Server address'), server);
      await type(find.widgetWithText(TextField, 'Password'), password);
      await tester.tap(signIn);
    }
    // Phones show a NavigationBar, wide screens such as an iPad a NavigationRail.
    final nav = find.byWidgetPredicate((w) => w is NavigationBar || w is NavigationRail);
    for (var i = 0; i < 240 && nav.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    await wait(tester, 80);
    Future<void> tab(String label) async {
      await tester.tap(find.descendant(of: nav, matching: find.text(label)));
      await wait(tester, 30);
    }

    await tab('Playlists');
    await shot('playlists');

    await tab('Podcasts');
    await shot('podcasts');

    await tester.tap(find.text(show).first);
    await wait(tester, 40);
    await shot('podcast');

    await tester.tap(find.byType(EpisodeTile).first);
    await wait(tester, 40);
    // The episode screen is the player: a video has a second play button over its picture.
    await tester.tap(find.byWidgetPredicate((w) => w is IconButton && (w.tooltip == 'Play' || w.tooltip == 'Resume')).first);
    await wait(tester, 80);
    await shot('player');
    // The player covers the tabs.
    await tester.tap(find.byTooltip('Back'));
    await wait(tester, 20);

    await tab('Episodes');
    final filterField = find.byType(FilterField);
    if (await type(filterField, filter)) {
      tester.widget<EditableText>(find.descendant(of: filterField, matching: find.byType(EditableText))).onSubmitted?.call(filter);
    } else {
      await tester.testTextInput.receiveAction(TextInputAction.done);
    }
    FocusManager.instance.primaryFocus?.unfocus();
    await wait(tester, 40);
    await shot('filter');
  });
}
