import AppKit

/// One call of a handler in an AppleScript run against a terminal app. The text goes in as an argument of the handler, never into the
/// script's source, so quotes, backslashes and line breaks in it are only text.
struct AppleScriptCall: Equatable, Sendable {
    /// The app the script talks to.
    let bundleID: String
    let source: String
    /// The handler's name, in lower case as AppleScript wants it.
    let handler: String
    let arguments: [String]
    /// What the handler returns when it did its work.
    let expecting: String
    /// Whether an app that isn't running may be started by the call: not for sending, which only makes sense to an open terminal.
    let launches: Bool
}

/// What an AppleScript call came to.
enum ScriptResult: Equatable, Sendable {
    /// The handler returned this text.
    case value(String)
    /// macOS refused the Apple Event: the user hasn't allowed Nunsseop to control the app (Automation, error -1743).
    case notAllowed
    case failed
}

/// Runs AppleScript calls. Tests give it one that records, so no test talks to a real terminal.
struct AppleScriptRunner: Sendable {
    var run: @Sendable (AppleScriptCall) -> ScriptResult

    /// errAEEventNotPermitted.
    static let notPermitted = -1743

    /// One script at a time: NSAppleScript is not safe to use from several threads at once.
    private static let queue = DispatchQueue(label: "nunsseop.terminal-scripts")

    static let live = AppleScriptRunner { call in
        if !call.launches, NSRunningApplication.runningApplications(withBundleIdentifier: call.bundleID).isEmpty { return .failed }
        return queue.sync { execute(call) }
    }

    /// The result for an error number from NSAppleScript.
    static func result(forError code: Int) -> ScriptResult { code == notPermitted ? .notAllowed : .failed }

    private static func fourCC(_ code: String) -> UInt32 { code.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    private static func execute(_ call: AppleScriptCall) -> ScriptResult {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: call.source), script.compileAndReturnError(&errorInfo) else {
            return result(forError: errorInfo?[NSAppleScript.errorNumber] as? Int ?? 0)
        }
        // A call of a handler with parameters: the subroutine event, whose direct parameter lists the arguments.
        let event = NSAppleEventDescriptor(eventClass: fourCC("ascr"), eventID: fourCC("psbr"), targetDescriptor: .null(),
                                           returnID: -1, transactionID: 0)
        event.setParam(NSAppleEventDescriptor(string: call.handler), forKeyword: fourCC("snam"))
        let arguments = NSAppleEventDescriptor.list()
        for (index, argument) in call.arguments.enumerated() { arguments.insert(NSAppleEventDescriptor(string: argument), at: index + 1) }
        event.setParam(arguments, forKeyword: fourCC("----"))
        let answer = script.executeAppleEvent(event, error: &errorInfo)
        if let errorInfo { return result(forError: errorInfo[NSAppleScript.errorNumber] as? Int ?? 0) }
        return answer.stringValue.map(ScriptResult.value) ?? .failed
    }
}

/// The scripts of the terminals that are driven through Apple Events (their dictionaries, read from the apps' sdef files: Terminal's
/// `tab` has a read-only `tty` and `do script ... in tab`; Ghostty's `new tab ... with configuration` takes `initial working directory`
/// and `command`; iTerm2's from its documentation: `session` has `tty`, `write text ... newline`, `create tab with default profile command`).
/// Each app is named by bundle id, so a renamed app is still the one.
enum TerminalScripts {
    static let terminalID = "com.apple.Terminal"
    static let itermID = "com.googlecode.iterm2"
    static let ghosttyID = "com.mitchellh.ghostty"

