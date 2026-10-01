# mport

A macOS command-line tool for exporting, importing, and migrating MongoDB collections between saved connections.

- **Export** collections to BSON, JSON, or mongo shell syntax.
- **Import** BSON dumps (from `mport export` or `mongodump`) into any database.
- **Migrate** collections directly from one connection or database to another, with nothing written to disk.
- Handles target collections that already exist: back up then clear, clear, overwrite, or skip.
- Works on several collections at once (4 by default), each over its own connection.
- Keeps connection URIs, and the credentials in them, in the macOS Keychain, not in a config file.

## Requirements

macOS 26.5 or later, on Apple Silicon or Intel.

## Install

**Download a release.** Grab the latest `mport-<version>-macos.zip` from the
[Releases page](https://github.com/vbuongiovanni/mport/releases), unzip it, and put `mport` somewhere on your
`PATH`:

```sh
unzip mport-*-macos.zip
mv mport-*/mport ~/.local/bin/    # or /usr/local/bin
mport --version
```

Release builds are signed and notarized by Apple, so macOS runs them without complaint.

**Build from source.** You need Xcode 26.5 or later.

```sh
git clone https://github.com/vbuongiovanni/mport.git
cd mport
swift build -c release
cp .build/release/mport ~/.local/bin/
```

> Replacing an existing `mport` with `cp` over the old file can make macOS kill the new one on launch. If that
> happens, copy it to a new name first and then move it into place: `cp .build/release/mport ~/.local/bin/mport.new
> && mv -f ~/.local/bin/mport.new ~/.local/bin/mport`.

## Quick start

```sh
# Save a connection. Leave out the URI and you're asked for it, hidden as you type.
mport register-connection staging

# Set defaults: where exports go, their format, and how many collections to work on at once.
mport configure-defaults ~/mongo-exports bson --concurrency 4

# Export every collection in the `shop` database.
mport export ~/mongo-exports staging shop --export-all

# Import them into a local database, backing up any collection that already exists first.
mport import ~/mongo-exports/staging/shop local -d shop --import-all --collision-resolution dump-before-import

# Or copy straight from one connection to another.
mport migrate --from staging --from-db shop --to local --to-db shop --migrate-all
```

Arguments you leave out are asked for interactively: the connection, the database, the collections, and so on.

## Commands

### `register-connection <name> [<uri>]`

Saves a connection under a short name that the other commands use. The URI goes into your Keychain, and only the
name goes into the config file.

```sh
mport register-connection prod                     # prompts for the URI, hidden as you type
op read "op://Vault/Mongo/uri" | mport register-connection prod   # or pipe it in from a password manager
mport register-connection prod "mongodb+srv://…" --overwrite      # works, but leaves the URI in your shell history
```

`--overwrite` (`-o`) replaces an existing connection of the same name.

### `remove-connection <name>`

Removes a saved connection, and its URI from your Keychain.

### `configure-defaults [<output-path>] [<format>] [--concurrency <n>]`

Saves defaults that the other commands fall back on:

- **Output path:** where `export` writes, and where `import` looks when you don't give a directory.
- **Format:** `bson`, `json`, or `mongo-shell-syntax`.
- **Concurrency:** how many collections to work on at once, 1–32. The default is 4.

### `export [<export-path>] [<connection>] [<database>]`

Writes each collection to `<export-path>/<connection>/<database>/<collection>.<ext>`.

| Option | |
|---|---|
| `--format <format>` | `bson` (can be imported back), `json` (one JSON array), or `mongo-shell-syntax` |
| `-e`, `--export-all` | Export every collection instead of choosing |
| `-j`, `--concurrency <n>` | Collections to export at once, for this run only |

`system.*` collections are never exported. On a disk that doesn't tell upper and lower case apart (the macOS
default), two collections such as `Users` and `users` would share one file, so `export` refuses to run and asks you
to export them separately.

### `import [<directory>] [<connection>]`

Imports `.bson` files from a directory and its subfolders. Each file goes into a collection named after it, minus
`.bson`, and you're offered the chance to rename any of them.

| Option | |
|---|---|
| `-d`, `--db-name <database>` | The database to import into |
| `--import-all` | Import every file found instead of choosing |
| `-c`, `--collection-names <names>` | Import only these files (comma-separated, without `.bson`) |
| `--collision-resolution <strategy>` | What to do when a target collection already exists (see below) |
| `--skip-backup` | With `dump-before-import`, clear existing collections without backing them up |
| `-j`, `--concurrency <n>` | Files to import at once, for this run only |

