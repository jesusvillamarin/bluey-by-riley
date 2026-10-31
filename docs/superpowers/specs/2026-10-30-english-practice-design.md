# English practice breaks — design

Date: 2026-10-30. Agreed with the founder in conversation. Items marked **(builder's call)** were chosen by Claude, not
the founder, and can be overridden.

## Problem

The founder works from home all day and forgets to make time to learn English. They want a separate Mac app, built on
Bluey, that interrupts them like an active-break reminder and runs short Duolingo-style lessons on the computer.

## What success looks like

- Several short practice sessions happen every working day without the founder having to remember them.
- The app never interrupts a meeting.
- Lessons start from absolute basics and get harder as the AI learns the founder's real level.
- Each lesson builds on what went wrong in the previous ones.

## Goals

1. **Reminder from the notch.** At configured times, a pill drops down from the MacBook notch: "Time to practice
   English", with a 60-second countdown and the buttons **Start now**, **In 15 min** and **Not today**.
2. **Busy detection.** When the reminder is due and the microphone or camera is in use, no pill appears. The app
   shows a system notification instead: "Ups, veo que estás ocupado. Te molestaré después." and postpones.
3. **No answer means postpone.** If the countdown reaches zero without a tap, the reminder is postponed, not started
   (founder decision).
4. **Short Duolingo-style lessons** in their own window, practising all four skills: reading, writing, listening and
   speaking (founder decision: not speaking only).
5. **Start from zero; the AI finds the level.** No placement test up front. The first lessons are absolute-beginner,
   and difficulty adapts from results.
6. **Memory in JSON.** Every session is stored in a JSON file that keeps growing. After each lesson, an agent writes
   a summary with points to improve, stored in memory and used by the next lesson.
7. **Configurable schedule.** How many reminders per day, between which hours, and on which days.

## Non-goals (for now)

- iPhone app, phone pairing, Bluey's focus or screen monitoring.
- Accounts, cloud sync, leagues, hearts or gems. A day streak is the only game element.
- Exact pronunciation scoring (phoneme-level). Speaking is checked by comparing what was heard with the target phrase.

## Anti-goals (a failure even if it works)

- A reminder or sound during a call (the microphone or camera is in use).
- A lesson that starts on its own while nobody is at the computer.
- Surprise bills: the app never switches on its own to a different provider or key than the one the user chose.
- Lessons that feel like a chat with an AI instead of quick exercises with instant right/wrong feedback.

## How it gets made

### App and code (builder's call)

- The app is named **Bluey Teach** (founder decision).
- Same repository, new SwiftPM executable target `TeachMac`. It ships as its own menu bar app, `Bluey Teach.app`, with
  bundle ID `co.visionairy.googly.teach` and its own build script `scripts/build-teach.sh`, modelled on
  `scripts/build-mac.sh`.
- `ClaudeStream`, `ElevenLabs`, `Keychain` and the font loading live in the `GooglyMac` *executable* target, which
  SwiftPM can't depend on. Move the reusable parts into a new library target, `GooglyMacKit`, which both apps depend
  on. Bluey's behaviour must not change: all existing tests must pass after the move. `Palette` already sits in
  `GooglyShared`. `Shared/Fonts` is excluded from that target, and `Fonts.swift` loads fonts from `Bundle.main`, so
  the new build script copies the `.ttf` files into the app bundle, as `build-mac.sh` does.
- Menu bar icon with: **Practice now**, **Schedule…**, **Progress**, **Keys & agent…**, **Pause reminders today**,
  **Quit**.

### Keys and agent (founder decision)

- The user enters their own keys in Bluey Teach. They're stored in the app's own store,
  `~/Library/Application Support/BlueyTeach/keys.json`, with private file permissions, the same way Bluey stores its
  keys. Bluey's keys aren't shared or read (builder's call).
- **ElevenLabs key: required.** Without it, reminders don't fire. The first launch opens **Keys & agent…**.
- **Agent:** the user picks one of three providers. This agent generates lessons, judges alternative answers and
  writes summaries.
  - **Claude subscription:** the `claude` CLI with the user's Claude Code sign-in, as Bluey's Subscription voice does.
  - **Anthropic API key:** default model `claude-haiku-5-5` (builder's call).
  - **OpenAI API key:** a current small OpenAI model, chosen by the builder.
- Build one agent interface with three implementations. All return the same lesson, grading and summary JSON.
- **No switching between providers on its own.** If the chosen agent fails (missing key, signed out, out of credit),
  the user sees exactly what's wrong and how to fix it. Nothing silently moves to another provider or key.
- A **Test** button next to each key checks it with a tiny request. Launch at
  login via `SMAppService`, on by default.
- macOS 14+, matching `Package.swift`.

### The notch pill

- A borderless, non-activating `NSPanel` positioned at the notch. Find the notch with `NSScreen.auxiliaryTopLeftArea`
  and `auxiliaryTopRightArea`. When there is no notch (lid closed, external monitor), place it at the top center of
  the main screen.
- Collection behaviour `.canJoinAllSpaces` and `.fullScreenAuxiliary`, so it also appears over full-screen apps.
- Shape and motion: a black pill that grows out of the notch, about 360×110 pt when open, with Bluey's face on the
  left saying the reminder. The design follows Bluey's palette and Fredoka font (builder's call).
- **Bluey the character teaches** (founder decision). His face appears in the pill and in the lesson window, where
  he reacts to right and wrong answers. The face is drawn today in the iOS app (`iOS/Sources/FaceView.swift`,
  `BlobShape.swift`). Port it to a shared SwiftUI view the Mac can use, without changing how it looks on the phone.
- It must not steal keyboard focus from whatever the founder is typing in.
- Countdown: 60 seconds, shown as a shrinking ring or bar. **Start now** opens the lesson. **In 15 min** postpones.
  **Not today** skips the rest of today's reminders.

### Scheduling (builder's call where not stated)

- Settings: reminders per day (default 3), start and end hours (default 9:00–18:00), and weekdays (default
  Monday–Friday). Reminders are spread evenly across the window, for example 3 between 9 and 18 fall at 10:30, 13:30
  and 16:30.
- **Postpone rules:**
  - "Busy" postpones 30 minutes.
  - "No answer" and **In 15 min** postpone 15 minutes.
  - After 3 postpones, that slot is dropped. A postponed reminder never fires outside the configured hours, and never
    stacks with the next slot: if it would land within 30 minutes of the next slot, it is dropped.
- **Sleep, lock and wake:** if one or more slots were missed while the Mac slept or was locked, show **one** reminder
  (after the busy check) on unlock, never a pile-up. Never show a reminder while the screen is locked.
- **Practice now** from the menu skips scheduling entirely. A lesson finished this way counts toward the day, so the
  next scheduled reminder that day is skipped if it falls within 60 minutes.

### Busy detection

- At reminder time only, check:
  - **Microphone:** CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere` on every input device.
  - **Camera:** the CoreMediaIO equivalent on every video device.
- Never check during the app's own lesson, because the speaking exercise opens the microphone itself.
- **Spike first:** confirm detection with a muted Zoom, Google Meet and FaceTime call, and with AirPods as the input.
  If one case can't be detected reliably, report it back before building around it.
- Microphone and camera are the only signals (founder decision). There's no calendar or meeting-app check. The
  founder accepts the small risk that the pill appears during a screen share with both turned off.
- The "busy" message is a system notification (`UNUserNotificationCenter`), not the pill. Notifications respect Focus
  and Do Not Disturb, and macOS hides them during screen sharing. The pill is never shown when busy.

### Lessons

- **Length:** about 5 minutes, 8–10 exercises, mixing all four skills in each lesson (builder's call).
- **Window:** a centered window of about 720×560 with a progress bar at the top, one exercise card and a **Check**
  button. Pressing Return works like **Check**. After each answer, a green or red strip shows the correct answer and a
  one-line explanation in Spanish, with a short sound. Escape or closing the window ends the lesson early, and a
  partial lesson still gets a summary.
- **Exercise types:**
  - **Reading:** pick the meaning of a word or sentence, or read a short text and answer a question.
  - **Writing:** translate a Spanish sentence to English by typing it, or build a sentence by tapping word tiles.
  - **Listening:** hear a sentence and pick or type what was said. A slow-replay button is available.
  - **Speaking:** read a sentence aloud. The app transcribes it and compares it with the target. It accepts small
    differences and points out the words that didn't match.
- **Grading:**
  - Multiple choice and word tiles are checked locally.
  - Typed answers: a local check first, with case, punctuation and common contractions normalized. If that fails,
    the agent judges whether the answer is a valid alternative, so correct alternatives aren't marked wrong.
  - Speaking: the transcript is compared word by word, with tolerance for small differences.
- **Generation:** the chosen agent returns the whole lesson as one JSON object with a fixed schema.
  - With the Claude subscription, it reuses the env-var scrubbing in `ClaudeVoiceSession.environment(base:binary:)`.
  - It also needs a one-shot variant of `ClaudeStream.arguments`, because that function is built for stream-json
    input and requires an MCP config. Generation starts **when
  the pill appears**, so the lesson is ready by the time the founder taps Start. If generation fails, show a short
  error with a retry button. Nothing falls back to another provider.
- **Instructions:** written in Spanish while the founder's level is low, moving to English as the level rises.
  Exercise content is English.
- **Voice and speech recognition: ElevenLabs for both, always** (founder decision). Both use the ElevenLabs key
  entered in Bluey Teach. No macOS voice or Apple speech recognition is used anywhere in the app.
  - **Listening:** ElevenLabs TTS reusing `ElevenLabs.swift`, with an English voice. Fetch the audio for the
    lesson's listening exercises while the pill shows, right after the lesson is generated. Slow replay asks
    ElevenLabs for a slower speed (builder's call).
  - **Speaking:** the founder holds a mic button while speaking. On release, the clip goes to Scribe v2 *batch*,
    reusing `MeetingNotes.scribeBatch`'s request (builder's call: batch is cheaper than Realtime and the clips are
    a few seconds long).
  - **No fallback voice** (founder decision). If ElevenLabs fails while the lesson is being prepared, the pill says
    so and offers **Retry**, or **Keys & agent…** when the key is the problem. If it fails in the middle of an
    exercise, that exercise shows the error with **Retry**. Nothing switches to a macOS voice.

### Memory

- File: `~/Library/Application Support/BlueyTeach/memory.json`. Writes are atomic (write a temp file, then rename),
  and permissions are private.
- Shape:
  - `profile`: estimated CEFR level (starts at `pre-A1`), strengths, weak points, and a vocabulary/grammar item list.
    Each item records when it was last seen, its result, and when it is next due for review (simple spaced repetition:
    1, 3, 7 and 14 days).
  - `sessions[]`: an append-only list. Each entry records the date, duration, whether it was finished, every exercise
    with the founder's answer and the result, and the summary.
  - `schedule` settings and `streak` live in the app's preferences, not in memory.
- **Summary agent:** after each lesson, a second call to the chosen agent receives that session's results and the current
  profile. It returns:
  - a summary in Spanish with 2–4 points to improve
  - the updated profile, including level changes and review dates

  Both are saved. The summary is shown on the lesson's final screen.
- **What the next lesson receives:** the profile, the last 5 summaries and the review items now due. It never gets
  the whole file, which grows forever.

### Progress

- The **Progress** window shows the streak in days, practice minutes this week, the estimated level and the latest
  summary.

## Cost

- Lesson generation, grading of alternative answers and summaries use the agent the user chose. On the Claude
  subscription there's no extra bill. With an Anthropic or OpenAI key, each lesson is a few small requests billed to
  that key.
- Listening and speaking use ElevenLabs, paid per use (founder decision). Rough cost at 3 lessons a day: about 1,500
  TTS characters (Flash v2.5 at $0.04/1K) and 2 minutes of Scribe batch ($0.22/h), which is about $0.07 a day. The
  real model and price come from `ElevenLabs.swift` at build time.

## Left to the builder

- Exact JSON schemas for lessons and memory, prompt wording, the pill animation, sounds, and window styling within
  Bluey's palette.
- Test strategy. Scheduling, postpone rules, answer normalization, spaced repetition and memory read/write must be
  unit-tested; they are pure logic.
