import AppKit
import CaffCore

final class AgentLauncherPanel: NSObject {
    let view: NSStackView
    private let commandPopup = NSPopUpButton()
    private let nameField = NSTextField(string: "")
    private let executableField = NSTextField(string: "")
    private let argumentsField = NSTextField(string: "")
    private let workingDirectoryField = NSTextField(string: "~")
    private let environmentField = NSTextField(string: "")
    private let statusLabel = NSTextField(labelWithString: "Agent launcher idle")
    private let launchButton = NSButton(title: "Launch Agent Command", target: nil, action: nil)
    private let releaseButton = NSButton(title: "Release Assertion Only", target: nil, action: nil)
    private let terminateButton = NSButton(title: "Terminate Command", target: nil, action: nil)
    private let onLaunch: (AgentCommandDefinition) -> Void
    private let onReleaseAssertion: () -> Void
    private let onTerminate: () -> Void
    private let onError: (Error) -> Void

    init(
        onLaunch: @escaping (AgentCommandDefinition) -> Void,
        onReleaseAssertion: @escaping () -> Void,
        onTerminate: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.onLaunch = onLaunch
        self.onReleaseAssertion = onReleaseAssertion
        self.onTerminate = onTerminate
        self.onError = onError
        self.view = NSStackView()
        super.init()
        configure()
    }

    func update(isProcessRunning: Bool, hasLauncherAssertion: Bool) {
        launchButton.isEnabled = !isProcessRunning && !hasLauncherAssertion
        releaseButton.isEnabled = hasLauncherAssertion
        terminateButton.isEnabled = isProcessRunning
    }

    func setStatus(_ status: String) {
        statusLabel.stringValue = status
    }

    @objc private func selectCommand() {
        let index = commandPopup.indexOfSelectedItem
        guard AgentCommandDefinition.builtInExamples.indices.contains(index) else {
            return
        }
        apply(AgentCommandDefinition.builtInExamples[index])
    }

    @objc private func launchSelectedCommand() {
        do {
            onLaunch(try currentCommand())
        } catch {
            onError(error)
        }
    }

    @objc private func releaseAssertionOnly() {
        onReleaseAssertion()
    }

    @objc private func terminateCommand() {
        onTerminate()
    }

    private func configure() {
        commandPopup.addItems(withTitles: AgentCommandDefinition.builtInExamples.map(\.name))
        commandPopup.target = self
        commandPopup.action = #selector(selectCommand)
        for field in [nameField, executableField, argumentsField, workingDirectoryField, environmentField] {
            field.font = .systemFont(ofSize: 12)
        }
        nameField.placeholderString = "Name"
        executableField.placeholderString = "Executable, e.g. codex"
        argumentsField.placeholderString = "Arguments, e.g. --help"
        workingDirectoryField.placeholderString = "~/Desktop/code/project"
        environmentField.placeholderString = "KEY=value, OTHER=value"
        AppLabelStyle.configureSecondary(statusLabel)
        launchButton.target = self
        launchButton.action = #selector(launchSelectedCommand)
        releaseButton.target = self
        releaseButton.action = #selector(releaseAssertionOnly)
        terminateButton.target = self
        terminateButton.action = #selector(terminateCommand)
        for button in [launchButton, releaseButton, terminateButton] {
            button.bezelStyle = .rounded
        }

        view.setViews([
            commandPopup,
            nameField,
            executableField,
            argumentsField,
            workingDirectoryField,
            environmentField,
            launchButton,
            releaseButton,
            terminateButton,
            statusLabel
        ], in: .top)
        view.orientation = .vertical
        view.alignment = .width
        view.spacing = 8
        view.translatesAutoresizingMaskIntoConstraints = false
        apply(AgentCommandDefinition.builtInExamples[0])
        update(isProcessRunning: false, hasLauncherAssertion: false)
    }

    private func currentCommand() throws -> AgentCommandDefinition {
        let executable = executableField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !executable.isEmpty else {
            throw AgentCommandParseError.emptyExecutable
        }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return AgentCommandDefinition(
            id: name.isEmpty ? UUID().uuidString : name,
            name: name.isEmpty ? executable : name,
            executable: executable,
            arguments: try AgentCommandParser.tokenizeArguments(argumentsField.stringValue),
            workingDirectory: workingDirectoryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            environment: try AgentCommandParser.parseEnvironment(environmentField.stringValue)
        )
    }

    private func apply(_ command: AgentCommandDefinition) {
        nameField.stringValue = command.name
        executableField.stringValue = command.executable
        argumentsField.stringValue = command.arguments.joined(separator: " ")
        workingDirectoryField.stringValue = command.workingDirectory
        environmentField.stringValue = command.environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
    }

}
