import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import QtQuick.Dialogs
import QtQuick.Window
import QtQuick.Effects

ApplicationWindow {
    id: window
    visible: true
    width: 960
    height: 640
    minimumWidth: 720
    minimumHeight: 480
    title: "PyMusic"
    // 无边框 + 透明窗口：顶栏内部绘制、圆角由 rootSurface 裁剪。
    // 按平台能力启用：xcb 支持；wayland 下 KDE Plasma(KWin) 支持
    // startSystemMove/Resize，GNOME 等不支持则回退原生顶栏。
    property bool _frameless: player.framelessSupported
    flags: _frameless ? Qt.FramelessWindowHint : Qt.Window
    color: "transparent"

    // 启动防白屏：首帧渲染完成前内容保持全透明（opacity 0），首帧交换后
    // 250ms 淡入——用户看到的是"窗口淡入"而不是"白屏→内容"。
    // 注意：淡入必须作用在窗口内的根容器 rootSurface 上，不能作用在
    // ApplicationWindow 上——Wayland 平台不支持窗口级透明度，对
    // window.opacity 的每次赋值都会刷一条
    // "This plugin does not support setting window opacity" 警告
    // （250ms 动画约 37 帧 = 37 条）。
    property bool _booted: false
    onFrameSwapped: {
        if (!window._booted) {
            window._booted = true
            bootFadeIn.start()
        }
    }
    NumberAnimation {
        id: bootFadeIn
        target: rootSurface
        property: "opacity"
        from: 0
        to: 1
        duration: 250
        easing.type: Easing.OutCubic
    }

    // 点击 × 时：根据 closeToTray 决定隐藏到托盘还是退出。
    // 系统没有可用托盘时（部分精简桌面环境），隐藏窗口会导致程序
    // 无任何入口可恢复，必须直接退出。
    onClosing: function(closeEvent) {
        if (closeToTray && appBridge.trayAvailable) {
            closeEvent.accepted = false
            window.hide()
        } else {
            appBridge.quitApp()
        }
    }

    // ========== 全局字体 ==========
    // 注：window.font 不会被普通 Text 继承，此列表仅作兜底候选；
    // 真正的"全局字体"由 customFontFamily + player.applyGlobalFont()
    // （QGuiApplication.setFont）下发，见下方设置区。
    // 字体族列表按顺序尝试，命中第一个系统里存在、且能覆盖当前文字的即可。
    //
    // 之前只写了 "Noto Sans CJK SC"（SC = Simplified Chinese，简体中文子集）。
    // 打开日文歌词时终端会刷屏 "qt.text.font.db: OpenType support missing for
    // ..., script XX" 这类警告——这条警告本身来自 Qt 字体数据库在做复杂文字
    // 塑形(shaping)时，发现当前尝试的字体缺少某个 script 对应的 OpenType 表，
    // 多数情况下是无害的噪音（只要实际显示的文字不是方框/乱码），但如果系统里
    // 字体数量较多，Qt 为了找到"能正确渲染这段文字"的字体会遍历一遍字体库，
    // 这个过程可能造成明显卡顿——这正是"打开日文歌词时" 触发的原因：CJK SC
    // 子集虽然通常也内置了假名和常用汉字字形，但不是针对日文排版规则优化的，
    // 遇到日文文字时更容易命中这条警告分支。
    //
    // 这里追加 "Noto Sans CJK JP"（日文子集）作为候选，让 Qt 在遇到日文歌词时
    // 能优先匹配到专门支持日文的字体，减少警告刷屏和查找开销。这个改动是安全的
    // 纯追加：如果系统里没有安装这个字体，Qt 会静默跳过、自动尝试列表里下一个
    // 候选，不会报错也不会让现有的中文/英文显示变得更差。
    font.family: "Noto Sans CJK JP, Noto Sans CJK SC, Noto Sans, sans-serif"

    // ========== 深色模式（固定深色，无亮色切换） ==========
    property bool darkMode: true

    // ========== 颜色主题（跟随深色背景 customDarkBg） ==========
    property color bgDark: customDarkBg !== "" ? customDarkBg : "#1a1a2e"
    property color bgPanel: "#16213e"
    property color bgCard: "#0f3460"
    property color accent: customAccent !== "" ? customAccent : "#e94560"
    property color accentHover: "#ff6b81"
    property color textPrimary: "#eaeaea"
    property color textSecondary: "#8899aa"
    property color textMuted: "#556677"
    property color progressBg: "#2a2a4e"
    property color progressFill: customAccent !== "" ? customAccent : "#e94560"

    // 自定义颜色（空字符串表示使用默认值）
    property string customAccent: ""
    property string customDarkBg: ""
    property string customLyricColor: ""
    property string customLyricPlayedColor: ""
    property string customLyricUnplayedColor: ""
    property string customBtnBg: ""

    // 桌面歌词样式（空字符串表示使用默认值）
    property string desktopLyricFont: ""     // 桌面歌词字体族
    property string desktopLyricColor: ""    // 桌面歌词当前行颜色
    // 桌面歌词"锁定歌词"：开启后窗口点击穿透、不可挪动
    property bool desktopLyricLocked: false

    // 解析后的颜色属性（string → color，用于 lyrics 等 var 上下文，避免 .r/.g/.b 失效）
    property color _resolvedLyricColor: customLyricColor !== "" ? customLyricColor : accent
    property color _resolvedLyricPlayedColor: customLyricPlayedColor !== "" ? customLyricPlayedColor : textMuted
    property color _resolvedLyricUnplayedColor: customLyricUnplayedColor !== "" ? customLyricUnplayedColor : textSecondary

    // 背景效果
    property real blurRadius: 80
    property real panelOpacity: 0.45

    // 播放列表折叠状态
    property bool playlistVisible: player.playlistVisible

    // 隐藏控件底色
    property bool hideControlBackgrounds: false

    // 显示设置
    property real rowSpacing: 48
    property string customFontFamily: ""

    // 全局字体统一入口：customFontFamily 非空时用自定义字体，
    // 否则用 window 的 CJK 候选列表。所有 Text 的 font.family 都绑定它
    // （QML 普通 Text 不继承 window.font，也不跟随 QGuiApplication 默认
    // 字体——实测两种方式都无效，必须逐处显式绑定）。
    readonly property string uiFontFamily: customFontFamily !== "" ? customFontFamily : window.font.family

    // 设置面板状态
    property bool settingsVisible: false

    function toggleSettings() {
        settingsVisible = !settingsVisible
        console.log("[UI] 设置面板 " + (settingsVisible ? "打开" : "关闭"))
    }

    // 颜色线性插值：t=0 → 精确 c1，t=1 → 精确 c2（含 alpha）
    function mixColor(c1, c2, t) {
        return Qt.rgba(c1.r + (c2.r - c1.r) * t,
                       c1.g + (c2.g - c1.g) * t,
                       c1.b + (c2.b - c1.b) * t,
                       c1.a + (c2.a - c1.a) * t)
    }

    // 下载面板状态
    property bool downloadVisible: false

    function toggleDownload() {
        downloadVisible = !downloadVisible
        console.log("[UI] 下载面板 " + (downloadVisible ? "打开" : "关闭"))
        if (downloadVisible) {
            // 打开面板时重置"用户手动编辑"标记并刷新预填：
            // 否则用户编辑过一次后 _searchBoxEdited 永久为 true，
            // 之后切歌时预填被跳过，搜索框不再跟随当前歌曲
            window._searchBoxEdited = false
            searchInput.text = player.currentSongName || ""
        }
    }

    // 自动切换到歌词界面（播放键点击 + 歌曲列表点击）
    property bool autoSwitchToLyric: true
    // 点击右上角 × 时隐藏到托盘（true）还是退出程序（false）
    property bool closeToTray: true

    // ===== 封面刷新版本号 =====
    // 重新下载封面会覆盖原文件，路径字符串不变，QML Image 的 source
    // 绑定不会重新求值、Qt 图片缓存也不会重载同 URL 的图片，导致
    // 界面一直显示旧封面。把版本号拼进 file:// URL 的 query
    // （封面 ?c=N、背景 ?b=N、缩略图 ?t=N），换 URL 键强制重新加载。
    // （实测 file:// 带 query 可正常加载，且 query 变化会触发重载）
    property int coverStamp: 0

    // ===== 输入框聚焦检测 =====
    // 任何可聚焦控件获得焦点时禁用全局快捷键。除输入框（打字时空格/
    // 方向键）外，Qt 的 QShortcutMap 会在焦点控件收到按键之前拦截事件：
    // - Slider 聚焦时按 ←/→：本该调节滑块值，却触发 seek（重启 ffplay）
    // - Button 聚焦时按空格：本该激活按钮，却触发播放/暂停
    // activeFocusItem 有变更通知，绑定会在焦点转移时自动重新求值。
    readonly property bool _isTyping: {
        var f = window.activeFocusItem
        if (f === null)
            return false
        return f instanceof TextInput || f instanceof TextField
            || f instanceof Slider || f instanceof Button
    }

    // 下载面板搜索框是否被用户手动编辑过（编辑过则不再随切歌自动刷新预填内容）
    property bool _searchBoxEdited: false

    function switchToLyric() {
        if (autoSwitchToLyric) {
            player.playlistVisible = false
        }
    }

    // ========== 设置持久化 ==========
    function saveSetting(key, value) {
        player.saveSetting(key, String(value))
    }

    function saveAllSettings() {
        saveSetting("customAccent", customAccent)
        saveSetting("customDarkBg", customDarkBg)
        saveSetting("customLyricColor", customLyricColor)
        saveSetting("customLyricPlayedColor", customLyricPlayedColor)
        saveSetting("customLyricUnplayedColor", customLyricUnplayedColor)
        saveSetting("customBtnBg", customBtnBg)
        saveSetting("blurRadius", blurRadius)
        saveSetting("panelOpacity", panelOpacity)
        saveSetting("hideControlBackgrounds", hideControlBackgrounds)
        saveSetting("sortMode", player.sortMode)
        saveSetting("rowSpacing", rowSpacing)
        saveSetting("customFontFamily", customFontFamily)
        saveSetting("autoSwitchToLyric", autoSwitchToLyric)
        saveSetting("closeToTray", closeToTray)
        saveSetting("desktopLyricFont", desktopLyricFont)
        saveSetting("desktopLyricColor", desktopLyricColor)
        saveSetting("desktopLyricLocked", desktopLyricLocked)
        saveSetting("volume", player.volume)
    }

    // 从配置文件加载全部设置并应用到 UI/player。
    // 启动时调用一次；设置回退（settingsRolledBack）后再次调用，
    // 让整个界面回到上一次保存的状态。
    function reloadSettings() {
        var s = player.loadSettings()
        if (s.customAccent !== undefined) customAccent = s.customAccent
        if (s.customDarkBg !== undefined) customDarkBg = s.customDarkBg
        if (s.customLyricColor !== undefined) customLyricColor = s.customLyricColor
        if (s.customLyricPlayedColor !== undefined) customLyricPlayedColor = s.customLyricPlayedColor
        if (s.customLyricUnplayedColor !== undefined) customLyricUnplayedColor = s.customLyricUnplayedColor
        if (s.customBtnBg !== undefined) customBtnBg = s.customBtnBg
        
        if (s.blurRadius !== undefined) blurRadius = s.blurRadius
        if (s.panelOpacity !== undefined) panelOpacity = s.panelOpacity
        if (s.hideControlBackgrounds !== undefined) hideControlBackgrounds = s.hideControlBackgrounds
        if (s.sortMode !== undefined) player.sortMode = s.sortMode
        if (s.rowSpacing !== undefined) rowSpacing = s.rowSpacing
        if (s.customFontFamily !== undefined) customFontFamily = s.customFontFamily
        // 全局字体：customFontFamily 通过 QGuiApplication.setFont 下发给
        // 整个应用（QML 的 window.font 不会被普通 Text 继承）
        player.applyGlobalFont(customFontFamily)
        if (s.autoSwitchToLyric !== undefined) autoSwitchToLyric = s.autoSwitchToLyric
        if (s.closeToTray !== undefined) closeToTray = s.closeToTray
        if (s.desktopLyricFont !== undefined) desktopLyricFont = s.desktopLyricFont
        if (s.desktopLyricColor !== undefined) desktopLyricColor = s.desktopLyricColor
        if (s.desktopLyricLocked !== undefined) desktopLyricLocked = s.desktopLyricLocked
        // 把桌面歌词样式应用到后端（QML 的属性的 onChange 也会触发，这里兜底）
        if (typeof appBridge !== "undefined")
            appBridge.setDesktopStyle(desktopLyricFont, desktopLyricColor)
        if (s.volume !== undefined) player.volume = s.volume
        if (s.musicDir !== undefined) player.setMusicDir(s.musicDir)
        if (s.lastFile !== undefined && s.lastFile) player.restoreLastPosition()
        saveAllSettings()
    }

    Component.onCompleted: reloadSettings()

    // 设置回退：player 恢复 .bak1 后重新加载全部设置到 UI
    Connections {
        target: player
        function onSettingsRolledBack() { window.reloadSettings() }
    }

    onCustomAccentChanged: saveSetting("customAccent", customAccent)
    onCustomDarkBgChanged: saveSetting("customDarkBg", customDarkBg)
    onCustomLyricColorChanged: saveSetting("customLyricColor", customLyricColor)
    onCustomLyricPlayedColorChanged: saveSetting("customLyricPlayedColor", customLyricPlayedColor)
    onCustomLyricUnplayedColorChanged: saveSetting("customLyricUnplayedColor", customLyricUnplayedColor)
    onCustomBtnBgChanged: saveSetting("customBtnBg", customBtnBg)
    
    onBlurRadiusChanged: saveSetting("blurRadius", blurRadius)
    onPanelOpacityChanged: saveSetting("panelOpacity", panelOpacity)
    onHideControlBackgroundsChanged: saveSetting("hideControlBackgrounds", hideControlBackgrounds)
    onRowSpacingChanged: {
        saveSetting("rowSpacing", rowSpacing)
        // 行间距一变，歌词区里所有行的目标 y 都会跟着变（因为 groupBaseY/targetY
        // 都实时依赖 itemHeight=rowSpacing）。如果任其走正常的弹簧动画过渡，
        // 拖动滑块调节时会看到歌词区一直在"跳来跳去做动画"，观感很差——
        // 用户在调设置，预期是所见即所得地瞬间看到新间距，而不是过渡动画。
        // 复用之前给"切歌瞬间归位"写的 snapAll()：临时关闭每行的 Behavior，
        // 让新的 targetY 直接、无动画地写入 y。
        if (typeof lyricView !== "undefined" && lyricView.snapAll) {
            Qt.callLater(lyricView.snapAll)
        }
    }
    onCustomFontFamilyChanged: {
        saveSetting("customFontFamily", customFontFamily)
        player.applyGlobalFont(customFontFamily)
    }
    onAutoSwitchToLyricChanged: saveSetting("autoSwitchToLyric", autoSwitchToLyric)
    onCloseToTrayChanged: saveSetting("closeToTray", closeToTray)
    onDesktopLyricFontChanged: {
        saveSetting("desktopLyricFont", desktopLyricFont)
        appBridge.setDesktopStyle(desktopLyricFont, desktopLyricColor)
    }
    onDesktopLyricColorChanged: {
        saveSetting("desktopLyricColor", desktopLyricColor)
        appBridge.setDesktopStyle(desktopLyricFont, desktopLyricColor)
    }
    onDesktopLyricLockedChanged: {
        saveSetting("desktopLyricLocked", desktopLyricLocked)
        if (typeof appBridge !== "undefined")
            appBridge.setDesktopLyricsLocked(desktopLyricLocked)
    }

    Connections {
        target: player
        function onSortModeChanged() { saveSetting("sortMode", player.sortMode) }
    }
    // ========== 背景图片层（高斯模糊 + 渐变过渡） ==========
    // 使用双层图片（A/B）实现切换渐变。用 _frontIsA 标记当前哪一层在显示（前景），
    // 另一层作为预加载/新图层。过渡时只切换 opacity，两层各自的 source 除了
    // "预加载新图"这一次赋值之外，绝不会在过渡过程中被清空或腾挪——
    // 这是避免闪烁的关键：一旦某层 source 被清空，它对应的 FastBlur 会因为
    // visible 绑定跟着瞬间消失，没有淡出动画，看起来就是"背景瞬间消失一下"。

    // 防止狂点时动画堆积：标记位
    property bool _bgTransitioning: false
    // true：A 层是当前显示的前景；false：B 层是当前显示的前景
    property bool _frontIsA: true
    // 过渡代数：每次开始/提前结束过渡都自增，旧过渡挂起的定时器
    // 凭代数判断自己是否已失效，避免迟到地翻转前后景标记造成错乱
    property int _bgToken: 0
    // 当前过渡挂起的完成定时器实例（每次过渡重建并销毁旧实例，
    // 否则 createQmlObject 出来的 Timer 会随切歌次数无限累积）
    property var _bgTimer: null

    // 当前“前景层”的 Image / FastBlur（只读快捷方式，避免重复三元判断）
    function _frontImage() { return window._frontIsA ? bgImageA : bgImageB }
    function _frontBlur() { return window._frontIsA ? bgBlurA : bgBlurB }
    function _backImage() { return window._frontIsA ? bgImageB : bgImageA }
    function _backBlur() { return window._frontIsA ? bgBlurB : bgBlurA }

    // 开始背景图片渐变过渡
    function _startBgTransition() {
        // 背景层使用独立的 query key（?b=），与封面图（?c=）、底栏缩略图
        // （?t=）不同 URL——三个 Image 各自持有独立的加载应答，避免 Qt
        // 图片缓存共享同一 QQuickPixmap 应答、一层被中止加载时其它层收到
        // "connectFinished() called when not loading" 之类的告警。
        var newSource = player.currentSongImage
            ? "file://" + player.currentSongImage + "?b=" + window.coverStamp : ""

        var frontImg = window._frontImage()
        var frontBlur = window._frontBlur()
        var backImg = window._backImage()
        var backBlur = window._backBlur()

        // 情况 1：正在过渡中 → 立即完成当前过渡（交换前后景标记），再用新图重新开始。
        // 先自增代数：让上一个过渡挂起的 650ms 定时器作废，防止它迟到后
        // 再次翻转标记；同时断开两层的挂起连接，防止串层回调。
        if (window._bgTransitioning) {
            window._bgToken++
            if (window._bgTimer) {
                window._bgTimer.destroy()
                window._bgTimer = null
            }
            bgImageA.statusChanged.disconnect(window._bgOnLoad)
            bgImageB.statusChanged.disconnect(window._bgOnLoad)
            frontBlur.opacity = 0.0
            backBlur.opacity = 1.0
            window._frontIsA = !window._frontIsA
            window._bgTransitioning = false
            // 递归调用自身，用新图重新开始过渡
            window._startBgTransition()
            return
        }

        // 情况 2：新图与当前前景相同 → 无需过渡
        // 注意必须用 String() 转换再比较：frontImg.source 是 url 类型，
        // url 与 string 用 === 比较永远为 false，会导致同图也重复过渡。
        if (newSource === String(frontImg.source))
            return

        // 情况 2.5：新歌没有封面 → 淡出背景。
        // 不能直接清空 source：FastBlur 的 visible 绑定在 source 清空时
        // 会瞬间变 false，没有淡出动画。先淡出 opacity，动画结束后再清空。
        if (newSource === "") {
            window._bgTransitioning = true
            window._bgToken++
            var clearToken = window._bgToken
            bgImageA.statusChanged.disconnect(window._bgOnLoad)
            bgImageB.statusChanged.disconnect(window._bgOnLoad)
            if (window._bgTimer) {
                window._bgTimer.destroy()
                window._bgTimer = null
            }
            frontBlur.opacity = 0.0
            backBlur.opacity = 0.0
            var clearTimer = Qt.createQmlObject(
                "import QtQuick; Timer { interval: 620; onTriggered: { window._finishBgClear(" + clearToken + "); } }",
                window)
            window._bgTimer = clearTimer
            clearTimer.start()
            return
        }

        // 确保前景持有旧图（如果是首次启动，前景还没图，直接设置前景）
        if (frontImg.source === "") {
            frontImg.source = newSource
            frontBlur.opacity = 1.0
            return
        }

        // 将新图加载到后景层（后景层此刻必定是空闲的，不会影响当前显示）
        backImg.source = newSource

        // 如果图片已经加载完成/失败，立即处理
        if (backImg.status === Image.Ready) {
            window._doBgFade()
        } else if (backImg.status === Image.Error) {
            // 加载失败，直接更新前景（不经过渡，因为没有可用的新图可淡入）
            frontImg.source = newSource
            backImg.source = ""
        } else {
            // 等待加载完成后触发渐变
            backImg.statusChanged.connect(window._bgOnLoad)
        }
    }

    // 后景层图片加载完成后的回调（一次性）
    function _bgOnLoad() {
        // 无论触发的是哪一层，都先把两层挂起的连接全部断开，
        // 防止历史连接在新过渡里串层触发。
        bgImageA.statusChanged.disconnect(window._bgOnLoad)
        bgImageB.statusChanged.disconnect(window._bgOnLoad)
        var backImg = window._backImage()
        if (backImg.status === Image.Ready) {
            window._doBgFade()
        } else {
            backImg.source = ""
        }
    }

    // 执行渐变：前景（旧图）淡出、后景（新图）淡入
    function _doBgFade() {
        window._bgTransitioning = true
        window._bgToken++
        var token = window._bgToken
        window._frontBlur().opacity = 0.0
        window._backBlur().opacity = 1.0

        // 650ms 后完成过渡（比动画 600ms 稍长）。
        // 定时器回调带上自己的代数，只有仍是最新过渡时才翻转标记。
        // 每次过渡先销毁上一个定时器实例（QML destroy 为延迟销毁，安全），
        // 避免 createQmlObject 出的 Timer 对象随切歌次数累积泄漏。
        if (window._bgTimer)
            window._bgTimer.destroy()
        var timer = Qt.createQmlObject(
            "import QtQuick; Timer { interval: 650; onTriggered: { window._finishBgTransition(" + token + "); } }",
            window)
        window._bgTimer = timer
        timer.start()
    }

    // 完成过渡：只交换前后景标记，不改动任何 source，不清空任何一层
    function _finishBgTransition(token) {
        if (window._bgTimer) {
            window._bgTimer.destroy()
            window._bgTimer = null
        }
        if (token !== window._bgToken)
            return  // 这个过渡已被更早完成/替换，忽略迟到的回调
        window._frontIsA = !window._frontIsA
        window._bgTransitioning = false
    }

    // ===== 圆角裁剪根容器 =====
    // 所有内容（背景双层图、模糊层、主布局、滑出面板）都是它的子树，
    // clip:true 把一切裁进圆角——这是"背景图片盖住圆角"的根治点：
    // 图片层必须位于被裁剪的圆角容器内部，而不是窗口的直接子项。
    // 最大化时去圆角/去边距（贴边窗口圆角会露出桌面背景角）。
    Rectangle {
        id: rootSurface
        anchors.fill: parent
        anchors.margins: (_frameless && window.visibility !== Window.Maximized) ? 6 : 0
        radius: (_frameless && window.visibility !== Window.Maximized) ? 12 : 0
        clip: true
        color: bgDark
        // 启动防白屏：初始全透明，首帧交换后由 bootFadeIn 淡入（见上）
        opacity: 0

        // ===== 背景层容器（唯一进入蒙版层的部分） =====
        // 整窗 layer+OpacityMask 会把所有文字也渲染进离屏纹理再采样，
        // 文字失去亚像素渲染优化而发虚——所以蒙版只包住背景层
        // （背景本身是模糊图，遮罩采样无感），文字/按钮留在层外保持清晰。
        Rectangle {
            id: bgSurface
            anchors.fill: parent
            radius: rootSurface.radius
            layer.enabled: true
            layer.effect: OpacityMask {
                maskSource: rootMask
            }

            // A 层：只作为 FastBlur 的取样源，不直接可见。
            // 本地文件用同步加载（asynchronous: false）：切换歌曲时不会出现
            // "中途被新 source 打断" 的异步加载应答，从根上消除
            // "QQuickPixmap: connectFinished() called when not loading" 警告，
            // 也让下面的 status 判断在赋值后立刻就是最终结果。
            Image {
                id: bgImageA
                anchors.fill: parent
                fillMode: Image.PreserveAspectCrop
                source: ""
                asynchronous: false
                smooth: true
                visible: false
            }

            // B 层：只作为 FastBlur 的取样源，不直接可见
            Image {
                id: bgImageB
                anchors.fill: parent
                fillMode: Image.PreserveAspectCrop
                source: ""
                asynchronous: false
                smooth: true
                visible: false
            }

            // A 层的模糊结果：谁在前景就淡入到 1，谁在后景就淡出到 0
            FastBlur {
                id: bgBlurA
                anchors.fill: parent
                source: bgImageA
                radius: blurRadius
                cached: true
                opacity: 0.0
                visible: bgImageA.source !== ""

                Behavior on opacity {
                    NumberAnimation { duration: 600; easing.type: Easing.OutCubic }
                }
            }

            // B 层的模糊结果
            FastBlur {
                id: bgBlurB
                anchors.fill: parent
                source: bgImageB
                radius: blurRadius
                cached: true
                opacity: 0.0
                visible: bgImageB.source !== ""

                Behavior on opacity {
                    NumberAnimation { duration: 600; easing.type: Easing.OutCubic }
                }
            }

            // 顶栏底色（panelOpacity 驱动）：声明在最后，盖在模糊层之上，
            // 随背景一起被圆角遮罩；文字与按钮在透明的 titleBar 里，不经过蒙版层
            Rectangle {
                id: titleBarTint
                width: parent.width
                height: 38
                visible: titleBar.visible
                color: Qt.rgba(bgDark.r, bgDark.g, bgDark.b, panelOpacity)
            }

            // 底栏底色（panelOpacity 驱动）：与顶栏同理放进蒙版层，
            // 左下/右下随背景一起裁圆角，不再出现方形暗角
            Rectangle {
                id: bottomBarTint
                anchors.bottom: parent.bottom
                width: parent.width
                height: 72
                color: Qt.rgba(bgDark.r, bgDark.g, bgDark.b, panelOpacity)
            }
        }

        // ===== 内部顶栏（无边框模式下绘制；Wayland 回退时隐藏） =====
        Rectangle {
            id: titleBar
            visible: window._frameless
            // 显式 z 抬到背景模糊层/主布局之上
            // （主布局从 topMargin 开始不重叠；滑出面板 z=100 仍覆盖顶栏）
            z: 1
            width: parent.width
            height: 38
            // 底色由 bgSurface.titleBarTint 提供(随背景一起圆角遮罩)，
            // 顶栏本身透明，文字/按钮不经过蒙版层保持清晰
            color: "transparent"

            // 拖动区放最前声明（后续兄弟层叠在上、优先收事件）
            MouseArea {
                id: titleDragArea
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton
                cursorShape: Qt.ArrowCursor
                onPressed: {
                    if (window.visibility !== Window.Maximized)
                        window.startSystemMove()
                }
            }

            RowLayout {
                // 注意：必须显式锚定左右边，leftMargin/rightMargin 才生效
                // （之前只有 width/height，RowLayout 贴到 x=0，LOGO 被
                // 圆角遮罩切掉左侧）
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                height: parent.height
                anchors.leftMargin: 12
                anchors.rightMargin: 6
                spacing: 6

                Text {
                    text: "PyMusic"
                    color: textPrimary
                    font.family: window.uiFontFamily
                    font.pixelSize: 12
                    font.bold: true
                    Layout.alignment: Qt.AlignVCenter
                }
                Item { Layout.fillWidth: true }

                // 最小化
                Rectangle {
                    id: titleMinBtn
                    Layout.alignment: Qt.AlignVCenter
                    width: 34; height: 26; radius: 6
                    color: titleMinBtnMouse.containsPress ? accent : (titleMinBtnMouse.containsMouse ? Qt.rgba(1,1,1,0.12) : "transparent")
                    Behavior on color { ColorAnimation { duration: 100 } }
                    Image {
                        id: titleMinIconImg
                        anchors.centerIn: parent
                        width: 14
                        height: 14
                        source: "icons/window-minimize.svg"
                        sourceSize.width: 14
                        sourceSize.height: 14
                        visible: false
                    }
                    ColorOverlay {
                        anchors.fill: titleMinIconImg
                        source: titleMinIconImg
                        color: textPrimary
                    }
                    MouseArea {
                        id: titleMinBtnMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: window.showMinimized()
                    }
                }

                // 退出
                Rectangle {
                    id: titleCloseBtn
                    Layout.alignment: Qt.AlignVCenter
                    width: 34; height: 26; radius: 6
                    color: titleCloseBtnMouse.containsPress ? accent : (titleCloseBtnMouse.containsMouse ? Qt.rgba(0.9, 0.2, 0.25, 0.75) : "transparent")
                    Behavior on color { ColorAnimation { duration: 100 } }
                    Image {
                        id: titleCloseIconImg
                        anchors.centerIn: parent
                        width: 13
                        height: 13
                        source: "icons/close.svg"
                        sourceSize.width: 13
                        sourceSize.height: 13
                        visible: false
                    }
                    ColorOverlay {
                        anchors.fill: titleCloseIconImg
                        source: titleCloseIconImg
                        color: textPrimary
                    }
                    MouseArea {
                        id: titleCloseBtnMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        // X = 退出（300ms 音量淡出后退出，不走 closeToTray 的隐藏逻辑）
                        onClicked: {
                            console.log("[UI] 点击退出 (fadeOutQuit)")
                            player.fadeOutQuit()
                        }
                    }
                }
            }
        }

    Connections {
        target: player
        function onSongChanged(index) {
            if (index < 0) return
            window._startBgTransition()
        }
    }

    // 监听封面文件更新（重新下载覆盖同路径文件时），提升版本号
    // 强制所有图片重新加载。
    // 注意：不能简单地再调一次 _startBgTransition()——onSongChanged 已经
    // 触发过一次过渡，这里再叠加一次会让 A/B 状态机和挂起的 650ms 定时器
    // 互相竞争，正是"下载封面后背景消失"的原因。正确做法是：前景层显示的
    // 就是这张封面时，就地重载（换带新版本号的 URL），不做过渡。
    Connections {
        target: player
        function onCoverFileUpdated(path) {
            window.coverStamp++
            var cur = player.currentSongImage
            var frontImg = window._frontImage()
            // 与本次下载前的 URL 精确比较（url 类型没有 indexOf，
            // 且模糊子串匹配可能误伤路径相近的其它歌曲封面）
            var prevUrl = "file://" + cur + "?b=" + (window.coverStamp - 1)
            if (cur && String(frontImg.source) === prevUrl) {
                frontImg.source = "file://" + cur + "?b=" + window.coverStamp
            } else {
                window._startBgTransition()
            }
        }
    }

    // 切歌时刷新下载面板搜索框的预填内容（搜索框的 text 绑定在用户
    // 手动编辑过一次后就会断开，之后不再跟随当前歌曲变化；这里在
    // 用户从未编辑过的情况下补一次刷新）
    Connections {
        target: player
        function onSongChanged(index) {
            if (!window._searchBoxEdited)
                searchInput.text = player.currentSongName || ""
        }
    }


    // 无封面淡出动画结束：此刻两层 FastBlur 已完全透明，清空 source 无感。
    // token 校验防止动画期间又切了歌（交给新过渡处理）。
    function _finishBgClear(token) {
        if (window._bgTimer) {
            window._bgTimer.destroy()
            window._bgTimer = null
        }
        if (token !== window._bgToken)
            return
        bgImageA.source = ""
        bgImageB.source = ""
        window._bgTransitioning = false
    }


    // ========== 布局 ==========
    ColumnLayout {
        anchors.fill: parent
        anchors.topMargin: titleBar.visible ? titleBar.height : 0
        spacing: 0

        // --- 主内容区 ---
        Item {
            id: mainContentArea
            Layout.fillWidth: true
            Layout.fillHeight: true

            RowLayout {
                anchors.fill: parent
                spacing: 0

                // ===== 左侧：始终显示专辑封面 =====
                Rectangle {
                    id: leftPanel
                    Layout.preferredWidth: playlistVisible ? parent.width * 0.38 : parent.width * 0.5
                    Layout.fillHeight: true
                    color: Qt.rgba(bgDark.r, bgDark.g, bgDark.b, panelOpacity)
                    clip: true

                    Behavior on Layout.preferredWidth {
                        NumberAnimation { duration: 250; easing.type: Easing.OutCubic }
                    }

                    // 封面视图
                    ColumnLayout {
                        anchors.centerIn: parent
                        width: parent.width * (playlistVisible ? 0.8 : 0.6)
                        spacing: 16

                        Behavior on width {
                            NumberAnimation { duration: 250; easing.type: Easing.OutCubic }
                        }

                        // 封面图片
                        Rectangle {
                            id: coverFrame
                            Layout.preferredWidth: parent.width
                            Layout.preferredHeight: parent.width
                            radius: playlistVisible ? 12 : 16
                            color: bgCard
                            clip: true

                            Behavior on radius {
                                NumberAnimation { duration: 250 }
                            }

                            Rectangle {
                                anchors.fill: parent
                                visible: coverImage.status !== Image.Ready
                                color: bgDark
                                radius: parent.radius

                                ColumnLayout {
                                    anchors.centerIn: parent
                                    spacing: 8

                                    // 无封面占位音符图标
                                    Item {
                                        Layout.alignment: Qt.AlignHCenter
                                        width: playlistVisible ? 64 : 80
                                        height: playlistVisible ? 64 : 80

                                        Image {
                                            id: noCoverIconImg
                                            anchors.centerIn: parent
                                            width: parent.width
                                            height: parent.height
                                            source: "icons/music-note.svg"
                                            sourceSize.width: parent.width
                                            sourceSize.height: parent.height
                                            visible: false
                                        }
                                        ColorOverlay {
                                            anchors.fill: noCoverIconImg
                                            source: noCoverIconImg
                                            color: textMuted
                                        }
                                    }
                                    Text {
                                        font.family: window.uiFontFamily
                                        Layout.alignment: Qt.AlignHCenter
                                        text: "暂无封面"
                                        font.pixelSize: 13
                                        color: textMuted
                                    }
                                }
                            }

                            Image {
                                id: coverImage
                                anchors.fill: parent
                                fillMode: Image.PreserveAspectCrop
                                source: player.currentSongImage ? "file://" + player.currentSongImage + "?c=" + window.coverStamp : ""
                                asynchronous: false
                                smooth: true
                                visible: status === Image.Ready
                            }

                            Rectangle {
                                anchors.fill: parent
                                radius: parent.radius
                                color: "transparent"
                                border.width: 1
                                border.color: Qt.rgba(1, 1, 1, 0.05)
                            }
                        }

                        Text {
                            font.family: window.uiFontFamily
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            text: player.currentSongName || "未选择歌曲"
                            color: textPrimary
                            font.pixelSize: playlistVisible ? 16 : 18
                            font.bold: true
                            elide: Text.ElideRight
                            maximumLineCount: 2
                            wrapMode: Text.Wrap

                            Behavior on font.pixelSize {
                                NumberAnimation { duration: 200 }
                            }
                        }

                        Row {
                            Layout.alignment: Qt.AlignHCenter
                            spacing: 8
                            visible: player.state !== "stopped"

                            Text {
                                font.family: window.uiFontFamily
                                text: player.formatTime(player.position)
                                color: textSecondary
                                font.pixelSize: 12
                            }
                            Text {
                                font.family: window.uiFontFamily
                                text: "/"
                                color: textMuted
                                font.pixelSize: 12
                            }
                            Text {
                                font.family: window.uiFontFamily
                                text: player.formatTime(player.duration)
                                color: textSecondary
                                font.pixelSize: 12
                            }
                        }
                    }
                }

                // ===== 分割线（折叠时显示，分隔封面和歌词） =====
                Rectangle {
                    id: divider
                    width: 1
                    Layout.fillHeight: true
                    color: Qt.rgba(1, 1, 1, 0.06)
                    visible: !playlistVisible
                }

                // ===== 右侧：播放列表（展开时）/ 歌词（折叠时） =====
                Rectangle {
                    id: rightPanel
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    color: Qt.rgba(bgDark.r, bgDark.g, bgDark.b, panelOpacity)
                    clip: true

                    // ---- 播放列表（展开时显示） ----
                    ColumnLayout {
                        anchors.fill: parent
                        spacing: 0
                        visible: playlistVisible

                        // 标题栏
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 48
                            color: Qt.rgba(bgDark.r, bgDark.g, bgDark.b, panelOpacity)

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 16
                                anchors.rightMargin: 16

                                Text {
                                    font.family: window.uiFontFamily
                                    text: "播放列表"
                                    color: textPrimary
                                    font.pixelSize: 15
                                    font.bold: true
                                }

                                // 列表/卡片样式切换
                                Rectangle {
                                    width: 28
                                    height: 28
                                    radius: 6
                                    color: styleBtnHovered ? Qt.rgba(accent.r, accent.g, accent.b, 0.2) : "transparent"

                                    property bool styleBtnHovered: false

                                    // 卡片/列表视图切换图标：列表视图显示"网格"（切到卡片），
                                    // 卡片视图显示"列表"（切回列表）
                                    Image {
                                        id: styleIconImg
                                        anchors.centerIn: parent
                                        width: 17
                                        height: 17
                                        source: player.listStyle === 0 ? "icons/grid.svg" : "icons/list.svg"
                                        sourceSize.width: 17
                                        sourceSize.height: 17
                                        visible: false
                                    }

                                    ColorOverlay {
                                        anchors.fill: styleIconImg
                                        source: styleIconImg
                                        color: textPrimary
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            player.listStyle = player.listStyle === 0 ? 1 : 0
                                            console.log("[UI] 视图切换 → " + (player.listStyle === 0 ? "列表" : "卡片"))
                                        }
                                        onEntered: parent.styleBtnHovered = true
                                        onExited: parent.styleBtnHovered = false
                                    }

                                    ToolTip {
                                        visible: parent.styleBtnHovered
                                        text: player.listStyle === 0 ? "切换为卡片视图" : "切换为列表视图"
                                        delay: 500
                                    }
                                }

                                // 排序按钮：循环切换 4 种排序模式
                                Rectangle {
                                    width: 28
                                    height: 28
                                    radius: 6
                                    color: sortBtnHovered ? Qt.rgba(accent.r, accent.g, accent.b, 0.2) : "transparent"

                                    property bool sortBtnHovered: false

                                    Image {
                                        id: sortIconImg
                                        anchors.centerIn: parent
                                        width: 18
                                        height: 18
                                        source: {
                                            switch (player.sortMode) {
                                                case 0: return "icons/sort-name-asc.svg"
                                                case 1: return "icons/sort-name-desc.svg"
                                                case 2: return "icons/sort-time-asc.svg"
                                                default: return "icons/sort-time-desc.svg"
                                            }
                                        }
                                        sourceSize.width: 18
                                        sourceSize.height: 18
                                        visible: false
                                    }

                                    ColorOverlay {
                                        anchors.fill: sortIconImg
                                        source: sortIconImg
                                        color: textPrimary
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            player.sortMode = (player.sortMode + 1) % 4
                                            console.log("[UI] 排序模式 → " + player.sortMode)
                                        }
                                        onEntered: parent.sortBtnHovered = true
                                        onExited: parent.sortBtnHovered = false
                                    }
                                }

                                Item { Layout.fillWidth: true }

                                // 本地曲库搜索框（圆角，风格与设置面板输入框一致）
                                TextField {
                                    id: songSearchInput
                                    Layout.preferredWidth: 150
                                    height: 26
                                    placeholderText: "搜索歌曲..."
                                    color: textPrimary
                                    font.pixelSize: 12
                                    selectByMouse: true
                                    onTextChanged: player.setSongSearch(text)
                                    background: Rectangle {
                                        implicitWidth: 150
                                        implicitHeight: 26
                                        radius: 6
                                        // 底色透明：与面板融为一体，仅保留描边
                                        color: "transparent"
                                        border.color: "#334466"
                                        border.width: 1
                                    }
                                }

                                Text {
                                    font.family: window.uiFontFamily
                                    text: player.filteredSongCount + " 首"
                                    color: textMuted
                                    font.pixelSize: 12
                                }
                            }
                        }

                        // 列表
                        ListView {
                            id: songListView
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: player.listStyle === 0
                            clip: true
                            model: player.songListModel
                            // 搜索过滤时禁用 currentIndex 跟随（过滤后列表位置与
                            // 完整列表索引不对应，高亮由 delegate 的 modelData.index 负责）
                            currentIndex: songSearchInput.text === "" ? player.currentIndex : -1
                            boundsBehavior: Flickable.DragAndOvershootBounds
                            flickDeceleration: 2000
                            maximumFlickVelocity: 4000
                            ScrollBar.vertical: ScrollBar {
                                policy: ScrollBar.AlwaysOn
                                width: 12

                                // 滑块主题跟随：颜色显式绑定 window.accent（含
                                // customAccent 变化），轨道底色跟随深色主题，
                                // 且都带过渡动画——否则切换强调色时只有
                                // 这里瞬间跳变或保持旧样式，与其余控件不同步。
                                contentItem: Rectangle {
                                    implicitWidth: 12
                                    radius: 6
                                    color: Qt.rgba(window.accent.r, window.accent.g, window.accent.b, 0.55)
                                    Behavior on color { ColorAnimation { duration: 150 } }
                                }
                                background: Rectangle {
                                    implicitWidth: 12
                                    radius: 6
                                    color: Qt.rgba(1, 1, 1, 0.05)
                                    Behavior on color { ColorAnimation { duration: 150 } }
                                }
                            }

                            // ===== 居中控制（用户滚动打断，3 秒后自动恢复） =====
                            property real _viewCenter: songListView.height * 0.5
                            property real _itemHeight: rowSpacing
                            property real _centerOffset: _viewCenter - _itemHeight * 0.5

                            // 用户滚动时冻结 header/footer 高度，停止跟随 currentIndex
                            property real _frozenH: 0
                            property real _frozenF: 0
                            property bool _frozen: false

                            // 用户正在手动滚动
                            property bool _userScrolling: dragging || flicking

                            // 搜索激活（搜索框有文字）：居中占位失效，列表从顶部排列
                            property bool _searching: songSearchInput.text !== ""

                            // ===== 滚轮速率自适应（滚得快→步长大、动画短，不被卡死） =====
                            property real _wheelStep: 100      // 当前单格步长（px）
                            property int _wheelLastTs: 0       // 上一滚轮事件时间戳
                            property int _wheelStreak: 0       // 连续快速滚动的次数

                            function _wheelRate() {
                                var now = Date.now()
                                var gap = now - songListView._wheelLastTs
                                songListView._wheelLastTs = now
                                if (gap < 120) {
                                    songListView._wheelStreak = Math.min(songListView._wheelStreak + 1, 8)
                                } else {
                                    songListView._wheelStreak = 0
                                }
                                // 步长随连滚递增（1x → 4.2x），时长递减（150ms → 54ms）
                                songListView._wheelStep = 100 * (1 + songListView._wheelStreak * 0.4)
                                songListView._wheelDuration = Math.max(54, 150 - songListView._wheelStreak * 12)
                            }
                            property int _wheelDuration: 150

                            function _freeze() {
                                songListView._frozenH = Math.max(0,
                                    songListView._centerOffset - songListView.currentIndex * songListView._itemHeight)
                                songListView._frozenF = Math.max(0,
                                    songListView.height - songListView._viewCenter - songListView._itemHeight * 0.5
                                    - (player.songCount - 1 - songListView.currentIndex) * songListView._itemHeight)
                                songListView._frozen = true
                                songListResumeTimer.stop()
                            }

                            function _unfreeze() {
                                songListView._frozen = false
                            }

                            onDraggingChanged: {
                                if (dragging) {
                                    listWheelScrollAnim.stop()
                                    listFollowAnim.stop()
                                    songListView._freeze()
                                } else if (!flicking) songListResumeTimer.restart()
                            }
                            onFlickingChanged: {
                                if (flicking) {
                                    listWheelScrollAnim.stop()
                                    listFollowAnim.stop()
                                    songListView._freeze()
                                } else if (!dragging) songListResumeTimer.restart()
                            }

                            Timer {
                                id: songListResumeTimer
                                interval: 3000
                                onTriggered: {
                                    songListView._unfreeze()
                                }
                            }

                            onCurrentIndexChanged: {
                                // 搜索激活时不自动滚动（过滤后列表位置与播放索引不对应）
                                if (songListView._searching || songListView._userScrolling) {
                                    songListView._unfreeze()
                                    return
                                }
                                songListView._unfreeze()
                                var targetY = songListView.currentIndex * songListView._itemHeight - songListView._centerOffset
                                // 平滑滚动到当前歌曲（不跳变）
                                listFollowAnim.stop()
                                listFollowAnim.to = Math.max(0, targetY)
                                listFollowAnim.start()
                            }

                            // 切歌时平滑滚动到当前歌曲
                            NumberAnimation {
                                id: listFollowAnim
                                target: songListView
                                property: "contentY"
                                duration: 260
                                easing.type: Easing.OutCubic
                            }

                            headerPositioning: ListView.InlineHeader
                            footerPositioning: ListView.InlineFooter

                            header: Item {
                                // 搜索激活时占位归零（过滤结果从顶部排列，不"悬浮"）
                                height: songListView._searching
                                    ? 0
                                    : (songListView._frozen
                                        ? songListView._frozenH
                                        : Math.max(0, songListView._centerOffset - songListView.currentIndex * songListView._itemHeight))
                                Behavior on height { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                                clip: true
                                Text {
                                    font.family: window.uiFontFamily
                                    anchors.centerIn: parent
                                    text: {
                                        var lines = Math.floor(parent.height / rowSpacing)
                                        var s = ""
                                        for (var i = 0; i < lines; i++) s += "—\n"
                                        return s
                                    }
                                    color: textMuted
                                    font.pixelSize: 13
                                    opacity: 0.4
                                    visible: parent.height > rowSpacing * 0.5
                                }
                            }
                            footer: Item {
                                // 搜索激活时占位归零
                                height: songListView._searching
                                    ? 0
                                    : (songListView._frozen
                                        ? songListView._frozenF
                                        : Math.max(0, songListView.height - songListView._viewCenter - songListView._itemHeight * 0.5
                                                     - (player.songCount - 1 - songListView.currentIndex) * songListView._itemHeight))
                                Behavior on height { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                                clip: true
                                Text {
                                    font.family: window.uiFontFamily
                                    anchors.centerIn: parent
                                    text: {
                                        var lines = Math.floor(parent.height / rowSpacing)
                                        var s = ""
                                        for (var i = 0; i < lines; i++) s += "—\n"
                                        return s
                                    }
                                    color: textMuted
                                    font.pixelSize: 13
                                    opacity: 0.4
                                    visible: parent.height > rowSpacing * 0.5
                                }
                            }

                            Component.onCompleted: Qt.callLater(function() {
                                if (songListView._searching) return
                                var targetY = songListView.currentIndex * songListView._itemHeight - songListView._centerOffset
                                songListView.contentY = Math.max(0, targetY)
                            })

                            Connections {
                                target: window
                                function onPlaylistVisibleChanged() {
                                    if (playlistVisible) {
                                        Qt.callLater(function() {
                                            songListView._unfreeze()
                                            if (songListView._searching) return
                                            var targetY = songListView.currentIndex * songListView._itemHeight - songListView._centerOffset
                                            songListView.contentY = Math.max(0, targetY)
                                        })
                                    }
                                }
                            }

                            Connections {
                                target: player
                                function onSortModeChanged() {
                                    songListView._unfreeze()
                                    if (songListView._searching) return
                                    var targetY = songListView.currentIndex * songListView._itemHeight - songListView._centerOffset
                                    songListView.contentY = Math.max(0, targetY)
                                }
                            }

                            delegate: Rectangle {
                                width: songListView.width
                                height: rowSpacing
                                // 高亮/序号/点击全部用 modelData.index（完整列表下标）：
                                // 搜索过滤后 delegate 的 index 是过滤后的位置，
                                // 不能用于与播放索引比较
                                color: {
                                    if (modelData.index === player.currentIndex) return Qt.rgba(0.913, 0.271, 0.376, 0.15)
                                    if (mouseArea.containsMouse || rowActions.visible) return Qt.rgba(1, 1, 1, 0.04)
                                    return "transparent"
                                }
                                Behavior on color { ColorAnimation { duration: 120 } }

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 16
                                    anchors.rightMargin: 16
                                    spacing: 12

                                    // 序号/播放指示
                                    Rectangle {
                                        Layout.preferredWidth: 24
                                        Layout.preferredHeight: 24
                                        radius: 12
                                        color: modelData.index === player.currentIndex ? accent : "transparent"
                                        border.width: modelData.index === player.currentIndex ? 0 : 1
                                        border.color: textMuted

                                        Text {
                                            font.family: window.uiFontFamily
                                            anchors.centerIn: parent
                                            text: modelData.index === player.currentIndex ? "▶" : (modelData.index + 1)
                                            color: modelData.index === player.currentIndex ? "#fff" : textMuted
                                            font.pixelSize: modelData.index === player.currentIndex ? 10 : 11
                                        }
                                    }

                                    // 歌曲名
                                    Text {
                                        font.family: window.uiFontFamily
                                        Layout.fillWidth: true
                                        text: modelData.name || "未知"
                                        color: modelData.index === player.currentIndex ? accent : textPrimary
                                        font.pixelSize: 13
                                        font.bold: modelData.index === player.currentIndex
                                        elide: Text.ElideRight
                                    }

                                }

                                MouseArea {
                                    id: mouseArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        player.currentIndex = modelData.index
                                        window.switchToLyric()
                                        player.play()
                                    }
                                }

                                // 悬停时浮现的编辑/删除操作。声明在整行 MouseArea
                                // 之后，栈序更高，因此按钮点击不会触发整行的播放。
                                Row {
                                    id: rowActions
                                    anchors.right: parent.right
                                    anchors.rightMargin: 16
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 6
                                    z: 2
                                    visible: mouseArea.containsMouse
                                             || editRowMouse.containsMouse
                                             || deleteRowMouse.containsMouse

                                    Item {
                                        width: 22
                                        height: 22
                                        Image {
                                            id: editRowIcon
                                            anchors.fill: parent
                                            source: "icons/edit.svg"
                                            sourceSize.width: 18
                                            sourceSize.height: 18
                                            visible: false
                                        }
                                        ColorOverlay {
                                            anchors.fill: editRowIcon
                                            source: editRowIcon
                                            color: editRowMouse.containsMouse ? accent : textSecondary
                                        }
                                        MouseArea {
                                            id: editRowMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: renameDialog.openFor(modelData.index)
                                        }
                                    }

                                    Item {
                                        width: 22
                                        height: 22
                                        Image {
                                            id: deleteRowIcon
                                            anchors.fill: parent
                                            source: "icons/delete.svg"
                                            sourceSize.width: 18
                                            sourceSize.height: 18
                                            visible: false
                                        }
                                        ColorOverlay {
                                            anchors.fill: deleteRowIcon
                                            source: deleteRowIcon
                                            color: deleteRowMouse.containsMouse ? "#e94560" : textSecondary
                                        }
                                        MouseArea {
                                            id: deleteRowMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: deleteDialog.openFor(modelData.index, modelData.name)
                                        }
                                    }
                                }
                            }

                            // 滚轮：手动驱动滚动并吞掉事件，保证：
                            // 1) 滚轮只滚动、不触发全局滚轮音量；
                            // 2) 滚到头/底时继续滚无事发生（不调音量）。
                            // 3) 滚动带平滑动画（150ms OutCubic），不跳变。
                            WheelHandler {
                                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                                onWheel: (event) => {
                                    // 与拖拽一致：滚轮滚动视为用户手动滚动，
                                    // 冻结 currentIndex 跟随，3 秒后自动恢复
                                    songListView._freeze()
                                    songListResumeTimer.restart()

                                    songListView._wheelRate()
                                    var maxY = Math.max(0, songListView.contentHeight - songListView.height)
                                    var ny = songListView.contentY - event.angleDelta.y / 120 * songListView._wheelStep
                                    ny = Math.max(0, Math.min(maxY, ny))
                                    listWheelScrollAnim.stop()
                                    listWheelScrollAnim.duration = songListView._wheelDuration
                                    listWheelScrollAnim.to = ny
                                    listWheelScrollAnim.start()
                                    event.accepted = true
                                }
                            }

                            // 滚轮逐格滚动动画（快速连续滚动时从当前位置继续）
                            NumberAnimation {
                                id: listWheelScrollAnim
                                target: songListView
                                property: "contentY"
                                duration: 150
                                easing.type: Easing.OutCubic
                            }
                        }

                        // ===== 卡片网格视图（列表样式=1） =====
                        // 卡片大小由设置 cardSize 控制；列数随宽度自适应，
                        // 每行卡片整体居中（宽度不足以再多一列时均匀居中）
                        Item {
                            id: cardView
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: player.listStyle === 1
                            clip: true

                            property real cardGap: 12
                            property real cell: player.cardSize + cardGap
                            // 列数 = 能塞下的最大列数（至少 1）
                            property int cols: Math.max(1, Math.floor((width + cardGap) / cell))
                            // 行整体居中偏移（剩余宽度均匀分到两边）
                            property real centerOffset: Math.max(0, (width - (cols * cell - cardGap)) / 2)
                            // 内容总高
                            property real contentHeight: Math.ceil(player.songListModel.length / cols) * cell - cardGap

                            // ===== 滚轮速率自适应（同列表） =====
                            property real _wheelStep: 150
                            property int _wheelLastTs: 0
                            property int _wheelStreak: 0
                            property int _wheelDuration: 150

                            function _wheelRate() {
                                var now = Date.now()
                                var gap = now - cardView._wheelLastTs
                                cardView._wheelLastTs = now
                                if (gap < 120) {
                                    cardView._wheelStreak = Math.min(cardView._wheelStreak + 1, 8)
                                } else {
                                    cardView._wheelStreak = 0
                                }
                                cardView._wheelStep = Math.max(60, cardView.cell) * (1 + cardView._wheelStreak * 0.4)
                                cardView._wheelDuration = Math.max(54, 150 - cardView._wheelStreak * 12)
                            }

                            Flickable {
                                id: cardFlick
                                anchors.fill: parent
                                contentWidth: cardView.width
                                contentHeight: cardView.contentHeight
                                clip: true
                                // 弹性过界 + 阻尼衰减：拖拽出界带阻力、松手弹簧回弹，
                                // 惯性尾巴柔和（阻尼停下）
                                boundsBehavior: Flickable.DragAndOvershootBounds
                                flickDeceleration: 2000
                                maximumFlickVelocity: 4000

                                ScrollBar.vertical: ScrollBar {
                                    policy: ScrollBar.AsNeeded
                                    width: 8
                                    contentItem: Rectangle {
                                        implicitWidth: 8
                                        radius: 4
                                        color: Qt.rgba(window.accent.r, window.accent.g, window.accent.b, 0.55)
                                    }
                                    background: Rectangle {
                                        implicitWidth: 8
                                        radius: 4
                                        color: "transparent"
                                    }
                                }

                                Repeater {
                                    model: player.songListModel

                                    // 卡片：封面铺满 + 底部磨砂浮层(歌名/作者)
                                    // 外层 Item 负责定位/悬停缩放/层级；卡片本体与
                                    // 圆角遮罩作为兄弟节点（maskSource 不能是自身子项）
                                    Item {
                                        // 居中网格定位：x = 行内列偏移 + 整行居中，y = 行
                                        property int colIdx: index % cardView.cols
                                        property int rowIdx: Math.floor(index / cardView.cols)
                                        x: cardView.centerOffset + colIdx * cardView.cell
                                        y: rowIdx * cardView.cell
                                        // 高度=cardSize（此前 cardSize+46 的标签区超出
                                        // 行距 cell=cardSize+gap，会被下一行卡片盖住）
                                        width: player.cardSize
                                        height: player.cardSize

                                        // 悬停放大 1.1x，并抬升到相邻卡片之上。
                                        // 含"移到右上角操作按钮上"的情形，避免鼠标
                                        // 移到按钮上时 cardMouse 丢失 hover 导致缩放抖动。
                                        property bool _hovered: cardMouse.containsMouse
                                                               || editCardMouse.containsMouse
                                                               || deleteCardMouse.containsMouse
                                        scale: _hovered ? 1.1 : 1.0
                                        z: _hovered ? 1 : 0
                                        Behavior on scale {
                                            NumberAnimation { duration: 500; easing.type: Easing.OutCubic }
                                        }
                                        transformOrigin: Item.Center

                                        // 卡片本体
                                        // 说明：原先用 Rectangle.clip + MultiEffect(maskSource: 独立
                                        // 不可见 Rectangle cardMask，visible:false) 来裁圆角。问题在于
                                        // Qt Quick 场景图对 visible: false 的节点会直接跳过渲染，不生成
                                        // 任何纹理内容，导致 MultiEffect 采样到的 mask 全为透明
                                        // （alpha=0），整个卡片（封面+文字）被当成完全透明裁掉——卡片
                                        // 因此"消失"，但布局位置和 MouseArea 命中区域仍在，所以只能盲点。
                                        //
                                        // 修复：改用 Qt5Compat.GraphicalEffects 的 OpacityMask（本文件
                                        // 顶部窗口整体圆角已用同样的手法验证过，在当前环境下稳定可用），
                                        // mask 源节点始终 visible: true、真正参与渲染，不再依赖
                                        // "看不见但要参与渲染"这种脆弱写法。
                                        // 裁剪对象是"整张卡片内容"（封面 cardCover + 底部磨砂标签
                                        // cardLabel 一起裁），这样即使封面图片铺满到卡片边缘、盖住了
                                        // 卡片背景 Rectangle 的圆角，四角依然会被裁圆——图片本身的
                                        // 四角像素也会被一起裁掉，不会再出现"图片方角盖住卡片圆角"的问题。
                                        Rectangle {
                                            id: cardItem
                                            anchors.fill: parent
                                            radius: 10
                                            antialiasing: true
                                            color: modelData.index === player.currentIndex
                                                ? Qt.rgba(0.913, 0.271, 0.376, 0.18)
                                                : "#16213e"
                                            Behavior on color { ColorAnimation { duration: 120 } }

                                            // 未裁剪前的原始内容（封面 + 标签），整体作为一个节点
                                            // 渲染进离屏纹理，layer.effect 直接用 OpacityMask 采样
                                            // cardMask 裁出圆角——写法与本文件顶部 rootSurface 的
                                            // 整窗圆角（bgSurface + OpacityMask + rootMask）完全一致，
                                            // 那里已验证在当前 Qt/驱动环境下稳定可用。
                                            // 必须 visible: true，否则同样会被场景图跳过渲染，
                                            // 变成本次要修复的"全透明"问题。
                                            Item {
                                                id: cardContent
                                                anchors.fill: parent
                                                visible: true
                                                layer.enabled: true
                                                layer.effect: OpacityMask {
                                                    maskSource: cardMask
                                                }

                                                // 封面
                                                Image {
                                                    id: cardCover
                                                    anchors.fill: parent
                                                    fillMode: Image.PreserveAspectCrop
                                                    source: modelData.image ? "file://" + modelData.image + "?c=" + window.coverStamp : ""
                                                    asynchronous: false
                                                    smooth: true

                                                    // 无封面占位
                                                    Rectangle {
                                                        anchors.fill: parent
                                                        visible: cardCover.status !== Image.Ready
                                                        color: bgCard

                                                        Item {
                                                            anchors.centerIn: parent
                                                            width: 28
                                                            height: 28

                                                            Image {
                                                                id: cardNoCoverIcon
                                                                anchors.fill: parent
                                                                source: "icons/music-note.svg"
                                                                sourceSize.width: 28
                                                                sourceSize.height: 28
                                                                visible: false
                                                            }
                                                            ColorOverlay {
                                                                anchors.fill: cardNoCoverIcon
                                                                source: cardNoCoverIcon
                                                                color: textMuted
                                                            }
                                                        }
                                                    }
                                                }

                                                // 底部磨砂玻璃标签区（在封面之上）
                                                Item {
                                                    id: cardLabel
                                                    anchors.left: parent.left
                                                    anchors.right: parent.right
                                                    anchors.bottom: parent.bottom
                                                    height: 40
                                                    clip: true

                                                    // 磨砂背景：模糊封面底部区域（layer 渲染 FastBlur 输出）
                                                    Rectangle {
                                                        anchors.fill: parent
                                                        layer.enabled: true
                                                        layer.effect: FastBlur {
                                                            source: cardCover
                                                            radius: 18
                                                        }
                                                    }
                                                    // 半透明暗色：提高文字可读性（在磨砂之上）
                                                    Rectangle {
                                                        anchors.fill: parent
                                                        color: Qt.rgba(0.04, 0.06, 0.09, 0.5)
                                                    }

                                                    // 歌名 / 作者
                                                    ColumnLayout {
                                                        anchors.left: parent.left
                                                        anchors.right: parent.right
                                                        anchors.verticalCenter: parent.verticalCenter
                                                        anchors.leftMargin: 6
                                                        anchors.rightMargin: 6
                                                        spacing: 1

                                                        Text {
                                                            Layout.fillWidth: true
                                                            font.family: window.uiFontFamily
                                                            text: {
                                                                var n = modelData.name || "未知"
                                                                var i = n.lastIndexOf(" - ")
                                                                return i > 0 ? n.slice(0, i) : n
                                                            }
                                                            color: "#f2f2f2"
                                                            font.pixelSize: 11
                                                            font.bold: true
                                                            elide: Text.ElideRight
                                                            maximumLineCount: 1
                                                        }
                                                        Text {
                                                            Layout.fillWidth: true
                                                            font.family: window.uiFontFamily
                                                            text: {
                                                                var n = modelData.name || ""
                                                                var i = n.lastIndexOf(" - ")
                                                                return i > 0 ? n.slice(i + 3) : ""
                                                            }
                                                            color: Qt.rgba(1, 1, 1, 0.7)
                                                            font.pixelSize: 9
                                                            elide: Text.ElideRight
                                                            maximumLineCount: 1
                                                        }
                                                    }
                                                }
                                            }

                                            // 圆角遮罩源：始终 visible，与 cardContent 是兄弟节点，
                                            // 场景图会为它生成真实纹理内容，供 OpacityMask 采样；
                                            // 靠 z 值压到最底层、且被 cardContent（不透明）完全盖住，
                                            // 实际不会单独露出来。
                                            Rectangle {
                                                id: cardMask
                                                anchors.fill: parent
                                                radius: 10
                                                antialiasing: true
                                                z: -1
                                            }

                                            MouseArea {
                                                id: cardMouse
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    player.currentIndex = modelData.index
                                                    window.switchToLyric()
                                                    player.play()
                                                }
                                            }
                                        }

                                        // 悬停时浮现的编辑/删除操作（卡片右上角）。
                                        // 位于封面/标签之外，不受圆角遮罩裁剪影响。
                                        Row {
                                            id: cardActions
                                            anchors.top: parent.top
                                            anchors.right: parent.right
                                            anchors.margins: 4
                                            spacing: 4
                                            z: 5
                                            visible: _hovered

                                            Rectangle {
                                                width: 24
                                                height: 24
                                                radius: 12
                                                color: Qt.rgba(0, 0, 0, 0.45)
                                                Image {
                                                    id: editCardIcon
                                                    anchors.centerIn: parent
                                                    source: "icons/edit.svg"
                                                    sourceSize.width: 16
                                                    sourceSize.height: 16
                                                    visible: false
                                                }
                                                ColorOverlay {
                                                    anchors.fill: editCardIcon
                                                    source: editCardIcon
                                                    color: editCardMouse.containsMouse ? accent : "#f2f2f2"
                                                }
                                                MouseArea {
                                                    id: editCardMouse
                                                    anchors.fill: parent
                                                    hoverEnabled: true
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: renameDialog.openFor(modelData.index)
                                                }
                                            }

                                            Rectangle {
                                                width: 24
                                                height: 24
                                                radius: 12
                                                color: Qt.rgba(0, 0, 0, 0.45)
                                                Image {
                                                    id: deleteCardIcon
                                                    anchors.centerIn: parent
                                                    source: "icons/delete.svg"
                                                    sourceSize.width: 16
                                                    sourceSize.height: 16
                                                    visible: false
                                                }
                                                ColorOverlay {
                                                    anchors.fill: deleteCardIcon
                                                    source: deleteCardIcon
                                                    color: deleteCardMouse.containsMouse ? "#ff6b81" : "#f2f2f2"
                                                }
                                                MouseArea {
                                                    id: deleteCardMouse
                                                    anchors.fill: parent
                                                    hoverEnabled: true
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: deleteDialog.openFor(modelData.index, modelData.name)
                                                }
                                            }
                                        }
                                    }
                                }

                                // 滚轮：手动驱动滚动并吞掉事件（同列表）：
                                // 滚轮只滚动卡片网格，不触发全局滚轮音量；
                                // 滚到头/底时继续滚无事发生；滚动带平滑动画；
                                // 步长/时长随滚速自适应（滚得快→滚得快）。
                                WheelHandler {
                                    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                                    onWheel: (event) => {
                                        cardView._wheelRate()
                                        var maxY = Math.max(0, cardFlick.contentHeight - cardFlick.height)
                                        var ny = cardFlick.contentY - event.angleDelta.y / 120 * cardView._wheelStep
                                        ny = Math.max(0, Math.min(maxY, ny))
                                        cardWheelScrollAnim.stop()
                                        cardWheelScrollAnim.duration = cardView._wheelDuration
                                        cardWheelScrollAnim.to = ny
                                        cardWheelScrollAnim.start()
                                        event.accepted = true
                                    }
                                }

                                // 卡片滚轮逐格滚动动画
                                NumberAnimation {
                                    id: cardWheelScrollAnim
                                    target: cardFlick
                                    property: "contentY"
                                    duration: 150
                                    easing.type: Easing.OutCubic
                                }
                            }
                        }
                        }

                    // ---- 歌词视图（折叠时显示） ----
                    ColumnLayout {
                        id: lyricViewPanel
                        anchors.fill: parent
                        spacing: 0
                        visible: !playlistVisible

                        // 歌词标题
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 48
                            color: "transparent"

                            // 歌词标题 + 时间戳调节箭头：
                            // 左箭头=时间戳提前 0.3s（变快），右箭头=延后 0.3s（变慢），
                            // 直接写入 LRC 文件并立即刷新
                            RowLayout {
                                anchors.centerIn: parent
                                spacing: 6

                                Rectangle {
                                    width: 24
                                    height: 24
                                    radius: 12
                                    color: lyricFasterHover ? Qt.rgba(accent.r, accent.g, accent.b, 0.15) : "transparent"

                                    property bool lyricFasterHover: false

                                    Image {
                                        id: lyricFasterIcon
                                        anchors.centerIn: parent
                                        width: 14
                                        height: 14
                                        source: "icons/left.svg"
                                        sourceSize.width: 14
                                        sourceSize.height: 14
                                        visible: false
                                    }
                                    ColorOverlay {
                                        anchors.fill: lyricFasterIcon
                                        source: lyricFasterIcon
                                        color: "#ffffff"
                                    }
                                    MouseArea {
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: player.shiftLyricTimestamps(-0.3)
                                        onEntered: parent.lyricFasterHover = true
                                        onExited: parent.lyricFasterHover = false
                                    }
                                    ToolTip {
                                        visible: parent.lyricFasterHover
                                        text: "歌词提前 0.3 秒（写入文件）"
                                        delay: 500
                                    }
                                }

                                Text {
                                    font.family: window.uiFontFamily
                                    text: "歌词"
                                    color: "#ffffff"
                                    font.pixelSize: 13
                                }

                                Rectangle {
                                    width: 24
                                    height: 24
                                    radius: 12
                                    color: lyricSlowerHover ? Qt.rgba(accent.r, accent.g, accent.b, 0.15) : "transparent"

                                    property bool lyricSlowerHover: false

                                    Image {
                                        id: lyricSlowerIcon
                                        anchors.centerIn: parent
                                        width: 14
                                        height: 14
                                        source: "icons/Right.svg"
                                        sourceSize.width: 14
                                        sourceSize.height: 14
                                        visible: false
                                    }
                                    ColorOverlay {
                                        anchors.fill: lyricSlowerIcon
                                        source: lyricSlowerIcon
                                        color: "#ffffff"
                                    }
                                    MouseArea {
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: player.shiftLyricTimestamps(0.3)
                                        onEntered: parent.lyricSlowerHover = true
                                        onExited: parent.lyricSlowerHover = false
                                    }
                                    ToolTip {
                                        visible: parent.lyricSlowerHover
                                        text: "歌词延后 0.3 秒（写入文件）"
                                        delay: 500
                                    }
                                }

                                // 删除当前歌曲（复用删除确认弹窗；无当前歌曲时隐藏）
                                Rectangle {
                                    visible: player.currentIndex >= 0
                                    width: 24
                                    height: 24
                                    radius: 12
                                    color: lyricDeleteHover
                                        ? Qt.rgba(0.913, 0.271, 0.376, 0.2)
                                        : "transparent"

                                    property bool lyricDeleteHover: false

                                    Image {
                                        id: lyricDeleteIcon
                                        anchors.centerIn: parent
                                        width: 14
                                        height: 14
                                        source: "icons/delete.svg"
                                        sourceSize.width: 14
                                        sourceSize.height: 14
                                        visible: false
                                    }
                                    ColorOverlay {
                                        anchors.fill: lyricDeleteIcon
                                        source: lyricDeleteIcon
                                        color: lyricDeleteHover ? "#ff6b81" : "#e94560"
                                    }
                                    MouseArea {
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: deleteDialog.openFor(player.currentIndex,
                                                                        player.currentSongName)
                                        onEntered: parent.lyricDeleteHover = true
                                        onExited: parent.lyricDeleteHover = false
                                    }
                                    ToolTip {
                                        visible: parent.lyricDeleteHover
                                        text: "删除当前歌曲"
                                        delay: 500
                                    }
                                }
                            }
                        }

                        // 歌词列表
                        // ===== 新版逐行独立动画歌词视图 =====
                        // 不再用 ListView.contentY 整体平移；改为 Repeater 生成每一行，
                        // 每行自己持有一个"目标位置" targetY，用 SpringAnimation 独立地
                        // 追向目标。当 currentIndex 变化时，所有行的 targetY 同时更新，
                        // 但因为每行的弹簧动画是独立运行的实例（不同的当前值/速度），
                        // 视觉上就会出现"上一行先到位，其余行按各自节奏慢慢跟上"的错落感，
                        // 而不是所有行整体在同一时刻同步滑动。
                        //
                        // 高亮 + 放大不再是布尔跳变，而是基于"行中心到高亮区中心的距离"
                        // 连续计算出的 0~1 进度值 highlightProgress，颜色、字号都由它插值，
                        // 所以文字在滑入/滑出高亮区边缘时会平滑地渐变、缩放，而不是一进入
                        // 索引命中就瞬间跳变。
                        Item {
                            id: lyricView
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            Layout.leftMargin: 32
                            Layout.rightMargin: 32
                            clip: true

                            // ===== 高亮区域中心：基于"歌词所在的主内容区"，而不是整个窗口 =====
                            // 之前的写法 "height * 0.4" 里的 height 是 lyricView 自己的高度——
                            // lyricView 上方还叠着一个"歌词"标题栏（48px），如果只按 lyricView
                            // 自身高度算比例，这个标题栏占的空间会被排除在外，"40%处"实际上是
                            // 相对"去掉标题栏之后剩余区域"的 40%，跟直觉上"整个歌词页面的
                            // 40%"不是同一回事。
                            //
                            // 后来尝试过换成 window.height（整个窗口高度）——但这样又把窗口
                            // 底部的播放控制栏（bottomBar，固定 72px）也算进去了，高亮区的
                            // 定位基准包含了一段跟歌词显示完全无关的区域，不是用户想要的。
                            //
                            // 正确的参照系应该是：mainContentArea——也就是根布局里"主内容区"
                            // 那个 Item，它上包含左侧封面/右侧歌词两栏（含"歌词"标题栏），
                            // 但不包含底部固定 72px 的播放控制栏。用它的高度算 40% 比例，
                            // 高亮区就正好落在"歌词显示窗口"（含标题栏、不含底部控件栏）的
                            // 纵向 40% 处，且不管窗口怎么缩放都保持这个比例不变。
                            //
                            // 重要坑点（已修正）：最初尝试直接把 mapFromItem(...) 的返回值
                            // 写进一个 property 绑定表达式里，想让它自动跟着窗口/布局变化
                            // 重新求值。但 QML 的绑定依赖追踪只认"表达式里直接读取了哪些
                            // 可观察属性"，mapFromItem 内部做的坐标变换并不通过读取这类
                            // 属性完成，引擎完全感知不到它的结果依赖了什么——于是窗口一旦
                            // 被拖拽缩放，这个绑定根本不会重新求值，_topOffset 会停留在
                            // 第一次算出来的旧值上，centerY 也就跟着长期算错，只是平时窗口
                            // 不缩放的话很难注意到。
                            //
                            // 修法：显式地把"所有会影响这个偏移量的几何属性"都在表达式里
                            // 读一遍，哪怕值本身没直接用到——只要读取了，就会被登记为依赖，
                            // 对应的属性一变，这条绑定就会被强制重新求值。
                            property real _topOffset: {
                                // 强制建立依赖：读一遍自身的位置/尺寸和参照容器的尺寸，
                                // 确保它们任意一个变化时这条绑定都会重新求值
                                var _dep1 = lyricView.x
                                var _dep2 = lyricView.y
                                var _dep3 = lyricView.width
                                var _dep4 = lyricView.height
                                var _dep5 = mainContentArea.width
                                var _dep6 = mainContentArea.height
                                var p = mapFromItem(mainContentArea, 0, 0)
                                return -p.y
                            }
                            readonly property real centerY: _topOffset + mainContentArea.height * 0.4
                            // 每行的基准行高（放大时行本身高度不变，只有文字 scale 变大，
                            // 避免因为行高跳变导致相邻行跟着抖动）
                            readonly property real itemHeight: rowSpacing
                            // 高亮时的最大缩放倍数
                            readonly property real maxScale: 1.28

                            // ===== 双语对照行分组 =====
                            // 后端 parse_lrc_text() 会把形如 "[00:12.00]日本語/中文翻译"
                            // 这种带 "/" 的双语行拆成两条独立记录，但拆出来的两条记录
                            // 时间戳完全相同、且在数组里紧挨着（Python sort 是稳定排序，
                            // 同一时间戳的多条记录会保持原始相对顺序不变）。
                            // 于是只需要比较"这一行的时间戳是否和上一行相同"，就能不依赖
                            // 任何额外后端接口，纯前端识别出"哪些行属于同一对原文/译文"。
                            //
                            // groupOf[i]：第 i 行所属的组号（同一对歌词组号相同）
                            // groupBaseOffset[g]：第 g 组相对于"组 0"的基准累积偏移量，
                            // 用组间距 itemHeight 累加而来（不含组内间距）
                            // indexInGroup[i]：第 i 行在其所属组内的序号（0 或 1，理论上
                            // 双语最多两行；如果超过 2 行的极端情况也按顺序往下排）
                            //
                            // 组内两行之间的间距用 groupInnerGap。
                            //
                            // 重要：这里不能写成 "itemHeight * 某系数"——itemHeight 就是
                            // 用户在设置里拖动的 rowSpacing（行间距滑块），如果组内间距跟着
                            // itemHeight 等比例缩放，会导致"调节行间距"这个操作看起来像是在
                            // 调节"原文和译文之间的距离"（因为组内间距的绝对变化量往往比组间
                            // 距的变化更显眼），这正是用户反馈的 bug。
                            //
                            // 正确语义应该是：rowSpacing 只控制"组与组"（也就是句子与句子）
                            // 之间的距离；原文↔译文的贴近程度是排版上的固定观感，不应该被
                            // "行间距"这个设置影响。所以这里用一个不依赖 rowSpacing 的固定
                            // 像素值，且限制在一个合理范围内（不会比 itemHeight 本身还大，
                            // 否则两行看起来反而比组间距更松散，失去"贴近"的效果）。
                            // 组内间距上限提到 40px：Text 允许 Wrap 两行
                            // （14px × 1.3 × 2 ≈ 36px），之前上限 30px 会让
                            // 长原文/译文两行文字互相压字。仍保持"不大于
                            // itemHeight"的约束，不会比组间距更松散。
                            readonly property real groupInnerGap: Math.min(40, itemHeight)

                            property var groupOf: []
                            property var indexInGroup: []
                            // 每组的行数：groupBaseY 需要据此判断"该组是否真有多行"，
                            // 只有多行的组才在组内预留 groupInnerGap——否则普通歌词
                            // （单行组）也会被无端加上 40px，行距变成
                            // itemHeight + groupInnerGap（实测 102px），与双语歌词
                            // 的跨组间距（62px）不一致。
                            property var groupSize: []
                            // groupBaseY[g]：第 g 组"组内第 0 行"相对于第 0 组的累积偏移。
                            // 每组累加 itemHeight；多行组（双语对照等）按组内行数-1
                            // 额外累加 groupInnerGap——普通歌词行距 = rowSpacing，
                            // 双语歌词组内 = groupInnerGap、跨组视觉间距 = itemHeight，
                            // 且组内行数不受限于 2（3 行及以上也不会侵入下一组），
                            // 与行序保护(C 方案)的跨组 minGap(itemHeight) 一致。
                            readonly property var groupBaseY: {
                                var arr = []
                                var base = 0
                                for (var g = 0; g < groupCount; g++) {
                                    arr.push(base)
                                    base += itemHeight
                                    // 组内有几行就预留几个组内间距：
                                    // 双语 2 行时行为不变；3 行及以上时若只预留
                                    // 1 个 gap，目标布局本身会与下一组重叠，
                                    // 行序保护只能把后续组整体下推、居中失效
                                    if (groupSize.length > g && groupSize[g] > 1)
                                        base += (groupSize[g] - 1) * groupInnerGap
                                }
                                return arr
                            }
                            // 组的总数，供上面的 groupBaseY 绑定使用（分组数量本身只在
                            // rebuildGroups 里，随歌词内容变化才会变，这里单独存一份）
                            property int groupCount: 0
                            // currentGroupIndex：当前播放行所在的组号，供高亮判断使用
                            readonly property int currentGroupIndex:
                                (groupOf.length > player.currentLyricIndex && player.currentLyricIndex >= 0)
                                    ? groupOf[player.currentLyricIndex] : -1

                            // ===== 大跨度跳转：全局 600ms 平滑滑行 =====
                            // 逐组自然推进时 |Δ|≤1，保留弹簧错落手感；一次变化超过
                            // 3 组说明是 seek/进度条 scrub/恢复播放位置造成的大跳转——
                            // 此时不再瞬间 snapAll 归位，而是整堆歌词 600ms 平移到
                            // 目标位置（beginBigJumpGlide，见下方），避免跳变。
                            property int _lastSnapGroup: -1
                            onCurrentGroupIndexChanged: {
                                var g = currentGroupIndex
                                if (g < 0) {
                                    // 歌词切换/清空：重置基准
                                    _lastSnapGroup = -1
                                    return
                                }
                                // 从无歌词状态直接落到远处（如恢复上次播放位置）也算大跳
                                var jump = _lastSnapGroup < 0 ? g : Math.abs(g - _lastSnapGroup)
                                if (jump > 3) {
                                    // 手动浏览歌词期间不做全局滑行（会跟手动偏移打架），
                                    // 保持原 snapAll 瞬间行为
                                    if (lyricView.manualScrolling) {
                                        Qt.callLater(snapAll)
                                    } else {
                                        lyricView.beginBigJumpGlide()
                                    }
                                }
                                _lastSnapGroup = g
                            }

                            function rebuildGroups() {
                                var count = player.lyricCount
                                var gOf = []
                                var iInG = []
                                var gSize = []
                                var g = -1
                                var lastTime = null
                                var curGroupStart = 0
                                for (var i = 0; i < count; i++) {
                                    var t = player.lyricTime(i)
                                    if (lastTime === null || t !== lastTime) {
                                        g += 1
                                        curGroupStart = i
                                    }
                                    gOf.push(g)
                                    iInG.push(i - curGroupStart)
                                    lastTime = t
                                }
                                // 回填每组的行数：groupBaseY 绑定依赖它判断
                                // 该组是否为双语对照（行数 > 1 才预留组内 gap）
                                for (var gi = 0; gi <= g; gi++) gSize.push(0)
                                for (var j = 0; j < count; j++) gSize[gOf[j]] += 1

                                groupOf = gOf
                                indexInGroup = iInG
                                groupSize = gSize
                                // groupCount 只依赖分组结构（歌词内容），不依赖 itemHeight；
                                // 触发 groupBaseY 的 binding 重新求值靠的是它被读取时自动
                                // 建立的依赖关系，这里赋值即可，具体的像素值交给上面的
                                // binding 表达式实时算，不在这里手动拼数组。
                                groupCount = g + 1
                            }

                            // 第 idx 行相对于"第 0 组基准位置"的纵向偏移：
                            // 组间用 itemHeight 累加，组内额外再加 indexInGroup * groupInnerGap，
                            // 因为组内间距更小，两行会明显比"组与组之间"靠得更近。
                            function rowOffsetInStack(idx) {
                                if (idx < 0 || idx >= groupOf.length) return 0
                                return groupBaseY[groupOf[idx]] + indexInGroup[idx] * groupInnerGap
                            }

                            // 手动滚动产生的额外偏移量（在自动居中位置基础上叠加）
                            property real manualOffset: 0
                            // 用户是否正处于"手动浏览歌词"状态（滚轮滚动中，或滚动后
                            // 还没归位的 3 秒等待期）。这段时间内每行的延迟归零，
                            // 保证滚轮手感跟手；只有回到"跟随播放自动滚动"时才启用
                            // 按距离错落延迟的效果。
                            property bool manualScrolling: false
                            // 手动浏览开始那一刻的 currentLyricIndex。浏览期间
                            // currentTargetBase 若继续跟随播放推进，整个歌词堆会
                            // 移动、用户正在读的行会漂走——冻结基准，回中动画
                            // 结束后再恢复跟随。
                            property int manualBaseIndex: -1

                            // 手动滚动的边界钳制：滚到第一行/最后一行到达中心
                            // 即停，避免滚出歌词堆看到大片空白。
                            // 堆总高度按 groupBaseY（含组内 gap）计算
                            function clampManualOffset(v) {
                                var g = currentGroupIndex >= 0 ? currentGroupIndex : 0
                                var curBase = groupBaseY.length > g ? groupBaseY[g] : 0
                                var lastBase = groupCount > 0 ? groupBaseY[groupCount - 1] : 0
                                var upLimit = curBase + itemHeight
                                var downLimit = Math.max(0, lastBase - curBase + itemHeight)
                                return Math.max(-downLimit, Math.min(v, upLimit))
                            }

                            function currentTargetBase(idx) {
                                // 第 idx 行的基准 y：让"当前播放行所在组的组内第 0 行"
                                // 居中于高亮区，其余行按 rowOffsetInStack 的相对偏移量
                                // 跟随排布——这样无论 currentLyricIndex 命中的是原文还是
                                // 译文，同一组的两行都会一起移动到高亮区附近。
                                // 手动浏览期间用冻结的基准索引，防止自动滚动推动歌词堆。
                                var curIdx = (lyricView.manualScrolling && lyricView.manualBaseIndex >= 0)
                                    ? lyricView.manualBaseIndex : player.currentLyricIndex
                                if (curIdx < 0 || groupOf.length === 0) {
                                    return centerY - itemHeight * 0.5 - (curIdx - idx) * itemHeight
                                }
                                var curGroupBase = groupBaseY.length > groupOf[curIdx] ? groupBaseY[groupOf[curIdx]] : 0
                                return centerY - itemHeight * 0.5 - (curGroupBase - rowOffsetInStack(idx))
                            }

                            // 首次加载时：先建分组表，再让所有行瞬间归位到正确位置。
                            // 注意：这两步必须写在同一个 Component.onCompleted 里——
                            // QML 不允许同一个对象上出现两个 Component.onCompleted
                            // （会报 "Property value set multiple times" 而拒绝加载整个文件）。
                            // 之前误把 rebuildGroups() 和 snapAll() 分别写在了两处
                            // Component.onCompleted 里，就是这个报错的直接原因。
                            Component.onCompleted: {
                                rebuildGroups()
                                Qt.callLater(snapAll)
                            }

                            Timer {
                                id: resumeAutoScrollTimer
                                interval: 3000
                                onTriggered: {
                                    manualOffsetAnim.stop()
                                    manualOffsetAnim.from = lyricView.manualOffset
                                    manualOffsetAnim.to = 0
                                    manualOffsetAnim.start()
                                }
                            }
                            NumberAnimation {
                                id: manualOffsetAnim
                                target: lyricView
                                property: "manualOffset"
                                duration: 400
                                easing.type: Easing.OutCubic
                                // 注意：不能用 "onStopped: if (to === 0) ..." 来判断回中是否
                                // 完成——因为滚轮里的 manualOffsetAnim.stop() 打断动画时也会
                                // 触发 onStopped，且此时 to 很可能残留着上一次设的值（0），
                                // 会被误判成"回中完成"，导致用户还在滚动时延迟错落效果就
                                // 提前被打开、手感发飘。改为动画"自然播放完毕"时才触发的
                                // onFinished（Qt: finished() 不会在 stop() 手动打断时触发，
                                // 只在动画自己跑完时触发），这样能准确区分
                                // "回中动画正常走完" vs "被新的滚动打断"。
                                onFinished: {
                                    // 回中动画自然结束：恢复跟随播放自动滚动。
                                    // 弹簧收敛时间常数(~3.6s)远大于 400ms 回中动画，
                                    // 只切回跟随的话行还要再漂移 2 秒多才到当前播放行。
                                    // 这里追加一次 snapAll，让所有行瞬间精确落位。
                                    lyricView.manualScrolling = false
                                    lyricView.manualBaseIndex = -1
                                    Qt.callLater(lyricView.snapAll)
                                }
                            }

                            // ===== 大跨度跳转（seek/恢复播放位置）的全局平移动画 =====
                            // 之前用 snapAll 瞬间归位（避免逐行弹簧追赶时行交叉坍缩）。
                            // 现在改为：先给全部行加一个统一位移 _bigJumpShift，让它们
                            // 视觉上停在原地，再在 600ms 内把位移平滑归零——整堆歌词
                            // 像整体平移一样滑到目标位置，既没有瞬间跳变，也不会出现
                            // 逐行弹簧追赶导致的交叉。动画期间行处于"绑定直写"模式
                            // （Behavior 关闭，snapAll 同款机制），位移由动画统一驱动。
                            property real _bigJumpShift: 0

                            NumberAnimation {
                                id: bigJumpGlideAnim
                                target: lyricView
                                property: "_bigJumpShift"
                                duration: 600
                                easing.type: Easing.OutCubic
                                onStopped: {
                                    // 只有自然走完（位移已归零）才恢复逐行弹簧模式；
                                    // 被 stop() 打断重启时位移仍非 0，跳过，由新的滑行动画接管
                                    if (lyricView._bigJumpShift === 0) {
                                        Qt.callLater(function() {
                                            for (var i = 0; i < lyricRepeater.count; i++) {
                                                var row = lyricRepeater.itemAt(i)
                                                if (row) row.yBehaviorEnabled = true
                                            }
                                        })
                                    }
                                }
                            }

                            // 大跳转：进入"全局滑行"流程（替代原先的瞬间 snapAll）
                            function beginBigJumpGlide() {
                                if (lyricRepeater.count === 0)
                                    return
                                bigJumpGlideAnim.stop()
                                // 以第 0 行的当前位置为基准，计算需要补偿的位移：
                                // 新的 targetY（含位移）必须等于行当前的视觉位置，
                                // 才能让动画开始时整堆歌词纹丝不动
                                var ref = lyricRepeater.itemAt(0)
                                var oldY = ref ? ref.y : 0
                                lyricView._bigJumpShift = oldY - lyricView.currentTargetBase(0)
                                // 行进入"绑定直写"模式并同步到含位移的目标值
                                for (var i = 0; i < lyricRepeater.count; i++) {
                                    var row = lyricRepeater.itemAt(i)
                                    if (row) {
                                        row.yBehaviorEnabled = false
                                        row._animY = row.targetY
                                        row._animY = Qt.binding(lyricView.bindTargetY(row))
                                    }
                                }
                                bigJumpGlideAnim.from = lyricView._bigJumpShift
                                bigJumpGlideAnim.to = 0
                                bigJumpGlideAnim.start()
                            }

                            // 鼠标滚轮：手动浏览歌词，3 秒无操作后自动回到当前播放行。
                            // enabled 绑定歌词行数：没有歌词时（纯音乐）这个 handler
                            // 会白白吞掉滚轮事件（默认 blocking），导致根部的
                            // "全局滚轮音量"在右侧歌词区失效——没有行可滚时
                            // 直接把事件放行给根部音量 handler。
                            WheelHandler {
                                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                                enabled: player.lyricCount > 0
                                onWheel: (event) => {
                                    // 大跳转滑行期间（行处于"绑定直写"模式）开始手动预览：
                                    // 先结束滑行、恢复逐行弹簧，否则每格滚轮都会瞬间跳转
                                    if (bigJumpGlideAnim.running) {
                                        bigJumpGlideAnim.stop()
                                        lyricView._bigJumpShift = 0
                                        for (var g_i = 0; g_i < lyricRepeater.count; g_i++) {
                                            var g_row = lyricRepeater.itemAt(g_i)
                                            if (g_row) g_row.yBehaviorEnabled = true
                                        }
                                    }
                                    // 本次浏览会话开始时冻结自动滚动基准
                                    if (!lyricView.manualScrolling)
                                        lyricView.manualBaseIndex = player.currentLyricIndex
                                    lyricView.manualScrolling = true
                                    manualOffsetAnim.stop()
                                    lyricView.manualOffset = lyricView.clampManualOffset(
                                        lyricView.manualOffset + event.angleDelta.y / 120 * rowSpacing)
                                    resumeAutoScrollTimer.restart()
                                }
                            }

                            Repeater {
                                id: lyricRepeater
                                model: player.lyricCount

                                delegate: Item {
                                    id: lyricRow
                                    width: lyricView.width
                                    height: lyricView.itemHeight
                                    x: 0

                                    // 目标 y：基准位置 + 手动滚动偏移 + 大跳转全局位移
                                    property real targetY: lyricView.currentTargetBase(index) + lyricView.manualOffset + lyricView._bigJumpShift

                                    // 这一行所在的组号 / 组内序号（组号相同 = 同一对原文/译文）。
                                    property int _groupIdx: lyricView.groupOf.length > index ? lyricView.groupOf[index] : index
                                    property int _idxInGroup: lyricView.indexInGroup.length > index ? lyricView.indexInGroup[index] : 0

                                    // ===== C 方案：行序保护 =====
                                    // 弹簧动画照常写到 _animY（手感完全不变），实际 y 用绑定
                                    // 对 _animY 做下限钳制：任何时候都不会越过上一行的已动画
                                    // 位置 + 最小间距，从根本上杜绝快速滚动/seek 跳转时因
                                    // 相位错乱产生的行交叉与堆叠。正常跟随时钳制不触发，
                                    // 弹簧轨迹原样呈现。
                                    property real _animY: targetY
                                    y: {
                                        var t = _animY
                                        if (index > 0) {
                                            var prev = lyricRepeater.itemAt(index - 1)
                                            if (prev) {
                                                var minGap = (_idxInGroup > 0)
                                                    ? lyricView.groupInnerGap : lyricView.itemHeight
                                                t = Math.max(t, prev.y + minGap)
                                            }
                                        }
                                        return t
                                    }
                                    // ===== 错落跟随的核心：按"离当前播放组的距离"给延迟 =====
                                    // 之前的版本里所有行用完全相同的 SpringAnimation、
                                    // 且在同一 tick 收到新的 targetY，于是所有行的运动轨迹
                                    // 几乎重合，看起来是"整体同步"而不是"一行一行跟上"。
                                    //
                                    // 这里借用 CSS 里 transition-delay 的思路：每一行的动画
                                    // 前面先插入一段 PauseAnimation，暂停时长由"组距离"决定——
                                    // 越靠近当前播放组的组延迟越短（几乎立即跟上），越远的组
                                    // 延迟越长（拖在后面）。
                                    //
                                    // 关键点：延迟必须按"组号距离"算，不能按"行号距离"算——
                                    // 如果按行号算，同一组内原文行和译文行的 index 不同，会算出
                                    // 不同的延迟，导致两行的弹簧动画不同步启动。而
                                    // _groupBaseRowY（下面）是用"当前行的 y 反推组基准行位置"
                                    // 算出来的，一旦两行延迟不一致，动画过程中反推出来的组基准
                                    // 位置会短暂对不上、产生抖动。按组号算延迟，同组两行的
                                    // yDelay 完全相同，弹簧动画会同步启动、同步运动，从而保证
                                    // 整组在动画的每一帧都严格保持"靠在一起、一起高亮"。
                                    property int _distanceFromCurrentGroup: Math.abs(_groupIdx - lyricView.currentGroupIndex)
                                    // 每远一组多延迟的毫秒数；这个系数越大，错落感越明显，
                                    // 但太大会显得"追不上"、观感涣散，30~50 之间比较自然。
                                    //
                                    // 注意：之前用 32ms 这个系数时，实际观感上几乎看不出"一行
                                    // 一行跟上"的错落，看起来像所有行整体同步移动。原因不是
                                    // 延迟机制没生效——延迟值本身确实是按组距离正确算出来的，
                                    // 不同行确实拿到了不同的延迟——而是下面 SpringAnimation
                                    // 的参数（spring:3.2, damping:0.42）收敛速度太快，运动
                                    // 本身可能一两百毫秒就基本走完，这时候几十毫秒的启动时差
                                    // 在整个运动过程里占比太小，视觉上被"弹簧跑得快"盖过了。
                                    // 现在把延迟系数调大、同时把弹簧参数放缓（见下面 spring/
                                    // damping），让整个追赶过程拉长，这样启动时差才能在过程中
                                    // 被明显看出来。
                                    readonly property int perLineDelay: 55
                                    // 延迟设上限，避免离得特别远的组（比如歌词一次滚很多行）
                                    // 要等待过长时间才开始动，看起来像卡住了
                                    property int _rawDelay: Math.min(_distanceFromCurrentGroup * perLineDelay, 380)
                                    // 用户手动滚动歌词时不应该有这种"错落延迟"的观感——那样会
                                    // 显得歌词对滚轮操作的响应发飘、不跟手。只有在跟随播放自动
                                    // 滚动（currentLyricIndex 变化）时才启用延迟；手动滚动
                                    // （lyricView.manualOffset 变化）时延迟归零，所有行同步跟手。
                                    property int yDelay: lyricView.manualScrolling ? 0 : _rawDelay

                                    property alias yBehaviorEnabled: yBehavior.enabled
                                    Behavior on _animY {
                                        id: yBehavior
                                        SequentialAnimation {
                                            PauseAnimation { duration: lyricRow.yDelay }
                                            // spring 调小、damping 调大：让追赶过程本身拉长、
                                            // 更"软"一些，弹簧收敛不再是几乎瞬间完成，这样
                                            // 上面的启动延迟差才有足够的时间窗口被看出来，
                                            // 而不是被极快的弹簧运动盖过。
                                            SpringAnimation {
                                                spring: 1.8
                                                damping: 0.55
                                                mass: 1.0
                                                epsilon: 0.05
                                            }
                                        }
                                    }

                                    // ===== 线性距离缩放（和"上一行退出"用同一套逻辑） =====
                                    // 之前尝试过"按组距离分三档（1.0/0.5/0）+ 人为延迟"的方案，
                                    // 想借延迟制造"当前行先动、下一行稍后跟上"的层次感——
                                    // 但这是治标不治本：只要两行的目标值在同一时刻更新，
                                    // 不管延迟多短，起步时间点的"错位感"始终是刻意做出来的，
                                    // 而不是自然的物理结果，看起来还是会有"当前行和下一行
                                    // 同时在变"的观感，因为延迟结束后两者又会重新同步推进。
                                    //
                                    // 回到最朴素也最自然的方案：不再区分"进入"和"退出"两套
                                    // 逻辑，统一用"这一行中心到高亮区中心的连续像素距离"来
                                    // 线性插值 highlightProgress——distance 越小，progress 越
                                    // 接近 1；distance 越大，progress 越接近 0。这样当前行
                                    // （distance 几乎是 0）天然比下一行（distance 还有小半个
                                    // itemHeight）progress 更高、放大更多，两者的缩放程度
                                    // 差异完全由"位置差"自然决定，不需要任何延迟或分档去
                                    // 人为制造区分——这正好和"上一行退出高亮区"时的连续渐变
                                    // 是同一套数学关系，进入和退出对称、手感一致。
                                    //
                                    // fadeRange：距离超过这个像素值就完全不高亮了。控件距离
                                    // （即 rowSpacing/itemHeight）越大，理论上这个值也应该
                                    // 适当放大，这样无论行间距怎么调，"当前行→下一行"这段
                                    // 距离占 fadeRange 的比例基本不变，保持一致的视觉手感。
                                    readonly property real fadeRange: lyricView.itemHeight * 1.35
                                    property real highlightProgress: Math.max(0, Math.min(1,
                                        1 - distance / fadeRange))
                                    Behavior on highlightProgress {
                                        NumberAnimation {
                                            duration: 60
                                            easing.type: Easing.OutCubic
                                        }
                                    }

                                    // _groupBaseRowY：用当前行的实际 y 反推出"如果这行是组内
                                    // 第 0 行，它现在应该在哪"，从而让同组的原文行和译文行
                                    // 拿到完全相同的 distance/highlightProgress——只要两行的
                                    // y 动画全程保持组内固定的相对偏移（groupInnerGap），
                                    // 这个反推在数学上就是精确成立的，不依赖两行动画是否
                                    // 同步启动。这一步逻辑保持不变，双语对照行"一起高亮、
                                    // 一起缩放"的效果不受这次改动影响。
                                    property real _groupBaseRowY: y - _idxInGroup * lyricView.groupInnerGap
                                    property real distance: Math.abs(_groupBaseRowY + lyricView.itemHeight * 0.5 - lyricView.centerY)

                                    // 是否正在"接近"高亮区中心（true=放大中，false=缩小中）。
                                    // 用距离的变化方向判断：距离在减小 → 正在进入 → 放大；
                                    // 距离在增大 → 正在离开 → 缩小。用命令式 handler 显式地
                                    // "先比较、再更新缓存"，避免两个 binding 同时监听同一
                                    // 信号时求值顺序不确定的问题。
                                    property real _lastDistance: 999999
                                    property bool growing: true
                                    onDistanceChanged: {
                                        growing = distance < _lastDistance
                                        _lastDistance = distance
                                    }

                                    Text {
                                        font.family: window.uiFontFamily
                                        id: lyricText
                                        anchors.centerIn: parent
                                        width: parent.width
                                        text: player.lyricText(index)

                                        // 颜色在"未播放色/已播放色"与"高亮色"之间连续插值：
                                        // 已经划过高亮区（所在组在当前组之前）的行以"已播放色"
                                        // 为基底，还没到的以"未播放色"为基底，随 highlightProgress
                                        // 叠加高亮色。
                                        //
                                        // 注意：这里必须比较"组号"而不是原始行号 index——
                                        // 因为 currentLyricIndex 命中的可能是对照组里下标更大的
                                        // 那一条（例如原文在前、译文在后时，二分查找会命中译文行）。
                                        // 如果直接用 index < player.currentLyricIndex 判断，
                                        // 同组内的原文行会因为它的 index 小于 currentLyricIndex
                                        // 而被误判成"已播放"变灰，即使它和译文行其实同属一组、
                                        // 应该一起保持高亮，不应该提前变暗。
                                        color: {
                                            var unplayed = window._resolvedLyricUnplayedColor
                                            var played = window._resolvedLyricPlayedColor
                                            var highlight = window._resolvedLyricColor
                                            var base = (lyricRow._groupIdx < lyricView.currentGroupIndex) ? played : unplayed
                                            // 线性 RGB 插值：progress=1 时精确等于设定高亮色，
                                            // progress=0 时精确等于底色。Qt.tint 是叠加运算，
                                            // 永远到不了目标色（满高亮时是"底色染粉"的混合色）
                                            return window.mixColor(base, highlight, lyricRow.highlightProgress)
                                        }

                                        font.pixelSize: 14
                                        // 注意：这里不用 font.bold 来强调当前行——bold 是一个
                                        // 布尔值，字重要么是常规、要么是加粗，中间没有过渡态，
                                        // Qt/Text 引擎没办法把"变粗"这个动作按帧插值，所以只要
                                        // highlightProgress 跨过某个阈值，字重必然是一次性瞬间
                                        // 跳变，这正是之前"淡出变细很突兀"的根源——并不是曲线或
                                        // 延迟设置得不对，而是这个属性本身不支持连续过渡。
                                        //
                                        // （也考虑过用 font.weight 数值插值，理论上 QML 支持
                                        // 100~900 的连续数值，但大多数系统字体、尤其是中文字体
                                        // 实际只内置了少数几档可用字重，渲染引擎会把中间值就近
                                        // 取整到最近的档位，效果上还是会有台阶感的跳变，只是
                                        // 从一次跳变变成两三次小跳变，没有真正解决问题。）
                                        //
                                        // 当前行的"更醒目"已经完全由下面连续过渡的 scale（放大）
                                        // 和上面连续过渡的 color（颜色渐亮）来体现，不再需要额外
                                        // 叠加一个不连续的加粗效果。

                                        // 用 scale 而不是改 font.pixelSize 来放大：
                                        // font.pixelSize 变化会触发文字重新排版/重新光栅化，
                                        // 连续插值下每帧都变字号开销大也容易抖动；
                                        // scale 是纯合成层变换，GPU 加速，插值完全平滑，
                                        // 且不会影响旁边行的布局位置，能稳定跑在 60fps。
                                        scale: 1.0 + (lyricView.maxScale - 1.0) * lyricRow.highlightProgress
                                        transformOrigin: Item.Center

                                        // 缩放动画曲线：进入时用 OutBack 制造"冲一下再回弹"的
                                        // 弹性观感，退出时更快更干脆地收回去，两个方向手感不同，
                                        // 更接近主流播放器里的那种细节质感。
                                        Behavior on scale {
                                            NumberAnimation {
                                                duration: lyricRow.growing ? 320 : 220
                                                easing.type: lyricRow.growing ? Easing.OutBack : Easing.OutCubic
                                                easing.overshoot: 1.6
                                            }
                                        }
                                        Behavior on color {
                                            ColorAnimation { duration: 200 }
                                        }

                                        horizontalAlignment: Text.AlignHCenter
                                        wrapMode: Text.Wrap
                                        maximumLineCount: 2
                                        elide: Text.ElideRight
                                        lineHeight: 1.3
                                    }
                                }
                            }

                            // 首次加载 / 切歌时，让所有行直接跳到目标位置，不要从旧位置弹一遍。
                            // 注意：不能写 row.y = row.targetY ——因为 y 本身是靠
                            // "y: targetY" 这行声明式绑定来跟随的，任何脚本里对 y 的
                            // 直接赋值都会当场摧毁这个绑定，之后 y 就再也不会自动跟随
                            // targetY 变化了。正确做法是只关掉每行的 Behavior，然后
                            // "触发"绑定重新求值——做法是先记下 currentLyricIndex 相关的
                            // 依赖不变，直接调用 Qt.callLater 在下一帧关闭动画期间
                            // 让已经变化的 targetY 直接、无动画地写入 y（绑定本身仍然完整）。
                            // 绑定辅助：为指定行创建 targetY 绑定。
                            // 不能直接写 Qt.binding(function() { return row.targetY })——
                            // 循环里的 var row 是函数级作用域，所有闭包共享同一个
                            // 变量（循环结束后的最后一行），会导致每行的绑定都
                            // 指向最后一行的 targetY。用参数传参为每次调用创建
                            // 独立作用域。
                            function bindTargetY(r) {
                                return function() { return r.targetY }
                            }

                            function snapAll() {
                                // 若大跳转滑行动画还在跑，先停掉并清零位移，
                                // 避免与本次瞬间归位叠加造成偏移错位
                                bigJumpGlideAnim.stop()
                                lyricView._bigJumpShift = 0
                                for (var i = 0; i < lyricRepeater.count; i++) {
                                    var row = lyricRepeater.itemAt(i)
                                    if (row) {
                                        row.yBehaviorEnabled = false
                                        // Qt6 下仅把 Behavior 设为 disabled 不会打断
                                        // 正在运行的弹簧动画（实测 _animY 仍停在旧值），
                                        // 必须显式写入目标值再恢复绑定，才能瞬间归位。
                                        row._animY = row.targetY
                                        row._animY = Qt.binding(lyricView.bindTargetY(row))
                                        // 行被复用给新歌词时重置距离缓存，避免 growing
                                        // 方向判断沿用上一首歌的残留值导致首次缩放
                                        // 动画 easing 方向错误
                                        row._lastDistance = 999999
                                        row.growing = false
                                    }
                                }
                                // 关闭 Behavior 后，绑定已经把 y 更新为最新的 targetY
                                // （因为 currentLyricIndex/manualOffset 早已变化，只是之前
                                // 被 Behavior 动画拦下来了；这里 disable 之后，Qt 会在本帧
                                // 把 y 直接同步为绑定表达式的当前值，无过渡）。
                                // 下一帧再恢复 Behavior，后续变化重新走动画。
                                Qt.callLater(function() {
                                    for (var i = 0; i < lyricRepeater.count; i++) {
                                        var row = lyricRepeater.itemAt(i)
                                        if (row) row.yBehaviorEnabled = true
                                    }
                                })
                            }

                            // 注意：切歌时的"瞬间归位"不能挂在 player.songChanged 上触发——
                            // 查看 main.py 可知歌词是在 _async_load_metadata() 里异步加载的
                            // （_load_lyrics() 调用点在 durationChanged.emit() 之后），
                            // 也就是说 songChanged 触发的那一刻，新歌的歌词大概率还没加载完，
                            // 这时候去 rebuildGroups()/snapAll() 用到的还是上一首歌的分组表
                            // 和行数，会整个错位。真正代表"歌词数据已经就绪"的信号是
                            // lyricsChanged（_load_lyrics 末尾发出），所以分组重建和瞬间归位
                            // 都应该挂在 lyricsChanged 上，而不是 songChanged。
                            //
                            // 顺序也很重要：必须先 rebuildGroups() 算出新的分组表，
                            // 再执行 snapAll()——否则 snapAll 触发绑定重新求值时，
                            // currentTargetBase()/rowOffsetInStack() 用到的 groupOf 等数组
                            // 还是旧的，位置会算错。
                            Connections {
                                target: player
                                function onLyricsChanged() {
                                    // 切歌：完整复位手动浏览状态——之前只重置 manualOffset，
                                    // manualScrolling 残留 true 会把错落延迟禁用数秒，
                                    // 3 秒计时器和回中动画还会继续跑一次无意义动画
                                    lyricView.manualOffset = 0
                                    lyricView.manualScrolling = false
                                    lyricView.manualBaseIndex = -1
                                    resumeAutoScrollTimer.stop()
                                    manualOffsetAnim.stop()
                                    lyricView.rebuildGroups()
                                    Qt.callLater(lyricView.snapAll)
                                }
                            }
                        }

                        // 底部：歌曲名 + 时间
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 72
                            color: "transparent"

                            ColumnLayout {
                                anchors.centerIn: parent
                                spacing: 6

                                Text {
                                    font.family: window.uiFontFamily
                                    Layout.alignment: Qt.AlignHCenter
                                    text: player.currentSongName || ""
                                    color: textPrimary
                                    font.pixelSize: 14
                                    font.bold: true
                                    elide: Text.ElideRight
                                    maximumLineCount: 1
                                }

                                Row {
                                    Layout.alignment: Qt.AlignHCenter
                                    spacing: 8
                                    visible: player.state !== "stopped"

                                    Text {
                                        font.family: window.uiFontFamily
                                        text: player.formatTime(player.position)
                                        color: textSecondary
                                        font.pixelSize: 12
                                    }
                                    Text {
                                        font.family: window.uiFontFamily
                                        text: "/"
                                        color: textMuted
                                        font.pixelSize: 12
                                    }
                                    Text {
                                        font.family: window.uiFontFamily
                                        text: player.formatTime(player.duration)
                                        color: textSecondary
                                        font.pixelSize: 12
                                    }
                                }
                            }
                        }

                        // 无歌词时吞掉歌词区滚轮，避免触发全局滚轮音量；
                        // 有歌词时由歌词浏览 WheelHandler 接管（已 accept）。
                        WheelHandler {
                            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                            enabled: player.lyricCount === 0
                            onWheel: (event) => { event.accepted = true }
                        }
                    }
                }
            }
        }

        // ===== 底部控制栏 =====
        Rectangle {
            id: bottomBar
            Layout.fillWidth: true
            Layout.preferredHeight: 72
            // 底色由 bgSurface.bottomBarTint 提供（随背景一起被圆角遮罩）：
            // 之前这里自带方形背景，方角直抵窗口底边，左下/右下会画出
            // 暗色尖角；控件文字留在层外保持清晰
            color: "transparent"

            ColumnLayout {
                anchors.fill: parent
                spacing: 0

                // 进度条
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 4
                    color: progressBg

                    Rectangle {
                        id: progressFillBar
                        height: parent.height
                        width: player.duration > 0 ? (player.position / player.duration) * parent.width : 0
                        color: progressFill
                        radius: 2
                        // 拖动预览时关闭 200ms 动画，进度条精确跟手；
                        // 平时播放进度保留平滑过渡
                        Behavior on width {
                            enabled: !seekMouseArea.seeking
                            NumberAnimation { duration: 200 }
                        }
                    }

                    MouseArea {
                        id: seekMouseArea
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        property bool seeking: false
                        property bool dragging: false
                        property real pressX: 0
                        property real pendingPos: 0

                        // ===== 拖动逻辑（停止-预览-恢复） =====
                        // 按下只记录位置，不打断播放；真正开始拖动（位移 >3px）时
                        // 才停止播放进程（seekDragStarted），拖动过程中只做纯 UI
                        // 预览（seekPreview，精确跟随鼠标、不触碰进程），松手时
                        // 在目标位置恢复播放（seekCommit，-ss 精确定位）。
                        // 旧逻辑每次 mousemove 都杀启一次 ffplay，拖一次进度条
                        // = 几十次进程重启，是拖动卡顿的主因。
                        onPressed: {
                            if (player.duration > 0) {
                                seeking = true
                                dragging = false
                                pressX = mouseX
                                pendingPos = Math.max(0, Math.min(mouseX / width * player.duration, player.duration))
                            }
                        }
                        onPositionChanged: {
                            if (!seeking || player.duration <= 0)
                                return
                            pendingPos = Math.max(0, Math.min(mouseX / width * player.duration, player.duration))
                            if (!dragging && Math.abs(mouseX - pressX) > 3) {
                                dragging = true
                                player.seekDragStarted()
                            }
                            if (dragging)
                                player.seekPreview(pendingPos)
                        }
                        onReleased: {
                            if (!seeking)
                                return
                            seeking = false
                            if (dragging)
                                player.seekCommit(pendingPos)
                            else
                                player.seek(pendingPos)  // 原地点击：直接跳转
                        }
                        onCanceled: {
                            if (!seeking)
                                return
                            seeking = false
                            if (dragging)
                                player.seekCommit(pendingPos)
                        }
                    }
                }

                // 控制按钮
                RowLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.leftMargin: 24
                    Layout.rightMargin: 24
                    spacing: 8

                    // 设置按钮
                    Rectangle {
                        id: settingsBtn
                        width: 45
                        height: 45
                        radius: 22
                        color: hideControlBackgrounds ? "transparent" : (settingsBtnMouse.containsPress ? accentHover : accent)
                        Behavior on color { ColorAnimation { duration: 100 } }

                        Image {
                            id: settingsIconImg
                            anchors.centerIn: parent
                            width: 20
                            height: 20
                            source: "icons/cog.svg"
                            sourceSize.width: 20
                            sourceSize.height: 20
                            visible: false
                        }
                        ColorOverlay {
                            anchors.fill: settingsIconImg
                            source: settingsIconImg
                            color: hideControlBackgrounds ? "#eaeaea" : "#fff"
                        }

                        MouseArea {
                            id: settingsBtnMouse
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            hoverEnabled: true
                            onClicked: window.toggleSettings()
                        }

                        ToolTip {
                            visible: settingsBtnMouse.containsMouse
                            text: "设置"
                            delay: 500
                        }
                    }

                    // 下载按钮
                    Rectangle {
                        id: downloadBtn
                        width: 45
                        height: 45
                        radius: 22
                        color: hideControlBackgrounds ? "transparent" : (downloadBtnMouse.containsPress ? accentHover : accent)
                        Behavior on color { ColorAnimation { duration: 100 } }

                        Image {
                            id: downloadIconImg
                            anchors.centerIn: parent
                            width: 20
                            height: 20
                            source: "icons/DownLoad.svg"
                            sourceSize.width: 20
                            sourceSize.height: 20
                            visible: false
                        }

                        ColorOverlay {
                            anchors.fill: downloadIconImg
                            source: downloadIconImg
                            color: "#ffffff"
                        }

                        MouseArea {
                            id: downloadBtnMouse
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            hoverEnabled: true
                            onClicked: window.toggleDownload()
                        }

                        ToolTip {
                            visible: downloadBtnMouse.containsMouse
                            text: "在线下载歌词/封面"
                            delay: 500
                        }
                    }

                    // 左侧：当前播放信息
                    RowLayout {
                        Layout.preferredWidth: 200
                        spacing: 8
                        visible: player.state !== "stopped"

                        Rectangle {
                            Layout.preferredWidth: 36
                            Layout.preferredHeight: 36
                            radius: 6
                            color: bgCard
                            visible: coverImage.status === Image.Ready

                            Image {
                                anchors.fill: parent
                                fillMode: Image.PreserveAspectCrop
                                source: player.currentSongImage ? "file://" + player.currentSongImage + "?t=" + window.coverStamp : ""
                                asynchronous: false
                                smooth: true
                            }
                        }

                        Text {
                            font.family: window.uiFontFamily
                            text: player.currentSongName || ""
                            color: textPrimary
                            font.pixelSize: 13
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                    }

                    // 下一曲 (居中)
                    Text {
                        font.family: window.uiFontFamily
                        text: {
                            if (player.songCount <= 0 || player.currentIndex < 0) return ""
                            var nextIdx = (player.currentIndex + 1) % player.songCount
                            return "下一曲: " + player.songName(nextIdx)
                        }
                        color: textSecondary
                        font.pixelSize: 12
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                        visible: player.state !== "stopped"
                    }

                    Item { Layout.fillWidth: true; visible: player.state === "stopped" }

                    // 播放模式（顺序/单曲循环/随机）按钮：位于播放列表按钮左侧
                    Rectangle {
                        id: playModeBtn
                        width: 45
                        height: 45
                        radius: 22
                        color: hideControlBackgrounds ? "transparent" : (playModeBtnMouse.containsPress ? accentHover : accent)
                        Behavior on color { ColorAnimation { duration: 100 } }

                        Image {
                            id: playModeIconImg
                            anchors.centerIn: parent
                            width: 24
                            height: 24
                            source: {
                                switch (player.playMode) {
                                    case 0: return "icons/repeat.svg"        // 顺序
                                    case 1: return "icons/repeat-one.svg"    // 单曲循环
                                    default: return "icons/shuffle.svg"      // 随机
                                }
                            }
                            sourceSize.width: 24
                            sourceSize.height: 24
                            visible: false
                        }

                        ColorOverlay {
                            anchors.fill: playModeIconImg
                            source: playModeIconImg
                            color: "#ffffff"
                        }

                        MouseArea {
                            id: playModeBtnMouse
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            hoverEnabled: true
                            onClicked: player.playMode = (player.playMode + 1) % 3
                        }

                        ToolTip {
                            visible: playModeBtnMouse.containsMouse
                            text: {
                                switch (player.playMode) {
                                    case 0: return "顺序播放"
                                    case 1: return "单曲循环"
                                    default: return "随机播放"
                                }
                            }
                            delay: 500
                        }
                    }

                    // 折叠/展开播放列表按钮
                    Rectangle {
                        id: togglePlaylistBtn
                        width: 45
                        height: 45
                        radius: 22
                        color: hideControlBackgrounds ? "transparent" : (toggleBtnMouse.containsPress ? accentHover : accent)
                        Behavior on color { ColorAnimation { duration: 100 } }

                        Image {
                            id: playlistToggleIconImg
                            anchors.centerIn: parent
                            width: 20
                            height: 20
                            source: "icons/menu.svg"
                            sourceSize.width: 20
                            sourceSize.height: 20
                            visible: false
                        }
                        ColorOverlay {
                            anchors.fill: playlistToggleIconImg
                            source: playlistToggleIconImg
                            color: hideControlBackgrounds ? "#eaeaea" : "#fff"
                        }

                        MouseArea {
                            id: toggleBtnMouse
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            hoverEnabled: true
                                onClicked: {
                                    player.playlistVisible = !player.playlistVisible
                                    console.log("[UI] 播放列表 " + (player.playlistVisible ? "展开" : "收起"))
                                }
                        }

                        ToolTip {
                            visible: toggleBtnMouse.containsMouse
                            text: playlistVisible ? "收起播放列表" : "展开播放列表"
                            delay: 500
                        }
                    }

                    // 控制按钮组
                    RowLayout {
                        spacing: 4

                        // 上一首
                        Rectangle {
                            id: prevBtn
                            width: 50
                            height: 50
                            radius: 25
                            color: hideControlBackgrounds ? "transparent" : (prevBtnMouse.containsPress ? accentHover : accent)
                            Behavior on color { ColorAnimation { duration: 100 } }

                            Image {
                                id: prevIconImg
                                anchors.centerIn: parent
                                width: 24
                                height: 24
                                source: "icons/left.svg"
                                sourceSize.width: 24
                                sourceSize.height: 24
                                visible: false
                            }

                            ColorOverlay {
                                anchors.fill: prevIconImg
                                source: prevIconImg
                                color: "#ffffff"
                            }

                            MouseArea {
                                id: prevBtnMouse
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    console.log("[UI] 上一首")
                                    player.previous()
                                }
                            }
                        }

                        // 播放/暂停
                        Rectangle {
                            id: playBtn
                            width: 52
                            height: 52
                            radius: 26
                            color: hideControlBackgrounds ? "transparent" : (playBtnMouse.containsPress ? accentHover : accent)
                            Behavior on color { ColorAnimation { duration: 100 } }

                            Text {
                                font.family: window.uiFontFamily
                                anchors.centerIn: parent
                                text: player.state === "playing" ? "⏸" : "▶"
                                color: hideControlBackgrounds ? "#eaeaea" : "#fff"
                                font.pixelSize: 20
                            }

                            MouseArea {
                                id: playBtnMouse
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (playlistVisible && player.state !== "playing") {
                                        window.switchToLyric()
                                    }
                                    player.playPause()
                                    console.log("[UI] 播放/暂停 → " + player.state)
                                }
                            }
                        }

                        // 下一首
                        Rectangle {
                            id: nextBtn
                            width: 50
                            height: 50
                            radius: 25
                            color: hideControlBackgrounds ? "transparent" : (nextBtnMouse.containsPress ? accentHover : accent)
                            Behavior on color { ColorAnimation { duration: 100 } }

                            Image {
                                id: nextIconImg
                                anchors.centerIn: parent
                                width: 24
                                height: 24
                                source: "icons/Right.svg"
                                sourceSize.width: 24
                                sourceSize.height: 24
                                visible: false
                            }

                            ColorOverlay {
                                anchors.fill: nextIconImg
                                source: nextIconImg
                                color: "#ffffff"
                            }

                            MouseArea {
                                id: nextBtnMouse
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    console.log("[UI] 下一首")
                                    player.next()
                                }
                            }
                        }
                    }

                    // 右侧：音量
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignRight
                        spacing: 8

                        // 音量滑块
                        RowLayout {
                            spacing: 6
                            Layout.alignment: Qt.AlignRight

                            Image {
                                id: volumeIconImg
                                source: player.volume === 0 ? "icons/volume_off.svg" : (player.volume < 75 ? "icons/volume-low.svg" : "icons/volume_high.svg")
                                sourceSize.width: 18
                                sourceSize.height: 18
                                Layout.alignment: Qt.AlignVCenter
                                visible: false
                            }

                            ColorOverlay {
                                width: volumeIconImg.width
                                height: volumeIconImg.height
                                Layout.preferredWidth: volumeIconImg.width
                                Layout.preferredHeight: volumeIconImg.height
                                source: volumeIconImg
                                color: hideControlBackgrounds ? "#eaeaea" : "#ffffff"
                            }

                            Slider {
                                id: volumeSlider
                                from: 0
                                to: 100
                                value: player.volume
                                stepSize: 1
                                implicitWidth: 100
                                implicitHeight: 22

                                background: Rectangle {
                                    x: volumeSlider.leftPadding
                                    y: volumeSlider.topPadding + volumeSlider.availableHeight / 2 - height / 2
                                    width: volumeSlider.availableWidth
                                    height: 4
                                    radius: 2
                                    color: Qt.rgba(progressBg.r, progressBg.g, progressBg.b, 0.45)

                                    Rectangle {
                                        width: volumeSlider.visualPosition * parent.width
                                        height: parent.height
                                        radius: 2
                                        color: Qt.rgba(accent.r, accent.g, accent.b, 0.6)
                                    }
                                }

                                handle: Rectangle {
                                    x: volumeSlider.leftPadding + volumeSlider.visualPosition * (volumeSlider.availableWidth - width)
                                    y: volumeSlider.topPadding + volumeSlider.availableHeight / 2 - height / 2
                                    width: 14
                                    height: 14
                                    radius: 7
                                    color: volumeSlider.pressed
                                        ? Qt.rgba(accentHover.r, accentHover.g, accentHover.b, 0.85)
                                        : (hideControlBackgrounds
                                            ? Qt.rgba(accent.r, accent.g, accent.b, 0.85)
                                            : Qt.rgba(1, 1, 1, 0.85))
                                    border.color: Qt.rgba(accent.r, accent.g, accent.b, 0.8)
                                    border.width: 2
                                    Behavior on color { ColorAnimation { duration: 100 } }
                                }

                                onMoved: {
                                    // 拖动过程中做防抖：滑块视觉立即跟手，
                                    // 但真正下发给 player.volume（可能触发
                                    // PulseAudio 调用或 ffplay 重启）延迟到
                                    // 停止拖动一小段时间后再执行，避免每个
                                    // 像素都触发一次后端调用导致卡顿。
                                    volumeApplyTimer.pendingValue = value
                                    volumeApplyTimer.restart()
                                }
                                onPressedChanged: {
                                    if (!pressed) {
                                        // 松手时立即应用，不再等待防抖计时器
                                        volumeApplyTimer.stop()
                                        player.volume = value
                                    }
                                }

                                Timer {
                                    id: volumeApplyTimer
                                    interval: 60
                                    repeat: false
                                    property real pendingValue: volumeSlider.value
                                     onTriggered: player.volume = pendingValue
                                 }
                             }
                         }

                    }
                }
            }
        }
    }

    // ========== 设置面板（左侧滑出，占窗口 1/4 宽度） ==========
    Item {
        id: settingsOverlay
        anchors.fill: parent
        visible: false
        z: 100

        // 半透明遮罩（点击关闭）
        Rectangle {
            anchors.fill: parent
            radius: rootSurface.radius
            color: Qt.rgba(0, 0, 0, 0.35)

            MouseArea {
                anchors.fill: parent
                onClicked: settingsVisible = false
            }
        }

        // 设置面板
        Rectangle {
            id: settingsPanel
            width: Math.max(parent.width / 4, 300)
            height: parent.height
            x: settingsVisible ? 0 : -width
            color: Qt.rgba(bgDark.r, bgDark.g, bgDark.b, 0.97)

            Behavior on x {
                NumberAnimation { duration: 300; easing.type: Easing.OutCubic }
            }

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
                        color: Qt.rgba(accent.r, accent.g, accent.b, 0.55)
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
                    font.family: window.uiFontFamily
                    text: "设置"
                    color: textPrimary
                    font.pixelSize: 20
                    font.bold: true
                }

                // ===== 音乐文件夹 =====
                Text {
                    font.family: window.uiFontFamily
                    text: "音乐文件夹"
                    color: textPrimary
                    font.pixelSize: 14
                    font.bold: true
                }

                TextField {
                    id: musicDirInput
                    Layout.fillWidth: true
                    text: player.musicDir
                    placeholderText: "输入音乐文件夹路径..."
                    color: textPrimary
                    font.pixelSize: 12

                    // 目录无效时的红框提示状态（应用无效路径时短暂点亮）
                    property bool _invalid: false

                    background: Rectangle {
                        color: customBtnBg !== "" ? customBtnBg : "#1a1a3e"
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
                            color: customBtnBg !== "" ? customBtnBg : "#2a2a4e"
                            radius: 6
                        }
                        contentItem: Text {
                            text: parent.text
                            color: textPrimary
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
                                saveSetting("musicDir", musicDirInput.text)
                            } else {
                                musicDirInput.text = player.musicDir
                                musicDirInput._invalid = true
                                musicDirInvalidTimer.restart()
                            }
                        }
                        background: Rectangle {
                            implicitWidth: 52
                            implicitHeight: 28
                            color: accent
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
                    color: textMuted
                    opacity: 0.3
                }

                // ===== 颜色自定义 =====
                Text {
                    font.family: window.uiFontFamily
                    text: "颜色自定义"
                    color: textPrimary
                    font.pixelSize: 14
                    font.bold: true
                }

                // 主题色
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Text {
                        font.family: window.uiFontFamily
                        text: "主题色"
                        color: textPrimary
                        font.pixelSize: 12
                        Layout.preferredWidth: 60
                    }

                    Rectangle {
                        width: 20; height: 20; radius: 4
                        color: accent
                        border.color: textMuted
                        border.width: 1
                    }

                    Item { Layout.fillWidth: true }

                    Button {
                        text: "选择"
                        font.pixelSize: 11
                        onClicked: {
                            openColorDialog("customAccent", accent)
                        }
                        background: Rectangle {
                            implicitWidth: 52
                            implicitHeight: 28
                            color: customBtnBg !== "" ? customBtnBg : "#2a2a4e"
                            radius: 4
                        }
                        contentItem: Text {
                            text: parent.text
                            color: textPrimary
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
                        font.family: window.uiFontFamily
                        text: "背景色"
                        color: textPrimary
                        font.pixelSize: 12
                        Layout.preferredWidth: 60
                    }

                    Rectangle {
                        width: 20; height: 20; radius: 4
                        color: customDarkBg !== "" ? customDarkBg : "#1a1a2e"
                        border.color: textMuted
                        border.width: 1
                    }

                    Item { Layout.fillWidth: true }

                    Button {
                        text: "选择"
                        font.pixelSize: 11
                        onClicked: {
                            openColorDialog("customDarkBg", customDarkBg !== "" ? customDarkBg : "#1a1a2e")
                        }
                        background: Rectangle {
                            implicitWidth: 52
                            implicitHeight: 28
                            color: customBtnBg !== "" ? customBtnBg : "#2a2a4e"
                            radius: 4
                        }
                        contentItem: Text {
                            text: parent.text
                            color: textPrimary
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
                        font.family: window.uiFontFamily
                        text: "控件底色"
                        color: textPrimary
                        font.pixelSize: 12
                        Layout.preferredWidth: 60
                    }

                    Rectangle {
                        width: 20; height: 20; radius: 4
                        color: customBtnBg !== "" ? customBtnBg : "#2a2a4e"
                        border.color: textMuted
                        border.width: 1
                    }

                    Item { Layout.fillWidth: true }

                    Button {
                        text: "选择"
                        font.pixelSize: 11
                        onClicked: {
                            openColorDialog("customBtnBg", customBtnBg !== "" ? customBtnBg : "#2a2a4e")
                        }
                        background: Rectangle {
                            implicitWidth: 52
                            implicitHeight: 28
                            color: customBtnBg !== "" ? customBtnBg : "#2a2a4e"
                            radius: 4
                        }
                        contentItem: Text {
                            text: parent.text
                            color: textPrimary
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
                    color: textMuted
                    opacity: 0.3
                }

                // ===== 歌词颜色 =====
                Text {
                    font.family: window.uiFontFamily
                    text: "歌词颜色"
                    color: textPrimary
                    font.pixelSize: 14
                    font.bold: true
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Text {
                        font.family: window.uiFontFamily
                        text: "当前行"
                        color: textPrimary
                        font.pixelSize: 12
                        Layout.preferredWidth: 60
                    }

                    Rectangle {
                        width: 20; height: 20; radius: 4
                        color: customLyricColor !== "" ? customLyricColor : accent
                        border.color: textMuted
                        border.width: 1
                    }

                    Item { Layout.fillWidth: true }

                    Button {
                        text: "选择"
                        font.pixelSize: 11
                        onClicked: {
                            openColorDialog("customLyricColor", customLyricColor !== "" ? customLyricColor : accent)
                        }
                        background: Rectangle {
                            implicitWidth: 52
                            implicitHeight: 28
                            color: customBtnBg !== "" ? customBtnBg : "#2a2a4e"
                            radius: 4
                        }
                        contentItem: Text {
                            text: parent.text
                            color: textPrimary
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
                        font.family: window.uiFontFamily
                        text: "已播行"
                        color: textPrimary
                        font.pixelSize: 12
                        Layout.preferredWidth: 60
                    }

                    Rectangle {
                        width: 20; height: 20; radius: 4
                        color: customLyricPlayedColor !== "" ? customLyricPlayedColor : textMuted
                        border.color: textMuted
                        border.width: 1
                    }

                    Item { Layout.fillWidth: true }

                    Button {
                        text: "选择"
                        font.pixelSize: 11
                        onClicked: {
                            openColorDialog("customLyricPlayedColor", customLyricPlayedColor !== "" ? customLyricPlayedColor : textMuted)
                        }
                        background: Rectangle {
                            implicitWidth: 52
                            implicitHeight: 28
                            color: customBtnBg !== "" ? customBtnBg : "#2a2a4e"
                            radius: 4
                        }
                        contentItem: Text {
                            text: parent.text
                            color: textPrimary
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
                        font.family: window.uiFontFamily
                        text: "未播行"
                        color: textPrimary
                        font.pixelSize: 12
                        Layout.preferredWidth: 60
                    }

                    Rectangle {
                        width: 20; height: 20; radius: 4
                        color: customLyricUnplayedColor !== "" ? customLyricUnplayedColor : textSecondary
                        border.color: textMuted
                        border.width: 1
                    }

                    Item { Layout.fillWidth: true }

                    Button {
                        text: "选择"
                        font.pixelSize: 11
                        onClicked: {
                            openColorDialog("customLyricUnplayedColor", customLyricUnplayedColor !== "" ? customLyricUnplayedColor : textSecondary)
                        }
                        background: Rectangle {
                            implicitWidth: 52
                            implicitHeight: 28
                            color: customBtnBg !== "" ? customBtnBg : "#2a2a4e"
                            radius: 4
                        }
                        contentItem: Text {
                            text: parent.text
                            color: textPrimary
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
                        font.family: window.uiFontFamily
                        text: "隐藏控件底色"
                        color: textPrimary
                        font.pixelSize: 12
                        Layout.preferredWidth: 80
                    }

                    Item { Layout.fillWidth: true }

                    Rectangle {
                        width: 40; height: 22; radius: 11
                        color: hideControlBackgrounds ? accent : "#3a3a5e"
                        Behavior on color { ColorAnimation { duration: 150 } }

                        Rectangle {
                            x: hideControlBackgrounds ? 20 : 2
                            y: 2
                            width: 18; height: 18; radius: 9
                            color: "#ffffff"
                            Behavior on x { NumberAnimation { duration: 150 } }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: hideControlBackgrounds = !hideControlBackgrounds
                        }
                    }
                }

                // ===== 分割线 =====
                Rectangle {
                    Layout.fillWidth: true
                    height: 1
                    color: textMuted
                    opacity: 0.3
                }

                // ===== 背景效果 =====
                Text {
                    font.family: window.uiFontFamily
                    text: "背景效果"
                    color: textPrimary
                    font.pixelSize: 14
                    font.bold: true
                }

                // 模糊程度
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Text {
                        font.family: window.uiFontFamily
                        text: "模糊程度"
                        color: textPrimary
                        font.pixelSize: 12
                        Layout.preferredWidth: 60
                    }

                    Slider {
                        id: blurSlider
                        from: 0
                        to: 140
                        stepSize: 1
                        value: blurRadius
                        Layout.fillWidth: true
                        onValueChanged: blurRadius = value
                        background: Rectangle {
                            x: blurSlider.leftPadding
                            y: blurSlider.topPadding + blurSlider.availableHeight / 2 - height / 2
                            implicitWidth: 200
                            implicitHeight: 4
                            width: blurSlider.availableWidth
                            height: implicitHeight
                            radius: 2
                            color: progressBg
                            Rectangle {
                                width: blurSlider.visualPosition * parent.width
                                height: parent.height
                                color: accent
                                radius: 2
                            }
                        }
                        handle: Rectangle {
                            x: blurSlider.leftPadding + blurSlider.visualPosition * (blurSlider.availableWidth - width)
                            y: blurSlider.topPadding + blurSlider.availableHeight / 2 - height / 2
                            implicitWidth: 14
                            implicitHeight: 14
                            radius: 7
                            color: accent
                        }
                    }

                    Text {
                        font.family: window.uiFontFamily
                        text: Math.round(blurRadius)
                        color: textSecondary
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
                        font.family: window.uiFontFamily
                        text: "面板透明度"
                        color: textPrimary
                        font.pixelSize: 12
                        Layout.preferredWidth: 60
                    }

                    Slider {
                        id: opacitySlider
                        from: 0
                        to: 1
                        stepSize: 0.01
                        value: panelOpacity
                        Layout.fillWidth: true
                        onValueChanged: panelOpacity = value
                        background: Rectangle {
                            x: opacitySlider.leftPadding
                            y: opacitySlider.topPadding + opacitySlider.availableHeight / 2 - height / 2
                            implicitWidth: 200
                            implicitHeight: 4
                            width: opacitySlider.availableWidth
                            height: implicitHeight
                            radius: 2
                            color: progressBg
                            Rectangle {
                                width: opacitySlider.visualPosition * parent.width
                                height: parent.height
                                color: accent
                                radius: 2
                            }
                        }
                        handle: Rectangle {
                            x: opacitySlider.leftPadding + opacitySlider.visualPosition * (opacitySlider.availableWidth - width)
                            y: opacitySlider.topPadding + opacitySlider.availableHeight / 2 - height / 2
                            implicitWidth: 14
                            implicitHeight: 14
                            radius: 7
                            color: accent
                        }
                    }

                    Text {
                        font.family: window.uiFontFamily
                        text: Math.round(panelOpacity * 100) + "%"
                        color: textSecondary
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
                        customAccent = ""
                        customDarkBg = ""
                        customLyricColor = ""
                        customLyricPlayedColor = ""
                        customLyricUnplayedColor = ""
                        customBtnBg = ""
                        
                    }
                    background: Rectangle {
                        implicitWidth: 52
                        implicitHeight: 28
                        color: customBtnBg !== "" ? customBtnBg : "#2a2a4e"
                        radius: 4
                    }
                    contentItem: Text {
                        text: parent.text
                        color: textPrimary
                        font: parent.font
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                // ===== 分割线 =====
                Rectangle {
                    Layout.fillWidth: true
                    height: 1
                    color: textMuted
                    opacity: 0.3
                }

                // ===== 显示设置 =====
                Text {
                    font.family: window.uiFontFamily
                    text: "显示设置"
                    color: textPrimary
                    font.pixelSize: 14
                    font.bold: true
                }

                // 行间距
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Text {
                        font.family: window.uiFontFamily
                        text: "行间距"
                        color: textPrimary
                        font.pixelSize: 12
                        Layout.preferredWidth: 60
                    }

                    Slider {
                        id: rowSpacingSlider
                        from: 36
                        to: 72
                        stepSize: 2
                        value: rowSpacing
                        Layout.fillWidth: true
                        onValueChanged: rowSpacing = value
                        background: Rectangle {
                            x: rowSpacingSlider.leftPadding
                            y: rowSpacingSlider.topPadding + rowSpacingSlider.availableHeight / 2 - height / 2
                            implicitWidth: 200
                            implicitHeight: 4
                            width: rowSpacingSlider.availableWidth
                            height: implicitHeight
                            radius: 2
                            color: progressBg
                            Rectangle {
                                width: rowSpacingSlider.visualPosition * parent.width
                                height: parent.height
                                color: accent
                                radius: 2
                            }
                        }
                        handle: Rectangle {
                            x: rowSpacingSlider.leftPadding + rowSpacingSlider.visualPosition * (rowSpacingSlider.availableWidth - width)
                            y: rowSpacingSlider.topPadding + rowSpacingSlider.availableHeight / 2 - height / 2
                            implicitWidth: 14
                            implicitHeight: 14
                            radius: 7
                            color: accent
                        }
                    }

                    Text {
                        font.family: window.uiFontFamily
                        text: Math.round(rowSpacing) + "px"
                        color: textSecondary
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
                        font.family: window.uiFontFamily
                        text: "卡片大小"
                        color: textPrimary
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
                            color: progressBg
                            Rectangle {
                                width: cardSizeSlider.visualPosition * parent.width
                                height: parent.height
                                color: accent
                                radius: 2
                            }
                        }
                        handle: Rectangle {
                            x: cardSizeSlider.leftPadding + cardSizeSlider.visualPosition * (cardSizeSlider.availableWidth - width)
                            y: cardSizeSlider.topPadding + cardSizeSlider.availableHeight / 2 - height / 2
                            implicitWidth: 14
                            implicitHeight: 14
                            radius: 7
                            color: accent
                        }
                    }

                    Text {
                        font.family: window.uiFontFamily
                        text: player.cardSize + "px"
                        color: textSecondary
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
                        font.family: window.uiFontFamily
                        text: "全局字体"
                        color: textPrimary
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
                        text: customFontFamily
                        placeholderText: "留空则自动匹配，如需解决日文乱码可填 Noto Sans CJK JP"
                        color: textPrimary
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
                            if (customFontFamily !== text) customFontFamily = text
                        }
                        onAccepted: {
                            applyIfChanged()
                            focus = false
                        }
                        onActiveFocusChanged: {
                            if (!activeFocus) applyIfChanged()
                        }
                        background: Rectangle {
                            color: customBtnBg !== "" ? customBtnBg : "#1a1a3e"
                            radius: 6
                            border.color: "#334466"
                        }
                    }

                    Button {
                        text: "选择"
                        font.pixelSize: 11
                        onClicked: fontDialog.openFor("global", customFontFamily)
                        background: Rectangle {
                            implicitWidth: 52
                            implicitHeight: 28
                            color: customBtnBg !== "" ? customBtnBg : "#2a2a4e"
                            radius: 4
                        }
                        contentItem: Text {
                            text: parent.text
                            color: textPrimary
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
                            customFontFamily = ""
                        }
                        background: Rectangle {
                            implicitWidth: 52
                            implicitHeight: 28
                            color: customBtnBg !== "" ? customBtnBg : "#2a2a4e"
                            radius: 6
                        }
                        contentItem: Text {
                            text: parent.text
                            color: textPrimary
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
                    color: textMuted
                    opacity: 0.3
                    Layout.topMargin: 8
                    Layout.bottomMargin: 4
                }

                // ===== 自动切换到歌词界面 =====
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Text {
                        font.family: window.uiFontFamily
                        text: "自动切换到歌词"
                        color: textPrimary
                        font.pixelSize: 12
                    }

                    Item { Layout.fillWidth: true }

                    Rectangle {
                        width: 40; height: 22; radius: 11
                        color: autoSwitchToLyric ? accent : "#3a3a5e"
                        Behavior on color { ColorAnimation { duration: 150 } }

                        Rectangle {
                            x: autoSwitchToLyric ? 20 : 2
                            y: 2
                            width: 18; height: 18; radius: 9
                            color: "#ffffff"
                            Behavior on x { NumberAnimation { duration: 150 } }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: autoSwitchToLyric = !autoSwitchToLyric
                        }
                    }
                }

                // ===== 关闭行为 =====
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Text {
                        font.family: window.uiFontFamily
                        text: "点击 × 时隐藏到托盘"
                        color: textPrimary
                        font.pixelSize: 12
                    }

                    Item { Layout.fillWidth: true }

                    Rectangle {
                        width: 40; height: 22; radius: 11
                        color: closeToTray ? accent : "#3a3a5e"
                        Behavior on color { ColorAnimation { duration: 150 } }

                        Rectangle {
                            x: closeToTray ? 20 : 2
                            y: 2
                            width: 18; height: 18; radius: 9
                            color: "#ffffff"
                            Behavior on x { NumberAnimation { duration: 150 } }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: closeToTray = !closeToTray
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
                        color: customBtnBg !== "" ? customBtnBg : "#2a2a4e"
                        radius: 4
                    }
                    contentItem: Text {
                        text: parent.text
                        color: enabled ? textPrimary : textMuted
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
                    color: textMuted
                    opacity: 0.3
                }

                // ===== 桌面歌词设置 =====
                Text {
                    font.family: window.uiFontFamily
                    text: "桌面歌词"
                    color: textPrimary
                    font.pixelSize: 14
                    font.bold: true
                }

                // 桌面歌词开关
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Text {
                        font.family: window.uiFontFamily
                        text: "启用桌面歌词"
                        color: textPrimary
                        font.pixelSize: 12
                    }

                    Text {
                        font.family: window.uiFontFamily
                        text: appBridge && appBridge.desktopAvailable ? "" : "（不可用）"
                        color: textMuted
                        font.pixelSize: 10
                    }

                    Item { Layout.fillWidth: true }

                    Rectangle {
                        width: 40; height: 22; radius: 11
                        color: (appBridge && appBridge.desktopLyricsEnabled) ? accent : "#3a3a5e"
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
                        font.family: window.uiFontFamily
                        text: "锁定歌词"
                        color: textPrimary
                        font.pixelSize: 12
                    }

                    Text {
                        font.family: window.uiFontFamily
                        text: "开启后不可拖动"
                        color: textMuted
                        font.pixelSize: 10
                    }

                    Item { Layout.fillWidth: true }

                    Rectangle {
                        width: 40; height: 22; radius: 11
                        color: desktopLyricLocked ? accent : "#3a3a5e"
                        opacity: appBridge && appBridge.desktopAvailable ? 1.0 : 0.4
                        Behavior on color { ColorAnimation { duration: 150 } }

                        Rectangle {
                            x: desktopLyricLocked ? 20 : 2
                            y: 2
                            width: 18; height: 18; radius: 9
                            color: "#ffffff"
                            Behavior on x { NumberAnimation { duration: 150 } }
                        }

                        MouseArea {
                            anchors.fill: parent
                            enabled: appBridge && appBridge.desktopAvailable
                            cursorShape: Qt.PointingHandCursor
                            onClicked: desktopLyricLocked = !desktopLyricLocked
                        }
                    }
                }

                // 桌面歌词字体
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Text {
                        font.family: window.uiFontFamily
                        text: "歌词字体"
                        color: textPrimary
                        font.pixelSize: 12
                        Layout.preferredWidth: 60
                    }

                    Text {
                        font.family: window.uiFontFamily
                        text: desktopLyricFont !== "" ? desktopLyricFont : "（默认）"
                        color: desktopLyricFont !== "" ? textPrimary : textMuted
                        font.pixelSize: 12
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }

                    Button {
                        text: "选择"
                        font.pixelSize: 11
                        onClicked: fontDialog.openFor("desktop", desktopLyricFont)
                        background: Rectangle {
                            implicitWidth: 52
                            implicitHeight: 28
                            color: customBtnBg !== "" ? customBtnBg : "#2a2a4e"
                            radius: 6
                        }
                        contentItem: Text {
                            text: parent.text
                            color: textPrimary
                            font: parent.font
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }

                    Button {
                        text: "重置"
                        font.pixelSize: 11
                        onClicked: desktopLyricFont = ""
                        background: Rectangle {
                            implicitWidth: 52
                            implicitHeight: 28
                            color: customBtnBg !== "" ? customBtnBg : "#2a2a4e"
                            radius: 6
                        }
                        contentItem: Text {
                            text: parent.text
                            color: textPrimary
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
                        font.family: window.uiFontFamily
                        text: "歌词颜色"
                        color: textPrimary
                        font.pixelSize: 12
                        Layout.preferredWidth: 60
                    }

                    Rectangle {
                        width: 22; height: 22; radius: 4
                        color: desktopLyricColor !== "" ? desktopLyricColor : "#ffffff"
                        border.color: textMuted
                        border.width: 1
                    }

                    Item { Layout.fillWidth: true }

                    Button {
                        text: "选择"
                        font.pixelSize: 11
                        onClicked: openColorDialog("desktopLyricColor", desktopLyricColor !== "" ? desktopLyricColor : "#ffffff")
                        background: Rectangle {
                            implicitWidth: 52
                            implicitHeight: 28
                            color: customBtnBg !== "" ? customBtnBg : "#2a2a4e"
                            radius: 4
                        }
                        contentItem: Text {
                            text: parent.text
                            color: textPrimary
                            font: parent.font
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }

            }
        }
    }
    }

    // ========== 下载面板（右侧滑出） ==========
    Item {
        id: downloadOverlay
        anchors.fill: parent
        visible: false
        z: 100

        // 半透明遮罩（点击关闭）
        Rectangle {
            anchors.fill: parent
            radius: rootSurface.radius
            color: Qt.rgba(0, 0, 0, 0.35)

            MouseArea {
                anchors.fill: parent
                onClicked: downloadVisible = false
            }
        }

        // 下载面板
        Rectangle {
            id: downloadPanel
            width: parent.width / 3
            height: parent.height
            x: downloadVisible ? parent.width - width : parent.width
            color: Qt.rgba(bgDark.r, bgDark.g, bgDark.b, 0.97)

            Behavior on x {
                NumberAnimation { duration: 300; easing.type: Easing.OutCubic }
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 20
                spacing: 12

                // 标题
                Text {
                    font.family: window.uiFontFamily
                    text: "在线下载歌词/封面"
                    color: textPrimary
                    font.pixelSize: 16
                    font.bold: true
                }

                // 当前歌曲
                Text {
                    font.family: window.uiFontFamily
                    text: "当前歌曲: " + (player.currentSongName || "无")
                    color: textSecondary
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
                            color: textPrimary
                            font.pixelSize: 13
                            clip: true
                            text: player.currentSongName || ""
                            onTextEdited: window._searchBoxEdited = true
                        }
                    }

                    Rectangle {
                        width: 60
                        height: 36
                        radius: 6
                        color: accent
                        Behavior on color { ColorAnimation { duration: 100 } }

                        Text {
                            font.family: window.uiFontFamily
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
                    font.family: window.uiFontFamily
                    id: downloadStatusText
                    text: player.downloadStatus || ""
                    color: textSecondary
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
                                    font.family: window.uiFontFamily
                                    text: modelData.name || ""
                                    color: textPrimary
                                    font.pixelSize: 13
                                    font.bold: true
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }

                                Text {
                                    font.family: window.uiFontFamily
                                    text: (modelData.artist || "") + (modelData.album ? " · " + modelData.album : "")
                                    color: textSecondary
                                    font.pixelSize: 11
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }

                                // 歌曲时长（小标题下方）：duration 为 0（接口
                                // 未返回）时隐藏，不占空间
                                Text {
                                    font.family: window.uiFontFamily
                                    text: modelData.duration > 0 ? player.formatTime(modelData.duration / 1000) : ""
                                    color: textMuted
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
                                color: accent
                                Behavior on color { ColorAnimation { duration: 100 } }

                                Text {
                                    font.family: window.uiFontFamily
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
                                color: accent
                                Behavior on color { ColorAnimation { duration: 100 } }

                                Text {
                                    font.family: window.uiFontFamily
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
    }

    // ===== 圆角遮罩（rootSurface 的 layer.effect 取样源，勿放进 rootSurface 内） =====
    Rectangle {
        id: rootMask
        visible: false
        anchors.fill: rootSurface
        radius: rootSurface.radius
    }

    // ===== 无边框窗口的尺寸调节边缘 =====
    // 根容器四周留了 6px 透明边，边缘条挂在窗口级（rootSurface 之上），
    // 最大化时隐藏（贴边不需要也无法调节）
    Item {
        id: resizeEdges
        visible: window._frameless && window.visibility !== Window.Maximized
        anchors.fill: parent

        MouseArea {
            anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
            width: 6
            cursorShape: Qt.SizeHorCursor
            onPressed: window.startSystemResize(Qt.LeftEdge)
        }
        MouseArea {
            anchors { right: parent.right; top: parent.top; bottom: parent.bottom }
            width: 6
            cursorShape: Qt.SizeHorCursor
            onPressed: window.startSystemResize(Qt.RightEdge)
        }
        MouseArea {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            height: 6
            cursorShape: Qt.SizeVerCursor
            onPressed: window.startSystemResize(Qt.TopEdge)
        }
        MouseArea {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: 6
            cursorShape: Qt.SizeVerCursor
            onPressed: window.startSystemResize(Qt.BottomEdge)
        }
        MouseArea {
            anchors { left: parent.left; top: parent.top }
            width: 10; height: 10
            cursorShape: Qt.SizeFDiagCursor
            onPressed: window.startSystemResize(Qt.LeftEdge | Qt.TopEdge)
        }
        MouseArea {
            anchors { right: parent.right; top: parent.top }
            width: 10; height: 10
            cursorShape: Qt.SizeBDiagCursor
            onPressed: window.startSystemResize(Qt.RightEdge | Qt.TopEdge)
        }
        MouseArea {
            anchors { left: parent.left; bottom: parent.bottom }
            width: 10; height: 10
            cursorShape: Qt.SizeBDiagCursor
            onPressed: window.startSystemResize(Qt.LeftEdge | Qt.BottomEdge)
        }
        MouseArea {
            anchors { right: parent.right; bottom: parent.bottom }
            width: 10; height: 10
            cursorShape: Qt.SizeFDiagCursor
            onPressed: window.startSystemResize(Qt.RightEdge | Qt.BottomEdge)
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
                case "customAccent": customAccent = selectedColor; break
                case "customDarkBg": customDarkBg = selectedColor; break
                case "customLyricColor": customLyricColor = selectedColor; break
                case "customLyricPlayedColor": customLyricPlayedColor = selectedColor; break
                case "customLyricUnplayedColor": customLyricUnplayedColor = selectedColor; break
                case "customBtnBg": customBtnBg = selectedColor; break
                case "desktopLyricColor": desktopLyricColor = selectedColor; break
                
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
                    desktopLyricFont = _selectedFont
                } else {
                    customFontFamily = _selectedFont
                    customFontInput.text = _selectedFont
                }
            }
        }

        background: Rectangle {
            color: Qt.rgba(bgDark.r, bgDark.g, bgDark.b, 1)
            radius: 8
        }

        header: Rectangle {
            implicitHeight: 44
            color: "transparent"
            Text {
                font.family: window.uiFontFamily
                anchors.centerIn: parent
                text: fontDialog.target === "desktop" ? "选择桌面歌词字体" : "选择全局字体"
                color: textPrimary
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
                color: textPrimary
                font.pixelSize: 12
                background: Rectangle {
                    color: customBtnBg !== "" ? customBtnBg : "#1a1a3e"
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
                        ? accent
                        : (fontMouse.containsMouse ? Qt.rgba(1,1,1,0.08) : "transparent")

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: 8
                        text: modelData
                        color: fontDialog._selectedFont === modelData ? "#fff" : textPrimary
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
                        color: Qt.rgba(accent.r, accent.g, accent.b, 0.55)
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
                        color: customBtnBg !== "" ? customBtnBg : "#2a2a4e"
                        radius: 6
                    }
                    contentItem: Text {
                        text: parent.text
                        color: textSecondary
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
                        color: enabled ? accent : "#3a3a5e"
                        radius: 6
                    }
                    contentItem: Text {
                        text: parent.text
                        color: enabled ? "#fff" : textMuted
                        font: parent.font
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }
        }
    }

    // ===== 重命名歌曲对话框 =====
    Dialog {
        id: renameDialog
        modal: true
        width: 380
        height: 220
        padding: 0

        property int targetIndex: -1
        property string errorText: ""

        function openFor(idx) {
            renameDialog.targetIndex = idx
            renameDialog.errorText = ""
            // 用真实文件名（不含扩展名）预填，而不是列表显示名——
            // 显示名可能来自内嵌元数据，与磁盘文件名不一致。
            var p = player.songPath(idx)
            var base = p ? p.replace(/^.*[\\/]/, "").replace(/\.[^.]+$/, "") : ""
            renameInput.text = base
            renameDialog.open()
            renameInput.forceActiveFocus()
            renameInput.selectAll()
        }

        background: Rectangle {
            color: Qt.rgba(bgDark.r, bgDark.g, bgDark.b, 1)
            radius: 8
        }

        header: Rectangle {
            implicitHeight: 44
            color: "transparent"
            Text {
                font.family: window.uiFontFamily
                anchors.centerIn: parent
                text: "重命名歌曲"
                color: textPrimary
                font.pixelSize: 15
                font.bold: true
            }
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 10

            TextField {
                id: renameInput
                Layout.fillWidth: true
                placeholderText: "新文件名（不含扩展名）"
                color: textPrimary
                font.pixelSize: 13
                selectByMouse: true
                onTextChanged: renameDialog.errorText = ""
                onAccepted: confirmRenameButton.clicked()
                background: Rectangle {
                    color: customBtnBg !== "" ? customBtnBg : "#1a1a3e"
                    radius: 6
                    border.color: renameDialog.errorText !== "" ? "#e94560" : "#334466"
                }
            }

            Text {
                Layout.fillWidth: true
                visible: renameDialog.errorText !== ""
                text: renameDialog.errorText
                color: "#e94560"
                font.pixelSize: 11
                wrapMode: Text.WordWrap
            }

            Item { Layout.fillHeight: true }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Item { Layout.fillWidth: true }
                Button {
                    text: "取消"
                    font.pixelSize: 12
                    onClicked: renameDialog.reject()
                    background: Rectangle {
                        implicitWidth: 60
                        implicitHeight: 28
                        color: customBtnBg !== "" ? customBtnBg : "#2a2a4e"
                        radius: 6
                    }
                    contentItem: Text {
                        text: parent.text
                        color: textSecondary
                        font: parent.font
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
                Button {
                    id: confirmRenameButton
                    text: "确定"
                    font.pixelSize: 12
                    enabled: renameInput.text.trim() !== ""
                    onClicked: {
                        if (player.renameSong(renameDialog.targetIndex, renameInput.text.trim()))
                            renameDialog.accept()
                        else
                            renameDialog.errorText = "重命名失败：名称为空、非法或目标文件已存在"
                    }
                    background: Rectangle {
                        implicitWidth: 60
                        implicitHeight: 28
                        color: enabled ? accent : "#3a3a5e"
                        radius: 6
                    }
                    contentItem: Text {
                        text: parent.text
                        color: enabled ? "#fff" : textMuted
                        font: parent.font
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }
        }
    }

    // ===== 删除歌曲确认对话框 =====
    Dialog {
        id: deleteDialog
        modal: true
        width: 380
        height: 250
        padding: 0
        // 从整个界面左上角下拉下来：定位到左上角，进入时从界面上方滑入
        x: 0
        y: 0

        property int targetIndex: -1
        property string targetName: ""
        property string errorText: ""

        function openFor(idx, name) {
            deleteDialog.targetIndex = idx
            deleteDialog.targetName = name || ""
            deleteDialog.errorText = ""
            deleteDialog.open()
        }

        // 打开：从界面上方（负 y，画面之外）下拉到左上角，同时淡入
        enter: Transition {
            ParallelAnimation {
                NumberAnimation { property: "opacity"; from: 0.0; to: 1.0; duration: 160; easing.type: Easing.OutCubic }
                NumberAnimation { property: "y"; from: -deleteDialog.height; to: 0; duration: 260; easing.type: Easing.OutCubic }
            }
        }
        // 关闭：向上收回画面之外并淡出
        exit: Transition {
            ParallelAnimation {
                NumberAnimation { property: "opacity"; from: 1.0; to: 0.0; duration: 160; easing.type: Easing.InCubic }
                NumberAnimation { property: "y"; from: 0; to: -deleteDialog.height; duration: 200; easing.type: Easing.InCubic }
            }
        }

        // 毛玻璃半透明：深色底随 panelOpacity 半透明，透出背后已模糊的封面；
        // 叠一圈细边框 + 顶部高光，营造玻璃质感。panelOpacity 过低时 clamp
        // 一个下限，避免文字失去可读性。
        background: Item {
            Rectangle {
                anchors.fill: parent
                radius: 12
                color: Qt.rgba(bgDark.r, bgDark.g, bgDark.b,
                               Math.min(0.85, Math.max(0.55, panelOpacity)))
                border.width: 1
                border.color: Qt.rgba(1, 1, 1, 0.14)

                // 顶部玻璃高光，模拟光线在磨砂玻璃上的反射
                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    height: parent.height * 0.45
                    radius: parent.radius
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0.10) }
                        GradientStop { position: 1.0; color: Qt.rgba(1, 1, 1, 0.0) }
                    }
                }
            }
        }

        // 弹窗出现时除弹窗外的界面整体变暗 25%
        Overlay.modal: Rectangle {
            color: Qt.rgba(0, 0, 0, 0.25)
        }

        header: Rectangle {
            implicitHeight: 44
            color: "transparent"
            Text {
                font.family: window.uiFontFamily
                anchors.centerIn: parent
                text: "删除歌曲"
                color: textPrimary
                font.pixelSize: 15
                font.bold: true
            }
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 10

            Text {
                Layout.fillWidth: true
                text: "确定要删除《" + deleteDialog.targetName + "》吗？"
                color: textPrimary
                font.pixelSize: 13
                wrapMode: Text.WordWrap
            }

            Text {
                Layout.fillWidth: true
                text: "将同时删除磁盘上的歌曲文件、歌词与封面（含 .bak 备份），此操作不可恢复。"
                color: textMuted
                font.pixelSize: 11
                wrapMode: Text.WordWrap
            }

            Text {
                Layout.fillWidth: true
                visible: deleteDialog.errorText !== ""
                text: deleteDialog.errorText
                color: "#e94560"
                font.pixelSize: 11
                wrapMode: Text.WordWrap
            }

            Item { Layout.fillHeight: true }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Item { Layout.fillWidth: true }
                Button {
                    text: "取消"
                    font.pixelSize: 12
                    onClicked: deleteDialog.reject()
                    background: Rectangle {
                        implicitWidth: 60
                        implicitHeight: 28
                        color: customBtnBg !== "" ? customBtnBg : "#2a2a4e"
                        radius: 6
                    }
                    contentItem: Text {
                        text: parent.text
                        color: textSecondary
                        font: parent.font
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
                Button {
                    text: "删除"
                    font.pixelSize: 12
                    onClicked: {
                        if (player.deleteSong(deleteDialog.targetIndex))
                            deleteDialog.accept()
                        else
                            deleteDialog.errorText = "删除失败：文件可能已被占用或没有权限"
                    }
                    background: Rectangle {
                        implicitWidth: 60
                        implicitHeight: 28
                        color: "#e94560"
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

    

    // ========== 设置面板显示/隐藏控制 ==========
    Timer {
        id: settingsCloseTimer
        interval: 300
        onTriggered: settingsOverlay.visible = false
    }

    // ========== 下载面板显示/隐藏控制 ==========
    Timer {
        id: downloadCloseTimer
        interval: 300
        onTriggered: downloadOverlay.visible = false
    }

    // ========== 全局鼠标滚轮音量调节（非滚动区生效） ==========
    // 挂在窗口根级（最后声明=最上层），鼠标在窗口任意位置都能捕获滚轮。
    // 可滚动视图（曲目列表/卡片/歌词）内部各自挂有"手动滚动+吞事件"的
    // WheelHandler，会把该区域内的滚轮事件全部拦截，根级处理器收不到，
    // 因此这些区域滚轮只滚动、不调音量；其余区域（底部控制栏、标题栏、
    // 左侧封面等）的滚轮事件才会到达这里调节音量。
    WheelHandler {
        target: null
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad

        onWheel: (event) => {
            // 设置面板或下载面板打开时放行，让子级滚动/输入正常
            if (settingsVisible || downloadVisible) {
                event.accepted = false
                return
            }

            var steps = event.angleDelta.y / 120
            // 在防抖窗口的 pendingValue 上累加，避免快速滚动丢步
            var base = wheelVolumeTimer.running ? wheelVolumeTimer.pendingValue : player.volume
            var newVolume = Math.max(0, Math.min(100, Math.round(base + steps * 5)))
            if (newVolume !== base) {
                wheelVolumeTimer.pendingValue = newVolume
                wheelVolumeTimer.restart()
            }
        }
    }

    Timer {
        id: wheelVolumeTimer
        interval: 40
        repeat: false
        property real pendingValue: player.volume
        onTriggered: player.volume = pendingValue
    }

    // ========== 键盘快捷键 ==========
    // enabled 绑定 _isTyping：输入框获得焦点时不拦截按键，
    // 避免打字时误触播放/seek
    Shortcut {
        sequence: "Space"
        enabled: !window._isTyping
        onActivated: player.playPause()
    }
    Shortcut {
        sequence: "Right"
        enabled: !window._isTyping
        onActivated: {
            // 时长未知（异步加载未完成）时不能按 0 clamp，否则会 seek 到 0:00
            var target = player.position + 5
            if (player.duration > 0)
                target = Math.min(target, player.duration)
            player.seek(target)
        }
    }
    Shortcut {
        sequence: "Left"
        enabled: !window._isTyping
        onActivated: player.seek(Math.max(player.position - 5, 0))
    }

    onSettingsVisibleChanged: {
        if (settingsVisible) {
            // 快速关闭再打开时，之前启动的关闭计时器必须取消，
            // 否则计时器到期会把刚重新打开的面板隐藏
            settingsCloseTimer.stop()
            settingsOverlay.visible = true
        } else {
            settingsCloseTimer.start()
        }
    }

    onDownloadVisibleChanged: {
        if (downloadVisible) {
            downloadCloseTimer.stop()
            downloadOverlay.visible = true
        } else {
            downloadCloseTimer.start()
        }
    }
}
