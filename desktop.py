#!/usr/bin/env python3
"""desktop.py - 桌面歌词（透明置顶窗口）

独立于 main.py 的桌面歌词层：创建一个小型、无边框、透明的置顶 QML 窗口，
实时显示当前播放歌词，与主窗口共用同一 QApplication。

用法:
  from desktop import DesktopLyrics
  lyrics = DesktopLyrics(player)
  lyrics.show() / lyrics.hide() / lyrics.setEnabled(True/False)
  python3 desktop.py            # 独立自测（内置假歌词）

Wayland 说明:
  Wayland 协议不允许客户端自我置顶/查询或设置自己窗口的全局坐标，
  Qt.WindowStaysOnTopHint / setPosition 在 Wayland 下会被合成器忽略。
  因此按桌面环境分派：
  - KDE Wayland（默认）：层模式（layer-shell）。窗口是合成器的
    wlr-layer-shell layer surface（desktop_layer.qml，KDE 系统库
    org.kde.layershell）：layer=Overlay 天然置顶于所有普通窗口之上，
    锚定屏幕底边+左边（位置由 margins 决定），键盘不可交互，点击
    穿透由 WindowTransparentForInput 翻译成的空 input region 实现。
    可用环境变量 PYMUSIC_DESKTOP_LYRIC_NO_LAYER_SHELL=1 关闭。
  - 非 KDE Wayland / 层模式加载失败：普通窗口回退（desktop.qml）。
    置顶只设 Qt flag（合成器通常忽略，建议用窗口规则）；位置借道
    运行在合成器内部的 KWin 脚本，通过 org.kde.KWin D-Bus 接口注入
    一次性脚本，脚本内按标题匹配窗口读写 frameGeometry，并用 callDBus
    把真实坐标回调给本进程注册的 org.pymusic.DesktopLyric D-Bus 服务
    （_PositionReceiver）。仅在 KDE + Wayland 且 PySide6.QtDBus 可用
    时启用，任何一环缺失静默降级（位置退回默认摆位）。

鼠标交互与移动:
  歌词窗口默认是普通窗口（可被 KWin 原生拖动）：左键拖动
  （startSystemMove）或 Meta+左键 均可；置顶由 KWin 脚本 keepAbove
  保证（Wayland 下客户端无协议级置顶请求）。
  "锁定歌词"开关（持久化 desktopLyricLocked）决定点击穿透。
  位置保存：每 3 秒借道 KWin 脚本查询合成器侧真实坐标落盘（异常退出
  也不丢位置，可用 PYMUSIC_DESKTOP_LYRIC_SYNC_MS 改间隔），关闭时
  再兜底一次。
  层模式（PYMUSIC_DESKTOP_LYRIC_LAYER_SHELL=1，默认关闭）：窗口是
  layer surface，天然置顶但 KWin 无法移动它（协议硬限制）。
"""

import os
import sys
import json
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

from PySide6.QtCore import QObject, QPoint, QTimer, Signal, Slot, Property, QUrl, Qt, ClassInfo
from PySide6.QtQuick import QQuickView
from PySide6.QtQml import QQmlApplicationEngine
from PySide6.QtGui import QGuiApplication
from PySide6.QtWidgets import QMenu
try:
    from PySide6.QtDBus import QDBusConnection
    _HAVE_QTDBUS = True
except Exception:
    _HAVE_QTDBUS = False

# 加入入口目录，保证能找到同目录的 main.py（自测时才需要）
_HERE = Path(__file__).resolve().parent
_QML_PATH = _HERE / "desktop.qml"
_QML_LAYER_PATH = _HERE / "desktop_layer.qml"

# 供 KWin 窗口规则匹配的窗口类/标题关键词
WINDOW_CLASS_HINT = "desktoplyric"
WINDOW_TITLE_HINT = "桌面歌词"

# 调试日志：默认关闭，设 PYMUSIC_DESKTOP_LYRIC_DEBUG=1 打开
_DEBUG = os.environ.get("PYMUSIC_DESKTOP_LYRIC_DEBUG") == "1"


def _dlog(msg):
    if not _DEBUG:
        return
    ts = time.strftime("%H:%M:%S")
    print("[desktop][%s] %s" % (ts, msg), file=sys.stderr, flush=True)


def _use_layer_shell_mode():
    """是否启用 Wayland 层模式（KDE layer-shell）。

    默认不启用：层窗口（layer surface）在 KWin 里 isMovableAcrossScreens()
    = false，KWin 的交互式移动（Meta+左键 强制拖动）对层窗口无效——
    层窗口永远无法被 KWin 拖动，这是协议层面的硬限制。因此默认走普通
    窗口（KWin 原生拖动可用，置顶由 keepAbove 脚本保证）。

    仅当显式设置 PYMUSIC_DESKTOP_LYRIC_LAYER_SHELL=1 且处于 KDE Wayland
    时启用（置顶最可靠，但不可拖动）。QML 加载失败会在
    DesktopLyrics.__init__ 里回退普通窗口。
    """
    if QGuiApplication.platformName() != "wayland":
        return False
    if "KDE" not in os.environ.get("XDG_CURRENT_DESKTOP", ""):
        _dlog("_use_layer_shell_mode: 非 KDE 桌面（%r），不启用层模式"
              % os.environ.get("XDG_CURRENT_DESKTOP", ""))
        return False
    if os.environ.get("PYMUSIC_DESKTOP_LYRIC_LAYER_SHELL") != "1":
        _dlog("_use_layer_shell_mode: 未设置 PYMUSIC_DESKTOP_LYRIC_LAYER_"
              "SHELL=1（层窗口不可拖动，默认普通窗口）")
        return False
    return True


def _is_hyprland():
    """是否运行在 Hyprland（Wayland）下。"""
    if QGuiApplication.platformName() != "wayland":
        return False
    if os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"):
        return True
    return "Hyprland" in os.environ.get("XDG_CURRENT_DESKTOP", "")


class _HyprlandFloater:
    """Hyprland 下把桌面歌词窗口切换为浮动。

    Hyprland 是平铺合成器，普通窗口默认会被平铺；而 Wayland 协议不允许
    客户端自己请求浮动，只能借道 Hyprland 的 hyprctl：
      - `hyprctl -j clients` 列出所有窗口（含 pid/title/class/floating）；
      - 按"本进程 pid + 标题"定位桌面歌词窗口；
      - 未浮动则 `hyprctl dispatch setfloating address:<addr>`，旧版
        没有该 dispatcher 时回退 `togglefloating`。
    窗口 show 后需几百毫秒才被合成器注册，调用方负责延迟重试。
    """

    def __init__(self, title, class_hint):
        self._title = title or ""
        self._class = (class_hint or "").lower()

    @staticmethod
    def is_hyprland():
        return _is_hyprland()

    def _clients(self):
        try:
            r = subprocess.run(["hyprctl", "-j", "clients"],
                               capture_output=True, text=True, timeout=3)
            if r.returncode != 0 or not r.stdout.strip():
                _dlog("_HyprlandFloater._clients: hyprctl 返回 rc=%s" % r.returncode)
                return None
            return json.loads(r.stdout)
        except Exception as e:
            _dlog("_HyprlandFloater._clients 异常: %r" % (e,))
            return None

    def ensure_floating(self):
        """把本进程的桌面歌词窗口设为浮动；成功或已浮动返回 True。"""
        if not self.is_hyprland():
            return False
        clients = self._clients()
        if clients is None:
            return False
        pid = os.getpid()
        target = None
        for c in clients:
            try:
                if int(c.get("pid", -1)) != pid:
                    continue
            except (TypeError, ValueError):
                continue
            title = c.get("title") or ""
            cls = ((c.get("class") or "") + " " + (c.get("initialClass") or "")).lower()
            if (self._title and self._title in title) \
                    or (self._class and self._class in cls):
                target = c
                break
        if target is None:
            _dlog("_HyprlandFloater.ensure_floating: 未找到本进程的桌面歌词窗口")
            return False
        if target.get("floating"):
            _dlog("_HyprlandFloater.ensure_floating: 窗口已是浮动，无需处理")
            return True
        addr = target.get("address")
        if not addr:
            return False
        # 依次尝试：
        # 1) 新版 Lua 配置（Hyprland 0.56+）：dispatcher 为 hl.dsp.window.float，
        #    必须经 hl.dispatch() 执行；用字符串式 dispatch 会报 Lua 解析错误。
        # 2) 旧版字符串 dispatcher：setfloating（较新）→ togglefloating（兜底）。
        # 已确认窗口未浮动，故 togglefloating 不会把它平铺掉。
        eval_code = ("hl.dispatch(hl.dsp.window.float({ action='set', "
                     "window='address:%s' }))" % addr)
        candidates = (
            ["hyprctl", "eval", eval_code],
            ["hyprctl", "dispatch", "setfloating", "address:" + addr],
            ["hyprctl", "dispatch", "togglefloating", "address:" + addr],
        )
        for args in candidates:
            try:
                r = subprocess.run(args, capture_output=True, text=True, timeout=3)
            except Exception as e:
                _dlog("_HyprlandFloater.ensure_floating: %s 异常 %r" % (args[1:3], e))
                continue
            out = ((r.stdout or "") + (r.stderr or "")).strip()
            low = out.lower()
            if r.returncode == 0 and "error" not in low \
                    and "invalid" not in low and "unknown" not in low:
                _dlog("_HyprlandFloater.ensure_floating: %s -> %s"
                      % (args[1:3], out))
                return True
            _dlog("_HyprlandFloater.ensure_floating: %s 失败 rc=%s out=%r"
                  % (args[1:3], r.returncode, out))
        return False


# 普通窗口置顶：KWin 脚本按标题匹配窗口，设置 keepAbove。
# Wayland 下客户端无法请求置顶（xdg 协议没有该请求），KWin 脚本是
# 唯一途径；keepAbove 是窗口属性，设置后持续有效。
_KWIN_SET_KEEP_ABOVE_TEMPLATE = r"""
function setKeepAbove() {
    var list = workspace.windowList();
    for (var i = 0; i < list.length; i++) {
        var w = list[i];
        if (!w) continue;
        try {
            if (w.caption === "%(title)s") {
                w.keepAbove = %(on)s;
                return;
            }
        } catch (e) {
            // 忽略：不同 KWin 版本 Window API 略有差异
        }
    }
}
setKeepAbove();
"""


