// Jev request/answer handling and the 3D drawing router. No network unless JEV_LIVE=1
// (then one real call through Vercel AI Gateway, with AI_GATEWAY_API_KEY from the environment).
import Foundation

var failures = 0
func check(_ condition: Bool, _ name: String) {
    if condition { print("ok   \(name)") } else { failures += 1; print("FAIL \(name)") }
}

// Request body
let body = TeachyJev.requestBody(state: "hi", questions: ["urgent": .noul(instructions: "Urgent?"),
                                                           "team": .choice(instructions: "Team", criteria: ["a": "A"]),
                                                           "mood": .score(instructions: "Mood", levels: ["calm", "angry"])])
check(body["model"] as? String == "typesafe-ai/jev", "model id")
check(TeachyJev.requestBody(state: "hi", questions: [:], provider: .openRouter)["model"] as? String == "~typesafe/jev-latest", "openrouter model id")
check(TeachyJevProvider.recognized(fromKey: "sk-or-v1-abc") == .openRouter && TeachyJevProvider.recognized(fromKey: "vck_abc") == .vercelGateway, "key prefixes recognized")
check(TeachyJevProvider.recognized(fromKey: "AQ.Ab8example") == .gemini, "newer Google AI Studio keys recognized")
check(TeachyJevProvider.recognized(fromKey: "unknownformat123") == nil, "unknown prefix → no guess")
check(TeachyJevProvider.openRouter.endpoint.absoluteString == "https://openrouter.ai/api/alpha/decisions", "openrouter endpoint")
let geminiBody = TeachyJev.requestBody(state: "hi", questions: [:], provider: .gemini)
check(geminiBody["model"] as? String == "gemini-decision-1" && geminiBody["input"] as? String == "hi" && geminiBody["state"] == nil, "gemini body uses input")
check(TeachyJevProvider.recognized(fromKey: "AIzaSyExample") == .gemini, "classic gemini key recognized")
check(TeachyJevProvider.gemini.endpoint.absoluteString == "https://generativelanguage.googleapis.com/v1beta/decisions", "gemini endpoint")
let questionObjects = body["questions"] as? [String: [String: Any]]
check(questionObjects?["urgent"]?["type"] as? String == "noul", "noul question")
check((questionObjects?["team"]?["criteria"] as? [String: String])?["a"] == "A", "choice criteria")
check((questionObjects?["mood"]?["criteria"] as? [String])?.count == 2, "score levels")
check(JSONSerialization.isValidJSONObject(body), "body is JSON")

// Answer parsing (shape from TypeSafe's docs)
let sample = """
{"model":"jev-1.13.0","answers":{
 "department":{"type":"choice","choice":"technical","confidence":1.0,"probabilities":{"technical":1.0}},
 "frustration":{"type":"score","score":0.67,"confidence":0.5},
 "is_urgent":{"type":"noul","noul":0.99},
 "odd":{"type":"refusal"}},"usage":{"input_tokens":428}}
""".data(using: .utf8)!
let parsed = TeachyJevAnswers.parse(sample)
check(parsed?.choices["department"] == TeachyJevChoiceAnswer(choice: "technical", confidence: 1), "parse choice")
check(parsed?.scores["frustration"]?.score == 0.67, "parse score")
check(parsed?.nouls["is_urgent"] == 0.99, "parse noul")
check(TeachyJevAnswers.parse(Data("{}".utf8)) == nil, "no answers → nil")

