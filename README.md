# Talking Head

A macOS menu bar applet and `th` command-line tool that reads text aloud with Apple's built-in speech
engine while an animated portrait lip-syncs to it.

- **Two characters:** a man (Daniel's voice) and a woman (Samantha's voice).
- **Lip sync:** the mouth follows the audio actually playing, using 12 cartoon mouth shapes derived from
  the spelling of each word. Loudness scales how far it opens.
- **Blinking:** the eyelids blink every few seconds.
- **Eyebrows:** the eyebrows lift on the words the voice stresses (found from its pitch), on words in
  capitals, and highest at the end of a question or exclamation. They dip slightly on negative or
  doubtful words ("not", "never", "but", "sorry"…).
- **Moods:** the face can look happy, sad, surprised, concerned or angry, through its eyebrows and a
  closed mouth that turns down. With no hint, the text suggests the mood: emoji and emoticons (😊,
  😟, `:(`…) and feeling words ("congratulations", "unfortunately", "warning"…) set it for their
  sentence, and are not read out. Any caller can also say which mood to show:
  - `th --mood concerned "Build failed"`, or `mood=` in a `talkinghead://` link, for all of the text;
  - `[mood]` cues in the text, such as `[happy] Good news! [sad] But I'm leaving.`, from that point on.
    `[neutral]` ends one. Cues also work in the typing window and with the Services menu.
- **Speech bubble:** a bubble beside the head shows the text, highlights the word being spoken, and
  scrolls to follow it. Click the head to show or hide it.
- **Controls:** play/pause, type text, or pick a file to speak, from buttons below the head or from the
  menu bar.
- **From other apps:** select text (an email in Mail, a paragraph in Safari…) and choose **Services →
  Speak with Talking Head**, or open a `talkinghead://` link. Web links are read too, and a link to a
  highlight (`#:~:text=…`) reads just the highlighted passage.

![Daniel](screenshots/Daniel.png) 

https://github.com/user-attachments/assets/fa5e0d48-b055-455c-b689-b5dfc53b3d40

![Samantha](screenshots/Samantha.png)

https://github.com/user-attachments/assets/e3388cf4-3ee7-45cc-b270-c060d18efc0e

**Feature tour:** [sandipchitale.github.io/TalkingHead](https://sandipchitale.github.io/TalkingHead/) is a
page where every feature has a 🔊 **Explain** link that makes Talking Head explain it out loud. The links
need Talking Head installed. On the live page, **📖 Read this card** also shows Talking Head reading a
passage straight from the page. The page shows how to add such links to your own pages, and its
source is [`docs/index.html`](docs/index.html).

## Requirements

- macOS 26 (Tahoe) or later
- Xcode 26 or later (Swift 6)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), only if you change `project.yml`
  (`brew install xcodegen`)

## Build

```sh
xcodebuild -project TalkingHead.xcodeproj -scheme TalkingHead -configuration Debug \
  -derivedDataPath build build
```

The app is built to `build/Build/Products/Debug/TalkingHead.app`. You can also open
`TalkingHead.xcodeproj` in Xcode and run it.

Run the unit tests (mouth-shape rules and `th` argument parsing):

```sh
xcodebuild -project TalkingHead.xcodeproj -scheme TalkingHead -derivedDataPath build test
```

`project.yml` is the source of truth for the Xcode project. After changing it, run
`xcodegen generate` and commit both files.

## Install

```sh
cp -R build/Build/Products/Debug/TalkingHead.app /Applications/
ln -sf /Applications/TalkingHead.app/Contents/MacOS/th /usr/local/bin/th
open /Applications/TalkingHead.app
```

To keep it in the menu bar all the time, turn on **Launch at Login** in its menu. On macOS Tahoe,
also check that it's allowed in System Settings → Menu Bar.

## Menu bar applet

Launched from Finder or at login, Talking Head runs only in the menu bar: no Dock icon and no app menu.
Its menu offers:

- **Show Talking Head** opens the face window.
- **Type Text to Speak…** opens a window with a text box and a Speak button (⌘⏎).
- **Play/Pause** and **Stop**.
- **Voice:** Male (Daniel) or Female (Samantha).
- **Speed:** Slower, Normal or Faster (applies from the next text spoken).
- **Always on Top:** keeps the talking head (and its bubble) above other windows. Remembered between
  launches.
