# share-save-as-auto

Tiny Android app (Flutter): Android share target that accepts anything shared to it (text, URLs, files of any type) and saves it into a user-chosen directory.

- No background execution; app only runs when invoked via share.
- Single screen: shows the target directory + a button to grant permission (SAF folder picker).
- Text shares are saved as `yyyy-MM-dd-HH-mm-ss.json` — a JSON document with the shared text, EXTRA_TITLE / EXTRA_SUBJECT (when present), the intent action, MIME type, the sending app's package (referrer), and the save timestamp.
- Files are saved with their proper extension; if the type can't be detected, `.bin`.
- Share launches return to the sharing app automatically right after saving (a failed save keeps the error visible a few seconds, then closes). Opening from the launcher (no share intent) stays open on the directory screen.

made because tasker share solution was too complicated for my workflow
