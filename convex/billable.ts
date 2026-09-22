// Fail closed until the owner explicitly approves cost and retention boundaries.
export const billableEnabled = () => process.env.GEMINI_BILLABLE_ENABLED === "true";
export const billablePausedMessage = "Cloud transcription and chat are paused pending cost and retention approval.";
