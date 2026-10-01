import Foundation

/// Copyable starting points paired with stable IDs from the community catalog.
struct MCPWorkflow: Identifiable {
    let id: String
    let icon: String
    let title: String
    let scope: String
    let prompt: String
    let skillID: String

    static let examples: [MCPWorkflow] = [
        .init(id: "transcribe", icon: "text.bubble", title: "Transcribe and preview",
              scope: "No project needed",
              prompt: "Use VoxStudio to transcribe my audio file, identify speakers, and preview the first 15 seconds with timestamped text. Ask me for the file path if needed.",
              skillID: "mcp-transcription"),
        .init(id: "translate", icon: "captions.bubble", title: "Create multilingual subtitles",
              scope: "No project needed",
              prompt: "Use VoxStudio to transcribe my audio, segment the subtitles, and add English and Chinese translation tracks. Preview both languages, then select the Chinese subtitles.",
              skillID: "mcp-transcription"),
        .init(id: "voice", icon: "waveform.badge.plus", title: "Build a reference voice",
              scope: "No project needed",
              prompt: "Add my short recording to the VoxStudio voice library. Help me verify its exact transcript and reference details, then preview the saved voice.",
              skillID: "mcp-voice-reference"),
        .init(id: "dub", icon: "waveform.and.person.filled", title: "Dub and listen",
              scope: "No project needed",
              prompt: "Show my VoxStudio reference voices. Use the voice I choose to say: Welcome to our workshop. Today we will practice clear communication. Generate the audio and play a preview.",
              skillID: "mcp-dubbing"),
        .init(id: "ask", icon: "bubble.left.and.text.bubble.right", title: "Ask your knowledge base",
              scope: "No project needed",
              prompt: "Use VoxStudio to summarize decisions and next steps from my latest meeting. Cite the source and timestamp for each decision; mark missing owners or deadlines as unspecified.",
              skillID: "knowledge-qa"),
        .init(id: "search", icon: "text.magnifyingglass", title: "Find the exact moment",
              scope: "No project needed",
              prompt: "Search my VoxStudio transcripts for customer feedback. Return the five most relevant passages with session titles, speakers, and timestamps.",
              skillID: "knowledge-search"),
        .init(id: "compare", icon: "rectangle.2.swap", title: "Connect ideas across sessions",
              scope: "No project needed",
              prompt: "Use VoxStudio to find sessions discussing launch plans. Compare their decisions, highlight what changed, and cite evidence from each session.",
              skillID: "knowledge-qa"),
        .init(id: "captions", icon: "captions.bubble", title: "Style your next video",
              scope: "Open a video project",
              prompt: "Inspect my active VoxStudio project and suggest a caption preset that fits the footage. Show me the proposed style before applying it to the timeline.",
              skillID: "caption-templates"),
    ]
}