### `migrate`

Copies collections from one connection and database to another. Documents stream straight from the source to the
target.

| Option | |
|---|---|
| `--from <connection>`, `--from-db <database>` | Where to copy from |
| `--to <connection>`, `--to-db <database>` | Where to copy into |
| `-m`, `--migrate-all` | Copy every collection instead of choosing |
| `-c`, `--collection-names <names>` | Copy only these collections (comma-separated) |
| `--collision-resolution <strategy>` | What to do when a target collection already exists (see below) |
| `-j`, `--concurrency <n>` | Collections to copy at once, for this run only |

## When a target collection already exists

`import` and `migrate` check first, and show a plan before changing anything. You choose a strategy with
`--collision-resolution`, or at the prompt:

| Strategy | What happens |
|---|---|
| `dump-before-import` | Each existing collection is backed up to a `.bson` file, then cleared, then written. |
| `clear-before-import` | Each existing collection is cleared, then written. |
| `overwrite` | Documents are added, and any with a matching `_id` are replaced. |
| `skip` | Documents are added, and any with a matching `_id` are left alone. |

With `dump-before-import`:

- **Where backups go.** They go under the import directory (for `migrate`, under your default export path, or the
  current folder if you haven't set one), in `.mport-backups/<connection>/<database>/<timestamp>/`. The leading dot keeps them out of `import`'s file list.
- **How to restore one.** Import that folder: `mport import <backup folder> <connection> -d <database> --import-all`.
- **Unchanged collections are left alone.** If a collection's backup comes out identical to the file about to be
  imported into it, the collection already holds exactly that file. It isn't cleared or re-imported, and the summary
  shows it as "unchanged, skipped".

## Working on several collections at once

`export`, `import`, and `migrate` work on up to 4 collections at a time, and backups run the same way. Change the
number for one run with `-j`, or permanently with `mport configure-defaults --concurrency <n>`. Each collection in
flight uses its own connection (two for `migrate`) and holds up to 8 MB of documents in memory. `-j 1` does one at a
time.

If one collection fails, no new ones start, the ones already running finish, and mport reports what completed, what
failed, and what never started.

## Where mport keeps things

| What | Where |
|---|---|
| Connection URIs (with their credentials) | Your login Keychain, as "mport connection: \<name\>" (service `mport`) |
| Connection names and defaults | `~/.mport-config.json`, readable only by you (mode 600) |

The config file holds no credentials, so it's safe to keep in a dotfiles repo. Older versions of mport stored URIs in
it. The first time a newer mport reads such a file, it moves them into the Keychain and rewrites the file without
them. If you ever committed an older config, change those database passwords.

macOS remembers which program saved each Keychain entry. Release builds are signed, so they keep access across
updates. A build you
compile yourself may make macOS ask "mport wants to use your confidential information" after each rebuild; choose
**Always Allow**.

If `~/.mport-config.json` can't be decoded (after a bad hand edit, say), mport moves it to
`~/.mport-config.json.broken-<timestamp>` and starts a fresh one. It never overwrites the original.

## Development

Open `mport.xcodeproj` in Xcode, or build and test from the command line:

```sh
xcodebuild test -project mport.xcodeproj -scheme mport -destination 'platform=macOS' -skipPackagePluginValidation
```

The integration tests need a MongoDB. By default they use `mongodb://root:password@localhost:27017`; set
`MPORT_TEST_MONGO_URI` to use another. Every test runs in its own throwaway `mport_test_*` database. With no
MongoDB reachable, those tests are skipped and the rest still run.

`Package.swift` builds the tool with Swift Package Manager (`swift build`). The tests run only through the Xcode
project, because its test target compiles the app's sources directly.

## Releasing

Pushing a tag like `v1.2.0` runs [`.github/workflows/release.yml`](.github/workflows/release.yml). It tests, builds a
universal binary, signs it with a Developer ID certificate, notarizes it, and publishes a GitHub release with a zip
and its SHA-256. The workflow file lists the repository secrets it needs. Before tagging, update the version in
`mport/Mport.swift`, `mport/ConfigureDefaults.swift`, and `mport/RegisterConnection.swift`; the workflow stops if
`mport --version` doesn't match the tag.

## License

MIT; see [LICENSE](LICENSE). mport uses open-source packages under the MIT and Apache 2.0 licenses; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
