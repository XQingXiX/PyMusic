import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window

// ===== 下载窗口（独立窗口）=====
// 由 main.qml 在首次打开时惰性创建；host 为主窗口。
Window {
    id: downloadWindow
    required property var host

    // 尺寸：优先使用上次关闭时保存的尺寸（与主程序写入同一个 config 文件）
    property var _savedSize: player.loadSettings()
    width: _savedSize.downloadWinW > 0 ? _savedSize.downloadWinW : Math.max(Math.round(host.width / 3), 360)
    height: _savedSize.downloadWinH > 0 ? _savedSize.downloadWinH : host.height
    title: "在线下载歌词/封面"
    // 背景色：可在设置里调整（customDownloadBg）；未设置则跟随主主题深色背景
    readonly property color panelBg: host.customDownloadBg !== "" ? host.customDownloadBg : host.bgDark
    color: panelBg
    visible: true

    // 搜索框是否被用户手动编辑过（编辑过则不再随切歌自动刷新预填内容）
    property bool _searchBoxEdited: false

    // 关闭前把当前尺寸写回 config（关闭按钮 / 隐藏都会触发）
    function _persistSize() {
        player.saveSetting("downloadWinW", width)
        player.saveSetting("downloadWinH", height)
    }

    onClosing: function(closeEvent) {
        _persistSize()
        host.downloadVisible = false
    }
    onVisibleChanged: {
        if (visible) {
            _searchBoxEdited = false
            searchInput.text = player.currentSongName || ""
        } else {
            _persistSize()
            if (host && host.downloadVisible)
                host.downloadVisible = false
        }
    }

    // 切歌时刷新搜索框预填（未手动编辑过时）
    Connections {
        target: player
        function onSongChanged(index) {
            if (!_searchBoxEdited)
                searchInput.text = player.currentSongName || ""
        }
    }

        Rectangle {
            id: downloadPanel
            anchors.fill: parent
            color: downloadWindow.panelBg

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 20
                spacing: 12

                // 标题
                Text {
                    font.family: host.uiFontFamily
                    text: "在线下载歌词/封面"
                    color: host.textPrimary
                    font.pixelSize: 16
                    font.bold: true
                }

                // 当前歌曲
                Text {
                    font.family: host.uiFontFamily
                    text: "当前歌曲: " + (player.currentSongName || "无")
                    color: host.textSecondary
                    font.pixelSize: 12
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }

                // 搜索框
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Rectangle {
                        Layout.fillWidth: true
                        height: 36
                        radius: 6
                        color: "#2a2a4e"
                        border.color: "#3a3a5e"
                        border.width: 1

                        TextInput {
                            id: searchInput
                            anchors.fill: parent
                            anchors.margins: 8
                            color: host.textPrimary
                            font.pixelSize: 13
                            clip: true
                            text: player.currentSongName || ""
                            onTextEdited: _searchBoxEdited = true
                        }
                    }

                    Rectangle {
                        width: 60
                        height: 36
                        radius: 6
                        color: host.accent
                        Behavior on color { ColorAnimation { duration: 100 } }

                        Text {
                            font.family: host.uiFontFamily
                            anchors.centerIn: parent
                            text: "搜索"
                            color: "#fff"
                            font.pixelSize: 12
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: player.searchNetEase(searchInput.text)
                        }
                    }
                }

                // 状态提示
                Text {
                    font.family: host.uiFontFamily
                    id: downloadStatusText
                    text: player.downloadStatus || ""
                    color: host.textSecondary
                    font.pixelSize: 12
                    visible: text !== ""
                    Layout.fillWidth: true
                }

                // 搜索结果列表
                ListView {
                    id: searchResultList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    spacing: 8
                    flickDeceleration: 2000
                    model: player.searchResultModel

                    delegate: Rectangle {
                        width: ListView.view.width
                        height: 72
                        radius: 8
                        color: "#1a2a4e"

                        RowLayout {
                            anchors.fill: parent
                            anchors.margins: 10
                            spacing: 10

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2

                                Text {
                                    font.family: host.uiFontFamily
                                    text: modelData.name || ""
                                    color: host.textPrimary
                                    font.pixelSize: 13
                                    font.bold: true
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }

                                Text {
                                    font.family: host.uiFontFamily
                                    text: (modelData.artist || "") + (modelData.album ? " · " + modelData.album : "")
                                    color: host.textSecondary
                                    font.pixelSize: 11
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }

                                // 歌曲时长（小标题下方）：duration 为 0（接口
                                // 未返回）时隐藏，不占空间
                                Text {
                                    font.family: host.uiFontFamily
                                    text: modelData.duration > 0 ? player.formatTime(modelData.duration / 1000) : ""
                                    color: host.textMuted
                                    font.pixelSize: 11
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                    visible: text !== ""
                                }
                            }

                            // 下载歌词
                            Rectangle {
                                width: 52
                                height: 28
                                radius: 6
                                color: host.accent
                                Behavior on color { ColorAnimation { duration: 100 } }

                                Text {
                                    font.family: host.uiFontFamily
                                    anchors.centerIn: parent
                                    text: "歌词"
                                    color: "#fff"
                                    font.pixelSize: 11
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: player.downloadLyric(modelData.id, player.songPath(player.currentIndex))
                                }
                            }

                            // 下载封面
                            Rectangle {
                                width: 52
                                height: 28
                                radius: 6
                                color: host.accent
                                Behavior on color { ColorAnimation { duration: 100 } }

                                Text {
                                    font.family: host.uiFontFamily
                                    anchors.centerIn: parent
                                    text: "封面"
                                    color: "#fff"
                                    font.pixelSize: 11
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: player.downloadCover(modelData.picUrl, player.songPath(player.currentIndex), modelData.id)
                                }
                            }
                        }
                    }
                }
            }
        }
}
