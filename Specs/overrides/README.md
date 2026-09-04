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

A migrated spec keeps upstream's imports (`@fig/autocomplete-generators`,
`@fig/autocomplete-helpers`, `semver`, `yaml`, …): `Specs/package.json` pins
those packages and the build installs them before bundling. `Specs/tsconfig.json`
gives editors the Fig types (strict), and the build runs `npm run typecheck` in
`Specs/` before bundling, so a spec that does not type-check never ships.

The bundle version becomes `<upstream>+b2.ov.<hash>` whenever this directory
is non-empty (`b2` is the bundle format), so a change here rolls out to users
on the next build (the spec-bundle workflow runs on push to this directory,
and weekly).

Check a spec locally before pushing:

    ./Scripts/build-specs.sh
    SILL_SPEC_DIR=build/specs swift run Sill --complete "<command> "

## Where this is heading

Upstream stopped publishing in May 2025. Rather than patch on top of a frozen
corpus, a spec that needs work is migrated here whole: copy its source from
withfig/autocomplete (MIT; keep the attribution line at the top), fix it, and
own it from then on. Only specs that need it move; the rest keep coming from
the upstream bundle, and the app's `--help` overlay fills gaps on each
machine in the meantime.

Once a dozen or so specs live here, they move to their own repository — a
fork of withfig/autocomplete under domus-apps, keeping its history — with the
spec-bundle workflow alongside them, and the app's download URL pointing
there. That keeps this repository small (the upstream source is ~100 MB) and
keeps the door open: if upstream resumes, a fork can still merge from it,
and the files here are the same files a fork would hold.
