import XCTest
import Foundation
import Security
import CryptoKit
@testable import LessMeet

@MainActor
final class ChatGPTAuthTests: XCTestCase {
    func testPKCEIsFreshAndS256() throws {
        let uri = URL(string: "http://127.0.0.1:43123/auth/callback")!
        let a = try ChatGPTAuthAttempt(redirectURI: uri, clientID: nil)
        let b = try ChatGPTAuthAttempt(redirectURI: uri, clientID: nil)
        XCTAssertEqual(a.verifier.count, 43)
        XCTAssertNotEqual(a.verifier, b.verifier)
        XCTAssertNotEqual(a.state, b.state)
        XCTAssertNotEqual(a.nonce, b.nonce)
        XCTAssertNotEqual(a.state, a.nonce)
        XCTAssertEqual(a.challenge, ChatGPTAuthConstants.base64URL(Data(SHA256.hash(data: Data(a.verifier.utf8)))))
    }

    func testCallbackRejectsAmbiguityStateClientAndErrors() throws {
        let uri = URL(string: "http://127.0.0.1:43123/auth/callback")!
        let attempt = try ChatGPTAuthAttempt(redirectURI: uri, clientID: "oaiapp_fixture")
        func url(_ query: String, host: String = "127.0.0.1", path: String = "/auth/callback") -> URL {
            URL(string: "http://\(host):43123\(path)?\(query)")!
        }
        let valid = "state=\(attempt.state)&code=fixture-code"
        XCTAssertEqual(try attempt.callback(url(valid)).clientID, "oaiapp_fixture")
        for query in ["state=wrong&code=fixture-code", valid + "&state=duplicate", valid + "&client_id=other",
                      valid + "&error=access_denied", "state=\(attempt.state)&code=", "code=fixture-code"] {
            XCTAssertThrowsError(try attempt.callback(url(query)))
        }
        XCTAssertThrowsError(try attempt.callback(url(valid, host: "localhost")))
        XCTAssertThrowsError(try attempt.callback(url(valid, path: "/callback")))
        XCTAssertThrowsError(try attempt.callback(url("state=\(attempt.state)&error=access_denied"))) {
            XCTAssertEqual($0 as? ChatGPTAuthError, .oauth("access_denied"))
        }
        let fresh = try ChatGPTAuthAttempt(redirectURI: uri, clientID: nil)
        XCTAssertThrowsError(try fresh.callback(url("state=\(fresh.state)&code=fixture-code")))
        XCTAssertThrowsError(try fresh.callback(url("state=\(fresh.state)&code=fixture-code&client_id=dynamic_agent_client")))
    }

    func testHTTPCallbackRejectsDuplicateHostBodyAndWrongTarget() throws {
        let uri = URL(string: "http://127.0.0.1:43123/auth/callback")!
        let valid = "GET /auth/callback?state=fixture HTTP/1.1\r\nHost: 127.0.0.1:43123\r\n\r\n"
        XCTAssertEqual(try ChatGPTLoopbackListener.parseRequest(Data(valid.utf8), redirectURI: uri).path, "/auth/callback")
        for request in [valid.replacingOccurrences(of: "GET", with: "POST"),
                        valid.replacingOccurrences(of: "Host:", with: "Host: invalid\r\nHost:"),
                        valid.replacingOccurrences(of: "127.0.0.1:43123", with: "localhost:43123"),
                        valid.replacingOccurrences(of: "/auth/callback?", with: "http://attacker.invalid/?"),
                        valid + "body", valid.replacingOccurrences(of: "Host:", with: "Transfer-Encoding: chunked\r\nHost:")] {
            XCTAssertThrowsError(try ChatGPTLoopbackListener.parseRequest(Data(request.utf8), redirectURI: uri))
        }
    }

    func testJWTSignatureAndRequiredClaims() throws {
        let fixture = try ChatGPTAuthSigningFixture()
        let good = try fixture.token()
        let identity = try fixture.verify(good)
        XCTAssertEqual(identity.subject, "fixture-subject")
        XCTAssertNotEqual(identity.profile(clientID: "one").id, identity.profile(clientID: "two").id)
        var parts = good.split(separator: ".").map(String.init)
        var signature = try ChatGPTAuthConstants.decodeBase64URL(parts[2])
        signature[0] ^= 1
        parts[2] = ChatGPTAuthConstants.base64URL(signature)
        XCTAssertThrowsError(try fixture.verify(parts.joined(separator: ".")))
        for claims: [String: Any] in [["nonce": "wrong"], ["sub": "other"], ["sub": ""],
                                     ["iss": "https://wrong.invalid"], ["aud": "wrong"],
                                     ["exp": 999], ["iat": 2000], ["nbf": 2000],
                                     ["aud": ["oaiapp_fixture", "other"]], ["azp": "other"]] {
            XCTAssertThrowsError(try fixture.verify(fixture.token(overrides: claims)))
        }
        XCTAssertThrowsError(try fixture.verify(fixture.token(algorithm: "none")))
        XCTAssertThrowsError(try fixture.verify(fixture.token(algorithm: "HS256")))
        XCTAssertThrowsError(try fixture.verify(fixture.token(kid: "unknown")))
        XCTAssertThrowsError(try fixture.verify(fixture.token(omit: "iat")))
        XCTAssertThrowsError(try fixture.verify(fixture.token(omit: "nonce")))
        XCTAssertNoThrow(try fixture.verify(fixture.token(overrides: ["aud": ["oaiapp_fixture", "other"], "azp": "oaiapp_fixture"])))
    }

