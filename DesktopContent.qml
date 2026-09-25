import QtQuick 2.15

// 桌面歌词 UI 组件（desktop.qml / desktop_layer.qml 共用）。
// 根元素由外壳提供：desktop.qml 是普通 Item（QQuickView 容器），
// desktop_layer.qml 是带 org.kde.layershell 附加属性的 Window（层模式）。
//
// 桥接对象 player（desktop.py 注入）：
//   - groupCount    : 分组（块）数量；同时间戳的"原文/译文"并成一个块
//   - curGroup      : 当前播放所在的块号 (indexChanged 通知)
//   - groupSize(g)  : 第 g 块的行数（一般 1 或 2）
//   - groupText(g,s): 第 g 块第 s 行文本
//   - stateText     : "playing"/"paused"/"stopped" (stateChanged 通知)
//
// 窗口不可拖动：移动请用 KWin 原生强制拖动（Meta+左键），位置在窗口
// 关闭时由 KWin 脚本查询保存（见 desktop.py close()）。

Item {
    id: root
    width: 900
    height: 120

    // 半透明背景圆角板（置微小，便于调试；正式可设 0）
    Rectangle {
        anchors.fill: parent
        radius: 12
        color: "#66000000"
        opacity: 0.3
    }

    // ---- 排版参数 ----
    // 单行行高 / 块内双语两行之间的间隙 / 块与块之间的间距
    readonly property real lineH: 54
    readonly property real innerGap: 8
    readonly property real blockGap: 30   // 块间距（用户要求略微加大两块距离）

    property int groupCount: player ? player.groupCount : 0

    // 每块的固有高度（不含块间距）：1 行 = lineH；双语 2 行 = 2*lineH + innerGap
    function blockHeight(g) {
        if (g < 0 || g >= (player ? player.groupCount : 0)) return lineH
        var s = player.groupSize(g)
        return s * lineH + (s - 1) * innerGap
    }

    // groupBaseY(g)：第 g 块的顶边相对"第 0 块顶边"的累积偏移（含块间距）
    property var _gbY: []
    property real _contentH: 0
    function _rebuildBaseY() {
        var arr = []
        var base = 0
        var n = player ? player.groupCount : 0
        for (var g = 0; g < n; g++) {
            arr.push(base)
            base += blockHeight(g) + blockGap
        }
        _gbY = arr
        _contentH = base > 0 ? base : 0
    }
    onGroupCountChanged: _rebuildBaseY()
    Component.onCompleted: _rebuildBaseY()

    // 滚动区：窗口内裁切，内容整体上下平移
    Item {
        id: scroller
        anchors.fill: parent
        clip: true

        Item {
            id: content
            width: scroller.width
            height: root._contentH
            // 注意：content.y 不用绑定（绑定驱动的变化不会触发 Behavior 动画），
            // 而是在 onScrollYChanged 里手动赋值，让下面的 Behavior on y 生效，
            // 实现弹簧滚动。这样 scrollY 作为纯目标值即时更新。
            Behavior on y {
                SpringAnimation {
                    spring: 1.8
                    damping: 0.55
                    mass: 1.0
                    epsilon: 0.05
                }
            }

            // 每个块一行（块内用 Repeater 排 1~2 行文字）
            Repeater {
                model: player ? player.groupCount : 0
                delegate: Item {
                    id: blk

                    // 注意：内层还有一层 Repeater，其 delegate 里的裸 `index`
                    // 会覆盖这里的 `index`。所以把"本块的索引"存成命名属性
                    // groupIndex 供内层使用，避免取到内层行索引（全部串成 XXXX）。
                    readonly property int groupIndex: index

                    width: content.width
                    height: root.blockHeight(groupIndex)
                    x: 0
                    y: (root._gbY.length > groupIndex) ? root._gbY[groupIndex] : 0

                    readonly property bool active: groupIndex === root.curGroup

                    Column {
                        anchors.centerIn: parent
                        spacing: root.innerGap
                        width: parent.width - 40
                        Repeater {
                            model: player ? player.groupSize(blk.groupIndex) : 0
                            Text {
                                width: parent.width
                                height: root.lineH
                                text: player ? player.groupText(blk.groupIndex, modelData) : ""
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                                // 字体/当前行颜色由主面板"桌面歌词设置"控制
                                //（通过 player.desktopFont / player.desktopColor 传入）；
                                // 空值回退到默认。
                                font.family: (player && player.desktopFont !== "") ? player.desktopFont : "Noto Sans CJK SC"
                                font.pixelSize: 30
                                font.weight: blk.active ? Font.DemiBold : Font.Normal
                                color: blk.active
                                       ? ((player && player.desktopColor !== "") ? player.desktopColor : "#ffffff")
                                       : "#99ffffff"
                                style: Text.Outline
                                styleColor: "#80000000"
                                elide: Text.ElideRight
                            }
                        }
                    }
                }
            }
        }
    }

    // 当前块 & 滚动位置
    property int curGroup: player ? player.curGroup : -1
    // 滚轮累计量：鼠标一格 120，触控板是连续小值，累计到 ±120 再调一档
    property real _wheelAccum: 0
    onCurGroupChanged: _onGroupChanged()
    // scrollY 是纯目标值（无 Behavior），_onGroupChanged 即时更新；
    // content 的滚动动画由其自身的 Behavior on y 提供。
    property real scrollY: 0
    onScrollYChanged: {
        if (Math.abs(content.y + scrollY) > 0.05) content.y = -scrollY
    }
    function _onGroupChanged() {
        if (curGroup < 0 || (player ? player.groupCount : 0) <= 0) return
        var base = (_gbY.length > curGroup) ? _gbY[curGroup] : 0
        var bh = blockHeight(curGroup)
        scrollY = Math.max(0, base + bh / 2 - root.height / 2)
    }
    Connections {
        target: player
        function onIndexChanged(idx) { root.curGroup = player ? player.curGroup : -1 }
        function onStateChanged() {
            var on = player && player.stateText === "playing"
            fadeAnim.stop(); fadeAnim.to = on ? 1.0 : 0.25; fadeAnim.start()
        }
    }

    // 无歌词占位
    Text {
        anchors.centerIn: parent
        text: "♪ 暂无歌词"
        font.pixelSize: 20
        color: "#60ffffff"
        visible: player ? player.groupCount === 0 : true
    }

    NumberAnimation {
        id: fadeAnim
        target: root
        property: "opacity"
        duration: 300
    }

    // 右键菜单 + 左键拖动：
    // 可交互性由 Python 侧"锁定歌词"开关决定（持久化 desktopLyricLocked）：
    //   锁定 → 整窗点击穿透（WindowTransparentForInput），本层收不到事件；
    //   取消锁定 → 右键弹出自绘菜单（隐藏）；左键按 player.dragMode：
    //     "system"（普通窗口）：startSystemMove() 合成器原生移动窗口，
    //       onReleased 通知 Python 保存位置（借道 KWin 脚本查真实坐标）；
    //     "none"（层窗口，PYMUSIC_DESKTOP_LYRIC_LAYER_SHELL=1）：不可
    //       拖动——layer surface 在 KWin 里 isMovableAcrossScreens()=false，
    //       连 Meta+左键 强制拖动都无效（协议硬限制）。
    MouseArea {
        id: dragArea
        anchors.fill: parent
        z: 10
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.ArrowCursor

        onPressed: (mouse) => {
            if (mouse.button === Qt.RightButton) {
                mouse.accepted = true
                if (player && player.showContextMenu) {
                    var gp = mapToGlobal(mouse.x, mouse.y)
                    player.showContextMenu(gp.x, gp.y)
                }
                return
            }
            if (player && player.dragMode === "system") {
                if (root.window && typeof root.window.startSystemMove === "function") {
                    root.window.startSystemMove()
                }
            }
        }

        onReleased: (mouse) => {
            if (mouse.button === Qt.LeftButton) {
                if (player && player.dragFinished) {
                    player.dragFinished()
                }
            }
        }
    }

    // 非锁定状态下：滚轮调节音量（每档 5，与主界面一致）。
    // 锁定状态整窗点击穿透，本层收不到事件；这里再用 player.locked 兜底。
    // 触控板连续滚动累计到 ±120 才调一档，避免每帧写 pactl。
    WheelHandler {
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        enabled: player ? !player.locked : false
        onWheel: (event) => {
            if (!player)
                return
            root._wheelAccum += event.angleDelta.y
            var step = 120
            if (root._wheelAccum >= step) {
                var up = Math.floor(root._wheelAccum / step)
                root._wheelAccum -= up * step
                player.adjustVolume(up)
            } else if (root._wheelAccum <= -step) {
                var down = Math.ceil(root._wheelAccum / step)
                root._wheelAccum -= down * step
                player.adjustVolume(down)
            }
            event.accepted = true
        }
    }
}
