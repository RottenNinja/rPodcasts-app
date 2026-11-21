# Changelog

## Unreleased



## 1.2.0 (2026-11-21)

- Fixed playlists briefly showing errors while a sync finished loading, most often on the first sync after signing in.
- Fixed downloaded episodes streaming instead of playing from the device after an app update on iPhone, which failed with Can't reach the server when offline. The app finds the files again when it starts.
- The app now tells a server that's down apart from a phone with no internet. With only the server down, Status says Server unreachable rather than Offline, and playlists of ordinary podcasts are no longer greyed out, as they still stream from the podcasts' own sites; only videos need the server.
- New setting, Pause downloads (Settings → This device, for a hotspot or roaming): nothing downloads by itself until it is turned off, and downloads part way stop and pick up where they were afterwards. Download on an episode still works. Status shows it, with Resume.
- Fixed offline mode: the app no longer sits on Syncing… or keeps erroring once the connection is back. It syncs as soon as the server answers again or the app comes back to the front, and Server defaults and Devices in Settings come back without restarting the app. It notices it is offline within about 5 seconds, and those two settings can't be opened while it is.
- Reset progress (when selecting episodes, and the Unplayed swipe) has a new icon, so it no longer looks like Refresh.
- Playlists has All and Offline playlists under the Find box, to show only the playlists this device downloads.
- Playlists also has Downloaded episodes: every playlist with unplayed episodes on this device, whichever playlist downloaded them, counting only those episodes.
- Playlists also has Streaming episodes: every playlist with unplayed episodes not downloaded, counting only those, so downloads can be saved for later.
- A playlist opened from Downloaded episodes or Streaming episodes lists only those episodes, and what plays next keeps to them; the chip at its top clears that.
- A playlist's page says how many of its unplayed episodes are downloaded.
- When the server can't be reached, playlists with nothing downloaded are greyed out; they still open.
- The playlist setting On this device is now called Keep offline.
- Tapping the tab you're on again, once at its first page, clears its Find box, tag and filters.
- Starting a video on a phone stops other apps' sound, as audio already did; a call pauses the video, which plays on afterwards, and it pauses when headphones come out.
- New setting, Keep playing in the background (Settings → Playback and theme → Video): a video's sound plays on when you leave the app.
- New setting, Full screen in landscape: full screen turns the phone sideways for a video wider than it is tall.
- The Next episode button over a video can be swiped away for the rest of the episode.
- The Playlists screen has a Find box at the top that narrows the playlists by name as you type.
- The Episodes tab has a sound-wave icon instead of a magnifying glass, so it no longer looks like search.
- The Podcasts screen has a Find box at the top that narrows the grid by name as you type.
- New playlist setting, Hide played episodes (on for new playlists): the page lists only what is left to play, with Show played under it, while played episodes stay in the playlist and out of `!$playlist` (needs an up-to-date server).
- Add a podcast starts on Search, with Manual for an address; either way the podcast is shown (picture, author, episodes, audio or video) with its tags before Follow.
- The preview has a Name field, so a podcast can be renamed before it is followed.
- An address that can't be reached or has nothing to play is refused with the reason, instead of becoming a podcast that fails to read (needs an up-to-date server; older ones follow as before).
- A stream whose connection drops, or that ends short, is opened again where it was, without "Press play to carry on".
- Resuming a stream paused for more than 5 minutes reopens it with a fresh link instead of failing with a network error.
- Remember speed for each podcast (Settings → Playback): a speed changed while playing becomes the podcast's own, on every device.
- Video podcasts play and download through the server, at the podcast's video quality (needs an up-to-date server; older ones still give the enclosure).
- Downloads wait in an in-app queue, a few at a time; a short audio download no longer stays at "Started" until the app restarts.
- Swiping an episode left no longer stars it, so Android's Back gesture doesn't change anything.
- An episode whose picture can't be loaded shows its podcast's picture instead.
- With nothing followed yet, Playlists shows how to start (follow a podcast, what playlists are, tags and downloads) with Add a podcast on it, and a new sign-in shows a spinner until its first sync instead of an empty page.
- Filters take `$podcast` as another name for `$channel`; it is saved as `$channel`, so older apps and servers still read the playlist.

## 1.1.1 (2026-11-15)
