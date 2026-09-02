# Changelog

All notable changes to Sill are documented here. The release workflow publishes each version's section as the GitHub release notes and embeds it in the Sparkle appcast, so the in-app update dialog shows the same notes. A release fails early if its version has no section here.

Keep each bullet on a single line: release notes render line breaks literally (both on GitHub and in the update dialog), so wrapped lines would break mid-sentence.

## 1.0.0

- Initial release: IDE-style autocomplete for Terminal.app and iTerm2 — a popup at your cursor with subcommands, options, files, and branches for the command you're typing, each with a short description.
- Arrows choose, Tab or Return inserts, Esc dismisses — with the popup closed, Return runs your command as usual.
- Completion definitions for hundreds of CLIs from the open-source withfig/autocomplete corpus, downloaded on first run and refreshed daily.
- Dynamic suggestions — git branches, npm scripts, file paths — computed locally in the session's working directory.
- A one-line zsh integration installed from the app (and cleanly removable in Settings); ~/.zshrc is backed up first.
- Sparkle keeps the app up to date.
