import QtQuick
import Quickshell
import qs.Ui // qmllint disable import

// Omarchy Assistant bar icon: click to open the assistant window.
BarWidget {
    id: root
    moduleName: "io.github.jburchel.omarchy-assistant"

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: "\u{F0674}"   // nf-md-creation: sparkles
        tooltipText: "Omarchy Assistant: describe a change or a problem"
        onPressed: function(b) { if (root.bar) root.bar.run("omarchy-shell omarchy-assistant toggle"); }
    }
}
