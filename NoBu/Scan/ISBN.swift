import Foundation

/// ISBN の正規化と検算（Worker の `shared/isbn.ts` と同じ）。
enum ISBN {
    /// EAN-13 のチェックディジットが合っているか
    static func isValidEan13(_ code: String) -> Bool {
        guard code.count == 13, code.allSatisfy(\.isNumber) else { return false }
        let digits = code.compactMap { $0.wholeNumberValue }
        guard digits.count == 13 else { return false }
        var sum = 0
        for i in 0..<12 { sum += digits[i] * (i % 2 == 0 ? 1 : 3) }
        return (10 - (sum % 10)) % 10 == digits[12]
    }

    /// 書籍の ISBN-13（978/979 始まり・検算合格）か。2段目（192…）などは false
    static func isBookIsbn13(_ code: String) -> Bool {
        guard code.count == 13, code.hasPrefix("978") || code.hasPrefix("979") else { return false }
        return isValidEan13(code)
    }
}
