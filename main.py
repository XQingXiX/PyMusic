#!/usr/bin/env python3
"""MusicPlayer2 - PySide6 + QML 音频播放器"""

import os
import random
import signal
import subprocess
import sys
import tempfile
from pathlib import Path

import re
import json
import time
import hashlib
import threading
from api import search_songs, save_lyric_file, save_cover_file, NeteaseAPIError

from PySide6.QtCore import (
    QObject, Signal, Slot, Property, QTimer, QProcess, QSocketNotifier
)
from PySide6.QtGui import QIcon, QFont, QGuiApplication
from PySide6.QtNetwork import QLocalServer
from PySide6.QtWidgets import QApplication
from PySide6.QtWidgets import QSystemTrayIcon, QMenu, QMessageBox
from PySide6.QtQml import QQmlApplicationEngine


MUSIC_DIR = Path("~/Music").expanduser()
SUPPORTED_AUDIO = (".mp3", ".flac", ".wav", ".ogg", ".m4a", ".wma", ".ape")
SUPPORTED_IMAGE = (".jpg", ".jpeg", ".png", ".bmp")

# AppImage 打包时自带的 ffmpeg/ffplay/ffprobe 位于 <app>/bin/，
# 把它们放到 PATH 最前面，保证优先使用与程序一起打包的版本；
# 目录不存在（源码运行）时不做任何改动，回退到系统 PATH。
_BUNDLED_BIN = Path(__file__).parent / "bin"
if _BUNDLED_BIN.is_dir():
    os.environ["PATH"] = str(_BUNDLED_BIN) + os.pathsep + os.environ.get("PATH", "")

# ========== 渲染循环 ==========
# Wayland 下 AppImage 捆绑的 Qt 有时会自动探测/降级为 basic（单线程）
# 场景图渲染循环——渲染完全挂在主线程事件循环里补帧，不再有独立线程
# 按固定节拍推进动画，导致歌词高亮这类 Behavior/SpringAnimation 动画
# 该刷新时刷不出来，攒到某个时刻才一次性跳变（表现为"卡在上一句，
# 快播完才跳到当前句"）。X11 下同一份 AppImage 通常能拿到 threaded
# 循环，所以只在 Wayland 复现。强制指定 threaded，让动画线程独立于
# 主线程推进，不受 ffprobe/subprocess 等同步调用影响。
os.environ.setdefault("QSG_RENDER_LOOP", "threaded")

# ========== 诊断日志 ==========
# QSG_INFO=1：让 Qt 在启动时自行打印实际使用的场景图后端
# （RHI/OpenGL/Software 等），用于排查 AppImage 下渲染性能问题。
os.environ.setdefault("QSG_INFO", "1")
# PYMUSIC_VERBOSE=1 时输出更详细的运行期日志（歌词索引变化等）
_VERBOSE = os.environ.get("PYMUSIC_VERBOSE") == "1"

# 歌词索引提前量（秒）：播放器/桌面歌词的滚动与高亮是动画驱动的，动画
# （highlightMoveDuration 等）会让"当前行跳到新一句"这个视觉动作比音频
# 实际唱到那句滞后约 0.1~0.3s。用一个小的提前量让索引在歌词时间戳到达前
# 就切过去，抵消动画延迟，观看上与演唱同步。可用
# PYMUSIC_LYRIC_LEAD_MS 覆盖（单位毫秒）。
try:
    _LYRIC_LEAD_SEC = int(os.environ.get("PYMUSIC_LYRIC_LEAD_MS", "300")) / 1000.0
except ValueError:
    _LYRIC_LEAD_SEC = 0.3

import logging
import logging.handlers
import faulthandler

# 日志通道：
# 1) stderr（终端直接可见，现状保留）
# 2) /dev/log → systemd journal（journalctl -t PyMusic 可查）
_LOG = logging.getLogger("PyMusic")
_LOG.setLevel(logging.DEBUG if _VERBOSE else logging.INFO)
_LOG_FORMAT = "[%(asctime)s][%(levelname)s] %(message)s"
_LOG_DATEFMT = "%H:%M:%S"
_LOG_SETUP_DONE = False


def _setup_logging():
    global _LOG_SETUP_DONE
    if _LOG_SETUP_DONE:
        return
    _LOG_SETUP_DONE = True
    _sh = logging.StreamHandler(sys.stderr)
    _sh.setFormatter(logging.Formatter(_LOG_FORMAT, _LOG_DATEFMT))
    _LOG.addHandler(_sh)
    try:
        _jh = logging.handlers.SysLogHandler(
            address="/dev/log",
            facility=logging.handlers.SysLogHandler.LOG_USER,
        )
        # journald 按 syslog 报文"冒号前"解析 SYSLOG_IDENTIFIER，所以把
        # "PyMusic: " 前缀放进 formatter（不用 SysLogHandler 的 ident 属性，
        # 该属性拼接时不含冒号，journald 会回退成发送进程名 python3）
        _jh.setFormatter(logging.Formatter("PyMusic: [%(levelname)s] %(message)s"))
        _LOG.addHandler(_jh)
    except Exception as e:
        _LOG.warning("journald 不可用，仅记录到 stderr: %s", e)


def _log(tag, msg):
    _LOG.info("[%s] %s", tag, msg)


def _log_warn(tag, msg):
    _LOG.warning("[%s] %s", tag, msg)


def _log_debug(tag, msg):
    _LOG.debug("[%s] %s", tag, msg)


def _install_qt_msg_handler():
    """把 Qt/QML 的 console.log 与 Qt 警告接入 logging（进 journal）。

    QML 里 console.log() 走 QtDebugMsg；这里统一转发到 _LOG。
    """
    from PySide6.QtCore import qInstallMessageHandler, QtMsgType

    def _qt_handler(qtMsgType, context, message):
        try:
            msg = str(message)
        except Exception:
            msg = str(qtMsgType)
        if qtMsgType == QtMsgType.QtWarningMsg:
            _LOG.warning("[QML] %s", msg)
        elif qtMsgType in (QtMsgType.QtCriticalMsg, QtMsgType.QtFatalMsg):
            _LOG.error("[QML] %s", msg)
        else:
            _LOG.debug("[QML] %s", msg)

    qInstallMessageHandler(_qt_handler)


# ffplay stderr 已直接转发到终端（ForwardedErrorChannel），不再需要
# 捕获与噪音过滤，相关代码已移除。


def _log_startup_diagnostics():
    """启动诊断：版本/平台/渲染相关环境变量/捆绑工具版本"""
    from PySide6.QtCore import qVersion
    from PySide6.QtGui import QGuiApplication
    _log("启动", "Python %s | PySide6/Qt %s | QPA 平台 %s"
         % (sys.version.split()[0], qVersion(), QGuiApplication.platformName()))
    _log("启动", "APPDIR=%s | 捆绑bin=%s"
         % (os.environ.get("APPDIR", "(非AppImage)"),
            str(_BUNDLED_BIN) if _BUNDLED_BIN.is_dir() else "(无)"))
    _log("启动", "QT_QPA_PLATFORM=%s QT_QUICK_BACKEND=%s QSG_RENDER_LOOP=%s QT_SCALE_FACTOR=%s"
         % (os.environ.get("QT_QPA_PLATFORM", "(默认)"),
            os.environ.get("QT_QUICK_BACKEND", "(默认)"),
            os.environ.get("QSG_RENDER_LOOP", "(默认)"),
            os.environ.get("QT_SCALE_FACTOR", "(默认)")))
    _log("启动", "PATH 前 300 字符: %s" % os.environ.get("PATH", "")[:300])

    def _probe():
        # 延后执行，避免阻塞启动；确认实际使用的 ffplay/ffmpeg 版本
        for tool in ("ffplay", "ffmpeg", "ffprobe"):
            try:
                r = subprocess.run([tool, "-version"], capture_output=True, text=True, timeout=5)
                first = r.stdout.splitlines()[0] if r.stdout else "(无输出)"
                _log("探测", "%s: %s" % (tool, first))
            except Exception as e:
                _log("探测", "%s: 不可用 (%s)" % (tool, e))
    QTimer.singleShot(1500, _probe)


def _to_path(path_str):
    """Normalize a path string to a Path object with cross-platform support.
    Converts Windows backslashes to forward slashes so paths from any OS
    are parsed correctly regardless of the host platform."""
    if isinstance(path_str, Path):
        return path_str
    return Path(str(path_str).replace("\\", "/"))


def find_matching_image(song_path, dir_images=None):
    """Find an image file that matches the song filename.

    dir_images: 可选，该目录下已列好的图片文件列表（由 scan_music 缓存传入，
    避免同一目录下每首歌都重复 iterdir 一遍，加快扫描速度）。
    """
    song_path = _to_path(song_path)
    song_dir = song_path.parent
    song_name = song_path.name
    song_base = song_path.stem

    candidates = []

    # 1. Exact match: song_base.jpg/png
    for ext in SUPPORTED_IMAGE:
        candidate = song_dir / (song_base + ext)
        if candidate.is_file():
            candidates.append(candidate)

    # 2. Audio_ext.jpg match: song_base.mp3.jpg / song_base.wav.jpg
    for ext in SUPPORTED_IMAGE:
        candidate = song_dir / (song_name + ext)
        if candidate.is_file():
            candidates.append(candidate)

    # 3. Partial match: image base name is a substring of song base name or vice versa
    if dir_images is None:
        try:
            dir_images = [
                f for f in song_dir.iterdir()
                if any(f.name.lower().endswith(ext) for ext in SUPPORTED_IMAGE)
            ]
        except (FileNotFoundError, OSError):
            dir_images = []

    for img_path in dir_images:
        if img_path in candidates:
            continue
        img_base = img_path.stem
        # Remove trailing .mp3/.wav from image base if present
        for aext in SUPPORTED_AUDIO:
            if img_base.lower().endswith(aext):
                img_base = img_base[:-len(aext)]
                break
        # Check if one contains the other
        if img_base and (img_base in song_base or song_base in img_base):
            candidates.append(img_path)

    return str(candidates[0]) if candidates else ""


def find_matching_lyrics(song_path):
    """Find an LRC file that matches the song filename."""
    song_path = _to_path(song_path)
    song_dir = song_path.parent
    song_name = song_path.name
    song_base = song_path.stem

    # 1. Exact match: song_base.lrc
    candidate = song_dir / (song_base + ".lrc")
    if candidate.is_file():
        return str(candidate)

    # 2. Audio_ext.lrc match: song_name.lrc
    candidate = song_dir / (song_name + ".lrc")
    if candidate.is_file():
        return str(candidate)

    # 3. Fuzzy match: find .lrc file whose base name contains or is contained in song_base
    try:
        dir_entries = list(song_dir.iterdir())
    except (FileNotFoundError, OSError):
        dir_entries = []
    for f in dir_entries:
        if f.name.lower().endswith(".lrc"):
            lrc_base = f.stem
            if lrc_base and (lrc_base in song_base or song_base in lrc_base):
                return str(f)

    return ""


# 歌曲附属文件（封面 / 歌词）会随歌曲一起被重命名或删除：api.py 下载封面时
# 按图片魔数写 .jpg/.png/.bmp/.webp，歌词写 .lrc，覆盖前还会把旧文件轮换成
# <文件名>.bak1/.bak2（见 api._rotate_backup）。这里集中列出这些候选后缀。
_SIDECAR_EXTS = (".jpg", ".jpeg", ".png", ".bmp", ".webp", ".lrc")


def _associated_sidecar_paths(song_path):
    """返回与歌曲同名的附属文件（封面/歌词 + 其 .bak1/.bak2 备份）路径列表。

    只做"精确同名"匹配，避免误伤同目录下名称恰好前后缀相同的其它文件。
    同时覆盖 <歌名>.<后缀> 与 <完整文件名>.<后缀> 两种命名
    （后者对应 find_matching_image 的 "song.mp3.jpg" 情形）。
    """
    song_path = _to_path(song_path)
    directory = song_path.parent
    bases = {song_path.stem, song_path.name}
    paths = []
    for base in bases:
        for ext in _SIDECAR_EXTS:
            paths.append(directory / (base + ext))
            paths.append(directory / (base + ext + ".bak1"))
            paths.append(directory / (base + ext + ".bak2"))
    return paths


def _looks_like_jpeg(path):
    """检查文件是否以 JPEG 魔数 (FF D8) 开头"""
    try:
        with open(path, "rb") as f:
            return f.read(2) == b"\xff\xd8"
    except OSError:
        return False


def extract_embedded_image(song_path):
    """Extract embedded cover art from audio file using ffmpeg.

    缓存文件名由「文件绝对路径 + mtime + 大小」哈希而来：
    - 旧实现只按文件名 stem 命名（mp2_<stem>.jpg），不同目录下同名歌曲
      会命中同一缓存文件，导致封面互相串图；
    - 音频被重新打标签（内嵌封面变化）后 mtime/大小会变，自动重新提取。

    先尝试 -vcodec copy 无损拷贝：内嵌封面是 JPEG 时速度最快。
    如果拷贝结果不是有效 JPEG（内嵌的是 PNG/BMP 时，copy 会把原始
    字节流直接塞进 .jpg 容器，生成损坏文件），回退为重新编码成 JPEG。
    """
    song_path = _to_path(song_path)
    try:
        st = song_path.stat()
        key = f"{song_path.resolve()}:{st.st_mtime}:{st.st_size}"
    except OSError:
        key = str(song_path.resolve())
    digest = hashlib.md5(key.encode("utf-8")).hexdigest()[:16]

    # 输出到程序的缓存目录（方案 B：曲库扫描/首次运行在这里建立封面缓存，
    # 重启后直接命中，无需重复 ffmpeg）
    cover_dir = SCAN_CACHE_DIR / "covers"
    try:
        cover_dir.mkdir(parents=True, exist_ok=True)
    except OSError:
        cover_dir = Path(tempfile.gettempdir())
    output_path = cover_dir / f"mp2_{digest}.jpg"

    # Return cached if already extracted
    if output_path.is_file() and output_path.stat().st_size > 0:
        return str(output_path)

    try:
        proc = subprocess.run(
            ["ffmpeg", "-y", "-i", song_path, "-an", "-vcodec", "copy", str(output_path)],
            capture_output=True, timeout=15
        )
        copied_ok = (
            proc.returncode == 0
            and output_path.is_file()
            and output_path.stat().st_size > 0
            and _looks_like_jpeg(output_path)
        )
        if not copied_ok:
            # 非 JPEG 内嵌封面：重新编码为 JPEG（mjpeg 编码器）
            subprocess.run(
                ["ffmpeg", "-y", "-i", song_path, "-an", "-vcodec", "mjpeg",
                 "-q:v", "3", str(output_path)],
                capture_output=True, timeout=15
            )
        if output_path.is_file() and output_path.stat().st_size > 0:
            return str(output_path)
    except Exception:
        pass
    return ""


def parse_lrc(filepath):
    """Parse an LRC file into a list of (time_seconds, text) tuples."""
    try:
        text = Path(filepath).read_text(encoding="utf-8", errors="replace")
        return parse_lrc_text(text)
    except Exception:
        return []


_LRC_TIME_RE = re.compile(r"\[(\d{1,3}):(\d{1,2}(?:\.\d{1,3})?)\]")


