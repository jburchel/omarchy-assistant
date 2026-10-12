import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Reads this plugin's entry from shell.json (third-party plugins are not
// handed the shell config, so watch the file) and writes changes back through
// the shell's updateEntryInline, which owns the file.
Item {
    id: store

    property var shell: null
    property string pluginId: ""

    property var raw: ({})
    readonly property var values: Model.normalize(store.raw)

    function set(key, value) {
        var next = {};
        var current = store.values;
        for (var k in current)
            next[k] = current[k];
        next[key] = value;
        store.raw = next;
        if (store.shell && typeof store.shell.updateEntryInline === "function")
            store.shell.updateEntryInline(store.pluginId, next);
    }

    function load(text) {
        try {
            store.raw = Model.entryFromConfig(JSON.parse(text), store.pluginId) || {};
        } catch (e) {
            // Mid-write or hand-edited into invalid JSON: keep the last good values.
        }
    }

    FileView {
        path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: store.load(text())
    }
}
