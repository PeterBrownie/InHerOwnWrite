# Experiments and decisions

What has been tried for reading pages on this Mac, what was kept, and what was set aside and why. Add to it
whenever something is tested, so the same ground isn't covered twice.

Numbers are from an M3 Pro with 18 GB of memory, November 2026.

## Test pages

No journal content is kept in this repository. Tests used:

- **Invented pages** drawn in handwriting fonts (Bradley Hand, Savoye) by `WriteCheck`: a single page with a
  crossed-out word, and a two-page spread on a dark table with a shadowed fold and a printed page number.
- **Two facing pages of a real journal**, photographed on a dark surface: neat printed handwriting on ruled
  paper, each photo catching a strip of the facing page, a printed page number in the corner, a few
  scribbled-out words, and noticeable curl toward the fold.
- **A page of messy handwriting** on unruled spiral-notebook paper, on a light, speckled counter.

Real photos are only ever read from outside the repository and never copied into it.

## The decision model

**Kept: MiniCPM-OCR-Jev, Q8_0 GGUF (2B), in Homebrew llama.cpp.** It is the only small open decision model
found that looks at images. It answers one question: is this candidate text right for this crop? Each request
carries the crop, a rendered image of one candidate, and that candidate as text, and returns a probability.

- It cannot score several options in one pass. llama.cpp's decision support for this model requires two
  classifier labels and one candidate per request, so a choice among six letters is six requests.
- Its probabilities on handwriting are low and uncalibrated (a correct word often scores 0.02 to 0.05)
  because it was trained on printed documents. Only comparisons between candidates are meaningful, so shares
  (each option's score divided by the total) are used.
- Memory while reading: about 2.9 GB resident, of which about 2.7 GB is the model files mapped from disk.

**Clef-Flash (9B), first test, November 2026.** ggml-org's Q4_K_M build (6.7 GB, plus a 0.6 GB vision
projector), in the same Homebrew `llama-server` and `/v1/systemone` API. Unlike MiniCPM-OCR-Jev, it scores
every option of a `choice` question in one request, and returns a probability for each. It was sent only the
word crop and the spellings as options, with no rendered candidate image. On 70 words from the invented pages
(Bradley Hand and Savoye), each against five look-alike decoys in shuffled order:

| Model | Right | Per word | Memory |
| --- | --- | --- | --- |
| MiniCPM-OCR-Jev, image tokens 8–32, six requests | 68 of 70 | 1,051 ms | about 2.9 GB |
| Clef-Flash Q4_K_M, default image tokens, one request | 70 of 70 | 799 ms | 4.9 GB |

Not yet tried: real handwriting, capped image tokens (the server didn't start with the caps used for
MiniCPM), or using it inside the reader.

Set aside:

| Option | Why not |
| --- | --- |
| Text-only decision models (OpenDecision-Small 70M, Laya 421M, Tev1 0.8B, Strands Decider 2B) | They can't see the page; choosing letters from text alone is guessing from context. |
| Image-capable choice models (Clef-flash 9B, pplx-decider 27B) | One pass could score many options, but 4 to 13 times larger, and not trained to compare handwriting with a reading. Clef-Flash has now had a first test (above); pplx-decider is untested. |
| Tokz OpenDecision, PP-OCRv6 | Text-only classifier; and a recognizer that doesn't rank options (and reads handwriting poorly in its own benchmarks). |

### Speed

| Setting | Per decision | Accuracy on 35 words with 6 decoys each |
| --- | --- | --- |
| Default image tokens, crops at full size | 348 ms | 33 of 35 |
| Crops scaled to 48 px high | 345 ms | 35 of 35 |
| Crops at 32 px | 340 ms | 35 of 35 |
| Image tokens capped at 16–64 | 206 ms | 35 of 35 |
| **Image tokens capped at 8–32 (kept)** | **167 ms** | 35 of 35 |

No effect: four parallel slots (the GPU is already busy, so total time was the same), prompt caching
(`--cache-ram 2048`), flash attention on its own.

## Finding lines, words, and letters

**Kept: Apple Vision, read in strips about one line tall.** Asked about a whole page of handwriting on ruled
paper, Vision's text recognition skipped whole bands of lines (on one real page it lost everything below 40%
of the height) and merged neighboring lines, which made word crops show two lines. On the same page, strips
1.5 line-pitches tall, stepping half a pitch, found every line (about 5 seconds per page). Overlapping strips
read each line more than once, and their differences become options for the model.

- The newer `RecognizeDocumentsRequest` and running Vision on the cropped page alone skipped lines just
  the same.
