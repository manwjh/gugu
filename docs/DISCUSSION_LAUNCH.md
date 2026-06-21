Gugu v2.3.0 is the first public source-first release of Gugu, an AI desktop lifeform for macOS.

Gugu is not a chatbot with a skin. It is a small SpriteKit bird that lives on your desktop, reacts to touch and dragging, senses your work rhythm, remembers shared history, grows over time, and speaks only when the timing feels right.

Preview:

![Gugu preview](https://github.com/manwjh/gugu/releases/download/v2.3.0/gugu-preview-v2.3.0.png)

What is in this release:

- Programmatic desktop bird with movement, blinking, grooming, idle behavior, and window-perching
- Local work-rhythm sensing without recording input content
- Memory, growth stages, and daily dream distillation
- OpenAI Chat Completions compatible model transport
- Optional camera, wake word, and local TTS
- Proposal-gated local tools and auditable local state

Privacy boundaries:

- Keyboard and mouse sensing counts rhythm only, not typed content
- Camera and microphone are off by default
- Raw audio/video is not uploaded or saved
- Local memory, audit logs, proposals, and config are inspectable files under the local Gugu data directory

Current limitations:

- This is source-first: no notarized downloadable app yet
- macOS 14+ and Swift 5.9+ are required
- You need your own OpenAI-compatible model endpoint and API key
- Optional object recognition requires a local Core ML model

Start here:

- GitHub: https://github.com/manwjh/gugu
- Release: https://github.com/manwjh/gugu/releases/tag/v2.3.0
- FAQ: https://github.com/manwjh/gugu/blob/main/docs/FAQ.md
- Feedback issue: https://github.com/manwjh/gugu/issues/1

The feedback I want most:

1. Can you build and run it successfully?
2. Are the privacy boundaries clear enough?
3. Would you let a small desktop lifeform like this stay on your Mac?
