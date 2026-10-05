import Foundation
import Security
import CryptoKit

public enum IdentityValidation {
    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public static func decode(_ string: String) -> Data? {
        let value = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: value + String(repeating: "=", count: (4 - value.count % 4) % 4))
    }
    public static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ValidationError.invalid }
        return base64URL(Data(bytes))
    }
    public static func challenge(_ verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    public struct Identity { public let subject: String; public let email: String? }
    public enum ValidationError: Error, LocalizedError {
        case invalid
        public var errorDescription: String? { "无法验证 ChatGPT 登录身份。请重新登录。" }
    }
    public static func validate(token: String, jwks: Data, clientID: String, nonce: String, issuer: String = "https://auth.openai.com", now: Date = Date()) throws -> Identity {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let headerData = decode(parts[0]), let payload = decode(parts[1]), let signature = decode(parts[2]),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let claims = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let kid = header["kid"] as? String, let alg = header["alg"] as? String,
              let set = try JSONSerialization.jsonObject(with: jwks) as? [String: Any], let keys = set["keys"] as? [[String: Any]],
              let key = keys.first(where: { ($0["kid"] as? String) == kid }),
              key["use"] == nil || key["use"] as? String == "sig",
              key["alg"] == nil || key["alg"] as? String == alg else { throw ValidationError.invalid }
        let signed = Data((parts[0] + "." + parts[1]).utf8)
        var valid = false
        if alg == "RS256", key["kty"] as? String == "RSA", let n = key["n"] as? String, let e = key["e"] as? String,
           let modulus = decode(n), let exponent = decode(e) {
            let der = element(0x30, integer(modulus) + integer(exponent))
            let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
            if let secKey = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil) {
                valid = SecKeyVerifySignature(secKey, .rsaSignatureMessagePKCS1v15SHA256, signed as CFData, signature as CFData, nil)
            }
        } else if alg == "ES256", key["kty"] as? String == "EC", key["crv"] as? String == "P-256",
                  let x = key["x"] as? String, let y = key["y"] as? String, let xd = decode(x), let yd = decode(y), xd.count == 32, yd.count == 32 {
            let publicKey = try P256.Signing.PublicKey(x963Representation: Data([4]) + xd + yd)
            valid = publicKey.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: signature), for: signed)
        }
        let audience = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard valid, claims["iss"] as? String == issuer, audience.contains(clientID),
              audience.count <= 1 || claims["azp"] as? String == clientID,
              let exp = claims["exp"] as? Double, exp > now.timeIntervalSince1970 - 5,
              let iat = claims["iat"] as? Double, iat <= now.timeIntervalSince1970 + 5,
              claims["nonce"] as? String == nonce, let sub = claims["sub"] as? String, !sub.isEmpty,
              (claims["nbf"] as? Double ?? 0) <= now.timeIntervalSince1970 + 5 else { throw ValidationError.invalid }
        return Identity(subject: sub, email: claims["email"] as? String)
    }
    private static func integer(_ bytes: Data) -> Data {
        var data = bytes
        while data.count > 1 && data.first == 0 { data.removeFirst() }
        if (data.first ?? 0) & 0x80 != 0 { data.insert(0, at: 0) }
        return element(0x02, data)
    }
    private static func element(_ tag: UInt8, _ data: Data) -> Data {
        var length = data.count
        var bytes: [UInt8] = []
        if length < 128 { bytes = [UInt8(length)] } else {
            while length > 0 { bytes.insert(UInt8(length & 0xff), at: 0); length >>= 8 }
            bytes.insert(0x80 | UInt8(bytes.count), at: 0)
        }
        return Data([tag] + bytes) + data
    }
}