    /// Types the text into the tab on that device and presses Return: Terminal can't type without it. "missing" when no tab has it.
    static func terminalSend(tty: String, text: String) -> AppleScriptCall {
        AppleScriptCall(bundleID: terminalID, source: """
            on send_text(theTTY, theText)
            	tell application id "\(terminalID)"
            		repeat with wi from 1 to count of windows
            			set w to window wi
            			repeat with ti from 1 to count of tabs of w
            				set t to tab ti of w
            				if tty of t is theTTY then
            					do script theText in t
            					return "sent"
            				end if
            			end repeat
            		end repeat
            	end tell
            	return "missing"
            end send_text
            """, handler: "send_text", arguments: [tty, text], expecting: "sent", launches: false)
    }

    /// Types the text into the session on that device, with a Return after it when `submit`.
    static func itermSend(tty: String, text: String, submit: Bool) -> AppleScriptCall {
        AppleScriptCall(bundleID: itermID, source: """
            on send_text(theTTY, theText, withReturn)
            	tell application id "\(itermID)"
            		repeat with wi from 1 to count of windows
            			set w to window wi
            			repeat with ti from 1 to count of tabs of w
            				set t to tab ti of w
            				repeat with si from 1 to count of sessions of t
            					set s to session si of t
            					if tty of s is theTTY then
            						if withReturn is "1" then
            							tell s to write text theText
            						else
            							tell s to write text theText newline false
            						end if
            						return "sent"
            					end if
            				end repeat
            			end repeat
            		end repeat
            	end tell
            	return "missing"
            end send_text
            """, handler: "send_text", arguments: [tty, text, submit ? "1" : "0"], expecting: "sent", launches: false)
    }

    /// Brings the tab on that device forward: selected in its window, the window raised (and restored when minimized). "missing" when no tab has it.
    static func terminalFocus(tty: String) -> AppleScriptCall {
        AppleScriptCall(bundleID: terminalID, source: """
            on focus_tab(theTTY)
            	tell application id "\(terminalID)"
            		repeat with wi from 1 to count of windows
            			set w to window wi
            			repeat with ti from 1 to count of tabs of w
            				set t to tab ti of w
            				if tty of t is theTTY then
            					if miniaturized of w then set miniaturized of w to false
            					set selected of t to true
            					set index of w to 1
            					activate
            					return "focused"
            				end if
            			end repeat
            		end repeat
            	end tell
            	return "missing"
            end focus_tab
            """, handler: "focus_tab", arguments: [tty], expecting: "focused", launches: false)
    }

    /// Brings the session on that device forward: its window, tab and pane selected. "missing" when no session has it.
    static func itermFocus(tty: String) -> AppleScriptCall {
        AppleScriptCall(bundleID: itermID, source: """
            on focus_session(theTTY)
            	tell application id "\(itermID)"
            		repeat with wi from 1 to count of windows
            			set w to window wi
            			repeat with ti from 1 to count of tabs of w
            				set t to tab ti of w
            				repeat with si from 1 to count of sessions of t
            					set s to session si of t
            					if tty of s is theTTY then
            						tell w to select
            						tell t to select
            						tell s to select
            						activate
            						return "focused"
            					end if
            				end repeat
            			end repeat
            		end repeat
            	end tell
            	return "missing"
            end focus_session
            """, handler: "focus_session", arguments: [tty], expecting: "focused", launches: false)
    }

    /// A new tab of the front iTerm2 window running the command, or a window of its own when there is none.
    static func itermTab(command: String) -> AppleScriptCall {
        AppleScriptCall(bundleID: itermID, source: """
            on open_tab(theCommand)
            	tell application id "\(itermID)"
            		activate
            		if (count of windows) is 0 then
            			create window with default profile command theCommand
            		else
            			tell current window to create tab with default profile command theCommand
            		end if
            	end tell
            	return "opened"
            end open_tab
            """, handler: "open_tab", arguments: [command], expecting: "opened", launches: true)
    }

