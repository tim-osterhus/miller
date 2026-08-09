import Foundation
import MillerCore
import MillerStorage
import Testing

@Suite
struct SQLiteConversationRepositoryTests {
    @Test
    func ensureConversationIsIdempotentPreservesStateAndCreatesNoTurn() async throws {
        let fixture = try TestDatabase(named: #function)
        let repository = try SQLiteConversationRepository(path: fixture.path)
        let conversationID = ConversationID()

        try await repository.ensureConversation(conversationID: conversationID)
        let created = try #require(
            try await repository.conversations().first { $0.id == conversationID }
        )
        try await repository.ensureConversation(conversationID: conversationID)

        #expect(try await repository.turns(conversationID: conversationID).isEmpty)
        #expect(try await repository.conversations() == [created])

        try await repository.archive(conversationID: conversationID)
        let archived = try #require(
            try await repository.conversations().first { $0.id == conversationID }
        )
        try await repository.ensureConversation(conversationID: conversationID)

        #expect(try await repository.conversations() == [archived])
        #expect(try await repository.turns(conversationID: conversationID).isEmpty)
    }
}