// Errors in both gateway shapes
check(TeachyJevError.from(statusCode: 401, body: Data(#"{"message":"Authentication failed","error_type":"authentication_error"}"#.utf8)).message == "Authentication failed", "typesafe error shape")
check(TeachyJevError.from(statusCode: 402, body: Data(#"{"error":{"message":"Out of credits","type":"x"}}"#.utf8)).message == "Out of credits", "gateway error shape")

// Router
let candidates = [SceneSubjectCandidate(id: "eng.fan", label: "Fan", name: "Intake fan"),
                  SceneSubjectCandidate(id: "eng.noz", label: nil, name: "Nozzle"),
                  SceneSubjectCandidate(id: "eng.x", label: nil, name: nil)]
let options = SceneJevRouter.partOptions(from: candidates)
check(options.criteria.count == 2, "unnamed parts are left out")
check(options.criteria["p0"] == "Fan — Intake fan" && options.partIDForOptionID["p1"] == "eng.noz", "part options")
let many = (0..<100).map { SceneSubjectCandidate(id: "p\($0)", label: "Part \($0)") }
check(SceneJevRouter.partOptions(from: many).criteria.count == SceneJevRouter.maximumPartOptions, "part options capped")

let questions = SceneJevRouter.questions(title: "Jet engine", partOptions: options)
check(Set(questions.keys) == ["control", "about_drawing", "part"], "three questions")
check(SceneJevRouter.questions(title: nil, partOptions: .init()).keys.contains("part") == false, "no part question without parts")
check(SceneJevRouter.state(request: "get nearer", title: "Jet engine").contains("\"Jet engine\""), "state names the drawing")

func answers(control: String = "none", controlConfidence: Double = 1, about: Double = 0, part: String = "none", partConfidence: Double = 1) -> TeachyJevAnswers {
    TeachyJevAnswers(nouls: ["about_drawing": about],
                     choices: ["control": .init(choice: control, confidence: controlConfidence), "part": .init(choice: part, confidence: partConfidence)])
}
check(SceneJevRouter.decision(from: answers(control: "zoom_in"), partOptions: options) == .adjust(phrase: "zoom in"), "control → adjust")
check(SceneJevRouter.decision(from: answers(control: "zoom_in", controlConfidence: 0.5), partOptions: options) == nil, "unsure control → old path")
check(SceneJevRouter.decision(from: answers(about: 0.95, part: "p0"), partOptions: options) == .refine(parts: ["eng.fan"]), "about a part → refine with part")
check(SceneJevRouter.decision(from: answers(about: 0.95, part: "p0", partConfidence: 0.3), partOptions: options) == .refine(parts: []), "unsure part → refine without part")
check(SceneJevRouter.decision(from: answers(about: 0.4), partOptions: options) == nil, "not about drawing → old path")
for control in SceneJevRouter.controls {
    check(SceneLiveAdjustment.plan(request: control.phrase, sceneIsLive: true) != nil, "phrase \"\(control.phrase)\" is a known local control")
}
check(SceneCanvasRoute.namesExternalTarget("what's this error in my terminal"), "external words still detected")

// Optional live call
if ProcessInfo.processInfo.environment["JEV_LIVE"] == "1" {
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        defer { semaphore.signal() }
        let requests = ["could you get a bit nearer to it", "what does the fan at the front do", "draw me a rocket instead"]
        for request in requests {
            let started = Date()
            do {
                let liveAnswers = try await TeachyJev.ask(state: SceneJevRouter.state(request: request, title: "Jet engine"),
                                                          questions: SceneJevRouter.questions(title: "Jet engine", partOptions: options), timeout: 10)
                let decision = SceneJevRouter.decision(from: liveAnswers, partOptions: options)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                print("live \(ms) ms  \"\(request)\" → \(decision.map { "\($0)" } ?? "old path")  control=\(liveAnswers.choices["control"].map { "\($0.choice) \($0.confidence)" } ?? "-") about=\(liveAnswers.nouls["about_drawing"] ?? -1) part=\(liveAnswers.choices["part"].map { "\($0.choice) \($0.confidence)" } ?? "-")")
            } catch {
                failures += 1
                print("FAIL live call: \(error.localizedDescription)")
            }
        }
    }
    semaphore.wait()
}

print(failures == 0 ? "All Jev checks passed." : "\(failures) Jev check(s) failed.")
exit(failures == 0 ? 0 : 1)
