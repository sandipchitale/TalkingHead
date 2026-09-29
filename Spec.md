# Talking Head

## Original request

Develop a simple GUI in SwiftUI which UI allows user to type text in a text view. Then use Apple's
native engine to speak that text. Allow user to pause and resume speech. Also generate s simple
animated face which will sync with the speech. This should run on MacOS.

## Current specification

### Platform and voices
- macOS 26 (Tahoe) or later, SwiftUI, Swift 6. Speech uses `AVSpeechSynthesizer`.
- Two faces: the man speaks with **Daniel**, the woman with **Samantha**, each at its best installed
  quality ("Daniel (Enhanced)", "Samantha (Premium)"… count as the same voice).
- Each face can instead use any installed English voice macOS labels with its gender (unlabelled and
  novelty voices aren't offered), chosen in Man's Voice / Woman's Voice and saved per face
  (`faceVoice.<Daniel|Samantha>`, the voice's identifier). A missing or unsuitable choice falls back to
  the face's own voice. The choice applies wherever the face speaks (app, `th`, links, MCP, VoiceChat),
  and the menu and typing window name the voice speaking.

### The face
- Lip sync: the mouth follows the audio being heard, using mouth shapes for A/E/I, O, U, EE, F/V, L, R,
  TH, CH/J/SH, B/M/P, Q/W, other consonants and rest, taken from each word's spelling and timed to when
  the word is voiced. A closed mouth shows the portrait's own smile unless a mood turns it down.
- The eyes blink every few seconds.
- The eyebrows lift briefly on stressed words: a word whose pitch rises well above the speaker's
  median, relative to how far that voice usually rises; the more it rises, the higher. Without a pitch,
  stress is guessed: the first word of each sentence or clause, and words of 7+ letters. Capitalised
  words and the last word before "?" or "!" lift them too. Lifts come at most every 0.8 s, except that
  the last word before "?" or "!" always lifts them, half as high again.
- They dip (half as far) on negative or doubtful words ("no", "not", "never", "…n't", "but",
  "however", "sorry", "problem", "wrong"…). A dip wins over a lift, except the "?"/"!" lift.

### Moods
- `neutral`, `happy` (brows a little up), `sad` (inner brows up, mouth down), `surprised` (brows well
  up), `concerned` (brows down, inner ends up, mouth down), `angry` (brows down, inner ends down, mouth
  down). Stress movements add to the mood's brows.
- A caller sets it with `th --mood`, `mood=` in a link or MCP, for all the text, or with `[mood]` cues
  (any case) from where they stand to the next cue; `[neutral]` ends one. Cues aren't spoken; brackets
  that don't name a mood are left alone.
- Otherwise each sentence gets the mood its emoji, emoticons (😊 happy, 😢 `:(` sad, 😮 surprised,
  😟 🤔 ⚠️ concerned, 😠 angry…) and feeling words ("great", "sorry", "warning", "failed"…) suggest.
  Emoji count double, the first mood wins a tie, and an emoji belongs to the sentence it follows. Mood
  emoji and emoticons aren't spoken.
- Cues win over a whole-text mood, which wins over guesses. The mood holds through a pause and fades to
  neutral when the speech ends.

### Presence: listening and thinking
- Between speeches the face shows the presence a client holds on the spooler socket (see Speech
  spooler):
  - **Listening:** brows slightly up. A `nod` pulse dips the head 3–4 px and back over about 350 ms.
  - **Thinking:** one brow up, the other slightly down; the upper lids lowered (the portrait's own lids
    and lashes redrawn lower); the mouth closed; slower blinks (every 5–9 s). If the speech bubble is
    showing, it shows an animated "·", "··", "···"; it never opens the bubble.
- The head doesn't tilt, sway or breathe; blinking is life enough. Only a nod moves it.
- Poses ease in over about 250 ms, and ease back to neutral while speaking.
- The face is redrawn only when something in it changes, so holding presence costs a few percent of
  one core at most.

### Windows
- **Face window:** resizable and draggable, showing only the head. Titled "Man" or "Woman", subtitled
  with the voice speaking (none when macOS's default voice speaks). Toolbar below the head:
  **Play/Pause** (Space; replays the last text when idle), **Type text to speak**, **Select a file to
  speak**, and **Pin/Unpin** (keeps the window and bubble above others).
- **Speech bubble:** a rounded bubble beside the face window, its tail pointing at the head. It shows
  the text with the current word highlighted and scrolled into view, follows the window, and starts
  hidden; clicking the head shows or hides it.
- **Typing window:** a text box and **Speak** (⌘⏎).

### Menu bar applet
- No Dock icon or app menu. Launched from Finder or at login it shows only the menu bar item, and keeps
  running when its windows close.
- The menu starts with a heading, "Talking Head <version>", then: Show Talking Head, Type Text to
  Speak…, Play/Pause, Stop, Voice (Man/Woman, each shown with its voice, e.g. "Woman (Ava)"), Man's
  Voice, Woman's Voice (the face's own, or installed voices of its gender, best quality first), Speed
  (Slower/Normal/Faster), Always on Top (same as the pin, remembered), Launch at Login, MCP Server
  (port N), MCP Server Config…, and Quit.

### Command line: `th`
- Packaged as `TalkingHead.app/Contents/MacOS/th`. Usage:
  `th [-v|--voice male|female] [-m|--mood MOOD] [-t|--tty] [-f|--file path] [-u|--url URL] [--always-on-top] [text ...]`
  - `-v`: `male` (Daniel, the default) or `female` (Samantha). `-m`: a mood.
  - `-f`: a file (`-` is standard input). `-u`: an http(s) page, or just its text-fragment passage.
    `-t`: text typed at the terminal (end with Control-D). `--always-on-top`: for this run only.
  - `text ...`: the remaining arguments, joined with spaces; `--` ends the options.
- Only one text source may be given. With none, piped or redirected standard input is read; at a
  terminal, `th` just shows the face.
- With text, `th` shows the face, speaks and quits (staying open if its typing window or file picker
  was used). It quits when its windows close and never adds a menu bar item.
- When the menu bar app is running, `th` with text hands it to the app's spooler instead (always naming
  its voice: male unless `-v female`), waits for the speech to end, and exits as it would have: 0 when
  finished or stopped, 2 with its `th: …` message on failure. SIGTERM or SIGINT cancels only its own
  request. `--report-start` (for `th-mcp`, not in the usage) prints `started` when the voice starts.
- `-h` prints usage. Invalid options, voices or moods, unreadable files or pages, and text fragments not
  found print an error and exit 2.

### Speaking from other apps
- **Services menu:** "Speak with Talking Head" speaks the selected text; a single selected web link
  speaks that page (or its passage). The face window opens.
- **URL scheme:** `talkinghead://speak?text=…` or `?url=…`, with optional `voice=male|female` and
  `mood=…` (an unknown mood is ignored). It launches Talking Head if needed.
- **Text fragments:** `#:~:text=[prefix-,]start[,end][,-suffix]` speaks only that passage, matched
  ignoring case and whitespace; without one, the whole page is spoken. A fragment not found is an error.

### MCP server
- The same tools (written once, in `MCPTools/`, with the MCP Swift SDK, exactly 0.12.1) are served
  over two transports:
  - **stdio:** `th-mcp`, packaged next to `th` and signed before the app.
  - **Streamable HTTP:** in the menu bar applet at `http://127.0.0.1:<port>/mcp` (default 8766), bound
    to `127.0.0.1` only. Off by default; the "MCP Server (port N)" item turns it on and is remembered;
    `TALKINGHEAD_MCP_HTTP_PORT` turns it on at launch. A port that can't be bound shows an alert. An
    instance started by `th` never serves it. Sessions start with `initialize` (`Mcp-Session-Id`), end
    with `DELETE`, and expire after an hour idle.
- **Tools** (annotated not read-only, not destructive, not idempotent):
  - `speak`: `text` (required; may contain `[mood]` cues), `voice`, `mood`, `wait` (default true).
  - `speak_url`: `url` (http(s), may end in `#:~:text=…`), `voice`, `mood`, `wait`; reads it as `th -u`.
  - `stop`: stops the speech, drops speech waiting its turn, and closes the face.
- Speech shows the face above other windows. `wait` true returns when the speech finishes, false when
  it starts. No call blocks longer than `TALKINGHEAD_MCP_WAIT_MS` (default 45000); then it returns a
  normal result, "Still speaking. It will finish on its own; don't call again to repeat it." (or
  "Waiting for earlier speech to finish; …"), and the speech carries on. The `wait` description says so.
- With a `progressToken`, a waiting call sends `notifications/progress` every 5 s ("Waiting for earlier
  speech…" or "Speaking…"), on both transports.
- Calls take turns: while the menu bar app runs, every caller shares its one queue; otherwise each
  `th-mcp` has its own. `stop` means silence for everyone and closes the face. Speech stopped elsewhere
  also drops a caller's queued requests.
- Omitting `voice` means the menu's face (without the app, `th-mcp` reads its saved choice; male if
  none).
- Errors are tool results with `isError` and a plain sentence.
- **`th-mcp`** writes only JSON-RPC to standard output. Each call goes to the spooler (with
  `alwaysOnTop`) when its socket answers, else to the `th` beside it (following symlinks) with
  `--always-on-top`, `-v`, `-m`, `-u` and the text on standard input; `th`'s exit ends the speech, and
  status 2 with its `th: …` line is the error. `stop` sends the spooler `stop` and ends a running `th`.
  Standard input closing, SIGTERM and SIGINT shut it down, cancelling its own speech.
- **MCP Server Config…** opens a floating window with sample configuration for both transports
  (`talkinghead-stdio`, `talkinghead-http`): a JSON tab (`mcpServers`) and a Shell tab of remove-then-add
  commands for Claude Code, Antigravity and Codex, each with a copy button; Copy/Copy All and Save…
  (`mcp.json` or `talkinghead-mcp.sh`).

### Speech spooler
- While the menu bar app runs, it owns the face and speaks everything from one first-in, first-out
  queue: `th`, `th-mcp`, the HTTP server, VoiceChat, links, the Services menu, and its own typing window,
  file button and Play. Only the menu bar applet serves it; `th` and `th-mcp` never launch the app.
- It listens on `~/Library/Application Support/TalkingHead/speech.sock` (0600, in a 0700 folder, same
  user only), with newline-delimited JSON objects keyed by `type`:
  - `speak` {`text` | `url`, `voice`?, `mood`?, `alwaysOnTop`?}, one per connection → `queued`,
    `started`, then `finished`, `stopped` or `error` {`message`}.
  - `stop` → `stopped`. It (like the MCP tool and the menu's Stop) ends the current speech and clears the
    whole queue.
  - `presence` {`state`: `listening` | `thinking` | `none`, `voice`?, `pulse`: `nod`?} → `presence`. An
    unknown state is answered `error`; an unknown voice is ignored.
- Closing a connection drops its queued speech, stops its speech if speaking, and drops its presence.
- Each job speaks with its own voice (else the menu's) and floats if asked; a face the spooler opened
  closes about a second after it has nothing to show. The menu's face is saved (`voice`) for `th-mcp`.
- **Presence rules:**
  - Held per connection; the newest message wins, and `none` drops it. With several holders, the most
    recently updated one is shown, with its voice.
  - Never queued. Speech overrides it; a change during speech is shown when the speech ends, and the
    face returns to the presence instead of closing.
  - Presence opens the face, floating, without activating Talking Head. The face closes only when the
    queue is empty and nobody holds presence.
  - Stop clears speech, not presence. A nod happens only while nothing is speaking.
  - `speak` and `stop` are unchanged for older clients; an older Talking Head answers `presence` with
    `error`, which clients take as "not supported".