    func testSignInPlanAndIdentityOnlyConsent() async throws {
        let h = try ChatGPTAuthHarness()
        let session = h.session()
        await session.signIn()
        XCTAssertNil(session.error)
        XCTAssertEqual(session.profiles.count, 1)
        XCTAssertNotNil(session.activeProfileID)
        XCTAssertFalse(session.canUseChatGPTPlan)
        XCTAssertEqual(h.authorization?["client_id"], "dynamic_agent_client")
        XCTAssertEqual(h.authorization?["agent_name_hint"], "LessMeet")
        XCTAssertNil(h.authorization?["prompt"])
        XCTAssertEqual(h.authorization?["scope"], ChatGPTAuthConstants.planScopes)
        XCTAssertTrue(h.listenerStartedBeforeBrowser)
        await assertThrows(.consent) { try await session.accessToken() }
        let previousSession = session.sessionIdentifier
        let host = try h.record().hostID
        h.grantPlan = true
        await session.signIn(profileID: session.activeProfileID, requestPlanConsent: true)
        XCTAssertNil(session.error)
        XCTAssertTrue(session.canUseChatGPTPlan)
        XCTAssertEqual(h.authorization?["prompt"], "consent")
        XCTAssertEqual(h.authorization?["scope"], ChatGPTAuthConstants.planScopes)
        XCTAssertEqual(h.authorization?["client_id"], "oaiapp_fixture")
        XCTAssertNil(h.authorization?["agent_name_hint"])
        XCTAssertNotNil(h.authorization?["id_token_hint"])
        XCTAssertEqual(try h.record().hostID, host)
        XCTAssertNotEqual(session.sessionIdentifier, previousSession)
        let access = try await session.accessToken()
        XCTAssertEqual(access, "fixture-access-initial")
    }

    func testIdentityOnlyTokenMayOmitAccessRefreshAndScope() async throws {
        let h = try ChatGPTAuthHarness()
        h.identityOnlyResponse = true
        let session = h.session()
        await session.signIn()
        XCTAssertNil(session.error)
        XCTAssertNotNil(session.activeProfileID)
        XCTAssertFalse(session.canUseChatGPTPlan)
    }

    func testOrdinaryFirstAndReturningSignInRequestPlanWithoutForcedConsent() async throws {
        let h = try ChatGPTAuthHarness()
        h.grantPlan = true
        let session = h.session()
        await session.signIn()
        XCTAssertNil(session.error)
        XCTAssertTrue(session.canUseChatGPTPlan)
        XCTAssertEqual(h.authorization?["scope"], ChatGPTAuthConstants.planScopes)
        XCTAssertNil(h.authorization?["prompt"])
        XCTAssertEqual(h.authorization?["client_id"], "dynamic_agent_client")
        let profile = try XCTUnwrap(session.activeProfileID)
        let previousSession = session.sessionIdentifier
        await session.signIn(profileID: profile)
        XCTAssertNil(session.error)
        XCTAssertEqual(h.authorization?["scope"], ChatGPTAuthConstants.planScopes)
        XCTAssertNil(h.authorization?["prompt"])
        XCTAssertEqual(h.authorization?["client_id"], "oaiapp_fixture")
        XCTAssertTrue(session.canUseChatGPTPlan)
        XCTAssertNotEqual(session.sessionIdentifier, previousSession)
    }

    func testRegistrationSurvivesInvalidGrantAndRetriesIssuedClient() async throws {
        let h = try ChatGPTAuthHarness()
        h.exchangeError = "invalid_grant"
        let session = h.session()
        await session.signIn()
        XCTAssertNotNil(session.error)
        XCTAssertNil(session.activeProfileID)
        XCTAssertEqual(try h.record().registrations.first?.clientID, "oaiapp_fixture")
        h.exchangeError = nil
        await session.signIn()
        XCTAssertNil(session.error)
        XCTAssertEqual(h.authorization?["client_id"], "oaiapp_fixture")
        XCTAssertEqual(session.profiles.count, 1)
    }

    func testReturningIdentityMismatchPreservesOriginalCredentials() async throws {
        let h = try ChatGPTAuthHarness()
        let session = h.session()
        await session.signIn()
        let before = try h.record()
        h.subject = "different-fixture-subject"
        await session.signIn(profileID: session.activeProfileID)
        XCTAssertEqual(session.error, ChatGPTAuthError.identity.localizedDescription)
        XCTAssertEqual(session.activeProfileID, before.activeProfileID)
        XCTAssertEqual(try h.record().registrations.first?.tokens?.identity, before.registrations.first?.tokens?.identity)
    }

    func testNonceMismatchNeverActivatesSession() async throws {
        let h = try ChatGPTAuthHarness()
        h.wrongNonce = true
        let session = h.session()
        await session.signIn()
        XCTAssertEqual(session.error, ChatGPTAuthError.identity.localizedDescription)
        XCTAssertNil(session.activeProfileID)
        XCTAssertNil(try h.record().registrations.first?.tokens)
    }

    func testStorageFailurePreventsBrowserAndActivation() async throws {
        let h = try ChatGPTAuthHarness()
        h.store.failWrites = true
        let session = h.session()
        await session.signIn()
        XCTAssertEqual(session.error, ChatGPTAuthError.storage.localizedDescription)
        XCTAssertNil(h.authorization)
        XCTAssertNil(session.activeProfileID)
        XCTAssertFalse(session.needsSignOutRetry)
    }

