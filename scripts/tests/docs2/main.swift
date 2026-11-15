// Run: scripts/tests/run_docs2_tests.sh
import AppKit
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
var failures = 0
var checks = 0
func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    checks += 1
    if condition() { print("ok   \(name)") } else { failures += 1; print("FAIL \(name)") }
}

let workDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("teachy-docs2/tests-\(UUID().uuidString.prefix(8))", isDirectory: true)
try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workDirectory) }
func temp(_ name: String) -> URL { workDirectory.appendingPathComponent(name) }

// MARK: - Sentences, truncation, pieces

do {
    let text = "First sentence here. Second one follows! A third? Then a line\nbreak and 3.5 metres of cable. Done."
    let sentences = DocumentTextTools.sentences(text)
    check("sentences: joining gives the text back", sentences.joined() == text)
    check("sentences: 3.5 is not split", sentences.contains { $0.contains("3.5 metres") })
    check("sentences: count", sentences.count == 6)

    let long = (1...40).map { "Sentence number \($0) has a few words in it." }.joined(separator: " ")
    for limit in [60, 137, 400, 999] {
        let cut = DocumentTextTools.truncate(long, to: limit)
        check("truncate \(limit): within limit", cut.count <= limit)
        check("truncate \(limit): ends on a sentence", cut.hasSuffix(". […]"))
    }
    check("truncate: short text untouched", DocumentTextTools.truncate("Short.", to: 100) == "Short.")
    let noStops = String(repeating: "word ", count: 200)
    let cutWords = DocumentTextTools.truncate(noStops, to: 103)
    check("truncate: no sentence ends → cut between words", cutWords.count <= 103 && cutWords.hasSuffix("word […]"))

    let pieces = DocumentTextTools.pieces(long, targetCharacters: 300)
    check("pieces: joining gives the text back", pieces.joined() == long)
    check("pieces: none over target", pieces.allSatisfy { $0.count <= 300 })
    check("pieces: each ends on a sentence", pieces.allSatisfy { DocumentTextTools.endsAtSentenceBoundary($0) })
    let blob = String(repeating: "x", count: 2500)
    let blobPieces = DocumentTextTools.pieces(blob, targetCharacters: 500)
    check("pieces: an unbroken run is still split", blobPieces.joined() == blob && blobPieces.allSatisfy { $0.count <= 500 })

    check("search words: endings meet", DocumentTextTools.searchWords("Batteries charging charged") == DocumentTextTools.searchWords("battery charge charge"))
    check("search words: common words dropped", DocumentTextTools.searchWords("What is the revenue of this?") == ["revenu"])
    check("search words: numbers kept", DocumentTextTools.searchWords("page 7 has 412 people").contains("412"))
}

// MARK: - Chunking and retrieval

let report = SyntheticReport.document()
let reportChunks = DocumentChunker.chunks(for: report)
do {
    check("chunks: every page has at least one", Set(reportChunks.map(\.sectionNumber)).count == 30)
    check("chunks: in reading order", reportChunks.map(\.order) == Array(0..<reportChunks.count))
    check("chunks: none crosses a page", reportChunks.allSatisfy { chunk in
        report.sections[chunk.sectionNumber - 1].text.contains(chunk.text)
    })
    check("chunks: none far over the target", reportChunks.allSatisfy { $0.text.count <= DocumentChunker.defaultChunkCharacters })
    check("chunks: all text kept", reportChunks.reduce(0) { $0 + $1.text.count } >= report.characterCount - 2 * reportChunks.count)

    for item in SyntheticReport.questions {
        let ranked = DocumentRetriever.rank(question: item.question, chunks: reportChunks)
        let top = ranked.first
        check("retrieval: \"\(item.question)\" → page \(item.page) first (got \(top?.chunk.sectionNumber ?? -1))",
              top?.chunk.sectionNumber == item.page && (top?.chunk.text.contains(item.answer) ?? false) && (top?.score ?? 0) > 0)
    }
    let nothing = DocumentRetriever.rank(question: "the of and", chunks: reportChunks)
    check("retrieval: a question of only common words scores nothing", nothing.allSatisfy { $0.score == 0 })
    check("retrieval: unmatched chunks keep reading order", nothing.map(\.chunk.order) == Array(0..<reportChunks.count))
}

