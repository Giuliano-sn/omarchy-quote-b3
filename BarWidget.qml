import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Quote B3: up to three B3 tickers / BRL currency pairs in the bar, each as
// "NAME ▲ value". Left-click opens details, right-click opens settings (where
// assets are picked by typing their name), middle-click refreshes now.
// Network: one HTTPS request to Yahoo Finance per refresh (default every
// 5 minutes, can be turned off in settings), plus search requests while typing
// in the settings form.
BarWidget {
  id: root
  moduleName: "io.github.giuliano-sn.quote-b3"

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // --- settings --------------------------------------------------------------
  readonly property var symbols: Model.symbolList(setting("symbols", null))
  readonly property string symbolsKey: symbols.join(",")
  readonly property int intervalMinutes: Model.clampInt(setting("intervalMinutes", 5), 1, 120, 5)
  readonly property bool autoRefresh: setting("autoRefresh", true) === true
  readonly property bool colorizeTrend: setting("colorizeTrend", true) === true

  // --- state -----------------------------------------------------------------
  property var quotes: ({})
  property double lastUpdated: 0
  property bool lastFailed: false
  property bool pendingRefresh: false

  property var themeColors: ({ up: "", down: "" })
  readonly property color barForeground: bar ? bar.barForeground : Color.foreground
  readonly property color upColor: themeColors.up !== "" ? themeColors.up : barForeground
  readonly property color downColor: themeColors.down !== "" ? themeColors.down : barForeground

  // "": closed, "details", "settings".
  property string panelMode: ""
  readonly property bool opened: panelMode !== ""

  // Settings drafts, committed on Save.
  property var draftSymbols: []
  property var draftNames: ({})
  property int draftInterval: 5
  property bool draftAutoRefresh: true
  property bool draftColorize: true

  // Search state for the settings form.
  property string searchText: ""
  property string searchRanFor: ""
  property var searchResults: []
  property int searchIndex: 0
  readonly property bool searching: searchProc.running || searchDebounce.running

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onSymbolsKeyChanged: Qt.callLater(root.refresh)
  Component.onCompleted: Qt.callLater(root.refresh)

  function trendColor(trend) {
    if (!root.colorizeTrend || trend === 0) return button.foreground
    return trend > 0 ? root.upColor : root.downColor
  }

  function priceText(q) {
    return q ? Commons.I18n.formatNumber(q.price, q.decimals) : "…"
  }

  function changeText(q) {
    if (!q) return ""
    var sign = q.change > 0 ? "+" : (q.change < 0 ? "−" : "")
    return sign + Commons.I18n.formatNumber(Math.abs(q.change), q.decimals)
      + " (" + sign + Commons.I18n.formatNumber(Math.abs(q.changePercent), 2) + "%)"
  }

  function timeText(ms) {
    return ms > 0 ? new Date(ms).toLocaleTimeString(Qt.locale(Commons.I18n.formatLocale), "HH:mm") : "—"
  }

  function nameFor(symbol) {
    if (root.draftNames[symbol]) return root.draftNames[symbol]
    var q = root.quotes[symbol]
    return q ? q.name : ""
  }

  // --- quotes ----------------------------------------------------------------
  function refresh() {
    var url = Model.quotesUrl(root.symbols)
    if (url === "") { root.quotes = ({}); return }
    if (quoteProc.running) { root.pendingRefresh = true; return }
    quoteProc.command = Model.curlArgs(url)
    quoteProc.running = true
  }

  Process {
    id: quoteProc
    stdout: StdioCollector { id: quoteOut; waitForEnd: true }
    onExited: function (exitCode) {
      var parsed = exitCode === 0 ? Model.parseQuotes(quoteOut.text) : ({})
      if (Object.keys(parsed).length > 0) {
        root.quotes = parsed
        root.lastUpdated = Date.now()
        root.lastFailed = false
      } else {
        root.lastFailed = true
      }
      if (root.pendingRefresh) {
        root.pendingRefresh = false
        Qt.callLater(root.refresh)
      }
    }
  }

  Timer {
    interval: root.intervalMinutes * 60000
    running: root.autoRefresh && root.symbols.length > 0
    repeat: true
    onTriggered: root.refresh()
  }

  // --- theme colors (ANSI green/red from colors.toml) -----------------------
  FileView {
    id: colorsFile
    path: Color.currentThemePath + "/colors.toml"
    printErrors: false
    onLoaded: root.themeColors = Model.trendColors(text())
    onLoadFailed: root.themeColors = ({ up: "", down: "" })
  }

  // Theme switches push new colors to Color; re-read ours alongside.
  Connections {
    target: Color
    function onForegroundChanged() { colorsFile.reload() }
    function onAccentChanged() { colorsFile.reload() }
  }

  // --- search (settings form) -----------------------------------------------
  onSearchTextChanged: {
    root.searchIndex = 0
    if (Model.searchUrl(root.searchText) === "") {
      searchDebounce.stop()
      root.searchRanFor = ""
      root.searchResults = Model.parseSearch("", root.searchText, root.draftSymbols)
    } else {
      searchDebounce.restart()
    }
  }

  Timer {
    id: searchDebounce
    interval: 350
    onTriggered: root.runSearch()
  }

  function runSearch() {
    var url = Model.searchUrl(root.searchText)
    if (url === "") return
    if (searchProc.running) { searchDebounce.restart(); return }
    root.searchRanFor = root.searchText
    searchProc.command = Model.curlArgs(url)
    searchProc.running = true
  }

  Process {
    id: searchProc
    stdout: StdioCollector { id: searchOut; waitForEnd: true }
    onExited: function (exitCode) {
      // Ignore answers to a query the user has already typed past.
      if (root.searchRanFor !== root.searchText) return
      root.searchResults = Model.parseSearch(exitCode === 0 ? searchOut.text : "", root.searchText, root.draftSymbols)
      if (root.searchIndex >= root.searchResults.length) root.searchIndex = 0
    }
  }

  function resetSearch() {
    searchDebounce.stop()
    root.searchText = ""
    root.searchRanFor = ""
    root.searchResults = []
    root.searchIndex = 0
  }

  function addSymbol(item) {
    if (!item || root.draftSymbols.length >= Model.MAX_SYMBOLS) return
    var s = Model.normalizeSymbol(item.symbol)
    if (s === "" || root.draftSymbols.indexOf(s) !== -1) return
    var next = root.draftSymbols.slice()
    next.push(s)
    root.draftSymbols = next
    if (item.name) {
      var names = Object.assign({}, root.draftNames)
      names[s] = item.name
      root.draftNames = names
    }
    root.resetSearch()
  }

  function removeSymbol(symbol) {
    root.draftSymbols = root.draftSymbols.filter(function (s) { return s !== symbol })
  }

  function moveSearch(delta) {
    var n = root.searchResults.length
    if (n === 0) return
    root.searchIndex = (root.searchIndex + delta + n) % n
  }

  // --- panels ----------------------------------------------------------------
  function openDetails() { root.panelMode = "details" }

  function openSettings() {
    root.draftSymbols = root.symbols.slice()
    root.draftNames = ({})
    root.draftInterval = root.intervalMinutes
    root.draftAutoRefresh = root.autoRefresh
    root.draftColorize = root.colorizeTrend
    root.resetSearch()
    root.panelMode = "settings"
  }

  function saveSettings() {
    var entry = { id: root.moduleName }
    for (var k in root.settings) if (k !== "id") entry[k] = root.settings[k]
    entry.symbols = Model.symbolList(root.draftSymbols)
    entry.intervalMinutes = Model.clampInt(root.draftInterval, 1, 120, 5)
    entry.autoRefresh = root.draftAutoRefresh
    entry.colorizeTrend = root.draftColorize
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
    root.closePanel()
    root.refresh()
  }

  function closePanel() {
    root.resetSearch()
    root.panelMode = ""
  }

  function close() { root.closePanel() }
  function open() { root.openDetails() }
  function toggle() { root.opened ? root.closePanel() : root.openDetails() }

  IpcHandler {
    target: root.moduleName
    function refresh(): void { root.refresh() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function settings(): void { root.openSettings() }
  }

  // --- bar -------------------------------------------------------------------
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    tooltipText: strings.t("tooltip")
    fixedHeight: root.barSize
    fixedWidth: root.vertical ? root.barSize : Math.max(12, contentRow.implicitWidth + scaledHorizontalMargin * 2)

    onPressed: function (buttonCode) {
      if (buttonCode === Qt.RightButton) root.openSettings()
      else if (buttonCode === Qt.MiddleButton) root.refresh()
      else root.openDetails()
    }

    Row {
      id: contentRow
      visible: !root.vertical
      anchors.centerIn: parent
      spacing: Style.space(12)
      opacity: root.lastFailed ? 0.6 : 1

      Text {
        visible: root.symbols.length === 0
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: " " + strings.t("configure")
        color: button.foreground
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
      }

      Repeater {
        model: root.symbols

        Row {
          id: quoteItem
          required property string modelData
          readonly property var quote: root.quotes[modelData] || null
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(4)

          BarText { text: quoteItem.modelData }
          BarText {
            visible: quoteItem.quote !== null
            text: quoteItem.quote ? Model.arrow(quoteItem.quote.trend) : ""
            color: quoteItem.quote ? root.trendColor(quoteItem.quote.trend) : button.foreground
            font.pixelSize: button.fontSize * 0.8
          }
          BarText { text: root.priceText(quoteItem.quote) }
        }
      }
    }

    Text {
      visible: root.vertical
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: ""
      color: button.foreground
      font.family: button.fontFamily
      font.pixelSize: button.fontSize
    }
  }

  component BarText: Text {
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
    textFormat: Text.PlainText
    color: button.foreground
    font.family: button.fontFamily
    font.pixelSize: button.fontSize
  }

  component PanelText: Text {
    textFormat: Text.PlainText
    color: root.barForeground
    font.family: Style.font.family
    font.pixelSize: Style.font.body
  }

  component Caption: Text {
    textFormat: Text.PlainText
    color: Qt.darker(root.barForeground, 1.5)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    wrapMode: Text.Wrap
  }

  // --- details popup (left-click) -------------------------------------------
  KeyboardPanel {
    id: detailsPanel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.panelMode === "details"
    focusTarget: detailsLoader.item
    contentWidth: detailsPanel.fittedContentWidth(Style.space(360))
    contentHeight: detailsPanel.fittedContentHeight(detailsLoader.item ? detailsLoader.item.implicitHeight : 0, Style.space(560))

    Loader {
      id: detailsLoader
      anchors.fill: parent
      active: root.panelMode === "details"
      sourceComponent: detailsContent
    }
  }

  Component {
    id: detailsContent

    PanelKeyCatcher {
      implicitHeight: detailsColumn.implicitHeight
      onCloseRequested: root.closePanel()

      Column {
        id: detailsColumn
        width: parent.width
        spacing: Style.space(10)

        PanelHero {
          width: parent.width
          title: strings.t("title")
          meta: root.lastUpdated > 0
            ? (root.lastFailed ? strings.t("updateFailed") : strings.t("updatedAt").arg(root.timeText(root.lastUpdated)))
            : (root.lastFailed ? strings.t("noData") : strings.t("waiting"))
          foreground: root.barForeground
          fontFamily: Style.font.family
          iconComponent: Component {
            Text {
              text: ""
              color: root.barForeground
              font.family: Style.font.family
              font.pixelSize: Style.font.display
            }
          }
        }

        PanelSeparator { foreground: root.barForeground }

        Caption {
          width: parent.width
          visible: root.symbols.length === 0
          text: strings.t("empty")
        }

        Repeater {
          model: root.symbols

          Column {
            id: detailItem
            required property string modelData
            readonly property var quote: root.quotes[modelData] || null
            width: detailsColumn.width
            spacing: Style.space(2)

            Item {
              width: parent.width
              implicitHeight: Math.max(symbolText.implicitHeight, priceRow.implicitHeight)

              PanelText {
                id: symbolText
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: detailItem.modelData
                font.bold: true
              }

              Row {
                id: priceRow
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(6)

                PanelText {
                  visible: detailItem.quote !== null
                  anchors.verticalCenter: parent.verticalCenter
                  text: detailItem.quote ? Model.arrow(detailItem.quote.trend) : ""
                  color: detailItem.quote && detailItem.quote.trend !== 0
                    ? (detailItem.quote.trend > 0 ? root.upColor : root.downColor) : root.barForeground
                  font.pixelSize: Style.font.bodySmall
                }
                PanelText {
                  anchors.verticalCenter: parent.verticalCenter
                  text: detailItem.quote ? root.priceText(detailItem.quote) : "—"
                  font.bold: true
                }
              }
            }

            Item {
              width: parent.width
              implicitHeight: nameCaption.implicitHeight

              Caption {
                id: nameCaption
                anchors.left: parent.left
                width: parent.width - changeCaption.implicitWidth - Style.space(8)
                wrapMode: Text.NoWrap
                elide: Text.ElideRight
                text: detailItem.quote ? detailItem.quote.name : strings.t("noData")
              }
              Caption {
                id: changeCaption
                anchors.right: parent.right
                wrapMode: Text.NoWrap
                text: root.changeText(detailItem.quote)
                color: detailItem.quote && detailItem.quote.trend !== 0
                  ? (detailItem.quote.trend > 0 ? root.upColor : root.downColor) : Qt.darker(root.barForeground, 1.5)
              }
            }

            Caption {
              width: parent.width
              visible: detailItem.quote !== null && detailItem.quote.dayLow !== null && detailItem.quote.dayHigh !== null
              text: detailItem.quote && detailItem.quote.dayLow !== null && detailItem.quote.dayHigh !== null
                ? strings.t("dayRange").arg(Commons.I18n.formatNumber(detailItem.quote.dayLow, detailItem.quote.decimals))
                    .arg(Commons.I18n.formatNumber(detailItem.quote.dayHigh, detailItem.quote.decimals))
                  + (detailItem.quote.previousClose !== null
                    ? "  ·  " + strings.t("previousClose").arg(Commons.I18n.formatNumber(detailItem.quote.previousClose, detailItem.quote.decimals))
                    : "")
                : ""
            }
          }
        }

        PanelSeparator { foreground: root.barForeground }

        Row {
          anchors.right: parent.right
          spacing: Style.space(10)

          Button {
            text: strings.t("settings")
            bordered: true
            foreground: root.barForeground
            onClicked: root.openSettings()
          }
          Button {
            text: strings.t("refresh")
            bordered: true
            foreground: root.barForeground
            onClicked: root.refresh()
          }
        }
      }
    }
  }

  // --- settings popup (right-click) -----------------------------------------
  KeyboardPanel {
    id: settingsPanel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.panelMode === "settings"
    focusTarget: settingsLoader.item ? settingsLoader.item.searchField : null
    contentWidth: settingsPanel.fittedContentWidth(Style.space(400))
    contentHeight: settingsPanel.fittedContentHeight(settingsLoader.item ? settingsLoader.item.implicitHeight : 0, Style.space(680))

    Loader {
      id: settingsLoader
      anchors.fill: parent
      active: root.panelMode === "settings"
      sourceComponent: settingsContent
    }
  }

  Component {
    id: settingsContent

    Item {
      id: settingsRoot
      property alias searchField: searchField
      readonly property real footerBlockHeight: footerRow.implicitHeight + Style.space(21)
      implicitHeight: settingsColumn.implicitHeight + footerBlockHeight

      Keys.onEscapePressed: root.closePanel()

      Flickable {
        id: settingsFlick
        anchors.fill: parent
        anchors.bottomMargin: settingsRoot.footerBlockHeight
        contentWidth: width
        contentHeight: settingsColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: settingsColumn
          width: settingsFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: strings.t("settingsTitle")
            foreground: root.barForeground
            fontFamily: Style.font.family
            iconComponent: Component {
              Text {
                text: ""
                color: root.barForeground
                font.family: Style.font.family
                font.pixelSize: Style.font.display
              }
            }
          }

          PanelSeparator { foreground: root.barForeground }

          PanelSectionHeader { text: strings.t("section.assets"); foreground: root.barForeground }

          // Chosen assets.
          Repeater {
            model: root.draftSymbols

            Item {
              id: chosenRow
              required property string modelData
              width: settingsColumn.width
              implicitHeight: Math.max(removeButton.implicitHeight, Style.spacing.popupRowHeight)

              PanelText {
                id: chosenSymbol
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: chosenRow.modelData
                font.bold: true
              }
              Caption {
                anchors.left: chosenSymbol.right
                anchors.leftMargin: Style.space(10)
                anchors.right: removeButton.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                wrapMode: Text.NoWrap
                elide: Text.ElideRight
                text: root.nameFor(chosenRow.modelData)
              }
              Button {
                id: removeButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: strings.t("remove")
                bordered: true
                foreground: root.barForeground
                onClicked: root.removeSymbol(chosenRow.modelData)
              }
            }
          }

          // Search by name / ticker.
          TextField {
            id: searchField
            width: parent.width
            visible: root.draftSymbols.length < 3
            placeholderText: strings.t("search.placeholder")
            foreground: root.barForeground
            maximumLength: 40
            text: root.searchText
            onTextChanged: if (root.searchText !== text) root.searchText = text
            Keys.onUpPressed: root.moveSearch(-1)
            Keys.onDownPressed: root.moveSearch(1)
            Keys.onReturnPressed: root.addSymbol(root.searchResults[root.searchIndex])
            Keys.onEnterPressed: root.addSymbol(root.searchResults[root.searchIndex])
            Keys.onEscapePressed: function (event) {
              if (text !== "") root.resetSearch()
              else root.closePanel()
            }
          }

          Column {
            width: parent.width
            visible: searchField.visible && root.searchText.length > 0
            spacing: Style.space(2)

            Repeater {
              model: root.searchResults

              CursorSurface {
                id: match
                required property var modelData
                required property int index
                width: parent.width
                implicitHeight: Style.spacing.popupRowHeight
                foreground: root.barForeground
                hasCursor: root.searchIndex === index

                PanelText {
                  id: matchSymbol
                  anchors.left: parent.left
                  anchors.leftMargin: Style.spacing.xl
                  anchors.verticalCenter: parent.verticalCenter
                  text: match.modelData.symbol
                  font.bold: true
                }
                Caption {
                  anchors.left: matchSymbol.right
                  anchors.leftMargin: Style.space(10)
                  anchors.right: parent.right
                  anchors.rightMargin: Style.spacing.xl
                  anchors.verticalCenter: parent.verticalCenter
                  wrapMode: Text.NoWrap
                  elide: Text.ElideRight
                  text: match.modelData.name
                }
                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onPositionChanged: root.searchIndex = match.index
                  onClicked: root.addSymbol(match.modelData)
                }
              }
            }

            Caption {
              width: parent.width
              visible: root.searchResults.length === 0 || root.searching
              horizontalAlignment: Text.AlignHCenter
              topPadding: Style.spacing.md
              text: root.searching ? strings.t("search.searching") : strings.t("search.noMatches")
            }
          }

          Caption {
            width: parent.width
            visible: root.draftSymbols.length >= 3
            text: strings.t("search.limit")
          }

          Button {
            text: strings.t("restoreDefaults")
            bordered: true
            foreground: root.barForeground
            onClicked: { root.draftSymbols = Model.DEFAULT_SYMBOLS.slice(); root.resetSearch() }
          }

          PanelSectionHeader { text: strings.t("section.refresh"); foreground: root.barForeground }

          Toggle {
            width: parent.width
            label: strings.t("autoRefresh")
            checked: root.draftAutoRefresh
            foreground: root.barForeground
            onClicked: root.draftAutoRefresh = !root.draftAutoRefresh
          }

          NumberField {
            label: strings.t("interval")
            enabled: root.draftAutoRefresh
            value: root.draftInterval
            from: 1
            to: 120
            stepSize: 1
            fieldWidth: Style.spacing.numberFieldWidth * 0.75
            foreground: root.barForeground
            onModified: function (value) { root.draftInterval = value }
          }

          PanelSectionHeader { text: strings.t("section.display"); foreground: root.barForeground }

          Toggle {
            width: parent.width
            label: strings.t("colorize")
            checked: root.draftColorize
            foreground: root.barForeground
            onClicked: root.draftColorize = !root.draftColorize
          }

          Caption {
            width: parent.width
            text: strings.t("source")
          }
        }
      }

      PanelSeparator {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: footerRow.top
        anchors.bottomMargin: Style.space(10)
        foreground: root.barForeground
      }

      Row {
        id: footerRow
        anchors.bottom: parent.bottom
        anchors.right: parent.right
        spacing: Style.space(10)

        Button {
          text: strings.t("cancel")
          bordered: true
          foreground: root.barForeground
          onClicked: root.closePanel()
        }
        Button {
          text: strings.t("save")
          bordered: true
          foreground: root.barForeground
          onClicked: root.saveSettings()
        }
      }
    }
  }
}