    func testFailedAtomicSaveDoesNotPublishNewCredentials() async throws {
        let h = try ChatGPTAuthHarness()
        h.store.failWriteNumber = 3
        let session = h.session()
        await session.signIn()
        XCTAssertEqual(session.error, ChatGPTAuthError.storage.localizedDescription)
        XCTAssertNil(session.activeProfileID)
        XCTAssertNil(try h.record().registrations.first?.tokens)
        XCTAssertEqual(try h.record().registrations.first?.clientID, "oaiapp_fixture")
    }

    func testRefreshRotationAndConcurrentCallers() async throws {
        let h = try ChatGPTAuthHarness()
        h.grantPlan = true
        let session = h.session()
        await session.signIn(requestPlanConsent: true)
        h.clock = h.clock.addingTimeInterval(3600)
        async let a = session.accessToken()
        async let b = session.accessToken()
        let values = try await [a, b]
        XCTAssertEqual(values, ["fixture-access-rotated", "fixture-access-rotated"])
        XCTAssertEqual(h.refreshes, 1)
        XCTAssertEqual(try h.record().registrations.first?.tokens?.refresh, "fixture-refresh-rotated")
        XCTAssertNil(h.lastRefreshFields?["scope"])
        XCTAssertEqual(h.lastRefreshFields?["client_id"], "oaiapp_fixture")
        XCTAssertEqual(h.lastRefreshFields?["resource"], ChatGPTAuthConstants.resource)
    }

    func testTwoSessionInstancesSerializeRotatingCredential() async throws {
        let h = try ChatGPTAuthHarness()
        h.grantPlan = true
        let first = h.session()
        await first.signIn(requestPlanConsent: true)
        let second = h.session()
        h.clock = h.clock.addingTimeInterval(3600)
        async let a = first.accessToken()
        async let b = second.accessToken()
        let values = try await [a, b]
        XCTAssertEqual(values, ["fixture-access-rotated", "fixture-access-rotated"])
        XCTAssertEqual(h.refreshes, 1)
    }

