import Foundation
import Testing
@testable import VoxstudioPro

@Suite("Account registration")
struct AccountRegistrationTests {
    @MainActor @Test func passwordRulesMatchBackend() {
        #expect(!AccountRegistrationStore.isPasswordValid("abcdefg1".dropLast().description))
        #expect(!AccountRegistrationStore.isPasswordValid("abcdefgh"))
        #expect(!AccountRegistrationStore.isPasswordValid("12345678"))
        #expect(AccountRegistrationStore.isPasswordValid("Strong123"))
    }

    @MainActor @Test func failedRegistrationCanRetryAndThenResend() async {
        var attempts = 0
        var resentEmail: String?
        let store = AccountRegistrationStore(register: { email, _ in
            attempts += 1
            if attempts == 1 { throw VoxellaAPIError.http(400, #"{"detail":"Email already registered"}"#) }
            return .init(message: "Check your email", email: email)
        }, resend: { email in
            resentEmail = email
            return .init(message: "Sent", email: email)
        })
        await store.createAccount(email: " fixture@example.invalid ", password: "Strong123")
        #expect(store.verificationEmail == nil)
        #expect(store.errorMessage == "Email already registered")
        #expect(!store.isWorking)
        await store.createAccount(email: " fixture@example.invalid ", password: "Strong123")
        #expect(store.verificationEmail == "fixture@example.invalid")
        #expect(store.errorMessage == nil)
        await store.resendVerification()
        #expect(resentEmail == "fixture@example.invalid")
        store.reset()
        #expect(store.verificationEmail == nil)
    }

    @MainActor @Test func repeatedSubmissionDoesNotCreateDuplicateAccounts() async {
        var finish: CheckedContinuation<Void, Never>?
        var attempts = 0
        let store = AccountRegistrationStore(register: { email, _ in
            attempts += 1
            await withCheckedContinuation { finish = $0 }
            return .init(message: "Check your email", email: email)
        })
        let operation = Task { await store.createAccount(email: "fixture@example.invalid", password: "Strong123") }
        while finish == nil { await Task.yield() }
        #expect(store.isWorking)
        await store.createAccount(email: "fixture@example.invalid", password: "Strong123")
        #expect(attempts == 1)
        #expect(store.verificationEmail == nil)
        finish?.resume()
        await operation.value
        #expect(!store.isWorking)
        #expect(store.verificationEmail != nil)
    }

    @Test func registrationAndResendAreAnonymousWithoutStartingLogin() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RegistrationURLProtocol.self]
        let auth = VoxellaAuthService(loadRefresh: { nil }, saveRefresh: { _ in }, deleteRefresh: {})
        let api = VoxellaAPIClient(auth: auth, session: URLSession(configuration: config))
        let result = try await api.register(email: " fixture@example.invalid ", password: "Strong123")
        #expect(result.email == "fixture@example.invalid")
        _ = try await api.resendVerification(email: result.email)
        #expect(await auth.currentAccessToken() == nil)
    }
}

private final class RegistrationURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
        #expect(payload?["email"] == "fixture@example.invalid")
        let isRegistration = request.url?.path == "/api/v1/auth/register"
        if isRegistration { #expect(payload?["password"] == "Strong123") }
        else {
            #expect(request.url?.path == "/api/v1/auth/resend-verification")
            #expect(payload?["password"] == nil)
        }
        let body = #"{"message":"Check your email","email":"fixture@example.invalid"}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: isRegistration ? 201 : 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
