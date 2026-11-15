//
//  DocumentTurnContext.swift
//  leanring-buddy
//
//  The one call the voice turn makes for documents.
//

import Foundation

/// Everything document-related for one question: the attached files, and, when the
/// question is about "this PDF / this page / this article" and nothing is attached,
/// the whole document in the front app.
enum DocumentTurnContext {
    static func forVoiceTurn(
        question: String,
        budgetCharacters: Int = DocumentContext.defaultBudgetCharacters
    ) async -> (text: String, images: [(data: Data, label: String)]) {
        let shelf = AttachmentShelf.shared
        if !shelf.isEmpty {
            await shelf.waitUntilRead()
            return shelf.contextForNextTurn(question: question, budgetCharacters: budgetCharacters)
        }
        guard DocumentQuestionClassifier.refersToCurrentDocument(question),
              let frontDocument = await FrontDocumentReader.readFrontmost() else { return ("", []) }
        return AttachmentShelf.context(question: question, documents: [frontDocument], budgetCharacters: budgetCharacters)
    }
}