    func testTerminalRefreshErrorsClearOnlyTokens() async throws {
        for code in ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
                     "refresh_token_invalidated", "refresh_token_reused"] {
            let h = try ChatGPTAuthHarness()
            h.grantPlan = true
            let session = h.session()
            await session.signIn(requestPlanConsent: true)
            let host = try h.record().hostID
            h.clock = h.clock.addingTimeInterval(3600)
            h.refreshError = code
            await assertThrows(.oauth(code)) { try await session.accessToken() }
            XCTAssertNil(session.activeProfileID)
            XCTAssertEqual(session.profiles.count, 1)
            XCTAssertNil(try h.record().registrations.first?.tokens)
            XCTAssertEqual(try h.record().hostID, host)
        }
    }

    func testTransientAndInvalidClientRefreshRetainCredentials() async throws {
        for code in ["invalid_client", "temporary"] {
            let h = try ChatGPTAuthHarness()
            h.grantPlan = true
            let session = h.session()
            await session.signIn(requestPlanConsent: true)
            h.clock = h.clock.addingTimeInterval(3600)
            h.refreshError = code
            await assertThrows(code == "temporary" ? .temporary : .oauth(code)) { try await session.accessToken() }
            XCTAssertNotNil(session.activeProfileID)
            XCTAssertEqual(try h.record().registrations.first?.tokens?.refresh, "fixture-refresh-initial")
        }
    }

    func testLogoutRevokesThenClearsButRetainsRegistrationAndHost() async throws {
        let h = try ChatGPTAuthHarness()
        h.grantPlan = true
        let session = h.session()
        await session.signIn(requestPlanConsent: true)
        let host = try h.record().hostID
        let profile = session.activeProfileID
        await session.signOut()
        XCTAssertNil(session.error)
        XCTAssertEqual(h.revocations, 1)
        XCTAssertTrue(h.tokensPresentDuringRevocation)
        XCTAssertNil(session.activeProfileID)
        XCTAssertNil(session.sessionIdentifier)
        XCTAssertFalse(session.canUseChatGPTPlan)
        XCTAssertNil(try h.record().registrations.first?.tokens)
        XCTAssertEqual(try h.record().hostID, host)
        XCTAssertEqual(session.profiles.first?.id, profile)
        await session.signIn(profileID: profile)
        XCTAssertEqual(h.authorization?["client_id"], "oaiapp_fixture")
        XCTAssertNil(h.authorization?["id_token_hint"])
    }

    func testLogoutTransientRevocationWarnsAndClearsLocally() async throws {
        let h = try ChatGPTAuthHarness()
        h.grantPlan = true
        h.revokeStatus = 503
        let session = h.session()
        await session.signIn(requestPlanConsent: true)
        await session.signOut()
        XCTAssertEqual(h.revocations, 2)
        XCTAssertTrue(session.error?.contains("Remote revocation was not confirmed") == true)
        XCTAssertNil(try h.record().registrations.first?.tokens)
    }

    func testLogoutBlocksLateRefreshReactivation() async throws {
        let h = try ChatGPTAuthHarness()
        h.grantPlan = true
        let session = h.session()
        await session.signIn(requestPlanConsent: true)
        h.clock = h.clock.addingTimeInterval(3600)
        h.holdRefresh = true
        let refresh = Task { try await session.accessToken() }
        try await waitUntil { h.refreshWaiter != nil }
        let logout = Task { await session.signOut() }
        try await waitUntil { session.activeProfileID == nil }
        h.releaseRefresh()
        await assertObsolete(refresh)
        await logout.value
        XCTAssertNil(session.activeProfileID)
        XCTAssertNil(try h.record().registrations.first?.tokens)
        XCTAssertFalse(session.canUseChatGPTPlan)
        XCTAssertFalse(h.refreshWasCanceled)
        XCTAssertEqual(h.lastRevocationFields?["token"], "fixture-refresh-rotated")
        XCTAssertEqual(h.storedRefreshDuringRevocation, "fixture-refresh-rotated")
    }

    func testCancelSignInRejectsLateCallback() async throws {
        let h = try ChatGPTAuthHarness()
        h.holdCallback = true
        let session = h.session()
        let attempt = Task { await session.signIn() }
        try await waitUntil { h.callbackWaiter != nil }
        session.cancelSignIn()
        h.releaseCallback()
        await attempt.value
        XCTAssertNil(session.activeProfileID)
        XCTAssertEqual(h.exchanges, 0)
        XCTAssertFalse(session.busy)
        XCTAssertFalse(session.needsSignOutRetry)
    }

    func testKernelFileLockSerializesIndependentInstances() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ChatGPTAuthTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = ChatGPTFileLock(directory: directory)
        let b = ChatGPTFileLock(directory: directory)
        try await a.acquire()
        var entered = false
        let waiter = Task { try await b.acquire(); entered = true; b.release() }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(entered)
        a.release()
        try await waiter.value
        XCTAssertTrue(entered)
    }

    func testLoopbackTimeoutAndSingleConsumption() async throws {
        let listener = ChatGPTLoopbackListener(timeoutNanoseconds: 150_000_000)
        let uri = try await listener.start()
        XCTAssertEqual(uri.host, "127.0.0.1")
        XCTAssertEqual(uri.path, "/auth/callback")
        XCTAssertNotEqual(uri.port, 0)
        await assertThrows(.timeout) { try await listener.callback().absoluteString }
        await assertThrows(.callback) { try await listener.callback().absoluteString }
    }

    func testSwitchChangesSessionAndPreservesOtherRegistration() async throws {
        let h = try ChatGPTAuthHarness()
        h.grantPlan = true
        let session = h.session()
        await session.signIn(requestPlanConsent: true)
        let first = try XCTUnwrap(session.activeProfileID)
        let oldSession = session.sessionIdentifier
        h.clientID = "oaiapp_second_fixture"
        h.subject = "second-fixture-subject"
        await session.signIn(requestPlanConsent: true)
        XCTAssertNil(session.error)
        XCTAssertEqual(session.profiles.count, 2)
        XCTAssertNotEqual(session.activeProfileID, first)
        XCTAssertNotEqual(session.sessionIdentifier, oldSession)
        XCTAssertEqual(try h.record().registrations.filter { $0.tokens != nil }.count, 2)
        let secondSession = session.sessionIdentifier
        h.clientID = "oaiapp_fixture"
        h.subject = "fixture-subject"
        await session.signIn(profileID: first)
        XCTAssertEqual(session.activeProfileID, first)
        XCTAssertNotEqual(session.sessionIdentifier, secondSession)
        await session.signOut()
        XCTAssertEqual(try h.record().registrations.filter { $0.tokens != nil }.count, 1)
        XCTAssertEqual(session.profiles.count, 2)
    }

    func testSwitchFencesLateRefresh() async throws {
        let h = try ChatGPTAuthHarness()
        h.grantPlan = true
        let session = h.session()
        await session.signIn(requestPlanConsent: true)
        h.clock = h.clock.addingTimeInterval(3600)
        h.includeRefreshIdentity = true
        h.holdRefresh = true
        let refresh = Task { try await session.accessToken() }
        try await waitUntil { h.refreshWaiter != nil }
        let next = Task { await session.signIn() }
        try await waitUntil { session.busy }
        h.clientID = "oaiapp_second_fixture"
        h.subject = "second-fixture-subject"
        h.releaseRefresh()
        await assertObsolete(refresh)
        await next.value
        XCTAssertNil(session.error)
        XCTAssertEqual(session.profiles.first(where: { $0.id == session.activeProfileID })?.clientID, "oaiapp_second_fixture")
        XCTAssertEqual(try h.record().registrations.first?.tokens?.refresh, "fixture-refresh-rotated")
        XCTAssertFalse(h.refreshWasCanceled)
    }

    func testFailedSwitchStillPersistsDispatchedRefresh() async throws {
        let h = try ChatGPTAuthHarness()
        h.grantPlan = true
        let session = h.session()
        await session.signIn()
        let originalProfile = session.activeProfileID
        let originalSession = session.sessionIdentifier
        let originalIdentityToken = try h.record().registrations.first?.tokens?.identity
        h.clock = h.clock.addingTimeInterval(3600)
        h.includeRefreshIdentity = true
        h.holdRefresh = true
        let refresh = Task { try await session.accessToken() }
        try await waitUntil { h.refreshWaiter != nil }
        let next = Task { await session.signIn() }
        try await waitUntil { session.busy }
        h.clientID = "oaiapp_second_fixture"
        h.exchangeError = "invalid_grant"
        h.releaseRefresh()
        await assertObsolete(refresh)
        await next.value
        XCTAssertNotNil(session.error)
        XCTAssertEqual(session.activeProfileID, originalProfile)
        XCTAssertEqual(session.sessionIdentifier, originalSession)
        XCTAssertEqual(try h.record().registrations.first?.tokens?.refresh, "fixture-refresh-rotated")
        XCTAssertNotEqual(try h.record().registrations.first?.tokens?.identity, originalIdentityToken)
        XCTAssertFalse(h.refreshWasCanceled)
        let access = try await session.accessToken()
        XCTAssertEqual(access, "fixture-access-rotated")
        XCTAssertEqual(h.refreshes, 1)
    }

    func testLogoutDrainsRefreshIdentityValidationBeforeRevoking() async throws {
        let h = try ChatGPTAuthHarness()
        h.grantPlan = true
        let session = h.session()
        await session.signIn()
        h.clock = h.clock.addingTimeInterval(3600)
        h.includeRefreshIdentity = true
        h.holdJWKS = true
        h.holdRevocation = true
        let refresh = Task { try await session.accessToken() }
        try await waitUntil { h.jwksWaiter != nil }
        let logout = Task { await session.signOut() }
        try await waitUntil { session.activeProfileID == nil }
        h.holdJWKS = false
        h.jwksWaiter?.resume()
        h.jwksWaiter = nil
        try await waitUntil { h.revocationWaiter != nil }
        XCTAssertEqual(try h.record().registrations.first?.tokens?.refresh, "fixture-refresh-rotated")
        XCTAssertEqual(h.lastRevocationFields?["token"], "fixture-refresh-rotated")
        XCTAssertNil(session.activeProfileID)
        XCTAssertNil(session.sessionIdentifier)
        XCTAssertFalse(session.canUseChatGPTPlan)
        await assertObsolete(refresh)
        h.revocationWaiter?.resume()
        h.revocationWaiter = nil
        await logout.value
        XCTAssertNil(session.error)
        XCTAssertNil(try h.record().registrations.first?.tokens)
    }

    func testLogoutBeforeRefreshDispatchDoesNotRotate() async throws {
        let h = try ChatGPTAuthHarness()
        h.grantPlan = true
        let session = h.session()
        await session.signIn()
        h.clock = h.clock.addingTimeInterval(3600)
        h.holdDiscovery = true
        let refresh = Task { try await session.accessToken() }
        try await waitUntil { h.discoveryWaiter != nil }
        let logout = Task { await session.signOut() }
        try await waitUntil { session.activeProfileID == nil }
        h.holdDiscovery = false
        h.discoveryWaiter?.resume()
        h.discoveryWaiter = nil
        await assertObsolete(refresh)
        await logout.value
        XCTAssertEqual(h.refreshes, 0)
        XCTAssertEqual(h.lastRevocationFields?["token"], "fixture-refresh-initial")
        XCTAssertNil(try h.record().registrations.first?.tokens)
    }

    func testLogoutRetriesFailedLocalClearForExactTarget() async throws {
        for remoteStatus in [200, 503] {
            let h = try ChatGPTAuthHarness()
            h.grantPlan = true
            let session = h.session()
            await session.signIn()
            let firstID = session.activeProfileID
            h.clientID = "oaiapp_second_fixture"
            h.subject = "second-fixture-subject"
            await session.signIn()
            let target = try XCTUnwrap(session.activeProfileID)
            let host = try h.record().hostID
            h.revokeStatus = remoteStatus
            h.store.failWrites = true
            await session.signOut()
            XCTAssertNotNil(session.error)
            XCTAssertTrue(session.error?.contains("stored credentials may remain after restart") == true)
            XCTAssertNil(session.activeProfileID)
            XCTAssertNil(session.sessionIdentifier)
            XCTAssertFalse(session.canUseChatGPTPlan)
            XCTAssertEqual(try h.record().registrations.filter { $0.tokens != nil }.count, 2)
            XCTAssertTrue(session.needsSignOutRetry)
            await assertThrows(.signedOut) { try await session.accessToken() }
            let exchanges = h.exchanges
            await session.signIn(profileID: firstID)
            XCTAssertEqual(h.exchanges, exchanges)
            XCTAssertNotNil(session.error)
            h.store.failWrites = false
            await session.signOut()
            let record = try h.record()
            XCTAssertNil(record.registrations.first(where: { $0.profile?.id == target })?.tokens)
            XCTAssertNotNil(record.registrations.first(where: { $0.profile?.id == firstID })?.tokens)
            XCTAssertEqual(record.hostID, host)
            XCTAssertEqual(session.profiles.count, 2)
            XCTAssertNil(session.activeProfileID)
            XCTAssertFalse(session.needsSignOutRetry)
            if remoteStatus == 200 { XCTAssertNil(session.error) }
            else { XCTAssertTrue(session.error?.contains("Remote revocation was not confirmed") == true) }
        }
    }

    func testCancelRefreshCallerDoesNotLoseSharedRotation() async throws {
        let h = try ChatGPTAuthHarness()
        h.grantPlan = true
        let session = h.session()
        await session.signIn(requestPlanConsent: true)
        h.clock = h.clock.addingTimeInterval(3600)
        h.holdRefresh = true
        let canceled = Task { try await session.accessToken() }
        try await waitUntil { h.refreshWaiter != nil }
        let survivor = Task { try await session.accessToken() }
        canceled.cancel()
        h.releaseRefresh()
        do { _ = try await canceled.value; XCTFail("Canceled caller must not receive a token") }
        catch { XCTAssertTrue(error is CancellationError) }
        let value = try await survivor.value
        XCTAssertEqual(value, "fixture-access-rotated")
        XCTAssertEqual(h.refreshes, 1)
        XCTAssertEqual(try h.record().registrations.first?.tokens?.refresh, "fixture-refresh-rotated")
    }

    func testLogoutFencesLateSignInExchange() async throws {
        let h = try ChatGPTAuthHarness()
        h.holdExchange = true
        let session = h.session()
        let signIn = Task { await session.signIn() }
        try await waitUntil { h.exchangeWaiter != nil }
        let previousAcquires = h.lock.acquires
        let logout = Task { await session.signOut() }
        try await waitUntil { h.lock.acquires > previousAcquires }
        h.exchangeWaiter?.resume()
        h.exchangeWaiter = nil
        await signIn.value
        await logout.value
        XCTAssertNil(session.activeProfileID)
        XCTAssertNil(try h.record().registrations.first?.tokens)
    }

    func testRefreshSaveFailureRetainsPriorAtomicRecord() async throws {
        let h = try ChatGPTAuthHarness()
        h.grantPlan = true
        let session = h.session()
        await session.signIn(requestPlanConsent: true)
        h.clock = h.clock.addingTimeInterval(3600)
        h.store.failWrites = true
        await assertThrows(.storage) { try await session.accessToken() }
        XCTAssertEqual(try h.record().registrations.first?.tokens?.refresh, "fixture-refresh-initial")
    }

    func testRefreshRevokedScopeDisablesPlanWithoutLosingIdentity() async throws {
        let h = try ChatGPTAuthHarness()
        h.grantPlan = true
        let session = h.session()
        await session.signIn(requestPlanConsent: true)
        h.clock = h.clock.addingTimeInterval(3600)
        h.grantPlan = false
        await assertThrows(.consent) { try await session.accessToken() }
        XCTAssertFalse(session.canUseChatGPTPlan)
        XCTAssertNotNil(session.activeProfileID)
        XCTAssertEqual(try h.record().registrations.first?.tokens?.refresh, "fixture-refresh-rotated")
    }

    func testDiscoveryRejectsOffOriginAndUserInfo() throws {
        let endpoint = URL(string: ChatGPTAuthConstants.issuer + "/endpoint")!
        for url in ["https://attacker.invalid/keys", "http://auth.openai.com/keys",
                    "https://name@auth.openai.com/keys", "https://auth.openai.com/keys?extra=true"] {
            let discovery = ChatGPTDiscovery(issuer: ChatGPTAuthConstants.issuer, authorization_endpoint: endpoint,
                token_endpoint: endpoint, jwks_uri: URL(string: url)!, revocation_endpoint: endpoint)
            XCTAssertThrowsError(try discovery.validate())
        }
    }

    func testRealLoopbackConsumesOnlyOneSyntheticCallback() async throws {
        let listener = ChatGPTLoopbackListener(timeoutNanoseconds: 2_000_000_000)
        let uri = try await listener.start()
        defer { listener.cancel() }
        let callback = Task { try await listener.callback() }
        let url = URL(string: uri.absoluteString + "?state=fixture-state&code=fixture-code")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 2
        let client = URLSession(configuration: configuration)
        defer { client.invalidateAndCancel() }
        let (body, response) = try await client.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: body, encoding: .utf8), "Return to LessMeet to finish sign-in.")
        let received = try await callback.value
        XCTAssertEqual(received, url)
        await assertThrows(.callback) { try await listener.callback().absoluteString }
    }

    func testLoopbackCancellationReleasesWaiter() async throws {
        let listener = ChatGPTLoopbackListener()
        _ = try await listener.start()
        let callback = Task { try await listener.callback() }
        await Task.yield()
        listener.cancel()
        do { _ = try await callback.value; XCTFail("Canceled callback must fail") }
        catch { XCTAssertEqual(error as? ChatGPTAuthError, .canceled) }
    }

    func testEarliestRefreshAndIncompleteReplacement() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let valid = ChatGPTTokenResponse(access_token: "fixture-access", refresh_token: "fixture-refresh", id_token: nil,
            token_type: "Bearer", expires_in: 3600, scope: ChatGPTAuthConstants.planScopes, earliest_refresh_at: 4500)
        let tokens = try valid.tokens(now: now, previousIdentity: "fixture-id", refresh: true)
        XCTAssertEqual(tokens.earliestRefreshAt, Date(timeIntervalSince1970: 4500))
        XCTAssertEqual(tokens.expiresAt, Date(timeIntervalSince1970: 4600))
        let incomplete = ChatGPTTokenResponse(access_token: "fixture-access", refresh_token: nil, id_token: nil,
            token_type: "Bearer", expires_in: 3600, scope: ChatGPTAuthConstants.planScopes, earliest_refresh_at: nil)
        XCTAssertThrowsError(try incomplete.tokens(now: now, previousIdentity: "fixture-id", refresh: true))
    }

    func testLockWaitCanBeCanceled() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ChatGPTAuthTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = ChatGPTFileLock(directory: directory)
        let b = ChatGPTFileLock(directory: directory)
        try await a.acquire()
        defer { a.release() }
        let waiting = Task { try await b.acquire() }
        await Task.yield()
        waiting.cancel()
        do { try await waiting.value; b.release(); XCTFail("Canceled lock wait must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    private func assertThrows(_ expected: ChatGPTAuthError, _ body: () async throws -> String,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await body(); XCTFail("Expected an authentication failure", file: file, line: line) }
        catch { XCTAssertEqual(error as? ChatGPTAuthError, expected, file: file, line: line) }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            guard Date() < deadline else { throw ChatGPTAuthError.timeout }
            await Task.yield()
        }
    }

    private func assertObsolete(_ task: Task<String, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await task.value; XCTFail("Obsolete caller received a token", file: file, line: line) }
        catch { XCTAssertTrue(error is CancellationError || error as? ChatGPTAuthError == .canceled, file: file, line: line) }
    }
}

