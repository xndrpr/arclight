import Testing

@testable import ArclightEditor

struct ChatMarkdownTests {
    /// A reply being written is parsed in two parts (the settled head is cached): the blocks must be the same as
    /// parsing it whole, at every length it passes through.
    @Test func liveParsingMatchesWholeParsing() {
        let reply = """
            # Plan

            First paragraph with **bold**
            and a second line.

            - one
              - nested

            ```swift
            let a = 1

            let b = 2
            ```

            1. step one
            2. step two

            Last words
            """
        for n in 0...reply.count {
            let s = String(reply.prefix(n))
            #expect(ChatMarkdown.cachedBlocks(s, live: true) == ChatMarkdown.blocks(s), "at \(n) characters")
        }
    }
}