// MARK: - Budget assembly

do {
    let wholeBudget = 200_000
    let whole = DocumentContext.buildDetailed(for: "What was the revenue?", documents: [report], budgetCharacters: wholeBudget)
    check("context: a document that fits goes in whole", whole.isWhole == [true] && whole.includedSections[0].count == 30)
    check("context whole: every page is labelled", (1...30).allSatisfy { whole.text.contains("[page \($0)]") })
    check("context whole: says full text", whole.text.contains("full text"))
    check("context whole: tells the model to cite pages", whole.text.contains("on page 12"))

    for budget in [900, 1500, 2500, 4000, 6000, 9000, 14_000, 20_000] {
        for item in SyntheticReport.questions {
            let result = DocumentContext.buildDetailed(for: item.question, documents: [report], budgetCharacters: budget)
            if result.text.count > budget {
                check("context \(budget): never over budget (\(result.text.count)) for \"\(item.question)\"", false)
            }
            if budget >= 2500 {
                if !result.text.contains(item.answer) || !result.includedSections[0].contains(item.page) {
                    check("context \(budget): answer for \"\(item.question)\" is included", false)
                }
                if !result.text.contains("[page \(item.page)]") {
                    check("context \(budget): page \(item.page) is labelled", false)
                }
            }
        }
    }
    check("context: within budget and holding the answer at 8 budgets × 10 questions", true)

    let tight = DocumentContext.buildDetailed(for: SyntheticReport.questions[5].question, documents: [report], budgetCharacters: 6000)
    check("context tight: not whole", tight.isWhole == [false])
    check("context tight: has a table of contents", tight.text.contains("Contents (first line of each page):") && tight.text.contains("- page 30: Outlook"))
    check("context tight: has the first page", tight.text.contains("[page 1]") && tight.text.contains("Letter from the chair\n"))
    check("context tight: includes the page before or after the answer's chunk when there is room", tight.includedSections[0].count >= 3)
    check("context tight: says it is a selection", tight.text.contains("selected parts"))

    // No sentence is cut in the middle: every line of every included page is a whole line of that page.
    var brokenLines = 0
    for budget in [1500, 2500, 4000, 6000, 9000] {
        for item in SyntheticReport.questions {
            let text = DocumentContext.build(for: item.question, documents: [report], budgetCharacters: budget)
            var currentPage: Int?
            for line in text.components(separatedBy: "\n") {
                if line.hasPrefix("[page "), let number = Int(line.dropFirst(6).dropLast()) { currentPage = number; continue }
                guard let page = currentPage, !line.isEmpty, line != "[…]" else { continue }
                let pageText = SyntheticReport.text(forPage: page)
                let body = line.hasSuffix(" […]") ? String(line.dropLast(4)) : line
                if !pageText.contains(body) { brokenLines += 1; continue }
                if !DocumentTextTools.endsAtSentenceBoundary(body) && !pageText.components(separatedBy: "\n").contains(body) { brokenLines += 1 }
            }
        }
    }
    check("context: no sentence split in the middle across 50 builds (broken: \(brokenLines))", brokenLines == 0)

    // A question that matches nothing still gets a spread of the document.
    let summary = DocumentContext.buildDetailed(for: "Summarize this.", documents: [report], budgetCharacters: 9000)
    let spread = summary.includedSections[0]
    print("     summarize spread: \(spread)")
    check("context: 'summarize' gets pages from start, middle and end", spread.contains { $0 <= 5 } && spread.contains { $0 > 10 && $0 <= 20 } && spread.contains { $0 > 24 })
    check("context: 'summarize' stays in budget", summary.text.count <= 9000)

    // Two documents: the short one goes in whole, the long one is excerpted.
    let memo = ReadDocument(title: "memo.txt", kind: .text, sections: [DocumentSection(number: 1, title: "lines 1–2", text: "The offsite is on 14 May in Leith.\nBring the tide tables.")])
    let both = DocumentContext.buildDetailed(for: "When is the offsite and what dividend is proposed?", documents: [report, memo], budgetCharacters: 7000)
    check("context two documents: within budget", both.text.count <= 7000)
    check("context two documents: short one whole, long one not", both.isWhole == [false, true])
    check("context two documents: both answers present", both.text.contains("14 May") && both.text.contains("0.42 euros"))
    check("context two documents: numbered headers", both.text.contains("=== Document 1: \"Northwind Tidal Annual Report 2025\" (PDF, 30 pages)") && both.text.contains("=== Document 2: \"memo.txt\""))

    check("context: no documents → empty", DocumentContext.build(for: "x", documents: [], budgetCharacters: 1000).isEmpty)
    check("context: absurd budget still respected", DocumentContext.build(for: "revenue", documents: [report], budgetCharacters: 120).count <= 120)

    let picture = ReadDocument(title: "whiteboard.png", kind: .image, sections: [], pageCount: 1, imageData: Data([1, 2, 3]))
    let pictureContext = AttachmentShelf.context(question: "what is this", documents: [picture, memo], budgetCharacters: 4000)
    check("context: a picture is handed over as an image with a label", pictureContext.images.count == 1 && pictureContext.images[0].label.contains("whiteboard.png"))
    check("context: and mentioned in the text", pictureContext.text.contains("picture itself is attached"))
}