@MainActor
private final class ChatGPTAuthMemoryStore: ChatGPTCredentialStore {
    var data: Data?
    var failWrites = false
    var failWriteNumber: Int?
    var writes = 0
    func read() throws -> Data? { data }
    func write(_ data: Data) throws {
        writes += 1
        if failWrites || failWriteNumber == writes { throw ChatGPTAuthError.storage }
        self.data = data
    }
}

@MainActor
private final class ChatGPTAuthMemoryLock: ChatGPTCredentialLock {
    var locked = false
    var acquires = 0
    func acquire() async throws {
        acquires += 1
        let deadline = Date().addingTimeInterval(3)
        while locked {
            try Task.checkCancellation()
            guard Date() < deadline else { throw ChatGPTAuthError.timeout }
            await Task.yield()
        }
        try Task.checkCancellation()
        locked = true
    }
    func release() { locked = false }
}

@MainActor
private final class ChatGPTAuthFixtureListener: ChatGPTCallbackListener {
    unowned let harness: ChatGPTAuthHarness
    init(_ harness: ChatGPTAuthHarness) { self.harness = harness }
    func start() async throws -> URL {
        harness.started = true
        return URL(string: "http://127.0.0.1:43123/auth/callback")!
    }
    func callback() async throws -> URL {
        if harness.holdCallback { await withCheckedContinuation { harness.callbackWaiter = $0 } }
        let state = harness.authorization!["state"]!
        return URL(string: "http://127.0.0.1:43123/auth/callback?state=\(state)&code=fixture-code&client_id=\(harness.clientID)")!
    }
    // Intentionally ignore cancellation to prove the session's generation fence.
    func cancel() { }
}

