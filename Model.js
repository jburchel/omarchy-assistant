.pragma library

// Settings live in this plugin's entry of ~/.config/omarchy/shell.json.
//   keybinding: "ask" (not decided yet) | "on" | "off"
//   backend:    "auto" | "claude" | "codex"

var KEY_COMBO = "SUPER + ALT + A";
var KEY_LABEL = "Super+Alt+A";
var KEY_MODMASK = 72;      // SUPER (64) + ALT (8)
var KEY_NAME = "A";

function normalize(raw) {
    var e = raw && typeof raw === "object" ? raw : {};
    var kb = e.keybinding === "on" || e.keybinding === "off" ? e.keybinding : "ask";
    var be = e.backend === "claude" || e.backend === "codex" ? e.backend : "auto";
    return { keybinding: kb, backend: be };
}

function entryFromConfig(config, pluginId) {
    // The shell saves a plugin's settings into its bar entry when it has a bar
    // widget on the bar, otherwise into the top-level "plugins" list. Read both;
    // the bar entry wins.
    var found = null;
    var plugins = config && Array.isArray(config.plugins) ? config.plugins : [];
    for (var i = 0; i < plugins.length; i++)
        if (plugins[i] && String(plugins[i].id || "") === pluginId)
            found = plugins[i];
    var layout = config && config.bar && config.bar.layout ? config.bar.layout : {};
    ["left", "center", "right"].forEach(function(section) {
        var list = Array.isArray(layout[section]) ? layout[section] : [];
        for (var j = 0; j < list.length; j++)
            if (list[j] && String(list[j].id || "") === pluginId) {
                var merged = {};
                var k;
                for (k in (found || {})) merged[k] = found[k];
                for (k in list[j]) merged[k] = list[j][k];
                found = merged;
            }
    });
    return found;
}

// Is SUPER+ALT+A already taken by someone else's binding? `binds` is the
// parsed output of `hyprctl binds -j`; ours carries our description.
function keyTaken(binds) {
    for (var i = 0; i < (binds || []).length; i++) {
        var b = binds[i];
        if (b && b.modmask === KEY_MODMASK && String(b.key).toUpperCase() === KEY_NAME
                && String(b.description || "") !== "Omarchy Assistant")
            return true;
    }
    return false;
}

function keyRegistered(binds) {
    for (var i = 0; i < (binds || []).length; i++) {
        var b = binds[i];
        if (b && b.modmask === KEY_MODMASK && String(b.key).toUpperCase() === KEY_NAME
                && String(b.description || "") === "Omarchy Assistant")
            return true;
    }
    return false;
}

// One line of a unified diff -> how to draw it.
function diffKind(line) {
    if (line.indexOf("+++") === 0 || line.indexOf("---") === 0) return "skip";
    if (line.indexOf("@@") === 0) return "hunk";
    if (line.charAt(0) === "+") return "add";
    if (line.charAt(0) === "-") return "del";
    return "ctx";
}

if (typeof module !== "undefined")
    module.exports = { KEY_COMBO: KEY_COMBO, normalize: normalize, entryFromConfig: entryFromConfig,
                       keyTaken: keyTaken, keyRegistered: keyRegistered, diffKind: diffKind };