// MARK: - Reading files

func readOrNil(_ url: URL) async -> ReadDocument? { try? await DocumentReader.read(url: url) }
func readError(_ url: URL) async -> DocumentReadError? {
    do { _ = try await DocumentReader.read(url: url); return nil } catch { return error as? DocumentReadError }
}

do {
    // PDF with a text layer plus one scanned page.
    let pdfURL = temp("report.pdf")
    SyntheticReport.writePDF(to: pdfURL, scannedPageText: "INVOICE 4471\nTotal due 980 euros\nPay before 30 June")
    let pdf = await readOrNil(pdfURL)
    check("pdf: read", pdf != nil)
    if let pdf {
        check("pdf: kind and page count (31 with the scan)", pdf.kind == .pdf && pdf.pageCount == 31 && pdf.sections.count == 31)
        check("pdf: title from the PDF's own metadata", pdf.title == SyntheticReport.title)
        check("pdf: page numbers are 1-based and in order", pdf.sections.map(\.number) == Array(1...31))
        var pagesWithFact = 0
        for (index, page) in SyntheticReport.pages.enumerated() {
            let flattened = pdf.sections[index].text.replacingOccurrences(of: "\n", with: " ")
            if flattened.contains(page.fact) && flattened.contains(page.heading) { pagesWithFact += 1 }
        }
        check("pdf: every page's text is on its own page (\(pagesWithFact)/30)", pagesWithFact == 30)
        check("pdf: text pages are not marked as recognised", pdf.sections.prefix(30).allSatisfy { !$0.usedOCR })
        let scanned = pdf.sections[30]
        check("pdf: the scanned page was recognised (got: \(scanned.text.replacingOccurrences(of: "\n", with: " / ")))",
              scanned.usedOCR && scanned.text.contains("4471") && scanned.text.lowercased().contains("total due"))
        check("pdf: not truncated", !pdf.isTruncated)

        // The real PDF through chunking and retrieval, end to end.
        let pdfChunks = DocumentChunker.chunks(for: pdf)
        var firstRankHits = 0
        for item in SyntheticReport.questions where DocumentRetriever.rank(question: item.question, chunks: pdfChunks).first?.chunk.sectionNumber == item.page { firstRankHits += 1 }
        check("pdf: retrieval on the extracted text ranks the right page first (\(firstRankHits)/10)", firstRankHits == 10)
        let invoice = DocumentContext.buildDetailed(for: "How much is the invoice total?", documents: [pdf], budgetCharacters: 5000)
        check("pdf: a question about the scanned page finds page 31", invoice.includedSections[0].contains(31) && invoice.text.contains("[page 31]"))
    }

    // CSV
    let csvURL = temp("sales.csv")
    var csv = "region,units,price,note\n"
    for row in 1...120 {
        csv += "\(["North", "South", "East"][row % 3]),\(row * 3),\(Double(row) + 0.5),\"said \"\"ok\"\", then left\"\n"
    }
    csv += "West,7,19.5,\"multi\nline\"\n"
    try csv.write(to: csvURL, atomically: true, encoding: .utf8)
    let table = CSVTable.parse(csv)
    check("csv: header", table.header == ["region", "units", "price", "note"])
    check("csv: rows", table.rows.count == 121)
    check("csv: quoted cell with doubled quotes and a comma", table.rows[0][3] == "said \"ok\", then left")
    check("csv: quoted cell with a line break", table.rows[120][3] == "multi\nline")
    let preview = table.preview()
    check("csv preview: size line", preview.hasPrefix("Table: 121 rows, 4 columns."))
    check("csv preview: number ranges", preview.contains("units (number, 3 to 360)") && preview.contains("price (number, 1.5 to 120.5)"))
    check("csv preview: few-valued column", preview.contains("region (4 different values)"))
    check("csv preview: markdown header and first and last rows", preview.contains("| region | units | price | note |") && preview.contains("| South | 3 | 1.5 |") && preview.contains("| West | 7 | 19.5 | multi line |"))
    check("csv preview: does not list all rows", !preview.contains("| 180 |"))
    check("csv: semicolons and tabs are detected", CSVTable.parse("a;b\n1;2").rows == [["1", "2"]] && CSVTable.parse("a\tb\n1\t2").header == ["a", "b"])
    let csvDocument = await readOrNil(csvURL)
    check("csv file: overview first, then row blocks", csvDocument?.kind == .csv && csvDocument?.sections.first?.title == "overview" && csvDocument?.sections[1].title == "rows 1–60")
    if let csvDocument {
        let found = DocumentContext.build(for: "which row has 180 units", documents: [csvDocument], budgetCharacters: 3000)
        check("csv file: a row outside the preview can be found", found.contains("| 180 |") && found.count <= 3000)
    }

    // Markdown, code, JSON, HTML, RTF, DOCX
    let markdownURL = temp("notes.md")
    try "# Setup\nInstall the thing.\n\n## Usage\nRun `teachy`.\n\n```\n# not a heading\n```\n".write(to: markdownURL, atomically: true, encoding: .utf8)
    let markdown = await readOrNil(markdownURL)
    check("markdown: split at headings, not inside code", markdown?.kind == .markdown && markdown?.sections.map(\.title) == ["Setup", "Usage"])

    let swiftURL = temp("Thing.swift")
    try (1...300).map { "let value\($0) = \($0)" }.joined(separator: "\n").write(to: swiftURL, atomically: true, encoding: .utf8)
    let code = await readOrNil(swiftURL)
    check("code: kind, and sections titled by line range", code?.kind == .code && code?.sections.first?.title?.hasPrefix("lines 1–") == true)
    if let code, let last = code.sections.last?.title {
        check("code: last section ends at line 300 (\(last))", last.hasSuffix("–300"))
        let labelled = DocumentContext.build(for: "value250", documents: [code], budgetCharacters: 100_000)
        check("code: context labels sections with line ranges", labelled.contains("[section 1 · lines 1–"))
    }

    let jsonURL = temp("config.json")
    try "{\"name\": \"teachy\", \"port\": 8080}".write(to: jsonURL, atomically: true, encoding: .utf8)
    let json = await readOrNil(jsonURL)
    check("json: read as text", json?.kind == .json && json?.sections.first?.text.contains("8080") == true)

    let htmlURL = temp("page.html")
    try "<html><head><title>Tide &amp; Time</title><style>p{color:red}</style></head><body><script>var hidden = 1;</script><h1>Hello</h1><p>First&nbsp;paragraph &#8212; done.</p><ul><li>One</li><li>Two</li></ul></body></html>".write(to: htmlURL, atomically: true, encoding: .utf8)
    let html = await readOrNil(htmlURL)
    let htmlText = html?.sections.first?.text ?? ""
    check("html: title from <title>", html?.title == "Tide & Time")
    check("html: tags, scripts and styles gone; entities decoded", htmlText.contains("First paragraph — done.") && !htmlText.contains("hidden") && !htmlText.contains("color:red") && !htmlText.contains("<"))
    check("html: list items on their own lines", htmlText.contains("• One\n• Two"))

    let rich = NSAttributedString(string: "Quarterly plan\nThe launch moves to the ninth of October.", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
    let rtfURL = temp("plan.rtf")
    try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: rtfURL)
    let rtf = await readOrNil(rtfURL)
    check("rtf: text read", rtf?.kind == .richText && rtf?.sections.first?.text.contains("ninth of October") == true)
    let docxURL = temp("plan.docx")
    try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]).write(to: docxURL)
    let docx = await readOrNil(docxURL)
    check("docx: text read", docx?.kind == .richText && docx?.sections.first?.text.contains("ninth of October") == true)

    // Image with text in it
    let imageURL = temp("sign.png")
    let imageSize = NSSize(width: 900, height: 300)
    if let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 300, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: imageSize).fill()
        ("Harbour closes at 21:30" as NSString).draw(at: NSPoint(x: 60, y: 120), withAttributes: [.font: NSFont.systemFont(ofSize: 56), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])?.write(to: imageURL)
    }
    let image = await readOrNil(imageURL)
    check("image: kept for the vision model as JPEG", image?.kind == .image && (image?.imageData?.starts(with: [0xFF, 0xD8]) ?? false))
    check("image: its text was recognised (got: \(image?.sections.first?.text ?? "nothing"))", image?.sections.first?.text.contains("21:30") == true)

    // Things that can't be read
    let binaryURL = temp("blob.xyz")
    try Data((0..<4096).map { UInt8($0 % 251) }).write(to: binaryURL)
    let binaryError = await readError(binaryURL)
    let numbersURL = temp("budget.numbers")
    try Data([80, 75, 3, 4]).write(to: numbersURL)
    let numbersError = await readError(numbersURL)
    check("Numbers file: asks for an export", numbersError == .needsExport("budget.numbers") && (numbersError?.errorDescription?.hasPrefix("Export budget.numbers as PDF first.") ?? false))
    check("unknown binary: a clear 'can't read this kind yet' error", binaryError == .unsupportedKind(".xyz") && (binaryError?.errorDescription?.contains("can't read .xyz files yet") ?? false))
    let unknownTextURL = temp("notes.weird")
    try "plain words in a file with an odd extension\n".write(to: unknownTextURL, atomically: true, encoding: .utf8)
    let unknownText = await readOrNil(unknownTextURL)
    check("unknown extension but plainly text: read", unknownText?.kind == .text)
    let missingError = await readError(temp("gone.pdf"))
    check("missing file: clear error", missingError == .notFound("gone.pdf"))
    let folderError = await readError(workDirectory)
    check("folder: clear error", folderError == .isFolder(workDirectory.lastPathComponent))
    let emptyURL = temp("empty.txt")
    try "".write(to: emptyURL, atomically: true, encoding: .utf8)
    let emptyError = await readError(emptyURL)
    check("empty file: clear error", emptyError == .empty("empty.txt"))
    let notPDFURL = temp("fake.pdf")
    try "this is not a pdf".write(to: notPDFURL, atomically: true, encoding: .utf8)
    let notPDFError = await readError(notPDFURL)
    check("broken pdf: clear error", notPDFError == .unreadable("fake.pdf"))

    // A file far over the text limit: only the start is read, and the file is never loaded whole.
    let bigURL = temp("huge.log")
    FileManager.default.createFile(atPath: bigURL.path, contents: nil)
    let handle = try FileHandle(forWritingTo: bigURL)
    let line = Data((String(repeating: "log line with some words in it ", count: 4) + "\n").utf8)
    var block = Data()
    while block.count < 1024 * 1024 { block.append(line) }
    for _ in 0..<12 { try handle.write(contentsOf: block) }
    try handle.close()
    let prefix = try DocumentReader.readPrefix(of: bigURL, limit: 1000)
    check("big file: prefix read stops at the limit", prefix.data.count == 1000 && !prefix.reachedEnd)
    let big = await readOrNil(bigURL)
    check("big file: read, marked as partly read", big?.isTruncated == true && (big?.truncationNote?.contains("Only the first 4 MB of this 12 MB file") ?? false))
    check("big file: at most the limit kept", (big?.characterCount ?? .max) <= DocumentLimits.maximumTextBytes)
    check("big file: does not end on half a line", big?.sections.last?.text.trimmingCharacters(in: .whitespaces).hasSuffix("words in it") == true)

    // A sparse 3 GB "PDF": refused from its size alone, without reading it.
    let giantURL = temp("giant.pdf")
    FileManager.default.createFile(atPath: giantURL.path, contents: nil)
    let giantHandle = try FileHandle(forWritingTo: giantURL)
    try giantHandle.truncate(atOffset: 3 * 1024 * 1024 * 1024)
    try giantHandle.close()
    let started = Date()
    let giantError = await readError(giantURL)
    check("3 GB file: refused by size, at once", giantError == .tooLarge(name: "giant.pdf", megabytes: 3072, limitMegabytes: 400) && Date().timeIntervalSince(started) < 1)
    try? FileManager.default.removeItem(at: giantURL)
}

