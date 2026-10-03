import Foundation

@main
enum BlocklistCheck {
    static func main() throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let list = Blocklist(try String(contentsOf: source, encoding: .utf8))
        assert(list.blocks("adult"))
        assert(list.blocks("www.adult"))
        assert(list.blocks("ADULT."))
        assert(list.blocks("anime-rule34-world.b-cdn.net"))
        assert(!list.blocks("sub.anime-rule34-world.b-cdn.net"))
        assert(!list.blocks("notadult"))
        assert(!list.blocks("example.org"))
        print("Blocklist check passed")
    }
}
