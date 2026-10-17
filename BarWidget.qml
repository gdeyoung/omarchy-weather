import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar entry for gdeyoung.weather: weather icon + current temperature for the
// DEVICE location ("here"). Left click opens the tabbed panel (here + pinned
// locations); right click cycles the label mode. Data flows through per-
// location state files written by fetchKey() — the render path never touches
// the network, so bar label and panel can never disagree.
BarWidget {
  id: root

  moduleName: "gdeyoung.weather"

  property var anchorItem: null
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property var settingsView: root.settings || {}
  readonly property string barExtra: settingsView.barExtra || "temp"
  readonly property string units: settingsView.units || "imperial"
  readonly property int refreshMin: Math.max(5, parseInt(settingsView.refreshMin, 10) || 15)
  readonly property var pinned: Model.parsePinned(settingsView.pinnedLocations || Model.DEFAULT_PINNED)
  readonly property string stateDir: Quickshell.env("HOME") + "/" + Model.STATE_DIR

  // ---- device location ---------------------------------------------------

  property var omarchyLocation: null

  FileView {
    id: omarchyLocationView
    path: Quickshell.env("HOME") + "/" + Model.OMARCHY_LOCATION
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      root.omarchyLocation = root.parseState(text())
      root.fetchKey("here")
    }
    onLoadFailed: root.omarchyLocation = null
  }

  function parseState(txt) {
    try {
      return txt ? JSON.parse(txt) : null;
    } catch (e) {
      return null;
    }
  }

  // "here" resolves to stored lat,lon; a stored name geocodes first; with no
  // configured location the widget stays a placeholder (no fake data).
  function hereLatLon() {
    var loc = omarchyLocation;
    if (!loc)
      return null;
    if (loc.latitude !== undefined && loc.longitude !== undefined
        && isFinite(Number(loc.latitude)) && isFinite(Number(loc.longitude)))
      return [Number(loc.latitude), Number(loc.longitude)];
    var name = typeof loc === "string" ? loc : loc.name;
    return name ? { name: String(name) } : null;
  }

  // ---- per-location state files (file bus) -------------------------------

  property var wxData: null // "here" data — drives the bar label

  FileView {
    id: hereView
    path: root.stateDir + "/here.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.wxData = root.parseState(text())
    onLoadFailed: root.wxData = null
  }

  function stateFile(key) {
    return stateDir + "/" + key + ".json";
  }

  // One bash pipeline per location: open-meteo forecast + air quality merged
  // into <key>.json with a fetchedAt stamp. Atomic via tmp+mv.
  function fetchKey(key, lat, lon) {
    if (key === "here") {
      var ll = hereLatLon();
      if (!ll)
        return;
      if (Object.prototype.toString.call(ll) === "[object Array]") {
        lat = ll[0];
        lon = ll[1];
      } else {
        geocodeThenFetch(ll.name, key);
        return;
      }
    }
    if (lat === undefined || lon === undefined || String(lat) === "" || String(lon) === "")
      return;
    var fUrl = Model.buildForecastUrl(lat, lon, units);
    var aUrl = Model.buildAirUrl(lat, lon);
    var file = stateFile(key);
    var stamp = new Date().toISOString();
    fetchProc.command = [
      "bash",
      "-c",
      "mkdir -p " + JSON.stringify(stateDir) +
        " ; f=$(curl -fsS --max-time 10 " + JSON.stringify(fUrl) + ") || exit 0" +
        " ; a=$(curl -fsS --max-time 10 " + JSON.stringify(aUrl) + " | jq '.current // {}' 2>/dev/null || echo '{}')" +
        " ; jq -n --argjson f \"$f\" --argjson a \"$a\" --arg s " + JSON.stringify(stamp) +
        " '{forecast: $f, air: $a, fetchedAt: $s}' > " + JSON.stringify(file + ".tmp") +
        " && mv " + JSON.stringify(file + ".tmp") + " " + JSON.stringify(file)
    ];
    fetchProc.running = true;
  }

  property string pendingGeocodeKey: ""

  function geocodeThenFetch(name, key) {
    geocodeProc.command = ["bash", "-c",
      "curl -fsS --max-time 8 " + JSON.stringify(Model.buildGeocodeUrl(name)) +
        " | jq -c '{lat: .results[0].latitude, lon: .results[0].longitude}'"];
    geocodeProc.running = true;
    pendingGeocodeKey = key;
  }

  Process {
    id: fetchProc
    stdout: StdioCollector {}
    stderr: StdioCollector {}
  }

  Process {
    id: geocodeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var p = root.parseState(String(text));
        if (p && p.lat !== undefined && root.pendingGeocodeKey !== "")
          root.fetchKey(root.pendingGeocodeKey, p.lat, p.lon);
      }
    }
    stderr: StdioCollector {}
  }

  Timer {
    id: refreshTimer
    interval: root.refreshMin * 60000
    running: true
    repeat: true
    onTriggered: root.fetchKey("here")
  }

  Component.onCompleted: {
    omarchyLocationView.reload();
    hereView.reload();
    // Cold start or cache older than one interval: refresh now; stale data
    // renders meanwhile.
    var stale = true;
    if (root.wxData && root.wxData.fetchedAt) {
      var age = Date.now() - new Date(root.wxData.fetchedAt).getTime();
      stale = !(age >= 0 && age < root.refreshMin * 60000);
    }
    if (stale)
      root.fetchKey("here");
  }

  // ---- label -------------------------------------------------------------

  readonly property var cur: wxData && wxData.forecast ? wxData.forecast.current : null
  readonly property string label: Model.barLabel(barExtra, wxData && wxData.forecast ? wxData.forecast : null)
  readonly property string iconGlyph: cur
    ? Model.glyph(cur.weather_code, cur.is_day === 0 || cur.is_day === false)
    : "🌡️"

  // ---- panel -------------------------------------------------------------

  function injectPanel() {
    var target = panelLoader.item;
    if (!target)
      return;
    if ("bar" in target)
      target.bar = root.bar;
    if ("settings" in target)
      target.settings = root.settings;
    if ("anchorItem" in target)
      target.anchorItem = button;
    if ("hostWidget" in target)
      target.hostWidget = root;
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle)
      panelLoader.item.toggle();
  }

  function cycleBarMode() {
    if (typeof root.setSetting === "function")
      root.setSetting("barExtra", Model.nextBarMode(barExtra));
  }

  Loader {
    id: panelLoader
    source: "Panel.qml"
    active: true
    onLoaded: root.injectPanel()
  }

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  visible: true
  implicitWidth: buttonRow.implicitWidth + 8
  implicitHeight: bar && bar.contentHeight !== undefined ? bar.contentHeight : 24

  Row {
    id: buttonRow
    anchors.centerIn: parent
    spacing: 5

    Text {
      text: root.iconGlyph
      font.family: root.fontFamily
      font.pixelSize: Style.font.iconLarge
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      text: root.label
      visible: root.label !== ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  MouseArea {
    id: button
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onClicked: mouse => {
      if (mouse.button === Qt.RightButton)
        root.cycleBarMode();
      else
        root.togglePanel();
    }
  }
}