    /// A new tab of the front Ghostty window in the folder, running the command, or a window of its own when there is none.
    static func ghosttyTab(cwd: String, command: String) -> AppleScriptCall {
        AppleScriptCall(bundleID: ghosttyID, source: """
            on open_tab(theDir, theCommand)
            	tell application id "\(ghosttyID)"
            		activate
            		if (count of windows) is 0 then
            			new window with configuration {initial working directory:theDir, command:theCommand}
            		else
            			new tab in front window with configuration {initial working directory:theDir, command:theCommand}
            		end if
            	end tell
            	return "opened"
            end open_tab
            """, handler: "open_tab", arguments: [cwd, command], expecting: "opened", launches: false)
    }

    /// Apple Events to Ghostty wait this long (seconds) for an answer: the default is two minutes, and a Ghostty that hangs or sits on
    /// the Automation prompt would hold the one script queue (every other terminal's sends with it) for that long.
    static let ghosttyTimeout = 3

    /// Every Ghostty terminal: its id, folder and title, fields apart by U+001F and records by U+001E (a title may hold tabs and line
    /// breaks). A value that is missing counts as empty.
    static func ghosttyList() -> AppleScriptCall {
        AppleScriptCall(bundleID: ghosttyID, source: """
            on list_terminals()
            	set fieldSeparator to character id 31
            	set recordSeparator to character id 30
            	set listing to ""
            	with timeout of \(ghosttyTimeout) seconds
            		tell application id "\(ghosttyID)"
            			set surfaces to terminals
            			repeat with i from 1 to count of surfaces
            				set t to item i of surfaces
            				set listing to listing & my text_of(id of t) & fieldSeparator & my text_of(working directory of t) & fieldSeparator & my text_of(name of t) & recordSeparator
            			end repeat
            		end tell
            	end timeout
            	return listing
            end list_terminals
            on text_of(v)
            	if v is missing value then return ""
            	return v as text
            end text_of
            """, handler: "list_terminals", arguments: [], expecting: "", launches: false)
    }

    /// Types the text into the terminal with that id, with Return after it when `submit`, but only if the terminal is still the one that
    /// was picked: its folder is one of `folders` (one per line) and its title is Claude's (a status mark, then text), holding `name`
    /// when `needsName`, and no other terminal fits as well. When the tab was picked without the name, it also refuses if it is the
    /// only one in the folder yet another tab's Claude title holds `name` and its own doesn't (see `Ghostty.resolve`). "gone" when it
    /// no longer fits or isn't there, "ambiguous" when another fits too; nothing is typed then.
    static func ghosttySend(terminal: String, folders: [String], name: String, needsName: Bool, text: String, submit: Bool) -> AppleScriptCall {
        AppleScriptCall(bundleID: ghosttyID, source: ghosttyChecked(handler: "send_text", parameters: "theID, theFolders, theName, theNeedsName, theText, withReturn", action: """
            \t\t\tinput text theText to found
            \t\t\tif withReturn is "1" then send key "enter" to found
            """), handler: "send_text",
                          arguments: [terminal, folders.joined(separator: "\n"), name, needsName ? "1" : "0", text, submit ? "1" : "0"],
                          expecting: "ok", launches: false)
    }

    /// Brings the terminal with that id forward (its tab selected, its window raised), after the same check as `ghosttySend`: nothing is
    /// focused when it is "gone" or "ambiguous".
    static func ghosttyFocus(terminal: String, folders: [String], name: String, needsName: Bool) -> AppleScriptCall {
        AppleScriptCall(bundleID: ghosttyID, source: ghosttyChecked(handler: "focus_terminal", parameters: "theID, theFolders, theName, theNeedsName", action: """
            \t\t\tfocus found
            \t\t\tactivate
            """), handler: "focus_terminal",
                          arguments: [terminal, folders.joined(separator: "\n"), name, needsName ? "1" : "0"], expecting: "ok", launches: false)
    }

