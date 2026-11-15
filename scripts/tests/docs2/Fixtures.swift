// Shared by the docs2 unit tests and the docs2 model check: a synthetic 30-page
// annual report where each page holds one fact that no other page has, plus the
// questions that fact answers.
import AppKit
import CoreText
import Foundation

struct ReportPage {
    let heading: String
    let fact: String
}

struct ReportQuestion {
    let question: String
    let page: Int
    /// Words the answer-bearing text contains.
    let answer: String
}

enum SyntheticReport {
    static let title = "Northwind Tidal Annual Report 2025"

    static let pages: [ReportPage] = [
        ReportPage(heading: "Letter from the chair", fact: "Our chair, Ingrid Halvorsen, opened the year by moving the head office from Bergen to Stavanger."),
        ReportPage(heading: "Company at a glance", fact: "Northwind Tidal employed 412 people at the end of the year, up from 367."),
        ReportPage(heading: "Turbine fleet", fact: "The fleet grew to 38 seabed turbines, each rated at 2.5 megawatts."),
        ReportPage(heading: "Energy delivered", fact: "We delivered 196 gigawatt hours to the grid, enough for about 49,000 homes."),
        ReportPage(heading: "Revenue", fact: "Revenue reached 84.6 million euros, an increase of 11 percent on the previous year."),
        ReportPage(heading: "Operating costs", fact: "Operating costs were 51.2 million euros, with vessel hire the largest single item."),
        ReportPage(heading: "Maintenance programme", fact: "Each turbine is lifted for a full overhaul every 54 months by the service vessel Skarv."),
        ReportPage(heading: "Blade redesign", fact: "The new carbon blade, called Fulmar, is 9 metres long and cut cavitation noise by a third."),
        ReportPage(heading: "Grid connection", fact: "A second subsea cable to Kirkwall was energised in March, carrying 66 kilovolts."),
        ReportPage(heading: "Safety", fact: "There were two lost-time injuries, both on the quay at Scrabster, and no injuries offshore."),
        ReportPage(heading: "Marine wildlife", fact: "Acoustic monitoring logged 1,340 harbour porpoise passes and no recorded collisions."),
        ReportPage(heading: "Seabed survey", fact: "The seabed survey found kelp regrowth on 70 percent of the foundations within eighteen months."),
        ReportPage(heading: "Community fund", fact: "The community fund paid 620,000 pounds to projects in Orkney, the largest being a ferry terminal waiting room."),
        ReportPage(heading: "Apprenticeships", fact: "Twenty-three apprentices started in September, nine of them trained as subsea electricians."),
        ReportPage(heading: "Research partners", fact: "With the University of Strathclyde we tested a biofouling coating made from crushed mussel shells."),
        ReportPage(heading: "Storm season", fact: "During storm Agnes in November the array was shut down for 31 hours as waves passed 12 metres."),
        ReportPage(heading: "Availability", fact: "Fleet availability averaged 94.3 percent, against a target of 92 percent."),
        ReportPage(heading: "Customers", fact: "Our largest customer is the Flotta hydrogen plant, which buys 40 percent of our output."),
        ReportPage(heading: "Pricing", fact: "The average contracted price was 178 euros per megawatt hour under fifteen-year agreements."),
        ReportPage(heading: "Debt and financing", fact: "We refinanced with a 120 million euro green bond that matures in 2037 at a coupon of 4.1 percent."),
        ReportPage(heading: "Dividend", fact: "The board proposes a dividend of 0.42 euros per share, payable on 19 June."),
        ReportPage(heading: "Board changes", fact: "Tomasz Wieczorek joined the board as finance director, replacing Aileen Drummond who retired."),
        ReportPage(heading: "Risk register", fact: "The top risk is gearbox seal failure, which caused 61 percent of unplanned downtime."),
        ReportPage(heading: "Insurance", fact: "Insurance premiums rose 18 percent after an anchor strike damaged a cable near Stroma."),
        ReportPage(heading: "Supply chain", fact: "Nacelles are now assembled in Arbroath rather than shipped from Gdansk, saving three weeks per unit."),
        ReportPage(heading: "Digital twin", fact: "A digital twin named Petrel predicts bearing wear eleven weeks ahead using vibration data."),
        ReportPage(heading: "Expansion plans", fact: "Phase three will add 24 turbines in the Pentland Firth, with first power planned for 2028."),
        ReportPage(heading: "Decommissioning", fact: "A decommissioning reserve of 7.8 million euros is held in escrow with Nordea."),
        ReportPage(heading: "Carbon accounting", fact: "Lifecycle emissions were 14 grams of carbon dioxide per kilowatt hour, mostly from steel."),
        ReportPage(heading: "Outlook", fact: "For 2026 we expect output of 230 gigawatt hours and plan to hire 60 more staff.")
    ]

