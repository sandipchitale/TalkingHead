import Foundation

/// How the app was asked to run, parsed from the command line.
///
/// The `th` script inside the app bundle runs the app executable with the user's arguments
/// packed into a `-THArguments` value (see `current()`):
///
///     th [-v|--voice male|female] [-t|--tty] [-f|--file path] [text ...]
///
/// The text comes from the non-option arguments, the `--file`, the terminal with `--tty`, or
/// standard input when that is piped or redirected. Otherwise just the talking head is shown. Launched from Finder (no `-THArguments`), the app starts quietly in the menu bar.
struct LaunchOptions {
    /// The options this process was launched with.
    static let launch = LaunchOptions.current()

    /// Whether `th` started this process (as opposed to Finder).
    var isCommandLine: Bool {
        if case .menuBar = mode { false } else { true }
    }

    enum Mode {
        /// Launched from Finder: start with just the menu bar item.
        case menuBar
        /// Just show the talking head.
        case face
        /// Speak this text, then quit.
        case speak(String)
    }

    var mode: Mode
    var portrait: Portrait

    static let usage = """
        usage: th [-v|--voice male|female] [-t|--tty] [-f|--file path] [text ...]

        Speaks text with an animated talking head, then quits. The text is the arguments,
        the file, what you type at the terminal (--tty), or piped standard input. With none
        of these, just shows the talking head.

          -v, --voice VOICE  male (Daniel, the default) or female (Samantha)
          -f, --file PATH    speak this file (plain text, RTF, HTML, Word…; - for stdin)
          -t, --tty          read the text typed at the terminal (end with Control-D)
          -h, --help         show this help
          --                 treat everything after this as text, even if it starts with -
        """

    /// Starting text for the typing window.
    static let defaultText = "Hello! I am a talking head. Type something here, press Speak, and I will read it aloud for you."

    /// The options for this process. `th` passes its arguments NUL-separated and base64
    /// encoded as `-THArguments <value>`, which AppKit exposes as a (temporary) user default.
    static func current() -> LaunchOptions {
        guard let packed = UserDefaults.standard.string(forKey: "THArguments") else {
            return parse([], isCLI: false)
        }
        let data = Data(base64Encoded: packed, options: .ignoreUnknownCharacters) ?? Data()
        let arguments = data.split(separator: 0, omittingEmptySubsequences: false)
            .dropFirst()  // the leading "th" marker
            .dropLast()  // after the trailing NUL
            .map { String(decoding: $0, as: UTF8.self) }
        return parse(Array(arguments), isCLI: true)
    }

    /// Parses the user's `arguments`. Prints usage or an error and exits the process when
    /// they ask for help or are invalid.
    static func parse(_ arguments: [String], isCLI: Bool) -> LaunchOptions {
        var portrait = Portrait.man
        var path: String?
        var readsTerminal = false
        var words: [String] = []

        var remaining = arguments[...]
        while let argument = remaining.popFirst() {
            switch argument {
            case "--":
                words += remaining
                remaining = []
            case "-h", "--help":
                print(usage)
                exit(0)
            case "-t", "--tty":
                readsTerminal = true
            case "-v", "--voice":
                guard let name = remaining.popFirst() else { fail("\(argument) needs male or female") }
                portrait = voice(named: name)
            case _ where argument.hasPrefix("--voice="):
                portrait = voice(named: String(argument.dropFirst("--voice=".count)))
            case "-f", "--file":
                guard let value = remaining.popFirst() else { fail("\(argument) needs a file path") }
                guard path == nil else { fail("only one file can be given") }
                path = value
            case _ where argument.hasPrefix("--file="):
                guard path == nil else { fail("only one file can be given") }
                path = String(argument.dropFirst("--file=".count))
            case _ where argument.hasPrefix("-") && argument.count > 1:
                fail("unknown option \(argument)")
            default:
                words.append(argument)
            }
        }
        let sources = [!words.isEmpty, path != nil, readsTerminal].filter { $0 }.count
        guard sources <= 1 else { fail("give text arguments, --file or --tty, not more than one") }

        if !isCLI {
            return LaunchOptions(mode: .menuBar, portrait: portrait)
        }
        let text: String
        if !words.isEmpty {
            text = words.joined(separator: " ")
        } else if let path {
            text = readText(from: path)
        } else if readsTerminal || isatty(STDIN_FILENO) == 0 {
            text = readStandardInput()
        } else {
            return LaunchOptions(mode: .face, portrait: portrait)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { fail("no text to speak") }
        return LaunchOptions(mode: .speak(text), portrait: portrait)
    }

    /// `male` selects Daniel (the man); `female` selects Samantha (the woman).
    private static func voice(named name: String) -> Portrait {
        switch name.lowercased() {
        case "male": .man
        case "female": .woman
        default: fail("unknown voice \(name); use male or female")
        }
    }

    private static func readText(from path: String) -> String {
        if path == "-" { return readStandardInput() }
        do {
            return try TextFile.read(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        } catch {
            fail("can't read \(path): \(error.localizedDescription)")
        }
    }

    private static func readStandardInput() -> String {
        if isatty(STDIN_FILENO) != 0 {
            FileHandle.standardError.write(Data("Type the text to speak, then press Control-D.\n".utf8))
        }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("th: \(message)\n\n\(usage)\n".utf8))
        exit(2)
    }
}
