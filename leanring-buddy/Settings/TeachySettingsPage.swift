import Foundation

enum TeachySettingsPage: String, CaseIterable, Identifiable {
    case account = "Account", general = "General", voice = "Voice", microphone = "Microphone"
    case dictation = "Dictation", shortcuts = "Shortcuts", cursor = "Cursor", touchAndGaze = "Touch & Eyes"
    case camera = "Camera input"
    case projects = "Projects"
    case integrations = "Integrations", skills = "Skills", agents = "Agents", routines = "Routines", drawings = "Drawings", memory = "Memory"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .account: return "person.crop.circle.fill"
        case .general: return "gearshape.fill"
        case .voice: return "waveform"
        case .microphone: return "mic"
        case .dictation: return "character.cursor.ibeam"
        case .shortcuts: return "command"
        case .cursor: return "cursorarrow"
        case .touchAndGaze: return "eye"
        case .camera: return "camera.viewfinder"
        case .projects: return "folder"
        case .integrations: return "puzzlepiece.extension.fill"
        case .skills: return "book.closed"
        case .agents: return "circle.hexagongrid.fill"
        case .routines: return "repeat"
        case .drawings: return "scribble.variable"
        case .memory: return "brain"
        }
    }
    var subtitle: String {
        switch self {
        case .account: return "Your balance, payment, and account."
        case .general: return "How Teachy behaves on your Mac."
        case .voice: return "How Teachy speaks. Changes apply from the next spoken reply."
        case .microphone: return "Which microphone Teachy listens through."
        case .dictation: return "Languages and the words Teachy should spell right."
        case .shortcuts: return "The keys that summon Teachy."
        case .cursor: return "The Teachy cursor that lives on your screen."
        case .touchAndGaze: return "Tap the screen to talk, and let Teachy see where you're looking."
        case .camera: return "Set up hands and eyes with your Mac camera."
        case .projects: return "Choose where Teachy keeps new agent jobs and drawings."
        case .integrations: return "Connect the tools you use to Teachy."
        case .skills: return "Teach Teachy your apps, or get skills other people made."
        case .agents: return "Give your agents a name and a role."
        case .routines: return "Tasks that run on your schedule."
        case .drawings: return "Pictures and explanations to revisit."
        case .memory: return "What Teachy remembers about you."
        }
    }
}

