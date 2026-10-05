import CryptoKit
import Foundation
import Testing
@testable import ScreenGPTCore

@Test func validSignedIdentityReturnsSubjectAndEmail() throws {
    let fixture = try IdentityFixture()
    let identity = try IdentityValidation.validate(
        token: fixture.signedToken(claims: fixture.validClaims()), jwks: fixture.jwks(),
        clientID: fixture.clientID, nonce: fixture.nonce, issuer: fixture.issuer, now: fixture.now
    )

    #expect(identity.subject == "user-42")
    #expect(identity.email == "person@example.com")
}

@Test func tamperedSignatureIsRejected() throws {
    let fixture = try IdentityFixture()
    try expectInvalid {
        try IdentityValidation.validate(
            token: fixture.signedToken(claims: fixture.validClaims(), tamperSignature: true), jwks: fixture.jwks(),
            clientID: fixture.clientID, nonce: fixture.nonce, issuer: fixture.issuer, now: fixture.now
        )
    }
}

@Test func wrongNonceClientAndIssuerAreRejected() throws {
    let fixture = try IdentityFixture()
    let token = fixture.signedToken(claims: fixture.validClaims())
    try expectInvalid {
        try IdentityValidation.validate(token: token, jwks: fixture.jwks(), clientID: fixture.clientID, nonce: "another-nonce", issuer: fixture.issuer, now: fixture.now)
    }
    try expectInvalid {
        try IdentityValidation.validate(token: token, jwks: fixture.jwks(), clientID: "another-client", nonce: fixture.nonce, issuer: fixture.issuer, now: fixture.now)
    }
    try expectInvalid {
        try IdentityValidation.validate(token: token, jwks: fixture.jwks(), clientID: fixture.clientID, nonce: fixture.nonce, issuer: "https://wrong.example", now: fixture.now)
    }
}

@Test func expiredTokenIsRejected() throws {
    let fixture = try IdentityFixture()
    var claims = fixture.validClaims()
    claims["exp"] = fixture.now.timeIntervalSince1970 - 60
    try expectInvalid {
        try IdentityValidation.validate(
            token: fixture.signedToken(claims: claims), jwks: fixture.jwks(),
            clientID: fixture.clientID, nonce: fixture.nonce, issuer: fixture.issuer, now: fixture.now
        )
    }
}

@Test func futureIssuedAtAndNotBeforeAreRejected() throws {
    let fixture = try IdentityFixture()
    var futureIssued = fixture.validClaims()
    futureIssued["iat"] = fixture.now.timeIntervalSince1970 + 60
    try expectInvalid {
        try IdentityValidation.validate(
            token: fixture.signedToken(claims: futureIssued), jwks: fixture.jwks(),
            clientID: fixture.clientID, nonce: fixture.nonce, issuer: fixture.issuer, now: fixture.now
        )
    }

    var notYetValid = fixture.validClaims()
    notYetValid["nbf"] = fixture.now.timeIntervalSince1970 + 60
    try expectInvalid {
        try IdentityValidation.validate(
            token: fixture.signedToken(claims: notYetValid), jwks: fixture.jwks(),
            clientID: fixture.clientID, nonce: fixture.nonce, issuer: fixture.issuer, now: fixture.now
        )
    }
}

@Test func unsignedAlgorithmIsRejected() throws {
    let fixture = try IdentityFixture()
    let token = fixture.unsignedToken(header: ["alg": "none", "kid": "ec-key-1"], claims: fixture.validClaims())
    try expectInvalid {
        try IdentityValidation.validate(
            token: token, jwks: fixture.jwks(), clientID: fixture.clientID,
            nonce: fixture.nonce, issuer: fixture.issuer, now: fixture.now
        )
    }
}

