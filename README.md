# rPodcasts app

The app for [rPodcasts](https://rpodcasts.rotten.ninja), a self-hosted podcast and video-channel player. It signs in to your own [rPodcasts server](https://github.com/RottenNinja/rPodcasts-server), keeps a full copy of your library, plays offline and syncs every device. One Flutter codebase for iPhone, iPad, Android, macOS, Linux and Windows.

## Get it

- iPhone and iPad: the [App Store](https://apps.apple.com/us/app/rpodcasts/id6834411126)
- Android (APK) and Linux x64: the [latest release](https://github.com/RottenNinja/rPodcasts-app/releases/latest)

## Build it

```sh
flutter run
```

Sign in with your server's address and password.

- Linux needs `libmpv-dev` to build and `libmpv` to run.
- Windows needs Visual Studio with the "Desktop development with C++" workload.
- iOS and macOS: set your own team and bundle identifier in Xcode.
- Android: a release build is signed with the debug key unless `android/key.properties` names your own keystore (`storeFile`, `storePassword`, `keyAlias`, `keyPassword`).

## Tests

```sh
flutter test
```

The filter language exists in the server too, and both are tested against the same examples; `test/examples.json` is a copy of the server's.

## Contributing: send a Prompt Request

Do not send pull requests. Send a prompt request! PR now stands for Prompt Request lol.

Why: me having to spend credits getting my AI to read hundreds of lines of code that you spent credits getting your AI to write, to then tell me what it does, and then having to get my AI to check and validate it, is slow and expensive. Just [open an issue](https://github.com/RottenNinja/rPodcasts-app/issues) saying in plain English what you want, in a single paragraph, and I'll get my AI to write it using the rules it already has. Much simpler, cheaper and better for the planet.

## Licence

Copyright 2026 rotten.ninja. This app is free software under the [GNU General Public License v3.0](LICENSE).