- **Launch at Login.**
- **MCP Server (port 8766):** serves the MCP tools over HTTP on this Mac only (see
  [MCP server](#mcp-server)). Off by default; remembered between launches.
- **MCP Server Config…:** a window with ready-made client configuration for both transports: a JSON
  tab to copy into a file such as `.mcp.json`, and a Shell tab with a `claude`, `agy` or `codex`
  command per host and transport, each with its own copy button. **Save…** writes the tab to a file.
- **Quit.**

## Face window

- The title is the voice name.
- Click the head to show or hide the speech bubble. It starts hidden, and moves and resizes with the
  window.
- The toolbar below the head has four buttons:
  - play/pause (Space). When nothing is playing, it replays the last text.
  - **Type text to speak** opens the typing window.
  - **Select a file to speak** picks a text file (plain text, RTF, HTML, …).
  - **Pin/unpin** keeps the window above other windows (same as **Always on Top** in the menu).

## Command line: `th`

```
th [-v|--voice male|female] [-m|--mood MOOD] [-t|--tty] [-f|--file path] [-u|--url URL] [--always-on-top] [text ...]
```

| Invocation | Result |
|---|---|
| `th Build finished` | Speaks the arguments as text, then quits |
| `th -f notes.txt` | Speaks the file (plain text, RTF, HTML, Word…), then quits |
| `echo "Hello" \| th`, `th < notes.txt` | Speaks piped standard input, then quits |
| `th -t` | Reads text typed at the terminal (end with Control-D), speaks it, then quits |
| `th` at a terminal | Shows the talking head only; use its toolbar to type text or pick a file |
| `th -v female …` | Uses Samantha instead of Daniel (the default, `male`) |
| `th --mood concerned "Build failed"` | Shows a mood: `neutral`, `happy`, `sad`, `surprised`, `concerned` or `angry` |
| `th --always-on-top …` | Keeps the talking head above other windows for this run |
| `th -- -5 degrees` | `--` ends the options, so text can start with `-` |
| `th -u 'https://example.com/#:~:text=This%20domain'` | Speaks the web page, or just the passage its text fragment highlights |

`th` quits when you close its windows, so the terminal gets its prompt back. If you use the typing
window or file picker, it stays open after speaking. `th --help` prints usage. Errors print a message
and exit with status 2.

## Speaking from other apps

**Services menu.** Select text in any app (for an email in Mail, click in the message and press ⌘A), then
right-click → **Services → Speak with Talking Head** (also in the app menu → Services). If the
selection is a single web link, Talking Head reads that page instead. The face window opens and
starts speaking.

The app needs to be in `/Applications` (or launched once) for macOS to list the service. If it doesn't
appear, check System Settings → Keyboard → Keyboard Shortcuts → Services → Text, where you can also give
it a keyboard shortcut.

**Links.** `talkinghead://` URLs work from Shortcuts, scripts, notes, or a browser's address bar:

| URL | Result |
|---|---|
| `talkinghead://speak?text=Hello%20there` | Speaks the text |
| `talkinghead://speak?url=<percent-encoded URL>` | Speaks the page, or its highlighted passage |
| add `&voice=female` or `&voice=male` | Picks the voice (when nothing is playing) |
| add `&mood=happy` (or another mood) | Shows that mood; an unknown mood is ignored |

For example, from Terminal: `open "talkinghead://speak?text=Build%20finished&voice=female"`.

**Text fragments.** Links made with Safari's **Copy Link to Highlight** (and Chrome's **Copy link to
highlight**) end in `#:~:text=…`. Talking Head downloads the page, extracts its text, and finds the
passage using the text-fragment rules: `start`, `start,end`, and the optional `prefix-,` and `,-suffix`
context. Matching ignores case and differences in whitespace. Pages that build their text with
JavaScript may have little or no text to read.

## MCP server

Talking Head is also an [MCP](https://modelcontextprotocol.io) server, so an AI agent can speak with
its face. There are two ways to connect, both with the same tools:

**Standard I/O (`th-mcp`).** The host starts `th-mcp`, which is inside the app. Point the host at it,
for example in `.mcp.json`:

```json
{
  "mcpServers": {
    "talkinghead": {
      "type": "stdio",
      "command": "/Applications/TalkingHead.app/Contents/MacOS/th-mcp"
    }
  }
}
```

Or, in Claude Code: `claude mcp add talkinghead -- /Applications/TalkingHead.app/Contents/MacOS/th-mcp`.
**MCP Server Config…** in the menu has these entries, and the commands for other hosts, ready to copy.
`th-mcp` speaks by running the `th` beside it, so it works whether or not the menu bar app is running.

**Streamable HTTP (menu bar app).** Turn on **MCP Server (port 8766)** in the menu, or launch the app
with `TALKINGHEAD_MCP_HTTP_PORT` set to start it on that port. It listens on `127.0.0.1` only:

```json
{
  "mcpServers": {
    "talkinghead": {
      "type": "streamable-http",
      "url": "http://localhost:8766/mcp"
    }
  }
}
```

Any local user account on the Mac can reach a localhost port, which is why this server is off until
you turn it on.

**Tools**

| Tool | Arguments | What it does |
|---|---|---|
| `speak` | `text` (required; may contain `[mood]` cues), `voice` (`male`/`female`), `mood`, `wait` (default `true`) | Speaks the text with the face, kept above other windows |
| `speak_url` | `url` (http/https, may end in `#:~:text=…`), `voice`, `mood`, `wait` | Reads the page, or just the highlighted passage, as `th -u` does |
| `stop` | none | Stops the speech, drops anything waiting, and closes the face |

With `wait`, a call returns when the speech has finished; without it, as soon as it starts. Calls take
turns: a new one waits for the previous speech to finish, so two faces never talk over each other.
Problems (a page that can't be read, a passage that isn't on the page, an unknown mood) come back as
tool errors with a plain sentence the agent can pass on.

**How agents use it**

- **Announcing when long tasks finish.** Add a line like this to `CLAUDE.md` or `AGENTS.md`:
  `When a build, test run or other task takes more than a minute, announce the result with the
  talkinghead speak tool: one or two sentences, with mood happy if it passed and concerned if it failed.`
- **Narrated walkthroughs.** Ask the agent to walk you through some code out loud: it calls `speak`
  (with `wait` left on) once per step, so each explanation finishes before it moves on to the next.
- **Reading a page in its own words.** `speak_url` with a text fragment reads a passage exactly as
  written, such as a changelog entry or a paragraph of documentation, instead of the agent's summary.

**Web apps can't use it.** claude.ai, chatgpt.com and other web apps connect to MCP servers from their
own servers, not from your Mac, so they can't reach a localhost server. They would need a public HTTPS
tunnel with authentication in front of it, which Talking Head doesn't provide.

## How it works

- **Speech:** `AVSpeechSynthesizer.write(_:toBufferCallback:)` renders the speech into audio buffers.
  The app plays them itself through `AVAudioEngine`, so it always knows which audio frame is audible.
  Pause and resume pause the player node, and the face freezes with it.
- **Timing:** while rendering, the app records a loudness envelope (RMS per 256 frames) and the frame
  at which each word starts. The synthesizer's word callbacks arrive in step with rendering.
- **Mouth shapes:** each word's spelling becomes a sequence of mouth shapes (visemes), such as
  "friend" → F, R, EE, N. The shapes share the time the word is actually voiced, vowels are held
  longer, and silence shows a resting mouth. The shape is parametric (width, lips, teeth, tongue,
  roundness), so it morphs smoothly between visemes.
- **Stress:** as the speech is rendered, the app estimates its pitch every 256 frames
  (autocorrelation over 1024 samples). A word counts as stressed when its pitch rises above the
  speaker's median by a good share of that speaker's usual rise, so a lively voice (Daniel) and a
  flatter one (Samantha) move their eyebrows about as often. The audio is rendered ahead of playback,
  so each word's pitch is known before it is heard.
- **Eyebrows:** the brows are moved without extra artwork: narrow columns of the image over each brow
  are redrawn stretched, squeezing the forehead and stretching the skin above the eye (or the
  reverse). A tilt moves the inner ends more than the outer ones.
- **Moods:** `Script` takes the cues and mood emoji out of the text and works out the mood at each
  point: a `[mood]` cue, else the mood given for the whole text, else its sentence's guess. The face
  eases from one mood to the next.
- **Portraits:** each portrait is an image plus two textures generated from it: a mouthless skin patch
  that fades in when the mouth opens, and skin for the eyelids. The portrait's own smile shows when
  the mouth is closed, unless a mood turns the mouth down.
- **`th`:** `th` is a shell script inside the app bundle (`Contents/MacOS/th`). It runs the app
  executable with the arguments packed into one `-THArguments` value, because AppKit would treat
  bare arguments such as file names as documents to open.

## Source layout

| Path | Purpose |
|---|---|
| `TalkingHead/TalkingHeadApp.swift` | App entry: menu bar item, windows, login item |
| `TalkingHead/LaunchOptions.swift` | Command-line parsing (`th` arguments) |
| `TalkingHead/SpeechEngine.swift` | Observable speech state, mouth shape, current word |
| `TalkingHead/AudioPipeline.swift` | Synthesis to buffers, playback, loudness, pitch and word timeline |
| `TalkingHead/Prosody.swift` | Pitch tracking, and how much the voice stresses each word |
| `TalkingHead/Mood.swift` | Moods, how the face shows them, and `Script`: cues, emoji and guessed moods |
| `TalkingHead/Expression.swift` | When the eyebrows move, and where each portrait's brows are |
| `TalkingHead/Viseme.swift` | Spelling → mouth shapes, parametric `MouthShape` |
| `TalkingHead/FaceView.swift` | Portrait rendering: animated mouth and eyelids; `Portrait` data |
| `TalkingHead/FaceWindow.swift` | Face window and its toolbar |
| `TalkingHead/SpeechBubble.swift` | Speech bubble child window and shape |
| `TalkingHead/SpokenTextView.swift` | Word-wrapped text with the moving highlight |
| `TalkingHead/InputWindow.swift` | Typing window |
| `TalkingHead/TextFile.swift` | Reads the text of a file (used by `th` and the file button) |
| `TalkingHead/ExternalRequests.swift` | The Services menu item and `talkinghead://` URLs |
| `TalkingHead/WebPage.swift` | Downloads a page's text, or its highlighted passage |
| `TalkingHead/TextFragment.swift` | Parses and finds `#:~:text=` text fragments |
| `MCPTools/TalkingHeadTools.swift` | The MCP tools' definitions and handlers, shared by both transports |
| `MCPTools/Speaking.swift` | `Speaker`, the interface the tools speak through, and `SpeechQueue`, which makes calls take turns |
| `MCPTools/THProcessSpeaker.swift` | Speaks by running `th` (for `th-mcp`) |
| `CLI/th-mcp/main.swift` | `th-mcp`, the stdio MCP server |
| `TalkingHead/AppSpeaker.swift` | Speaks with the menu bar app's own face (for the HTTP server) |
| `TalkingHead/MCPHTTPServer.swift` | The Streamable HTTP MCP server, served by the menu bar app |
| `TalkingHead/MCPServerController.swift` | Turns the HTTP server on and off (menu item, `TALKINGHEAD_MCP_HTTP_PORT`) |
| `TalkingHead/MCPConfigWindow.swift` | The MCP Server Config… window: sample client configuration to copy or save |
| `TalkingHead/Info.plist` | Service, URL scheme and network settings (generated from `project.yml`) |
| `TalkingHeadTests/` | Unit tests (Swift Testing) |
| `TalkingHead/Assets.xcassets` | Portraits and their generated mouth and eyelid textures |
| `CLI/th` | The `th` script, copied into the app bundle and signed at build time |
| `MCPTools/` | Code compiled into both the app and `th-mcp` |
| `project.yml` | XcodeGen project definition |

## Adding a portrait

1. Add the image to `Assets.xcassets` as `<Name>`.
2. Generate `<Name>MouthPatch` (skin with the lips painted out, feathered edges) and `<Name>Eyelids`
   (skin across the eyes) from the image.
3. Add a `Portrait` entry in `FaceView.swift`. It needs the voice name, the image size, the patch and
   eyelid rectangles, the eye rectangles, a region for each eyebrow (its left and right edges, the
   forehead above it, the middle of the brow, and the skin just above the eye) with how far it lifts,
   the mouth centre and scale, and a lip colour, all in image pixels. Include it in `Portrait.all`.

## Notes

- The app sandbox is off so `th` can read any file you pass.
- The portraits are 360×360 pixels, so they look soft when enlarged on Retina displays.
  Higher-resolution originals would look sharper.