// MARK: - "Is this about the document in front of me?"

do {
    let yes = [
        "Summarize this PDF",
        "can you summarise this article for me",
        "What does this page say about pricing?",
        "what are the key points of this document",
        "Explain this paper to me like I'm new to it",
        "tl;dr",
        "summarize this",
        "Give me the gist",
        "Read the whole page and tell me if there's a refund policy",
        "what's the main argument of the essay",
        "Does this contract mention a notice period?",
        "according to this report, how many people were hired",
        "Is there anything about cancellation in these terms... I mean in this policy",
        "which page talks about the dividend in this report",
        "translate this document into Spanish",
        "what is this article about?",
        "proofread my draft",
        "Open this PDF and summarize it"
    ]
    let no = [
        "what's this button",
        "how do I make this bold",
        "point to the file menu",
        "save this document",
        "open this file",
        "close this page",
        "print the page",
        "scroll down this page",
        "what's the weather today",
        "where is the share button on this page",
        "create a new document",
        "what does this error mean",
        "explain this function",
        "how do i export this document as a pdf",
        "what does this icon do",
        "summarize my day",
        "rename the file",
        "what is the page number setting for",
        "draw a turbofan engine",
        "",
        "ok"
    ]
    for question in yes { check("classifier yes: \"\(question)\"", DocumentQuestionClassifier.refersToCurrentDocument(question)) }
    for question in no { check("classifier no:  \"\(question)\"", !DocumentQuestionClassifier.refersToCurrentDocument(question)) }
}

