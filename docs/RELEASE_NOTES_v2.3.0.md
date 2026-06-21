# Gugu v2.3.0 - public launch release

Public launch release of Gugu, an AI desktop lifeform for macOS.

## Highlights

- Programmatic SpriteKit desktop bird
- Local work-rhythm sensing without recording input content
- Memory, growth stages, daily dream distillation
- OpenAI Chat Completions compatible model transport
- Optional camera, wake word, and local TTS
- Proposal-gated local tools and auditable local state
- MIT-licensed source release

## Demo

- MP4: `dist/gugu-demo-v2.3.0.mp4`
- GIF: `dist/gugu-demo-v2.3.0.gif`
- Regenerate with `./scripts/make-demo-video.sh`

## Current limitations

- Source-first release; no notarized downloadable app yet
- macOS 14+ only
- Requires your own OpenAI-compatible model endpoint and API key
- Optional object recognition requires a local Core ML model
- `web_search` has permission, queue, and audit plumbing, but currently records requests rather than performing live web retrieval

## Verification

Before tagging:

```bash
swift build
GUGU_HOME=/private/tmp/gugu-launch-selftest ./.build/debug/gugu --selftest-offline
./scripts/make-demo-video.sh
```

## Suggested tag

```bash
git tag v2.3.0
git push origin v2.3.0
```
