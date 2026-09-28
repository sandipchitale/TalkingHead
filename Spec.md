# Talking Head

## Original request

Develop a simple GUI in SwiftUI which UI allows user to type text in a text view. Then use Apple's
native engine to speak that text. Allow user to pause and resume speech. Also generate s simple
animated face which will sync with the speech. This should run on MacOS.

## Current specification

### Platform
- macOS 26 (Tahoe) or later, SwiftUI, Swift 6.
- Speech uses Apple's native engine (`AVSpeechSynthesizer`) with the system voices **Daniel** (male)
  and **Samantha** (female), at the best installed quality of each (the downloadable "Daniel
  (Enhanced)", "Samantha (Premium)" and so on count as the same voice).
- Each face can instead speak with an installed English voice of its gender, as macOS labels it (voices
  labelled neither male nor female, and novelty voices, aren't offered), chosen in the menu (Man's Voice,
  Woman's Voice) and saved per face (`faceVoice.<Daniel|Samantha>`, the voice's
  identifier). A chosen voice that is no longer installed, or doesn't suit the face, falls back to the
  face's own. The choice
  applies wherever that face speaks: the app, `th` (with or without the menu bar app), links and MCP.
  The menu and the typing window's greeting use the name of the voice speaking.

### Talking head
- Each voice has its own portrait: a man for Daniel, a woman for Samantha.
- The mouth lip-syncs to the audio being heard. It uses cartoon mouth shapes (visemes) for A/E/I, O,
  U, EE, F/V, L, R, TH, CH/J/SH, B/M/P, Q/W, other consonants, and rest.
- The shapes follow each word's spelling, timed to when the word is actually voiced.
- When the mouth is closed, the portrait's own smile shows, unless a mood turns it down (see Moods).
- The eyes blink every few seconds.
- The eyebrows lift briefly on the words the voice stresses, found from the pitch of the speech
  audio: a word whose pitch rises well above the speaker's median, measured against how far that
  voice usually rises. The more it rises, the higher they go. When a word's pitch can't be measured,
  stress is guessed from the text instead: the first word of each sentence or clause, and words of 7
  or more letters.
- Words in capitals and the last word before "?" or "!" also lift them. They lift at most every
  0.8 s, so they don't twitch, except that the last word before "?" or "!" always lifts them, and
  half as high again as other words.
- They dip slightly (half as far) on negative or doubtful words: "no", "not", "never", words ending in
  "n't", "but", "however", "sorry", "problem", "wrong" and the like. This wins over a lift, except
  the higher lift before "?" or "!".

### Moods
- The face can show a mood: `neutral`, `happy` (brows a little up), `sad` (inner brows up, mouth
  turned down), `surprised` (brows well up), `concerned` (brows down, inner ends up, mouth down) or
  `angry` (brows down, inner ends down, mouth down). The stress movements of the eyebrows add to it.
- Any caller can give a mood, AI or not:
  - `th --mood MOOD` or `mood=MOOD` in a `talkinghead://` link, for all of the text;
  - `[mood]` cues in the text (any case), from where they stand until the next cue; `[neutral]` ends
    one. Cues are not spoken, and square brackets that don't name a mood are left alone.
- Without a hint, each sentence gets the mood its emoji and emoticons (e.g. 😊 🙂 🎉 happy, 😢 `:(`
  sad, 😮 surprised, 😟 🤔 ⚠️ concerned, 😠 angry) and feeling words ("great", "thanks",
  "unfortunately", "sorry", "wow", "warning", "failed", "unacceptable"…) suggest; emoji count double,
  and the first mood wins a tie. An emoji belongs to the sentence it follows. Mood emoji and
  emoticons are not spoken; other emoji are left in the text.
- Cues win over a mood given for the whole text, which wins over the guesses.
- The mood holds through a pause and fades back to neutral when the speech ends.
### Face window
- A separate, resizable, draggable window showing only the talking head, titled with the face ("Man" or
  "Woman") and subtitled with the voice speaking for it (no subtitle when macOS's default voice speaks,
  because neither the chosen voice nor the face's own is installed).
- A toolbar centred below the head holds small round icon buttons:
  - **Play/Pause** (Space). When idle, it replays the last text.
  - **Type text to speak** (window icon) opens the typing window.
  - **Select a file to speak** (file icon) picks a text file and speaks it.
  - **Pin/Unpin** (pin icon, filled when pinned) keeps the window and its bubble above other windows.

### Speech bubble
- A rounded speech-bubble window beside the face window, a little apart from it, with its tail
  pointing at the head.
- It shows the spoken text with the current word highlighted, and scrolls to keep that word in view.
- It is hidden initially. Clicking the head shows or hides it.
- It follows the face window when that is moved or resized.

### Typing window
- A text box and a **Speak** button (⌘⏎) that sends the text to the talking head.

### Menu bar applet
- Runs as a menu bar applet: no Dock icon and no app menu.
- The menu starts with a heading showing the app's name and version ("Talking Head 0.0.8").
- The menu has: Show Talking Head, Type Text to Speak…, Play/Pause, Stop, Voice (Man/Woman, each
  shown with the voice it uses, e.g. "Woman (Ava)"), Man's Voice and Woman's Voice (the voice each face
  speaks with: its own, or an installed English voice of its gender, best quality first), Speed
  (Slower/Normal/Faster), Always on Top, Launch at Login, MCP Server (port N), MCP Server Config…, and
  Quit.
- **Always on Top** matches the face window's pin button and is remembered between launches.
- Launched from Finder or at login, it starts with only the menu bar item and keeps running when its
  windows are closed.

### Command line: `th`
- `th` is packaged inside the app bundle (`TalkingHead.app/Contents/MacOS/th`).
- Usage: `th [-v|--voice male|female] [-m|--mood MOOD] [-t|--tty] [-f|--file path] [-u|--url URL] [--always-on-top] [text ...]`
  - `-v`/`--voice`: `male` selects Daniel (the default), `female` selects Samantha.
  - `-m`/`--mood`: the mood to show (see Moods). An unknown mood is an error.
  - `-f`/`--file`: speak this file (`-` reads standard input).
  - `-u`/`--url`: speak an http(s) web page, or only the passage its text fragment (`#:~:text=…`)
    refers to.
  - `-t`/`--tty`: read the text typed at the terminal (end with Control-D).
  - `--always-on-top`: keep the talking head above other windows for this run (not saved).
  - `text ...`: the non-option arguments, joined with spaces, are the text to speak. `--` ends the
    options, so the text can start with `-`.
- Only one text source may be given: text arguments, `--file`, `--url` or `--tty`. With none of them, standard
  input is read when it is not a terminal (piped or redirected); otherwise `th` just shows the talking
  head.
- When given text, `th` shows the face, speaks, and quits when done. It stays open if the typing window
  or file picker was used.
- When the menu bar app is running, a `th` with text to speak (arguments, `--file`, `--url`, standard
  input or `--tty`) hands it to the app's spooler instead of showing its own face (always naming its
  voice: male unless `-v female`), waits until the speech has finished, and exits as it would have: 0
  when finished or stopped, 2 with its `th: …` message when the speech can't be spoken. SIGTERM or SIGINT
  ends it and so cancels only its own request. `--report-start` works the same way.
- `th` quits when its windows are closed. It doesn't add a menu bar item of its own.
- `-h`/`--help` prints usage. Invalid options, voices, moods, unreadable files or pages, and text fragments
  not found on the page print an error and exit with status 2.

### Speaking from other apps
- **Services menu:** "Speak with Talking Head" speaks the selected text in any app (e.g. an email in
  Mail). If the selection is a single web link, the page (or its highlighted passage) is spoken. The
  face window opens.
- **URL scheme:** `talkinghead://speak?text=…` or `talkinghead://speak?url=…`, with optional
  `voice=male|female` and `mood=…` (an unknown mood is ignored). Opening such a link launches Talking Head if needed and speaks straight away.
- **Text fragments:** for URLs with `#:~:text=[prefix-,]start[,end][,-suffix]`, only the referenced
  passage is spoken (case- and whitespace-insensitive). URLs without a fragment speak the whole page's
  text; a fragment that can't be found is reported as an error.

### MCP server
- Talking Head serves MCP tools over two transports, with the same tool definitions and handlers
  (written once, in `MCPTools/`), using the MCP Swift SDK, exactly version 0.12.1:
  - **stdio:** `th-mcp`, packaged in the app bundle next to `th` and signed before the app is.
  - **Streamable HTTP:** served in-process by the menu bar applet at `http://127.0.0.1:<port>/mcp`,
    bound to `127.0.0.1` only, never all interfaces. The default port is 8766.
- **Tools:**
  - `speak`: `text` (required; may contain `[mood]` cues), `voice` (`male`, `female`), `mood` (one of
    the moods), `wait` (boolean, default true).
  - `speak_url`: `url` (http or https, may end in `#:~:text=…`), `voice`, `mood`, `wait`. Reads the page,
    or only its text-fragment passage, exactly as `th -u` does.
  - `stop`: no arguments. Stops the current speech, drops speech waiting its turn, and closes the face.
  - Their annotations say they are not read-only, not destructive and not idempotent.
- Speech shows the face, kept above other windows. With `wait` true, a call returns when the speech has
  finished; with `wait` false, as soon as it starts.
- No call blocks longer than `TALKINGHEAD_MCP_WAIT_MS` (default 45000). When that is reached, the call
  returns a normal (not error) result, "Still speaking. It will finish on its own; don't call again to
  repeat it." (or, if the speech is still waiting its turn, "Waiting for earlier speech to finish; …"),
  and the speech carries on. The `wait` parameter's description says so.
- While a call waits, when the request carries a `progressToken`, a `notifications/progress` goes out
  every 5 s: "Waiting for earlier speech…" or "Speaking…". Both transports (over HTTP, the SDK sends
  them on the session's standalone GET stream).
- Calls are serialised: a new `speak` or `speak_url` waits for the previous one to finish. While the
  menu bar app runs, every caller shares its one queue (see Speech spooler); otherwise each `th-mcp`
  process has its own.
- `stop` means silence: it ends the current speech and clears the whole queue, whoever queued it, and
  closes the face. Speech stopped from elsewhere (the menu's Stop) also drops a caller's own queued
  requests.
- Leaving out `voice` means the voice chosen in the menu bar app's menu: through the spooler the app uses
  its current voice; without the app, `th-mcp` reads the app's saved choice and passes it to `th` (male
  if none was ever chosen).
- Errors (bad arguments, an unknown mood or voice, a page that can't be read, a text fragment not
  found) come back as tool results with `isError` and a plain sentence the model can relay to the user.
- **`th-mcp`:** writes nothing but JSON-RPC to standard output; diagnostics go to standard error. For
  each call, when the menu bar app's spooler socket answers, it hands the speech to the spooler (with
  `alwaysOnTop`) and follows its events; otherwise it runs the `th` beside it (following symlinks to find
  it) with `--always-on-top`, `-v`, `-m` and `-u` as given, and text on standard input. `th`'s exit is
  the end of the speech; exit status 2 means it couldn't speak, and its `th: …` line on standard error is
  the error message. `stop` sends the spooler a `stop` and terminates a running `th`. Standard input
  closing, SIGTERM and SIGINT shut `th-mcp` down cleanly, cancelling its own speech (its spooler
  connections close; a running `th` is ended).
- `th --report-start` (for `th-mcp`, not in the usage) prints `started` on standard output when the
  voice starts.
- **HTTP server:** off by default. The menu item "MCP Server (port N)" turns it on or off and is
  remembered between launches. `TALKINGHEAD_MCP_HTTP_PORT` turns it on at launch, on that port. If the
  port can't be bound, an alert says so and the server stays off. Only the menu bar applet serves
  HTTP; an instance started by `th` never opens the port.
- **MCP Server Config…** (menu bar applet) opens a window, as VoiceChat's does, with sample client
  configuration for both transports (`talkinghead-stdio` running `th-mcp` from /Applications, and
  `talkinghead-http` at the configured port): a JSON tab (an `mcpServers` document) and a Shell tab with
  remove-then-add commands for Claude Code (`claude`), Antigravity (`agy`) and Codex (`codex`), grouped
  by host, each with a copy button. Copy (Copy All on the Shell tab) copies the tab, and Save… writes it
  to `mcp.json` or `talkinghead-mcp.sh`. The window floats above other windows.
- The HTTP server speaks through the menu bar app's spooler. HTTP sessions are created by `initialize`
  (returning `Mcp-Session-Id`), closed by `DELETE`, and expire after an hour idle.

### Speech spooler
- While the menu bar app runs, it owns the face and speaks everything from one first-in, first-out
  queue: `th` (and so VoiceChat), every `th-mcp` process, the HTTP MCP server, `talkinghead://` links,
  the Services menu, and the app's own typing window, file button and Play.
- It listens on a Unix domain socket, `~/Library/Application Support/TalkingHead/speech.sock`, 0600 in
  a 0700 folder, accepting only the same user. The protocol is newline-delimited JSON, one `speak` per
  connection: requests `speak` {`text` | `url`, `voice`?, `mood`?, `alwaysOnTop`?} and `stop`; events
  `queued`, `started`, then `finished`, `stopped` or `error` {`message`}. `stop` is answered `stopped`.
- A caller whose connection closes has its queued requests dropped, and its speech stopped if it is the
  one speaking. Everyone else's speech is unaffected.
- `stop` (the MCP tool, or the socket's) and the menu's Stop end the current speech and clear the whole
  queue, whoever queued it.
- For each job the face uses the job's voice for that speech only (else the menu's choice), floats if
  asked, and a face opened for spooled speech closes about a second after the queue empties. The menu's
  voice choice is saved (`voice`, `male` or `female`) for `th-mcp` to read when the app isn't running.
- Only the menu bar applet serves the socket; an instance started by `th` never does. `th` and `th-mcp`
  never launch the app: without it, they behave as they would alone.
