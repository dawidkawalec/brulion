import Foundation

/// Sizes in the local AI's texts: decimal gigabytes with one decimal ("1,7 GB" in Polish),
/// matching the sizes Hugging Face and the PRD use.
enum LocalAIFormat {
    static func gigabytes(_ bytes: Int64, locale: Locale = AppLocale.current) -> String {
        let value = Double(bytes) / 1_000_000_000
        let number = value.formatted(.number.precision(.fractionLength(1)).locale(locale))
        return "\(number) GB"
    }
}
