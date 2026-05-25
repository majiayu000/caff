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
            field.controlSize = .small
        }
        nameField.placeholderString = "Name"
        executableField.placeholderString = "Executable, e.g. codex"
        argumentsField.placeholderString = "Arguments, e.g. --help"
        workingDirectoryField.placeholderString = "~/Desktop/code/project"
        environmentField.placeholderString = "KEY=value, OTHER=value"
        AppLabelStyle.configureSecondary(statusLabel)
        commandPopup.controlSize = .small
        launchButton.target = self
        launchButton.action = #selector(launchSelectedCommand)
        releaseButton.target = self
        releaseButton.action = #selector(releaseAssertionOnly)
        terminateButton.target = self
        terminateButton.action = #selector(terminateCommand)
        for button in [launchButton, releaseButton, terminateButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
        }
        launchButton.keyEquivalent = "\r"
        launchButton.bezelColor = CaffPanelStyle.accent
        launchButton.contentTintColor = .white

        statusLabel.alignment = .left

        let formRows = [
            formRow("Preset", control: commandPopup),
            formRow("Name", control: nameField),
            formRow("Executable", control: executableField),
            formRow("Arguments", control: argumentsField),
            formRow("Directory", control: workingDirectoryField),
            formRow("Env", control: environmentField)
        ]
        let form = NSStackView(views: formRows)
        form.orientation = .vertical
        form.alignment = .width
        form.spacing = 8

        let actionRow = NSStackView(views: [launchButton, releaseButton, terminateButton])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.distribution = .fillEqually
        actionRow.spacing = 8

        let formContainer = insetView(form, top: 14, bottom: 8)
        let actionContainer = insetView(actionRow, top: 8, bottom: 8)
        let statusContainer = insetView(statusLabel, top: 0, bottom: 14)
        view.setViews([formContainer, actionContainer, statusContainer], in: .top)
        view.orientation = .vertical
        view.alignment = .width
        view.spacing = 0
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate(formRows.map { $0.widthAnchor.constraint(equalTo: form.widthAnchor) })
        NSLayoutConstraint.activate([
            formContainer.widthAnchor.constraint(equalTo: view.widthAnchor),
            actionContainer.widthAnchor.constraint(equalTo: view.widthAnchor),
            statusContainer.widthAnchor.constraint(equalTo: view.widthAnchor)
        ])
        apply(AgentCommandDefinition.builtInExamples[0])
        update(isProcessRunning: false, hasLauncherAssertion: false)
    }

    private func insetView(_ content: NSView, top: CGFloat, bottom: CGFloat) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: top),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -bottom)
        ])
        return container
    }

    private func formRow(_ title: String, control: NSView) -> NSStackView {
        let label = fieldLabel(title)
        label.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 10
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(equalToConstant: 82)
        ])
        return row
    }

    private func fieldLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        AppLabelStyle.configureFieldLabel(label)
        return label
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
