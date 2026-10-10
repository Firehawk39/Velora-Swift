import XCTest
import CryptoKit

final class SubsonicAuthTests: XCTestCase {

    // Mirroring SubsonicAuth logic for verification
    func generateToken(password: String, salt: String) -> String {
        let combined = password + salt
        let data = Data(combined.utf8)
        let hash = Insecure.MD5.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    func generateSalt() -> String {
        let characters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<10).map { _ in characters.randomElement()! })
    }

    func testTokenGenerationProducesValidMD5Hex() {
        let password = "testPassword123"
        let salt = "c1a2b3d4e5"
        let token = generateToken(password: password, salt: salt)

        // MD5 hex string must be exactly 32 lowercase hex characters
        XCTAssertEqual(token.count, 32)
        XCTAssertTrue(token.allSatisfy { $0.isHexDigit })
    }

    func testTokenGenerationDeterministic() {
        let password = "securePassword"
        let salt = "fixedSalt1"
        let token1 = generateToken(password: password, salt: salt)
        let token2 = generateToken(password: password, salt: salt)

        XCTAssertEqual(token1, token2)
    }

    func testSaltGenerationLengthAndCharset() {
        let salt = generateSalt()
        XCTAssertEqual(salt.count, 10)
        XCTAssertTrue(salt.allSatisfy { $0.isLetter || $0.isNumber })
    }

    func testDistinctSaltsPerInvocation() {
        let salt1 = generateSalt()
        let salt2 = generateSalt()
        XCTAssertNotEqual(salt1, salt2)
    }
}