- **Line pitch** comes from how the ink in each row repeats down the page (autocorrelation of row ink in the
  middle of the page). Vision's box heights were tried first and failed on slanted pages, where boxes are
  taller than the lines, so neighboring lines merged.
- **Straightening:** the page is rotated by the median slant of Vision's longer lines before strips are cut.
  Without it, a level strip on a tilted page caught halves of two lines.
- **Choosing a line's reading:** the reading that agrees most with the other strips' readings of that line
  (not the best-centered one, which was sometimes a cut-off read).
- **Letters:** Vision gives one box per word, not per letter. Letters are split where the ink is faintest
  near where letter widths predict a cut.
- **Strip filter:** a reading is kept if it fills at least 40% of the strip or sits clear of both edges.
  Height alone dropped small, widely spaced writing; edges alone dropped real handwriting, which nearly
  fills each strip.

## Crop, fold, and curl

- **Fold:** found as a valley in column brightness with paper on both sides; the side with more writing is
  the page. Grouping lines into columns was tried first and failed when Vision read lines straight across
  the fold. The cut moves a little past the fold, short of the facing page's text, because writing runs up
  to the fold.
- **Paper edges:** brightness against the background, plus 2% of room so a page number at the edge isn't cut.
- **Page numbers:** a short number alone near the top or bottom. A small printed number was missed in a
  whole-photo pass, so the top and bottom of the crop are also read up close.
- **Both pages in one photo:** the fold is looked for in the middle two-fifths of the paper. Lit evenly,
  it is the darkest column. On two real photos of an open journal lit from one side, the lit page stayed
  bright right up to the fold and the brightness fell by three quarters within about 1% of the width, while
  the shaded page brightened only slowly; the darkest column was 3% inside the shaded page, and the split
  cut off the first letters of its lines. So when one side of the valley climbs at least three times faster
  than the other, the fold is at the foot of the fast climb. The split is then nudged (up to 1.5%) to where
  Vision's lines cross it least. With no shadow, the clearest gap in the writing near the middle is used.
  Both page numbers are looked for; when they don't follow on, the one with more digits wins, since on one
  real photo a printed page number with a faint last digit read as two digits.
- **Which way up:** both real two-page photos were taken with the phone upright, so the pages lay
  sideways. Reading the photo at each quarter turn and keeping the one Vision read most confidently was
  tried first and failed: Vision reads sideways and upside-down handwriting by itself, so all four scored
  alike, and it chose upside down for one photo. Instead, Vision reads the photo once, and each line it
  finds runs along the writing: each long line votes for the quarter turn that levels it, and what's left in
  the winning lines is the tilt (about 1.8° on one photo). Both photos came out upright. A photo of both
  pages is levelled by that tilt so the split line follows the fold; a single page is left to flattening.
- **Straightening by hand:** the Straighten slider turns the crop frame over a still photo instead of turning
  the photo. The first version decoded the full photo (up to 2400 px), turned it, and drew a new preview at
  every step of the slider, without cancelling the step before, and in Result view also re-cropped and
  re-flattened; it lagged badly. Now dragging only redraws the frame, edges move along the frame's own sides,
  and the frame shrinks or moves to stay inside the photo at its angle. The photo is turned and cut once,
  when the page is saved or Result is shown (after the slider rests for a quarter second). Quarter turns
  still turn the photo, so a sideways page is shown upright.
  Shrinking to fit had a cost: once turned, the frame often sat against the photo's edges and couldn't be
  dragged back out. Now an edge dragged past where the turned frame fits eases the turn toward level, only as
  much as that drag needs (to a tenth of a degree), since a level frame has the most room. Dragging back in
  during the same drag gives the turn back; past the photo itself, the edge stops there, level.
- **Flattening curl:** the page is measured in 14 vertical bands and up to 5 rows; each band's row profile
  is lined up with its neighbor's to find how far lines drift, a smooth curve is fitted per row (dropping
  outliers, such as bands catching the page edge), and each column is shifted up or down. On an invented
  page bent by 119 px it removed about 60% of the bend, and the real pages came out level. Rows that are
  mostly dark (table, shadow) are ignored. It only moves pixels up and down; text squeezed sideways into the
  fold isn't stretched back out.

## Deciding words and letters

- **Order:** a whole-word question first, then letters. **Quick** checks letters only where the word was a
  close call (under 60%); **Careful** checks them unless the model was at least 90% sure. Careful replaced an
  every-letter mode: on an invented page it cut decisions from 1,180 to 655.
