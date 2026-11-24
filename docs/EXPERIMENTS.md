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

Set aside:

| Option | Why not |
| --- | --- |
| Text-only decision models (OpenDecision-Small 70M, Laya 421M, Tev1 0.8B, Strands Decider 2B) | They can't see the page; choosing letters from text alone is guessing from context. |
| Image-capable choice models (Clef-flash 9B, pplx-decider 27B) | One pass could score many options, but 4 to 13 times larger, and not trained to compare handwriting with a reading. **Not yet tested;** Clef-flash may run in llama.cpp and is worth a head-to-head test. |
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
- **Re-checking corrections:** a changed word is scored again on four other crops (tighter, wider, shifted
  left and right) against Vision's reading and **Something else**, which scores a quarter of the page's
  typical good match. This confirmed genuine fixes, but it can't overturn a misreading the model makes
  consistently; it catches flukes of a single crop.
- **On the messy-handwriting page:** Vision alone made six errors; Quick fixed three of them and added one
  (a real-word swap), for four.

## Scribbled-out writing

OCR reads scribbles as stray letters or skips them, so they are found from the ink: a connected blot whose
box is at least 40% ink, at least half a line tall, with a solid core (ink a little way off in every
direction) of at least 0.2. On the real pages, scribbles had solid cores of 0.3 to 0.4, and letters at most
0.15. Fill alone flagged filled-in letter loops by the dozen (16 false marks across two pages); with the solid
core, the two solid scribbles were found and nothing else was. A scribble made of a loose coil, rather than
solid ink, is still missed. Blots touching the photo's edge or outside a line's span (binding, shadow) are
ignored. Scribbles become "###", as in readings from Claude.

## Fixing words

- After a local reading, words the model changed are underlined and words it wasn't sure of are highlighted
  orange (View → Show Reading Confidence). Clicking one offers the other spellings it weighed, Keep, or Type a
  Correction. The notes are saved with the page and drop off once the word is changed.
- Words can also be fixed in the reading window while the page is still being read; the fixes are applied
  when the page is saved.
- With Accurate Line Breaks off, edits made to the flowing paragraphs are carried back to the text as written,
  so line breaks stay as she wrote them.

## Updating the app

- Updates are built in the background from the repository while the app stays open; the app is closed only
  for the few seconds it takes to swap the new copy in. The first version quit right away and rebuilt, which
  left the app closed for a minute or two.
- The update check never uses the keychain: with the keychain, git asked for permission every launch. A
  private repository needs a read-only deploy key on each Mac; the repository was made public instead, with
  its history started fresh.
