# Spec overrides

Completion specs that ride on top of the upstream corpus. The bundle is
built from npm's `@withfig/autocomplete` (Scripts/build-specs.sh); whatever
is in this directory is converted the same way and copied over it, so a file
here **replaces** the upstream spec of the same name, or **adds** a command
upstream never had. Upstream stopped publishing in May 2025 — this is where
Sill keeps up.

Two formats, one file per command, named after the command:

- `<command>.ts` or `<command>.js` — an ES module with `export default spec`,
  the exact shape of an upstream source file
  (https://github.com/withfig/autocomplete/tree/master/src). Types are
  stripped, not checked; `Fig.Spec` annotations are fine. Generators and
  `loadSpec` work as they do upstream.
- `<command>.json` — a plain Fig.Spec object (`name`, `description`,
  `subcommands`, `options`, `args`). Data only; use this when nothing
  dynamic is needed.

Nested `loadSpec` files go in a subdirectory (`aws/s3.ts`), like upstream.

The bundle version becomes `<upstream>+ov.<hash>` whenever this directory is
non-empty, so a change here rolls out to users on the next build (the
spec-bundle workflow runs on push to this directory, and weekly).

Check a spec locally before pushing:

    ./Scripts/build-specs.sh
    SILL_SPEC_DIR=build/specs swift run Sill --complete "<command> "
