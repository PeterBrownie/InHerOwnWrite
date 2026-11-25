# Changelog

What changed in each build of In Her Own Write, newest first. A build's number is the number of commits on
`main` when it was pushed (`git rev-list --count HEAD`). It's shown as the version in brackets in **In Her
Own Write → About In Her Own Write**, and in the title of the matching GitHub release.

Builds pushed before this file was started (GitHub's builds 1 to 7) aren't listed.

## Build 47 (November 25, 2026)

- **Make your own stats.** **New Stat…** in Analysis counts something you ask in your own words, such as
  "How many times did I cry?". Claude suggests a name like "Cry Count", what counts as one, and the words
  that show it, from the question alone. Count the words on this Mac, instantly, or have Claude read each
  page's text and quote every instance. Older pages are sent as text, never photos; new pages are counted
  in the same request that reads them. Each stat has its total, a chart over time, and a list of where it
  was found.
- **Pages saved twice are noticed.** The same photo dropped twice is left out. A new photo that looks like
  a page already saved says which page before you save it, with **Skip This Photo**. A page whose text
  nearly repeats another page's says so at the top, with a button to open the other one. Pages saved
  before this update are checked quietly in the background.
- **Word ranks.** Each word in **Top words** shows its place in the list.
- **Typing in Analysis no longer lags.** The search box now waits for a one-second pause (or Return)
  without redrawing the charts and lists at every key press.
- **Clicking a word or name goes back to the top** of Analysis, where its chart is shown. ⌘-click still
  adds it to the comparison without moving.

## Build 46 (November 25, 2026)

- **Click a week in Analysis to see its entries.** In the Entries chart, clicking a week (or a month) opens
  the Entries list showing just the entries from it, labeled at the top. Click ✕ on the label to see all
  entries again.
- **Chart details no longer cover the bar.** The details shown when you point at a bar sit above it, or
  beside it when the bar is too tall.
- **Bars light up when you point at them**, brightening a little and fading back as the pointer leaves.
- **Clearer reading buttons.** A page that hasn't been read now says **Read with Claude**. On a page that's
  already read, reading on this Mac has moved into the page's **⋯** menu as **Read Again on This Mac**, next
  to **Read Again with Claude…**.

## Build 45 (November 25, 2026)

- **Sort entries.** Above the entries list, sort by date or by length, oldest or newest first, shortest or
  longest first. Sorting by length shows each entry's word count.
- **Star entries.** Click the star beside an entry's date, or right-click it in the list, to star it. Turn on
  **Starred** above the list to see starred entries from every journal. Stars stay with their entry when you
  edit the page or change its date.
- **Merge a continued entry with the one before.** When page numbers skip, the next page's first entry shows
  as "Continued from an earlier page". Its **⋯** button now has **Merge with Previous Entry**; the merged
  entry's **⋯** has **Split at Page N** to undo it.

## Build 43 (November 24, 2026)

- **Page photos take about 40% less space.** New pages are saved as HEIC instead of JPEG, with no visible
  difference. Pages saved before are converted quietly in the background while the library is open; a page
  partway through a reading on this Mac waits until that reading is finished.

## Build 42 (November 24, 2026)

- **Analysis lists every name.** The **Names** list no longer stops at 40, and a name found on a page now
  stays in it even when it isn't in the entries' text (only in a heading, say), shown with 0 mentions.

## Build 41 (November 24, 2026)

- **Searched words are highlighted where you read them.** After searching your journals, the words are
  highlighted in yellow in the entry or page you open, and the first one is scrolled into view. Opening a
  place from Analysis's **Where it appears** highlights the word there too.
- **Rename a name everywhere.** In Analysis, each name in the **Names** list has **Rename…**, which gives it
  a fuller name, like a last name, on every page where it's written. The text stays as written.
- In two-page view, the pages now always split exactly in half; the middle no longer moves around.

## Build 40 (November 24, 2026)

- **Analysis search no longer lags while typing.** It waits until you pause for a second before looking the
  words up and redrawing the charts. Press Return to look up right away.

## Build 39 (November 24, 2026)

- **Analysis counts people, not just names as written.** Once a page says who a name means, the Names list
  counts it as that person ("Hannah K."), and a first name that could mean more than one person shows as
  "Hannah (unsure which)". Click a person to see every place they're mentioned, under whatever name was
  written. A first name inside a full name ("Hannah Kim") now counts once, as the full name.
- **See how much room each journal takes.** Settings has a Storage section listing each journal's pages and
  size on this Mac (photos, text, and everything kept with them), the whole vault file, and the model for
  reading on this Mac if it's downloaded.

## Build 38 (November 24, 2026)

- **Say who a name means.** A page's footer now shows how many people it names, like **2 people**, with an
  orange mark when a first name could mean more than one person. Click it to give each name a last name or
  initial ("Hannah K."), or pick someone already known by that first name. Analysis doesn't count people by
  these choices yet.
- **Crop edges no longer get stuck after straightening.** When a page is turned with **Straighten**, you can
  keep dragging an edge or corner of the crop outward; the turn eases toward level just enough to make room,
  and the Straighten slider follows. Drag back in before letting go to get the turn back.
- In Analysis, the words and names you've chosen are tinted in the **Top words** and **Names** lists, in their
  chart colors when comparing several, so you can see what's selected without scrolling up.
- The **Usual time over time** chart puts earlier times at the top.
- Hovering a point on an over-time chart no longer covers the line: the details sit above or below it.
- When the Entries stats need two rows, they split evenly instead of leaving one on its own.

## Build 36 (November 24, 2026)

- **See how your averages changed.** In Analysis, click **Average per month**, **Average per week**, or
  **Usual time** to see a line of where that figure stood at the end of each month or week, counting only
  entries dated up to then. Click it again, or **Close**, to hide it. Usual time follows the Per Month / Per
  Week switch.
- **Pages read by Claude go three at a time** instead of one after another, so a stack of photos finishes
  sooner.
- In Analysis, a stat like **10:00 PM** no longer breaks onto two lines; when the tiles run out of room, they
  move to a second row instead.

## Build 33 (November 24, 2026)

- **Liquid Glass on Macs that build the app themselves.** Copies built from the code recorded the wrong
  macOS version, so they showed the older look. Copies downloaded from GitHub already had Liquid Glass.
- In Analysis, the dates under **Longest streak** and **Longest gap** show on two lines instead of being
  cut off.
- Groundwork for telling apart two people with the same first name (nothing to see yet).

## Build 30 (November 24, 2026)

- **Unlock with Touch ID or Apple Watch.** Turn it on in Settings. The journal then opens with a touch, or
  with a nearby unlocked Apple Watch, instead of the password. The password and recovery key still work, and
  turning the setting off removes the stored copy of the key.
- In Analysis, **Where it appears** lists the first 5 places, with **Show All** for the rest (it was 25).
- Builds are now numbered by their commit count, shown in About In Her Own Write and in the release title.
  The previous release was GitHub's build 7, so the numbers jump.