def _run_qdbus(args, timeout=3.0):
    """执行一条 qdbus 命令，返回 (成功?, stdout)。失败/超时静默降级，
    不打断桌面歌词的正常显示（位置持久化属锦上添花）。"""
    qdbus = shutil.which("qdbus") or shutil.which("qdbus6") or shutil.which("qdbus-qt6")
    if qdbus is None:
        return False, ""
    try:
        r = subprocess.run(
            [qdbus] + args,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return r.returncode == 0, r.stdout.strip()
    except Exception:
        return False, ""


_KWIN_QUERY_POSITION_SCRIPT_TEMPLATE = r"""
// 由 desktop.py 运行时生成：查询标题为 "%(title)s" 的窗口真实坐标，
// 经 callDBus 回调给 org.pymusic.DesktopLyric（Wayland 下客户端拿不到
// 自己窗口的全局坐标，只有合成器内的脚本能读 geometry.x/geometry.y）。
function findAndReport() {
    var list = (typeof workspace.windowList === "function")
        ? workspace.windowList()
        : (workspace.clientList ? workspace.clientList() : []);
    for (var i = 0; i < list.length; i++) {
        var w = list[i];
        if (!w) continue;
        try {
            if (w.caption === "%(title)s") {
                var g = w.geometry || w.frameGeometry;
                if (g) {
                    callDBus(
                        "org.pymusic.DesktopLyric",
                        "/PositionReceiver",
                        "org.pymusic.DesktopLyric",
                        "reportPosition",
                        Math.round(g.x),
                        Math.round(g.y)
                    );
                }
                return;
            }
        } catch (e) {
            // 忽略：不同 KWin/Qt 版本 Window/Client API 略有差异
        }
    }
}
findAndReport();
"""

_KWIN_SET_POSITION_SCRIPT_TEMPLATE = r"""
// 由 desktop.py 运行时生成：把标题为 "%(title)s" 的窗口移动到 (%(x)d, %(y)d)。
// Wayland 下客户端 setPosition 会被合成器忽略，只能借道脚本直接写
// frameGeometry（KWin 6 中该属性可写，赋值等价于 moveResize）。
// 保持窗口当前尺寸不变，只改位置。
function findAndMove() {
    var list = (typeof workspace.windowList === "function")
        ? workspace.windowList()
        : (workspace.clientList ? workspace.clientList() : []);
    for (var i = 0; i < list.length; i++) {
        var w = list[i];
        if (!w) continue;
        try {
            if (w.caption === "%(title)s") {
                var g = w.frameGeometry || w.geometry;
                if (g) {
                    w.frameGeometry = {
                        x: %(x)d,
                        y: %(y)d,
                        width: Math.round(g.width),
                        height: Math.round(g.height)
                    };
                }
                return;
            }
        } catch (e) {
            // 忽略：不同 KWin/Qt 版本 Window/Client API 略有差异
        }
    }
}
findAndMove();
"""

# 层窗口位置查询：客户端拿不到自己的全局坐标，由合成器内脚本读取真实
# 坐标，经 callDBus 回调 org.pymusic.DesktopLyric（_PositionReceiver）。
# 层窗口没有标题，不能按 caption 匹配；匹配条件 = Overlay 层(LAYER=9)
# + 尺寸相符（歌词窗 900x120 足够独特，且尺寸在层窗口里极少重复）。
# 不能用"已知位置容差"匹配——用户用 KWin 的 Meta+左键 强制拖动后，
# 客户端跟踪的位置是旧的（margins 未变），按旧位置匹配会失配。
# 本脚本只做只读查询，不做任何移动。
_KWIN_LAYER_QUERY_POSITION_TEMPLATE = r"""
function reportPos() {
    var list = workspace.windowList();
    for (var i = 0; i < list.length; i++) {
        var w = list[i];
        if (!w) continue;
        try {
            if (w.layer === 9) {
                var g = w.frameGeometry || w.geometry;
                if (g
                    && Math.abs(g.width - %(ow)d) <= 8
                    && Math.abs(g.height - %(oh)d) <= 8) {
                    callDBus(
                        "org.pymusic.DesktopLyric",
                        "/PositionReceiver",
                        "org.pymusic.DesktopLyric",
                        "reportPosition",
                        Math.round(g.x),
                        Math.round(g.y)
                    );
                    return;
                }
            }
        } catch (e) {
            // 忽略：不同 KWin/Qt 版本 Window API 略有差异
        }
    }
}
reportPos();
"""


class _KWinPinner:
    """通过 KWin D-Bus 脚本接口查询/设置标题匹配窗口的位置（Wayland 专属）。

    Wayland 协议不允许客户端读写自己窗口的全局坐标，只能借道运行在
    合成器内部的 KWin 脚本。置顶不在这里处理——请引导用户用窗口规则
    （标题 = 桌面歌词 → 在其它窗口之上 = 强制）。仅 KDE + Wayland 启用。

    用法：把脚本模板写临时文件 → qdbus loadScript → qdbus start →
    立即 unloadScript，不留常驻脚本。"""

    def __init__(self, title):
        self._title = title
        self._tmp_path = None

    @staticmethod
    def is_kde():
        if QGuiApplication.platformName() != "wayland":
            return False
        return "KDE" in os.environ.get("XDG_CURRENT_DESKTOP", "")

    def query_position(self, timeout=1.5):
        """注入脚本查询窗口真实坐标，经 callDBus 回调 reportPosition。

        Wayland 下 QWindow.x()/y() 在 startSystemMove 拖动后不会更新，
        真实坐标只有合成器内部知道。脚本查到的坐标异步回调到
        _PositionReceiver（几十毫秒），本函数只确认脚本加载/启动成功。"""
        if not self.is_kde():
            _dlog("_KWinPinner.query_position: is_kde()=False，跳过")
            return False
        if not _HAVE_QTDBUS:
            _dlog("_KWinPinner.query_position: PySide6.QtDBus 不可用，跳过"
                  "（可能是 PySide6 打包时没带 QtDBus 模块）")
            return False
        script = _KWIN_QUERY_POSITION_SCRIPT_TEMPLATE % {
            "title": self._title.replace('"', '\\"'),
        }
        try:
            fd, path = tempfile.mkstemp(prefix="pymusic-desktoplyric-qpos-", suffix=".js")
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(script)
        except Exception as e:
            _dlog("_KWinPinner.query_position: 写临时脚本文件异常: %r" % (e,))
            return False
        self._tmp_path = path
        script_name = "pymusic-desktoplyric-qpos"

        ok, out = _run_qdbus([
            "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting.loadScript",
            path, script_name,
        ])
        if not ok:
            _dlog("_KWinPinner.query_position: loadScript 失败")
            self._cleanup_tmp()
            return False

        ok2, _ = _run_qdbus([
            "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting.start",
        ])
        _dlog("_KWinPinner.query_position: loadScript 成功(id=%s)，start() 返回 %s，"
              "等待 KWin 脚本通过 callDBus 回调 org.pymusic.DesktopLyric"
              % (out, ok2))

        _run_qdbus([
            "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting.unloadScript",
            script_name,
        ])
        self._cleanup_tmp()
        return ok2

    def set_position(self, x, y):
        """通过 KWin 脚本把标题匹配窗口移动到 (x, y)。

        Wayland 下 QWindow.setPosition() 只更新本地缓存、实际落点由合成器
        决定，恢复位置只能靠脚本直接写 frameGeometry。脚本加载/启动成功
        即认为链路走通；窗口还没被 KWin 注册时脚本静默跳过，调用方应
        延迟重试（见 _schedule_restore）。
        """
        if not self.is_kde():
            _dlog("_KWinPinner.set_position: is_kde()=False，跳过")
            return False
        script = _KWIN_SET_POSITION_SCRIPT_TEMPLATE % {
            "title": self._title.replace('"', '\\"'),
            "x": int(x),
            "y": int(y),
        }
        try:
            fd, path = tempfile.mkstemp(prefix="pymusic-desktoplyric-move-", suffix=".js")
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(script)
        except Exception as e:
            _dlog("_KWinPinner.set_position: 写临时脚本文件异常: %r" % (e,))
            return False
        self._tmp_path = path
        # 唯一脚本名：移动脚本可能短时间内连续触发（hide→show），
        # 固定名会导致同名 loadScript 返回 -1 被当成失败。
        script_name = "pymusic-desktoplyric-move-%d" % int(time.monotonic() * 1000)

        ok, out = _run_qdbus([
            "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting.loadScript",
            path, script_name,
        ])
        if not ok:
            _dlog("_KWinPinner.set_position: loadScript 失败")
            self._cleanup_tmp()
            return False

        ok2, _ = _run_qdbus([
            "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting.start",
        ])
        _dlog("_KWinPinner.set_position: loadScript 成功(id=%s)，start() 返回 %s，"
              "已尝试把窗口移动到 (%d, %d)" % (out, ok2, int(x), int(y)))

        _run_qdbus([
            "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting.unloadScript",
            script_name,
        ])
        self._cleanup_tmp()
        return ok2

    # ---------- 层窗口（layer-shell）专用：拖动移动 / 位置查询 ----------
    # 层窗口没有标题，KWin 脚本无法按 caption 匹配；拖动时指针位于窗口上，
    # 用 workspace.windowAt(指针位置) 找最上层 Overlay 层窗口（LAYER=9）。
    # frameGeometry 写入对层窗口同样生效（moveResizeInternal 同步应用），
    # 无 wl_surface commit 依赖，不会像改 margins 那样延迟/回拉。

    def _run_script(self, script, prefix):
        """把脚本写临时文件 -> loadScript -> start -> unloadScript。

        返回 (成功?, 输出)。脚本名唯一，避免同名前一次还没卸载时
        loadScript 返回 -1 被当成失败。"""
        try:
            fd, path = tempfile.mkstemp(prefix=prefix, suffix=".js")
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(script)
        except Exception as e:
            _dlog("_KWinPinner._run_script: 写临时脚本文件异常: %r" % (e,))
            return False, ""
        script_name = "%s-%d" % (prefix, int(time.monotonic() * 1000))
        ok, out = _run_qdbus([
            "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting.loadScript",
            path, script_name,
        ])
        if ok:
            ok2, _ = _run_qdbus([
                "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting.start",
            ])
        else:
            ok2 = False
            _dlog("_KWinPinner._run_script: loadScript 失败")
        _run_qdbus([
            "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting.unloadScript",
            script_name,
        ])
        try:
            os.unlink(path)
        except OSError:
            pass
        return ok and ok2, out

    def layer_query_position(self, ow, oh):
        """查询"尺寸 (ow, oh)"的 Overlay 层窗口真实坐标（异步）。

        结果经 callDBus 回调 org.pymusic.DesktopLyric /PositionReceiver
        reportPosition。只读查询，不做移动。"""
        if not self.is_kde():
            _dlog("_KWinPinner.layer_query_position: is_kde()=False，跳过")
            return False
        script = _KWIN_LAYER_QUERY_POSITION_TEMPLATE % {
            "ow": int(ow),
            "oh": int(oh),
        }
        ok, _ = self._run_script(script, "pymusic-qpos")
        return ok

    def set_keep_above(self, on):
        """通过 KWin 脚本设置/取消普通窗口置顶（keepAbove）。

        Wayland 下客户端无法请求置顶，只有合成器内脚本能改窗口属性。
        keepAbove 对层窗口无效（Overlay 层天然置顶，无需设置）。"""
        if not self.is_kde():
            _dlog("_KWinPinner.set_keep_above: is_kde()=False，跳过")
            return False
        script = _KWIN_SET_KEEP_ABOVE_TEMPLATE % {
            "title": self._title.replace('"', '\\"'),
            "on": "true" if on else "false",
        }
        ok, _ = self._run_script(script, "pymusic-keepabove")
        return ok

    def _cleanup_tmp(self):
        if self._tmp_path:
            try:
                os.unlink(self._tmp_path)
            except OSError:
                pass
            self._tmp_path = None


@ClassInfo({"D-Bus Interface": "org.pymusic.DesktopLyric"})
class _PositionReceiver(QObject):
    """会话 D-Bus 服务 org.pymusic.DesktopLyric 的接收端。

    接收 KWin 脚本经 callDBus 回调的窗口真实坐标（query_position 链路）。

    ClassInfo 是链路能走通的关键：registerObject 默认把槽导出到"类名
    命名的 D-Bus 接口"下（_PositionReceiver），与脚本侧 callDBus 指定的
    org.pymusic.DesktopLyric 对不上时会被 Qt 以 UnknownInterface 拒掉，
    且双方都无报错。必须用 ClassInfo 显式指定接口名。
    """

    def __init__(self, on_position, parent=None):
        super().__init__(parent)
        self._on_position = on_position
        self._registered = False
        if not _HAVE_QTDBUS:
            _dlog("_PositionReceiver: PySide6.QtDBus 不可用，D-Bus 服务不会注册，"
                  "拖动后的真实坐标查询这条路完全用不了")
            return
        bus = QDBusConnection.sessionBus()
        if not bus.isConnected():
            _dlog("_PositionReceiver: 无法连接会话 D-Bus，服务不会注册")
            return
        ok_obj = bus.registerObject("/PositionReceiver", self,
                                     QDBusConnection.ExportAllSlots)
        ok_svc = bus.registerService("org.pymusic.DesktopLyric")
        self._registered = bool(ok_obj and ok_svc)
        _dlog("_PositionReceiver: 注册 D-Bus 服务 org.pymusic.DesktopLyric"
              "/PositionReceiver -> registerObject=%s registerService=%s "
              "(最终 registered=%s)" % (ok_obj, ok_svc, self._registered))

    @Slot(int, int)
    def reportPosition(self, x, y):
        """KWin 脚本查到窗口真实坐标后，通过 callDBus 调用这里。"""
        _dlog("_PositionReceiver.reportPosition 收到 KWin 回调坐标 (%d, %d)"
              % (x, y))
        if self._on_position is not None:
            try:
                self._on_position(int(x), int(y))
            except Exception as e:
                _dlog("_PositionReceiver.reportPosition 回调处理异常: %r" % (e,))


class _LyricBridge(QObject):
    """把 AudioPlayer 的歌词/状态接口翻译成 QML 友好的属性/信号/槽。

    QML 通过 setContextProperty("player", bridge) 拿到本对象，使用：
      - count        (property, 歌词行数)
      - curIndex     (property, 当前播放行索引)
      - stateText    (property, "playing"/"paused"/"stopped")
      - lyricText(i) (slot,    返回第 i 行文本)
      - indexChanged (signal,  当前行变化)
      - stateChanged (signal,  播放状态变化)
    """

    indexChanged = Signal(int)
    stateChanged = Signal()
    lyricsChanged = Signal()
    volumeChanged = Signal()
    lockedChanged = Signal()

    def __init__(self, player, parent=None):
        super().__init__(parent)
        self._player = player
        self._lyrics = []   # 本地缓存 [(t, text), ...]，避免频繁跨信号取值
        self._groups = []   # 分组缓存 [[(t,text),...], ...]：同时间戳相邻行并为一组
        self._desktop_font = ""   # 桌面歌词字体族（空=默认）
        self._desktop_color = ""  # 桌面歌词当前行颜色（空=默认白）
        self._drag_mode = "system"  # "system"=普通窗口拖动 / "none"=层窗口不可拖动
        self._locked = False       # "锁定歌词"状态（锁定时不响应滚轮调音量）

        # 滚轮音量：40ms 防抖合并连续滚动，避免快速滚动丢步与频繁写 pactl
        self._pending_volume = None
        self._wheel_timer = QTimer(self)
        self._wheel_timer.setSingleShot(True)
        self._wheel_timer.setInterval(40)
        self._wheel_timer.timeout.connect(self._flush_volume)

        if player is not None:
            player.lyricsChanged.connect(self._on_lyrics_changed)
            # 与主播放器使用同一"带提前量"索引，保证两句永远同步
            player.lyricIndexChanged.connect(self._on_index_changed)
            player.stateChanged.connect(self._on_state_changed)
            player.volumeChanged.connect(self._on_volume_changed)
            self._on_lyrics_changed()

    # ---------- 与 AudioPlayer 的同步 ----------

    def _refresh_cache(self):
        """从 AudioPlayer 拉取歌词列表缓存到本地（仅当列表变化时进行）。"""
        p = self._player
        try:
            n = p.lyricCount
        except Exception:
            n = 0
        if n != len(self._lyrics):
            self._lyrics = [(p.lyricTime(i), p.lyricText(i)) for i in range(n)]
        self._rebuild_groups()

    def _rebuild_groups(self):
        """把相邻、时间戳相同的歌词行并成一组（双语"原文/译文"同时间戳）。

        播放器的 parse_lrc_text 会把 "[00:12]原文/译文" 拆成两条时间戳
        相同的记录并保证相邻。这里复用同一约定：连续、且 .0 秒相等到
        毫秒级容差的行视为一组，桌面歌词把整组作为一个块渲染。
        """
        self._groups = []
        for t, text in self._lyrics:
            if self._groups and abs(self._groups[-1][-1][0] - t) < 1e-6:
                self._groups[-1].append((t, text))
            else:
                self._groups.append([(t, text)])

    def _on_lyrics_changed(self):
        self._refresh_cache()
        self.lyricsChanged.emit()

    def _on_index_changed(self, idx):
        self.indexChanged.emit(idx)

    def _on_state_changed(self, state):
        self.stateChanged.emit()

    def _on_volume_changed(self, *args):
        self.volumeChanged.emit()

    # ---------- 滚轮调节音量（非锁定状态下由 QML WheelHandler 调用） ----------

    @Property(int, notify=volumeChanged)
    def volume(self):
        """当前音量（0-100），供 QML 显示/读取。"""
        p = self._player
        if p is None:
            return 0
        try:
            return int(p.volume)
        except Exception:
            return 0

    @Slot(int)
    def adjustVolume(self, steps):
        """按滚轮步数调节音量：steps>0 变大，<0 变小（每步 5）。

        在防抖窗口的 pending 值上累加，快速滚动不丢步；40ms 后才真正写入
        player.volume，避免每个滚轮事件都触发一次持久化/pactl。
        """
        if not steps:
            return
        p = self._player
        if p is None:
            return
        try:
            base = self._pending_volume if self._pending_volume is not None \
                else int(p.volume)
        except Exception:
            base = 0
        new_volume = max(0, min(100, int(round(base + steps * 5))))
        if new_volume != base:
            self._pending_volume = new_volume
            self._wheel_timer.start()

    def _flush_volume(self):
        value = self._pending_volume
        self._pending_volume = None
        if value is not None and self._player is not None:
            try:
                self._player.volume = value
            except Exception:
                pass

    # ---------- 锁定状态（锁定时 QML 不处理滚轮调音量） ----------

    @Property(bool, notify=lockedChanged)
    def locked(self):
        return self._locked

    def setLocked(self, locked):
        locked = bool(locked)
        if locked != self._locked:
            self._locked = locked
            self.lockedChanged.emit()

    # ---------- QML 暴露的属性 ----------

    @Property(int, notify=lyricsChanged)
    def count(self):
        return len(self._lyrics)

    # 分组数量（每个双语"原文/译文"块算一组）
    @Property(int, notify=lyricsChanged)
    def groupCount(self):
        return len(self._groups)

    @Property(int, notify=indexChanged)
    def curIndex(self):
        p = self._player
        if p is None:
            return -1
        try:
            return p.currentLyricIndex
        except Exception:
            return -1

    # 当前播放行所在的组号（用于整块高亮/居中）
    @Property(int, notify=indexChanged)
    def curGroup(self):
        i = self.curIndex
        if i < 0:
            return -1
        # 统计已走过的行数，返回"组的下标"（从 0 计），而不是累计行偏移。
        # 早前实现误把累计行数当组号返回，当目标组之前存在被合并的组
        # （如 `[00:00]作词…/编曲…` 拆出的同时间戳多行、或双语同时间戳）时，
        # 会把组号整体 push 后，导致桌面歌词比主界面"快一句"。
        line = 0
        for gi, grp in enumerate(self._groups):
            if i < line + len(grp):
                return gi
            line += len(grp)
        return len(self._groups) - 1

    @Property(str, notify=stateChanged)
    def stateText(self):
        p = self._player
        if p is None:
            return "stopped"
        try:
            return p.state
        except Exception:
            return "stopped"

    # ---------- 桌面歌词样式（字体/当前行颜色，由主面板设置） ----------

    styleChanged = Signal()

    @Property(str, notify=styleChanged)
    def desktopFont(self):
        """当前行歌词字体族；空字符串表示使用默认字体。"""
        return self._desktop_font

    @Property(str, notify=styleChanged)
    def desktopColor(self):
        """当前行歌词颜色（十六进制/颜色名）；空字符串表示默认白。"""
        return self._desktop_color

    @Slot(str, str)
    def setStyle(self, font, color):
        """设置桌面歌词样式（font 可为空串表示默认，color 可为空串表示默认）。"""
        changed = False
        font = font or ""
        color = color or ""
        if font != self._desktop_font:
            self._desktop_font = font
            changed = True
        if color != self._desktop_color:
            self._desktop_color = color
            changed = True
        if changed:
            self.styleChanged.emit()

    @Slot(int, result=str)
    def lyricText(self, index):
        if 0 <= index < len(self._lyrics):
            return self._lyrics[index][1]
        return ""

    @Slot(int, result=int)
    def groupSize(self, g):
        """第 g 组的行数（一般 1 或 2）。"""
        if 0 <= g < len(self._groups):
            return len(self._groups[g])
        return 0

    @Slot(int, int, result=str)
    def groupText(self, g, sub):
        """第 g 组第 sub 行的文本。"""
        if 0 <= g < len(self._groups) and 0 <= sub < len(self._groups[g]):
            return self._groups[g][sub][1]
        return ""

    @Slot(int, result=str)
    def groupTextOnly(self, g):
        """整组的文本（多行用换行拼接），供无分组渲染的 Text 使用。"""
        if 0 <= g < len(self._groups):
            return "\n".join(t for _, t in self._groups[g])
        return ""

    # ---------- 右键菜单（由 desktop.qml 的 MouseArea 触发） ----------
    # 实际弹出逻辑委托给 DesktopLyrics（它持有 QQuickView，方便设置
    # WindowStaysOnTopHint / 隐藏窗口等），这里只是把 QML 的信号转发出去。
    contextMenuRequested = Signal(int, int)

    @Slot(int, int)
    def showContextMenu(self, x, y):
        self.contextMenuRequested.emit(x, y)

    # 拖动结束通知（普通窗口模式由 MouseArea.onReleased 触发，层模式不用）
    dragFinishedSig = Signal()

    @Slot()
    def dragFinished(self):
        self.dragFinishedSig.emit()

    # 拖动方式："system"=普通窗口 startSystemMove（合成器原生移动）；
    # "none"=层窗口不可拖动（layer surface 无法被 KWin 移动）。
    @Property(str, constant=True)
    def dragMode(self):
        return self._drag_mode


class DesktopLyrics:
    """桌面歌词窗口控制器：封装一个透明置顶的 QQuickView 并绑定 AudioPlayer。

    交互模型（详见模块 docstring）：
      - 默认普通窗口：左键拖动（startSystemMove）或 KWin 的 Meta+左键
        强制拖动均可移动窗口；置顶由 KWin 脚本 keepAbove 保证；
      - "锁定歌词"开启：整窗点击穿透；
      - 取消锁定：右键弹出自绘菜单（隐藏），滚轮调节音量（每档 5）。
      - 层模式（PYMUSIC_DESKTOP_LYRIC_LAYER_SHELL=1）：窗口不可拖动
        （layer surface 无法被 KWin 移动，协议硬限制），仅能 Meta+左键
        尝试（无效），位置在窗口关闭时由 KWin 脚本查询保存。
    """

    def __init__(self, player=None, parent=None):
        self._stay_on_top = True  # 右键菜单"置顶显示"状态
        self._locked = False      # "锁定歌词"；锁定则点击穿透
        self._save_pos_cb = None  # 由 _DesktopLyricsManager 注入的"保存位置"回调
        self._desired_pos = None  # 上次保存的窗口位置 (x,y)；None 用默认摆位
        self._suppress_pos_tracking = True  # 程序自摆位期间忽略 xChanged/yChanged
        self._view = None         # QQuickWindow（QQuickView 或其子类）
        self._engine = None       # 层模式时持有 QQmlApplicationEngine

        # KWin 脚本通道 + D-Bus 位置接收器：普通模式置顶/位置恢复、
        # 拖动结束与关闭时查询真实坐标保存都走这条链路
        self._kwin_pinner = _KWinPinner(WINDOW_TITLE_HINT)
        self._position_receiver = _PositionReceiver(
            self._on_kwin_reported_position, None)

        # Hyprland：平铺合成器会平铺普通窗口，首次展开后借 hyprctl 切为浮动
        self._hypr_float = _HyprlandFloater(WINDOW_TITLE_HINT, WINDOW_CLASS_HINT)
        self._hypr_float_supported = self._hypr_float.is_hyprland()
        self._hypr_float_started = False   # 是否已启动过浮动重试线程
        self._hypr_floated = False         # 是否已成功切为浮动

        # 客户端跟踪的窗口位置（合成器真相的副本）：层模式关闭时脚本
        # 匹配与兜底保存用。普通模式由 view 坐标/KWin 回调维护。
        self._last_known_pos = None
        # _last_known_pos 是否经过 KWin 查询验证：只有验证过的才是合成器
        # 真值，可以写回配置。set_position（恢复目标）设置的是"期望值"，
        # 配置本身可能是脏数据（如屏幕局部偏移），未经验证就写回会把
        # 脏值循环下去（自复位偏差的根源之一）。
        self._pos_verified = False

        # 周期位置同步：每 N 秒借道 KWin 脚本查询窗口真实位置并落盘，
        # 保证异常退出（未走 close()）也不丢位置。默认 3 秒，可用
        # PYMUSIC_DESKTOP_LYRIC_SYNC_MS 覆盖。
        self._pos_sync_ms = int(os.environ.get("PYMUSIC_DESKTOP_LYRIC_SYNC_MS", "3000"))
        self._pos_sync_timer = QTimer()
        self._pos_sync_timer.setSingleShot(False)
        self._pos_sync_timer.setInterval(self._pos_sync_ms)
        self._pos_sync_timer.timeout.connect(self._periodic_position_sync)
        self._sync_in_flight = False  # 上一轮查询未回调完成前不叠加
        self._pos_sync_timer.start()

        # 层模式（KDE Wayland layer-shell，显式开启）：窗口是合成器
        # layer surface，天然置顶、不可移动。默认普通窗口（可拖动）。
        self._layer_mode = _use_layer_shell_mode()
        if self._layer_mode:
            self._init_layer_window(player)
        else:
            self._init_plain_window(player)

        # 初始透明度按当前锁定状态应用（默认未锁定可交互）
        self._apply_lock()

        _dlog("__init__ 完成，layer_mode=%s，窗口坐标=(%d,%d)；"
              "_suppress_pos_tracking 仍为 True，manager.ensure() 稍后会在"
              "真正应用完保存的位置之后才关闭它"
              % (self._layer_mode, self._view.x(), self._view.y()))

    # ---------- 窗口初始化 ----------

    def _init_plain_window(self, player):
        """普通窗口模式：QQuickView + desktop.qml（Item 根）。

        无边框 + 置顶 + 不抢焦点 + 工具窗（不占任务栏）。
        WindowTransparentForInput 随"锁定歌词"开关决定；置顶 flag 仅 X11
        生效，Wayland 下由合成器窗口规则或层模式负责。
        """
        # 拖动位置去抖保存：拖动中 x/y 高频触发，停手 400ms 后才写一次配置
        self._pos_timer = QTimer()
        self._pos_timer.setSingleShot(True)
        self._pos_timer.setInterval(400)
        self._pos_timer.timeout.connect(self._save_position)
        # show 后分几次延迟重试 KWin 脚本恢复位置（窗口需先被 KWin 注册）
        self._restore_pending = False
        self._restore_remaining = 0

        # QQuickView 是独立顶层窗口，不进入主 engine 的 rootObjects
        self._view = QQuickView()
        self._view.setResizeMode(QQuickView.SizeRootObjectToView)
        self._view.setFlags(
            Qt.Window
            | Qt.FramelessWindowHint
            | Qt.WindowStaysOnTopHint
            | Qt.WindowDoesNotAcceptFocus
            | Qt.WindowTransparentForInput
            | Qt.Tool
        )
        self._view.setColor("transparent")
        self._view.setTitle(WINDOW_TITLE_HINT)
        self._view.setObjectName(WINDOW_CLASS_HINT)
        self._view.xChanged.connect(self._on_position_changed)
        self._view.yChanged.connect(self._on_position_changed)

        self._init_bridge(player)
        self._view.setSource(QUrl.fromLocalFile(str(_QML_PATH)))

        # 尺寸跟随 QML (SizeRootObjectToView)
        if self._view.status() == QQuickView.Error:
            print("[desktop] 加载 desktop.qml 失败:",
                  [str(e) for e in self._view.errors()])

        # 默认摆位：主屏幕水平居中、贴近底部。
        # _suppress_pos_tracking 让程序自己的 setPosition 不被当成"用户
        # 拖动"记录/保存，否则去抖定时器可能把默认坐标误写回配置。
        self._place_default()

    def _init_layer_window(self, player):
        """层模式：QQmlApplicationEngine + desktop_layer.qml（Window 根）。

        Window 根元素 + org.kde.layershell 附加属性（LayerOverlay /
        AnchorBottom|Left）由合成器置顶与定位：位置 = 锚定边 + margins。
        拖动期间由 KWin 脚本直接写 frameGeometry 移动窗口（drag_mode=
        "kwin"），不动 margins——避免 commit 延迟与回拉；拖动结束/关闭时
        用脚本查询真实坐标保存。
        QML 加载失败（模块缺失等）时回退普通窗口。
        """
        self._engine = QQmlApplicationEngine()
        self._init_bridge(player)
        _load_errors = []
        self._engine.warnings.connect(
            lambda errs: _load_errors.extend(str(e.toString()) for e in errs))
        self._engine.load(QUrl.fromLocalFile(str(_QML_LAYER_PATH)))
        if not self._engine.rootObjects():
            _dlog("_init_layer_window: 加载 desktop_layer.qml 失败（%s），"
                  "回退普通窗口模式" % (_load_errors or "无错误信息",))
            self._engine = None
            self._layer_mode = False
            self._init_plain_window(player)
            return
        self._view = self._engine.rootObjects()[0]
        # 层窗口已由 layer-shell 保证无边框/不抢焦点/不占任务栏，
        # flag 只需要最小集合（WindowTransparentForInput 由锁定开关控制）
        self._view.setFlags(Qt.Window | Qt.FramelessWindowHint)
        self._view.setColor("transparent")
        self._view.setTitle(WINDOW_TITLE_HINT)
        self._view.setObjectName(WINDOW_CLASS_HINT)
        # 默认摆位（底部居中）换算成 margins；_desired_pos 保持 None，
        # 与普通模式语义一致（manager.ensure() 会在有存档时 set_position）
        self._place_default()
        # 初始化位置跟踪：以边距换算的位置作为"已知位置"
        self._sync_last_known_pos()
        _dlog("_init_layer_window: 层模式初始化完成，flags=%s，默认边距 "
              "marginLeft=%d marginBottom=%d，跟踪位置=%s"
              % (self._view.flags(),
                 self._view.property("marginLeft"), self._view.property("marginBottom"),
                 self._last_known_pos))

    def _init_bridge(self, player):
        """桥接对象：QML 侧的 player 上下文属性 + 菜单/拖动信号转发。"""
        self._bridge = _LyricBridge(player, self._view)
        self._bridge._drag_mode = "none" if self._layer_mode else "system"
        self._bridge.contextMenuRequested.connect(self._on_context_menu_requested)
        self._bridge.dragFinishedSig.connect(self._on_drag_finished)
        # 普通模式挂在 QQuickView 的 rootContext，层模式挂在 engine 的
        # rootContext；两者必须在 load/setSource 之前注入
        if self._engine is not None:
            self._engine.rootContext().setContextProperty("player", self._bridge)
        else:
            self._view.rootContext().setContextProperty("player", self._bridge)

    # ---------- 拖动结束（普通窗口模式）-> 借道 KWin 脚本查询真实坐标 ----------

    def _on_drag_finished(self):
        """左键拖动结束（QML MouseArea.onReleased，仅普通窗口模式）。

        Wayland 下 self._view.x()/y() 不会随 startSystemMove 拖动更新，
        直接 _save_position() 存的是旧坐标，必须借道 KWin 脚本查询真实
        坐标（异步回调 _on_kwin_reported_position）。X11 下读数准确，
        直接兜底保存。"""
        if self._layer_mode:
            return
        _dlog("_on_drag_finished: 收到拖动结束通知，当前 self._view.x/y()="
              "(%d,%d)（Wayland 下这个读数在拖动后大概率是不准的，仅供"
              "参考，真实坐标要等下面 KWin 查询的回调）"
              % (self._view.x(), self._view.y()))
        if not self._kwin_pinner.is_kde():
            self._save_position()
            return
        import threading
        t = threading.Thread(
            target=self._kwin_pinner.query_position,
            daemon=True,
        )
        t.start()

    # ---------- 右键菜单 ----------

    def _on_context_menu_requested(self, x, y):
        """在全局坐标 (x, y) 弹出右键菜单。x/y 来自 QML 的 mapToGlobal，
        单位是设备无关像素（与 QCursor/QPoint 一致）。"""
        menu = QMenu()
        menu.setWindowFlags(menu.windowFlags() | Qt.FramelessWindowHint)

        if not self._layer_mode:
            # 层模式天然置顶（LayerOverlay），置顶开关没有意义，不显示
            top_action = menu.addAction("置顶显示")
            top_action.setCheckable(True)
            top_action.setChecked(self._stay_on_top)
            top_action.toggled.connect(self._set_stay_on_top)
            menu.addSeparator()
        hide_action = menu.addAction("隐藏桌面歌词")
        hide_action.triggered.connect(self.hide)

        # 用 exec 而不是 show，保证是模态弹出、点外部自动关闭
        menu.exec(QPoint(int(x), int(y)))

    # ---------- KWin 脚本查询真实坐标（周期同步/关闭时保存位置用） ----------

    def _periodic_position_sync(self):
        """每 3 秒把窗口位置同步到配置（定时器回调）。

        目的：歌词位置只在 close()（干净退出）时保存，而大部分时候程序
        是被直接关掉/杀掉的，配置里一直是旧位置。这里定时借道 KWin 脚本
        查询合成器侧真实坐标，经 reportPosition 回调落盘——异常退出也
        不丢位置，下次启动自复位准确。

        窗口未显示时跳过；X11 下 view 坐标准确，直接存，不跑脚本。
        """
        if self._sync_in_flight:
            return
        if self._view is None or not self._view.isVisible():
            return
        if not self._kwin_pinner.is_kde():
            # X11：view 坐标准确，直接落盘
            self._save_position()
            return
        self._sync_in_flight = True
        import threading
        if self._layer_mode:
            w, h = self._view.width(), self._view.height()
            target = self._kwin_pinner.layer_query_position
            args = (w, h)
        else:
            target = self._kwin_pinner.query_position
            args = ()
        # 线程结束（脚本执行完）即释放闸门；回调落盘是幂等的，
        # 与下一轮查询重叠最多一次，无副作用
        t = threading.Thread(
            target=self._run_sync_query,
            args=(target, args),
            daemon=True,
        )
        t.start()
        _dlog("_periodic_position_sync: 发起 KWin 位置查询")

    def _run_sync_query(self, target, args):
        """后台执行 KWin 查询脚本；无论成败都释放周期同步闸门。"""
        try:
            target(*args)
        except Exception as e:
            _dlog("_run_sync_query 异常: %r" % (e,))
        finally:
            self._sync_in_flight = False

    def _query_layer_position_async(self):
        """后台线程调 layer_query_position：按尺寸匹配层窗口，
        查询其真实坐标，经 reportPosition 异步回调落盘。"""
        import threading
        w, h = self._view.width(), self._view.height()
        t = threading.Thread(
            target=self._kwin_pinner.layer_query_position,
            args=(w, h),
            daemon=True,
        )
        t.start()

    def _on_kwin_reported_position(self, x, y):
        """收到 KWin 回调的真实坐标（Wayland 下唯一权威来源），
        更新 _desired_pos / _last_known_pos 并落盘。"""
        _dlog("_on_kwin_reported_position: 收到 KWin 回调的真实坐标 "
              "(%d, %d)，与 self._view 读数 (%d, %d) 对比"
              "%s，以 KWin 回调值为准写入配置"
              % (x, y, self._view.x(), self._view.y(),
                 "一致" if (x, y) == (self._view.x(), self._view.y())
                 else "不一致（符合预期，Wayland 下 QWindow 读数本来就不可靠）"))
        # 停掉残留去抖定时器：避免稍后用不可靠的 self._view 读数覆盖权威坐标
        if not self._layer_mode and self._pos_timer.isActive():
            self._pos_timer.stop()
        self._desired_pos = (int(x), int(y))
        # 以合成器真相更新跟踪位置（两种模式一致），并标记已验证
        self._last_known_pos = (int(x), int(y))
        self._pos_verified = True
        if self._save_pos_cb is not None:
            self._save_pos_cb("desktopLyricPosX", str(int(x)))
            self._save_pos_cb("desktopLyricPosY", str(int(y)))
            _dlog("_on_kwin_reported_position: 已写入配置 "
                  "desktopLyricPosX=%d desktopLyricPosY=%d" % (x, y))
        else:
            _dlog("_on_kwin_reported_position: _save_pos_cb 为 None，"
                  "坐标 (%d, %d) 没有写进配置！" % (x, y))

    def _set_stay_on_top(self, on):
        """右键菜单"置顶显示"：设 Qt.WindowStaysOnTopHint 并 raise 一次。
        X11 生效；Wayland 忽略该 flag，置顶请走窗口规则。
        层模式下不做任何事（LayerOverlay 天然置顶）。"""
        if self._layer_mode:
            _dlog("_set_stay_on_top(%s): 层模式下置顶由合成器保证，忽略"
                  % (on,))
            return
        self._stay_on_top = bool(on)
        self._view.setFlag(Qt.WindowStaysOnTopHint, self._stay_on_top)
        if self._stay_on_top:
            # 部分 WM（尤其 X11 下少数窗口管理器）需要重新 raise 才真正置顶
            self._view.raise_()

    def _place_default(self):
        """主屏幕底部居中的默认摆位。层模式下换算成 margins 交给合成器。"""
        if self._layer_mode:
            try:
                screen = self._current_screen()
                geo = self._screen_geometry(screen)
                w, h = self._view.width(), self._view.height()
                ml, mb = self._margins_from_pos(geo.x() + (geo.width() - w) // 2,
                                                geo.y() + geo.height() - h - 48,
                                                screen=screen)
                _dlog("_place_default: 层模式默认边距 marginLeft=%d "
                      "marginBottom=%d（窗口 %dx%d，屏幕 %s）"
                      % (ml, mb, w, h, geo))
                self._set_layer_margins(ml, mb, screen=screen)
            except Exception as e:
                _dlog("_place_default 层模式异常: %r" % (e,))
            return
        try:
            screen = QGuiApplication.primaryScreen()
            if screen is None:
                return
            avail = screen.availableGeometry()
            w = self._view.width()
            h = self._view.height()
            x = avail.x() + (avail.width() - w) // 2
            y = avail.y() + avail.height() - h - 48  # 距底部 48px
            _dlog("_place_default: 应用默认摆位 (%d, %d)（窗口尺寸 %dx%d，"
                  "屏幕可用区域 %s）" % (x, y, w, h, avail))
            self._view.setPosition(x, y)
        except Exception as e:
            _dlog("_place_default 异常: %r" % (e,))

    # ---------- 层模式边距 <-> 屏幕坐标换算 ----------
    #
    # layer-shell 的 margins 是"相对某一个具体输出（screen）"的锚定边距，
    # 不是相对整个虚拟桌面。之前的实现永远用 QGuiApplication.primaryScreen()
    # 换算，等价于把窗口焊死在主屏——margins 只在 [0, 主屏宽/高] 内取值
    # 有意义，副屏坐标换算出来的 margins 要么被钳成负数要么被
    # _set_layer_margins 直接夹回主屏范围，窗口当然拖不过去。
    # 这里改成：换算前先按"窗口当前落在哪个 QScreen 上"取该屏的
    # availableGeometry，边距就是"相对那块屏"的边距；QWindow 本身的
    # screen() 由 Qt/合成器根据窗口几何自动跟随（层窗口在 KDE Wayland
    # 下拖过输出边界，KWin 会把它重新分配到新的输出），所以不需要手动
    # setScreen，只需要换算时用对屏幕。

    def _current_screen(self):
        """窗口当前所在的 QScreen；取不到则退回主屏。"""
        screen = None
        try:
            screen = self._view.screen()
        except Exception:
            screen = None
        if screen is None:
            screen = QGuiApplication.primaryScreen()
        return screen

    def _screen_at(self, global_x, global_y):
        """全局坐标 (x, y) 所在的 QScreen；取不到则退回当前屏幕。"""
        try:
            from PySide6.QtCore import QPoint as _QPoint
            screen = QGuiApplication.screenAt(_QPoint(int(global_x), int(global_y)))
            if screen is not None:
                return screen
        except Exception:
            pass
        return self._current_screen()

    def _screen_geometry(self, screen=None):
        """指定屏幕（默认取窗口当前所在屏）的可用区域（逻辑坐标）。"""
        if screen is None:
            screen = self._current_screen()
        if screen is None:
            return None
        return screen.availableGeometry()

    def _set_layer_margins(self, ml, mb, screen=None):
        """应用层窗口边距（锚定 Bottom|Left，窗口位置由边距唯一确定）。

        限制在目标屏幕范围内：把窗口完全拖出该屏幕的边距没有意义，KWin
        也会钳制。通过 QML 声明的 marginLeft/marginBottom 属性写回，
        绑定链同步到 LayerShell.Window.margins.*。

        关键：wlr-layer-shell 的 set_margin 要等下一次 wl_surface commit
        合成器才应用，而静态画面 Qt 不会重绘/提交——实测没有强制提交时
        边距更新会一直积压，直到某次切歌词重绘才一次性跳转（约 1~2 秒
        延迟）。每次写边距后调 QWindow.requestUpdate() 强制排一帧渲染，
        让合成器 ~100ms 内就应用，拖动才能实时跟手。
        """
        geo = self._screen_geometry(screen)
        if geo is not None:
            w, h = self._view.width(), self._view.height()
            ml = max(0, min(ml, geo.width() - w))
            mb = max(0, min(mb, geo.height() - h))
        self._view.setProperty("marginLeft", int(ml))
        self._view.setProperty("marginBottom", int(mb))
        self._view.requestUpdate()

    def _layer_margins(self):
        """当前层窗口边距（以最近一次设置为准）。"""
        return (int(self._view.property("marginLeft")),
                int(self._view.property("marginBottom")))

    def _margins_from_pos(self, x, y, screen=None):
        """窗口左上角屏幕坐标 (x, y) -> 层模式边距 (marginLeft, marginBottom)。

        锚定 Bottom|Left：窗口左边缘距屏幕左缘 = marginLeft；
        窗口底边缘距屏幕底缘 = marginBottom。默认按 (x, y) 所在的屏幕
        换算（拖到副屏时不能仍然按主屏算，否则边距会越界被钳掉）。
        """
        if screen is None:
            screen = self._screen_at(x, y)
        geo = self._screen_geometry(screen)
        if geo is None:
            return 0, 0
        w, h = self._view.width(), self._view.height()
        ml = int(x) - geo.x()
        mb = (geo.y() + geo.height()) - int(y) - h
        return max(0, ml), max(0, mb)

    def _pos_from_margins(self, ml, mb, screen=None):
        """层模式边距 -> 窗口左上角屏幕坐标。"""
        geo = self._screen_geometry(screen)
        if geo is None:
            return 0, 0
        w, h = self._view.width(), self._view.height()
        return (geo.x() + ml, geo.y() + geo.height() - mb - h)

    # ---------- 层模式拖动：margins 移动 + 客户端位置跟踪 ----------

    def _sync_last_known_pos(self):
        """把"已知位置"同步为当前边距对应的位置（初始摆位/恢复时用）。"""
        if self._last_known_pos is None:
            ml, mb = self._layer_margins()
            self._last_known_pos = self._pos_from_margins(ml, mb)
            _dlog("_sync_last_known_pos: 初始化跟踪位置 = %s（边距 %d,%d）"
                  % (self._last_known_pos, ml, mb))

    def set_position(self, x, y):
        """记录上次保存的窗口位置并立即尝试应用（窗口未显示时 Wayland
        合成器会忽略 setPosition，真正生效靠 show 后的 _place_desired）。
        层模式下换算成边距直接生效（锚定定位，无需等 show）。

        注意：这里收到的是"配置里存的位置"，恢复语义由调用方保证为全局
        坐标（KWin 脚本 frameGeometry 是全局坐标，配置文件里的值必须
        与之一致，否则窗口会被摆到错误位置/错误屏幕）。"""
        self._desired_pos = (int(x), int(y))
        # 跟踪位置同步为恢复目标（KWin 查询回调到达前的最新已知值）；
        # 这是"期望值"不是"真值"，标记为未验证，禁止直接写回配置
        self._last_known_pos = (int(x), int(y))
        self._pos_verified = False
        if self._layer_mode:
            ml, mb = self._margins_from_pos(int(x), int(y))
            _dlog("set_position(%d, %d): 层模式换算边距 marginLeft=%d "
                  "marginBottom=%d" % (int(x), int(y), ml, mb))
            self._set_layer_margins(ml, mb)
            return
        _dlog("set_position(%d, %d) 记录目标位置，立即尝试 setPosition "
              "(窗口是否已 show: %s)" % (self._desired_pos[0], self._desired_pos[1],
                                       self._view.isVisible()))
        try:
            self._view.setPosition(*self._desired_pos)
            _dlog("set_position -> setPosition 调用后实际读回 (x=%d, y=%d)"
                  % (self._view.x(), self._view.y()))
        except Exception as e:
            _dlog("set_position -> setPosition 抛出异常: %r" % (e,))

    def _place_desired(self):
        """show 后窗口已映射时补一次 setPosition。层模式跳过。"""
        if self._layer_mode:
            return
        if self._desired_pos is None:
            return
        _dlog("_place_desired: 补一次 setPosition%s，补位前实际坐标 (x=%d, y=%d)"
              % (self._desired_pos, self._view.x(), self._view.y()))
        try:
            self._view.setPosition(*self._desired_pos)
            _dlog("_place_desired: 补位后实际读回 (x=%d, y=%d)"
                  % (self._view.x(), self._view.y()))
        except Exception as e:
            _dlog("_place_desired -> setPosition 抛出异常: %r" % (e,))

    def _on_position_changed(self, *args):
        # 用户拖动时记录最新位置（hide→show 按此恢复），落盘由去抖定时器完成。
        # _suppress_pos_tracking 为 True 时是程序自己在摆位（默认摆位 /
        # 恢复保存位置），忽略——否则会把默认坐标误记进 _desired_pos 并
        # 起一个 400ms 后可能把默认坐标写回配置的定时器。
        # 层模式下该信号不连接（窗口不可拖动），此守卫为防御性代码。
        if self._layer_mode:
            return
        if self._suppress_pos_tracking:
            try:
                _dlog("xChanged/yChanged 触发但 _suppress_pos_tracking=True，"
                      "忽略（当前坐标 (%d,%d)，这是程序自己摆位，不是用户拖动）"
                      % (self._view.x(), self._view.y()))
            except Exception:
                pass
            return
        try:
            new_pos = (self._view.x(), self._view.y())
            _dlog("xChanged/yChanged 触发（用户拖动），当前坐标 %s -> 更新 "
                  "_desired_pos，启动/重启 400ms 去抖保存定时器" % (new_pos,))
            self._desired_pos = new_pos
        except Exception as e:
            _dlog("_on_position_changed 读取坐标异常: %r" % (e,))
        self._pos_timer.start()

    def _save_position(self):
        """把当前窗口坐标写入配置（经 manager 注入的 _save_pos_cb）。

        坐标必须与恢复语义一致（全局坐标）。Wayland 下优先用
        _last_known_pos（KWin 查询回调/恢复目标的合成器侧真相），
        QWindow.x()/y() 只是客户端缓存，不可靠；X11 下 view 坐标准确。
        层模式同样用 _last_known_pos。

        只有经过 KWin 查询验证（_pos_verified）的位置才写回配置：
        set_position 得到的恢复目标可能本身就是脏配置（例如屏幕局部
        偏移），直接写回会让脏值循环。未验证时跳过（保留旧配置），
        等 close() 的 KWin 查询回调写入真值。"""
        if self._layer_mode:
            try:
                if self._last_known_pos is None:
                    return
                if not self._pos_verified:
                    _dlog("_save_position: 层模式跟踪位置 (%d, %d) 未经验证"
                          "（仅为恢复目标/期望值），不写回配置"
                          % self._last_known_pos)
                    return
                x, y = self._last_known_pos
                self._desired_pos = (x, y)
                if self._save_pos_cb is not None:
                    self._save_pos_cb("desktopLyricPosX", str(int(x)))
                    self._save_pos_cb("desktopLyricPosY", str(int(y)))
                    _dlog("_save_position: 层模式按跟踪位置 (%d, %d) 写入配置"
                          % (x, y))
                return
            except Exception as e:
                _dlog("_save_position 层模式异常: %r" % (e,))
                return
        try:
            if self._kwin_pinner.is_kde():
                # Wayland：仅写 KWin 查询验证过的真值
                if self._pos_verified and self._last_known_pos is not None:
                    x, y = self._last_known_pos
                    _dlog("_save_position: Wayland 用 KWin 验证位置 (%d, %d)"
                          "（view 读数 (%d,%d) 仅客户端缓存，忽略）"
                          % (x, y, self._view.x(), self._view.y()))
                else:
                    _dlog("_save_position: 位置未经验证（恢复目标/无查询"
                          "回调），不写回配置")
                    return
            else:
                # X11：view 坐标准确
                x, y = self._view.x(), self._view.y()
            self._desired_pos = (x, y)
            if self._save_pos_cb is not None:
                self._save_pos_cb("desktopLyricPosX", str(int(x)))
                self._save_pos_cb("desktopLyricPosY", str(int(y)))
                _dlog("_save_position: 写入配置 "
                      "desktopLyricPosX=%d desktopLyricPosY=%d" % (x, y))
            else:
                _dlog("_save_position: _save_pos_cb 为 None，"
                      "本次坐标 (%d, %d) 没有写进配置！" % (x, y))
        except Exception as e:
            _dlog("_save_position 异常: %r" % (e,))

    # ---------- 对外控制 ----------

    def _apply_lock(self):
        """按 _locked 设置点击穿透 flag：锁定 → 穿透；取消锁定 → 可交互。

        Wayland 下 Qt.WindowTransparentForInput 被 QtWayland 翻译成
        wl_surface.set_input_region（锁定=空 region，解锁=nil/全区域），
        但该请求要等下一次 wl_surface commit 才被合成器应用——静态画面
        不会自动重绘/提交，实测开关"锁定歌词"后输入区域可能一直停在旧
        状态（表现为窗口点不到/点不到恢复）。每次切换后强制 requestUpdate
        排一帧渲染，让穿透状态立即生效。
        """
        try:
            self._view.setFlag(Qt.WindowTransparentForInput, self._locked)
            self._view.requestUpdate()
        except Exception:
            pass
        # 同步给 QML 桥接对象：锁定状态下 QML 侧不处理滚轮调音量
        try:
            self._bridge.setLocked(self._locked)
        except Exception:
            pass

    def set_locked(self, locked):
        """设置"锁定歌词"状态：locked 为真时窗口点击穿透、不可挪动。"""
        self._locked = bool(locked)
        self._apply_lock()

    @property
    def locked(self):
        return self._locked

    def begin_position_tracking(self):
        """由 manager.ensure() 在"默认摆位 + 恢复保存位置"都处理完之后调用，
        正式打开用户拖动的坐标跟踪/去抖保存。在这之前的所有 setPosition
        （构造函数默认摆位、ensure 里恢复保存坐标）都不应被当成"用户拖动"
        记录下来，否则会有极小概率被 400ms 去抖定时器误当成新位置写回配置，
        参见 _on_position_changed 里的详细说明。层模式无位置跟踪，跳过。"""
        if self._layer_mode:
            _dlog("begin_position_tracking: 层模式，无位置跟踪")
            return
        self._suppress_pos_tracking = False
        _dlog("begin_position_tracking: 正式开始跟踪用户拖动，"
              "当前 _desired_pos=%s，当前 view 坐标=(%d,%d)"
              % (self._desired_pos, self._view.x(), self._view.y()))

    def show(self):
        """显示窗口并安排位置恢复（setEnabled(True) 的内部实现）。
        层模式下没有位置恢复与 KWin 脚本。"""
        _dlog("show() 调用，调用前 _desired_pos=%s，调用前 view 坐标=(%d,%d)"
              % (self._desired_pos, self._view.x(), self._view.y()))
        self._view.show()
        _dlog("show() -> QQuickView.show() 之后坐标=(%d,%d)"
              % (self._view.x(), self._view.y()))
        if self._layer_mode:
            return
        # Wayland 下客户端 setPosition 只更新本地缓存，真正落位靠
        # _schedule_restore 的 KWin 脚本移动；置顶靠 keepAbove 脚本
        # （普通窗口没有协议级置顶请求）。
        self._place_desired_after_show()
        self._schedule_restore()
        self._schedule_keep_above()
        self._schedule_hyprland_float()

    def _schedule_hyprland_float(self):
        """Hyprland：首次展开后把窗口切为浮动（平铺合成器默认会平铺）。

        只做一次；窗口 show 后需几百毫秒才被合成器注册，放到后台线程里
        按 0.5/1.2/1.9s 重试，避免阻塞 UI。非 Hyprland 直接跳过。
        """
        if not self._hypr_float_supported or self._hypr_float_started:
            return
        self._hypr_float_started = True
        import threading
        threading.Thread(target=self._hyprland_float_worker, daemon=True).start()

    def _hyprland_float_worker(self):
        # 首次失败后隔 0.7s 重试：Hyprland 注册窗口有延迟
        for i in range(3):
            time.sleep(0.5 if i == 0 else 0.7)
            if self._hypr_floated:
                return
            if self._hypr_float.ensure_floating():
                self._hypr_floated = True
                _dlog("_hyprland_float_worker: 桌面歌词已切为浮动")
                return
        _dlog("_hyprland_float_worker: 3 次尝试后仍未成功切为浮动")

    def hide(self):
        _dlog("hide() 调用")
        self._view.hide()

    @property
    def visible(self):
        return self._view.isVisible()

    def setEnabled(self, enabled):
        """开/关桌面歌词窗口：显示时同步置顶 flag/锁定状态并安排位置恢复，
        隐藏时同步穿透状态。不要与 show()/hide() 叠加调用，避免补位
        定时器与位置恢复被重复调度。"""
        _dlog("setEnabled(%s) 调用，调用前 _desired_pos=%s" % (enabled, self._desired_pos))
        if enabled:
            self.show()
        else:
            self._view.hide()
        if not self._layer_mode:
            # 只在"置顶显示"开关为真时才设 flag，避免关掉置顶后又被重新打开
            self._view.setFlag(Qt.WindowStaysOnTopHint, enabled and self._stay_on_top)
            # 切歌/恢复显示时重新 raise（部分 WM 需要）
            if enabled and self._stay_on_top:
                self._view.raise_()
        # 显示/隐藏后重新应用锁定状态（Wayland 下 flag 可能在 show 时重建）
        self._apply_lock()

    def _place_desired_after_show(self, delay_ms=120):
        """延迟 delay_ms 在窗口已映射后补一次 setPosition。层模式跳过。"""
        if self._layer_mode:
            return
        if self._desired_pos is None:
            return
        _dlog("_place_desired_after_show: 安排 %dms 后补位到 %s"
              % (delay_ms, self._desired_pos))
        t = QTimer(self._view)
        t.setSingleShot(True)
        t.setInterval(delay_ms)
        t.timeout.connect(self._place_desired)
        t.start()

    def _schedule_restore(self):
        """show 后分几次延迟调 KWin 脚本，把窗口真正移动到保存的位置。

        Wayland 下客户端 setPosition 会被合成器忽略，唯一可靠的恢复方式
        是脚本直接写 frameGeometry（_KWinPinner.set_position）。窗口 show
        后需几百毫秒才被 KWin 注册（标题匹配才有效），所以 700/1400/2100ms
        各试一次；hide→show 连续触发用 _restore_pending 合并为同一轮。
        层模式下位置由合成器锚定，跳过。
        """
        if self._layer_mode:
            return
        if self._desired_pos is None:
            return
        if not self._kwin_pinner.is_kde():
            # X11 下 setPosition 是准的，不需要脚本
            return
        if self._restore_pending:
            return
        self._restore_pending = True
        x, y = self._desired_pos
        self._restore_remaining = 3
        _dlog("_schedule_restore: show 后 700/1400/2100ms 各尝试一次 KWin "
              "脚本移动窗口到 %s" % ((x, y),))
        for delay in (700, 1400, 2100):
            t = QTimer(self._view)
            t.setSingleShot(True)
            t.setInterval(delay)
            t.timeout.connect(lambda: self._on_restore_attempt(x, y))
            t.start()

    def _on_restore_attempt(self, x, y):
        self._restore_remaining -= 1
        if self._restore_remaining <= 0:
            self._restore_pending = False
        self._move_async(x, y)

    def _move_async(self, x, y):
        """后台线程调 set_position（subprocess 不阻塞 UI）。"""
        import threading
        t = threading.Thread(
            target=self._kwin_pinner.set_position,
            args=(x, y),
            daemon=True,
        )
        t.start()

    def _schedule_keep_above(self):
        """show 后分几次延迟调 KWin 脚本设置 keepAbove 置顶。

        窗口 show 后需几百毫秒才被 KWin 注册（标题匹配才有效），所以
        500/1200ms 各试一次。仅普通窗口 + KDE Wayland 需要（层窗口
        天然置顶；X11 用 WindowStaysOnTopHint）。"""
        if self._layer_mode:
            return
        if not self._kwin_pinner.is_kde():
            return
        if not self._stay_on_top:
            return
        _dlog("_schedule_keep_above: show 后 500/1200ms 各尝试一次 KWin "
              "脚本设置 keepAbove")
        for delay in (500, 1200):
            t = QTimer(self._view)
            t.setSingleShot(True)
            t.setInterval(delay)
            t.timeout.connect(self._keep_above_async)
            t.start()

    def _keep_above_async(self):
        """后台线程调 set_keep_above（subprocess 不阻塞 UI）。"""
        import threading
        t = threading.Thread(
            target=self._kwin_pinner.set_keep_above,
            args=(True,),
            daemon=True,
        )
        t.start()

    def raiseWindow(self):
        self._view.raise_()

    # 供 main.py 在退出时调用，归还 QML 资源
    def close(self):
        """退出前保存窗口位置：借道 KWin 脚本查询合成器侧真实坐标
        （Wayland 下客户端拿不到自己的全局位置），回调
        _on_kwin_reported_position 落盘；回调到达前先用跟踪坐标兜底，
        随后给 D-Bus 回调留出处理时间。

        普通窗口按标题匹配查询（query_position），层窗口按尺寸匹配
        （layer_query_position）；两种模式都必须走 KWin 查询——
        QWindow.x()/y() 在 Wayland 下只是客户端缓存，直接存会写入
        错误位置（自复位偏差的根源）。"""
        _dlog("close(): 开始保存位置（当前跟踪位置=%s，view 读数=(%d,%d)）"
              % (self._last_known_pos, self._view.x(), self._view.y()))
        # 先同步保存跟踪坐标（防极端情况如立刻退出丢位置；
        # Wayland 下 _save_position 已按 KWin 侧真相取值）
        try:
            self._save_position()
        except Exception:
            pass
        if self._kwin_pinner.is_kde():
            try:
                # 用脚本查询合成器侧真实坐标，权威结果经回调覆盖写入配置。
                # 3 秒周期同步已保证位置最新，这里只做最后一次尽力确认，
                # 等待窗口必须尽量短——退出时阻塞太久会让主窗口 QML 在
                # 销毁期间继续跑（报 appBridge 空引用错误），也拖慢退出。
                import threading
                if self._layer_mode:
                    w, h = self._view.width(), self._view.height()
                    t = threading.Thread(
                        target=self._kwin_pinner.layer_query_position,
                        args=(w, h),
                        daemon=True,
                    )
                else:
                    t = threading.Thread(
                        target=self._kwin_pinner.query_position,
                        daemon=True,
                    )
                t.start()
                # 最多等 0.3s 让 D-Bus 回调落地；没等到就用周期同步的值
                from PySide6.QtCore import QCoreApplication, QEventLoop
                deadline = time.monotonic() + 0.3
                while time.monotonic() < deadline:
                    QCoreApplication.processEvents(
                        QEventLoop.ProcessEventsFlag.AllEvents, 50)
                    time.sleep(0.02)
            except Exception as e:
                _dlog("close() 位置查询异常: %r" % (e,))
        self._view.close()


# ========== 模块级管理器（供 main.py / AppBridge 调用） ==========
# 整个进程只存在一个 DesktopLyrics 实例，避免重复创建多个歌词窗口。
_manager = None


class _DesktopLyricsManager:
    """懒创建的单例控制器。

    - ensure(player)：首次调用创建窗口（隐藏），之后复用；
    - set_enabled(on)：显示/隐藏歌词窗并持久化开关。
    """

    def __init__(self):
        self._lyrics = None  # DesktopLyrics or None
        self._player = None  # AudioPlayer 实例（ensure 时设置），用于配置持久化
        self._enabled = False
        self._ever_shown = False  # 本进程内是否已通过 set_enabled 主动 show/hide 过
        self._desktop_font = ""
        self._desktop_color = ""
        self._desktop_locked = False
        self._desktop_pos = None  # (x, y) 或 None；None 表示用默认摆位

    def _load_saved(self, player):
        """从 PyMusic.config 读取桌面歌词的开关/字体/颜色/锁定/位置。"""
        try:
            s = player.loadSettings()
            self._enabled = bool(s.get("desktopLyricsEnabled", False))
            self._desktop_font = s.get("desktopLyricFont", "") or ""
            self._desktop_color = s.get("desktopLyricColor", "") or ""
            self._desktop_locked = str(s.get("desktopLyricLocked", "false")).lower() == "true"
            raw_x = s.get("desktopLyricPosX", "")
            raw_y = s.get("desktopLyricPosY", "")
            try:
                px = int(float(raw_x))
                py = int(float(raw_y))
                self._desktop_pos = (px, py)
            except (TypeError, ValueError):
                self._desktop_pos = None
            _dlog("_load_saved: 从配置读到 desktopLyricsEnabled=%s "
                  "desktopLyricPosX=%r desktopLyricPosY=%r -> 解析出 "
                  "_desktop_pos=%s" % (self._enabled, raw_x, raw_y, self._desktop_pos))
        except Exception as e:
            self._enabled = False
            _dlog("_load_saved: 读取配置异常，全部退回默认值: %r" % (e,))

    def ensure(self, player):
        self._player = player
        created = False
        if self._lyrics is None:
            _dlog("ensure(): 首次创建 DesktopLyrics 实例")
            self._lyrics = DesktopLyrics(player)
            created = True
        elif self._lyrics._bridge._player is not player:
            # 播放器实例变化（一般不会），重建桥接
            _dlog("ensure(): player 实例变化，重建 DesktopLyrics")
            self._lyrics.close()
            self._lyrics = DesktopLyrics(player)
            created = True
        # 把位置持久化回调挂到窗口（用于拖动后保存位置）
        self._lyrics._save_pos_cb = self._save
        # 只在首次创建时读取并应用已保存的样式/锁定/位置；之后的 ensure
        # 绝不能重新套用配置里的旧位置，否则会把用户刚拖动到位、但去抖
        # 保存还没落盘的新位置覆盖回原位。
        if not created:
            _dlog("ensure(): 非首次调用（窗口已存在），直接复用，不重新套用"
                  "配置里的旧位置")
            return self._lyrics
        # 首次 ensure 时读取播放器配置中保存的样式/开关；之后复用已缓存值
        if self._player is not None:
            self._load_saved(self._player)
        # 把已保存的样式下发到桥接对象（重启/app 启动后生效）
        try:
            self._lyrics._bridge.setStyle(self._desktop_font, self._desktop_color)
        except Exception as e:
            _dlog("ensure(): setStyle 异常: %r" % (e,))
        # 把已保存的锁定状态应用到窗口（重启/app 启动后生效）
        try:
            self._lyrics.set_locked(self._desktop_locked)
        except Exception as e:
            _dlog("ensure(): set_locked 异常: %r" % (e,))
        # 恢复已保存的窗口位置（有则用之，无则用默认摆位）。
        # 窗口尚未显示时 Wayland 会忽略 setPosition，真正落位由 show 后的
        # _place_desired_after_show 补一次完成。
        try:
            if self._desktop_pos is not None:
                _dlog("ensure(): 应用已保存的位置 %s" % (self._desktop_pos,))
                self._lyrics.set_position(*self._desktop_pos)
            else:
                _dlog("ensure(): 没有已保存的位置（_desktop_pos 为 None），"
                      "将保持构造函数里算出的默认摆位")
        except Exception as e:
            _dlog("ensure(): set_position 异常: %r" % (e,))
        # 程序自摆位（默认摆位 + 恢复保存位置）到此结束，正式打开用户
        # 拖动跟踪，避免自动摆位被误当成用户拖动记录/保存。
        self._lyrics.begin_position_tracking()
        return self._lyrics

    def _save(self, key, value):
        """通过播放器的 saveSetting 持久化到 PyMusic.config。"""
        try:
            if self._player is not None:
                self._player.saveSetting(key, value)
                _dlog("_save: 写配置 %s=%s" % (key, value))
            else:
                _dlog("_save: self._player 为 None，%s=%s 没有写进去！" % (key, value))
        except Exception as e:
            _dlog("_save: 写配置 %s=%s 异常: %r" % (key, value, e))

    def is_enabled(self):
        # 只有"本进程主动 show/hide 过窗口"之后才信任 visible 来同步
        # _enabled（启动时窗口刚创建未显示，visible 恒 False，会把刚读
        # 到的配置值覆盖掉导致"上次开着"恢复不了）。
        if self._lyrics is not None and self._ever_shown:
            self._enabled = self._lyrics.visible
        return self._enabled

    def set_enabled(self, on, player=None):
        _dlog("set_enabled(%s) 调用" % (on,))
        if player is not None:
            self.ensure(player)
        self._ever_shown = True
        if self._lyrics is None:
            self._enabled = bool(on)
            self._enabled_cache(on)
            return
        if on:
            self._lyrics.setEnabled(True)
        else:
            self._lyrics.setEnabled(False)
        self._enabled = bool(on)
        self._save("desktopLyricsEnabled", "true" if on else "false")

    def _enabled_cache(self, on):
        self._save("desktopLyricsEnabled", "true" if on else "false")

    def close(self):
        if self._lyrics is not None:
            self._lyrics.close()

    def set_style(self, font, color, player=None):
        """设置桌面歌词字体/当前行颜色（空串=默认），更新渲染并持久化。"""
        if player is not None:
            self.ensure(player)
        font = font or ""
        color = color or ""
        self._desktop_font = font
        self._desktop_color = color
        if self._lyrics is not None:
            try:
                self._lyrics._bridge.setStyle(font, color)
            except Exception:
                pass
        self._save("desktopLyricFont", font)
        self._save("desktopLyricColor", color)

    def set_locked(self, locked, player=None):
        """设置"锁定歌词"：锁定则点击穿透、不可挪动，并持久化。"""
        if player is not None:
            self.ensure(player)
        self._desktop_locked = bool(locked)
        if self._lyrics is not None:
            try:
                self._lyrics.set_locked(self._desktop_locked)
            except Exception:
                pass
        self._save("desktopLyricLocked", "true" if self._desktop_locked else "false")


def ensure_desktop_lyrics(player):
    """确保桌面歌词控制器存在并绑定到 player（未启用时也创建，隐藏）。"""
    global _manager
    if _manager is None:
        _manager = _DesktopLyricsManager()
    _manager.ensure(player)
    return _manager


def set_desktop_lyrics_enabled(on, player=None):
    """开关桌面歌词；on 为 True 时显示，False 时隐藏。"""
    global _manager
    if _manager is None:
        _manager = _DesktopLyricsManager()
    _manager.set_enabled(on, player)
    return _manager


def is_desktop_lyrics_enabled():
    """返回桌面歌词当前是否显示。"""
    global _manager
    if _manager is None:
        return False
    return _manager.is_enabled()


def set_desktop_style(font, color, player=None):
    """设置桌面歌词字体/颜色（空串表示用默认值）。"""
    global _manager
    if _manager is None:
        _manager = _DesktopLyricsManager()
    _manager.set_style(font, color, player)
    return _manager


def set_desktop_lyrics_locked(locked, player=None):
    """设置"锁定歌词"；locked 为 True 时窗口不可挪动（点击穿透）。"""
    global _manager
    if _manager is None:
        _manager = _DesktopLyricsManager()
    _manager.set_locked(locked, player)
    return _manager


def close_desktop_lyrics():
    """退出时归还桌面歌词资源。"""
    global _manager
    if _manager is not None:
        _manager.close()


def _selftest_main():
    """独立自测入口：构造一个假"播放器"喂给 DesktopLyrics，验证窗口效果。

    注意：右键菜单用的是 QtWidgets 的 QMenu，因此这里必须用 QApplication
    而不是 QGuiApplication ——否则 QMenu.exec() 会因为找不到 QApplication
    实例而报错/无法弹出。main.py 里本来就用的是 QApplication，不受影响。
    """
    from PySide6.QtCore import QTimer
    from PySide6.QtWidgets import QApplication

    app = QApplication(sys.argv)
    QGuiApplication.setApplicationName("DesktopLyric Selftest")

    # 假播放器：直接用真 AudioPlayer 会启动完整曲库扫描，太重。
    # 这里用一个最小 QObject 桥代替，暴露出歌词/状态接口。
    class FakePlayer(QObject):
        lyricsChanged = Signal()
        lyricIndexChanged = Signal(int)
        stateChanged = Signal(str)

        def __init__(self):
            super().__init__()
            self._lyrics = [(i * 3.0, "第 %d 句 — 桌面歌词自测" % (i + 1))
                            for i in range(12)]
            self._idx = -1
            self._state = "stopped"
            self._t = 0
            self._timer = QTimer()
            self._timer.setInterval(500)
            self._timer.timeout.connect(self._tick)
            self._timer.start()

        @property
        def lyricCount(self):
            return len(self._lyrics)

        def lyricText(self, i):
            return self._lyrics[i][1] if 0 <= i < len(self._lyrics) else ""

        def lyricTime(self, i):
            return self._lyrics[i][0] if 0 <= i < len(self._lyrics) else 0.0

        @property
        def lyricIndex(self):
            return self._idx

        @property
        def currentLyricIndex(self):
            return self._idx

        @property
        def state(self):
            return self._state

        def _tick(self):
            self._t += 0.5
            if self._t < 5:
                self._state = "playing"
                self._idx += 1
                if self._idx >= len(self._lyrics):
                    self._idx = 0
                self._emit_all()
            elif self._t < 8:
                self._state = "paused"
                self._emit_all()
            elif self._t < 12:
                self._state = "playing"
                self._idx += 1
                if self._idx >= len(self._lyrics):
                    self._idx = 0
                self._emit_all()
            else:
                # 循环
                self._t = 0
                self._idx = -1
                self._state = "stopped"
                self._emit_all()

        def _emit_all(self):
            self.lyricsChanged.emit()
            self.lyricIndexChanged.emit(self._idx)
            self.stateChanged.emit(self._state)

    fake = FakePlayer()
    lyrics = DesktopLyrics(fake)
    lyrics.show()

    QTimer.singleShot(20000, app.quit)
    print("[desktop] 自测：应看到一个透明置顶歌词窗，每 0.5s 换行，"
          "中间暂停淡出。20s 后自动退出。")
    rc = app.exec()
    lyrics.close()
    return rc


if __name__ == "__main__":
    sys.exit(_selftest_main())
