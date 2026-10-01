<p align="center">
  <img src="Assets/banner.png" alt="Sill: Autocomplete for your terminal" />
</p>

# Sill

IDE-style autocomplete for the terminal. Part of [Domus](https://domus-apps.com).

A sill is the ledge at the bottom of a window or door, the threshold that
holds what comes next. As you type a command in Terminal, iTerm2, or VS Code, Sill
shows a popup at your cursor with what can come next: subcommands, options,
files, branches, each with a short description. ↑↓ choose, Tab or Return
inserts, Esc dismisses (and then Return runs your command as usual).

## How it works

A one-line zsh integration (installed from the app, removable in Settings,
`~/.zshrc` is backed up first) streams the command line you're editing to
the app over a local socket. Sill parses it against completion definitions
for hundreds of CLIs from the open-source
[withfig/autocomplete](https://github.com/withfig/autocomplete) corpus
(downloaded on first run, refreshed daily), and inserts your choice through
the same shell integration, nothing types keystrokes on your behalf.

Dynamic suggestions (git branches, npm scripts) come from short shell
commands the completion definitions specify, run locally in the session's
working directory with a timeout.

With command-name completion enabled in Settings, the first word offers the
installed commands Sill has definitions for, plus the commands of Homebrew
formulae you installed by name and of casks, each with its package's
description. Commands a formula brought in as a dependency are left out.
Sill reads Homebrew's install records for this and never runs `brew`.

Aliases participate in completion too. With command-name completion enabled
in Settings, ordinary zsh aliases appear with their definitions, including
aliases loaded by `.zshrc` plugins or added in the current terminal. Alias
changes are picked up at the next prompt. Git aliases appear after `git`
(or a shell alias such as `g`); Git reads the applicable global, repository,
and included config files, with a short cache refreshed as you type.
Simple aliases retain argument completion: `gco='git checkout'` and Git's
`co = checkout` both offer branches after the alias. Completion inserts the
alias name itself. Compound shell aliases and Git `!` aliases are listed
with their definitions, but their bodies are not evaluated for completion.
Global/suffix zsh aliases and shell functions are not included. After
updating Sill, open a new terminal tab to load the updated shell integration.

The upstream corpus stopped updating in 2025, so Sill layers its own
definitions on top ([Specs/overrides](Specs/overrides/README.md)) and, if you
turn it on in Settings, learns commands the corpus doesn't know from their
own `--help` output: the program is run once, in the background, with a
quiet environment and a timeout, and what it prints is kept as a local
definition on your Mac. Only real programs are run, a shell script found in
your PATH is never executed for this. For a shell script, or a program whose
`--help` says nothing readable, Sill reads the zsh completion file installed
next to it instead (Homebrew links these into `share/zsh/site-functions`).
The file is read as text and never sourced, so lists it would only compute
at completion time are left out.

Steering keys (Tab, arrows, Return, Esc) are handled by the same shell
integration, as line-editor bindings active only while the popup is on
screen, nothing observes the keyboard at the system level, so they work
even with Secure Keyboard Entry enabled. Sill needs the Accessibility
permission for one thing: finding the caret's position on screen to place
the popup.

## Limitations

- zsh only, in Terminal.app, iTerm2, VS Code's integrated terminal, Ghostty
  and cmux, for now. Ghostty and cmux expose no caret to accessibility, so
  the popup is placed from the cell grid the terminal reports, a nudge off
  when the prompt uses glyphs whose width the shell misjudges.
- Over ssh, inside tmux, and in full-screen TUIs Sill stays out of the way
  automatically.

## Development

```sh
./Scripts/dev.sh      # rebuild-and-relaunch loop
./Scripts/test.sh     # unit tests
./Scripts/bundle.sh   # assemble build/Sill.app
./Scripts/build-specs.sh  # rebuild the completion-spec bundle
```

Requires macOS 26 or later.

## License

MIT, see [LICENSE](LICENSE). Bundled third-party software and its licenses are listed in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

Completion definitions come from Fig's open-source [withfig/autocomplete](https://github.com/withfig/autocomplete) corpus; see the notices for its license.
