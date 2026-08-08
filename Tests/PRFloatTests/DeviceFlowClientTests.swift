import Foundation
import Testing
@testable import PRFloatCore

@Suite("Device flow")
struct DeviceFlowClientTests {
    private func client(_ steps: [StubHTTPClient.Step]) -> (DeviceFlowClient, StubHTTPClient) {
        let http = StubHTTPClient(steps)
        return (DeviceFlowClient(clientID: "cid", http: http), http)
    }

    @Test("Requests a device code and parses the grant")
    func requestsCode() async throws {
        let (flow, http) = client([.respond(.json("""
        {"device_code":"dc","user_code":"WXYZ-1234",
         "verification_uri":"https://github.com/login/device",
         "expires_in":900,"interval":5}
        """))])

        let grant = try await flow.requestDeviceCode()

        #expect(grant.deviceCode == "dc")
        #expect(grant.userCode == "WXYZ-1234")
        #expect(grant.interval == 5)
        #expect(grant.expiresIn == 900)

        let body = http.bodyString(at: 0)
        #expect(body.contains("client_id=cid"))
        #expect(body.contains("scope=repo"))
    }

    @Test("An empty client ID fails before any network call")
    func missingClientID() async {
        let http = StubHTTPClient([])
        let flow = DeviceFlowClient(clientID: "", http: http)

        await #expect(throws: DeviceFlowError.missingClientID) {
            _ = try await flow.requestDeviceCode()
        }
        #expect(http.requestCount == 0)
    }

    @Test("Pending authorisation keeps the flow polling")
    func pollPending() async throws {
        let (flow, _) = client([.respond(.json(#"{"error":"authorization_pending"}"#))])
        #expect(try await flow.poll(deviceCode: "dc") == .pending)
    }

    @Test("slow_down carries the new interval")
    func pollSlowDown() async throws {
        let (flow, _) = client([.respond(.json(#"{"error":"slow_down","interval":12}"#))])
        #expect(try await flow.poll(deviceCode: "dc") == .slowDown(interval: 12))
    }

    @Test("A granted token is returned")
    func pollToken() async throws {
        let (flow, _) = client([.respond(.json(#"{"access_token":"gho_abc","token_type":"bearer"}"#))])
        #expect(try await flow.poll(deviceCode: "dc") == .token("gho_abc"))
    }

    @Test("An expired code is reported distinctly so the UI can offer a retry")
    func pollExpired() async {
        let (flow, _) = client([.respond(.json(#"{"error":"expired_token"}"#))])
        await #expect(throws: DeviceFlowError.expiredCode) {
            _ = try await flow.poll(deviceCode: "dc")
        }
    }

    @Test("Denial on GitHub ends the flow")
    func pollDenied() async {
        let (flow, _) = client([.respond(.json(#"{"error":"access_denied"}"#))])
        await #expect(throws: DeviceFlowError.accessDenied) {
            _ = try await flow.poll(deviceCode: "dc")
        }
    }

    @Test("Sends the RFC 8628 grant type, not a hyphenated variant")
    func grantType() async throws {
        let (flow, http) = client([.respond(.json(#"{"error":"authorization_pending"}"#))])
        _ = try await flow.poll(deviceCode: "dc")

        let body = http.bodyString(at: 0)
        #expect(body.contains("urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code"))
    }

    @Test("Unreadable output is surfaced rather than crashing")
    func malformedResponse() async {
        let (flow, _) = client([.respond(.json("not json at all"))])
        await #expect(throws: DeviceFlowError.self) {
            _ = try await flow.requestDeviceCode()
        }
    }
}