- **Changing what Vision read is held back**, because the model's small preferences were often wrong:
  - It never turns a real word into a non-word (it had turned "pm" into "prn").
  - A swap between two real words needs 2.55 times the evidence; it still made such swaps when confident,
    because it judges shape, not meaning.
  - Turning a non-word into a real word needs the least (1.2 times); these were its best corrections.
  - Changes in length (m and rn) need 1.4 times more; changes only in capitals need twice as much.
- **The dictionary** is the system word list with rare short words removed (it counted words like "nou" as
  real, which let misreadings through), plus common short words, month and weekday abbreviations,
  contractions, and every word already in her journals. It lists some contractions without their apostrophe,
  which are removed so the fix counts as non-word to word.
- **Look-alikes:** each letter has up to nine look-alike letters or pairs; real words one look-alike away
  are offered as spellings.
- **Apostrophes:** Vision often drops them or reads them as a letter, so contractions are offered as options:
  the same letters without the apostrophe, or one letter where the apostrophe goes. On the two real journal
  pages, Vision missed or misread 5 apostrophes; Quick restored all 5 and changed none that were right.
- **The spell checker's guesses:** for a word Vision read that isn't in the dictionary, macOS's spell checker
  (`NSSpellChecker`, its correction and guesses) is asked from the main thread before the word's question,
  and up to three single-word guesses within two letters of the reading that are real words join the
  spellings the model scores. Look-alikes only swap one letter for another, so a reading with a letter
  missing or extra, like a dropped "c" in a long word, had no right option. The guesses are held to the
  same switching rules as every other option (a change of length needs 1.4 times more).
- **Re-checking corrections:** a changed word is scored again on four other crops (tighter, wider, shifted
  left and right) against Vision's reading and **Something else**, which scores a quarter of the page's
  typical good match. This confirmed genuine fixes, but it can't overturn a misreading the model makes
  consistently; it catches flukes of a single crop.
- **On the messy-handwriting page:** Vision alone made six errors; Quick fixed three of them and added one
  (a real-word swap), for four.

- **Resuming:** a reading on this Mac is saved with the page, encrypted, as each line finishes and whenever
  a word is fixed: the decided words, their notes, the match scores so far, and her fixes. Reading the page
  again (**Resume on This Mac**) finds the lines again, about 5 seconds, and skips the finished lines when
  the layout matches word for word; otherwise it starts over. **Start Reading on This Mac Over** in the page
  menu discards it, and any finished reading clears it. On the invented page, resuming after the first two
  lines made 135 decisions instead of 164 and gave the same text.

## Scribbled-out writing

OCR reads scribbles as stray letters or skips them, so they are found from the ink: a connected blot whose
box is at least 35% ink (40% at first), at least half a line tall, with a solid core (ink a little way off in every
direction) of at least 0.2. On the real pages, scribbles had solid cores of 0.3 to 0.4, and letters at most
0.15. Fill alone flagged filled-in letter loops by the dozen (16 false marks across two pages); with the solid
core, the two solid scribbles were found and nothing else was.

**Loose coils.** A scribble drawn as a loose coil, on one of the ruled pages, was missed, but not for being
loose. It touched a printed ruled line, and at the usual threshold the rules count as ink, so the coil, the
rules, and the dark page edge made one blot the size of the page. The rules are lighter than pen ink:
counting only ink a fifth darker (80% of the threshold) drops them, and the coil stands alone with a solid
core of 0.42, against at most 0.11 for any letter, but a fill of only 0.39. So scribbles are now looked for
at both thresholds (overlapping finds counted once), and fill needs only 0.35; the solid core is what tells
scribbles from letters. On the three real pages this finds all three scribbles, the coil included, and
nothing else. At 65% the solid scribble on the other ruled page broke apart, so 80% was kept.

Also tried: counting how many strokes each row and column of a small window crosses, with no blots at all.
The coil ranked sixth on its page, behind windows on the dark page edge and the facing page's strip, so
it was set aside. Blots touching the photo's edge or outside a line's span (binding, shadow) are
ignored. Scribbles become "###", as in readings from Claude.

## Fixing words

- After a local reading, words the model changed are underlined and words it wasn't sure of are highlighted
  green (View → Show Reading Confidence). Clicking one offers the other spellings it weighed, Keep, or Type a
  Correction. The notes are saved with the page and drop off once the word is changed.
- Words can also be fixed in the reading window while the page is still being read; the fixes are applied
  when the page is saved.
- **Removing a word** that isn't on the page: in the reading window, empty a word's field and choose Remove.
  It stays struck through, with Restore, until the page is saved; then it's dropped, and notes on later words
  in its line move back by one so their marks stay on the right word.
