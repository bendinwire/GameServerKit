import Testing
@testable import GameServerKit

@Test func chatFilterMasksWordsAndKeepsTheRest() {
    #expect(ChatFilter.clean("well shit, that was close") == "well ****, that was close")
    #expect(ChatFilter.clean("you FUCKING bot") == "you ******* bot")
    #expect(ChatFilter.clean("sh1t!") == "****!")
    #expect(ChatFilter.clean("sh!t this") == "**** this")
    #expect(ChatFilter.clean("fuuuuck") == "*******")
    #expect(ChatFilter.clean("f u c k off") == "* * * * off")
    #expect(ChatFilter.clean("what the hell, damn") == "what the hell, damn")   // mild words allowed in chat
    #expect(ChatFilter.clean("nice hand") == "nice hand")
}

@Test func chatFilterLeavesRealWordsAlone() {
    for ok in ["Scunthorpe", "assassin", "class pass", "Cassandra", "cocktail", "Dickens", "analysis",
               "Cumberland", "shiitake", "hello", "I'm a b c d", "Sh*thead is fun", "glass", "therapist"] {
        #expect(ChatFilter.clean(ok) == ok, "\(ok)")
    }
}

@Test func chatFilterStripsLinks() {
    #expect(ChatFilter.clean("go to https://evil.example/x now") == "go to [link] now")
    #expect(ChatFilter.clean("visit www.spam.biz") == "visit [link]")
    #expect(ChatFilter.clean("free coins at coins.gg/free") == "free coins at [link]")
    #expect(ChatFilter.clean("ok... sure.") == "ok... sure.")
}
