import Foundation

@main
struct CodegenWire {
    static func main() {
        FileHandle.standardError.write(
            Data("codegen-wire: scaffold placeholder — real generator lands in a later commit\n".utf8)
        )
    }
}
