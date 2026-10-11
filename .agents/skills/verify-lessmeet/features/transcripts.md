# Transcripts

Users upload an approved recording, read its transcript and recover saved cloud work.

## Sub-features

- `transcript-create`: review upload consent and create a transcript.
- `transcript-cancel`: dismiss upload consent without submitting.
- `transcript-refresh`: recover a saved transcript through each refresh entry.
- `batch-recover`: inspect saved chunks, continue upload or retry a failed chunk.

## How to get to it (user POV)

- Open a recording from Library or recent items and choose **Transcript**.
- Use **Create Transcript** (or **Try again** after failure).
- Use **Check for transcript**, or **Recording options → Refresh transcript**.
- Saved batches expose **Refresh saved batch**, **Continue saved upload** and
  **Retry failed chunk** when the corresponding state allows them.

## Driving it with Computer Use

Preconditions: approved live account, backend, synthetic audio and explicit upload
and cost authority. The offline fixture cannot verify this feature.

- **Consent.** Click **Create Transcript** through `lmClick`, then capture the notice.
  Click **Cancel**. Verify no new saved remote ID or authorized backend record appeared.
- **Upload.** Reopen the notice and, only with authority, click **Upload and Create Transcript**.
  Capture progress and the resulting transcript. Inspect the selected recording's saved
  remote ID and scoped backend result. Do not infer success from a spinner or HTTP 200.
- **Refresh.** Exercise **Check for transcript** and **Refresh transcript** separately
  when reachable. Expect the saved transcript and unchanged remote ID, without a new upload.
- **Batch.** Use `lmClick` for **Refresh saved batch**; capture chunk states and transcript.
  **Continue saved upload** and **Retry failed chunk** require their own authorized
  scenarios. The retry confirmation is **Retry failed chunk (may incur a charge)**.
  Verify only the intended chunk/attempt changes and original audio stays present.

## Gotchas

- **Stop Waiting** ends local waiting; accepted server work can continue.
- Missing saved IDs do not authorize repeated uploads. A retry can incur another charge.
- A single-recording transcript path does not prove batch upload/recovery.
- Limits, auth and quotas depend on the approved backend. Record the observed errors.
