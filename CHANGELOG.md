# Changelog

All notable changes to Sill are documented here. The release workflow publishes each version's section as the GitHub release notes and embeds it in the Sparkle appcast, so the in-app update dialog shows the same notes. A release fails early if its version has no section here.

Keep each bullet on a single line: release notes render line breaks literally (both on GitHub and in the update dialog), so wrapped lines would break mid-sentence.

## 1.2.0

- Sill now speaks Korean: Settings, onboarding and the menu follow your system language.
- Type the first letter and Sill can offer the command itself, with a line on what it does — switch on "Complete command names" in Settings.
- Matching is fuzzy now: "chk" finds checkout and "rb" finds rebase, and the letters that matched are shown in the list. Exact and prefix matches still come first.
- After completing a word, your terminal's syntax highlighting updates right away instead of leaving it half-coloured.
- The list's icons no longer change with your system language.
- The "Check for Updates" button in Settings is its own size again.

## 1.1.0

- Ghostty and cmux now get completions too, alongside Terminal.app, iTerm2 and VS Code.
- Commands the definitions don't cover can now be learned from their own help text — switch it on under Specs in Settings, and only real programs are ever run.
- Completing a word no longer leaves a space behind it, and the list closes so your next keystroke goes straight to the shell.
- When what you typed is already the whole word, Return runs the command instead of completing it.
- The list lines up with your cursor the same way in every terminal now.
- Arrowing to the top or bottom of a long list keeps the highlighted row clear of the edge instead of tucking it under.
- Fixed the stray characters that could appear at your prompt when a terminal answered slowly.
- Fixed the pale corners that showed around the popup.

## 1.0.0

- Initial release: IDE-style autocomplete for Terminal.app and iTerm2 — a popup at your cursor with subcommands, options, files, and branches for the command you're typing, each with a short description.
- Arrows choose, Tab or Return inserts, Esc dismisses — with the popup closed, Return runs your command as usual.
- Completion definitions for hundreds of CLIs from the open-source withfig/autocomplete corpus, downloaded on first run and refreshed daily.
- Dynamic suggestions — git branches, npm scripts, file paths — computed locally in the session's working directory.
- A one-line zsh integration installed from the app (and cleanly removable in Settings); ~/.zshrc is backed up first.
- Sparkle keeps the app up to date.