    /// The handler that finds the terminal again and runs `action` (lines inside the `tell`) on `found` only if it is the one picked.
    private static func ghosttyChecked(handler: String, parameters: String, action: String) -> String {
        """
            on \(handler)(\(parameters))
            	set acceptedFolders to paragraphs of theFolders
            	with timeout of \(ghosttyTimeout + 2) seconds
            		tell application id "\(ghosttyID)"
            			set surfaces to terminals
            			set found to missing value
            			set foundNamed to false
            			set fits to 0
            			set inFolderCount to 0
            			set elsewhereNamed to 0
            			repeat with i from 1 to count of surfaces
            				set t to item i of surfaces
            				considering case
            					set dir to my text_of(working directory of t)
            					set titleText to my claude_title(my text_of(name of t))
            					set inFolder to dir is in acceptedFolders
            					set isNamed to theName is not "" and titleText contains theName
            					if inFolder then set inFolderCount to inFolderCount + 1
            					if inFolder and titleText is not "" and (theNeedsName is "0" or isNamed) then
            						set fits to fits + 1
            						if (id of t) is theID then
            							set found to t
            							set foundNamed to isNamed
            						end if
            					else if isNamed and not inFolder then
            						set elsewhereNamed to elsewhereNamed + 1
            					end if
            				end considering
            			end repeat
            			if found is missing value then return "gone"
            			if fits is not 1 then return "ambiguous"
            			if theNeedsName is "0" then
            				if inFolderCount is not 1 then return "ambiguous"
            				if not foundNamed and elsewhereNamed > 0 then return "ambiguous"
            			end if
            \(action)
            		end tell
            	end timeout
            	return "ok"
            end \(handler)
            on text_of(v)
            	if v is missing value then return ""
            	return v as text
            end text_of
            on claude_title(heading)
            	try
            		if (count of characters of heading) < 3 then return ""
            		set mark to id of (character 1 of heading)
            		if mark < \(Ghostty.markScalars.lowerBound) or mark > \(Ghostty.markScalars.upperBound) then return ""
            		if character 2 of heading is not " " then return ""
            		return text 3 thru -1 of heading
            	on error
            		return ""
            	end try
            end claude_title
            """
    }

    /// The name of a terminal app for a note, by bundle id.
    static func name(of bundleID: String) -> String {
        switch bundleID {
        case terminalID: "Terminal"
        case itermID: "iTerm2"
        case ghosttyID: "Ghostty"
        default: bundleID
        }
    }

    /// What the note says when macOS has refused Apple Events to an app.
    static func notAllowedNote(_ bundleID: String) -> String {
        String(localized: "Allow Nunsseop to control \(name(of: bundleID)) in System Settings › Privacy & Security › Automation")
    }
}

/// kitty's command-line tool, and the socket of a kitty that was seen: kitty can be controlled from outside only through the
/// socket it listens on, which a session in it reports as `KITTY_LISTEN_ON`.
enum Kitty {
    static let bundleID = "net.kovidgoyal.kitty"

    static var cli: URL? {
        let bundled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?
            .appendingPathComponent("Contents/MacOS/kitty")
        return ([bundled?.path] + ["/opt/homebrew/bin/kitty", "/usr/local/bin/kitty"]).compactMap { $0 }
            .map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static let socketKey = "kittySocket"

    /// The socket of the latest kitty session that reported one.
    static var socket: String? {
        get { saved(in: .standard) }
        set { UserDefaults.standard.set(newValue.flatMap(AgentInput.kittySocket), forKey: socketKey) }
    }

    static func saved(in defaults: UserDefaults) -> String? { AgentInput.kittySocket(defaults.string(forKey: socketKey)) }

    /// Whether the socket of an address (`unix:/path`) is there to connect to.
    static func socketExists(_ address: String) -> Bool {
        var info = stat()
        return stat(String(address.dropFirst("unix:".count)), &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK
    }

    /// Remembers the socket of a session's kitty, for resuming conversations in it.
    static func remember(_ input: AgentInput?, in defaults: UserDefaults = .standard) {
        if case .kitty(_, let socket)? = input, saved(in: defaults) != socket { defaults.set(socket, forKey: socketKey) }
    }
}