- **Where each word is:** a noted word carries its outline on the photo as saved. The reader levels the page
  by turning it about its center, so the word's box on the levelled page is turned back by the same angle,
  which gives four corners on the photo. That way the page view needs no levelled copy of the photo.
  Clicking a marked word outlines it on the photo; clicking a word in the reading window outlines it there.
- **Coloring the ink:** with Show Reading Confidence on, the ink of each noted word is recolored on the photo,
  red for words the model changed and green for close calls, in the page view and live in the reading
  window. Within the word's outline, a pixel is ink when it is darker than 55% of the way from the paper
  (the 75th percentile of the outline) to the pen (the 2nd percentile), so faint show-through and the facing
  page's ink stay uncolored. Vision's word boxes on handwriting run into the neighboring lines (on the real
  ruled page they were 1.6 line spacings tall), so each box is first cut to its line's band, from halfway to
  the line above to halfway to the line below; the outline saved with a note is cut the same way. On the
  three real pages, every word had at least half its ink tinted (median 91 to 100%, lowest 52%), and the
  printed ruling and show-through stayed clear. Not yet tried on joined-up cursive.
- With Accurate Line Breaks off, edits made to the flowing paragraphs are carried back to the text as written,
  so line breaks stay as she wrote them.

## Updating the app

- Updates are built in the background from the repository while the app stays open; the app is closed only
  for the few seconds it takes to swap the new copy in. The first version quit right away and rebuilt, which
  left the app closed for a minute or two.
- The update bar sits in the library's detail column, below the title bar, with its color kept inside the
  bar. It used to be attached to the whole window, where it tinted the title bar and the top of the sidebar
  and covered the "Journals" header. Screens without the sidebar (unlock, setup) still show it across the top.
- The update check never uses the keychain: with the keychain, git asked for permission every launch. A
  private repository needs a read-only deploy key on each Mac; the repository was made public instead, with
  its history started fresh.
- A copy of the app sent to another Mac (AirDrop or download) updates from GitHub's releases instead of
  building from a clone: GitHub builds and checks every push to `main`, and the app downloads the zip,
  checks its bundle identifier, code signature, and GitHub's checksum, and swaps it in. A Mac that was sent
  the app needs no developer tools, no clone, and no build that could fail where nobody can see why. Macs
  with a clone keep building updates themselves.

## Storing photos

- Photos take almost all of the vault (text is a few kilobytes a page), and they're encrypted, so the
  database file can't be compressed afterwards; only the way a photo is encoded can make it smaller.
- Tested on the five real test photos at 2400 pixels, measured against an uncompressed copy (PSNR):
  HEIC at quality 0.86 matches JPEG at 0.86 and takes about 60% of the space. JPEG at 0.75 or 0.65 saves
  less and looks worse than HEIC at 0.86. Black and white saves nothing. Even HEIC at 0.5 (about a quarter
  of the space) looked the same in close-ups, but 0.86 was kept to leave room for local reading.
- **Kept:** pages are stored as HEIC at 0.86 (about 50 ms a page), and turned back into a JPEG when sent to
  Claude, since the API doesn't take HEIC. Pages saved as JPEG before are converted in the background
  while the library is open, one every half second. A page with a reading on this Mac saved partway is
  skipped until that reading is finished, because the saved reading is matched to the photo it started on
  and a re-encoded photo could make it start over.
- Free space left in the vault by deleted pages is wiped (`secure_delete`) and reused by new pages, so it
  doesn't grow; it isn't worth vacuuming.

## Finding the same page twice

Tested November 25, 2026 on the approved real photos: two photos of the same open journal in different
light (four pages), two other single pages, and one page of different paper. Each page was cropped and
flattened as the app saves it, and again with a 3% looser crop and no flattening, as a less careful
second save would be.

| Fingerprint | Same page | Different pages |
| --- | --- | --- |
| Ink map, 48 × 64, rows and columns centered, shifts of ±3 cells | 0.36 to 0.76 | up to 0.42 |
| Ink map fitted to the writing's own extent instead of the crop | 0.32 to 0.83 | up to 0.36 |
| Vision's words, share of word pairs in common | 0.47 to 0.80 | 0.06 or less |

- **Kept:** Vision's words. Handwriting is misread, but the same page is misread the same way, and pages
  share few pairs of words in a row. A score of 0.25 or more counts as the same page. It takes about a
  second a page; pages saved before are fingerprinted in the background while the library is open.