    /// Sentences every page shares, so word matching has real distractors.
    private static let filler = [
        "Northwind Tidal runs tidal turbines in the waters between the Scottish mainland and Orkney.",
        "This section of the annual report sets out what happened during the year and what the board expects next.",
        "Figures are stated in euros unless noted, and compared with the previous year where that helps.",
        "The management team reviewed these results with the audit committee before publication.",
        "As in earlier years, the year was shaped by weather, vessel availability and the pace of grid work.",
        "Further detail is given in the notes at the back of the report and on the company website.",
        "The turbines sit on the seabed and turn with each tide, so output is predictable years ahead.",
        "Staff, contractors and partners all contributed to the results described here."
    ]

    static func text(forPage pageNumber: Int) -> String {
        let page = pages[pageNumber - 1]
        var lines = [page.heading, ""]
        // The fact sits in the middle of the page, between shared sentences.
        let rotated = (0..<filler.count).map { filler[($0 + pageNumber) % filler.count] }
        lines.append(rotated.prefix(4).joined(separator: " "))
        lines.append("")
        lines.append(page.fact + " " + rotated[4])
        lines.append("")
        lines.append(rotated.suffix(3).joined(separator: " ") + " " + rotated.prefix(3).joined(separator: " "))
        return lines.joined(separator: "\n")
    }

    static let questions: [ReportQuestion] = [
        ReportQuestion(question: "How many people did Northwind Tidal employ at the end of the year?", page: 2, answer: "412"),
        ReportQuestion(question: "What was the revenue and how much did it increase?", page: 5, answer: "84.6 million"),
        ReportQuestion(question: "How often is each turbine lifted for a full overhaul?", page: 7, answer: "54 months"),
        ReportQuestion(question: "What is the new carbon blade called and how long is it?", page: 8, answer: "Fulmar"),
        ReportQuestion(question: "How many harbour porpoise passes did the acoustic monitoring log?", page: 11, answer: "1,340"),
        ReportQuestion(question: "How long was the array shut down during storm Agnes?", page: 16, answer: "31 hours"),
        ReportQuestion(question: "Who is the largest customer and what share of output do they buy?", page: 18, answer: "Flotta"),
        ReportQuestion(question: "What dividend per share does the board propose?", page: 21, answer: "0.42"),
        ReportQuestion(question: "What causes most of the unplanned downtime?", page: 23, answer: "gearbox seal"),
        ReportQuestion(question: "What does the digital twin Petrel predict?", page: 26, answer: "bearing wear")
    ]

    static func document() -> ReadDocument {
        ReadDocument(
            title: title, kind: .pdf,
            sections: (1...pages.count).map { DocumentSection(number: $0, text: text(forPage: $0)) }
        )
    }

    /// Writes the report as a real PDF with a text layer, one report page per PDF page.
    /// `scannedPageText`, when given, is added as a last page that is only a picture of text.
    static func writePDF(to url: URL, scannedPageText: String? = nil) {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let attributes = [kCGPDFContextTitle: title] as CFDictionary
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, attributes) else { return }
        let bodyFont = NSFont.systemFont(ofSize: 12)
        let headingFont = NSFont.boldSystemFont(ofSize: 18)

        func draw(_ attributed: NSAttributedString, in rect: CGRect) {
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            let path = CGPath(rect: rect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
            CTFrameDraw(frame, context)
        }

        for pageNumber in 1...pages.count {
            context.beginPDFPage(nil)
            let pageText = text(forPage: pageNumber)
            let lines = pageText.components(separatedBy: "\n")
            let attributed = NSMutableAttributedString(string: lines[0] + "\n", attributes: [.font: headingFont])
            attributed.append(NSAttributedString(string: lines.dropFirst().joined(separator: "\n"), attributes: [.font: bodyFont]))
            draw(attributed, in: CGRect(x: 72, y: 72, width: 468, height: 648))
            context.endPDFPage()
        }

        if let scannedPageText {
            // A picture of text: no text layer, so the reader must recognise it.
            let width = 1224, height = 1584
            if let bitmap = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) {
                bitmap.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
                let scanned = NSAttributedString(string: scannedPageText, attributes: [
                    .font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black
                ])
                let framesetter = CTFramesetterCreateWithAttributedString(scanned)
                let frame = CTFramesetterCreateFrame(
                    framesetter, CFRange(location: 0, length: 0),
                    CGPath(rect: CGRect(x: 100, y: 100, width: width - 200, height: height - 200), transform: nil), nil)
                CTFrameDraw(frame, bitmap)
                if let image = bitmap.makeImage() {
                    context.beginPDFPage(nil)
                    context.draw(image, in: mediaBox)
                    context.endPDFPage()
                }
            }
        }
        context.closePDF()
    }
}
