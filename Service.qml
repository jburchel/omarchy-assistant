import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "Model.js" as Model

// Omarchy Assistant service: the IPC target and the optional SUPER+ALT+A key.
//
// Plugins can't ship keybindings, so the key is registered at runtime with
// `hyprctl eval`, only after the person says yes in the assistant window
// (keybinding = "on" in this plugin's shell.json entry), never over a key
// something else already uses, and again after every Hyprland config reload
// (a reload drops runtime bindings). Nothing is written to Hyprland config.
//
// IPC: omarchy-shell omarchy-assistant toggle | open | close | ask <text> | keybinding on|off
Item {
    id: root

    property var shell: null
    property var manifest: null
    readonly property string pluginId: String((root.manifest && root.manifest.id) || "io.github.jburchel.omarchy-assistant")

    SettingsStore {
        id: store
        shell: root.shell
        pluginId: root.pluginId
    }
    readonly property string keybinding: store.values.keybinding
    onKeybindingChanged: syncKey.restart()

    // "free" | "ours" | "taken" (by another binding)
    property string keyState: "free"

    // Open (never close) the assistant window, passing it an optional payload.
    function show(payload) {
        return root.shell && typeof root.shell.summon === "function"
            && root.shell.summon(root.pluginId, payload || "{}") !== false;
    }

    Timer {
        id: syncKey
        interval: 600
        onTriggered: bindsProc.running = true
    }

    Process {
        id: bindsProc
        command: ["hyprctl", "binds", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                var binds = [];
                try { binds = JSON.parse(String(text)); } catch (e) { return; }
                if (Model.keyTaken(binds)) {
                    root.keyState = "taken";
                    return;
                }
                var ours = Model.keyRegistered(binds);
                if (root.keybinding === "on" && !ours) {
                    bindProc.command = ["hyprctl", "eval",
                        'o.bind("' + Model.KEY_COMBO + '", "Omarchy Assistant", "omarchy-shell omarchy-assistant toggle")'];
                    bindProc.running = true;
                    root.keyState = "ours";
                } else if (root.keybinding !== "on" && ours) {
                    bindProc.command = ["hyprctl", "eval", 'hl.unbind("' + Model.KEY_COMBO + '")'];
                    bindProc.running = true;
                    root.keyState = "free";
                } else {
                    root.keyState = ours ? "ours" : "free";
                }
            }
        }
    }
    Process { id: bindProc }

    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event && String(event.name) === "configreloaded")
                syncKey.restart();
        }
    }

    Component.onCompleted: syncKey.restart()

    IpcHandler {
        target: "omarchy-assistant"
        function toggle(): string {
            return root.shell && root.shell.toggle(root.pluginId, "{}") ? "ok" : "unavailable";
        }
        function open(): string {
            return root.show("{}") ? "ok" : "unavailable";
        }
        function close(): string {
            if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId);
            return "ok";
        }
        function ask(text: string): string {
            return root.show(JSON.stringify({ ask: text })) ? "ok" : "unavailable";
        }
        function keybinding(value: string): string {
            if (value !== "on" && value !== "off") return "expected on or off";
            store.set("keybinding", value);
            return value;
        }
        function keyState(): string {
            return root.keyState;
        }
    }
}
