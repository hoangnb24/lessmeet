# Transcript chat

Historical cloud workflow only. The single-recording cloud chat view and draft
helper are retired. These controls are absent from the current local app.
BatchChatView remains for retained component fixtures, not normal startup.
Use README's ChatGPT/local-transcript procedure for the current app. The steps
below apply only to an approved historical artifact that actually has these controls.

Users ask questions about a transcript and prepare summaries or action-item prompts.

## Sub-features

- `chat-send`: submit from the button and Command-Return.
- `chat-notes`: prepare Summarize and Action items prompts.
- `chat-source`: open and close the source transcript.
- `chat-recover`: refresh an incomplete conversation or stop waiting.
- `batch-chat`: ask about a batch and recover a saved question.

## How to get to it (user POV)

- Open a recording's **Chat** tab with a ready transcript.
- Use **Meeting notes → Summarize / Action items** above the conversation.
- Use **Show transcript**, **Hide transcript** or **Close transcript pane**.
- For a saved batch, use its chat. **Open separate legacy transcript chat** and
  **Back to batch chat** switch between the separate conversations when available.

## Driving it with Computer Use

Preconditions: an approved live account and ready synthetic transcript. Sending,
resending and paid requests require explicit authority; draft preparation does not.

- **Draft.** Click **Question about this recording**, then use `sky.paste` to enter
  the approved question. Capture the draft before sending.
- **Send.** Use `lmClick(index, 'Send question')`; in a separate authorized case use
  `sky.press_key({app: lmApp, key: 'super+Return'})`. Capture question and answer.
  Reopen the recording and verify the saved conversation for the same account.
- **Notes.** Open **Meeting notes**, capture the menu, then choose **Summarize** or
  **Action items**. Each should fill a draft without sending it. Capture the draft
  and unchanged conversation. Restore the prior draft after the check.
- **Source.** Click **Show transcript**, capture the pane, then test **Hide transcript**
  and **Close transcript pane** on separate openings.
- **Recovery.** When shown, use **Refresh conversation** or **Stop waiting for answer**.
  Capture the resulting state and saved messages. Do not infer server cancellation.
- **Batch.** Use **Question about this batch transcript**, **Send question** and
  **Refresh batch chat** for the batch flow. Only an authorized absent-question
  scenario may use **Resend this saved question… → Confirm same-question resend**.
  Observe the same saved question identity and resulting answer.

## Gotchas

- Summary and action-item generation consume a question only after explicit Send.
- Button and keyboard send are separate entry points.
- Legacy and batch chats are separate; success in one does not prove the other.
- Signing out hides account-bound caches. It does not remove local recordings.