@MainActor
private final class ChatGPTAuthHarness {
    let store = ChatGPTAuthMemoryStore()
    let lock = ChatGPTAuthMemoryLock()
    let signing: ChatGPTAuthSigningFixture
    var clock = Date(timeIntervalSince1970: 1000)
    var authorization: [String: String]?
    var started = false
    var listenerStartedBeforeBrowser = false
    var grantPlan = false
    var identityOnlyResponse = false
    var subject = "fixture-subject"
    var clientID = "oaiapp_fixture"
    var wrongNonce = false
    var exchangeError: String?
    var refreshError: String?
    var exchanges = 0
    var refreshes = 0
    var revocations = 0
    var revokeStatus = 200
    var tokensPresentDuringRevocation = false
    var lastRefreshFields: [String: String]?
    var lastRevocationFields: [String: String]?
    var storedRefreshDuringRevocation: String?
    var refreshWasCanceled = false
    var includeRefreshIdentity = false
    var holdJWKS = false
    var jwksWaiter: CheckedContinuation<Void, Never>?
    var holdDiscovery = false
    var discoveryWaiter: CheckedContinuation<Void, Never>?
    var holdRevocation = false
    var revocationWaiter: CheckedContinuation<Void, Never>?
    var holdRefresh = false
    var refreshWaiter: CheckedContinuation<Void, Never>?
    var holdExchange = false
    var exchangeWaiter: CheckedContinuation<Void, Never>?
    var holdCallback = false
    var callbackWaiter: CheckedContinuation<Void, Never>?

