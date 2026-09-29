import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import QtQuick.Dialogs
import QtQuick.Window

// ===== 设置窗口（独立窗口）=====
// 由 main.qml 在首次打开设置时通过 Qt.createComponent 惰性创建，
// 通过 host 属性访问主窗口的状态/颜色/设置项（host 即主窗口）。
Window {
    id: settingsWindow
    required property var host

    // 尺寸：优先使用上次关闭时保存的尺寸（与主程序写入同一个 config 文件），
    // 否则默认主窗口 1/4 宽 × 等高。_savedSize 在窗口创建时读取一次。
    property var _savedSize: player.loadSettings()
    width: _savedSize.settingsWinW > 0 ? _savedSize.settingsWinW : Math.max(Math.round(host.width / 4), 320)
    height: _savedSize.settingsWinH > 0 ? _savedSize.settingsWinH : host.height
    title: "设置"
    // 背景色：可在设置里调整（customSettingsBg）；未设置则跟随主主题深色背景
    readonly property color panelBg: host.customSettingsBg !== "" ? host.customSettingsBg : host.bgDark
    color: panelBg
    visible: true

    // 关闭前把当前尺寸写回 config（关闭按钮 / 隐藏都会触发）
    function _persistSize() {
        player.saveSetting("settingsWinW", width)
        player.saveSetting("settingsWinH", height)
    }

    // 通知主窗口：本窗口已关闭（主窗口据此复位按钮/开关状态并隐藏本窗口）
    onClosing: function(closeEvent) {
        _persistSize()
        host.settingsVisible = false
    }
    onVisibleChanged: {
        if (!visible) {
            _persistSize()
            if (host && host.settingsVisible)
                host.settingsVisible = false
        }
    }

        Rectangle {
            id: settingsPanel
            anchors.fill: parent
            color: settingsWindow.panelBg

            Flickable {
                id: settingsFlickable
                anchors.fill: parent
                anchors.leftMargin: 20
                anchors.topMargin: 20
                anchors.bottomMargin: 20
                anchors.rightMargin: 6
                contentWidth: width
                contentHeight: settingsColumn.implicitHeight
                clip: true
                boundsBehavior: Flickable.DragAndOvershootBounds
                flickDeceleration: 2000
                flickableDirection: Flickable.VerticalFlick
                interactive: true

                ScrollBar.vertical: ScrollBar {
                    policy: ScrollBar.AsNeeded
                    width: 6
                    contentItem: Rectangle {
                        implicitWidth: 6
                        radius: 3
                        color: Qt.rgba(host.accent.r, host.accent.g, host.accent.b, 0.55)
                    }
                    background: Rectangle {
                        implicitWidth: 6
                        radius: 3
                        color: "transparent"
                    }
                }

                ColumnLayout {
                    id: settingsColumn
                    width: parent.width - 26
                    spacing: 12

                // 标题
                Text {
                    font.family: host.uiFontFamily
                    text: "设置"
                    color: host.textPrimary
                    font.pixelSize: 20
                    font.bold: true
                }

                // ===== 音乐文件夹 =====
                Text {
                    font.family: host.uiFontFamily
                    text: "音乐文件夹"
                    color: host.textPrimary
                    font.pixelSize: 14
                    font.bold: true
                }

                TextField {
                    id: musicDirInput
                    Layout.fillWidth: true
                    text: player.musicDir
                    placeholderText: "输入音乐文件夹路径..."
                    color: host.textPrimary
                    font.pixelSize: 12

                    // 目录无效时的红框提示状态（应用无效路径时短暂点亮）
                    property bool _invalid: false

                    background: Rectangle {
                        color: host.customBtnBg !== "" ? host.customBtnBg : "#1a1a3e"
                        radius: 6
                        border.color: musicDirInput._invalid ? "#e94560" : ("#334466")
                    }

                    Timer {
                        id: musicDirInvalidTimer
                        interval: 2000
                        onTriggered: musicDirInput._invalid = false
                    }
                }
                    
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 8
                                        Button {
                                            text: "浏览"
                        font.pixelSize: 12
                        onClicked: folderDialog.open()
                        background: Rectangle {
                            implicitWidth: 52
                            implicitHeight: 28
                            color: host.customBtnBg !== "" ? host.customBtnBg : "#2a2a4e"
                            radius: 6
                        }
                        contentItem: Text {
                            text: parent.text
                            color: host.textPrimary
                            font: parent.font
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }

                    Button {
                        text: "应用"
                        font.pixelSize: 12
                        onClicked: {
                            // setMusicDir 返回是否成功：只有目录有效才保存到配置，
                            // 避免无效路径被持久化后每次启动都静默失败
                            if (player.setMusicDir(musicDirInput.text)) {
                                host.saveSetting("musicDir", musicDirInput.text)
                            } else {
                                musicDirInput.text = player.musicDir
                                musicDirInput._invalid = true
                                musicDirInvalidTimer.restart()
                            }
                        }
                        background: Rectangle {
                            implicitWidth: 52
                            implicitHeight: 28
                            color: host.accent
                            radius: 6
                        }
                        contentItem: Text {
                            text: parent.text
                            color: "#fff"
                            font: parent.font
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }

                // ===== 分割线 =====
                Rectangle {
                    Layout.fillWidth: true
                    height: 1
                    color: host.textMuted
                    opacity: 0.3
                }

                // ===== 颜色自定义 =====
                Text {
                    font.family: host.uiFontFamily
                    text: "颜色自定义"
                    color: host.textPrimary
                    font.pixelSize: 14
                    font.bold: true
                }

                // 主题色
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Text {
                        font.family: host.uiFontFamily
                        text: "主题色"
                        color: host.textPrimary
                        font.pixelSize: 12
                        Layout.preferredWidth: 60
                    }

                    Rectangle {
                        width: 20; height: 20; radius: 4
                        color: host.accent
                        border.color: host.textMuted
                        border.width: 1
                    }

                    Item { Layout.fillWidth: true }

                    Button {
                        text: "选择"
                        font.pixelSize: 11
                        onClicked: {
                            openColorDialog("customAccent", host.accent)
                        }
                        background: Rectangle {
                            implicitWidth: 52
                            implicitHeight: 28
                            color: host.customBtnBg !== "" ? host.customBtnBg : "#2a2a4e"
                            radius: 4
                        }
                        contentItem: Text {
                            text: parent.text
                            color: host.textPrimary
                            font: parent.font
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }

                // 深色背景
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Text {
                        font.family: host.uiFontFamily
                        text: "背景色"
                        color: host.textPrimary
                        font.pixelSize: 12
                        Layout.preferredWidth: 60
                    }

                    Rectangle {
                        width: 20; height: 20; radius: 4
                        color: host.customDarkBg !== "" ? host.customDarkBg : "#1a1a2e"
                        border.color: host.textMuted
                        border.width: 1
                    }

                    Item { Layout.fillWidth: true }

                    Button {
                        text: "选择"
                        font.pixelSize: 11
                        onClicked: {
                            openColorDialog("customDarkBg", host.customDarkBg !== "" ? host.customDarkBg : "#1a1a2e")
                        }
                        background: Rectangle {
                            implicitWidth: 52
                            implicitHeight: 28
                            color: host.customBtnBg !== "" ? host.customBtnBg : "#2a2a4e"
                            radius: 4
                        }
                        contentItem: Text {
                            text: parent.text
                            color: host.textPrimary
                            font: parent.font
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }

                // 设置窗口背景色（独立设置窗口自身的背景）
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Text {
                        font.family: host.uiFontFamily
                        text: "设置窗背景"
                        color: host.textPrimary
                        font.pixelSize: 12
                        Layout.preferredWidth: 76
                    }

                    Rectangle {
                        width: 20; height: 20; radius: 4
                        color: host.customSettingsBg !== "" ? host.customSettingsBg
                               : (host.customDarkBg !== "" ? host.customDarkBg : "#1a1a2e")
                        border.color: host.textMuted
                        border.width: 1
                    }

                    Item { Layout.fillWidth: true }

                    Button {
                        text: "选择"
                        font.pixelSize: 11
                        onClicked: {
                            openColorDialog("customSettingsBg", host.customSettingsBg !== ""
                                            ? host.customSettingsBg
                                            : (host.customDarkBg !== "" ? host.customDarkBg : "#1a1a2e"))
                        }
                        background: Rectangle {
                            implicitWidth: 52
                            implicitHeight: 28
                            color: host.customBtnBg !== "" ? host.customBtnBg : "#2a2a4e"
                            radius: 4
                        }
                        contentItem: Text {
                            text: parent.text
                            color: host.textPrimary
                            font: parent.font
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }

                // 下载窗口背景色（独立下载窗口自身的背景）
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Text {
                        font.family: host.uiFontFamily
                        text: "下载窗背景"
                        color: host.textPrimary
                        font.pixelSize: 12
                        Layout.preferredWidth: 76
                    }

                    Rectangle {
                        width: 20; height: 20; radius: 4
                        color: host.customDownloadBg !== "" ? host.customDownloadBg
                               : (host.customDarkBg !== "" ? host.customDarkBg : "#1a1a2e")
                        border.color: host.textMuted
                        border.width: 1
                    }

                    Item { Layout.fillWidth: true }

                    Button {
                        text: "选择"
                        font.pixelSize: 11
                        onClicked: {
                            openColorDialog("customDownloadBg", host.customDownloadBg !== ""
                                            ? host.customDownloadBg
                                            : (host.customDarkBg !== "" ? host.customDarkBg : "#1a1a2e"))
                        }
                        background: Rectangle {
                            implicitWidth: 52
                            implicitHeight: 28
                            color: host.customBtnBg !== "" ? host.customBtnBg : "#2a2a4e"
                            radius: 4
                        }
                        contentItem: Text {
                            text: parent.text
                            color: host.textPrimary
                            font: parent.font
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }

                // 按钮/输入框底色
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Text {
                        font.family: host.uiFontFamily
                        text: "控件底色"
                        color: host.textPrimary
                        font.pixelSize: 12
                        Layout.preferredWidth: 60
                    }

                    Rectangle {
                        width: 20; height: 20; radius: 4
                        color: host.customBtnBg !== "" ? host.customBtnBg : "#2a2a4e"
                        border.color: host.textMuted
                        border.width: 1
                    }

                    Item { Layout.fillWidth: true }

                    Button {
                        text: "选择"
                        font.pixelSize: 11
                        onClicked: {
                            openColorDialog("customBtnBg", host.customBtnBg !== "" ? host.customBtnBg : "#2a2a4e")
                        }
                        background: Rectangle {
                            implicitWidth: 52
                            implicitHeight: 28
                            color: host.customBtnBg !== "" ? host.customBtnBg : "#2a2a4e"
                            radius: 4
                        }
                        contentItem: Text {
                            text: parent.text
                            color: host.textPrimary
                            font: parent.font
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }

                // ===== 分割线 =====
                Rectangle {
                    Layout.fillWidth: true
                    height: 1
                    color: host.textMuted
                    opacity: 0.3
                }

                // ===== 歌词颜色 =====
                Text {
                    font.family: host.uiFontFamily
                    text: "歌词颜色"
                    color: host.textPrimary
                    font.pixelSize: 14
                    font.bold: true
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Text {
                        font.family: host.uiFontFamily
                        text: "当前行"
                        color: host.textPrimary
                        font.pixelSize: 12
                        Layout.preferredWidth: 60
                    }

                    Rectangle {
                        width: 20; height: 20; radius: 4
                        color: host.customLyricColor !== "" ? host.customLyricColor : host.accent
                        border.color: host.textMuted
                        border.width: 1
                    }

                    Item { Layout.fillWidth: true }

                    Button {
                        text: "选择"
                        font.pixelSize: 11
                        onClicked: {
                            openColorDialog("customLyricColor", host.customLyricColor !== "" ? host.customLyricColor : host.accent)
                        }
                        background: Rectangle {
                            implicitWidth: 52
                            implicitHeight: 28
                            color: host.customBtnBg !== "" ? host.customBtnBg : "#2a2a4e"
                            radius: 4
                        }
                        contentItem: Text {
                            text: parent.text
                            color: host.textPrimary
                            font: parent.font
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Text {
                        font.family: host.uiFontFamily
                        text: "已播行"
                        color: host.textPrimary
                        font.pixelSize: 12
                        Layout.preferredWidth: 60
                    }

                    Rectangle {
                        width: 20; height: 20; radius: 4
                        color: host.customLyricPlayedColor !== "" ? host.customLyricPlayedColor : host.textMuted
                        border.color: host.textMuted
                        border.width: 1
                    }

                    Item { Layout.fillWidth: true }

                    Button {
                        text: "选择"
                        font.pixelSize: 11
                        onClicked: {
                            openColorDialog("customLyricPlayedColor", host.customLyricPlayedColor !== "" ? host.customLyricPlayedColor : host.textMuted)
                        }
                        background: Rectangle {
                            implicitWidth: 52
                            implicitHeight: 28
                            color: host.customBtnBg !== "" ? host.customBtnBg : "#2a2a4e"
                            radius: 4
                        }
                        contentItem: Text {
                            text: parent.text
                            color: host.textPrimary
                            font: parent.font
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Text {
                        font.family: host.uiFontFamily
                        text: "未播行"
                        color: host.textPrimary
                        font.pixelSize: 12
                        Layout.preferredWidth: 60
                    }

                    Rectangle {
                        width: 20; height: 20; radius: 4
                        color: host.customLyricUnplayedColor !== "" ? host.customLyricUnplayedColor : host.textSecondary
                        border.color: host.textMuted
                        border.width: 1
                    }

                    Item { Layout.fillWidth: true }

                    Button {
                        text: "选择"
                        font.pixelSize: 11
                        onClicked: {
                            openColorDialog("customLyricUnplayedColor", host.customLyricUnplayedColor !== "" ? host.customLyricUnplayedColor : host.textSecondary)
                        }
                        background: Rectangle {
                            implicitWidth: 52
                            implicitHeight: 28
                            color: host.customBtnBg !== "" ? host.customBtnBg : "#2a2a4e"
                            radius: 4
                        }
                        contentItem: Text {
                            text: parent.text
                            color: host.textPrimary
                            font: parent.font
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }

                // 隐藏控件底色
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Text {
                        font.family: host.uiFontFamily
                        text: "隐藏控件底色"
                        color: host.textPrimary
                        font.pixelSize: 12
                        Layout.preferredWidth: 80
                    }

                    Item { Layout.fillWidth: true }

                    Rectangle {
                        width: 40; height: 22; radius: 11
                        color: host.hideControlBackgrounds ? host.accent : "#3a3a5e"
                        Behavior on color { ColorAnimation { duration: 150 } }

                        Rectangle {
                            x: host.hideControlBackgrounds ? 20 : 2
                            y: 2
                            width: 18; height: 18; radius: 9
                            color: "#ffffff"
                            Behavior on x { NumberAnimation { duration: 150 } }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: host.hideControlBackgrounds = !host.hideControlBackgrounds
                        }
                    }
                }

                // ===== 分割线 =====
                Rectangle {
                    Layout.fillWidth: true
                    height: 1
                    color: host.textMuted
                    opacity: 0.3
                }

                // ===== 背景效果 =====
                Text {
                    font.family: host.uiFontFamily
                    text: "背景效果"
                    color: host.textPrimary
                    font.pixelSize: 14
                    font.bold: true
                }

                // 模糊程度
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Text {
                        font.family: host.uiFontFamily
                        text: "模糊程度"
                        color: host.textPrimary
                        font.pixelSize: 12
                        Layout.preferredWidth: 60
                    }

                    Slider {
                        id: blurSlider
                        from: 0
                        to: 140
                        stepSize: 1
                        value: host.blurRadius
                        Layout.fillWidth: true
                        onValueChanged: host.blurRadius = value
                        background: Rectangle {
                            x: blurSlider.leftPadding
                            y: blurSlider.topPadding + blurSlider.availableHeight / 2 - height / 2
                            implicitWidth: 200
                            implicitHeight: 4
                            width: blurSlider.availableWidth
                            height: implicitHeight
                            radius: 2
                            color: host.progressBg
                            Rectangle {
                                width: blurSlider.visualPosition * parent.width
                                height: parent.height
                                color: host.accent
                                radius: 2
                            }
                        }
                        handle: Rectangle {
                            x: blurSlider.leftPadding + blurSlider.visualPosition * (blurSlider.availableWidth - width)
                            y: blurSlider.topPadding + blurSlider.availableHeight / 2 - height / 2
                            implicitWidth: 14
                            implicitHeight: 14
                            radius: 7
                            color: host.accent
                        }
                    }

                    Text {
                        font.family: host.uiFontFamily
                        text: Math.round(host.blurRadius)
                        color: host.textSecondary
                        font.pixelSize: 12
                        Layout.preferredWidth: 30
                        horizontalAlignment: Text.AlignRight
                    }
                }

                // 面板透明度
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Text {
                        font.family: host.uiFontFamily
                        text: "面板透明度"
                        color: host.textPrimary
                        font.pixelSize: 12
                        Layout.preferredWidth: 60
                    }

                    Slider {
                        id: opacitySlider
                        from: 0
                        to: 1
                        stepSize: 0.01
                        value: host.panelOpacity
                        Layout.fillWidth: true
                        onValueChanged: host.panelOpacity = value
                        background: Rectangle {
                            x: opacitySlider.leftPadding
                            y: opacitySlider.topPadding + opacitySlider.availableHeight / 2 - height / 2
                            implicitWidth: 200
                            implicitHeight: 4
                            width: opacitySlider.availableWidth
                            height: implicitHeight
                            radius: 2
                            color: host.progressBg
                            Rectangle {
                                width: opacitySlider.visualPosition * parent.width
                                height: parent.height
                                color: host.accent
                                radius: 2
                            }
                        }
                        handle: Rectangle {
                            x: opacitySlider.leftPadding + opacitySlider.visualPosition * (opacitySlider.availableWidth - width)
                            y: opacitySlider.topPadding + opacitySlider.availableHeight / 2 - height / 2
                            implicitWidth: 14
                            implicitHeight: 14
                            radius: 7
                            color: host.accent
                        }
                    }

                    Text {
                        font.family: host.uiFontFamily
                        text: Math.round(host.panelOpacity * 100) + "%"
                        color: host.textSecondary
                        font.pixelSize: 12
                        Layout.preferredWidth: 36
                        horizontalAlignment: Text.AlignRight
                    }
                }

                // 恢复默认
                Button {
                    Layout.alignment: Qt.AlignHCenter
                    text: "恢复默认颜色"
                    font.pixelSize: 11
                    onClicked: {
                        host.customAccent = ""
                        host.customDarkBg = ""
                        host.customLyricColor = ""
                        host.customLyricPlayedColor = ""
                        host.customLyricUnplayedColor = ""
                        host.customBtnBg = ""
                        
                    }
                    background: Rectangle {
                        implicitWidth: 52
                        implicitHeight: 28
                        color: host.customBtnBg !== "" ? host.customBtnBg : "#2a2a4e"
                        radius: 4
                    }
                    contentItem: Text {
                        text: parent.text
                        color: host.textPrimary
                        font: parent.font
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                // ===== 分割线 =====
                Rectangle {
                    Layout.fillWidth: true
                    height: 1
                    color: host.textMuted
                    opacity: 0.3
                }

                // ===== 显示设置 =====
                Text {
                    font.family: host.uiFontFamily
                    text: "显示设置"
                    color: host.textPrimary
                    font.pixelSize: 14
                    font.bold: true
                }

                // 行间距
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Text {
                        font.family: host.uiFontFamily
                        text: "行间距"
                        color: host.textPrimary
                        font.pixelSize: 12
                        Layout.preferredWidth: 60
                    }

                    Slider {
                        id: rowSpacingSlider
                        from: 36
                        to: 72
                        stepSize: 2
                        value: host.rowSpacing
                        Layout.fillWidth: true
                        onValueChanged: host.rowSpacing = value
                        background: Rectangle {
                            x: rowSpacingSlider.leftPadding
                            y: rowSpacingSlider.topPadding + rowSpacingSlider.availableHeight / 2 - height / 2
                            implicitWidth: 200
                            implicitHeight: 4
                            width: rowSpacingSlider.availableWidth
                            height: implicitHeight
                            radius: 2
                            color: host.progressBg
                            Rectangle {
                                width: rowSpacingSlider.visualPosition * parent.width
                                height: parent.height
                                color: host.accent
                                radius: 2
                            }
                        }
                        handle: Rectangle {
                            x: rowSpacingSlider.leftPadding + rowSpacingSlider.visualPosition * (rowSpacingSlider.availableWidth - width)
                            y: rowSpacingSlider.topPadding + rowSpacingSlider.availableHeight / 2 - height / 2
                            implicitWidth: 14
                            implicitHeight: 14
                            radius: 7
                            color: host.accent
                        }
                    }

                    Text {
                        font.family: host.uiFontFamily
                        text: Math.round(host.rowSpacing) + "px"
                        color: host.textSecondary
                        font.pixelSize: 12
                        Layout.preferredWidth: 36
                        horizontalAlignment: Text.AlignRight
                    }
                }

                // 卡片大小（卡片网格视图）
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Text {
                        font.family: host.uiFontFamily
                        text: "卡片大小"
                        color: host.textPrimary
                        font.pixelSize: 12
                        Layout.preferredWidth: 60
                    }

                    Slider {
                        id: cardSizeSlider
                        from: 90
                        to: 220
                        stepSize: 10
                        value: player.cardSize
                        Layout.fillWidth: true
                        onValueChanged: player.cardSize = value
                        background: Rectangle {
                            x: cardSizeSlider.leftPadding
                            y: cardSizeSlider.topPadding + cardSizeSlider.availableHeight / 2 - height / 2
                            implicitWidth: 200
                            implicitHeight: 4
                            width: cardSizeSlider.availableWidth
                            height: implicitHeight
                            radius: 2
                            color: host.progressBg
                            Rectangle {
                                width: cardSizeSlider.visualPosition * parent.width
                                height: parent.height
                                color: host.accent
                                radius: 2
                            }
                        }
                        handle: Rectangle {
                            x: cardSizeSlider.leftPadding + cardSizeSlider.visualPosition * (cardSizeSlider.availableWidth - width)
                            y: cardSizeSlider.topPadding + cardSizeSlider.availableHeight / 2 - height / 2
                            implicitWidth: 14
                            implicitHeight: 14
                            radius: 7
                            color: host.accent
                        }
                    }

                    Text {
                        font.family: host.uiFontFamily
                        text: player.cardSize + "px"
                        color: host.textSecondary
                        font.pixelSize: 12
                        Layout.preferredWidth: 44
                        horizontalAlignment: Text.AlignRight
                    }
                }

                // ===== 全局字体 =====
                // 之前 window.font.family 写的是一串逗号分隔的候选列表
                // （"Noto Sans CJK SC, Noto Sans CJK JP, Noto Sans, sans-serif"），
                // 交给 Qt 的字体后端自己按字符集去匹配、回退——这个自动匹配在遇到
                // 日文等复杂文字时可能选不准（比如误用了不完整覆盖日文假名/汉字
                // 变体的字体），表现为乱码或方框，而且匹配过程本身还会触发前面
                // 提到的 "OpenType support missing" 警告刷屏、甚至轻微卡顿。
                //
                // customFontFamily 这个设置项、持久化读写（saveSetting/loadSettings）
                // 和实际生效逻辑（歌词 Text 的 font.family 绑定）在代码里其实早就
                // 存在了，只是设置面板里一直没有对应的输入框，用户没有入口去真正
                // 填一个精确的字体名——这里补上这个入口：直接让用户输入一个具体、
                // 明确的字体族名字（比如系统里安装的 "Noto Sans CJK JP"），一旦
                // 填了非空值，歌词文字会直接用这个字体，完全跳过前面那串"自动
                // 搜索候选"的逻辑，不再依赖 Qt 猜哪个字体支持当前文字。
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Text {
                        font.family: host.uiFontFamily
                        text: "全局字体"
                        color: host.textPrimary
                        font.pixelSize: 12
                        Layout.preferredWidth: 60
                    }

                    TextField {
                        id: customFontInput
                        Layout.fillWidth: true
                        // 注意：text 初始值绑定到 customFontFamily，但这只在"用户还没有
                        // 手动编辑过"这个输入框时有效——QML 里只要用户在 TextField 里
                        // 打字，这个绑定就会被断开（这是 Text/TextField 的标准行为，
                        // 输入框需要能被自由编辑，不能被外部值不断打回原样）。断开之后，
                        // 如果 customFontFamily 又在别的地方被改动（比如以后新增了别的
                        // 重置入口），这个输入框不会自动跟着刷新——所以下面"清空"按钮
                        // 才需要同时手动设置 customFontInput.text 和 customFontFamily
                        // 两者，而不能只改 customFontFamily 指望输入框自动同步。以后如果
                        // 再加别的会修改 customFontFamily 的入口，也要记得同样处理。
                        text: host.customFontFamily
                        placeholderText: "留空则自动匹配，如需解决日文乱码可填 Noto Sans CJK JP"
                        color: host.textPrimary
                        font.pixelSize: 12
                        // 用回车/失焦触发应用，而不是每敲一个字符就立刻生效——
                        // 逐字符生效会导致字体解析在打字过程中反复触发，一来
                        // 没有必要（用户还没打完字），二来容易造成输入过程卡顿。
                        //
                        // 注意：按回车确认后手动 focus = false 会紧接着触发
                        // onActiveFocusChanged，如果两个 handler 都无条件赋值，
                        // customFontFamily 会被设置两次、onCustomFontFamilyChanged
                        // 也会跟着多触发一次 saveSetting（多一次不必要的磁盘写入，
                        // 虽然值相同不会出错，但没必要）。这里加一个"值真的变了
                        // 才赋值"的判断，两处 handler 共享，避免这个重复。
                        function applyIfChanged() {
                            if (host.customFontFamily !== text) host.customFontFamily = text
                        }
                        onAccepted: {
                            applyIfChanged()
                            focus = false
                        }
                        onActiveFocusChanged: {
                            if (!activeFocus) applyIfChanged()
                        }
                        background: Rectangle {
                            color: host.customBtnBg !== "" ? host.customBtnBg : "#1a1a3e"
                            radius: 6
                            border.color: "#334466"
                        }
                    }

                    Button {
                        text: "选择"
                        font.pixelSize: 11
                        onClicked: fontDialog.openFor("global", host.customFontFamily)
                        background: Rectangle {
                            implicitWidth: 52
                            implicitHeight: 28
                            color: host.customBtnBg !== "" ? host.customBtnBg : "#2a2a4e"
                            radius: 4
                        }
                        contentItem: Text {
                            text: parent.text
                            color: host.textPrimary
                            font: parent.font
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }

                    Button {
                        text: "清空"
                        font.pixelSize: 12
                        onClicked: {
                            customFontInput.text = ""
                            host.customFontFamily = ""
                        }
                        background: Rectangle {
                            implicitWidth: 52
                            implicitHeight: 28
                            color: host.customBtnBg !== "" ? host.customBtnBg : "#2a2a4e"
                            radius: 6
                        }
                        contentItem: Text {
                            text: parent.text
                            color: host.textPrimary
                            font: parent.font
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }

                // ===== 分割线 =====
                Rectangle {
                    Layout.fillWidth: true
                    height: 1
                    color: host.textMuted
                    opacity: 0.3
                    Layout.topMargin: 8
                    Layout.bottomMargin: 4
                }

                // ===== 自动切换到歌词界面 =====
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Text {
                        font.family: host.uiFontFamily
                        text: "自动切换到歌词"
                        color: host.textPrimary
                        font.pixelSize: 12
                    }

                    Item { Layout.fillWidth: true }

                    Rectangle {
                        width: 40; height: 22; radius: 11
                        color: host.autoSwitchToLyric ? host.accent : "#3a3a5e"
                        Behavior on color { ColorAnimation { duration: 150 } }

                        Rectangle {
                            x: host.autoSwitchToLyric ? 20 : 2
                            y: 2
                            width: 18; height: 18; radius: 9
                            color: "#ffffff"
                            Behavior on x { NumberAnimation { duration: 150 } }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: host.autoSwitchToLyric = !host.autoSwitchToLyric
                        }
                    }
                }

                // ===== 关闭行为 =====
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Text {
                        font.family: host.uiFontFamily
                        text: "点击 × 时隐藏到托盘"
                        color: host.textPrimary
                        font.pixelSize: 12
                    }

                    Item { Layout.fillWidth: true }

                    Rectangle {
                        width: 40; height: 22; radius: 11
                        color: host.closeToTray ? host.accent : "#3a3a5e"
                        Behavior on color { ColorAnimation { duration: 150 } }

                        Rectangle {
                            x: host.closeToTray ? 20 : 2
                            y: 2
                            width: 18; height: 18; radius: 9
                            color: "#ffffff"
                            Behavior on x { NumberAnimation { duration: 150 } }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: host.closeToTray = !host.closeToTray
                        }
                    }
                }

                // ===== 回退设置（设置页最下方） =====
                // 恢复到上一次保存的全部设置（最多连续回退两次，对应
                // .bak1/.bak2 两个历史版本）；回退后整个界面重载。
                // 拖动滑块等密集保存会被合并为一个历史版本（3 秒静默
                // 窗口），回退恢复到"这一轮修改之前"而不是中间值。
                Button {
                    Layout.alignment: Qt.AlignHCenter
                    text: "回退上次设置"
                    font.pixelSize: 11
                    enabled: player.hasSettingsBackup
                    onClicked: player.rollbackSettings()
                    background: Rectangle {
                        implicitWidth: 52
                        implicitHeight: 28
                        color: host.customBtnBg !== "" ? host.customBtnBg : "#2a2a4e"
                        radius: 4
                    }
                    contentItem: Text {
                        text: parent.text
                        color: enabled ? host.textPrimary : host.textMuted
                        font: parent.font
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                // ===== 分割线 =====
                Rectangle {
                    Layout.fillWidth: true
                    Layout.topMargin: 10
                    Layout.bottomMargin: 4
                    height: 1
                    color: host.textMuted
                    opacity: 0.3
                }

                // ===== 桌面歌词设置 =====
                Text {
                    font.family: host.uiFontFamily
                    text: "桌面歌词"
                    color: host.textPrimary
                    font.pixelSize: 14
                    font.bold: true
                }

                // 桌面歌词开关
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Text {
                        font.family: host.uiFontFamily
                        text: "启用桌面歌词"
                        color: host.textPrimary
                        font.pixelSize: 12
                    }

                    Text {
                        font.family: host.uiFontFamily
                        text: appBridge && appBridge.desktopAvailable ? "" : "（不可用）"
                        color: host.textMuted
                        font.pixelSize: 10
                    }

                    Item { Layout.fillWidth: true }

                    Rectangle {
                        width: 40; height: 22; radius: 11
                        color: (appBridge && appBridge.desktopLyricsEnabled) ? host.accent : "#3a3a5e"
                        opacity: appBridge && appBridge.desktopAvailable ? 1.0 : 0.4
                        Behavior on color { ColorAnimation { duration: 150 } }

                        Rectangle {
                            x: (appBridge && appBridge.desktopLyricsEnabled) ? 20 : 2
                            y: 2
                            width: 18; height: 18; radius: 9
                            color: "#ffffff"
                            Behavior on x { NumberAnimation { duration: 150 } }
                        }

                        MouseArea {
                            anchors.fill: parent
                            enabled: appBridge && appBridge.desktopAvailable
                            cursorShape: Qt.PointingHandCursor
                            onClicked: appBridge && appBridge.setDesktopLyrics(!appBridge.desktopLyricsEnabled)
                        }
                    }
                }

                // 桌面歌词锁定（开关：决定是否可以直接被挪动）
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Text {
                        font.family: host.uiFontFamily
                        text: "锁定歌词"
                        color: host.textPrimary
                        font.pixelSize: 12
                    }

                    Text {
                        font.family: host.uiFontFamily
                        text: "开启后不可拖动"
                        color: host.textMuted
                        font.pixelSize: 10
                    }

                    Item { Layout.fillWidth: true }

                    Rectangle {
                        width: 40; height: 22; radius: 11
                        color: host.desktopLyricLocked ? host.accent : "#3a3a5e"
                        opacity: appBridge && appBridge.desktopAvailable ? 1.0 : 0.4
                        Behavior on color { ColorAnimation { duration: 150 } }

                        Rectangle {
                            x: host.desktopLyricLocked ? 20 : 2
                            y: 2
                            width: 18; height: 18; radius: 9
                            color: "#ffffff"
                            Behavior on x { NumberAnimation { duration: 150 } }
                        }

                        MouseArea {
                            anchors.fill: parent
                            enabled: appBridge && appBridge.desktopAvailable
                            cursorShape: Qt.PointingHandCursor
                            onClicked: host.desktopLyricLocked = !host.desktopLyricLocked
                        }
                    }
                }

                // 桌面歌词字体
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Text {
                        font.family: host.uiFontFamily
                        text: "歌词字体"
                        color: host.textPrimary
                        font.pixelSize: 12
                        Layout.preferredWidth: 60
                    }

                    Text {
                        font.family: host.uiFontFamily
                        text: host.desktopLyricFont !== "" ? host.desktopLyricFont : "（默认）"
                        color: host.desktopLyricFont !== "" ? host.textPrimary : host.textMuted
                        font.pixelSize: 12
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }

                    Button {
                        text: "选择"
                        font.pixelSize: 11
                        onClicked: fontDialog.openFor("desktop", host.desktopLyricFont)
                        background: Rectangle {
                            implicitWidth: 52
                            implicitHeight: 28
                            color: host.customBtnBg !== "" ? host.customBtnBg : "#2a2a4e"
                            radius: 6
                        }
                        contentItem: Text {
                            text: parent.text
                            color: host.textPrimary
                            font: parent.font
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }

                    Button {
                        text: "重置"
                        font.pixelSize: 11
                        onClicked: host.desktopLyricFont = ""
                        background: Rectangle {
                            implicitWidth: 52
                            implicitHeight: 28
                            color: host.customBtnBg !== "" ? host.customBtnBg : "#2a2a4e"
                            radius: 6
                        }
                        contentItem: Text {
                            text: parent.text
                            color: host.textPrimary
                            font: parent.font
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }

                // 桌面歌词颜色
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Text {
                        font.family: host.uiFontFamily
                        text: "歌词颜色"
                        color: host.textPrimary
                        font.pixelSize: 12
                        Layout.preferredWidth: 60
                    }

                    Rectangle {
                        width: 22; height: 22; radius: 4
                        color: host.desktopLyricColor !== "" ? host.desktopLyricColor : "#ffffff"
                        border.color: host.textMuted
                        border.width: 1
                    }

                    Item { Layout.fillWidth: true }

                    Button {
                        text: "选择"
                        font.pixelSize: 11
                        onClicked: openColorDialog("desktopLyricColor", host.desktopLyricColor !== "" ? host.desktopLyricColor : "#ffffff")
                        background: Rectangle {
                            implicitWidth: 52
                            implicitHeight: 28
                            color: host.customBtnBg !== "" ? host.customBtnBg : "#2a2a4e"
                            radius: 4
                        }
                        contentItem: Text {
                            text: parent.text
                            color: host.textPrimary
                            font: parent.font
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }

            }
        }
    }

    // ===== 颜色选择对话框（静态共享实例，用 colorDialogTarget 记录本次设置目标） =====
    property string colorDialogTarget: ""

    function openColorDialog(target, currentColor) {
        colorDialogTarget = target
        colorDialog.selectedColor = currentColor
        colorDialog.open()
    }

    ColorDialog {
        id: colorDialog
        onAccepted: {
            switch (colorDialogTarget) {
                case "customAccent": host.customAccent = selectedColor; break
                case "customDarkBg": host.customDarkBg = selectedColor; break
                case "customLyricColor": host.customLyricColor = selectedColor; break
                case "customLyricPlayedColor": host.customLyricPlayedColor = selectedColor; break
                case "customLyricUnplayedColor": host.customLyricUnplayedColor = selectedColor; break
                case "customBtnBg": host.customBtnBg = selectedColor; break
                case "customSettingsBg": host.customSettingsBg = selectedColor; break
                case "customDownloadBg": host.customDownloadBg = selectedColor; break
                case "desktopLyricColor": host.desktopLyricColor = selectedColor; break
                
            }
        }
    }

    // ===== 字体选择对话框（自定义列表，不依赖原生 Dialog） =====
    Dialog {
        id: fontDialog
        title: "选择字体"
        modal: true
        width: 380
        height: 480
        padding: 0

        property var allFonts: Qt.fontFamilies()
        property string _selectedFont: ""
        // 目标：用于区分对话框服务的是"全局字体"还是"桌面歌词字体"。
        // 打开前用 openFor(targetContent, targetValue) 设置。
        property string target: "global"   // "global" | "desktop"

        function openFor(t, value) {
            fontDialog.target = t
            fontDialog._selectedFont = value || ""
            fontDialog.open()
        }

        onAccepted: {
            if (_selectedFont) {
                if (fontDialog.target === "desktop") {
                    host.desktopLyricFont = _selectedFont
                } else {
                    host.customFontFamily = _selectedFont
                    customFontInput.text = _selectedFont
                }
            }
        }

        background: Rectangle {
            color: Qt.rgba(host.bgDark.r, host.bgDark.g, host.bgDark.b, 1)
            radius: 8
        }

        header: Rectangle {
            implicitHeight: 44
            color: "transparent"
            Text {
                font.family: host.uiFontFamily
                anchors.centerIn: parent
                text: fontDialog.target === "desktop" ? "选择桌面歌词字体" : "选择全局字体"
                color: host.textPrimary
                font.pixelSize: 15
                font.bold: true
            }
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 10

            TextField {
                id: searchField
                Layout.fillWidth: true
                placeholderText: "搜索字体..."
                color: host.textPrimary
                font.pixelSize: 12
                background: Rectangle {
                    color: host.customBtnBg !== "" ? host.customBtnBg : "#1a1a3e"
                    radius: 6
                    border.color: "#334466"
                }
            }

            ListView {
                id: fontListView
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                boundsBehavior: Flickable.DragAndOvershootBounds
                flickDeceleration: 2000

                property var _filtered: {
                    var raw = fontDialog.allFonts
                    var q = searchField.text.toLowerCase()
                    if (!q) return raw
                    var out = []
                    for (var i = 0; i < raw.length; i++) {
                        if (raw[i].toLowerCase().indexOf(q) !== -1)
                            out.push(raw[i])
                    }
                    return out
                }

                model: _filtered
                delegate: Rectangle {
                    width: parent.width
                    height: 36
                    radius: 4
                    color: fontDialog._selectedFont === modelData
                        ? host.accent
                        : (fontMouse.containsMouse ? Qt.rgba(1,1,1,0.08) : "transparent")

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: 8
                        text: modelData
                        color: fontDialog._selectedFont === modelData ? "#fff" : host.textPrimary
                        font.family: modelData
                        font.pixelSize: 13
                        elide: Text.ElideRight
                    }

                    MouseArea {
                        id: fontMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: fontDialog._selectedFont = modelData
                    }
                }

                ScrollBar.vertical: ScrollBar {
                    policy: ScrollBar.AsNeeded
                    width: 6
                    contentItem: Rectangle {
                        implicitWidth: 6
                        radius: 3
                        color: Qt.rgba(host.accent.r, host.accent.g, host.accent.b, 0.55)
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Item { Layout.fillWidth: true }
                Button {
                    text: "取消"
                    font.pixelSize: 12
                    onClicked: fontDialog.reject()
                    background: Rectangle {
                        implicitWidth: 60
                        implicitHeight: 28
                        color: host.customBtnBg !== "" ? host.customBtnBg : "#2a2a4e"
                        radius: 6
                    }
                    contentItem: Text {
                        text: parent.text
                        color: host.textSecondary
                        font: parent.font
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
                Button {
                    text: "确定"
                    font.pixelSize: 12
                    enabled: fontDialog._selectedFont !== ""
                    onClicked: fontDialog.accept()
                    background: Rectangle {
                        implicitWidth: 60
                        implicitHeight: 28
                        color: enabled ? host.accent : "#3a3a5e"
                        radius: 6
                    }
                    contentItem: Text {
                        text: parent.text
                        color: enabled ? "#fff" : host.textMuted
                        font: parent.font
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }
        }
    }

    // ===== 文件夹选择对话框 =====
    FolderDialog {
        id: folderDialog
        onAccepted: {
            // selectedFolder.toString() 返回的是 URL（如 file:///home/user/My%20Music），
            // 必须去掉 file:// 前缀并做百分号解码——否则含空格/中文的路径
            // 会带着 %20 等编码写进输入框，setMusicDir 判断目录不存在而静默失败
            var urlStr = selectedFolder.toString()
            if (urlStr.indexOf("file://") === 0)
                urlStr = urlStr.slice("file://".length)
            musicDirInput.text = decodeURIComponent(urlStr)
        }
    }
}