def shift_lrc_text(text, delta):
    """将 LRC 文本的所有 [mm:ss(.fff)] 时间戳整体平移 delta 秒（可正可负）。

    保留原始行结构与小数位数；结果为负的时间戳钳制为 0。
    """
    def _repl(m):
        mm = int(m.group(1))
        sec_part = m.group(2)
        if "." in sec_part:
            ss_str, frac = sec_part.split(".")
            frac_digits = len(frac)
            total = mm * 60 + int(ss_str) + int(frac.ljust(3, "0")) / 1000.0
            new = max(0.0, total + delta)
            new_mm = int(new // 60)
            new_ss = new - new_mm * 60
            return "[%02d:%0*.*f]" % (new_mm, 3 + frac_digits, frac_digits, new_ss)
        else:
            total = mm * 60 + int(sec_part)
            new = max(0, int(total + delta))
            return "[%02d:%02d]" % (new // 60, new % 60)

    return _LRC_TIME_RE.sub(_repl, text)


def _is_inline_bilingual(text):
    """判断歌词行是否为"原文/译文"内联双语格式。

    只拆分两侧至少有一侧含非 ASCII 字符的行：内联双语（如"日本語/中文翻译"）
    至少一侧是中文/日文等非 ASCII 文本；而 "he/she"、"R&B/Rap" 这类英文
    歌词里的斜杠两侧都是纯 ASCII，不应被误拆成两行。
    """
    if "/" not in text:
        return False
    parts = [p.strip() for p in text.split("/") if p.strip()]
    if len(parts) < 2:
        return False
    return any(any(ord(c) > 127 for c in p) for p in parts)


def parse_lrc_text(text):
    """Parse LRC lyrics from a string instead of a file."""
    lyrics = []
    pattern = r"\[(\d+):(\d+(?:\.\d+)?)\]"
    for line in text.split("\n"):
        line = line.strip()
        if not line:
            continue
        matches = re.findall(pattern, line)
        if not matches:
            continue
        text_part = re.sub(pattern, "", line).strip()
        if not text_part:
            continue
        if text_part.startswith("ti:") or text_part.startswith("ar:") \
           or text_part.startswith("al:") or text_part.startswith("by:") \
           or text_part.startswith("offset:") or text_part.startswith("re:"):
            continue
        for m in matches:
            minutes = int(m[0])
            seconds = float(m[1])
            total_seconds = minutes * 60 + seconds
            lyrics.append((total_seconds, text_part))
    lyrics.sort(key=lambda x: x[0])
    # Split bilingual lyrics (text containing "/") into separate entries
    split_lyrics = []
    for time_sec, text in lyrics:
        if _is_inline_bilingual(text):
            parts = [p.strip() for p in text.split("/") if p.strip()]
            for part in parts:
                split_lyrics.append((time_sec, part))
        else:
            split_lyrics.append((time_sec, text))
    return split_lyrics


def extract_embedded_lyrics(song_path):
    """Extract embedded lyrics from audio file metadata.
    Tries multiple tag names: 'lyrics', 'lyrics-XXX' (ID3v2 USLT frames), etc."""
    song_path = str(_to_path(song_path))

    def _try_parse(text):
        lyrics = parse_lrc_text(text)
        if lyrics:
            return lyrics
        lines = [l.strip() for l in text.split("\n") if l.strip()]
        if lines:
            return [(float(i), line) for i, line in enumerate(lines)]
        return []

    try:
        # First try the exact 'lyrics' tag (most common)
        result = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format_tags=lyrics",
             "-of", "default=noprint_wrappers=1:nokey=1", song_path],
            capture_output=True, text=True, timeout=10
        )
        if result.stdout.strip():
            parsed = _try_parse(result.stdout.strip())
            if parsed:
                return parsed

        # Fallback: get all format tags and search for any lyrics-* key
        result = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format_tags",
             "-of", "json", song_path],
            capture_output=True, text=True, timeout=10
        )
        data = json.loads(result.stdout)
        tags = data.get("format", {}).get("tags", {})
        for key, value in tags.items():
            if key.lower().startswith("lyrics") and value.strip():
                parsed = _try_parse(value.strip())
                if parsed:
                    return parsed
    except Exception:
        pass
    return []


def extract_song_metadata(song_path):
    """Extract embedded title and artist from audio file using ffprobe.
    Returns (title, artist) tuple. Empty strings if not found."""
    song_path = str(_to_path(song_path))
    try:
        result = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries",
             "format_tags=title,artist",
             "-of", "json", song_path],
            capture_output=True, text=True, timeout=10
        )
        data = json.loads(result.stdout)
        tags = data.get("format", {}).get("tags", {})
        title = tags.get("title", "").strip()
        artist = tags.get("artist", "").strip()
        return title, artist
    except Exception:
        return "", ""


def _get_scan_cache_dir():
    """扫描缓存目录：普通用户 ~/.cache/PyMusic。

    root 启动保护：以 root 运行时不往 /root/.cache 写持久缓存（那会
    产生 root 属主文件、且普通用户后续无法复用），改落到系统临时目录
    （会话级缓存，不污染用户环境）。
    """
    if getattr(os, "geteuid", lambda: -1)() == 0:
        return Path(tempfile.gettempdir()) / "PyMusic-root-cache"
    return Path.home() / ".cache" / "PyMusic"


SCAN_CACHE_DIR = _get_scan_cache_dir()


def _scan_cache_path(dir_path):
    """每个音乐目录一个缓存文件（按目录路径哈希命名）"""
    digest = hashlib.md5(str(dir_path).encode("utf-8")).hexdigest()[:16]
    return SCAN_CACHE_DIR / f"scan_{digest}.json"


def _list_dir_names(dir_path):
    """快速列出目录里的音频/图片文件名清单。

    用 os.scandir 的 d_type 判断文件类型，不逐文件 stat——
    这是缓存热路径，在 NAS/挂载盘上也能保持快（单次目录读取）。
    返回 (音频名列表, 图片名列表)，均为排序后的字符串列表。
    """
    audio, images = [], []
    try:
        with os.scandir(dir_path) as it:
            for e in it:
                try:
                    is_file = e.is_file(follow_symlinks=True)
                except OSError:
                    continue
                if not is_file:
                    continue
                name = e.name
                if name.lower().endswith(SUPPORTED_AUDIO):
                    audio.append(name)
                elif name.lower().endswith(SUPPORTED_IMAGE):
                    images.append(name)
    except OSError:
        return [], []
    return sorted(audio), sorted(images)


def _load_scan_cache(cache_path):
    try:
        with open(cache_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        if data.get("version") == 1:
            return data
    except Exception:
        pass
    return None


def _save_scan_cache(cache_path, audio_names, image_names, songs):
    try:
        SCAN_CACHE_DIR.mkdir(parents=True, exist_ok=True)
        with open(cache_path, "w", encoding="utf-8") as f:
            json.dump({
                "version": 1,
                "audio_names": audio_names,
                "image_names": image_names,
                "songs": songs,
            }, f, ensure_ascii=False)
    except OSError:
        pass  # 缓存目录不可写等情况下静默降级为每次全量扫描


def scan_music(dir_path=None):
    """扫描音乐目录，返回歌曲列表 [{path, name, image, mtime}, ...]。

    注意：这里只做快速文件扫描，不调用 ffprobe 提取元数据——元数据提取
    由 AudioPlayer._start_metadata_enrichment 在后台线程异步完成，
    避免大曲库启动扫描时长时间卡死 UI。

    缓存策略（大曲库/慢盘优化）：初次扫描全量执行（容忍一次慢）；
    之后每次启动先用 scandir 只列文件名（不 stat，NAS 友好），
    与缓存里的文件名清单一致就直接复用缓存的 image/mtime 映射——
    实测 3000 歌曲 + 1500 封面图：全量 2.5s，缓存命中 <20ms。
    文件名集合变化（增删歌曲/封面）时自动失效并重建缓存。
    """
    if dir_path is None:
        dir_path = MUSIC_DIR

    audio_names, image_names = _list_dir_names(dir_path)
    if not audio_names:
        return []

    cache_path = _scan_cache_path(dir_path)
    cached = _load_scan_cache(cache_path)
    if cached \
            and cached.get("audio_names") == audio_names \
            and cached.get("image_names") == image_names:
        # 热路径：直接复用缓存（浅拷贝，避免外部修改污染缓存对象）
        return [dict(s) for s in cached.get("songs", []) if s.get("path")]

    # 慢路径：全量扫描（含封面匹配与逐文件 stat），完成后写缓存
    songs = _full_scan(dir_path, audio_names, image_names)
    _save_scan_cache(cache_path, audio_names, image_names, songs)
    return songs


def _full_scan(dir_path, audio_names, image_names):
    """全量扫描：逐文件 stat + 封面匹配（慢，仅在缓存失效时执行）

    封面策略（方案 B）：
    1) 优先文件封面（同名 jpg/png，find_matching_image）
    2) 无文件封面时同步提取音频内嵌封面（ffmpeg），写入缓存目录
       ~/.cache/PyMusic/covers/，路径随扫描缓存一起持久化——
       首次运行会较慢（逐首 ffmpeg），之后秒开。
    """
    # 每个目录只列一次图片文件，避免同目录下每首歌都重复 iterdir
    image_paths = [dir_path / n for n in image_names]

    songs = []
    for name in audio_names:
        fpath = dir_path / name
        try:
            st = fpath.stat()
        except OSError:
            # 文件在扫描期间被删除/权限变化等情况，跳过而不是崩溃
            continue
        image = find_matching_image(str(fpath), image_paths)
        if not image:
            # 无文件封面：尝试内嵌封面（同步提取，结果进缓存目录）
            image = extract_embedded_image(fpath)
        songs.append({
            "path": str(fpath),
            "name": fpath.stem,
            "image": image,
            "mtime": st.st_mtime,
        })
    return songs


def build_song_name(song_path):
    """优先使用内嵌元数据作为歌曲显示名（"标题 - 作者"），否则回退到文件名 stem。"""
    song_path = _to_path(song_path)
    title, artist = extract_song_metadata(str(song_path))
    if title and artist:
        return f"{title} - {artist}"
    if title:
        return title
    return song_path.stem


def write_title_tag(song_path, title):
    """用 ffmpeg 改写音频文件的内嵌标题标签（保留作者等其它标签）。

    重命名歌曲时调用：列表显示名优先取内嵌标签（build_song_name），
    只改文件名不会改变显示名，因此把新名字写进标题标签，使列表持久生效。
    采用 `-c copy` 仅重封装、不重编码，先写临时文件再原子替换，避免
    写失败损坏原文件。成功返回 True。
    """
    song_path = _to_path(song_path)
    tmp_path = song_path.with_name(song_path.stem + ".pymusic_tmp" + song_path.suffix)
    try:
        result = subprocess.run(
            ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
             "-i", str(song_path),
             "-c", "copy",
             "-metadata", "title=" + title,
             str(tmp_path)],
            capture_output=True, text=True, timeout=120,
        )
        if result.returncode != 0 or not tmp_path.is_file():
            if tmp_path.is_file():
                try:
                    tmp_path.unlink()
                except OSError:
                    pass
            return False
        os.replace(str(tmp_path), str(song_path))
        return True
    except Exception:
        if tmp_path.is_file():
            try:
                tmp_path.unlink()
            except OSError:
                pass
        return False


class _TaskSignals(QObject):
    """后台任务完成信号：finished(task_id, ok, result)。"""
    finished = Signal(int, bool, object)