@Test func audienceArrayRequiresAuthorizedPartyAndAcceptsMatchingAzp() throws {
    let fixture = try IdentityFixture()
    var claims = fixture.validClaims()
    claims["aud"] = [fixture.clientID, "another-audience"]
    claims["azp"] = fixture.clientID
    let accepted = try IdentityValidation.validate(
        token: fixture.signedToken(claims: claims), jwks: fixture.jwks(),
        clientID: fixture.clientID, nonce: fixture.nonce, issuer: fixture.issuer, now: fixture.now
    )
    #expect(accepted.subject == "user-42")

    claims["azp"] = "another-client"
    try expectInvalid {
        try IdentityValidation.validate(
            token: fixture.signedToken(claims: claims), jwks: fixture.jwks(),
            clientID: fixture.clientID, nonce: fixture.nonce, issuer: fixture.issuer, now: fixture.now
        )
    }
    claims.removeValue(forKey: "azp")
    try expectInvalid {
        try IdentityValidation.validate(
            token: fixture.signedToken(claims: claims), jwks: fixture.jwks(),
            clientID: fixture.clientID, nonce: fixture.nonce, issuer: fixture.issuer, now: fixture.now
        )
    }
}

@Test func pkceChallengeMatchesRFC7636Example() {
    let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    #expect(IdentityValidation.challenge(verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
}

private struct IdentityFixture {
    let clientID = "desktop-client"
    let nonce = "login-nonce-123"
    let issuer = "https://auth.openai.com"
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let signingKey: P256.Signing.PrivateKey

    init() throws {
        signingKey = P256.Signing.PrivateKey()
    }

    func validClaims() -> [String: Any] {
        [
            "iss": issuer,
            "aud": clientID,
            "sub": "user-42",
            "email": "person@example.com",
            "nonce": nonce,
            "exp": now.timeIntervalSince1970 + 300,
            "iat": now.timeIntervalSince1970 - 30,
            "nbf": now.timeIntervalSince1970 - 30
        ]
    }

    func jwks() throws -> Data {
        let point = signingKey.publicKey.x963Representation
        let jwk: [String: Any] = [
            "keys": [[
                "kid": "ec-key-1",
                "kty": "EC",
                "crv": "P-256",
                "x": IdentityValidation.base64URL(point.subdata(in: 1..<33)),
                "y": IdentityValidation.base64URL(point.subdata(in: 33..<65)),
                "use": "sig",
                "alg": "ES256"
            ]]
        ]
        return try JSONSerialization.data(withJSONObject: jwk)
    }

    func signedToken(claims: [String: Any], tamperSignature: Bool = false) -> String {
        let header: [String: Any] = ["alg": "ES256", "kid": "ec-key-1", "typ": "JWT"]
        let encodedHeader = IdentityValidation.base64URL(try! JSONSerialization.data(withJSONObject: header))
        let encodedClaims = IdentityValidation.base64URL(try! JSONSerialization.data(withJSONObject: claims))
        let message = Data("\(encodedHeader).\(encodedClaims)".utf8)
        var signature = try! signingKey.signature(for: message).rawRepresentation
        if tamperSignature { signature[signature.startIndex] ^= 0x01 }
        return "\(encodedHeader).\(encodedClaims).\(IdentityValidation.base64URL(signature))"
    }

    func unsignedToken(header: [String: Any], claims: [String: Any]) -> String {
        let encodedHeader = IdentityValidation.base64URL(try! JSONSerialization.data(withJSONObject: header))
        let encodedClaims = IdentityValidation.base64URL(try! JSONSerialization.data(withJSONObject: claims))
        return "\(encodedHeader).\(encodedClaims)."
    }
}

private func expectInvalid(operation: () throws -> Any) throws {
    do {
        _ = try operation()
        Issue.record("Expected IdentityValidation.ValidationError.invalid")
    } catch IdentityValidation.ValidationError.invalid {
        // Expected validation failure.
    } catch {
        Issue.record("Expected IdentityValidation.ValidationError.invalid, received \(error)")
    }
}
