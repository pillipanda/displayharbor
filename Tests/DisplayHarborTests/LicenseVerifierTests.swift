import CryptoKit
import Foundation
import XCTest
@testable import DisplayHarbor

final class LicenseVerifierTests: XCTestCase {
    func testVerifiesActivationCertificateForConfiguredApp() throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let configuration = LicenseConfiguration(
            appID: "mbd.app.test-displayharbor",
            publicKey: signingKey.publicKey.rawRepresentation.base64URLEncoded,
            purchaseURL: nil
        )
        let header = #"{"alg":"EdDSA","kid":"test","typ":"JWT"}"#
        let payload = """
        {"iss":"zhuankuai","aud":"mbd.app.test-displayharbor","protocol":"mbd-license-v1","mode":"offline_signed","plan_code":"pro","plan_name":"Pro","iat":1700000000,"exp":4102444800}
        """
        let encodedHeader = Data(header.utf8).base64URLEncoded
        let encodedPayload = Data(payload.utf8).base64URLEncoded
        let input = Data("\(encodedHeader).\(encodedPayload)".utf8)
        let signature = try signingKey.signature(for: input).base64URLEncoded

        let verified = try LicenseVerifier.verify(
            "\(encodedHeader).\(encodedPayload).\(signature)",
            configuration: configuration
        )

        XCTAssertEqual(verified.planCode, "pro")
        XCTAssertEqual(verified.planName, "Pro")
    }

    func testRejectsCertificateForAnotherApplication() throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let configuration = LicenseConfiguration(
            appID: "mbd.app.test-displayharbor",
            publicKey: signingKey.publicKey.rawRepresentation.base64URLEncoded,
            purchaseURL: nil
        )
        let header = #"{"alg":"EdDSA","kid":"test","typ":"JWT"}"#
        let payload = #"{"iss":"zhuankuai","aud":"mbd.app.other","protocol":"mbd-license-v1","mode":"offline_signed","plan_code":"pro","iat":1700000000,"exp":4102444800}"#
        let encodedHeader = Data(header.utf8).base64URLEncoded
        let encodedPayload = Data(payload.utf8).base64URLEncoded
        let input = Data("\(encodedHeader).\(encodedPayload)".utf8)
        let signature = try signingKey.signature(for: input).base64URLEncoded

        XCTAssertThrowsError(try LicenseVerifier.verify(
            "\(encodedHeader).\(encodedPayload).\(signature)",
            configuration: configuration
        ))
    }
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