// MARK: - Attachments

do {
    let first = URL(fileURLWithPath: "/tmp/a/report.pdf")
    check("rules: a new file is added", AttachmentRules.outcome(adding: first, to: []) == .added)
    check("rules: the same file is not added twice", AttachmentRules.outcome(adding: first, to: [first]) == .alreadyAttached)
    check("rules: the same file by a different spelling", AttachmentRules.outcome(adding: URL(fileURLWithPath: "/tmp/a/../a/./report.pdf"), to: [first]) == .alreadyAttached)
    let five = (1...5).map { URL(fileURLWithPath: "/tmp/a/\($0).txt") }
    check("rules: a sixth file is refused", AttachmentRules.outcome(adding: first, to: five) == .full)
    check("rules: a duplicate is reported as a duplicate even when full", AttachmentRules.outcome(adding: five[0], to: five) == .alreadyAttached)

    var urls: [URL] = []
    for number in 1...7 {
        let url = temp("attach-\(number).txt")
        try "File number \(number) says the code word is walrus\(number).".write(to: url, atomically: true, encoding: .utf8)
        urls.append(url)
    }
    let shelf = AttachmentShelf()
    check("shelf: first add", shelf.add(url: urls[0]) == .added)
    check("shelf: duplicate refused with a notice", shelf.add(url: urls[0]) == .alreadyAttached && shelf.items.count == 1 && shelf.notice?.contains("already attached") == true)
    for url in urls[1...4] { shelf.add(url: url) }
    check("shelf: five attached", shelf.items.count == 5)
    check("shelf: sixth refused with a notice", shelf.add(url: urls[5]) == .full && shelf.items.count == 5 && shelf.notice?.contains("Up to 5") == true)
    await shelf.waitUntilRead()
    check("shelf: all five read", shelf.documents.count == 5 && !shelf.isReading)
    let context = shelf.contextForNextTurn(question: "what is the code word", budgetCharacters: 4000)
    check("shelf: context holds all five, within budget", (1...5).allSatisfy { context.text.contains("walrus\($0)") } && context.text.count <= 4000)
    shelf.remove(id: shelf.items[0].id)
    check("shelf: remove frees a place", shelf.items.count == 4 && shelf.add(url: urls[5]) == .added)
    let badURL = temp("thing.xyz")
    try Data([0, 1, 2, 0, 255]).write(to: badURL)
    shelf.remove(id: shelf.items[0].id)
    shelf.add(url: badURL)
    await shelf.waitUntilRead()
    check("shelf: an unreadable file shows why, and is left out of the context", shelf.items.last?.isFailed == true && shelf.items.last?.detail.contains("can't read .xyz files yet") == true && shelf.documents.count == 4)
    shelf.clear()
    check("shelf: clear", shelf.isEmpty && shelf.contextForNextTurn(question: "x").text.isEmpty)
}