    init() throws { signing = try ChatGPTAuthSigningFixture() }
    func session() -> ChatGPTSession {
        ChatGPTSession(store: store, credentialLock: lock, send: { try await self.send($0) },
                       makeListener: { ChatGPTAuthFixtureListener(self) }, openBrowser: {
            self.listenerStartedBeforeBrowser = self.started
            self.authorization = Self.query($0)
        }, now: { self.clock })
    }
    func record() throws -> ChatGPTAuthRecord { try JSONDecoder().decode(ChatGPTAuthRecord.self, from: XCTUnwrap(store.data)) }
    func releaseRefresh() { holdRefresh = false; refreshWaiter?.resume(); refreshWaiter = nil }
    func releaseCallback() { callbackWaiter?.resume(); callbackWaiter = nil }

    func send(_ request: URLRequest) async throws -> ChatGPTAuthHTTPResponse {
        await Task.yield()
        let url = try XCTUnwrap(request.url)
        switch url.path {
        case "/.well-known/openid-configuration":
            if holdDiscovery { await withCheckedContinuation { discoveryWaiter = $0 } }
            return try response(["issuer": ChatGPTAuthConstants.issuer,
                "authorization_endpoint": ChatGPTAuthConstants.issuer + "/api/accounts/authorize",
                "token_endpoint": ChatGPTAuthConstants.issuer + "/api/accounts/oauth/token",
                "jwks_uri": ChatGPTAuthConstants.issuer + "/.well-known/jwks.json",
                "revocation_endpoint": ChatGPTAuthConstants.issuer + "/revoke"])
        case "/.well-known/jwks.json":
            if holdJWKS { await withCheckedContinuation { jwksWaiter = $0 } }
            return ChatGPTAuthHTTPResponse(status: 200, data: signing.jwks)
        case "/api/accounts/oauth/token":
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8)!
            let fields = Self.query(URL(string: "https://fixture.invalid/?" + body)!)
            let refresh = fields["grant_type"] == "refresh_token"
            if refresh {
                refreshes += 1
                lastRefreshFields = fields
                if holdRefresh { await withCheckedContinuation { refreshWaiter = $0 } }
                refreshWasCanceled = Task.isCancelled
            } else {
                exchanges += 1
                if holdExchange { await withCheckedContinuation { exchangeWaiter = $0 } }
            }
            if let code = refresh ? refreshError : exchangeError {
                return try response(["error": code], status: code == "temporary" ? 503 : 400)
            }
            var fieldsOut: [String: Any] = ["scope": grantPlan ? ChatGPTAuthConstants.planScopes : ChatGPTAuthConstants.identityScopes]
            if !refresh {
                fieldsOut["id_token"] = try signing.token(overrides: ["nonce": wrongNonce ? "wrong" : authorization!["nonce"]!,
                    "sub": subject, "aud": clientID, "iat": Int(clock.timeIntervalSince1970), "exp": Int(clock.timeIntervalSince1970) + 3600])
            } else if includeRefreshIdentity {
                let selected = try XCTUnwrap(record().registrations.first { $0.clientID == fields["client_id"] })
                fieldsOut["id_token"] = try signing.token(overrides: ["nonce": "fixture-refresh-nonce",
                    "sub": try XCTUnwrap(selected.subject), "aud": selected.clientID,
                    "iat": Int(clock.timeIntervalSince1970), "exp": Int(clock.timeIntervalSince1970) + 3600])
            }
            if identityOnlyResponse { fieldsOut.removeValue(forKey: "scope") }
            else if grantPlan || refresh {
                fieldsOut["access_token"] = refresh ? "fixture-access-rotated" : "fixture-access-initial"
                fieldsOut["refresh_token"] = refresh ? "fixture-refresh-rotated" : "fixture-refresh-initial"
                fieldsOut["token_type"] = "Bearer"
                fieldsOut["expires_in"] = 3600
            }
            return try response(fieldsOut)
        case "/revoke":
            revocations += 1
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8)!
            lastRevocationFields = Self.query(URL(string: "https://fixture.invalid/?" + body)!)
            storedRefreshDuringRevocation = try record().registrations.first {
                $0.clientID == lastRevocationFields?["client_id"]
            }?.tokens?.refresh
            tokensPresentDuringRevocation = try record().registrations.contains { $0.tokens != nil }
            if holdRevocation { await withCheckedContinuation { revocationWaiter = $0 } }
            return ChatGPTAuthHTTPResponse(status: revokeStatus, data: Data())
        default: throw ChatGPTAuthError.response
        }
    }
    static func query(_ url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
    private func response(_ object: [String: Any], status: Int = 200) throws -> ChatGPTAuthHTTPResponse {
        ChatGPTAuthHTTPResponse(status: status, data: try JSONSerialization.data(withJSONObject: object))
    }
}