class AudioPlayer(QObject):
    """音频播放控制后端"""

    # saveSetting 的类型转换只针对这些已知的键：
    # 布尔键按 "true"/"false" 转换，数值键尝试转 int/float，
    # 其它键（musicDir 等路径，可能包含纯数字目录名）一律保持字符串。
    _BOOL_SETTING_KEYS = {"hideControlBackgrounds", "autoSwitchToLyric", "closeToTray",
                          "desktopLyricsEnabled", "desktopLyricLocked"}
    _NUMERIC_SETTING_KEYS = {"volume", "sortMode", "blurRadius", "panelOpacity",
                             "rowSpacing", "lastPosition", "playMode",
                             "cardSize", "listStyle"}

    # Signals emitted to QML
    positionChanged = Signal(float)  # current position in seconds
    durationChanged = Signal(float)  # total duration in seconds
    stateChanged = Signal(str)       # "playing", "paused", "stopped"
    songChanged = Signal(int)        # current song index
    songListChanged = Signal()
    lyricIndexChanged = Signal(int)  # current lyric line index（带提前量，供播放器主界面）
    lyricsChanged = Signal()         # lyrics list changed
    musicDirChanged = Signal()       # music directory changed
    sortModeChanged = Signal()       # sort mode changed
    playModeChanged = Signal()       # play mode changed
    downloadStatusChanged = Signal()  # download status text changed
    searchResultModelChanged = Signal()  # search results changed
    volumeChanged = Signal(int)          # volume changed
    coverFileUpdated = Signal(str)       # 封面文件内容已更新（路径不变），用于刷新 QML 图片缓存
    settingsRolledBack = Signal()        # 设置已回退到上一版本（QML 重新加载全部设置）
    settingsBackupChanged = Signal()     # 设置备份状态变化（回退按钮 enabled 绑定）

    def __init__(self, parent=None):
        super().__init__(parent)

        # 后台任务调度：网络请求/元数据提取都在线程中执行，避免阻塞 UI。
        # 线程里 emit 的信号会因接收者（本对象，位于 GUI 线程）自动排队投递，
        # 所以回调 _on_task_finished 一定在主线程执行。
        self._task_signals = _TaskSignals(self)
        self._task_signals.finished.connect(self._on_task_finished)
        self._task_counter = 0
        self._task_callbacks = {}

        # 音乐目录与歌曲列表
        self._music_dir = MUSIC_DIR
        self._songs = scan_music(self._music_dir)
        self._sort_mode = 0  # 0=name asc, 1=name desc, 2=time asc, 3=time desc
        self._play_mode = 0  # 0=顺序, 1=单曲循环, 2=随机
        # 播放列表样式：0=列表行, 1=卡片网格；卡片大小(px)
        self._list_style = 0
        self._card_size = 140
        # 随机模式下的播放历史（用于"上一首"回退，最多 50 条）
        self._play_history = []
        # 播放列表本地搜索词（小写，匹配歌曲名/文件名）
        self._song_search = ""
        self._current_index = -1
        self._song_list_model_cache = None
        self._sort_songs()

        # 播放状态
        self._state = "stopped"  # playing, paused, stopped
        self._volume = 50
        self._position = 0.0
        self._duration = 0.0

        # ffplay 子进程管理
        self._process = None  # QProcess for ffplay
        self._position_timer = QTimer(self)
        self._position_timer.setInterval(250)
        self._position_timer.timeout.connect(self._update_position)

        # 位置定时器滞后探针（诊断"高亮落后"是否为渲染/主线程繁忙导致）：
        # 统计实际触发间隔超过期望值 250ms 的次数与累计滞后
        self._timer_last_fire = 0.0
        self._timer_slow_count = 0
        self._timer_max_lag = 0.0
        self._timer_lag_total = 0.0

        # 停滞转储：主线程卡住超阈值时 dump 主线程 Python 堆栈到日志
        # （能直接看到卡在哪个调用上，如 QProcess/文件 IO/子进程等待）。
        # SIGALRM 按阈值间隔重复触发，直到事件循环恢复。
        # 阈值可用 PYMUSIC_STALL_DUMP_MS 调整（默认 800ms）。
        # faulthandler 需要真实 fd：写入管道，由排水定时器转发到日志
        try:
            _stall_ms = float(os.environ.get("PYMUSIC_STALL_DUMP_MS", "800"))
        except ValueError:
            _stall_ms = 800.0
        self._stall_threshold = _stall_ms / 1000.0
        self._stall_rfd, self._stall_wfd = os.pipe()
        # 读端必须非阻塞：排水定时器每次触发都 read，管道为空时若阻塞读
        # 会把主线程/事件循环卡死（这是之前所有定时器全灭的根因）
        os.set_blocking(self._stall_rfd, False)
        os.set_inheritable(self._stall_wfd, False)
        self._stall_wfile = os.fdopen(self._stall_wfd, "wb", buffering=0)
        self._loop_last_tick = 0.0
        self._watchdog_last_dump = 0.0
        self._stall_drain = QTimer(self)
        self._stall_drain.setInterval(200)
        self._stall_drain.timeout.connect(self._drain_stall_pipe)
        self._stall_drain.start()
        # 看门狗线程：主线程停滞超阈值时 dump 所有线程堆栈。
        # 不依赖 SIGALRM（实测 faulthandler.dump_traceback_later 的重复
        # 转储在部分环境失效）。
        threading.Thread(target=self._stall_watchdog, daemon=True).start()

        # 暂停/恢复的音量渐变（PA 平滑淡出淡入，250ms）
        self._fade_timer = QTimer(self)
        self._fade_timer.setInterval(30)
        self._fade_timer.timeout.connect(self._on_fade_tick)
        self._fade_direction = None   # None / "out"(暂停淡出) / "in"(恢复淡入) / "quit"(退出淡出)
        self._fade_step = 0
        self._fade_total = 0
        # 淡出代数：每次取消/结束渐变递增，用于丢弃在途的过期 pactl 音量命令
        self._fade_generation = 0
        # 退出淡出完成后要执行的退出回调（由 main() 注入 quit_app）
        self._quit_callback = None

        # 异步 pactl：在途 QProcess 集合 + 同一 pid 的 sink 查找去重
        self._pactl_procs = {}
        self._sink_pending = {}  # pid -> [callback, ...]
        self._prewarm_pa()

        # 歌词数据
        self._lyrics = []  # list of (time_seconds, text) tuples
        self._current_lyric_index = -1

        # 暂停/续播计时
        self._paused_position = 0.0
        self._play_start_time = 0.0
        self._pause_time = 0.0
        self._total_paused_duration = 0.0
        self._playlist_visible = True
        self._seek_base = 0.0
        self._volume_dirty = False  # 暂停期间是否有未应用到 ffplay 的音量变更（用于 resume 时补偿）
        # 进度条拖动开始前是否处于播放中（松手时据此决定恢复播放还是保持暂停）
        self._seek_drag_was_playing = False

        # PulseAudio 探测与 sink-input 查找缓存：
        # - _pa_available：pactl 可用性在启动时由 _prewarm_pa 异步探测一次；
        # - _sink_id_cache：同一 ffplay 进程的 sink-input index 在其生命周期内
        #   不变，按 pid 缓存可避免每次音量调节/重试都跑一遍 pactl list。
        self._pa_available = None
        self._sink_id_cache = {}

        # 最近一次启动的 ffplay 子进程 pid（供 SIGSEGV 处理器做最小化清理）
        self._last_child_pid = None

        # 下载面板数据
        self._search_results = []
        self._download_status = ""
        # 搜索请求代数：连续搜索时旧请求晚到会覆盖新结果，用代数丢弃过期回调
        self._search_seq = 0

        # 内嵌封面异步提取缓存（避免 ffmpeg 阻塞 GUI 线程）
        self._embedded_cover_cache = {}
        self._pending_cover_extract = set()
        self._embedded_cover_failed = set()

        # 配置文件路径
        self._config_dir = Path.home() / ".config" / "PyMusic"
        self._config_file = self._config_dir / "PyMusic.config"
        self._ensure_config_dir()
        # 设置备份轮换的静默窗口计时（把拖动滑块等密集保存合并为一个版本）
        self._last_backup_ts = 0.0

        # 从配置文件加载音量
        try:
            settings = self.loadSettings()
            if "volume" in settings:
                self._volume = max(0, min(100, int(settings["volume"])))
            if "playMode" in settings:
                self._play_mode = max(0, min(2, int(settings["playMode"])))
            if "listStyle" in settings:
                self._list_style = max(0, min(1, int(settings["listStyle"])))
            if "cardSize" in settings:
                self._card_size = max(90, min(220, int(settings["cardSize"])))
        except Exception:
            pass

        # 启动后台元数据补全（文件名先建列表，ffprobe 结果异步回填）
        self._start_metadata_enrichment()

    # ========== 歌曲信息查询 ==========

    def _drain_stall_pipe(self):
        """把停滞转储（看门狗线程写入管道）转发到日志"""
        self._loop_last_tick = time.monotonic()
        try:
            data = os.read(self._stall_rfd, 65536)
        except BlockingIOError:
            return
        except OSError:
            return
        if data:
            for line in data.decode("utf-8", "replace").splitlines():
                if line.strip():
                    _log("停滞", line)

    def _stall_watchdog(self):
        """看门狗线程：主线程事件循环停滞超阈值时转储主线程堆栈。"""
        import traceback as _tb
        while True:
            time.sleep(0.2)
            try:
                now = time.monotonic()
                if self._loop_last_tick and (now - self._loop_last_tick) > self._stall_threshold:
                    if (now - self._watchdog_last_dump) > 2.0:
                        self._watchdog_last_dump = now
                        _log_warn("停滞", "检测到主线程停滞 %.0fms，主线程堆栈:"
                                  % ((now - self._loop_last_tick) * 1000))
                        # 从看门狗线程安全读取主线程的 Python 帧
                        main_tid = threading.main_thread().ident
                        frame = sys._current_frames().get(main_tid)
                        if frame:
                            for line in _tb.format_stack(frame):
                                for l in line.rstrip("\n").split("\n"):
                                    if l.strip():
                                        _log("停滞", l)
            except Exception:
                pass

    @Slot(int, result=str)
    def songName(self, index):
        """返回指定索引的歌曲显示名称（歌曲名 - 作者）"""
        if 0 <= index < len(self._songs):
            return self._songs[index]["name"]
        return ""

    @Slot(int, result=str)
    def songPath(self, index):
        """返回指定索引的歌曲文件路径"""
        if 0 <= index < len(self._songs):
            return self._songs[index]["path"]
        return ""

    @Slot(int, result=str)
    def songImage(self, index):
        """返回指定索引的歌曲封面图片路径"""
        if 0 <= index < len(self._songs):
            return self._songs[index]["image"]
        return ""

    @Property(int, notify=songListChanged)
    def songCount(self):
        """返回歌曲总数（QML 可绑定）"""
        return len(self._songs)

    @Property("QVariantList", notify=songListChanged)
    def songListModel(self):
        """返回歌曲列表模型数据，每次排序/变更时重建列表

        支持本地搜索过滤：命中搜索词（歌名/文件名小写包含）的项才会出现，
        每项带 index 字段指向完整列表（_songs）下标，供 QML 高亮/点击
        与播放索引对齐。
        """
        if self._song_list_model_cache is None:
            cache = []
            search = self._song_search
            for i, s in enumerate(self._songs):
                if search and search not in s["name"].lower():
                    continue
                cache.append({
                    "name": s["name"],
                    "path": s["path"],
                    "image": s["image"],
                    "index": i,
                })
            self._song_list_model_cache = cache
        return self._song_list_model_cache

    @Slot(str)
    def setSongSearch(self, text):
        """设置播放列表本地搜索词（过滤歌曲列表模型）"""
        text = (text or "").strip().lower()
        if text != self._song_search:
            self._song_search = text
            self._song_list_model_cache = None
            self.songListChanged.emit()

    @Property(int, notify=songListChanged)
    def filteredSongCount(self):
        """搜索过滤后的歌曲数量（头部"N 首"显示用）"""
        if not self._song_search:
            return len(self._songs)
        return sum(1 for s in self._songs
                   if self._song_search in s["name"].lower())

    # ========== 音乐目录管理 ==========

    @Property(str, notify=musicDirChanged)
    def musicDir(self):
        """返回当前音乐目录路径（QML 可绑定）"""
        return str(self._music_dir)

    @Slot(str, result=bool)
    def setMusicDir(self, path):
        """切换音乐目录并重新扫描歌曲，返回是否成功（路径无效返回 False）"""
        path = _to_path(path).expanduser()
        if not path.is_dir():
            return False
        if path != self._music_dir:
            self._music_dir = path
            self._songs = scan_music(path)
            self._sort_songs()
            self._current_index = -1
            self._song_list_model_cache = None
            self._song_search = ""
            self.songListChanged.emit()
            self.songChanged.emit(-1)
            self.musicDirChanged.emit()
            self._start_metadata_enrichment()
        return True

    def _reload_songs(self, keep_path=None):
        """重新扫描音乐目录并恢复当前播放歌曲（重命名/删除文件后刷新列表）。

        与 _sort_songs 不同：先把 current_index 清成 -1 再扫描、排序，避免
        用旧下标去新列表里按路径"恢复"到错误的歌上；排序完成后再按 keep_path
        定位（重命名后传新路径，删除其它歌时传当前歌的旧路径）。
        """
        self._current_index = -1
        self._songs = scan_music(self._music_dir)
        self._song_list_model_cache = None
        self._sort_songs()
        if keep_path:
            for i, song in enumerate(self._songs):
                if song["path"] == keep_path:
                    self._current_index = i
                    self.songChanged.emit(i)
                    break

    def _write_scan_cache(self):
        """把当前歌曲列表写入扫描缓存（重命名/删除后调用）。

        正常情况下 scan_music 已会写缓存；这里显式再写一次，确保改名/删除
        后的最新文件名落盘，避免下次启动命中旧缓存而"找不到歌曲"。
        """
        try:
            audio_names, image_names = _list_dir_names(self._music_dir)
            _save_scan_cache(_scan_cache_path(self._music_dir),
                             audio_names, image_names, self._songs)
        except Exception:
            pass

    @Slot(int, str, result=bool)
    def renameSong(self, index, new_name):
        """把第 index 首歌曲及其封面/歌词（含 .bakN 备份）重命名为 new_name。

        new_name 不含扩展名，扩展名保留原样。目标已存在或名称非法时返回
        False 且不做任何改动。重命名后重新扫描目录，列表实时刷新。
        """
        if not (0 <= index < len(self._songs)):
            return False
        new_name = (new_name or "").strip()
        if not new_name or new_name in (".", "..") \
                or "/" in new_name or "\\" in new_name or "\0" in new_name:
            return False

        old_path = _to_path(self._songs[index]["path"])
        old_path_str = self._songs[index]["path"]
        if not old_path.is_file():
            return False
        new_audio = old_path.with_name(new_name + old_path.suffix)
        if new_audio == old_path:
            return True
        if new_audio.exists():
            return False

        # 汇总所有需要一起改名的文件：先算好目标路径并检查冲突，
        # 全部合法后再统一执行，避免改到一半失败留下半套文件。
        moves = [(old_path, new_audio)]
        for sidecar in _associated_sidecar_paths(old_path):
            if not sidecar.is_file():
                continue
            suffix = sidecar.name[len(old_path.stem):]
            target = new_audio.parent / (new_name + suffix)
            if target == sidecar:
                continue
            if target.exists():
                return False
            moves.append((sidecar, target))

        was_current = (index == self._current_index)
        current_path = None
        if 0 <= self._current_index < len(self._songs):
            current_path = self._songs[self._current_index]["path"]

        try:
            for src, dst in moves:
                src.rename(dst)
        except OSError:
            return False

        # 只改文件名不会改变列表显示名（build_song_name 优先取内嵌标签），
        # 因此把新名字同步写进标题标签，让列表与左侧曲名都持久生效。
        if not write_title_tag(new_audio, new_name):
            _log("重命名", "write_title_tag 失败（保持文件名已改）：%s" % new_audio)

        # 正在播放的是被改名这首：跟随到新路径；否则保持当前歌不变。
        keep_path = str(new_audio) if was_current else current_path
        self._reload_songs(keep_path)
        if was_current:
            # LRC/封面文件名变了，重新按新路径加载歌词
            self._load_lyrics()
        # 重新扫描后名字回退为文件名，后台补全元数据（标题/作者）再刷新
        self._start_metadata_enrichment()
        # 把改名结果写入扫描缓存，避免下次启动命中旧缓存找不到该曲
        self._write_scan_cache()
        # 若配置里记录的"上次播放歌曲"正是被改名这首，同步更新为新路径，
        # 否则重启后 restoreLastPosition 按旧路径找不到该曲
        if self.loadSettings().get("lastFile", "") == old_path_str:
            self.saveSetting("lastFile", str(new_audio))
        return True

    @Slot(int, result=bool)
    def deleteSong(self, index):
        """删除第 index 首歌及其封面/歌词（含 .bakN 备份），返回是否成功。

        会弹出确认框由 QML 负责；删除正在播放的歌时先停止播放。删除后
        重新扫描目录，列表实时刷新。
        """
        if not (0 <= index < len(self._songs)):
            return False
        path = _to_path(self._songs[index]["path"])
        was_current = (index == self._current_index)
        song_total = len(self._songs)
        current_path = None
        if 0 <= self._current_index < song_total:
            current_path = self._songs[self._current_index]["path"]

        # 删除的是当前播放歌曲时，先记下删除后要接续播放的"下一首"路径：
        # 删除后列表整体前移，原 index+1 处即新列表的下一首；删除的是最后
        # 一首则回到第一首。记录路径而非下标，避免重扫后错位。
        next_path = None
        if was_current and song_total > 1:
            next_path = self._songs[index + 1]["path"] if index + 1 < song_total \
                else self._songs[0]["path"]

        if was_current:
            self._kill_process()
            self._state = "stopped"
            self.stateChanged.emit("stopped")
            self._position = 0.0
            self.positionChanged.emit(0.0)
            self._lyrics = []
            self._current_lyric_index = -1
            self.lyricsChanged.emit()
            self.lyricIndexChanged.emit(-1)

        files = [path] + [p for p in _associated_sidecar_paths(path) if p.is_file()]
        ok = True
        for f in files:
            try:
                f.unlink()
            except OSError:
                ok = False

        self._reload_songs(None if was_current else current_path)
        self._start_metadata_enrichment()
        # 删除结果写入扫描缓存，避免下次启动命中旧缓存找不到该曲
        self._write_scan_cache()
        # 配置里记录的"上次播放歌曲"若正是被删这首，改为接续的下一首
        # （没有下一首则清空），否则重启时按失效路径找不到歌曲
        if self.loadSettings().get("lastFile", "") == str(path):
            self.saveSetting("lastFile", next_path or "")

        # 删除当前歌曲后自动接续播放下一首（列表已刷新，按路径重新定位）
        if next_path:
            for i, song in enumerate(self._songs):
                if song["path"] == next_path:
                    self._current_index = i
                    self._position = 0.0
                    self.songChanged.emit(i)
                    self.positionChanged.emit(0.0)
                    self.play()
                    break
        return ok

    # ========== 当前播放索引 ==========

    @Property(int, notify=songChanged)
    def currentIndex(self):
        """返回当前播放歌曲的索引（QML 可绑定）"""
        return self._current_index

    @currentIndex.setter
    def currentIndex(self, index):
        """设置当前播放歌曲索引，重置播放进度"""
        if index != self._current_index and 0 <= index < len(self._songs):
            self._current_index = index
            self._position = 0.0
            self.songChanged.emit(index)

    # ========== 播放状态属性 ==========

    @Property(str, notify=stateChanged)
    def state(self):
        """返回播放状态：playing / paused / stopped（QML 可绑定）"""
        return self._state

    @Property(float, notify=positionChanged)
    def position(self):
        """返回当前播放进度（秒，QML 可绑定）"""
        return self._position

    @Property(float, notify=durationChanged)
    def duration(self):
        """返回当前歌曲总时长（秒，QML 可绑定）"""
        return self._duration

    # ========== 音量控制 ==========

    @Property(int, notify=volumeChanged)
    def volume(self):
        """返回当前音量（0-100，QML 可绑定）"""
        return self._volume

    @volume.setter
    def volume(self, vol):
        """设置音量（0-100），优先使用 PulseAudio 无缝调节，失败时回退到重启 ffplay

        注意：暂停状态下 ffplay 进程处于 SIGSTOP 挂起态，此时既不应该
        通过 pactl 去调整（进程已挂起，sink-input 可能仍在但调整意义不大），
        也绝不能走"重启 ffplay 再 SIGSTOP"的回退分支——那样会在每次拖动
        滑块时都同步重启子进程并阻塞等待，造成 UI 卡顿。
        暂停时只记录新音量，标记为 dirty，等 resume() 或下次 play() 时
        再统一应用，避免频繁重启进程。
        """
        self._volume = max(0, min(100, vol))
        self.volumeChanged.emit(self._volume)
        # 自动持久化音量（参考其他设置项的 onChange 持久化模式）
        self.saveSetting("volume", str(self._volume))

        if self._state == "paused":
            # 暂停中：不触碰子进程，留到恢复播放时统一应用
            self._volume_dirty = True
            return

        # 优先尝试 PulseAudio/PipeWire 无缝调节（不中断播放，异步不阻塞）
        def on_vol_result(ok):
            if ok:
                self._volume_dirty = False
                return
            # 回退方案：重启 ffplay 以应用新音量（仅在正在播放且没有 PA 时才需要）
            # ffplay -nodisp 模式无法通过 stdin 按键调音量，只能重启
            if self._state == "playing" and 0 <= self._current_index < len(self._songs):
                # 重启前精确计算当前位置，减少进度回退
                elapsed = self._get_current_time() - self._play_start_time - self._total_paused_duration
                pos = max(0.0, self._seek_base + elapsed)
                # 时长未知（异步 ffprobe 还没返回）时不能按 0 clamp，否则会从头播放
                if self._duration > 0:
                    pos = min(pos, self._duration)

                filepath = self._songs[self._current_index]["path"]
                self._start_ffplay(filepath, pos, use_pa=False)
                self._state = "playing"
                self.stateChanged.emit("playing")
                self._volume_dirty = False

        self._adjust_volume_pa(on_vol_result)

    # ========== 排序模式 ==========

    @Property(int, notify=sortModeChanged)
    def sortMode(self):
        return self._sort_mode

    @sortMode.setter
    def sortMode(self, mode):
        mode = mode % 4
        if mode != self._sort_mode:
            self._sort_mode = mode
            self._sort_songs()
            self.sortModeChanged.emit()

    # ========== 播放模式 ==========

    @Property(int, notify=playModeChanged)
    def playMode(self):
        """播放模式：0=顺序, 1=单曲循环, 2=随机（QML 可绑定）"""
        return self._play_mode

    @playMode.setter
    def playMode(self, mode):
        mode = mode % 3
        if mode != self._play_mode:
            self._play_mode = mode
            self.saveSetting("playMode", str(mode))
            self.playModeChanged.emit()

    # ========== 播放列表样式 ==========

    @Property(int, notify=songListChanged)
    def listStyle(self):
        """播放列表样式：0=列表行, 1=卡片网格"""
        return self._list_style

    @listStyle.setter
    def listStyle(self, style):
        style = 0 if style != 1 else 1
        if style != self._list_style:
            self._list_style = style
            self.saveSetting("listStyle", str(style))
            self.songListChanged.emit()

    @Property(int, notify=songListChanged)
    def cardSize(self):
        """卡片大小（px，卡片网格视图用）"""
        return self._card_size

    @cardSize.setter
    def cardSize(self, size):
        size = max(90, min(220, int(size)))
        if size != self._card_size:
            self._card_size = size
            self.saveSetting("cardSize", str(size))
            self.songListChanged.emit()

    # ========== 下载面板：搜索 & 下载 ==========

    @Property("QVariantList", notify=searchResultModelChanged)
    def searchResultModel(self):
        """返回网易云搜索结果的模型列表（QML 可绑定）"""
        return self._search_results

    @Property(str, notify=downloadStatusChanged)
    def downloadStatus(self):
        """返回下载/搜索状态文字（QML 可绑定）"""
        return self._download_status

    @Slot(str)
    def searchNetEase(self, keywords):
        """搜索网易云歌曲（后台线程执行，不阻塞 UI）"""
        if not keywords.strip():
            self._download_status = "请输入搜索关键词"
            self.downloadStatusChanged.emit()
            return
        self._download_status = f"正在搜索: {keywords}..."
        self.downloadStatusChanged.emit()
        # 递增代数：连续搜索 A→B 时，若 A 的结果晚于 B 到达，
        # _on_search_done 会凭代数丢弃 A 的过期结果，避免列表回退
        self._search_seq += 1
        seq = self._search_seq
        self._run_task(
            lambda: search_songs(keywords),
            lambda ok, res: self._on_search_done(seq, ok, res),
        )

    def _on_search_done(self, seq, ok, result):
        """搜索完成回调（GUI 线程）"""
        if seq != self._search_seq:
            return  # 期间发起了新的搜索，丢弃过期结果
        if ok:
            self._search_results = result
            self._download_status = f"找到 {len(result)} 首歌曲"
        else:
            # 与"找到 0 首"区分：网络/风控失败给出明确提示
            self._search_results = []
            if isinstance(result, NeteaseAPIError):
                self._download_status = f"搜索失败：{result}"
            else:
                self._download_status = f"搜索失败: {result}"
        self.searchResultModelChanged.emit()
        self.downloadStatusChanged.emit()

    @Slot("qlonglong", str)
    def downloadLyric(self, song_id, current_path):
        """下载歌词到当前歌曲目录（后台线程执行，不阻塞 UI）

        注意 song_id 必须用 64 位（qlonglong）：网易歌曲 id 普遍大于
        2^31-1，QML 传递时若用 32 位 int 会被截断成负数（如
        2684112479 → -1610854817），接口对负 id 返回"暂无歌词"占位文本。
        """
        if not current_path:
            self._download_status = "没有当前播放歌曲"
            self.downloadStatusChanged.emit()
            return
        target_path = str(_to_path(current_path))
        self._download_status = "正在下载歌词..."
        self.downloadStatusChanged.emit()
        self._run_task(
            lambda: save_lyric_file(song_id, target_path),
            lambda ok, res: self._on_lyric_downloaded(ok, res, target_path),
        )

    def _on_lyric_downloaded(self, ok, result, target_path):
        """歌词下载完成回调（GUI 线程）"""
        if ok and result:
            self._download_status = f"歌词已保存: {Path(result).name}"
            # 下载期间可能已切歌，仅当目标仍是当前播放歌曲时才重载歌词
            if 0 <= self._current_index < len(self._songs) \
                    and self._songs[self._current_index]["path"] == target_path:
                self._load_lyrics()
        elif ok:
            self._download_status = "未找到歌词"
        else:
            self._download_status = f"下载歌词失败: {result}"
        self.downloadStatusChanged.emit()

    @Slot(str, str, "qlonglong")
    def downloadCover(self, pic_url, current_path, song_id=0):
        """下载封面图片到当前歌曲目录（后台线程执行，不阻塞 UI）

        song_id 同 downloadLyric，必须用 64 位：搜索结果的 picUrl 为空时
        要靠 get_netease_detail(song_id) 兜底，32 位截断后负 id 会让
        详情接口返回 None，封面下载随之失败。
        """
        if not current_path:
            self._download_status = "没有当前播放歌曲"
            self.downloadStatusChanged.emit()
            return
        target_path = str(_to_path(current_path))
        self._download_status = "正在下载封面..."
        self.downloadStatusChanged.emit()
        self._run_task(
            lambda: save_cover_file(song_id, pic_url, target_path),
            lambda ok, res: self._on_cover_downloaded(ok, res, target_path),
        )

    def _on_cover_downloaded(self, ok, result, target_path):
        """封面下载完成回调（GUI 线程）"""
        if ok and result:
            self._download_status = f"封面已保存: {Path(result).name}"
            # 按路径匹配目标歌曲（下载期间可能已切歌，不能只依赖 currentIndex）
            for i, song in enumerate(self._songs):
                if song["path"] == target_path:
                    song["image"] = result
                    self.songChanged.emit(i)
                    # 重新下载会覆盖同路径的旧封面：路径字符串不变，QML 的
                    # Image source 绑定不会重算，Qt 图片缓存也不会重载。
                    # 这里发出专门信号，让 QML 提升版本号强制刷新。
                    self.coverFileUpdated.emit(result)
                    break
        elif ok:
            self._download_status = "未找到封面"
        else:
            self._download_status = f"下载封面失败: {result}"
        self.downloadStatusChanged.emit()

    # ========== 后台任务调度 ==========

    def _run_task(self, fn, on_done):
        """在守护线程中执行 fn（阻塞式 I/O/网络操作），完成后在 GUI 线程回调 on_done(ok, result)。

        线程中 emit 的 Qt 信号因接收者（_task_signals 的父对象，即本播放器）
        位于 GUI 线程而自动排队投递，因此 on_done 一定在主线程执行，
        可以安全操作 UI 状态。
        """
        self._task_counter += 1
        task_id = self._task_counter
        self._task_callbacks[task_id] = on_done

        def worker():
            try:
                result = fn()
                ok = True
            except Exception as e:
                ok, result = False, e
            # 应用退出时 AudioPlayer 可能先于线程被销毁，此时 emit 会抛
            # RuntimeError: Signal source has been deleted（实测可复现）。
            # 守护线程随进程结束，直接忽略即可，避免退出时刷 traceback。
            try:
                self._task_signals.finished.emit(task_id, ok, result)
            except RuntimeError:
                pass

        threading.Thread(target=worker, daemon=True).start()

    def _on_task_finished(self, task_id, ok, result):
        """后台任务完成（GUI 线程）：取出并执行对应回调。"""
        cb = self._task_callbacks.pop(task_id, None)
        if cb is not None:
            cb(ok, result)

    # ========== 内部排序 ==========

    def _sort_songs(self):
        """根据当前排序模式对歌曲列表排序，保持当前播放歌曲索引"""
        current_path = None
        if 0 <= self._current_index < len(self._songs):
            current_path = self._songs[self._current_index]["path"]

        if self._sort_mode == 0:
            self._songs.sort(key=lambda s: s["name"].lower())
        elif self._sort_mode == 1:
            self._songs.sort(key=lambda s: s["name"].lower(), reverse=True)
        elif self._sort_mode == 2:
            self._songs.sort(key=lambda s: s["mtime"])
        elif self._sort_mode == 3:
            self._songs.sort(key=lambda s: s["mtime"], reverse=True)

        # 先通知列表已变更，让 ListView 重建模型
        self._song_list_model_cache = None
        self.songListChanged.emit()

        # 再恢复当前播放歌曲的索引
        if current_path:
            for i, song in enumerate(self._songs):
                if song["path"] == current_path:
                    if i != self._current_index:
                        self._current_index = i
                        self.songChanged.emit(i)
                    break

    def _start_metadata_enrichment(self):
        """后台异步提取所有歌曲的标题/作者元数据，完成后回填列表并重新排序。

        启动时同步跑 ffprobe 会导致大曲库长时间卡死 UI，所以先快速建列表，
        再在后台线程批量补全元数据。回写时按路径匹配，即使期间切换了目录
        或排序，也不会把结果错填到别的歌曲上。
        """
        snapshot = [(i, s["path"]) for i, s in enumerate(self._songs)]
        if not snapshot:
            return

        def work():
            return [(i, path, build_song_name(path)) for i, path in snapshot]

        self._run_task(work, self._on_metadata_enriched)

    def _on_metadata_enriched(self, ok, result):
        """元数据补全完成回调（GUI 线程）"""
        if not ok:
            return
        changed = False
        current_name_changed = False
        for i, path, name in result:
            if 0 <= i < len(self._songs) and self._songs[i]["path"] == path \
                    and name and self._songs[i]["name"] != name:
                self._songs[i]["name"] = name
                changed = True
                if i == self._current_index:
                    current_name_changed = True
        if changed:
            self._sort_songs()
            # 当前歌曲显示名也变了：补发 songChanged，否则 currentSongName
            # （notify=songChanged）不会刷新，左侧曲名与列表会不一致。
            if current_name_changed:
                self.songChanged.emit(self._current_index)

    # ========== ffplay 进程管理 ==========

    def _kill_process(self):
        """终止当前 ffplay 进程并清理资源"""
        self._cancel_fade()
        old_process = self._process
        if old_process:
            # Disconnect the finished signal to prevent side effects
            try:
                old_process.finished.disconnect(self._on_ffplay_finished)
            except Exception:
                pass
            if old_process.state() == QProcess.Running:
                pid = old_process.processId()
                if pid > 0:
                    # 先发 SIGTERM 再发 SIGCONT：进程若处于 SIGSTOP 挂起态，
                    # SIGTERM 会挂起为 pending，随后的 SIGCONT 唤醒时内核立即
                    # 投递 SIGTERM 使其终止，不会恢复执行——之前顺序相反
                    # （先 SIGCONT 后 SIGTERM），唤醒与终止之间 ffplay 会短暂
                    # 恢复出声，表现为"点退出时突然播放一下"
                    try:
                        os.kill(pid, signal.SIGTERM)
                    except OSError:
                        pass
                    try:
                        os.kill(pid, signal.SIGCONT)
                    except OSError:
                        pass
                old_process.terminate()
                if not old_process.waitForFinished(500):
                    old_process.kill()
                    old_process.waitForFinished(300)
            # QProcess 没有 parent：引用一旦被替换就只有 Python 侧回收，
            # 显式 deleteLater 让 Qt 事件循环确定性地销毁 C++ 对象
            old_process.deleteLater()
        self._process = None
        # 进程已死，pid 缓存随之失效
        self._sink_id_cache.clear()
        self._last_child_pid = None

    def _run_pactl(self, args, callback, timeout_ms=6000):
        """非阻塞执行 pactl 命令（QProcess，不阻塞 GUI 线程）。

        完成/超时后在主线程回调 callback(returncode, stdout_text)；
        returncode < 0 表示超时被杀或启动失败。
        """
        proc = QProcess()
        proc.setProcessChannelMode(QProcess.SeparateChannels)
        timer = QTimer(proc)
        timer.setSingleShot(True)
        timer.timeout.connect(proc.kill)
        timer.start(timeout_ms)

        def _done(code):
            if proc not in self._pactl_procs:
                return
            self._pactl_procs.pop(proc, None)
            out = bytes(proc.readAllStandardOutput()).decode("utf-8", "replace")
            callback(code, out)

        proc.finished.connect(_done)
        proc.start(args[0], args[1:])
        self._pactl_procs[proc] = True

    def _prewarm_pa(self):
        """启动时后台探测 PA 可用性，避免首次播放/退出时同步阻塞"""
        def done(rc, out):
            self._pa_available = rc == 0
        self._run_pactl(["pactl", "info"], done)

    def _check_pa_available(self):
        """检查系统是否有可用的 PulseAudio/PipeWire（读缓存，不阻塞）

        实际探测由 _prewarm_pa 在启动时异步完成；此处仅返回缓存值。
        缓存仍为 None（探测未完成）时返回 True 并按 PA 路径处理，
        音量纠正的失败分支会回退到 ffplay 自身音量。
        """
        if self._pa_available is None:
            return True
        return self._pa_available

    def _find_sink_input_id(self, pid, callback=None):
        """异步查找指定 pid 的 PulseAudio sink-input index。

        结果按 pid 缓存；同一 pid 的并发查找会合并（只发一次 pactl）。
        完成后在主线程回调 callback(index 或 None)。"""
        cached = self._sink_id_cache.get(pid)
        if cached is not None:
            if callback:
                callback(cached)
            return
        if pid in self._sink_pending:
            if callback:
                self._sink_pending[pid].append(callback)
            return
        self._sink_pending[pid] = [callback] if callback else []

        def done(rc, out):
            callbacks = self._sink_pending.pop(pid, [])
            sink = None
            if rc == 0 and out.strip():
                try:
                    inputs = json.loads(out)
                except ValueError:
                    inputs = None
                if inputs is not None:
                    if _VERBOSE:
                        _log("PA", "sink-inputs 共 %d 个，查找目标 pid=%s"
                             % (len(inputs), pid))
                    for inp in inputs:
                        props = inp.get("properties", {})
                        ipid = props.get("application.process.id")
                        if _VERBOSE:
                            _log("PA", "  sink=%s name=%s pid=%s"
                                 % (inp.get("index"), props.get("application.name"), ipid))
                        if ipid == str(pid):
                            sink = inp["index"]
                            break
            if sink is None:
                # pactl 失败或 sink 未注册：AppImage 下捆绑 ffplay 若未走
                # PulseAudio（SDL 回退 ALSA），这里就永远找不到 → 淡入淡出失效
                _log("PA", "pid=%s 未找到 sink-input (rc=%s) — 淡入淡出将走硬切换"
                     % (pid, rc))
                self._pa_available = None  # pactl 失败或 sink 未注册，下次重新探测
            else:
                _log("PA", "pid=%s → sink=%s" % (pid, sink))
                self._sink_id_cache[pid] = sink
            for cb in callbacks:
                if cb:
                    cb(sink)

        self._run_pactl(["pactl", "-f", "json", "list", "sink-inputs"], done)

    def _adjust_volume_pa(self, callback=None):
        """异步通过 PulseAudio/PipeWire 无缝调节音量（不中断播放，不阻塞）。

        完成后在主线程回调 callback(ok)；ok=False 表示无 PA/sink 未注册，
        调用方应回退到 ffplay 重启方案。"""
        if not self._process or self._process.state() != QProcess.Running:
            if callback:
                callback(False)
            return
        pid = self._process.processId()
        if not pid:
            if callback:
                callback(False)
            return

        def on_sink(sink_id):
            if sink_id is None:
                if callback:
                    callback(False)
                return
            pa_vol = int(self._volume / 100.0 * 65536)
            def on_set(rc, out):
                if rc == 0:
                    if callback:
                        callback(True)
                else:
                    self._pa_available = None
                    if callback:
                        callback(False)
            self._run_pactl(["pactl", "set-sink-input-volume", str(sink_id), str(pa_vol)], on_set)

        self._find_sink_input_id(pid, on_sink)

    def _pa_set_volume(self, pid, pa_vol, gen=None):
        """异步设置指定进程的 PA 音量（不阻塞，fire-and-forget）。

        gen 为淡出代数：与当前 _fade_generation 不一致时丢弃（过期命令）。
        """
        def on_sink(sink_id):
            if sink_id is None:
                self._pa_available = None
                return
            if gen is not None and gen != self._fade_generation:
                return  # 淡出已被取消/替换，丢弃在途命令
            def on_set(rc, out):
                if rc != 0:
                    _log("淡出", "set-sink-input-volume 失败 rc=%s (sink=%s vol=%d)"
                         % (rc, sink_id, pa_vol))
            self._run_pactl(["pactl", "set-sink-input-volume", str(sink_id), str(pa_vol)], on_set)

        self._find_sink_input_id(pid, on_sink)

    def _cancel_fade(self):
        """取消进行中的音量渐变（切歌/停止/seek 时调用）"""
        if self._fade_direction is not None:
            self._fade_timer.stop()
            self._fade_direction = None
        # 递增代数，使所有在途的过期 pactl 音量命令失效
        self._fade_generation += 1

    def setQuitCallback(self, callback):
        """注入退出回调（quit_app）：退出淡出完成后调用"""
        self._quit_callback = callback

    @Slot()
    def fadeOutQuit(self):
        """退出淡出：PA 音量 300ms 平滑降到 0 后终止进程并触发退出回调。

        PA 不可用/无运行进程时直接退出（无淡出可做）。
        sink 查找为异步，不阻塞 GUI 线程（PA 响应慢也不会卡住退出）。
        """
        if not self._quit_callback:
            self.cleanup()
            return
        # 若正在暂停淡出/淡入，先取消再走退出淡出
        if self._fade_direction is not None:
            self._cancel_fade()

        def on_done(ok):
            if ok:
                return  # 完成后在 _on_fade_tick 的 "quit" 分支继续
            self.cleanup()
            if self._quit_callback:
                self._quit_callback()

        self._start_fade("quit", duration_ms=300, on_done=on_done)

    def _start_fade(self, direction, duration_ms=250, on_done=None):
        """开始 PA 音量渐变：out=淡出到 0（暂停），in=淡入（恢复），
        quit=淡出到 0 后终止进程并退出。

        duration_ms: 渐变时长（默认 250，退出淡出用 300）。
        sink 查找为异步；完成后回调 on_done(True/False)：False 表示
        PA 不可用/sink 未注册/进程已切换（调用方应走硬切逻辑）。
        """
        if not self._process or self._process.state() != QProcess.Running:
            if on_done:
                on_done(False)
            return
        pid = self._process.processId()
        if not pid:
            if on_done:
                on_done(False)
            return

        def on_sink(sink_id):
            if sink_id is None:
                _log("淡出", "方向=%s: sink 未找到，走硬切换（无淡入淡出）" % direction)
                if on_done:
                    on_done(False)
                return
            # 查找期间进程可能已被切换/停止，此时不应启动渐变
            if self._process is None or self._process.processId() != pid:
                _log("淡出", "方向=%s: 查找期间进程已切换，放弃渐变" % direction)
                if on_done:
                    on_done(False)
                return
            self._fade_direction = direction
            self._fade_step = 0
            self._fade_total = max(1, round(duration_ms / self._fade_timer.interval()))
            self._fade_timer.start()
            if on_done:
                on_done(True)

        self._find_sink_input_id(pid, on_sink)

    def _on_fade_tick(self):
        """渐变定时器：每 30ms 异步调一次 PA 音量，到终点执行挂起/恢复"""
        if self._fade_direction is None:
            self._fade_timer.stop()
            return
        if not self._process or self._process.state() != QProcess.Running:
            self._cancel_fade()
            return
        pid = self._process.processId()
        self._fade_step += 1
        t = self._fade_step / self._fade_total
        if self._fade_direction == "in":
            pa_vol = int(self._volume / 100.0 * 65536 * t)
        else:
            # "out"(暂停淡出) 与 "quit"(退出淡出) 都是淡出到 0
            pa_vol = int(self._volume / 100.0 * 65536 * (1.0 - t))
        gen = self._fade_generation
        # pactl 上一个命令还在跑（如 AppImage 冷启动/系统繁忙导致 fork 变慢）时
        # 跳过本步下发，避免 QProcess 堆积加重主线程负担；t 仍按步数推进，
        # 最后一格（t=1）必然下发终点音量并收尾
        if self._pactl_procs:
            if t >= 1.0:
                self._fade_timer.stop()
                direction = self._fade_direction
                self._fade_direction = None
                self._fade_generation += 1
                if direction == "quit":
                    self._kill_process()
                    if self._quit_callback:
                        self._quit_callback()
                elif direction == "out":
                    try:
                        os.kill(pid, signal.SIGSTOP)
                    except OSError:
                        pass
                    self._pause_time = self._get_current_time()
                    self._state = "paused"
                    self.stateChanged.emit("paused")
                    self._position_timer.stop()
            return
        self._pa_set_volume(pid, pa_vol, gen)
        if t >= 1.0:
            self._fade_timer.stop()
            direction = self._fade_direction
            self._fade_direction = None
            self._fade_generation += 1  # 丢弃任何在途的过期命令
            if direction == "quit":
                # 退出淡出完成：音量已近 0，终止进程并触发退出回调
                self._kill_process()
                if self._quit_callback:
                    self._quit_callback()
            elif direction == "out":
                # 淡出完成：音量已近 0，挂起进程并转暂停态
                try:
                    os.kill(pid, signal.SIGSTOP)
                except OSError:
                    pass
                self._pause_time = self._get_current_time()
                self._state = "paused"
                self.stateChanged.emit("paused")
                self._position_timer.stop()
            # "in" 完成：音量已到当前值，无需额外动作（state 已 playing）

    def _retry_pa_volume(self, process_ref, attempt):
        """异步、不阻塞地重试将 PA 音量纠正到当前设置值。

        ffplay 启动初期 sink-input 尚未在 PulseAudio 中注册是正常现象，
        所以第一次尝试失败很常见。只要 process_ref 仍是当前正在播放的
        进程（用户没有切歌/停止），就按递增间隔继续尝试，直到成功或
        达到最大次数为止，从而避免"音量条50%实际播放100%"的问题。
        """
        # 进程已经被切换/停止，放弃重试
        if process_ref is not self._process:
            return
        # Starting 状态视为可重试：ffplay 可能还没完成启动（不再有
        # waitForStarted 兜底），只有 NotRunning 才彻底放弃
        if process_ref.state() == QProcess.NotRunning:
            return

        def on_result(ok):
            if ok:
                return  # 成功，音量已纠正
            if process_ref is not self._process:
                return
            if process_ref.state() == QProcess.NotRunning:
                return
            max_attempts = 8
            if attempt >= max_attempts:
                return
            delay_ms = min(50 * (attempt + 1), 400)
            QTimer.singleShot(delay_ms, lambda: self._retry_pa_volume(process_ref, attempt + 1))

        self._adjust_volume_pa(on_result)

    def _start_ffplay(self, filepath, seek_to=0.0, use_pa=None):
        """启动 ffplay 进程播放指定音频文件，支持从指定位置开始播放

        Args:
            use_pa: None=自动检测, True=强制使用 PA, False=不使用 PA
        """
        self._kill_process()
        self._process = QProcess()
        # ffplay stderr 直接转发到终端（不拦截不过滤）：横幅/元数据/错误
        # 原样可见，方便排查。需要按行捕获时改回 SeparateChannels +
        # readyReadStandardError。
        self._process.setProcessChannelMode(QProcess.ForwardedErrorChannel)

        if use_pa is None:
            use_pa = self._check_pa_available()

        if use_pa:
            # 有 PulseAudio 时，ffplay 固定 100% 音量，由 PA 直接控制
            vol = 100
        else:
            vol = self._volume

        args = [
            "ffplay",
            "-nodisp",
            "-autoexit",
        ]
        # 一律加 -nostats 关闭 ffplay 每 0.1s 的进度刷屏：这条输出经
        # QProcess 转发，在 AppImage 下会加重主线程/管道负担（实测位置
        # 定时器被拖到 1.5s 一次）。错误信息不受影响。需要调试进度时可
        # 设 PYMUSIC_FFPLAY_STATS=1 临时打开。
        if os.environ.get("PYMUSIC_FFPLAY_STATS") != "1":
            args.append("-nostats")
        args += [
            "-volume", str(vol),
            "-ss", str(seek_to),
            filepath,
        ]
        self._process.start("ffplay", args[1:])
        # 记录实际使用的 ffplay 路径（AppImage 下应是捆绑的 bin/ffplay）
        import shutil as _shutil
        _ffp = _shutil.which("ffplay")
        _log("播放", "启动 ffplay: %s (args: -ss %s)" % (_ffp or "?", seek_to))
        # 不调用 waitForStarted()：它会阻塞 GUI 线程最多 500ms，
        # 正是切歌时"轻微卡顿"的来源之一。进程启动交给事件循环处理，
        # PA 音量纠正本来就是异步重试，不受影响。
        self._process.finished.connect(self._on_ffplay_finished)
        self._process.started.connect(self._on_process_started)

        if use_pa:
            # ffplay 以 100% 启动，需要靠 PA 把音量纠正到用户设置的值。
            # sink-input 在 ffplay 打开音频设备前不会出现在 pactl 列表里，
            # 单次同步尝试常常因为这个时序问题而失败，之前失败后就不再重试，
            # 导致 ffplay 一直用启动时的 100% 音量播放，而界面滑块显示的却是
            # 用户设置的音量（比如 50%）——这就是"滑块50%等于实际100%"的原因。
            # 这里改为异步、多次、递增间隔地重试，直到成功把 PA 音量纠正过来，
            # 且不阻塞 UI 线程。
            this_process = self._process
            self._retry_pa_volume(this_process, attempt=0)

        # 异步获取时长与歌词，避免 ffprobe 阻塞 UI
        self._duration = 0.0
        self.durationChanged.emit(self._duration)
        self._async_load_metadata(filepath)
        self._load_lyrics()

        self._seek_base = seek_to
        self._play_start_time = self._get_current_time()
        self._total_paused_duration = 0.0
        self._timer_last_fire = 0.0  # 重置滞后基准（避免把暂停时长误计为滞后）
        self._position_timer.start()

    def _on_process_started(self):
        """记录 ffplay 子进程 pid（供 SIGSEGV 处理器做最小化清理）"""
        if self._process and self._process.state() != QProcess.NotRunning:
            pid = self._process.processId()
            if pid > 0:
                self._last_child_pid = pid

    def _async_load_metadata(self, filepath):
        """后台线程加载歌曲时长（ffprobe），完成后在 GUI 线程回调。

        旧实现虽然名字叫 async，实际是在 GUI 线程同步 subprocess.run，
        ffprobe 冷启动 50~200ms，正是切歌卡顿的主因。
        """
        self._run_task(
            lambda: self._get_duration(filepath),
            lambda ok, res: self._on_duration_loaded(filepath, ok, res),
        )

    def _on_duration_loaded(self, filepath, ok, duration):
        """时长加载完成（GUI 线程）：仅当仍是当前歌曲时才应用"""
        if ok and 0 <= self._current_index < len(self._songs) \
                and self._songs[self._current_index]["path"] == filepath:
            self._duration = float(duration) if duration else 0.0
            # 恢复的 lastPosition 越过实际时长时（文件被替换成更短的），
            # 未播放状态下直接钳制并同步进度条，避免 play 时 -ss 越过结尾
            if self._state == "stopped" and self._duration > 0 \
                    and self._position > self._duration:
                self._position = max(0.0, self._duration - 0.5)
                self.positionChanged.emit(self._position)
            self.durationChanged.emit(self._duration)

    def _get_current_time(self):
        """获取当前时间戳（用于计算播放进度）。

        用 time.monotonic() 而不是 time.time()：播放进度是相对时长计算，
        系统时钟被 NTP 校准/手动修改时 time.time() 会跳变，导致进度条
        和暂停时长补偿出现瞬间前跳/回退；monotonic 不受系统时钟影响。
        """
        return time.monotonic()

    def _get_duration(self, filepath):
        """通过 ffprobe 获取音频文件时长"""
        try:
            result = subprocess.run(
                ["ffprobe", "-v", "error", "-show_entries",
                 "format=duration", "-of", "default=noprint_wrappers=1:nokey=1",
                 filepath],
                capture_output=True, text=True, timeout=10
            )
            if result.stdout.strip():
                return float(result.stdout.strip())
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
        return 0.0

    def _update_position(self):
        """定时更新播放进度位置，触发信号通知 QML"""
        if self._state == "playing":
            now = time.monotonic()
            # 滞后探针：实际触发间隔显著超过 250ms 说明主线程被渲染/其他
            # 工作阻塞，歌词索引与进度条更新都会跟着延后
            if self._timer_last_fire:
                gap_ms = (now - self._timer_last_fire) * 1000
                lag = max(0.0, gap_ms - 250.0)
                if lag > 100:
                    self._timer_slow_count += 1
                    self._timer_max_lag = max(self._timer_max_lag, lag)
                    self._timer_lag_total += lag
                    if self._timer_slow_count <= 5 or self._timer_slow_count % 20 == 0:
                        _log("性能", "位置定时器滞后 %.0fms (实际间隔 %.0fms, 期望 250ms)"
                             % (lag, gap_ms))
            self._timer_last_fire = now

            elapsed = self._get_current_time() - self._play_start_time - self._total_paused_duration
            # 时长未知（异步 ffprobe 还没返回）时先不 clamp，避免进度条卡在 0
            if self._duration > 0:
                self._position = min(self._seek_base + elapsed, self._duration)
            else:
                self._position = self._seek_base + elapsed
            self.positionChanged.emit(self._position)
            self._update_lyric_index()

    def _on_ffplay_finished(self, exit_code, exit_status):
        """ffplay 进程结束时自动切换到下一曲"""
        self._position_timer.stop()
        # 只处理自然退出（我们自己杀进程切歌时已提前断开本信号）
        if self._state == "stopped":
            return

        # 退出码非 0 / 非正常退出：ffplay 启动失败（ffplay 不存在）、文件损坏、
        # 解码失败或被外部杀死。此时若继续自动切歌，会在坏文件之间无限循环；
        # 之前这里直接 return，UI 会永远停留在"播放中"而实际没有进程在放。
        # 改为转入 stopped 状态并通知 UI，让播放键回到可重新播放的状态。
        if exit_status != QProcess.NormalExit or exit_code != 0:
            _log_warn("播放", "ffplay 异常退出 code=%s status=%s，转入 stopped"
                      % (exit_code, exit_status))
            self._state = "stopped"
            self.stateChanged.emit("stopped")
            return

        # 时长已知时按播放进度判断是否接近结尾；时长未知（异步 ffprobe 还没
        # 返回，_duration 为 0）时按实际播放时长判断——否则
        # "position >= duration - 1.0" 在 duration 为 0 时恒成立，
        # 会在一开始播放就误触发切歌。
        if self._duration > 0:
            near_end = self._position >= self._duration - 1.0
        else:
            elapsed = self._get_current_time() - self._play_start_time - self._total_paused_duration
            near_end = elapsed >= 1.0
        if near_end:
            self._handle_song_finished()
            return

        # 正常退出（exit 0）却没到结尾：ffplay 遇到损坏/截断文件会静默正常退出
        # （实测 exit code 仍为 0），此时若不做处理，UI 会永远停在"播放中"、
        # 进度条冻结且没有声音。转入 stopped 让播放键恢复可用。
        self._state = "stopped"
        self.stateChanged.emit("stopped")

    @Slot()
    def play(self):
        """开始播放当前歌曲"""
        if len(self._songs) == 0:
            return
        if self._current_index < 0:
            self._current_index = 0
            self.songChanged.emit(0)

        # 恢复的 lastPosition 可能超过当前文件时长（文件被替换成更短的），
        # 直接 -ss 越过结尾会让 ffplay 立即退出、near_end 误判自动切歌。
        # 播放前钳制到时长内。
        if self._duration > 0 and self._position > self._duration:
            self._position = max(0.0, self._duration - 0.5)
            self.positionChanged.emit(self._position)

        filepath = self._songs[self._current_index]["path"]
        _log("播放", "play: idx=%d pos=%.2fs file=%s" % (self._current_index, self._position, filepath))
        self._start_ffplay(filepath, self._position)
        self._state = "playing"
        self.stateChanged.emit("playing")

    @Slot()
    def pause(self):
        """暂停当前播放（通过 SIGSTOP 暂停 ffplay 进程）

        有 PulseAudio 时先做 250ms 平滑淡出（音量降到 0 后再 SIGSTOP，
        避免瞬间无声）；无 PA 时退回直接挂起。

        ffplay 可能仍处于 Starting 状态（启动中）：此时直接 SIGSTOP 无效。
        把暂停动作挂到 started 信号上，进程真正起来后再立刻挂起；
        _pause_time 也在真正挂起的那一刻记录，保证 resume() 计算的
        暂停时长准确。
        """
        if self._state != "playing":
            return
        if self._fade_direction == "out":
            return  # 正在淡出中，忽略重复暂停
        if self._process and self._process.state() == QProcess.Running:
            pid = self._process.processId()
            if pid > 0:
                # PA 可用时平滑淡出；淡出完成回调里才 SIGSTOP + 转 paused。
                # sink 查找异步（不阻塞 GUI）；失败则立即硬暂停。
                def on_fade_out(ok):
                    if ok:
                        return  # 淡出完成回调里转 paused
                    try:
                        os.kill(pid, signal.SIGSTOP)
                    except OSError:
                        pass
                    self._pause_time = self._get_current_time()
                    self._state = "paused"
                    self.stateChanged.emit("paused")
                    self._position_timer.stop()

                self._start_fade("out", on_done=on_fade_out)
                return
        elif self._process and self._process.state() == QProcess.Starting:
            self._process.started.connect(self._pause_new_process)
        self._state = "paused"
        self.stateChanged.emit("paused")
        self._position_timer.stop()

    @Slot()
    def resume(self):
        """恢复播放（通过 SIGCONT 继续 ffplay 进程）

        有 PulseAudio 时 SIGCONT 后做 250ms 平滑淡入（音量 0→当前值），
        期间 UI 立即恢复播放态；无 PA 时直接出声。
        """
        if self._state != "paused":
            return
        if self._fade_direction == "in":
            return  # 正在淡入中，忽略重复恢复
        # 进程已挂起时才 SIGCONT 并补偿暂停时长；
        # 进程还在启动中（Starting，_pause_new_process 尚未触发）时跳过补偿。
        if self._process and self._process.state() == QProcess.Running:
            pid = self._process.processId()
            if pid > 0:
                os.kill(pid, signal.SIGCONT)
                self._total_paused_duration += self._get_current_time() - self._pause_time
                # PA 平滑淡入；失败（无 PA/sink 未注册）则直接出声
                self._start_fade("in")
        self._state = "playing"
        self.stateChanged.emit("playing")
        self._timer_last_fire = 0.0  # 重置滞后基准（避免把暂停时长误计为滞后）
        self._position_timer.start()

        # 应用暂停期间累积但未生效的音量变更。
        # 淡入进行中时跳过：渐变结束时音量已经是 _volume，无需再调整
        if self._volume_dirty:
            if self._fade_direction is None:
                def on_dirty_result(ok):
                    self._volume_dirty = False
                    if ok:
                        return
                    elapsed = self._get_current_time() - self._play_start_time - self._total_paused_duration
                    pos = max(0.0, self._seek_base + elapsed)
                    # 时长未知（异步 ffprobe 还没返回）时不能按 0 clamp，否则会从头播放
                    if self._duration > 0:
                        pos = min(pos, self._duration)
                    filepath = self._songs[self._current_index]["path"] if 0 <= self._current_index < len(self._songs) else None
                    if filepath:
                        self._start_ffplay(filepath, pos, use_pa=False)
                        self._state = "playing"
                        self.stateChanged.emit("playing")

                self._adjust_volume_pa(on_dirty_result)
            else:
                self._volume_dirty = False

    @Slot()
    def playPause(self):
        """播放/暂停切换（QML 播放按钮绑定）"""
        if self._state == "playing":
            self.pause()
        elif self._state == "paused":
            self.resume()
        else:
            self.play()

    @Slot()
    def stop(self):
        """停止播放并重置进度"""
        _log("播放", "stop")
        self._kill_process()
        self._position_timer.stop()
        self._position = 0.0
        self._state = "stopped"
        self.stateChanged.emit("stopped")
        self.positionChanged.emit(0.0)

    @Slot()
    def next(self):
        """切换到下一首歌曲"""
        self._switch_song(1)

    @Slot()
    def previous(self):
        """切换到上一首歌曲"""
        self._switch_song(-1)

    def _push_play_history(self):
        """记录当前歌曲到随机播放历史（供"上一首"回退）"""
        if self._current_index >= 0:
            self._play_history.append(self._current_index)
            if len(self._play_history) > 50:
                self._play_history.pop(0)

    def _handle_song_finished(self):
        """歌曲自然播放结束：按播放模式决定后续行为

        0=顺序：自动切到下一首（列表尾回到头）
        1=单曲循环：重新播放当前歌曲
        2=随机：随机选一首不同的歌曲播放
        """
        n = len(self._songs)
        if n == 0:
            return
        if self._current_index < 0:
            # 无有效当前歌曲：按顺序从第一首开始
            self._switch_song(1)
            return
        if self._play_mode == 1:
            # 单曲循环：从 0 重新播放当前歌曲
            self._position = 0.0
            self.positionChanged.emit(0.0)
            if self._state != "stopped":
                filepath = self._songs[self._current_index]["path"]
                self._start_ffplay(filepath, 0.0)
                self._state = "playing"
                self.stateChanged.emit("playing")
        elif self._play_mode == 2:
            # 随机：避免与当前歌曲重复，当前歌曲记入历史
            candidates = [i for i in range(n) if i != self._current_index]
            if not candidates:
                return
            self._push_play_history()
            self._current_index = random.choice(candidates)
            self.songChanged.emit(self._current_index)
            self._position = 0.0
            self.positionChanged.emit(0.0)
            if self._state != "stopped":
                filepath = self._songs[self._current_index]["path"]
                self._start_ffplay(filepath, 0.0)
                self._state = "playing"
                self.stateChanged.emit("playing")
        else:
            # 顺序播放：切到下一首（原逻辑）
            self.next()

    def _switch_song(self, delta):
        """按 delta 切换歌曲（+1 下一首 / -1 上一首），并在非停止状态下自动播放

        随机模式（playMode==2）下手动切歌也遵循随机：下一首=随机选一首
        不同的，上一首=回退到最近播放过的歌曲（无历史则随机）——否则
        随机模式只是"自然播放结束"随机、按键却是顺序，行为不一致。
        """
        if len(self._songs) == 0:
            return
        if self._play_mode == 2:
            if delta > 0:
                # 下一首：记录当前到历史，随机选一首不同的
                self._push_play_history()
                if self._current_index < 0:
                    self._current_index = random.randrange(len(self._songs))
                else:
                    candidates = [i for i in range(len(self._songs)) if i != self._current_index]
                    self._current_index = random.choice(candidates)
            else:
                # 上一首：回退到历史（无历史则随机选一首不同的）
                if self._play_history:
                    self._current_index = self._play_history.pop()
                else:
                    candidates = [i for i in range(len(self._songs)) if i != self._current_index]
                    self._current_index = random.choice(candidates) if candidates else 0
        else:
            # 顺序/单曲循环：手动切歌保持顺序（单曲循环只影响自然播放结束）
            if self._current_index < 0:
                # 尚未选择歌曲：下一首从第一首开始，上一首从最后一首开始
                # （(-1 + -1) % n 会得到 n-2，直接取模是错的）
                self._current_index = len(self._songs) - 1 if delta < 0 else 0
            else:
                self._current_index = (self._current_index + delta) % len(self._songs)
        self.songChanged.emit(self._current_index)
        self._position = 0.0
        self.positionChanged.emit(0.0)  # 立即刷新进度条，不必等下一次 250ms 定时器
        if self._state != "stopped":
            filepath = self._songs[self._current_index]["path"]
            self._start_ffplay(filepath, 0.0)
            self._state = "playing"
            self.stateChanged.emit("playing")

    @Slot(float)
    def seek(self, pos_seconds):
        """跳转到指定播放位置（秒）"""
        if self._current_index < 0:
            return
        # 时长未知时不按 0 clamp，否则进度会被错误压到 0
        if self._duration > 0:
            self._position = max(0.0, min(pos_seconds, self._duration))
        else:
            self._position = max(0.0, pos_seconds)
        # 立即同步 UI，不必等下一次 250ms 定时器
        self.positionChanged.emit(self._position)
        self._update_lyric_index()
        if self._state != "stopped":
            filepath = self._songs[self._current_index]["path"]
            was_playing = (self._state == "playing")
            self._start_ffplay(filepath, self._position)
            if was_playing:
                self._state = "playing"
                self.stateChanged.emit("playing")
            else:
                self._state = "paused"
                self.stateChanged.emit("paused")
                self._position_timer.stop()
                # ffplay 一启动就挂起（SIGSTOP）。不用 waitForStarted 阻塞等待，
                # 改由 started 信号触发，避免拖拽进度条时 UI 卡顿。
                if self._process:
                    self._process.started.connect(self._pause_new_process)

    @Slot()
    def seekDragStarted(self):
        """拖动进度条开始：停止播放进程，精确冻结当前位置。

        拖动期间不再按旧逻辑每次 mousemove 杀启一次 ffplay（拖一次
        进度条 = 几十次进程重启，是拖动卡顿的主因），改为开始拖动时
        停一次、松手时在目标位置起一次。
        """
        self._seek_drag_was_playing = (self._state == "playing")
        self._position_timer.stop()
        # 用单调时钟精确结算一次当前位置，此后位置完全由 UI 预览驱动
        if self._state == "playing":
            elapsed = self._get_current_time() - self._play_start_time - self._total_paused_duration
            pos = self._seek_base + elapsed
            if self._duration > 0:
                pos = min(pos, self._duration)
            self._position = max(0.0, pos)
            self.positionChanged.emit(self._position)
        if self._process:
            self._kill_process()
        if self._state != "stopped":
            self._state = "paused"
            self.stateChanged.emit("paused")

    @Slot(float)
    def seekPreview(self, pos):
        """拖动进度条过程中：只精确更新显示位置与歌词索引，不触碰播放进程"""
        if self._duration > 0:
            self._position = max(0.0, min(pos, self._duration))
        else:
            self._position = max(0.0, pos)
        self.positionChanged.emit(self._position)
        self._update_lyric_index()

    @Slot(float)
    def seekCommit(self, pos):
        """拖动结束：在目标位置恢复播放（拖动前在播）或保持暂停（拖动前暂停）"""
        resume_playing = self._seek_drag_was_playing
        self._seek_drag_was_playing = False
        if resume_playing and 0 <= self._current_index < len(self._songs):
            # 先切到"播放中"再走 seek() 的 was_playing 分支：
            # 重启进程并直接处于播放态，用 -ss 精确定位到松手位置
            self._state = "playing"
            self.stateChanged.emit("playing")
        self.seek(pos)

    def _pause_new_process(self):
        """seek/启动即暂停场景：ffplay 启动完成即刻挂起。仅当仍处于暂停态时生效，
        防止用户在 started 到达前点了播放导致误停新进程。

        挂起成功时同步记录 _pause_time——漏掉这一步的话，resume() 会用
        seek 之前旧的 _pause_time 累加 _total_paused_duration（该值已在
        _start_ffplay 里清零），造成暂停时长被重复计入、进度回跳。
        """
        if self._state != "paused" or not self._process:
            return
        if self._process.state() == QProcess.NotRunning:
            return
        pid = self._process.processId()
        if pid > 0:
            os.kill(pid, signal.SIGSTOP)
            self._pause_time = self._get_current_time()

    @Slot(int)
    def setVolume(self, vol):
        """设置音量（QML 滑块绑定）"""
        self.volume = vol

    @Slot(int, result=str)
    def formatTime(self, seconds):
        """将秒数格式化为 mm:ss 格式"""
        if seconds < 0:
            seconds = 0
        m = int(seconds // 60)
        s = int(seconds % 60)
        return f"{m:02d}:{s:02d}"

    @Property(str, notify=songChanged)
    def currentSongImage(self):
        """返回当前歌曲的封面图片路径（QML 可绑定）

        内嵌封面提取（ffmpeg，50~300ms）不再同步执行：首次访问时发起
        后台提取，完成后通过 songChanged 通知 QML 重新求值。提取失败
        的歌曲会被记住，避免反复空跑 ffmpeg。
        """
        if 0 <= self._current_index < len(self._songs):
            song = self._songs[self._current_index]
            if song["image"]:
                return song["image"]
            cached = self._embedded_cover_cache.get(song["path"], "")
            if cached:
                return cached
            # Lazy extract embedded image on demand (后台线程)
            self._request_embedded_cover(song["path"])
        return ""

    def _request_embedded_cover(self, song_path):
        """发起后台内嵌封面提取（同一首歌只发起一次）"""
        if song_path in self._pending_cover_extract \
                or song_path in self._embedded_cover_failed:
            return
        self._pending_cover_extract.add(song_path)
        self._run_task(
            lambda: extract_embedded_image(song_path),
            lambda ok, res: self._on_cover_extracted(song_path, ok, res),
        )

    def _on_cover_extracted(self, song_path, ok, result):
        """内嵌封面提取完成（GUI 线程）"""
        self._pending_cover_extract.discard(song_path)
        if not ok or not result:
            self._embedded_cover_failed.add(song_path)
            return
        self._embedded_cover_cache[song_path] = result
        if 0 <= self._current_index < len(self._songs) \
                and self._songs[self._current_index]["path"] == song_path:
            self.songChanged.emit(self._current_index)

    @Property(str, notify=songChanged)
    def currentSongName(self):
        """返回当前歌曲的显示名称（QML 可绑定）"""
        if 0 <= self._current_index < len(self._songs):
            return self._songs[self._current_index]["name"]
        return ""

    # ========== 播放列表折叠 ==========

    playlistVisibleChanged = Signal()

    @Property(bool, notify=playlistVisibleChanged)
    def playlistVisible(self):
        """返回播放列表是否可见（QML 可绑定）"""
        return self._playlist_visible

    @playlistVisible.setter
    def playlistVisible(self, visible):
        """设置播放列表折叠/展开状态"""
        if visible != self._playlist_visible:
            self._playlist_visible = visible
            self.playlistVisibleChanged.emit()

    # ========== 歌词相关 ==========

    def _load_lyrics(self, clear_first=True):
        """加载当前歌曲的歌词（后台线程执行）。

        内嵌歌词需要跑 ffprobe（每次 50~200ms），旧实现在 GUI 线程同步
        调用，是切歌卡顿的主因之一。现在先立刻清空旧歌词（避免新歌显示
        上一首的歌词），再后台加载，完成后回填。

        clear_first=False：不清空旧歌词直接重载（歌词时间戳调整后原地
        刷新，避免视图先回顶部再跳回造成弹跳）。
        """
        if clear_first:
            self._lyrics = []
            self._current_lyric_index = -1
            self.lyricsChanged.emit()
            self.lyricIndexChanged.emit(-1)
        if 0 <= self._current_index < len(self._songs):
            song_path = self._songs[self._current_index]["path"]
            self._run_task(
                lambda: self._read_lyrics(song_path),
                lambda ok, res: self._on_lyrics_loaded(song_path, ok, res),
            )

    def _read_lyrics(self, song_path):
        """后台线程：优先读取外部 LRC 文件，其次读取内嵌元数据"""
        lrc_path = find_matching_lyrics(song_path)
        if lrc_path:
            return parse_lrc(lrc_path)
        return extract_embedded_lyrics(song_path)

    @Slot(float)
    def shiftLyricTimestamps(self, delta):
        """整体平移当前歌曲 LRC 文件的时间戳（每次点击 ±0.3s），
        直接写回文件并立即重新加载刷新。

        无外部 LRC（内嵌歌词）时：把当前歌词按新时间写出为 <歌曲名>.lrc。
        """
        if not (0 <= self._current_index < len(self._songs)):
            return
        song_path = self._songs[self._current_index]["path"]
        song = _to_path(song_path)
        lrc_path = find_matching_lyrics(song_path)
        if lrc_path:
            lrc_path = _to_path(lrc_path)
            try:
                text = lrc_path.read_text(encoding="utf-8", errors="replace")
            except OSError as e:
                _log_warn("歌词", "读取 LRC 失败: %s (%s)" % (lrc_path, e))
                return
        else:
            # 内嵌歌词：从当前 _lyrics 生成 LRC（保留原文文本 + 新时间戳）
            lines = []
            for t, text_line, _raw in self._lyrics:
                ts = max(0.0, t + delta)
                mm = int(ts // 60)
                ss = ts - mm * 60
                lines.append("[%02d:%05.2f]%s" % (mm, ss, text_line))
            text = "\n".join(lines) + "\n"
            lrc_path = song.with_suffix(".lrc")
        try:
            lrc_path.write_text(shift_lrc_text(text, delta), encoding="utf-8")
            _log("歌词", "时间戳 %+.1fs 已写入 %s" % (delta, lrc_path))
        except OSError as e:
            _log_warn("歌词", "写入 LRC 失败: %s (%s)" % (lrc_path, e))
            return
        # 立即重新加载刷新：不清空旧歌词（否则视图先回顶部再跳回，多次
        # 调节会一直弹跳）；加载完成时按当前播放位置一次就位
        self._load_lyrics(clear_first=False)

    def _on_lyrics_loaded(self, song_path, ok, lyrics):
        """歌词加载完成（GUI 线程）：仅当仍是当前歌曲时才应用，避免快速
        切歌时旧歌词错填到新歌上。"""
        if ok and 0 <= self._current_index < len(self._songs) \
                and self._songs[self._current_index]["path"] == song_path:
            self._lyrics = lyrics or []
            # 立即按当前播放位置计算索引：让 QML 的 rebuildGroups+snapAll
            # 一次就位到当前行，避免"先回顶部再跳回"造成的弹跳
            self._current_lyric_index = self._find_lyric_index(self._lyric_lookup_position())
            _log("歌词", "加载完成: %d 行，当前行索引 %d"
                 % (len(self._lyrics), self._current_lyric_index))
            self.lyricsChanged.emit()
            self.lyricIndexChanged.emit(self._current_lyric_index)
        elif not ok:
            _log_debug("歌词", "加载失败或被跳过: %s" % song_path)

    @Property(int, notify=lyricsChanged)
    def lyricCount(self):
        """返回歌词行数（QML 可绑定）"""
        return len(self._lyrics)

    @Property(int, notify=lyricIndexChanged)
    def currentLyricIndex(self):
        """返回当前播放位置对应的歌词索引（QML 可绑定）"""
        return self._current_lyric_index

    @Property(float, notify=lyricIndexChanged)
    def currentLyricTime(self):
        """当前歌词行的时间戳，用于 QML 绑定追踪依赖。"""
        if 0 <= self._current_lyric_index < len(self._lyrics):
            return self._lyrics[self._current_lyric_index][0]
        return 0.0

    @Slot(int, result=str)
    def lyricText(self, index):
        """返回指定索引的歌词文本"""
        if 0 <= index < len(self._lyrics):
            return self._lyrics[index][1]
        return ""

    @Slot(int, result=float)
    def lyricTime(self, index):
        """返回指定索引的歌词时间戳"""
        if 0 <= index < len(self._lyrics):
            return self._lyrics[index][0]
        return 0.0

    def cleanup(self):
        """应用退出时清理资源，保存上次播放位置"""
        # 保存上次播放位置
        if self._current_index >= 0 and self._state != "stopped":
            song_path = self._songs[self._current_index]["path"]
            self.saveSetting("lastFile", song_path)
            self.saveSetting("lastPosition", str(self._position))
        self._kill_process()
        self._position_timer.stop()
        # 终止所有在途的异步 pactl 进程
        for proc in list(self._pactl_procs):
            proc.kill()
        self._pactl_procs.clear()
        self._sink_pending.clear()

    @Slot(result=bool)
    def restoreLastPosition(self):
        """恢复上次播放位置，返回是否成功找到歌曲"""
        settings = self.loadSettings()
        last_file = settings.get("lastFile", "")
        last_position = settings.get("lastPosition", 0.0)
        if not last_file or not _to_path(last_file).is_file():
            return False
        for i, song in enumerate(self._songs):
            if song["path"] == last_file:
                self._current_index = i
                self.songChanged.emit(i)
                # 防负值/异常值；越过时长的情况由 play()/时长加载回调钳制
                self._position = max(0.0, float(last_position))
                # 恢复的位置立刻同步给 UI（此时播放尚未开始，定时器不运行）
                self.positionChanged.emit(self._position)
                self._load_lyrics()
                return True
        return False

    def _lyric_lookup_position(self):
        """歌词索引查找用的位置：当前播放位置 + 提前量。

        提前量用于抵消播放器里滚动/高亮动画的视觉延迟（见 _LYRIC_LEAD_SEC）。
        桌面歌词与主界面都消费 lyricIndexChanged，因此两端同步提前。
        """
        return self._position + _LYRIC_LEAD_SEC

    def _find_lyric_index(self, pos):
        """二分查找最后一个 时间<=pos 的歌词行，无匹配返回 -1"""
        if not self._lyrics:
            return -1
        lo, hi = 0, len(self._lyrics) - 1
        idx = -1
        while lo <= hi:
            mid = (lo + hi) // 2
            if self._lyrics[mid][0] <= pos:
                idx = mid
                lo = mid + 1
            else:
                hi = mid - 1
        return idx

    def _update_lyric_index(self):
        """根据当前播放位置（+提前量）更新歌词索引（二分查找）。

        提前量索引（lyricIndexChanged）供播放器主界面与桌面歌词共同使用，
        用于抵消滚动/高亮动画延迟。"""
        if not self._lyrics:
            if self._current_lyric_index != -1:
                self._current_lyric_index = -1
                self.lyricIndexChanged.emit(-1)
            return
        idx = self._find_lyric_index(self._lyric_lookup_position())
        if idx != self._current_lyric_index:
            if _VERBOSE:
                _log("歌词", "索引 %d → %d @ pos=%.2fs (当前句时间 %.2fs)"
                     % (self._current_lyric_index, idx, self._position,
                        self._lyrics[idx][0] if 0 <= idx < len(self._lyrics) else -1))
            self._current_lyric_index = idx
            self.lyricIndexChanged.emit(idx)

    # ========== 配置持久化 ==========

    def _ensure_config_dir(self):
        """确保配置目录存在"""
        self._config_dir.mkdir(parents=True, exist_ok=True)

    @Slot(result="QVariantMap")
    def loadSettings(self):
        """从配置文件加载所有设置"""
        defaults = {
            "customAccent": "",
            "customDarkBg": "",
            "customLyricColor": "",
            "customLyricPlayedColor": "",
            "customLyricUnplayedColor": "",
            "customBtnBg": "",
            
            "blurRadius": 80,
            "panelOpacity": 0.45,
            "hideControlBackgrounds": False,
            "lastFile": "",
            "lastPosition": 0.0,
            "sortMode": 0,
            "playMode": 0,
            "listStyle": 0,
            "cardSize": 140,
            "musicDir": str(MUSIC_DIR),
            "rowSpacing": 48,
            "customFontFamily": "",
            "volume": 50,
            "closeToTray": True,
        }
        try:
            if self._config_file.exists():
                with open(self._config_file, "r", encoding="utf-8") as f:
                    saved = json.load(f)
                defaults.update(saved)
        except Exception:
            pass
        return defaults

    @Slot(str, str)
    def saveSetting(self, key, value):
        """保存单个设置项到配置文件

        回退保护：写盘前把现有配置轮换进 .bak1/.bak2（最多保留两个
        旧版本，bak1=上一次、bak2=再上一次），由设置界面的"回退"
        按钮恢复。内容无变化时不写盘、不轮换，避免历史被无意义覆盖。
        """
        self._ensure_config_dir()
        settings = {}
        try:
            if self._config_file.exists():
                with open(self._config_file, "r", encoding="utf-8") as f:
                    settings = json.load(f)
        except Exception:
            pass
        # 类型转换：按已知键白名单转换，避免把路径等任意字符串
        # 误转成数字（例如纯数字目录名的音乐路径被存成 int）
        if key in self._BOOL_SETTING_KEYS:
            settings[key] = value.lower() == "true"
        elif key in self._NUMERIC_SETTING_KEYS:
            try:
                settings[key] = float(value) if "." in value else int(value)
            except ValueError:
                settings[key] = value
        else:
            settings[key] = value
        try:
            new_text = json.dumps(settings, ensure_ascii=False, indent=2)
            if self._config_file.is_file() \
                    and self._config_file.read_text(encoding="utf-8") == new_text:
                return  # 内容无变化：不写盘、不轮换备份
            # 密集变化（拖动滑块、滚轮调音量等）合并为一个历史版本：
            # 距上次轮换超过 3 秒静默窗口才产生新版本，窗口内的连续保存
            # 只写盘不动备份——回退时恢复到"这一轮修改之前"的状态，
            # 而不是拖动过程中的某个中间值
            now = time.monotonic()
            if now - self._last_backup_ts > 3.0:
                try:
                    self._rotate_config_backup()
                except OSError:
                    pass  # 备份失败不阻塞本次保存
                self._last_backup_ts = now
            self._config_file.write_text(new_text, encoding="utf-8")
            self.settingsBackupChanged.emit()
        except OSError:
            pass

    def _rotate_config_backup(self):
        """把现有配置轮换进 .bak1/.bak2（最多保留两个旧版本）"""
        bak1 = self._config_file.with_name(self._config_file.name + ".bak1")
        bak2 = self._config_file.with_name(self._config_file.name + ".bak2")
        if bak2.is_file():
            bak2.unlink()
        if bak1.is_file():
            bak1.rename(bak2)
        if self._config_file.is_file():
            self._config_file.rename(bak1)

    @Property(bool, notify=settingsBackupChanged)
    def hasSettingsBackup(self):
        """是否有可回退的旧设置（QML 回退按钮 enabled 绑定）"""
        bak1 = self._config_file.with_name(self._config_file.name + ".bak1")
        return bak1.is_file()

    @Slot(result=bool)
    def rollbackSettings(self):
        """回退设置：恢复上一次保存的配置（.bak1），历史顺移（.bak2→.bak1），
        最多可连续回退两次。无备份时返回 False。"""
        bak1 = self._config_file.with_name(self._config_file.name + ".bak1")
        if not bak1.is_file():
            return False
        bak2 = self._config_file.with_name(self._config_file.name + ".bak2")
        try:
            if self._config_file.is_file():
                self._config_file.unlink()
            bak1.rename(self._config_file)
            if bak2.is_file():
                bak2.rename(bak1)
        except OSError:
            return False
        # 回退后重置静默窗口：下一次保存视为新一轮修改，正常轮换新版本
        self._last_backup_ts = 0.0
        self.settingsRolledBack.emit()
        self.settingsBackupChanged.emit()
        return True

    @Property(str, constant=True)
    def platformName(self):
        """QPA 平台名（xcb/wayland/offscreen）。"""
        return QGuiApplication.platformName()

    @Property(bool, constant=True)
    def framelessSupported(self):
        """当前会话是否支持无边框窗口 + startSystemMove/Resize。

        - xcb/offscreen：支持；
        - wayland：KDE Plasma 的 KWin 支持（用户会话实测 kwin_wayland），
          GNOME 等合成器不支持（无法移动/缩放窗口），回退原生顶栏。
        """
        platform = QGuiApplication.platformName()
        if platform in ("xcb", "offscreen"):
            return True
        if platform == "wayland":
            desktop = os.environ.get("XDG_CURRENT_DESKTOP", "")
            return "KDE" in desktop
        return False

    @Slot(str)
    def applyGlobalFont(self, family):
        """把自定义字体作为"全局字体"应用到整个应用。

        注意：QML 里 window.font 并不会被普通 Text 继承（实测 plain Text
        的空 family 最终解析到 QGuiApplication 的默认字体），所以全局字体
        必须通过 QGuiApplication.setFont 下发——所有未单独指定 font.family
        的控件（歌词、歌单、按钮、设置面板等）才会跟随变化。
        """
        family = (family or "").strip()
        QGuiApplication.instance().setFont(QFont(family) if family else QFont())


# ========== 应用入口 ==========


def _setup_signal_handlers(player):
    """注册信号处理器，确保在异常退出时清理 ffplay 子进程。

    当进程收到 SIGINT (Ctrl+C)、SIGTERM (kill) 时，先调用 player.cleanup()
    终止 ffplay 子进程，再退出。

    SIGSEGV 单独处理：段错误发生时进程内存可能已损坏，处理器里调用任何
    Python/Qt 方法（cleanup 含 waitForFinished 等复杂逻辑）都极不安全，
    可能造成二次崩溃或死锁。这里只做最小化处理：直接 os.kill 向记录的
    ffplay 子进程 pid 发 SIGTERM（纯系统调用），然后恢复默认处理，
    让进程按正常方式 core dump。
    """
    def _signal_handler(signum, frame):
        player.cleanup()
        # 恢复默认信号处理并重新发送信号，让进程以正常方式退出
        signal.signal(signum, signal.SIG_DFL)
        os.kill(os.getpid(), signum)

    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, _signal_handler)

    def _segv_handler(signum, frame):
        pid = getattr(player, "_last_child_pid", None)
        if pid:
            try:
                os.kill(pid, signal.SIGTERM)
            except OSError:
                pass
        signal.signal(signum, signal.SIG_DFL)
        os.kill(os.getpid(), signum)

    signal.signal(signal.SIGSEGV, _segv_handler)


class AppBridge(QObject):
    """桥接对象，向 QML 暴露 Python 侧的退出/桌面歌词等功能"""

    desktopLyricsEnabledChanged = Signal(bool)

    def __init__(self, parent=None):
        super().__init__(parent)
        self._quit_callback = None
        self._tray_available = True
        self._player = None
        self._desktop_available = False

    def setQuitCallback(self, callback):
        self._quit_callback = callback

    def setTrayAvailable(self, available):
        """记录系统托盘是否可用。不可用时 QML 关闭窗口应直接退出，
        否则窗口藏起来后没有任何入口能恢复（托盘图标不存在）。"""
        self._tray_available = bool(available)

    def setPlayer(self, player):
        """记录 AudioPlayer，供桌面歌词开关使用。"""
        self._player = player

    def setDesktopAvailable(self, available):
        """记录桌面歌词模块是否可用（初始化失败时设置面板开关禁用）。"""
        self._desktop_available = bool(available)

    @Property(bool, constant=True)
    def trayAvailable(self):
        return self._tray_available

    @Property(bool, constant=True)
    def desktopAvailable(self):
        return self._desktop_available

    @Property(bool, notify=desktopLyricsEnabledChanged)
    def desktopLyricsEnabled(self):
        try:
            import desktop as _d
            return _d.is_desktop_lyrics_enabled()
        except Exception:
            return False

    @Slot(bool)
    def setDesktopLyrics(self, on):
        """开关桌面歌词（QML 开关控件调用）。"""
        try:
            import desktop as _d
            _d.set_desktop_lyrics_enabled(on, self._player)
            self.desktopLyricsEnabledChanged.emit(on)
        except Exception as e:
            _log_warn("桌面歌词", "切换失败: %s" % e)

    @Slot(str, str)
    def setDesktopStyle(self, font, color):
        """设置桌面歌词字体/颜色（QML 设置面板调用，空串表示用默认值）。"""
        try:
            import desktop as _d
            _d.set_desktop_style(font or "", color or "", self._player)
        except Exception as e:
            _log_warn("桌面歌词", "设置样式失败: %s" % e)

    @Slot(bool)
    def setDesktopLyricsLocked(self, locked):
        """设置"锁定歌词"（QML 设置面板开关调用）：锁定后桌面歌词不可挪动。"""
        try:
            import desktop as _d
            _d.set_desktop_lyrics_locked(locked, self._player)
        except Exception as e:
            _log_warn("桌面歌词", "设置锁定状态失败: %s" % e)

    @Slot()
    def quitApp(self):
        if self._quit_callback:
            self._quit_callback()


_SINGLE_INSTANCE_NAME = "PyMusic-single-instance"


def _instance_pid_file():
    return SCAN_CACHE_DIR / "instance.pid"


def _read_instance_pid():
    try:
        return int(_instance_pid_file().read_text().strip())
    except (OSError, ValueError):
        return None


def _is_our_instance(pid):
    """按 /proc/<pid>/cmdline 校验 pid 确实属于本程序（防 pid 复用误杀）"""
    try:
        cmd = Path(f"/proc/{pid}/cmdline").read_bytes().decode(errors="replace")
    except OSError:
        return False
    return "main.py" in cmd and ("python" in cmd.lower() or "pymusic" in cmd.lower())


def _acquire_single_instance(server):
    """单实例接管：监听失败说明已有实例运行——直接 SIGTERM 终止旧实例
    （旧实例的 SIGTERM 处理器会清理 ffplay 子进程后退出），等它退出后
    回收套接字并重新监听，由本实例接管。返回是否成功成为唯一实例。"""
    if server.listen(_SINGLE_INSTANCE_NAME):
        return True
    old_pid = _read_instance_pid()
    if old_pid and _is_our_instance(old_pid):
        try:
            os.kill(old_pid, signal.SIGTERM)
        except OSError:
            pass
        # 等待旧实例退出（最多 2 秒），其 SIGTERM 处理器会清理 ffplay
        deadline = time.monotonic() + 2.0
        while time.monotonic() < deadline:
            try:
                os.kill(old_pid, 0)
            except OSError:
                break
            time.sleep(0.05)
    # 回收套接字（旧实例正常退出时 Qt 也会清理；这里兜底崩溃残留）
    QLocalServer.removeServer(_SINGLE_INSTANCE_NAME)
    return server.listen(_SINGLE_INSTANCE_NAME)


def main():
    """启动 PySide6 QML 应用"""
    _setup_logging()
    _install_qt_msg_handler()
    app = QApplication([])
    app.setApplicationName("MusicPlayer2 - Py")
    # 关闭主窗口时不退出程序，改为最小化到系统托盘
    app.setQuitOnLastWindowClosed(False)
    # 启动诊断：版本/平台/渲染后端/捆绑工具（打印到 stderr）
    _log_startup_diagnostics()

    # 让 Python 信号（Ctrl+C 等）在 Qt 事件循环空闲时也能及时投递。
    # 默认情况下 Python 信号处理器要等主线程执行到 Python 字节码才会运行，
    # 而 Qt 事件循环是纯 C++ 代码——无播放/无交互时（位置定时器不跑、
    # 没有槽函数触发）Ctrl+C 会一直挂起，表现为"按 Ctrl+C 很久都不退出"。
    # 用 set_wakeup_fd + QSocketNotifier：信号到达时内核向 socket 写一字节，
    # Qt 通知器立刻唤醒 Python 处理挂起的信号。
    import socket
    _sig_rfd, _sig_wfd = socket.socketpair()
    _sig_wfd.setblocking(False)                      # set_wakeup_fd 要求非阻塞
    os.set_inheritable(_sig_rfd.fileno(), False)   # 防止被 ffplay 子进程继承
    os.set_inheritable(_sig_wfd.fileno(), False)
    signal.set_wakeup_fd(_sig_wfd.fileno())
    _sig_notifier = QSocketNotifier(_sig_rfd.fileno(), QSocketNotifier.Read, app)
    _sig_notifier.activated.connect(lambda fd: os.read(fd, 4096))
    app._sig_wakeup = (_sig_rfd, _sig_wfd, _sig_notifier)  # 保持引用

    # 单实例：已有实例运行时直接终止旧实例并接管（旧实例的 SIGTERM
    # 处理器会先清理 ffplay 子进程）。同时避免两个实例互相覆盖配置。
    single_instance = QLocalServer()
    if not _acquire_single_instance(single_instance):
        # 极端情况（旧实例无法终止/套接字无法回收）：提示后退出
        QMessageBox.information(None, "PyMusic", "程序已在运行且无法终止")
        return 0
    # 记录本实例 pid，供下一实例"杀死旧的"时定位进程
    try:
        SCAN_CACHE_DIR.mkdir(parents=True, exist_ok=True)
        _instance_pid_file().write_text(str(os.getpid()))
    except OSError:
        pass

    # 设置窗口图标和系统托盘图标
    icon_path = str(Path(__file__).parent / "icons" / "LOGO.png")
    app.setWindowIcon(QIcon(icon_path))
    tray = QSystemTrayIcon(QIcon(icon_path), app)
    tray.setToolTip("MusicPlayer2 - Py")
    tray.show()

    engine = QQmlApplicationEngine()
    player = AudioPlayer()

    # 桌面歌词：模块级管理器懒创建透明置顶小窗（由设置面板开关控制）。
    # 这里仅确保控制器存在并绑定 player，不自动显示——是否显示由
    # AppBridge.setDesktopLyrics / 已保存的设置决定。
    # Wayland+KDE 下置顶需配合 KWin 窗口规则（见 desktop.py docstring）。
    try:
        import desktop as _desktop_mod
        _desktop_mod.ensure_desktop_lyrics(player)
    except Exception as e:
        _desktop_mod = None
        _log_warn("桌面歌词", "初始化失败（设置面板开关将不可用）: %s" % e)

    # 注册信号处理器，确保异常退出时清理子进程
    _setup_signal_handlers(player)

    def show_window():
        """恢复并激活主窗口（双击托盘图标 / 菜单中"显示主窗口"触发）"""
        window.show()
        window.raise_()
        window.requestActivate()

    def quit_app():
        """真正退出程序：先清理子进程，再关闭托盘图标，最后退出事件循环"""
        if _desktop_mod is not None:
            try:
                _desktop_mod.close_desktop_lyrics()
            except Exception:
                pass
        player.cleanup()
        tray.hide()
        app.quit()

    # 桥接对象：向 QML 暴露 quitApp()/桌面歌词开关。
    # 注意：必须在 engine.load() 之前设置 appBridge 上下文属性，否则 QML 里
    # 布局阶段就引用 appBridge 的绑定（如桌面歌词开关）会报 ReferenceError。
    bridge = AppBridge()
    bridge.setQuitCallback(quit_app)
    bridge.setTrayAvailable(QSystemTrayIcon.isSystemTrayAvailable())
    bridge.setPlayer(player)
    bridge.setDesktopAvailable(_desktop_mod is not None)

    engine.rootContext().setContextProperty("player", player)
    engine.rootContext().setContextProperty("appBridge", bridge)
    app.aboutToQuit.connect(player.cleanup)
    engine.load(str(Path(__file__).parent / "main.qml"))

    if not engine.rootObjects():
        print("错误: 无法加载 QML 文件")
        return -1

    window = engine.rootObjects()[0]

    # 应用上次保存的桌面歌词状态（上次开启则本次自动显示）
    if _desktop_mod is not None and bridge.desktopLyricsEnabled:
        try:
            _desktop_mod.set_desktop_lyrics_enabled(True, player)
            # 这里直接调用的是 desktop 模块的函数，没有经过
            # bridge.setDesktopLyrics()，所以不会自动触发
            # desktopLyricsEnabledChanged —— 设置面板里的开关控件在
            # engine.load() 时已经按"未恢复前"的状态渲染过一次，如果不
            # 在这里手动补发一次信号，即便窗口这次确实正常恢复显示了，
            # 面板上的开关看起来仍然是"关"的，容易让人误以为又失败了。
            bridge.desktopLyricsEnabledChanged.emit(True)
        except Exception as e:
            _log_warn("桌面歌词", "恢复上次状态失败: %s" % e)
    # 退出淡出：X 按钮走 player.fadeOutQuit()，淡出完成后调用同一退出回调
    player.setQuitCallback(quit_app)

    # 托盘右键菜单：显示主窗口 / 退出
    tray_menu = QMenu()
    show_action = tray_menu.addAction("显示主窗口")
    show_action.triggered.connect(show_window)
    tray_menu.addSeparator()
    quit_action = tray_menu.addAction("退出")
    quit_action.triggered.connect(quit_app)
    tray.setContextMenu(tray_menu)

    # 双击托盘图标恢复窗口
    def on_tray_activated(reason):
        if reason == QSystemTrayIcon.ActivationReason.DoubleClick:
            show_window()

    tray.activated.connect(on_tray_activated)

    # ===== 自测驱动（PYMUSIC_SELFTEST=1）：自动执行播放/暂停/恢复/seek/切歌/
    # 调音量序列，用于在 AppImage 等环境复现"淡出/切歌瞬间主线程卡顿"并
    # 由停滞转储（faulthandler）抓取阻塞点堆栈。 =====
    if os.environ.get("PYMUSIC_SELFTEST") == "1":
        def _selftest():
            _log("自测", "开始: 播放→暂停→恢复→seek×3→切歌×2→调音量×3→退出淡出")
            seq = [
                (3.0, lambda: player.play()),
                (8.0, lambda: player.seek(player.position + 20)),
                (10.0, lambda: player.seek(player.position + 20)),
                (12.0, lambda: player.pause()),
                (15.0, lambda: player.resume()),
                (17.0, lambda: player.setVolume(70)),
                (19.0, lambda: player.seek(player.position + 15)),
                (21.0, lambda: player.next()),
                (23.0, lambda: player.setVolume(40)),
                (25.0, lambda: player.pause()),
                (28.0, lambda: player.resume()),
                (30.0, lambda: player.next()),
                (32.0, lambda: player.setVolume(60)),
                (34.0, lambda: player.fadeOutQuit()),
            ]
            for delay, fn in seq:
                QTimer.singleShot(int(delay * 1000), fn)
            QTimer.singleShot(42000, app.quit)  # 兜底退出

        QTimer.singleShot(2000, _selftest)

    rc = app.exec()

    return rc


if __name__ == "__main__":
    sys.exit(main())
