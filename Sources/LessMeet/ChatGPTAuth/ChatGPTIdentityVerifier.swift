import Foundation
import Security
import CryptoKit

struct ChatGPTVerifiedIdentity {
    let subject: String
    let displayName: String

    func profile(clientID: String) -> ChatGPTProfile {
        let components = [ChatGPTAuthConstants.issuer, clientID, subject]
        let bytes = try! JSONEncoder().encode(components)
        let id = ChatGPTAuthConstants.base64URL(Data(SHA256.hash(data: bytes)))
        return ChatGPTProfile(id: id, displayName: displayName + " · " + id.prefix(6), clientID: clientID)
    }
}

enum ChatGPTIdentityVerifier {
    private struct Header: Decodable {
        let alg: String
        let kid: String
        let crit: [String]?
        let b64: Bool?
    }
    private struct Claims: Decodable {
        let iss: String
        let sub: String
        let aud: Audience
        let exp: Int64
        let iat: Int64
        let nbf: Int64?
        let nonce: String?
        let azp: String?
        let name: String?
    }
    private enum Audience: Decodable {
        case values([String])
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let string = try? value.decode(String.self) { self = .values([string]) }
            else { self = .values(try value.decode([String].self)) }
        }
    }
    private struct KeySet: Decodable { let keys: [Key] }
    private struct Key: Decodable {
        let kty: String
        let kid: String?
        let alg: String?
        let use: String?
        let key_ops: [String]?
        let n: String?
        let e: String?
    }

    static func verify(_ token: String, jwks: Data, clientID: String, nonce: String?,
                       subject: String?, now: Date) throws -> ChatGPTVerifiedIdentity {
        do {
            let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, token.count <= 32_768 else { throw ChatGPTAuthError.identity }
            let decoder = JSONDecoder()
            let header = try decoder.decode(Header.self, from: ChatGPTAuthConstants.decodeBase64URL(parts[0]))
            guard header.alg == "RS256", !header.kid.isEmpty, header.crit == nil, header.b64 == nil else {
                throw ChatGPTAuthError.identity
            }
            let matching = try decoder.decode(KeySet.self, from: jwks).keys.filter { $0.kid == header.kid }
            guard matching.count == 1, let key = matching.first, key.kty == "RSA",
                  key.alg == nil || key.alg == "RS256", key.use == nil || key.use == "sig",
                  key.key_ops == nil || key.key_ops == ["verify"], let n = key.n, let e = key.e else {
                throw ChatGPTAuthError.identity
            }
            let modulus = try ChatGPTAuthConstants.decodeBase64URL(n)
            let exponent = try ChatGPTAuthConstants.decodeBase64URL(e)
            guard modulus.count >= 256, modulus.count <= 1024, modulus.first != 0,
                  modulus.count > 256 || modulus.first! >= 128,
                  !exponent.isEmpty, exponent.count <= 8 else { throw ChatGPTAuthError.identity }
            let der = tagged(0x30, integer(modulus) + integer(exponent))
            let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                           kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
            guard let publicKey = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil),
                  SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                        Data((parts[0] + "." + parts[1]).utf8) as CFData,
                                        try ChatGPTAuthConstants.decodeBase64URL(parts[2]) as CFData, nil) else {
                throw ChatGPTAuthError.identity
            }
            let claims = try decoder.decode(Claims.self, from: ChatGPTAuthConstants.decodeBase64URL(parts[1]))
            let time = now.timeIntervalSince1970
            guard claims.iss == ChatGPTAuthConstants.issuer, !claims.sub.isEmpty,
                  claims.sub.count <= 1024, Double(claims.exp) > time - 5,
                  Double(claims.iat) <= time + 5, claims.iat <= claims.exp,
                  claims.nbf == nil || Double(claims.nbf!) <= time + 5,
                  nonce == nil || claims.nonce == nonce,
                  subject == nil || claims.sub == subject else { throw ChatGPTAuthError.identity }
            guard case .values(let audiences) = claims.aud, audiences.contains(clientID),
                  (audiences.count == 1 || claims.azp == clientID),
                  claims.azp == nil || claims.azp == clientID else { throw ChatGPTAuthError.identity }
            let name = claims.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            return ChatGPTVerifiedIdentity(subject: claims.sub,
                                           displayName: (name?.isEmpty == false ? String(name!.prefix(120)) : "ChatGPT account"))
        } catch { throw ChatGPTAuthError.identity }
    }

    private static func integer(_ bytes: Data) -> Data {
        tagged(0x02, bytes.first.map { $0 >= 128 } == true ? Data([0]) + bytes : bytes)
    }
    private static func tagged(_ tag: UInt8, _ content: Data) -> Data {
        let length = content.count
        let prefix: [UInt8]
        if length < 128 { prefix = [tag, UInt8(length)] }
        else if length < 256 { prefix = [tag, 0x81, UInt8(length)] }
        else { prefix = [tag, 0x82, UInt8(length >> 8), UInt8(length & 255)] }
        return Data(prefix) + content
    }
}