// MARK: - Timeline

do {
    let fileURL = temp("brain/timeline.jsonl")
    let store = ChatTimelineStore(fileURL: fileURL)
    check("timeline: empty before anything is posted", store.rows().isEmpty)
    let base = Date(timeIntervalSince1970: 1_794_000_000)
    store.post(.drawing(title: "How a turbofan works", thumbnailURL: URL(fileURLWithPath: "/tmp/turbofan.png"), id: "d1"), date: base)
    store.post(.job(title: "Inbox Hunter", status: .running, answer: nil, id: "j1"), date: base.addingTimeInterval(60))
    store.post(.note("Attached report.pdf"), date: base.addingTimeInterval(90))
    store.post(.job(title: "Inbox Hunter", status: .done, answer: "Three emails need a reply.", id: "j1"), date: base.addingTimeInterval(300))

    let reopened = ChatTimelineStore(fileURL: fileURL).rows()
    check("timeline: saved and read back by a new store", reopened.count == 3)
    check("timeline: kinds in order", reopened.map(\.kind) == [.drawing, .job, .note])
    check("timeline: a job posted again updates its row in place", reopened[1].status == .done && reopened[1].answer == "Three emails need a reply." && reopened[1].date == base.addingTimeInterval(60))
    check("timeline: drawing keeps its thumbnail path", reopened[0].thumbnailPath == "/tmp/turbofan.png")
    check("timeline: file is one JSON object per line", (try? String(contentsOf: fileURL, encoding: .utf8))?.split(separator: "\n").count == 3)

    try (ChatTimelineStore.encode(reopened) + "this line is not json\n{\"id\":1}\n").write(to: fileURL, atomically: true, encoding: .utf8)
    check("timeline: unreadable lines are skipped", store.rows().count == 3)
    for number in 0..<(ChatTimelineStore.maximumRows + 20) { store.post(.note("note \(number)"), date: base.addingTimeInterval(1000 + Double(number))) }
    check("timeline: capped at \(ChatTimelineStore.maximumRows) rows, newest kept", store.rows().count == ChatTimelineStore.maximumRows && store.rows().last?.title == "note \(ChatTimelineStore.maximumRows + 19)")
    store.removeAll()
    check("timeline: removeAll", store.rows().isEmpty)

    // Thread
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let now = Date(timeIntervalSince1970: 1_794_441_600 + 43_200) // a noon, UTC
    func ago(days: Double, minutes: Double = 0) -> Date { now.addingTimeInterval(-days * 86_400 + minutes * 60) }
    let messages = [
        ChatMessage(isFromUser: true, text: "Old question", date: ago(days: 9)),
        ChatMessage(isFromUser: false, text: "Old answer", date: ago(days: 9, minutes: 1)),
        ChatMessage(isFromUser: true, text: "What is a café?", date: ago(days: 1)),
        ChatMessage(isFromUser: false, text: "A place for coffee. [POINT:120,300:menu]", date: ago(days: 1, minutes: 1)),
        ChatMessage(isFromUser: true, text: "Show me a turbofan", date: ago(days: 0, minutes: -30))
    ]
    let rows = [
        ChatTimelineRow(id: "drawing-d1", kind: .drawing, title: "Turbofan", date: ago(days: 0, minutes: -29)),
        ChatTimelineRow(id: "job-j1", kind: .job, title: "Inbox Hunter", date: ago(days: 1, minutes: 5), status: .done, answer: "Three emails need a reply.")
    ]
    let thread = ChatThread.merge(messages: messages, rows: rows)
    check("thread: rows sit between messages by time", thread.map(\.id).suffix(3) == ["job-j1", thread[thread.count - 2].id, "drawing-d1"])
    check("thread: action tags are not shown", thread.contains { $0.content == .assistantMessage("A place for coffee.") })
    check("thread: unique ids", Set(thread.map(\.id)).count == thread.count)
    let days = ChatThread.days(thread, now: now, calendar: calendar, locale: Locale(identifier: "en_GB"))
    check("thread: grouped into three days", days.count == 3 && days.map { $0.items.count } == [2, 3, 2])
    check("thread: day labels (\(days.map(\.label)))", days[1].label == "Yesterday" && days[2].label == "Today" && days[0].label.contains("November") )
    let weekday = ChatThread.dayLabel(for: calendar.startOfDay(for: ago(days: 3)), now: now, calendar: calendar, locale: Locale(identifier: "en_GB"))
    check("thread: a day this week is named (\(weekday))", ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"].contains(weekday))

    check("search: one word, any case", ChatThread.filter(thread, matching: "TURBOFAN").count == 2)
    check("search: accents ignored", ChatThread.filter(thread, matching: "cafe").count == 1)
    check("search: all words must match", ChatThread.filter(thread, matching: "emails reply").map(\.id) == ["job-j1"] && ChatThread.filter(thread, matching: "emails turbofan").isEmpty)
    check("search: empty shows everything", ChatThread.filter(thread, matching: "  ").count == thread.count)

    let live = ChatThread.merge(messages: messages, rows: [], pendingQuestion: ("And the bypass ratio?", now), streamingReply: ("It is the air going around the core [POINT:3", now))
    check("thread: a question just asked shows at once", live[live.count - 2].content == .userMessage("And the bypass ratio?"))
    check("thread: the arriving reply shows without a half-arrived tag", live.last?.content == .streamingReply("It is the air going around the core"))
    let saved = messages + [ChatMessage(isFromUser: true, text: "And the bypass ratio?", date: now.addingTimeInterval(4))]
    check("thread: once saved, the question is not shown twice", ChatThread.merge(messages: saved, rows: [], pendingQuestion: ("And the bypass ratio?", now)).filter { $0.plainText == "And the bypass ratio?" }.count == 1)

    // Reply text
    check("tags: whole tags removed", ChatReplyText.withoutActionTags("Click here. [POINT:10,20:Save] Then wait. [SHOW: a pendulum]") == "Click here. Then wait.")
    check("tags: code indentation is left alone", ChatReplyText.withoutActionTags("```\nif x {\n    go()\n}\n``` [POINT:1,2:x]") == "```\nif x {\n    go()\n}\n```")
    check("tags: ordinary brackets kept", ChatReplyText.withoutActionTags("Use array[0] and [see note].") == "Use array[0] and [see note].")
    check("tags: a tag still arriving is hidden", ChatReplyText.withoutActionTags("Sure. [SH") == "Sure." && ChatReplyText.withoutActionTags("Sure. [") == "Sure.")
    let blocks = ChatReplyText.blocks("Here you go:\n\n```swift\nlet a = 1\n\nprint(a)\n```\nThat prints 1.\n```\nunclosed")
    check("blocks: paragraph, code with language, paragraph, unclosed code", blocks == [
        .paragraph("Here you go:"), .code(language: "swift", text: "let a = 1\n\nprint(a)"), .paragraph("That prints 1."), .code(language: nil, text: "unclosed")
    ])

    check("composer: Return sends", ChatComposerKeyRule.action(shift: false, option: false, isComposingText: false) == .send)
    check("composer: Shift+Return adds a line", ChatComposerKeyRule.action(shift: true, option: false, isComposingText: false) == .insertNewline)
    check("composer: Option+Return adds a line", ChatComposerKeyRule.action(shift: false, option: true, isComposingText: false) == .insertNewline)
    check("composer: Return while an input method is composing is left alone", ChatComposerKeyRule.action(shift: false, option: false, isComposingText: true) == .passThrough)
}

print(failures == 0 ? "\nALL \(checks) CHECKS PASSED" : "\n\(failures) OF \(checks) CHECKS FAILED")
exit(failures == 0 ? 0 : 1)
