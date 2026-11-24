# In Her Own Write: notes for working on this repository

A private Mac app that turns photos of handwritten journal pages into an encrypted, searchable library.
Pages are read by Claude, or experimentally on the Mac itself. `README.md` is for people using the app;
`docs/EXPERIMENTS.md` records what was tested, kept, and set aside, plus **Future ideas** and **Known
issues**. Read it before changing how pages are read.

## Ground rules

- **This repository is public.** Never commit journal photos or text, real or excerpted, even in comments,
  tests, or docs. Tests use invented pages drawn in handwriting fonts. Describe real test pages only in
  general terms. `.gitignore` excludes images, databases, and `JournalOCR/` (an older app kept locally).
- **Commit with the GitHub no-reply address** (`31493909+PeterBrownie@users.noreply.github.com`), not a
  personal email, for example with `git -c user.email=... commit`.
- **Never rewrite or force-push `main`.** Installed apps update only when their build commit is an ancestor
  of `origin/main`; rewritten history stops updates.
- **New ideas and bugs go in `docs/EXPERIMENTS.md`** (Future ideas or Known issues) unless the person asks
  for them to be built.

## Building and checking

Built with Apple's Command Line Tools only, no Xcode. That's why views use the `ViewState` wrapper instead
of `@State`: the macro plugin ships only with Xcode. Swift 5 language mode.

| Command | What it does |
| --- | --- |
| `swift build` | Debug build |
| `swift run WriteCheck` | All offline checks: vault, encryption, entries, photo handling, page finding, splitting both pages, photo order, flattening, local reading rules, editing, the update bar, rotation. Must pass before committing. |
| `swift run WriteCheck --local` | Reads an invented page with the real decision model (needs the model downloaded). Add `--thorough` for Careful mode. |
| `swift run WriteCheck --live` | Reads an invented page through the Anthropic API (needs `ANTHROPIC_API_KEY`). |
| `swift run WriteCheck --render <folder>` | Renders the app's screens to PNGs for a visual check. |
| `./"Start In Her Own Write.command"` | Release build, installs to `~/Applications`, opens it. `--stage-only` builds without installing (the updater uses this). |

To try internal code on a real photo without touching the app, compile the core library with a scratch
`main.swift` kept outside the repository:
`swiftc -O -o probe Sources/WriteCore/*.swift Sources/WriteCore/LocalReading/*.swift main.swift -lsqlite3 -module-name WriteCore`.
Keep real photos and anything derived from them outside the repository, and delete them afterward.

## Where things are

- `Sources/WriteCore`: everything without UI. `Vault` (encrypted SQLite store), `Transcriber` (Claude),
  `PagePhoto` (prepare, crop, rotate), `PageScan` (finding the page, fold, and page number), `PageFlattener`
  (straightening curled lines), `Entries` (date headings, entries, reflowing text with a map back to the
  written text), `WordNotes` (words a local reading changed or doubted).
- `Sources/WriteCore/LocalReading`: reading on the Mac. `PageLayout` (straightening, line pitch, reading in
  strips with Vision, letter splitting, scribbles), `Candidates` (look-alikes, dictionary, contractions,
  switching rules), `LocalReader` (the question loop, re-checks on other crops, notes), `DecisionServer`
  (model download, a private `llama-server` under a watchdog, `/v1/systemone` requests).
- `Sources/WriteApp`: SwiftUI app. `AppModel` holds state; `LocalReading.swift` and `LocalReaderViews.swift`
  are the reading-on-this-Mac queue and live window; `UploadSheet` has the crop editor; `JournalTextEditor`
  draws and handles the confidence marks; `Updater` and `UpdateBanner` handle updates.
- `Sources/WriteCheck`: the checks above, with `LocalChecks.swift` for the newer parts.

## Reading on this Mac, in brief

The decision model is MiniCPM-OCR-Jev (Q8_0 GGUF, 2B), downloaded to
`~/Library/Application Support/In Her Own Write/Models`, and run by Homebrew's `llama-server` on 127.0.0.1
with image tokens capped at 8 to 32 (about 170 ms a decision on an M3 Pro). It only answers "is this
candidate right for this crop?", one candidate per request. Vision finds lines by reading the page in
overlapping strips; the model then chooses between spellings and look-alike letters, under rules that
keep it from changing real words into non-words. Details and the reasons are in `docs/EXPERIMENTS.md`.

## Updates

Pushing to `main` is a release. `.github/workflows/release.yml` runs the checks on GitHub's Macs and
publishes the app as the latest release (`In-Her-Own-Write.zip`). Installed apps check GitHub on launch; if
their build commit is behind, they get the new version in the background and show **There has been an
update.** with Update & Restart and Ignore. An app built here from the code builds the update from its clone;
any other copy downloads the latest release. Keep `main` building and `swift run WriteCheck` passing before
every push.