- The ink maps were set aside: ruled lines and the rhythm of lines of writing make different pages of one
  notebook look alike, and a looser crop or a strip of the facing page moves the map more than a few
  cells' shift can absorb.
- Also: the same file dropped twice is caught by a digest of its bytes, and after reading, pages whose text
  shares 60% or more of its runs of four words with another page are marked as possible copies.

## Future ideas

Not started. Listed so they aren't forgotten.

- **Switch the decision model to Clef-Flash?** It did better than MiniCPM-OCR-Jev in a first test (below).
  Before switching: get its image-token caps working (the server didn't come up with
  `--image-min-tokens 8 --image-max-tokens 32`; not looked into), try it on real handwriting, and weigh
  the 7.4 GB download and about 5 GB of memory against 2.7 GB.

- **Try the spell checker's guesses on real pages.** They pass the offline checks and leave the invented
  page's reading unchanged, but haven't been measured with the model on real handwriting, where words with a
  missing or extra letter actually occur.
- **Try the ink tint on joined-up cursive.** It was checked on neat printing and on messy unruled writing;
  cursive word boxes may be looser.
- **More analysis of entries** (approved for later, November 24, 2026), alongside the Entries section (weekdays,
  streaks, and time of day are built):
  - entry length over time (average words per entry by month) and the longest entries;
  - when each name first appears, and who comes up most each month;
  - words and pages written per month.

  Also suggested and not chosen: "on this day", entries from the same date in earlier years.
- **Ripped-out pages.** Pages are sometimes torn out, so the notebook's printed page numbers skip. Built so
  far (November 25, 2026): a "Continued from an earlier page" entry after a skip has **Merge with Previous
  Entry**, which saves on that page that it follows on (`PageInfo.followsOn`), and the merged entry can be
  split again. Not built: when the page being viewed has a previous or next page whose number skips, a
  small control to say that one or more pages were ripped out there. It should stay quiet: nothing in the
  journal marks a ripped page; she just sees the page numbers skip.
- **Two pages with different heights.** A photo of both pages is cut with one frame around both, split at
  the fold. When one page sits much higher than the other, each page's top and bottom could be found
  separately instead.
- **Scroll the photo to an outlined word.** When the photo pane is zoomed in, clicking a marked word outlines
  it but doesn't scroll it into view.

- **Custom stats that add up amounts** (November 25, 2026). Stats count instances. "How many hours did I
  sleep?" or "How much did I spend?" would need each instance to carry a number and the chart to sum them.

- **Lowercase ordinary words in the word counts** (asked for November 24, 2026). The word list shows each
  word's most common spelling, so a word that often starts a sentence shows capitalized. Show ordinary
  words in lowercase, and keep capitals only for names (the names found on pages, and people's names) and
  titles. One way to spot titles: words written with a capital mostly in the middle of a sentence.

## Known issues

- **Custom stats haven't been tried against the real API** (November 25, 2026). The requests, schemas, and
  saving pass the offline checks with a stubbed network. Planning a stat and counting old pages were first
  run live in the app on November 25, 2026: counting crashed as soon as a quote came back that wasn't
  written word for word in one entry (fixed in build 49). Counting while a page is read hasn't been run
  live, and the quality of Claude's counts and quotes is unmeasured. The duplicate warnings in the add-page sheet and on pages haven't been tried by
  hand either.

- **Not yet tried by hand in the installed app** (as of November 24, 2026): the turning crop frame (and easing the turn by dragging an edge out), the people button and counting people in Analysis, renaming a name on every page, the Storage list in Settings, sorting and starring entries, merging a continued entry with the one before, clicking a week in Analysis and the chart's hover brightening (offscreen renders can't hover), keeping photos as HEIC and converting older pages, removing
  and restoring words in the reading window, Resume on This Mac after quitting, the word outline, the ink
  tint, adding both pages from one photo, and dropping several photos at once. They pass
  `swift run WriteCheck` and look right in `--render` screenshots, and resuming was checked
  with the real model (`--local`), but none has been used in the app itself yet.
- **Unlocking with Touch ID or Apple Watch hasn't been tried by hand** (November 24, 2026). The checks cover
  the vault side with a software key, and a probe confirmed that a Secure Enclave key can be made and used by
  an ad-hoc signed program like this app. Not yet confirmed: that one Touch ID prompt is enough (the app
  passes the approved prompt on to the enclave, so it shouldn't ask twice), and that the watch works, since the
  Mac it was built on has no paired watch. The Keychain was not used: its Touch ID items need a
  `keychain-access-groups` entitlement, which a build signed without Xcode or a team can't have.
