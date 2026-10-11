enum AccountDeletionCopy {
    static let timing = "Normal account deletion requests are handled within 7 calendar days of receipt. We email updates and the result to your verified account contact. If an exception delays completion, we email the status, reason and next update date."
    static let scope = "This covers your LessMeet account and its cloud data. It does not confirm that all internal provider copies are erased."
    static let googleConsequence = "LessMeet handles applicable Google permission revocation. This can affect sign-in across clients in the LessMeet Google project."
    static let confirmation = "Cloud access will be locked and deletion of your account, uploaded audio, transcripts and chat will begin. This cannot be undone here. \(googleConsequence) \(timing) \(scope) Local recordings and saved results remain. Apple billing continues unless you cancel separately; cancellation is not required to request deletion. Deleting this account does not transfer purchases to another account."

    static func googleStatus(_ status: AccountDeletionStatus) -> String? {
        guard status.requested else { return nil }
        switch status.googleStatus {
        case .pending:
            return "Google permission revocation is pending. LessMeet handles this through its service."
        case .revoking:
            return "Google permission revocation is in progress. LessMeet handles this through its service."
        case .acknowledged:
            return "Google accepted permission revocation. This does not confirm that all copies are erased or all provider handling is complete."
        case .exception:
            return "Google permission revocation needs operator handling. LessMeet will email the status, reason and next update date."
        case .notApplicable:
            return "Google permission revocation was verified as not applicable to this request's scope. This does not confirm that all copies are erased."
        case .unknown:
            return "Google permission revocation status is unknown. The operator must check it; completion is not confirmed."
        case nil:
            return "Google permission revocation status was not reported. The operator can check it; this response does not confirm Google revocation."
        }
    }
}
