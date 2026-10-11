# Recording library

Users record local microphone and system audio, find recordings and play saved audio.

## Sub-features

- `capture-save`: start, stop and save a consented recording.
- `library-search`: find and clear a title search.
- `library-open`: open from a library card or sidebar recent item.
- `title-save`: edit a title and confirm it after reopening.
- `playback`: play, pause and seek.
- `files`: reveal the saved recording files.

## How to get to it (user POV)

- Use **New recording** in the top bar, then **Stop & Save**.
- Open **Library** and select a recording card, or select a recent sidebar item.
- Use **Search recordings** in the sidebar.
- Open a recording to edit **Recording title** or use its playback controls.
- Open **Recording options** and choose **Show Files**.

## Driving it with Computer Use

Preconditions: approved normal bundle, one UI owner, and an authorized synthetic
recording. Capture needs participant consent and the required macOS permissions.
The offline app has no library. Do not create fixture metadata in the user's store.

- **Capture.** Run `lmClick(index, 'New recording')` and capture the timer/stop state.
  After the agreed sample, click **Stop & Save**. Expect saving to finish and a saved item.
- **Open.** Use `lmClick` on the matching card, then repeat through its recent sidebar
  entry. Each path must show the same title and duration.
- **Search.** Click **Search recordings**, use `sky.paste` with the authorized title,
  then capture matching rows. A unique nonexistent query shows an empty result;
  click **Clear search** to restore the library.
- **Title.** Click **Recording title**, select its text with `sky.press_key` (`super+a`),
  paste a distinct test title, and move focus. Reopen the item and verify the title.
- **Playback.** Click **Play recording**, capture **Pause recording** and advancing
  time, then pause. Use the observed **Playback position** slider to seek. Audio
  quality needs a listening check; changing time alone is insufficient.
- **Files.** Open **Recording options**, click **Show Files**, and observe Finder.
  Inspect only the selected recording's `recording.json`, `combined.m4a` and source
  files. Reopen the app and verify saved title, duration and playback remain usable.

## Gotchas

- Current labels are **New recording** and **Stop & Save**; older README prose differs.
- Normal builds share a recording store. No launch flag provides an isolated library.
- Permission prompts and recording are outside the default skill rehearsal.
- Preserve original source audio when export fails. Never remove user recordings
  as automatic cleanup. Close only Finder windows opened by this run.
