import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The gdeyoung.weather enlarged dropdown — tabbed: [Here] + pinned locations
// + [+]. "Here" follows the device location and is what the bar shows; every
// tab renders the full panel (hero, details + level bars, remaining-hours
// strip, 7-day, sun, radar link) from its own cached state file. The [+]
// button searches cities via Open-Meteo geocoding and pins them into plugin
// settings, so tabs survive shell restarts (shell.json backup).
Panel {
  id: root

  moduleName: "gdeyoung.weather"
  ipcTarget: "gdeyoung.weather"
  manageIpc: true

  onOpenedChanged: {
    if (opened) {
      activeKey = "here";
      tabView.reload();
      maybeRefreshActive();
    }
  }

  property var anchorItem: null
  property var hostWidget: null

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property var settingsView: settings || {}
  readonly property string units: settingsView.units || "imperial"
  readonly property var pinned: Model.parsePinned(settingsView.pinnedLocations || Model.DEFAULT_PINNED)
  readonly property var omarchyLocation: hostWidget && hostWidget.omarchyLocation !== undefined ? hostWidget.omarchyLocation : null
  readonly property string stateDir: Quickshell.env("HOME") + "/" + Model.STATE_DIR

  // tabs: here first, then pinned
  readonly property var tabs: {
    var t = [{ key: "here", name: Model.locationName(omarchyLocation, "Here"), pinned: false }];
    for (var i = 0; i < pinned.length; i++)
      t.push({ key: pinned[i].key, name: pinned[i].name, pinned: true, lat: pinned[i].lat, lon: pinned[i].lon });
    return t;
  }
  property string activeKey: "here"
  readonly property var activeTab: {
    for (var i = 0; i < tabs.length; i++)
      if (tabs[i].key === activeKey)
        return tabs[i];
    return tabs[0];
  }

  // ---- active tab data (its own file) ------------------------------------

  property var tabData: null

  FileView {
    id: tabView
    path: root.stateDir + "/" + root.activeKey + ".json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.tabData = root.hostWidget ? root.hostWidget.parseState(text()) : root.parseTab(text())
    onLoadFailed: root.tabData = null
  }

  function parseTab(txt) {
    try {
      return txt ? JSON.parse(txt) : null;
    } catch (e) {
      return null;
    }
  }

  onActiveKeyChanged: {
    tabView.reload();
    maybeRefreshActive();
  }

  function maybeRefreshActive() {
    if (!hostWidget || typeof hostWidget.fetchKey !== "function")
      return;
    var t = activeTab;
    if (!t)
      return;
    var stale = true;
    if (tabData && tabData.fetchedAt) {
      var age = Date.now() - new Date(tabData.fetchedAt).getTime();
      stale = !(age >= 0 && age < 15 * 60000);
    }
    if (stale)
      hostWidget.fetchKey(t.key, t.lat, t.lon);
  }

  readonly property var j: tabData && tabData.forecast ? tabData.forecast : null
  readonly property var air: tabData && tabData.air ? tabData.air : null
  readonly property var cur: j ? j.current : null
  readonly property var daily: j && j.daily ? j.daily : null
  readonly property string todayStr: new Date().toISOString().slice(0, 10)
  readonly property var hours: Model.remainingHours(j, 12)
  readonly property string heroIcon: cur
    ? Model.glyph(cur.weather_code, cur.is_day === 0 || cur.is_day === false)
    : "🌡️"

  function muted(alpha) {
    return Qt.rgba(foreground.r, foreground.g, foreground.b, alpha === undefined ? 0.55 : alpha);
  }

  // Scriptable tab switching (also used for automated verification).
  IpcHandler {
    target: "gdeyoung.weather.tab"
    function switchTab(key: string): void {
      for (var i = 0; i < root.tabs.length; i++) {
        if (root.tabs[i].key === key) {
          root.activeKey = key;
          return;
        }
      }
    }
  }

  // ---- geocode search (the [+] tab) ---------------------------------------

  property bool searching: false
  property string searchText: ""
  property var searchResults: []

  function runSearch() {
    var q = String(searchText || "").trim();
    if (q.length < 2)
      return;
    searchProc.command = ["bash", "-c",
      "curl -fsS --max-time 8 " + JSON.stringify(Model.buildGeocodeUrl(q))
        + " | jq -c '[.results[]? | {name, admin1, country_code, latitude, longitude}]'"];
    searchProc.running = true;
  }

  Process {
    id: searchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.searchResults = JSON.parse(text);
        } catch (e) {
          root.searchResults = [];
        }
      }
    }
    stderr: StdioCollector {}
  }

  function addPinned(place) {
    var list = pinned.slice();
    var name = place.name + (place.admin1 ? " · " + place.admin1 : "");
    list.push({ name: name, lat: place.latitude, lon: place.longitude });
    if (typeof root.setSetting === "function")
      root.setSetting("pinnedLocations", JSON.stringify(list));
    searching = false;
    searchText = "";
    searchResults = [];
    var key = Model.slugify(place.name);
    var lat = place.latitude, lon = place.longitude;
    Qt.callLater(function() {
      root.activeKey = key;
      if (root.hostWidget && typeof root.hostWidget.fetchKey === "function")
        root.hostWidget.fetchKey(key, lat, lon);
    });
  }

  function removePinned(key) {
    var list = pinned.filter(function(p) { return p.key !== key; });
    if (typeof root.setSetting === "function")
      root.setSetting("pinnedLocations", JSON.stringify(list));
    if (activeKey === key)
      activeKey = "here";
  }

  // ---- inline radar (RainViewer frame + dark basemap tiles) ---------------

  // Active-tab coordinates: pinned tab lat/lon, else the device location.
  readonly property var radarLatLon: {
    var t = activeTab;
    if (t && t.lat !== undefined && isFinite(Number(t.lat)))
      return [Number(t.lat), Number(t.lon)];
    if (omarchyLocation && omarchyLocation.latitude !== undefined
      && isFinite(Number(omarchyLocation.latitude)))
      return [Number(omarchyLocation.latitude), Number(omarchyLocation.longitude)];
    return null;
  }

  // 2×2 tile window at zoom 7 (~500 km square) centered on the point.
  readonly property var radarWin: radarLatLon
    ? Model.radarTileWindow(radarLatLon[0], radarLatLon[1], 7, 2, 2)
    : null

  property string radarHost: "https://tilecache.rainviewer.com"
  property string radarFrame: ""
  property real radarFrameTime: 0

  // The frame index is location-independent; only tile coords change per tab.
  function fetchRadar() {
    radarProc.command = ["bash", "-c",
      "curl -fsS --max-time 8 https://api.rainviewer.com/public/weather-maps.json"
        + " | jq -c '{host: .host, path: (.radar.past[-1].path // \"\"), time: (.radar.past[-1].time // 0)}'"];
    radarProc.running = true;
  }

  Process {
    id: radarProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var r = root.parseTab(text);
        if (!r || !r.path)
          return;
        root.radarHost = r.host || root.radarHost;
        root.radarFrame = r.path;
        root.radarFrameTime = Number(r.time) || 0;
      }
    }
    stderr: StdioCollector {}
  }

  // Fetch on open and every 5 min while open (frames update ~10 min).
  Timer {
    interval: 5 * 60000
    running: root.opened && !root.searching
    repeat: true
    triggeredOnStart: true
    onTriggered: root.fetchRadar()
  }

  function openRadarWeb() {
    var ll = radarLatLon;
    if (ll)
      Qt.openUrlExternally(Model.radarUrl(ll[0], ll[1]));
  }

  // =========================================================================

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root  // framework KeyboardPanel.close() needs owner.close(); a
                 // widget-owner without close() makes it assign open=false
                 // statically, severing the open binding on the first
                 // dismiss-overlay close (panel then wedges until reload).
    bar: root.bar
    open: root.opened
    contentWidth: panel.fittedContentWidth(Style.space(600))
    contentHeight: Math.round(panel.fittedContentHeight(column.implicitHeight))

    focusTarget: keyCatcher

    PanelKeyCatcher {
      id: keyCatcher
      onCloseRequested: root.close()
    }

    Flickable {
      id: flick
      anchors.fill: parent
      contentWidth: width
      contentHeight: column.implicitHeight
      clip: true

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.spacing.panelGap

        // ---- tab row ------------------------------------------------------

        Row {
          id: tabBar
          width: parent.width
          spacing: Style.spacing.sm

          Repeater {
            model: root.tabs

            Rectangle {
              id: tabChip
              required property var modelData
              readonly property var tab: modelData
              readonly property bool isActive: root.activeKey === tab.key
              width: chipRow.implicitWidth + 16
              height: 26
              radius: 13
              color: isActive ? root.foreground : "transparent"
              border.width: 1
              border.color: isActive ? root.foreground : root.muted(0.35)

              Row {
                id: chipRow
                anchors.centerIn: parent
                spacing: 4

                Text {
                  text: tabChip.tab ? tabChip.tab.name : ""
                  color: tabChip.isActive ? (root.bar && root.bar.background ? root.bar.background : "#181825") : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body * 0.8
                  font.weight: tabChip.isActive ? Font.DemiBold : Font.Normal
                }

                Text {
                  visible: tabChip.tab && tabChip.tab.pinned && tabChip.isActive
                  text: "✕"
                  color: tabChip.isActive ? (root.bar && root.bar.background ? root.bar.background : "#181825") : root.muted(0.8)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body * 0.8
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (tabChip.tab.pinned && root.activeKey === tabChip.tab.key)
                    root.removePinned(tabChip.tab.key);
                  else
                    root.activeKey = tabChip.tab.key;
                }
              }
            }
          }

          Rectangle {
            width: 26
            height: 26
            radius: 13
            color: root.searching ? root.foreground : "transparent"
            border.width: 1
            border.color: root.searching ? root.foreground : root.muted(0.35)
            visible: !root.searching

            Text {
              anchors.centerIn: parent
              text: "＋"
              color: root.searching ? (root.bar && root.bar.background ? root.bar.background : "#181825") : root.muted(0.8)
              font.family: root.fontFamily
              font.pixelSize: Style.font.body * 0.85
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.searching = true
            }
          }
        }

        // ---- search row ---------------------------------------------------

        Column {
          width: parent.width
          visible: root.searching
          spacing: Style.spacing.sm

          Row {
            width: parent.width
            spacing: Style.spacing.sm

            Rectangle {
              width: parent.width - cancelSearch.implicitWidth - Style.spacing.sm
              height: 30
              radius: 6
              color: root.muted(0.08)
              border.width: 1
              border.color: searchInput.activeFocus ? root.foreground : root.muted(0.25)

              TextInput {
                id: searchInput
                anchors.fill: parent
                anchors.margins: 6
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body * 0.9
                verticalAlignment: TextInput.AlignVCenter
                clip: true
                text: root.searchText
                onTextChanged: root.searchText = text
                onAccepted: root.runSearch()
                Text {
                  visible: !searchInput.text && !searchInput.activeFocus
                  text: "Search city, press Enter…"
                  color: root.muted(0.45)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body * 0.9
                }
              }
            }

            Text {
              id: cancelSearch
              text: "✕ close"
              color: root.muted(0.8)
              font.family: root.fontFamily
              font.pixelSize: Style.font.body * 0.8
              anchors.verticalCenter: parent.verticalCenter

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.searching = false;
                  root.searchText = "";
                  root.searchResults = [];
                }
              }
            }
          }

          Repeater {
            model: root.searchResults

            Rectangle {
              width: parent.width
              height: 30
              radius: 6
              color: resultMouse.containsMouse ? root.muted(0.12) : "transparent"
              required property var modelData
              readonly property var place: modelData

              Row {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: 8
                spacing: 6

                Text {
                  text: place ? place.name : ""
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body * 0.85
                  font.weight: Font.DemiBold
                }
                Text {
                  text: place ? [place.admin1, place.country_code].filter(Boolean).join(" · ") : ""
                  color: root.muted(0.6)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body * 0.8
                }
              }

              MouseArea {
                id: resultMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.addPinned(place)
              }
            }
          }
        }

        // ---- header: place · updated · radar · refresh ---------------------

        Item {
          width: parent.width
          implicitHeight: headerLeft.implicitHeight
          visible: !root.searching

          Row {
            id: headerLeft
            anchors.left: parent.left
            spacing: 8

            Text {
              text: root.activeTab ? root.activeTab.name : ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body * 1.05
              font.weight: Font.DemiBold
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              text: root.cur ? "" : "Weather unavailable — check network"
              color: root.muted(0.7)
              visible: root.cur === null
              font.family: root.fontFamily
              font.pixelSize: Style.font.body * 0.9
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Row {
            anchors.right: parent.right
            spacing: 8

            Text {
              text: root.tabData && root.tabData.fetchedAt ? "updated " + Model.relativeAge(root.tabData.fetchedAt) : ""
              color: root.muted(0.6)
              font.family: root.fontFamily
              font.pixelSize: Style.font.body * 0.82
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              text: "Radar ↗"
              color: radarMouse.containsMouse ? root.foreground : root.muted(0.8)
              font.family: root.fontFamily
              font.pixelSize: Style.font.body * 0.82
              anchors.verticalCenter: parent.verticalCenter

              MouseArea {
                id: radarMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openRadarWeb()
              }
            }

            Text {
              text: "⟳"
              color: refreshMouse.containsMouse ? root.foreground : root.muted(0.8)
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              anchors.verticalCenter: parent.verticalCenter

              MouseArea {
                id: refreshMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  var t = root.activeTab;
                  if (t && root.hostWidget)
                    root.hostWidget.fetchKey(t.key, t.lat, t.lon);
                  root.fetchRadar();
                }
              }
            }
          }
        }

        // ---- hero ----------------------------------------------------------

        Row {
          spacing: Style.spacing.xl
          visible: !root.searching

          Text {
            text: root.heroIcon
            font.family: root.fontFamily
            font.pixelSize: Style.font.body * 3.4
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            spacing: 2
            anchors.verticalCenter: parent.verticalCenter

            Text {
              text: root.cur ? Model.temp(root.cur.temperature_2m) : "--°"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body * 3.2
              font.weight: Font.DemiBold
            }

            Text {
              text: root.cur ? Model.condText(root.cur.weather_code) : ""
              color: root.muted(0.75)
              font.family: root.fontFamily
              font.pixelSize: Style.font.body * 1.05
            }
          }

          Column {
            spacing: 2
            anchors.verticalCenter: parent.verticalCenter

            Text {
              text: root.cur ? "Feels " + Model.temp(root.cur.apparent_temperature) : ""
              color: root.muted(0.75)
              font.family: root.fontFamily
              font.pixelSize: Style.font.body * 0.95
            }

            Text {
              text: root.daily && root.daily.temperature_2m_max
                ? "H " + Model.temp(root.daily.temperature_2m_max[0]) + "  L " + Model.temp(root.daily.temperature_2m_min[0])
                : ""
              color: root.muted(0.75)
              font.family: root.fontFamily
              font.pixelSize: Style.font.body * 0.95
            }
          }
        }

        PanelSeparator { visible: !root.searching }

        // ---- details grid with level bars -----------------------------------

        PanelSectionHeader { text: "Details"; visible: !root.searching }

        Grid {
          width: parent.width
          columns: 4
          columnSpacing: Style.spacing.md
          rowSpacing: Style.spacing.md
          visible: !root.searching

          Repeater {
            model: root.detailCells

            Column {
              spacing: 1
              required property var modelData
              readonly property var cell: modelData

              Text {
                text: cell && cell.label ? cell.label : ""
                color: root.muted(0.55)
                font.family: root.fontFamily
                font.pixelSize: Style.font.body * 0.78
              }
              Text {
                text: cell && cell.value ? cell.value : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body * 0.98
                font.weight: Font.DemiBold
                elide: Text.ElideRight
                width: (parent.parent ? parent.parent.width : 200) / 4 - Style.spacing.md
              }
              Rectangle {
                visible: cell && cell.level !== undefined && cell.level >= 0
                width: (parent.parent ? parent.parent.width : 200) / 4 - Style.spacing.md
                height: 3
                radius: 1.5
                color: root.muted(0.2)
                Rectangle {
                  anchors.left: parent.left
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  width: parent.width * Math.max(0, Math.min(1, (cell ? Number(cell.level) : 0)))
                  radius: 1.5
                  color: root.foreground
                }
              }
            }
          }
        }

        PanelSeparator { visible: !root.searching }

        // ---- remaining hours strip ------------------------------------------

        PanelSectionHeader { text: "Next hours"; visible: !root.searching }

        Row {
          id: hoursRow
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.leftMargin: Style.spacing.md
          anchors.rightMargin: Style.spacing.md
          spacing: 4
          visible: !root.searching

          Repeater {
            model: root.hours

            Column {
              spacing: 1
              // flex: divide the row width evenly across the hour cells
              width: (parent.width - (Math.max(1, root.hours.length) - 1) * hoursRow.spacing) / Math.max(1, root.hours.length)
              required property var modelData
              readonly property var h: modelData

              Text {
                text: h && h.isNow ? "NOW" : Model.hourLabel(h ? h.time : "")
                color: h && h.isNow ? root.foreground : root.muted(0.55)
                font.family: root.fontFamily
                font.pixelSize: Style.font.body * 0.75
                font.weight: h && h.isNow ? Font.DemiBold : Font.Normal
                anchors.horizontalCenter: parent.horizontalCenter
              }
              Text {
                text: h ? Model.glyph(h.code, false) : ""
                font.family: root.fontFamily
                font.pixelSize: Style.font.body * 1.15
                anchors.horizontalCenter: parent.horizontalCenter
              }
              Text {
                text: h ? Model.temp(h.temp) : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body * 0.85
                anchors.horizontalCenter: parent.horizontalCenter
              }
              Text {
                text: h && Number(h.pop) >= 20 ? "💧" + h.pop + "%" : ""
                color: root.muted(0.7)
                font.family: root.fontFamily
                font.pixelSize: Style.font.body * 0.7
                anchors.horizontalCenter: parent.horizontalCenter
              }
            }
          }
        }

        PanelSeparator { visible: !root.searching }

        // ---- 7-day + radar side by side --------------------------------------

        Row {
          id: forecastRow
          width: parent.width
          spacing: Style.spacing.lg
          visible: !root.searching

          Column {
            id: dailyCol
            width: parent.width - radarCol.width - forecastRow.spacing
            spacing: Style.spacing.sm

            PanelSectionHeader { text: "7-Day Forecast" }

            Repeater {
              model: root.daily && root.daily.time ? root.daily.time : []

              Row {
                width: parent.width
                spacing: 10
                required property var modelData
                required property int index
                readonly property int dayIndex: index
                property string dateStr: modelData

                Text {
                  text: dateStr === root.todayStr ? "Today" : Model.shortDay(dateStr)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body * 0.92
                  font.weight: dateStr === root.todayStr ? Font.DemiBold : Font.Normal
                  width: 52
                  anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                  text: root.daily && root.daily.weather_code ? Model.glyph(root.daily.weather_code[dayIndex], false) : ""
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body * 1.1
                  anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                  text: root.daily && root.daily.temperature_2m_max ? Model.temp(root.daily.temperature_2m_max[dayIndex]) : ""
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body * 0.92
                  font.weight: Font.DemiBold
                  anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                  text: root.daily && root.daily.temperature_2m_min ? Model.temp(root.daily.temperature_2m_min[dayIndex]) : ""
                  color: root.muted(0.6)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body * 0.92
                  anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                  text: root.daily && root.daily.weather_code ? Model.condText(root.daily.weather_code[dayIndex]) : ""
                  color: root.muted(0.6)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body * 0.82
                  elide: Text.ElideRight
                  width: parent.width - 160
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
            }
          }

          Column {
            id: radarCol
            width: Math.round(Math.min(forecastRow.width * 0.42, Style.space(258)) / 2) * 2
            spacing: Style.spacing.xs

            PanelSectionHeader { text: "Radar" }

            Item {
              id: radarMap
              width: radarCol.width
              height: width
              visible: root.radarWin !== null
              clip: true

              // exact point position as pixel fractions of the window
              readonly property real mx: root.radarWin ? (width / root.radarWin.cols) * root.radarWin.px : 0
              readonly property real my: root.radarWin ? (height / root.radarWin.rows) * root.radarWin.py : 0

              Repeater {
                model: root.radarWin ? root.radarWin.cols * root.radarWin.rows : 0

                Item {
                  id: cellItem
                  required property int index
                  readonly property int col: cellItem.index % 2
                  readonly property int rowIdx: Math.floor(cellItem.index / 2)
                  x: col * radarMap.width / 2
                  y: rowIdx * radarMap.height / 2
                  // +1 overlap on the top/left cell hides sub-pixel seams
                  width: radarMap.width / 2 + (col === 0 ? 1 : 0)
                  height: radarMap.height / 2 + (rowIdx === 0 ? 1 : 0)

                  Image {
                    anchors.fill: parent
                    source: root.radarWin
                      ? Model.radarBaseTileUrl(root.radarWin.z, root.radarWin.x0 + col, root.radarWin.y0 + rowIdx)
                      : ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                  }
                  Image {
                    anchors.fill: parent
                    visible: root.radarFrame !== ""
                    source: root.radarFrame !== "" && root.radarWin
                      ? Model.radarFrameTileUrl(root.radarHost, root.radarFrame, root.radarWin.z,
                          root.radarWin.x0 + col, root.radarWin.y0 + rowIdx)
                      : ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    cache: false
                  }
                  // labels sit above radar echoes so cities stay readable
                  Image {
                    anchors.fill: parent
                    source: root.radarWin
                      ? Model.radarLabelTileUrl(root.radarWin.z, root.radarWin.x0 + col, root.radarWin.y0 + rowIdx)
                      : ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                  }
                }
              }

              // location marker: ring + dot on the exact point
              Rectangle {
                x: radarMap.mx - 5
                y: radarMap.my - 5
                width: 10
                height: 10
                radius: 5
                color: "transparent"
                border.width: 1.5
                border.color: root.foreground
              }
              Rectangle {
                x: radarMap.mx - 1.5
                y: radarMap.my - 1.5
                width: 3
                height: 3
                radius: 1.5
                color: root.foreground
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openRadarWeb()
              }
            }

            Text {
              visible: root.radarWin === null
              text: "no location for radar"
              color: root.muted(0.45)
              font.family: root.fontFamily
              font.pixelSize: Style.font.body * 0.8
            }

            Text {
              text: root.radarFrame
                ? (root.radarFrameTime
                    ? Model.relativeAge(new Date(root.radarFrameTime * 1000).toISOString()) + " · "
                    : "")
                  + "© Esri · RainViewer"
                : "radar loading…"
              color: root.muted(0.35)
              font.family: root.fontFamily
              font.pixelSize: Style.font.body * 0.68
            }
          }
        }

        PanelSeparator { visible: !root.searching }

        // ---- sun + credit ------------------------------------------------------

        Row {
          width: parent.width
          spacing: Style.spacing.xl
          visible: !root.searching

          Text {
            text: root.daily && root.daily.sunrise ? "🌅 Sunrise " + String(root.daily.sunrise[0]).slice(11, 16) : "🌅 --"
            color: root.muted(0.75)
            font.family: root.fontFamily
            font.pixelSize: Style.font.body * 0.92
          }
          Text {
            text: root.daily && root.daily.sunset ? "🌇 Sunset " + String(root.daily.sunset[0]).slice(11, 16) : "🌇 --"
            color: root.muted(0.75)
            font.family: root.fontFamily
            font.pixelSize: Style.font.body * 0.92
          }
          Text {
            text: root.daily && root.daily.sunrise ? "☀ " + Model.daylightLength(root.daily.sunrise[0], root.daily.sunset[0]) : ""
            color: root.muted(0.75)
            font.family: root.fontFamily
            font.pixelSize: Style.font.body * 0.92
          }
        }

        Text {
          text: "Open-Meteo · bar follows this device · click a pinned tab twice to remove it"
          color: root.muted(0.35)
          font.family: root.fontFamily
          font.pixelSize: Style.font.body * 0.72
          visible: !root.searching
        }
      }
    }
  }

  // Details grid data — level bars where a 0..1 ratio exists.
  readonly property var detailCells: {
    var c = root.cur;
    var cells = [];
    function add(label, value, level) { cells.push({ label: label, value: value, level: level }); }
    if (!c)
      return cells;
    add("Wind", Model.windDir(c.wind_direction_10m) + " " + Math.round(Number(c.wind_speed_10m)) + " mph");
    add("Gusts", Number(c.wind_gusts_10m) > 0 ? Math.round(Number(c.wind_gusts_10m)) + " mph" : "—");
    add("Humidity", Math.round(Number(c.relative_humidity_2m)) + "%", Number(c.relative_humidity_2m) / 100);
    add("Pressure", Math.round(Number(c.surface_pressure)) + " hPa");
    add("UV", Math.round(Number(c.uv_index) * 10) / 10 + " " + Model.uvCategory(c.uv_index), Math.min(1, Number(c.uv_index) / 11));
    add("Dew pt", Model.temp(c.dew_point_2m));
    if (root.air && root.air.us_aqi !== undefined)
      add("AQI", Math.round(Number(root.air.us_aqi)) + " " + Model.aqiCategory(root.air.us_aqi), Math.min(1, Number(root.air.us_aqi) / 300));
    if (root.hours.length > 0 && root.hours[0].pop !== undefined)
      add("Rain now", root.hours[0].pop + "%", Number(root.hours[0].pop) / 100);
    return cells;
  }
}
