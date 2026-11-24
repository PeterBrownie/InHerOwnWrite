# In Her Own Write

A private Mac app for turning photos of handwritten journal pages into an encrypted, searchable
library. The name nods to *In His Own Write*, John Lennon's 1964 book of stories and drawings.

## Start

1. On a Mac that has the code, double-click `Start In Her Own Write.command`. It builds the app and
   installs it in `~/Applications`.
2. To give it to someone else, zip that app (Control-click it, then **Compress**) and AirDrop the zip.
   They move the app into Applications and open it. The first time, macOS blocks it because it isn't
   from the App Store. Open **System Settings → Privacy & Security**, scroll down, and click
   **Open Anyway**.
3. Choose a password and write down the recovery key.
4. Paste an Anthropic API key from [console.anthropic.com](https://console.anthropic.com).

The app works on Apple silicon Macs running macOS 15 or later. Journals live in that Mac's
Application Support folder, not inside the app, so replacing the app with a newer one keeps them.

## Updates

An app installed from a copy of this repository keeps itself current. Each time it opens, it checks the
repository's GitHub branch. If there are newer commits, a bar says **There has been an update.** with
**Update & Restart** and **Ignore**. Meanwhile, with the app still open and usable, the new version is
pulled and built in the background, which takes about a minute. Update & Restart waits for that build if
it isn't done, then quits, swaps the new copy in, and reopens, which takes a few seconds. Ignore hides the
bar until the next launch. **In Her Own Write → Check for Updates…** checks right away.

To set up a Mac to receive updates:

1. Install Apple's Command Line Tools (`xcode-select --install`).
2. For a private repository, give that Mac a read-only deploy key, so it needs no GitHub account: run
   `ssh-keygen -t ed25519 -N "" -f ~/.ssh/in_her_own_write` on it, add the `.pub` file's contents under the
   repository's **Settings → Deploy keys**, and add to `~/.ssh/config`:
   `Host github.com` / `IdentityFile ~/.ssh/in_her_own_write`.
3. Clone the repository, for example `git clone git@github.com:<you>/<repo>.git ~/In-Her-Own-Write`
   (or the `https://` address for a public repository).
4. Double-click `Start In Her Own Write.command` in that folder once.

The app never asks for a password and never touches the keychain; without access, it skips the update.

After that, pushing to the branch is enough. Updates only move forward: a copy with unpushed commits, or
one that can't fast-forward, keeps its current version. If a pull or build fails, the installed version
stays, and the details are in `~/Library/Logs/In Her Own Write/update.log`.

Anyone who can push to the repository can change the app that opens her journal, so keep it to accounts
you trust, with two-factor sign-in. The repository's `.gitignore` keeps photos and databases out of it.

## Adding a page

Press **+** or ⌘N and drop in a photo. With no journals yet, the sheet first asks for the first
journal's name.

- **Crop.** The app finds the page being added and darkens everything else: the table, and any strip of
  the facing page past the fold. Drag the edges or corners to adjust it, or drag inside to move it. Only
  the bright part is saved and read.
- **Turn.** The rotate buttons turn a sideways photo a quarter turn and look for the page again;
  **Straighten** levels a tilted page by up to 15°.
- **Flatten curved pages.** On by default. Lines of writing that bend toward the fold or slope across the
  photo are straightened before the page is saved. **Result** shows exactly what will be saved and read.
- **Page number.** A number printed or written alone at the top or bottom of the page fills in the page
  number. Typing a number replaces it.

The page is encrypted and saved first, then read in the background, so you can move straight to the next
page. A page that can't be read keeps its photo and can be retried.

## Reading and analysis

- **Pages or entries.** Each page is split into entries wherever a date line starts one, so an entry can be
  part of a page or run across several. A date written without a year takes its year from nearby entries.
  Editing a date line in the text updates the entry.
- **Reading controls.** Show or hide the photo, show one page or two, and flip with ⌘[ and ⌘]. Accurate
  Line Breaks (View menu or Settings) shows lines as written; turn it off to read flowing paragraphs. Text
  can be edited either way; with line breaks off, each change is made to the text as written.
- **Analysis.** Choose journals and page ranges, see top words (hide any you don't want), the names Claude
  found, and how often any word or name appears over time.

## Reading on this Mac (experimental)

Choose **This Mac** under **Read with** when adding a page, or click **Read on This Mac** under any page. The
page is read without leaving the Mac, and the **Reading on This Mac** window (⌥⌘R) shows the work live.

1. The page is straightened, and Apple's Vision framework, built into macOS, reads it in overlapping strips
   about one line tall. Asked about a whole page of handwriting on ruled paper, Vision skips lines and
   merges neighbors; asked about a strip, it reads the line in it. The overlapping strips read each line
   more than once, and the differences become options for the model. Each word is split into letters at
   the faintest columns of ink. A page number is left out of the text.
2. A decision model, [MiniCPM-OCR-Jev](https://huggingface.co/openbmb/MiniCPM-OCR-Jev-gguf) (2B parameters),
   answers one question at a time: does this text match this crop of handwriting? Comparing the answers picks
   between look-alike spellings of a word, and then between look-alike letters (a/o/u, n/m/rn, l/t, and
   so on). **Quick** checks letters only where the word was a close call (under 60%). **Careful** checks
   them everywhere except words the model is already sure of (90% or more). The model compares shapes, not
   meaning, so it is held back: it never turns a real word into a non-word, needs strong evidence to swap
   one real word for another, and needs the least to turn a non-word into a real word ("tbe" into "the").
   A word the model changes is checked again on four other crops of it (tighter, wider, shifted left and
   right), against Vision's reading and **Something else**. Something else wins when neither spelling
   matches as well as a quarter of a typical good match on the page; then Vision's reading stays, marked
   as a close call.
   Contractions Vision read without their apostrophe ("didnt") are offered with it. Writing scribbled out
   with solid ink is found from the ink itself and becomes "###", as in readings from Claude.
3. The text is saved to the page like any other reading. Date lines become entries, but names aren't found.

**Fixing words.** In the page text, words the model wasn't sure of are highlighted green, and words it
changed are underlined (**View → Show Reading Confidence** turns this off). Click one to see what Vision
first read, pick another spelling, keep it, or type a correction. In the reading window, any word already
decided can be clicked and fixed while the rest of the page is still being read; the fixes are saved with
the page.

It needs llama.cpp (`brew install llama.cpp`) and a one-time 2.7 GB model download from Hugging Face. On an
M3 Pro, finding the lines takes about 5 seconds and each decision about 170 ms. **Quick** reads a short
invented page in about 45 seconds; **Careful** takes longer. While reading, the model
uses about 3 GB of memory, which is freed 3 minutes after the last page. The model runs in a private
process on 127.0.0.1 that stops when the app quits or locks.

`swift run WriteCheck --local` reads an invented page with the real model and compares it with Vision alone
(add `--thorough` for Careful mode).

## What is protected

- Journal names, page numbers, photos, transcriptions, entry dates, names, hidden words, and the API key
  are encrypted with AES-256-GCM before they reach the database.
- The encryption key comes from her password through PBKDF2-HMAC-SHA256 with 2,000,000 iterations.
- The app locks after 10 idle minutes, and when the Mac sleeps or the screen locks.
- Location and camera details are removed from each photo before it is stored or sent.

## What to know

- **Each photo leaves the Mac.** It goes over HTTPS directly to Anthropic to be read, and the returned
  text is stored encrypted. Anthropic's data handling is covered by its
  [commercial terms and privacy policy](https://www.anthropic.com/legal).
- **A lost password and a lost recovery key mean the journals are gone.** Nobody can recover them.
- **Original photos are not touched.** Delete them from Photos, Downloads, or iCloud if they should
  live only in the vault.
- **The password can't protect an unlocked app.** Anyone using the Mac while it is unlocked can read it.
- **The database shows how many pages exist and their rough sizes**, but not what or whose they are.

## Data and backups

The vault is one file: `~/Library/Application Support/In Her Own Write/journal.vault`. Copying it is a
complete backup, and it stays encrypted in Time Machine or anywhere else.

## Checks

`swift run WriteCheck` tests the encryption, database, photo cleanup, and API handling with synthetic
pages and a stubbed network. It sends nothing to Anthropic. With `ANTHROPIC_API_KEY` set,
`swift run WriteCheck --live` reads one invented handwritten page through the real API.

## For developers

`CLAUDE.md` covers building, the checks, where things are, and the rules for this public repository.
`docs/EXPERIMENTS.md` records what has been tried for reading on the Mac, what was kept and why, and the
lists of future ideas and known issues.
