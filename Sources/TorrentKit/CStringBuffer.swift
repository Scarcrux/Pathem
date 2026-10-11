/// Decode a fixed-size C API output buffer without reading past its bounds or
/// including padding after the first NUL. Preserve C-string UTF-8 replacement.
func decodeCStringBuffer(_ buffer: [CChar]) -> String {
    String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}
