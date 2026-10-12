import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons // qmllint disable import
import qs.Ui // qmllint disable import
import "Model.js" as Model

// Omarchy Assistant window. Ask -> the engine investigates read-only and
// returns a proposal -> you see the explanation and the exact diff -> Apply
// (backed up, validated, reverted on failure) or Discard -> Undo any time.
//
// Kept loaded, so a request keeps running while the window is hidden.
// Every Text is PlainText: AI output and file contents are never markup.
Item {
    id: root

    property var shell: null
    property var manifest: null
    readonly property string pluginId: String((root.manifest && root.manifest.id) || "io.github.jburchel.omarchy-assistant")
    readonly property string engine: decodeURIComponent(Qt.resolvedUrl("bin/omarchy-assistant").toString().replace(/^file:\/\//, ""))

    property bool opened: false

    SettingsStore {
        id: store
        shell: root.shell
        pluginId: root.pluginId
    }

    // idle | asking | proposal | applying | applied | reverted | undone | error
    property string phase: "idle"
    property string request: ""
    property var statusLines: []
    property var proposal: null
    property var preview: null
    property string proposalFile: ""
    property string message: ""          // result or error text under the proposal
    property var problems: []
    property bool canForceUndo: false
    property var backends: []
    property bool hasUndo: false
    property string keyState: "free"

    readonly property string backendId: {
        var want = store.values.backend;
        for (var i = 0; i < root.backends.length; i++)
            if (root.backends[i].id === want) return want;
        return root.backends.length ? root.backends[0].id : "";
    }

    readonly property var examples: [
        "Make the gaps between windows smaller",
        "Why is my second monitor black?",
        "Add a key to open a terminal in floating mode",
        "Switch to the Tokyo Night theme"
    ]

    function open(payloadJson) {
        root.opened = true;
        backendsProc.running = true;
        historyProc.running = true;
        keyProc.running = true;
        var payload = {};
        try { payload = JSON.parse(payloadJson || "{}"); } catch (e) {}
        if (payload.ask) {
            input.text = String(payload.ask);
            root.ask();
        }
        Qt.callLater(function() { input.forceActiveFocus(); });
    }

    function close() {
        root.opened = false;
    }

    function dismiss() {
        root.opened = false;
        if (root.shell && typeof root.shell.hide === "function")
            root.shell.hide(root.pluginId);
    }

    function ask() {
        var text = input.text.trim();
        if (text === "" || root.phase === "asking" || root.phase === "applying") return;
        root.request = text;
        root.statusLines = [];
        root.proposal = null;
        root.preview = null;
        root.proposalFile = "";
        root.message = "";
        root.problems = [];
        root.phase = "asking";
        input.text = "";
        askProc.command = [root.engine, "ask", "--backend", root.backendId, text];
        askProc.running = true;
    }

    function handleEvent(line) {
        var ev;
        try { ev = JSON.parse(line); } catch (e) { return; }
        if (ev.type === "status") {
            var lines = root.statusLines.slice();
            lines.push(String(ev.text));
            root.statusLines = lines.slice(-6);
        } else if (ev.type === "error") {
            root.message = String(ev.text);
            root.phase = "error";
        } else if (ev.type === "done") {
            root.proposal = ev.proposal;
            root.preview = ev.preview;
            root.proposalFile = String(ev.proposalFile || "");
            root.problems = (ev.preview && ev.preview.problems) || [];
            root.phase = "proposal";
        }
    }

    function apply() {
        if (!root.proposalFile || root.phase !== "proposal") return;
        root.phase = "applying";
        applyProc.command = [root.engine, "apply", root.proposalFile];
        applyProc.running = true;
    }

    function discard() {
        root.phase = "idle";
        root.proposal = null;
        root.preview = null;
        root.request = "";
        Qt.callLater(function() { input.forceActiveFocus(); });
    }

    function undo(force) {
        undoProc.command = force ? [root.engine, "undo", "last", "--force"] : [root.engine, "undo", "last"];
        undoProc.running = true;
    }

    Process {
        id: askProc
        stdout: SplitParser { onRead: function(line) { root.handleEvent(line); } }
        onExited: function(code) {
            if (root.phase === "asking") {
                root.message = "The assistant stopped without an answer (exit " + code + ").";
                root.phase = "error";
            }
        }
    }

    Process {
        id: applyProc
        stdout: StdioCollector {
            onStreamFinished: {
                var r = {};
                try { r = JSON.parse(String(text)); } catch (e) {}
                if (r.ok) {
                    root.phase = "applied";
                    root.message = "Done. Backed up first; Undo puts it back.";
                } else {
                    root.phase = r.reverted ? "reverted" : "proposal";
                    root.problems = r.problems || ["The change could not be applied."];
                    root.message = r.reverted ? "That change broke the config check, so everything was put back as it was." : "";
                }
                historyProc.running = true;
            }
        }
    }

    Process {
        id: undoProc
        stdout: StdioCollector {
            onStreamFinished: {
                var r = {};
                try { r = JSON.parse(String(text)); } catch (e) {}
                root.canForceUndo = !r.ok && r.canForce === true;
                root.problems = r.ok ? [] : (r.problems || []);
                if (r.ok) {
                    root.phase = "undone";
                    root.message = "Undone: " + (r.summary || "the last change") + ".";
                } else {
                    root.message = "Couldn't undo.";
                }
                historyProc.running = true;
            }
        }
    }

    Process {
        id: backendsProc
        command: [root.engine, "backends"]
        stdout: StdioCollector {
            onStreamFinished: { try { root.backends = JSON.parse(String(text)); } catch (e) {} }
        }
    }

    Process {
        id: historyProc
        command: [root.engine, "history"]
        stdout: StdioCollector {
            onStreamFinished: {
                var h = [];
                try { h = JSON.parse(String(text)); } catch (e) {}
                root.hasUndo = h.some(function(x) { return x.status === "applied"; });
            }
        }
    }

    Process {
        id: keyProc
        command: ["hyprctl", "binds", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                var binds = [];
                try { binds = JSON.parse(String(text)); } catch (e) {}
                root.keyState = Model.keyTaken(binds) ? "taken" : (Model.keyRegistered(binds) ? "ours" : "free");
            }
        }
    }

    readonly property color fg: Color.menu.text
    readonly property color dim: Qt.rgba(fg.r, fg.g, fg.b, 0.6)

    PanelWindow { // qmllint disable uncreatable-type
        visible: root.opened
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "omarchy-assistant"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

        Rectangle { anchors.fill: parent; color: Color.menu.scrim }
        MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

        BorderSurface {
            id: card
            anchors.centerIn: parent
            width: Math.min(Style.space(900), parent.width - Style.space(120))
            height: Math.min(parent.height * 0.82, layout.implicitHeight + card.contentTopInset + card.contentBottomInset)
            radius: Style.cornerRadius
            color: Color.menu.background
            borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
            padding: Style.spacing.panelPadding

            MouseArea { anchors.fill: parent }

            Keys.onEscapePressed: root.dismiss()

            Column {
                id: layout
                x: card.contentLeftInset
                y: card.contentTopInset
                width: card.width - card.contentLeftInset - card.contentRightInset
                spacing: Style.spacing.md

                // ---- header
                Item {
                    width: parent.width
                    height: Math.max(title.implicitHeight, headerButtons.implicitHeight)
                    Text {
                        id: title
                        anchors.verticalCenter: parent.verticalCenter
                        textFormat: Text.PlainText
                        text: "Omarchy Assistant"
                        color: root.fg
                        font.family: Style.font.menuFamily
                        font.pixelSize: Style.font.heading
                        font.bold: true
                    }
                    Row {
                        id: headerButtons
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.spacing.sm
                        ButtonGroup {
                            visible: root.backends.length > 1
                            focusable: false
                            options: root.backends.map(function(b) { return { value: b.id, label: b.name }; })
                            value: root.backendId
                            fontFamily: Style.font.menuFamily
                            fontSize: Style.font.caption
                            onChanged: function(value) { store.set("backend", value); }
                        }
                        Button {
                            visible: root.hasUndo
                            text: "Undo last change"
                            bordered: true
                            fontSize: Style.font.caption
                            onClicked: root.undo(false)
                        }
                    }
                }

                // ---- one-time keybinding offer
                Rectangle {
                    visible: store.values.keybinding === "ask" && root.keyState === "free"
                    width: parent.width
                    height: visible ? offer.implicitHeight + Style.spacing.md * 2 : 0
                    radius: Style.cornerRadius
                    color: Color.menu.selectedBackground
                    Row {
                        id: offer
                        anchors.verticalCenter: parent.verticalCenter
                        x: Style.spacing.md
                        spacing: Style.spacing.md
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            textFormat: Text.PlainText
                            text: "Open the assistant with " + "Super+Alt+A" + "?"
                            color: root.fg
                            font.family: Style.font.menuFamily
                            font.pixelSize: Style.font.bodySmall
                        }
                        Button { text: "Use Super+Alt+A"; bordered: true; fontSize: Style.font.caption; onClicked: store.set("keybinding", "on") }
                        Button { text: "No thanks"; fontSize: Style.font.caption; onClicked: store.set("keybinding", "off") }
                    }
                }

                // ---- conversation
                Flickable {
                    id: scroller
                    width: parent.width
                    height: Math.min(convo.implicitHeight, Math.max(Style.space(120), card.parentHeight() - Style.space(260)))
                    contentHeight: convo.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    onContentHeightChanged: if (root.phase === "asking") contentY = Math.max(0, contentHeight - height)

                    Column {
                        id: convo
                        width: scroller.width
                        spacing: Style.spacing.md

                        // Intro, before anything is asked
                        Column {
                            visible: root.phase === "idle" && root.request === ""
                            width: parent.width
                            spacing: Style.spacing.sm
                            Text {
                                width: parent.width
                                wrapMode: Text.Wrap
                                textFormat: Text.PlainText
                                text: root.backends.length
                                    ? "Tell it what you want changed, or what's wrong. It looks at your setup, shows you exactly what it would change, and changes nothing until you press Apply. Every change can be undone."
                                    : "No AI tool found. Install and sign in to Claude Code (claude) or Codex (codex); the assistant uses your own account."
                                color: root.dim
                                font.family: Style.font.menuFamily
                                font.pixelSize: Style.font.bodySmall
                            }
                            Flow {
                                width: parent.width
                                spacing: Style.spacing.sm
                                Repeater {
                                    model: root.backends.length ? root.examples : []
                                    Button {
                                        required property string modelData
                                        text: modelData
                                        bordered: true
                                        fontSize: Style.font.caption
                                        onClicked: { input.text = modelData; input.forceActiveFocus(); }
                                    }
                                }
                            }
                        }

                        // The request
                        Text {
                            visible: root.request !== ""
                            width: parent.width
                            wrapMode: Text.Wrap
                            textFormat: Text.PlainText
                            text: "› " + root.request
                            color: root.fg
                            font.family: Style.font.menuFamily
                            font.pixelSize: Style.font.body
                            font.bold: true
                        }

                        // Progress while it looks around
                        Repeater {
                            model: root.phase === "asking" ? root.statusLines : []
                            Text {
                                required property string modelData
                                required property int index
                                width: convo.width
                                elide: Text.ElideRight
                                textFormat: Text.PlainText
                                text: (index === root.statusLines.length - 1 ? "… " : "  ") + modelData
                                color: root.dim
                                font.family: Style.font.menuFamily
                                font.pixelSize: Style.font.caption
                            }
                        }

                        // The answer
                        Text {
                            visible: root.proposal !== null && String(root.proposal.answer || "") !== ""
                            width: parent.width
                            wrapMode: Text.Wrap
                            textFormat: Text.PlainText
                            text: root.proposal ? String(root.proposal.answer || "") : ""
                            color: root.fg
                            font.family: Style.font.menuFamily
                            font.pixelSize: Style.font.bodySmall
                            lineHeight: 1.15
                        }

                        // The change, file by file
                        Repeater {
                            model: root.preview ? root.preview.files : []
                            Column {
                                id: fileBlock
                                required property var modelData
                                width: convo.width
                                spacing: 0
                                Text {
                                    textFormat: Text.PlainText
                                    text: (fileBlock.modelData.created ? "New file  " : "") + fileBlock.modelData.path
                                    color: Color.accent
                                    font.family: Style.font.family
                                    font.pixelSize: Style.font.caption
                                    bottomPadding: Style.spacing.xxs
                                }
                                Rectangle {
                                    width: parent.width
                                    height: diffCol.implicitHeight + Style.spacing.sm * 2
                                    radius: Style.cornerRadius
                                    color: Qt.rgba(0, 0, 0, 0.22)
                                    Column {
                                        id: diffCol
                                        x: Style.spacing.sm
                                        y: Style.spacing.sm
                                        width: parent.width - Style.spacing.sm * 2
                                        Repeater {
                                            model: String(fileBlock.modelData.diff || "").split("\n").filter(function(l) {
                                                return l !== "" && Model.diffKind(l) !== "skip";
                                            })
                                            Text {
                                                required property string modelData
                                                readonly property string kind: Model.diffKind(modelData)
                                                width: diffCol.width
                                                wrapMode: Text.WrapAnywhere
                                                textFormat: Text.PlainText
                                                text: modelData
                                                color: kind === "add" ? Color.accent : (kind === "del" ? Color.urgent : root.dim)
                                                font.family: Style.font.family
                                                font.pixelSize: Style.font.caption
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        Text {
                            visible: root.preview !== null && root.preview.commands.length > 0
                            width: parent.width
                            wrapMode: Text.Wrap
                            textFormat: Text.PlainText
                            text: root.preview ? "Then runs:  " + root.preview.commands.join("   ·   ") : ""
                            color: root.dim
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                        }

                        Repeater {
                            model: root.problems
                            Text {
                                required property string modelData
                                width: convo.width
                                wrapMode: Text.Wrap
                                textFormat: Text.PlainText
                                text: "⚠ " + modelData
                                color: Color.urgent
                                font.family: Style.font.menuFamily
                                font.pixelSize: Style.font.caption
                            }
                        }

                        Text {
                            visible: root.message !== ""
                            width: parent.width
                            wrapMode: Text.Wrap
                            textFormat: Text.PlainText
                            text: root.message
                            color: root.phase === "error" || root.phase === "reverted" ? Color.urgent : Color.accent
                            font.family: Style.font.menuFamily
                            font.pixelSize: Style.font.bodySmall
                        }
                    }
                }

                // ---- actions for the proposal
                Row {
                    visible: (root.phase === "proposal" && root.preview && root.preview.canApply) || root.phase === "applied" || root.canForceUndo
                    spacing: Style.spacing.sm
                    Button {
                        visible: root.phase === "proposal"
                        text: "Apply"
                        bordered: true
                        active: true
                        onClicked: root.apply()
                    }
                    Button {
                        visible: root.phase === "proposal"
                        text: "Discard"
                        onClicked: root.discard()
                    }
                    Button {
                        visible: root.phase === "applied"
                        text: "Undo"
                        bordered: true
                        onClicked: root.undo(false)
                    }
                    Button {
                        visible: root.canForceUndo
                        text: "Undo anyway"
                        onClicked: root.undo(true)
                    }
                }

                // ---- input
                TextField {
                    id: input
                    width: parent.width
                    enabled: root.backends.length > 0
                    placeholderText: root.phase === "asking" ? "Working on it…" : "Describe what you want changed, or what's wrong"
                    font.family: Style.font.menuFamily
                    focus: true
                    onAccepted: root.ask()
                    Keys.onEscapePressed: root.dismiss()
                    Keys.onPressed: function(event) {
                        var ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
                        if (ctrl && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && root.phase === "proposal" && root.preview && root.preview.canApply) {
                            root.apply();
                            event.accepted = true;
                        } else if (ctrl && event.key === Qt.Key_Z && (root.hasUndo || root.phase === "applied")) {
                            root.undo(false);
                            event.accepted = true;
                        }
                    }
                }

                Text {
                    textFormat: Text.PlainText
                    text: "enter  ask   ·   ctrl+enter  apply   ·   ctrl+z  undo   ·   esc  close (a running request keeps going)"
                    color: root.dim
                    opacity: 0.7
                    font.family: Style.font.menuFamily
                    font.pixelSize: Style.font.caption
                }
            }

            function parentHeight() { return card.parent ? card.parent.height * 0.82 : Style.space(700); }
        }
    }
}
