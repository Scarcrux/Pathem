# Known issues

Behavior we know about in the current release (0.9.4) and have judged minor. Use
this list to triage new reports: if a report matches an entry here, link the entry
instead of opening a new investigation. If a report shows one of these is worse than
described here (data loss, a crash, or a common workflow blocked), treat it as a new
bug and raise its severity.

Last reviewed 2026-11-20, after the launch-QA pass recorded in
[LAUNCH_CHECKLIST.md](LAUNCH_CHECKLIST.md) and the roadmap.

## File operations

- **Hard links in a copied folder become separate files.** Copying a folder, or moving
  it to another disk, turns a pair of hard links inside it into two independent files
  with the same contents. Nothing is lost; the link between them is.
- **A copied folder can get a new modification date.** File contents and metadata
  match exactly, but a folder's own modified date can change during a copy.
- **A file still being written while it is moved to another disk** can miss the
  writes that land after the copy finishes. Pathem copies the file as it is at that
  moment, then removes the original.
- **Replacing a folder swaps the whole folder.** Choosing Replace when a folder with
  the same name exists moves the existing folder to the Trash and puts the new one in
  its place; the two are not merged. The replaced folder can be restored from the
  Trash or with Undo.
- **Rename trims trailing spaces.** A name ending in spaces is saved without them. We
  have not yet confirmed whether Finder does the same.
- **Secure Delete is best-effort.** On APFS and SSDs, copy-on-write and wear leveling
  can keep older copies of the data, an APFS clone keeps its own copy of the original
  bytes, and extended attributes and resource forks are removed but not overwritten.
  The confirmation describes it as best-effort. A file with other hard links
  is removed by name but not overwritten, so the other names keep their contents.

## Onboarding and permissions

- **First launch shows several macOS permission prompts** (Local Network, Documents,
  Desktop and others) on top of the Full Disk Access guide. These come from macOS, one
  per protected location Pathem touches.
- **Full Disk Access applies after a relaunch.** After you add Pathem in System
  Settings, use Relaunch Pathem in the guide.
- **The Full Disk Access guide has extra space under Not Now.** Cosmetic; a fix is in
  progress.

## Layout and language

- **The sidebar's bottom row can sit under the Settings footer** in a very short
  window. Reported once in a test render; not reproduced since.
- **The Date Modified column can truncate dates** at its default width in some
  languages. Widen the column to see the full date.
- **Translations were checked by rendering, not by native speakers.** Wording reports
  from native speakers are welcome.

## Connections and devices

- **SFTP accepts a new server's host key on first connect without asking.** A key that
  later changes is still rejected. A proper "new host key, accept?" prompt is planned.
- **iPhone and iPad browsing needs the device unlocked** while Pathem talks to it.
- **Android (MTP) devices are not supported.**

## Not yet verified on a release build

These have automated or engine-level coverage but have not been exercised by hand on
the release app, so a report here may be a real bug.

- Empty Trash.
- Dragging a file out to Finder and back into Pathem twice in a row.
- Intel Macs (release builds are universal, but no Intel Mac has run them).
- PDF zoom and printing in the preview pane.
