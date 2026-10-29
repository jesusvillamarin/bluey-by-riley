# Subscription voice — design

Date: 2026-10-29. Agreed with the founder in conversation.

## Problem

Every word said to Bluey goes through the OpenAI Realtime API, billed per use. The founder already pays for a Claude
subscription and wants daily voice use to run on it, Panita-style, and wants Bluey to speak out loud.

## Proposal

A new **voice mode: Subscription** (Mac menu, the Mac is the source of truth). OpenAI Realtime stays as **Fast** mode,
unchanged.

1. **Hold to talk, like Panita Cloud.** Holding the phone opens an ElevenLabs **Scribe v2 Realtime** socket from the
   phone with a single-use token the Mac minted. Audio streams only while held. Releasing sends the commit. The final
   transcript goes to the Mac.
2. **Claude answers on the Mac.** A headless `claude -p` (model `haiku`, the user's subscription) is started when Bluey
   wakes and kept for the whole awake session, so it remembers the conversation. Bluey's existing tools (look, point,
   research, focus, Codex, computer control) are served to it by a local MCP server inside the Mac app.
3. **Bubbles as today.** The reply streams into the Mac bubble.
4. **Bluey speaks** (milestone 2). The Mac turns each finished sentence into speech with ElevenLabs Flash v2.5 and
   relays the audio to the phone, which plays it. Holding again stops him mid-sentence.
5. **Meeting notes** (milestone 3) transcribe with Scribe v2 **batch** instead of OpenAI, when an ElevenLabs key exists.

## Decisions and why

- **Scribe Realtime for conversation, batch for meeting notes.** Batch saves under $1/month at ~10 min/day of speech
  and adds 0.5–1.5 s per turn. Cost is controlled by streaming only while held.
- **One Claude process per awake session**, not one per dictation (Panita's model). Verified 2026-10-29: two turns in
  one `--input-format stream-json` process remember each other; first text delta 0.41–0.65 s on a warm process.
- **Tools over local HTTP MCP.** Verified: `--mcp-config` with an `http` server plus `--allowedTools mcp__bluey`
  works in `-p` mode; without `--allowedTools` the call is denied. A screenshot-sized JPEG plus a 600-word target
  list (82 KB result) reached Haiku intact: it read the text and described the shapes. First text after one tool
  round trip ≈ 1.6–2.7 s, so look → point → answer is ~3–4 s.
- **Barge-in uses the stream-json interrupt.** Verified: `{"type":"control_request","request_id":…,"request":{"subtype":"interrupt"}}`
  ends the turn in ~20 ms with a `result` of subtype `error_during_execution`, and the process keeps working.
- **TTS on the Mac, HTTP stream, `pcm_24000`.** The ElevenLabs key stays on the Mac and the HTTP endpoint's PCM
  format is documented (the websocket's is not). Replies are one short line, so one request per sentence is enough.
- **No silent fallback to Fast mode** when `claude` is missing or signed out: show the fix instead, so the founder is
  never billed by surprise.
- **Voice ID is a setting.** ElevenLabs retires its old default voices on 2026-12-31.
- **OpenAI key stays required** for focus screen checks and `web_research`. This removes the Realtime bill, not the key.

## Cost (ElevenLabs official API prices, 2026-10-18)

Scribe v2 Realtime $0.39/h (+$0.08/h with keyterms), Scribe v2 batch $0.22/h, Flash v2.5 TTS $0.04 per 1K characters.

## Language (founder decision, 2026-10-29)

Both. Bluey answers in the language the user just spoke: English as the British persona, Spanish as natural Latin
American Spanish (Mexican/Colombian). Scribe auto-detects; the TTS voice must be verified for both `en` and `es`.

## Execution (founder decision)

All three milestones, subagent-driven.
