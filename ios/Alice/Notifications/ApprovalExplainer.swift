import Foundation

/// What an approval is asking for, in words someone who has never opened a
/// terminal can decide on.
///
/// Hermes asks before an assistant does something it classes as risky, and
/// names the class in its own shorthand — `recursive delete`, `pipe remote
/// content to shell`, `execute_code script execution. The script can spawn
/// subprocesses…` — next to the raw command. Both are accurate, and neither
/// tells a person what they would be agreeing to. The classes are a fixed list
/// (`tools/approval_detection.py`); this says each one plainly.
struct ApprovalExplanation: Hashable, Sendable {
    /// What will happen, finishing "Wants to …": "run a small program it wrote".
    var action: String
    /// What could go wrong if it is allowed.
    var risk: String
}

enum ApprovalExplainer {

    static func explain(description: String?, command: String?) -> ApprovalExplanation {
        let text = (description ?? "").lowercased()
        let code = (command ?? "").lowercased()

        if text.hasPrefix("execute_code") || code.hasPrefix("execute_code") {
            return program
        }
        // Order matters where one class's words appear in another's:
        // "delete backups" is not a file delete, "force stop service" is not
        // closing programs, and "hermes secrets" is not restarting Hermes.
        for rule in rules where rule.needles.contains(where: { text.contains($0) }) {
            return rule.explanation
        }
        if let description, !description.isEmpty {
            return ApprovalExplanation(
                action: "do something Hermes treats as risky",
                risk: "Hermes describes it as “\(description)”. Look at the exact command before "
                    + "allowing it."
            )
        }
        return ApprovalExplanation(
            action: "run a command on the computer where Hermes is installed",
            risk: "Hermes didn't say what makes it risky. Look at the exact command before allowing it."
        )
    }

    static func label(_ choice: Message.ApprovalChoice) -> String {
        switch choice {
        case .once: "Allow once"
        case .session: "Allow for this conversation"
        case .always: "Always allow"
        case .deny: "Don't allow"
        }
    }

    /// What the offered choices mean — only the ones Hermes offered, since a
    /// request its safety check flagged comes with "once" and "deny" alone.
    static func choiceHint(_ choices: [Message.ApprovalChoice]) -> String {
        var parts = ["“Allow once” lets it do only this."]
        if choices.contains(.session) {
            parts.append("“For this conversation” also allows the same kind of action until the conversation ends.")
        }
        if choices.contains(.always) {
            parts.append("“Always allow” stops Hermes asking about this kind of action in any conversation.")
        }
        parts.append("If you don't answer, Hermes refuses after a few minutes.")
        return parts.joined(separator: " ")
    }

    static let smartDeniedWarning =
        "Hermes' safety check thinks this is genuinely dangerous and recommends not allowing it."

    // MARK: - Classes

    static let program = ApprovalExplanation(
        action: "run a small program it wrote",
        risk: "The program runs on the computer where Hermes is installed, and can read, change or "
            + "delete files there or start other programs."
    )

    private struct Rule {
        var needles: [String]
        var explanation: ApprovalExplanation
    }

    private static let rules: [Rule] = [
        Rule(needles: ["ssh key", "hermes secrets", "credential"], explanation: .init(
            action: "read your private keys or saved passwords",
            risk: "Anyone who gets these can sign in to your accounts or servers as you."
        )),
        Rule(needles: ["block device", "disk copy", "format", "wipe", "partition", "clear-disk", "cipher /w"],
             explanation: .init(
            action: "write directly to a disk",
            risk: "This can erase everything stored on that disk."
        )),
        Rule(needles: ["registry", "boot configuration", "shadow copies", "delete backups"], explanation: .init(
            action: "change core system settings or remove backups",
            risk: "This can stop the computer from starting properly, or remove your way to undo a mistake."
        )),
        Rule(needles: ["obfuscation", "decoded content"], explanation: .init(
            action: "run a command that has been deliberately disguised",
            risk: "Disguised commands are a common way to slip something harmful past a safety check."
        )),
        Rule(needles: ["remote content", "remote script", "invoke-expression", "iwr"], explanation: .init(
            action: "download something from the internet and run it straight away",
            risk: "Whatever is downloaded runs immediately, with no chance to check what it is first."
        )),
        Rule(needles: ["hermes gateway", "hermes update"], explanation: .init(
            action: "restart Hermes",
            risk: "Everything Hermes is doing right now stops — other conversations and automations included."
        )),
        Rule(needles: ["service"], explanation: .init(
            action: "stop or restart a system service",
            risk: "Parts of the computer that rely on it may stop working until it runs again."
        )),
        Rule(needles: ["kill"], explanation: .init(
            action: "force programs that are running to close",
            risk: "Anything unsaved in those programs is lost."
        )),
        // Not "rm": it is inside "permissions" and "format".
        Rule(needles: ["recursive delete", "find -delete", "with rm", "-execdir rm", "delete in root",
                       "force options", "delete"], explanation: .init(
            action: "delete files or folders, including everything inside them",
            risk: "Deleted files don't go to the Trash — they can't be recovered."
        )),
        Rule(needles: ["overwrite system"], explanation: .init(
            action: "replace an important system file",
            risk: "If the new contents are wrong, parts of the computer can stop working."
        )),
        Rule(needles: ["overwrite project"], explanation: .init(
            action: "overwrite a project's settings file",
            risk: "Whatever that file holds now — settings, keys — is replaced and can't be brought back."
        )),
        Rule(needles: ["writable", "chown", "icacls", "everyone access", "acl"], explanation: .init(
            action: "change who is allowed to open or change files",
            risk: "Other people or programs on the computer could read or change those files."
        )),
        Rule(needles: ["parser limit", "malformed"], explanation: .init(
            action: "run a command too complicated for Hermes to check",
            risk: "Hermes couldn't read it well enough to tell what it does."
        )),
        Rule(needles: ["save to memory"], explanation: .init(
            action: "save something to its long-term memory",
            risk: "It will remember this in future conversations."
        )),
    ]
}
