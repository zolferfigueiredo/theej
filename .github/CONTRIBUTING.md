# Contributing

Thanks for helping with TheeJ. Bug reports, ideas, translations and code are all welcome.

## Issues

- **Bugs and ideas**: [open an issue](https://github.com/zolferfigueiredo/theej/issues/new/choose). Search the open ones first.
- **Security problems**: don't open an issue. Follow the [security policy](SECURITY.md).

## Pull requests

For anything bigger than a small fix, open an issue first so we can agree on the idea before you build it.

1. Fork the repository and branch from `main`.
2. Make your change. `./run.sh` builds TheeJ and runs it in the terminal, and `swift test` runs the tests. You need macOS 14 or later and the Xcode command line tools; a deej board helps, and external screens need m1ddc.
3. If you changed the app (anything in `Sources` or `Package.swift`), raise `appVersion` in `Sources/TheeJ/Version.swift`, for example 1.2.3 to 1.2.4.
4. Open a pull request against `main`.

CI builds and tests it on macOS, counting any compiler warning as an error. It also runs shellcheck on the scripts and checks that the version went up.

## Translations

Each language has its own file in [`Sources/TheeJ/Strings`](../Sources/TheeJ/Strings). To fix a translation, edit that file. The tests check that every language has every string and keeps placeholders like `{version}`.

## License

By contributing, you agree that your work is licensed under the [MIT License](../LICENSE).