private final class ChatGPTAuthSigningFixture {
    let key: SecKey
    let jwks: Data
    init() throws {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: false],
            kSecPublicKeyAttrs as String: [kSecAttrIsPermanent as String: false]]
        key = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
        let der = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        var cursor = 0
        func readTag(_ expected: UInt8) throws -> Data {
            guard cursor + 2 <= der.count, der[cursor] == expected else { throw ChatGPTAuthError.identity }
            cursor += 1
            var length = Int(der[cursor]); cursor += 1
            if length >= 128 {
                let count = length & 127
                length = 0
                for _ in 0..<count { length = length * 256 + Int(der[cursor]); cursor += 1 }
            }
            let body = der.subdata(in: cursor..<cursor + length)
            if expected != 0x30 { cursor += length }
            return body
        }
        _ = try readTag(0x30)
        let n = try readTag(0x02).drop(while: { $0 == 0 })
        let e = try readTag(0x02).drop(while: { $0 == 0 })
        jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kid": "fixture-key", "kty": "RSA", "alg": "RS256", "use": "sig",
            "n": ChatGPTAuthConstants.base64URL(Data(n)), "e": ChatGPTAuthConstants.base64URL(Data(e))]]])
    }
    func token(overrides: [String: Any] = [:], algorithm: String = "RS256", kid: String = "fixture-key", omit: String? = nil) throws -> String {
        var claims: [String: Any] = ["iss": ChatGPTAuthConstants.issuer, "sub": "fixture-subject", "aud": "oaiapp_fixture",
                                    "iat": 1000, "exp": 4600, "nonce": "fixture-nonce", "name": "Fixture account"]
        overrides.forEach { claims[$0.key] = $0.value }
        if let omit { claims.removeValue(forKey: omit) }
        let header = ChatGPTAuthConstants.base64URL(try JSONSerialization.data(withJSONObject: ["alg": algorithm, "kid": kid]))
        let payload = ChatGPTAuthConstants.base64URL(try JSONSerialization.data(withJSONObject: claims))
        let input = header + "." + payload
        let signature = try XCTUnwrap(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(input.utf8) as CFData, nil))
        return input + "." + ChatGPTAuthConstants.base64URL(signature as Data)
    }
    func verify(_ token: String) throws -> ChatGPTVerifiedIdentity {
        try ChatGPTIdentityVerifier.verify(token, jwks: jwks, clientID: "oaiapp_fixture", nonce: "fixture-nonce",
                                           subject: "fixture-subject", now: Date(timeIntervalSince1970: 1000))
    }
}
