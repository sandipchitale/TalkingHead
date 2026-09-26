# Talking Head

## Original request

Develop a simple GUI in SwiftUI which UI allows user to type text in a text view. Then use Apple's
native engine to speak that text. Allow user to pause and resume speech. Also generate s simple
animated face which will sync with the speech. This should run on MacOS.

## Current specification

### Platform
- macOS 26 (Tahoe) or later, SwiftUI, Swift 6.
- Speech uses Apple's native engine (`AVSpeechSynthesizer`) with the system voices **Daniel** (male)
  and **Samantha** (female), at the best installed quality of each.

### Talking head
- Each voice has its own portrait: a man for Daniel, a woman for Samantha.
- The mouth lip-syncs to the audio being heard. It uses cartoon mouth shapes (visemes) for A/E/I, O,
  U, EE, F/V, L, R, TH, CH/J/SH, B/M/P, Q/W, other consonants, and rest.
- The shapes follow each word's spelling, timed to when the word is actually voiced.
- When the mouth is closed, the portrait's own smile shows.
- The eyes blink every few seconds.
- The eyebrows lift briefly on stressed words: the first word of each sentence or clause, words in
  capitals, words of 7 or more letters, and the last word before "?" or "!". They lift at most every
  0.8 s, so they don't twitch, except that the last word before "?" or "!" always lifts them, and
  half as high again as other words.
- They dip slightly (half as far) on negative or doubtful words: "no", "not", "never", words ending in
  "n't", "but", "however", "sorry", "problem", "wrong" and the like. This wins over a lift, except
  the higher lift before "?" or "!".

### Face window
- A separate, resizable, draggable window showing only the talking head, titled with the voice name.
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
- The menu has: Show Talking Head, Type Text to Speak…, Play/Pause, Stop, Voice (Male/Female),
  Speed (Slower/Normal/Faster), Always on Top, Launch at Login, and Quit.
- **Always on Top** matches the face window's pin button and is remembered between launches.
- Launched from Finder or at login, it starts with only the menu bar item and keeps running when its
  windows are closed.

### Command line: `th`
- `th` is packaged inside the app bundle (`TalkingHead.app/Contents/MacOS/th`).
- Usage: `th [-v|--voice male|female] [-t|--tty] [-f|--file path] [-u|--url URL] [--always-on-top] [text ...]`
  - `-v`/`--voice`: `male` selects Daniel (the default), `female` selects Samantha.
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
- `th` quits when its windows are closed. It doesn't add a menu bar item of its own.
- `-h`/`--help` prints usage. Invalid options, voices, unreadable files or pages, and text fragments
  not found on the page print an error and exit with status 2.

### Speaking from other apps
- **Services menu:** "Speak with Talking Head" speaks the selected text in any app (e.g. an email in
  Mail). If the selection is a single web link, the page (or its highlighted passage) is spoken. The
  face window opens.
- **URL scheme:** `talkinghead://speak?text=…` or `talkinghead://speak?url=…`, with optional
  `voice=male|female`. Opening such a link launches Talking Head if needed and speaks straight away.
- **Text fragments:** for URLs with `#:~:text=[prefix-,]start[,end][,-suffix]`, only the referenced
  passage is spoken (case- and whitespace-insensitive). URLs without a fragment speak the whole page's
  text; a fragment that can't be found is reported as an error.
