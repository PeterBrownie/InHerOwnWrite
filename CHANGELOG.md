# Changelog

What changed in each build of In Her Own Write, newest first. A build's number is the number of commits on
`main` when it was pushed (`git rev-list --count HEAD`). It's shown as the version in brackets in **In Her
Own Write → About In Her Own Write**, and in the title of the matching GitHub release.

Builds pushed before this file was started (GitHub's builds 1 to 7) aren't listed.

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
