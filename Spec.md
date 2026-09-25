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

### Face window
- A separate, resizable, draggable window showing only the talking head, titled with the voice name.
- A toolbar centred below the head holds small round icon buttons:
  - **Play/Pause** (Space). When idle, it replays the last text.
  - **Type text to speak** (window icon) opens the typing window.
  - **Select a file to speak** (file icon) picks a text file and speaks it.

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
  Speed (Slower/Normal/Faster), Launch at Login, and Quit.
- Launched from Finder or at login, it starts with only the menu bar item and keeps running when its
  windows are closed.

### Command line: `th`
- `th` is packaged inside the app bundle (`TalkingHead.app/Contents/MacOS/th`).
- Usage: `th [-v|--voice male|female] [-t|--tty] [file]`
  - `-v`/`--voice`: `male` selects Daniel (the default), `female` selects Samantha.
  - `-t`/`--tty`: read the text typed at the terminal (end with Control-D).
  - `file`: speak this file.
- Without a file, standard input is read only when it is not a terminal (piped or redirected), or with
  `--tty`. Otherwise `th` just shows the talking head.
- When given text, `th` shows the face, speaks, and quits when done. It stays open if the typing window
  or file picker was used.
- `th` quits when its windows are closed. It doesn't add a menu bar item of its own.
- `-h`/`--help` prints usage. Invalid options, voices or unreadable files print an error and exit with
  status 2.
