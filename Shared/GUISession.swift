// SPDX-License-Identifier: GPL-3.0-or-later
//
// Whether this Mac has somebody in front of it.
//
// Apple Core is commonly run as a headless bridge on a Mac nobody is sitting
// at. Anything that puts a window on screen still "succeeds" there, it just
// helps nobody, so tools whose whole purpose is to show something need to say
// so rather than silently open a window into the void.
//
// The same condition explains a family of failures that read like app bugs:
// a locked Mac reports zero capturable displays and hangs the Shortcuts CLI.
// In both cases there is no usable window server session, which is a fact
// about the machine and not a fault in the caller.

import CoreGraphics
import Foundation

public enum GUISession {
    /// True when this process is attached to the console session and that
    /// session is not sitting at the lock screen.
    ///
    /// `CGSessionCopyCurrentDictionary` returns nil for a process with no
    /// window server connection at all, which is the case over ssh, so a nil
    /// dictionary is itself an answer rather than an error.
    public static var isActive: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        let onConsole = info[kCGSessionOnConsoleKey as String] as? Bool ?? false
        // No public constant for this one. The key has been stable for many
        // macOS releases, and its absence is treated as "not locked" so a
        // rename degrades toward letting the call through rather than
        // blocking a Mac someone is actually using.
        let isLocked = info["CGSSessionScreenIsLocked"] as? Bool ?? false
        return onConsole && !isLocked
    }

    /// Explanation for a tool that cannot do anything useful without a screen.
    /// Names the action so the caller can tell which of several show-style
    /// tools it tripped over.
    public static func unavailableMessage(for action: String) -> String {
        "NO_GUI_SESSION: \(action) needs a Mac that somebody is signed in to and looking at. "
            + "This one has no active desktop session, or its screen is locked, so the window "
            + "would open where nobody can see it."
    }
}
