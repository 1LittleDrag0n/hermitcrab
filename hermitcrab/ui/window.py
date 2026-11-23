"""HermitCrab main window: Mode → Scan → Review → Run."""

from __future__ import annotations

import html
import json
import os
import re
import shutil
import signal
import sys
import time
from pathlib import Path

from PySide6.QtCore import QObject, QProcess, QProcessEnvironment, Qt, QThread, QTimer, QUrl, Signal
from PySide6.QtGui import QAction, QDesktopServices, QFont, QFontDatabase, QIcon, QTextCursor
from PySide6.QtWidgets import (QApplication, QButtonGroup, QCheckBox, QComboBox, QFileDialog, QFrame,
                               QHBoxLayout, QInputDialog, QLabel, QLineEdit, QMainWindow,
                               QMenu, QMessageBox, QPlainTextEdit, QProgressBar, QPushButton,
                               QSizePolicy, QStackedWidget, QToolButton, QVBoxLayout, QWidget)

from .. import APP_ID, APP_NAME, __version__, job, sysinfo
from ..model import ScanResult, human_size
from . import desktop, theme
from .tree import SORT_NAME, SORT_ORIGINAL, SORT_SIZE, SelectionTree

CONFIG_DIR = Path.home() / ".config/hermitcrab"
PRESET_DIR = CONFIG_DIR / "presets"
ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
HEADER_RE = re.compile(r"^══\s*(.+?)\s*══$")

MODES = {
    "migrate": ("Full backup",
                "Everything: themes, widgets, login screen, settings and every app you have "
                "installed. For your own machines — keep it private."),
    "themepack": ("Theme pack",
                  "Just the look, safe to share with friends. No passwords, no browser data, "
                  "no personal files, no apps."),
    "restore": ("Restore",
                "Open a full backup or a theme pack and choose what to bring back."),
}


# ── background workers ───────────────────────────────────────────────────────
class ScanWorker(QObject):
    progress = Signal(str, int)
    finished = Signal(object, object, object)   # ScanResult, pack_dir, work_root
    failed = Signal(str)
    wrong_password = Signal(str)

    def __init__(self, mode: str, source: str, password: str | None = None):
        super().__init__()
        self.mode, self.source, self.password = mode, source, password

    def run(self) -> None:
        # Let VS Code / debugpy stop at breakpoints in this Qt thread
        try:
            import debugpy
            debugpy.debug_this_thread()
        except Exception:  # noqa: BLE001 — not running under a debugger
            pass
        try:
            if self.mode == "restore":
                from ..packscan import PackScanner
                pack, work = job.prepare_pack(self.source, lambda m: self.progress.emit(m, 5),
                                              password=self.password)
                self.password = None
                res = PackScanner(str(pack), self.progress.emit).run()
                self.finished.emit(res, pack, work)
            else:
                from ..scanner import Scanner
                res = Scanner(self.mode, self.progress.emit).run()
                self.finished.emit(res, None, None)
        except job.WrongPassword as e:
            self.wrong_password.emit(str(e))
        except Exception as e:  # noqa: BLE001 — surface anything to the user
            self.failed.emit(f"{type(e).__name__}: {e}")


# ── small widgets ────────────────────────────────────────────────────────────
def password_strength(pw: str) -> tuple[int, str]:
    """0 = empty, 1 = weak, 2 = okay, 3 = strong. Simple and honest: length
    matters most; a few random words beat short symbol soup."""
    if not pw:
        return 0, ""
    classes = sum(bool(re.search(p, pw)) for p in (r"[a-z]", r"[A-Z]", r"\d", r"[^\w\s]"))
    words = len([w for w in re.split(r"[\s\-_.]+", pw) if len(w) >= 3])
    if len(pw) >= 16 or words >= 4 or (len(pw) >= 12 and classes >= 3):
        return 3, "strong"
    if len(pw) >= 10 or (len(pw) >= 8 and classes >= 3):
        return 2, "okay — longer is better"
    return 1, "weak — use 12+ characters, or a few random words"

def _title(text: str, size: int = 18) -> QLabel:
    l = QLabel(text)
    f = l.font()
    f.setPointSize(size)
    f.setBold(True)
    l.setFont(f)
    return l


def _muted(text: str) -> QLabel:
    l = QLabel(text)
    l.setWordWrap(True)
    l.setEnabled(False)
    return l


class ModeCard(QPushButton):
    def __init__(self, key: str, icon_name: str):
        title, desc = MODES[key]
        super().__init__()
        self.key = key
        self.setCheckable(True)
        self.setMinimumHeight(120)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Preferred)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(16, 14, 16, 14)
        top = QHBoxLayout()
        ic = QLabel()
        ic.setPixmap(QIcon.fromTheme(icon_name).pixmap(32, 32))
        top.addWidget(ic)
        top.addWidget(_title(title, 13))
        top.addStretch()
        lay.addLayout(top)
        d = QLabel(desc)
        d.setWordWrap(True)
        d.setAttribute(Qt.WA_TransparentForMouseEvents)
        ic.setAttribute(Qt.WA_TransparentForMouseEvents)
        lay.addWidget(d)
        lay.addStretch()


class Banner(QLabel):
    def __init__(self):
        super().__init__()
        self.setWordWrap(True)
        self.setTextFormat(Qt.RichText)
        self.setMargin(10)
        self.hide()

    def show_kind(self, kind: str, text: str) -> None:
        colors = {"warn": ("#fff4ce", "#7a5c00"), "error": ("#fde2e1", "#8a1c14"),
                  "ok": ("#dff6dd", "#0f5223"), "info": ("#e6f0fb", "#1c3d6e")}
        bg, fg = colors.get(kind, colors["info"])
        self.setStyleSheet(f"background:{bg}; color:{fg}; border-radius:6px;")
        self.setText(text)
        self.show()


# ── main window ──────────────────────────────────────────────────────────────
class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle(APP_NAME)
        self.resize(1080, 760)
        self.mode = "migrate"
        self.result: ScanResult | None = None
        self.pack_dir: Path | None = None
        self.work_root: Path | None = None
        self.proc: QProcess | None = None
        self.current_job: job.Job | None = None
        self.out_dir: str = ""
        self.archive_path: str = ""
        self._buf = ""
        self._headers_total = 1
        self._headers_seen = 0

        self.stack = QStackedWidget()
        self.setCentralWidget(self.stack)
        self.page_mode = self._build_mode_page()
        self.page_scan = self._build_scan_page()
        self.page_review = self._build_review_page()
        self.page_run = self._build_run_page()
        for p in (self.page_mode, self.page_scan, self.page_review, self.page_run):
            self.stack.addWidget(p)
        self._build_menu()
        self._select_mode("migrate")

    # ── menu ─────────────────────────────────────────────────────────────────
    def _build_menu(self) -> None:
        m = self.menuBar().addMenu("&HermitCrab")
        self.act_install = QAction("Add to application menu", self)
        self.act_install.triggered.connect(self._toggle_launcher)
        m.addAction(self.act_install)
        m.addSeparator()
        about = QAction("About", self)
        about.triggered.connect(self._about)
        m.addAction(about)
        quit_ = QAction("Quit", self)
        quit_.setShortcut("Ctrl+Q")
        quit_.triggered.connect(self.close)
        m.addAction(quit_)
        self._sync_launcher_action()

    def _sync_launcher_action(self) -> None:
        self.act_install.setText("Remove from application menu" if desktop.is_installed()
                                 else "Add to application menu")

    def _toggle_launcher(self) -> None:
        msg = desktop.uninstall() if desktop.is_installed() else desktop.install()
        self._sync_launcher_action()
        QMessageBox.information(self, APP_NAME, msg)

    def _about(self) -> None:
        QMessageBox.about(self, f"About {APP_NAME}",
                          f"<h3>{APP_NAME} {__version__}</h3>"
                          "<p>A hermit crab moves its whole home into a new shell.<br>"
                          "This moves your whole desktop into a new install.</p>"
                          "<p>Work in progress — take a snapshot before restoring.</p>"
                          "<p>Licensed under GPL-3.0.</p>")

    # ── page 0: mode ─────────────────────────────────────────────────────────
    def _build_mode_page(self) -> QWidget:
        w = QWidget()
        lay = QVBoxLayout(w)
        lay.setContentsMargins(32, 28, 32, 28)
        lay.setSpacing(14)
        head = QHBoxLayout()
        logo = QLabel()
        icon = desktop.icon_path()
        if icon:
            logo.setPixmap(QIcon(str(icon)).pixmap(56, 56))
        head.addWidget(logo)
        tcol = QVBoxLayout()
        tcol.addWidget(_title(APP_NAME, 22))
        tag = _muted("Move your whole desktop into a new shell.")
        tag.setWordWrap(False)
        tcol.addWidget(tag)
        head.addLayout(tcol)
        head.addStretch()
        lay.addLayout(head)

        warn = Banner()
        warn.show_kind("warn", "<b>Work in progress.</b> Restoring changes system files and can "
                       "break a desktop. Take a snapshot first "
                       "(<code>sudo snapper -c root create</code>).")
        lay.addWidget(warn)

        cards = QHBoxLayout()
        self.mode_group = QButtonGroup(self)
        self.mode_group.setExclusive(True)
        for key, icon_name in [("migrate", "drive-harddisk"), ("themepack", "preferences-desktop-theme"),
                               ("restore", "document-revert")]:
            c = ModeCard(key, icon_name)
            self.mode_group.addButton(c)
            c.clicked.connect(lambda _=False, k=key: self._select_mode(k))
            cards.addWidget(c)
        lay.addLayout(cards)

        self.path_label = QLabel()
        lay.addWidget(self.path_label)
        row = QHBoxLayout()
        self.path_edit = QLineEdit()
        row.addWidget(self.path_edit, 1)
        self.btn_browse = QPushButton(QIcon.fromTheme("folder-open"), "Choose folder…")
        self.btn_browse.clicked.connect(self._browse_folder)
        row.addWidget(self.btn_browse)
        self.btn_browse_file = QPushButton(QIcon.fromTheme("package-x-generic"), "Choose archive…")
        self.btn_browse_file.clicked.connect(self._browse_archive)
        row.addWidget(self.btn_browse_file)
        lay.addLayout(row)
        self.path_hint = _muted("")
        lay.addWidget(self.path_hint)

        lay.addStretch()
        bottom = QHBoxLayout()
        bottom.addStretch()
        self.btn_scan = QPushButton(QIcon.fromTheme("system-search"), "Scan")
        self.btn_scan.setDefault(True)
        self.btn_scan.setMinimumWidth(140)
        self.btn_scan.clicked.connect(self._start_scan)
        bottom.addWidget(self.btn_scan)
        lay.addLayout(bottom)
        return w

    def _select_mode(self, key: str) -> None:
        self.mode = key
        for b in self.mode_group.buttons():
            b.setChecked(b.key == key)
        restore = key == "restore"
        self.btn_browse_file.setVisible(restore)
        if restore:
            self.path_label.setText("<b>Pack to restore</b>")
            self.path_edit.setPlaceholderText("Pick a .tar.gz archive or an unpacked pack folder")
            self.path_edit.setText("")
            self.path_hint.setText("Nothing is changed until you press Start on the next screens.")
        else:
            self.path_label.setText("<b>Where to save it</b>")
            self.path_edit.setPlaceholderText(str(Path.home()))
            if not self.path_edit.text():
                self.path_edit.setText(str(Path.home()))
            self.path_hint.setText("A folder and a .tar.gz archive will be created here. "
                                   "Pick another drive if your home is short on space.")

    def _browse_folder(self) -> None:
        d = QFileDialog.getExistingDirectory(self, "Choose folder", self.path_edit.text() or
                                             str(Path.home()))
        if d:
            self.path_edit.setText(d)

    def _browse_archive(self) -> None:
        f, _ = QFileDialog.getOpenFileName(self, "Choose pack", str(Path.home()),
                                           "HermitCrab packs (*.tar.gz *.tgz *.tar.gz.gpg *.gpg);;All files (*)")
        if f:
            self.path_edit.setText(f)

    # ── page 1: scanning ─────────────────────────────────────────────────────
    def _build_scan_page(self) -> QWidget:
        w = QWidget()
        lay = QVBoxLayout(w)
        lay.setContentsMargins(32, 28, 32, 28)
        lay.addStretch()
        self.scan_title = _title("Scanning…")
        self.scan_title.setAlignment(Qt.AlignCenter)
        lay.addWidget(self.scan_title)
        self.scan_msg = QLabel("")
        self.scan_msg.setAlignment(Qt.AlignCenter)
        lay.addWidget(self.scan_msg)
        self.scan_bar = QProgressBar()
        self.scan_bar.setRange(0, 100)
        self.scan_bar.setMaximumWidth(520)
        h = QHBoxLayout()
        h.addStretch()
        h.addWidget(self.scan_bar, 1)
        h.addStretch()
        lay.addLayout(h)
        lay.addWidget(_muted("Nothing is being copied — this only looks at what's there."),
                      alignment=Qt.AlignCenter)
        lay.addStretch()
        return w

    def _start_scan(self) -> None:
        src = self.path_edit.text().strip() or (str(Path.home()) if self.mode != "restore" else "")
        if self.mode == "restore":
            if not src or not Path(src).expanduser().exists():
                QMessageBox.warning(self, APP_NAME, "Pick a pack to restore first.")
                return
        else:
            Path(src).expanduser().mkdir(parents=True, exist_ok=True)
            self.path_edit.setText(str(Path(src).expanduser()))
        password = None
        if self.mode == "restore" and job.is_encrypted(src):
            password, ok = QInputDialog.getText(
                self, "Password protected backup",
                f"{Path(src).name}\n\nThis backup is locked. Enter its password:",
                QLineEdit.Password)
            if not ok:
                return
            if not password:
                QMessageBox.warning(self, APP_NAME, "The password can't be empty.")
                return
        self._cleanup_work()
        self.scan_title.setText(f"Scanning for {MODES[self.mode][0].lower()}…")
        self.scan_bar.setValue(0)
        self.stack.setCurrentWidget(self.page_scan)

        self.thread = QThread(self)
        self.worker = ScanWorker(self.mode, src, password)
        password = None
        self.worker.moveToThread(self.thread)
        self.thread.started.connect(self.worker.run)
        self.worker.progress.connect(self._scan_progress)
        self.worker.finished.connect(self._scan_done)
        self.worker.failed.connect(self._scan_failed)
        self.worker.finished.connect(self.thread.quit)
        self.worker.failed.connect(self.thread.quit)
        self.worker.wrong_password.connect(self._scan_wrong_password)
        self.worker.wrong_password.connect(self.thread.quit)
        self.thread.start()

    def _scan_progress(self, msg: str, pct: int) -> None:
        self.scan_msg.setText(msg)
        self.scan_bar.setValue(pct)

    def _scan_failed(self, err: str) -> None:
        QMessageBox.critical(self, APP_NAME, f"Scan failed:\n\n{err}")
        self.stack.setCurrentWidget(self.page_mode)

    def _scan_wrong_password(self, _msg: str) -> None:
        self.stack.setCurrentWidget(self.page_mode)
        again = QMessageBox.warning(
            self, APP_NAME, "That password didn't open the backup.\n\n"
            "Passwords are case-sensitive — check Caps Lock and try again.",
            QMessageBox.Retry | QMessageBox.Cancel, QMessageBox.Retry)
        if again == QMessageBox.Retry:
            QTimer.singleShot(0, self._start_scan)

    def _scan_done(self, result: ScanResult, pack, work) -> None:
        self.result, self.pack_dir, self.work_root = result, pack, work
        self.tree.load(result)
        self.search.clear()
        self._fill_review_header()
        self.stack.setCurrentWidget(self.page_review)

    # ── page 2: review ───────────────────────────────────────────────────────
    def _build_review_page(self) -> QWidget:
        w = QWidget()
        lay = QVBoxLayout(w)
        lay.setContentsMargins(20, 16, 20, 16)
        lay.setSpacing(10)
        self.review_title = _title("Choose what to move", 16)
        lay.addWidget(self.review_title)
        self.review_sub = _muted("")
        lay.addWidget(self.review_sub)
        self.review_banner = Banner()
        lay.addWidget(self.review_banner)

        tools = QHBoxLayout()
        self.search = QLineEdit()
        self.search.setPlaceholderText("Search (e.g. davinci, steam, cursor)…")
        self.search.setClearButtonEnabled(True)
        self.search.textChanged.connect(lambda t: self.tree.filter(t))
        tools.addWidget(self.search, 1)
        self.sort_box = QComboBox()
        self.sort_box.setToolTip("Sort every level of the list. Tip: click the Size "
                                 "column header to toggle biggest-first.")
        for label, mode in [("Sort: scan order", SORT_ORIGINAL),
                            ("Sort: biggest first", SORT_SIZE),
                            ("Sort: name A–Z", SORT_NAME)]:
            self.sort_box.addItem(label, mode)
        tools.addWidget(self.sort_box)
        for text, fn in [("Expand all", lambda: self.tree.expandAll()),
                         ("Collapse all", lambda: self.tree.collapseAll()),
                         ("Tick all", lambda: self.tree.set_all(True)),
                         ("Untick all", lambda: self.tree.set_all(False)),
                         ("Defaults", lambda: self.tree.reset_defaults())]:
            b = QPushButton(text)
            b.clicked.connect(fn)
            tools.addWidget(b)
        lay.addLayout(tools)

        self.tree = SelectionTree()
        self.tree.selectionChangedTotals.connect(self._totals_changed)
        self.sort_box.currentIndexChanged.connect(
            lambda _i: self.tree.apply_sort(self.sort_box.currentData()))
        self.tree.sortModeChanged.connect(self._sync_sort_box)
        lay.addWidget(self.tree, 1)

        self.opts = QFrame()
        ol = QVBoxLayout(self.opts)
        ol.setContentsMargins(0, 0, 0, 0)
        self.opt_sddm = QCheckBox("Switch the login screen to SDDM "
                                  "(only needed for a custom login theme — leave off if unsure)")
        self.opt_mismatch = QCheckBox("Continue even though the Plasma versions don't match")
        ol.addWidget(self.opt_sddm)
        ol.addWidget(self.opt_mismatch)
        lay.addWidget(self.opts)

        lay.addWidget(self._build_lock_box())

        bottom = QHBoxLayout()
        self.totals = QLabel("")
        bottom.addWidget(self.totals, 1)
        back = QPushButton(QIcon.fromTheme("go-previous"), "Back")
        back.clicked.connect(self._back_to_mode)
        bottom.addWidget(back)
        presets = QToolButton()
        presets.setText("Presets")
        presets.setPopupMode(QToolButton.InstantPopup)
        pm = QMenu(presets)
        pm.addAction("Save current selection…", self._save_preset)
        self.load_menu = pm.addMenu("Load")
        pm.aboutToShow.connect(self._fill_load_menu)
        presets.setMenu(pm)
        bottom.addWidget(presets)
        dry = QPushButton(QIcon.fromTheme("document-preview"), "Dry run")
        dry.setToolTip("Show exactly what would happen, without copying anything")
        dry.clicked.connect(self._dry_run)
        bottom.addWidget(dry)
        self.btn_start = QPushButton(QIcon.fromTheme("media-playback-start"), "Start")
        self.btn_start.setDefault(True)
        self.btn_start.setMinimumWidth(120)
        self.btn_start.clicked.connect(self._start_run)
        bottom.addWidget(self.btn_start)
        lay.addLayout(bottom)
        return w

    def _build_lock_box(self) -> QWidget:
        """Full backup only: password-protect the archive, delete the folder."""
        box = QFrame()
        box.setFrameShape(QFrame.StyledPanel)
        v = QVBoxLayout(box)
        v.setContentsMargins(10, 8, 10, 8)
        self.opt_lock = QCheckBox("Protect the backup with a password")
        self.opt_lock.setToolTip("Like a password-protected zip: the archive can't be opened "
                                 "without the password (AES-256 encryption).")
        v.addWidget(self.opt_lock)

        self.lock_fields = QWidget()
        g = QVBoxLayout(self.lock_fields)
        g.setContentsMargins(24, 0, 0, 0)
        row = QHBoxLayout()
        self.pw1 = QLineEdit()
        self.pw1.setEchoMode(QLineEdit.Password)
        self.pw1.setPlaceholderText("Password")
        self.pw2 = QLineEdit()
        self.pw2.setEchoMode(QLineEdit.Password)
        self.pw2.setPlaceholderText("Type it again")
        self.pw_show = QCheckBox("Show")
        row.addWidget(self.pw1, 1)
        row.addWidget(self.pw2, 1)
        row.addWidget(self.pw_show)
        g.addLayout(row)
        self.pw_hint = QLabel("")
        g.addWidget(self.pw_hint)
        g.addWidget(_muted("⚠ If you forget the password, the backup can't be opened. "
                           "There is no reset — write it down somewhere safe."))
        v.addWidget(self.lock_fields)

        self.opt_delete = QCheckBox("Delete the backup folder once the archive is made "
                                    "(the archive is checked first — leaves one single file)")
        v.addWidget(self.opt_delete)
        self.delete_hint = QLabel("")
        self.delete_hint.setWordWrap(True)
        v.addWidget(self.delete_hint)

        def toggled(on: bool) -> None:
            self.lock_fields.setVisible(on)
            if on:
                self.opt_delete.setChecked(True)   # an unlocked copy beside it defeats the point
                self.pw1.setFocus()
            self._update_pw_hint()

        self.opt_lock.toggled.connect(toggled)
        self.opt_delete.toggled.connect(lambda _on: self._update_pw_hint())
        self.pw_show.toggled.connect(lambda on: [
            e.setEchoMode(QLineEdit.Normal if on else QLineEdit.Password)
            for e in (self.pw1, self.pw2)])
        self.pw1.textChanged.connect(lambda _t: self._update_pw_hint())
        self.pw2.textChanged.connect(lambda _t: self._update_pw_hint())
        self.lock_fields.hide()
        self.lock_box = box
        return box

    def _update_pw_hint(self) -> None:
        a, b = self.pw1.text(), self.pw2.text()
        level, words = password_strength(a)
        colour = {1: "#c0392b", 2: "#c08a00", 3: "#2e8b57"}.get(level, "inherit")
        text = f"Strength: <span style='color:{colour}'><b>{words}</b></span>" if level else ""
        if b and a != b:
            text += (" · " if text else "") + "<span style='color:#c0392b'>passwords don't match</span>"
        elif b and a == b:
            text += " · <span style='color:#2e8b57'>✓ match</span>"
        self.pw_hint.setText(text)
        if self.opt_lock.isChecked() and not self.opt_delete.isChecked():
            self.delete_hint.setText("<span style='color:#c08a00'>The folder left next to the "
                                     "archive is <b>not</b> password protected.</span>")
            self.delete_hint.show()
        else:
            self.delete_hint.hide()

    def _clear_passwords(self) -> None:
        for e in (self.pw1, self.pw2):
            e.clear()
        self.pw_show.setChecked(False)

    def _sync_sort_box(self, mode: str) -> None:
        i = self.sort_box.findData(mode)
        if i >= 0 and i != self.sort_box.currentIndex():
            self.sort_box.blockSignals(True)
            self.sort_box.setCurrentIndex(i)
            self.sort_box.blockSignals(False)

    def _fill_review_header(self) -> None:
        r = self.result
        assert r is not None
        if r.mode == "restore":
            kind = {"migrate": "full backup", "themepack": "theme pack"}.get(
                r.info.get("type", ""), "pack")
            self.review_title.setText("Choose what to restore")
            self.review_sub.setText(f"This is a {kind}. Untick anything you don't want back. "
                                    "The original pack is never changed.")
            self.opts.show()
            self.lock_box.hide()
            self.opt_sddm.setChecked(False)
            self.opt_mismatch.setVisible(bool(r.info.get("version_mismatch")))
            self.opt_mismatch.setChecked(False)
            self.opt_sddm.setVisible(any(n.label == "Login screen" for n in r.roots))
        else:
            self.review_title.setText("Choose what to move" if r.mode == "migrate"
                                      else "Choose what goes in the theme pack")
            self.review_sub.setText(
                "Everything is ticked except caches and very large folders. "
                "Untick anything you don't want." if r.mode == "migrate" else
                "Only appearance is listed — private data is never offered for a theme pack.")
            self.opts.hide()
            self.lock_box.setVisible(r.mode == "migrate")
            self.opt_lock.setChecked(False)
            self.opt_delete.setChecked(False)
            self._clear_passwords()
        if r.warnings:
            self.review_banner.show_kind("warn", "<br><br>".join(html.escape(w) for w in r.warnings))
        else:
            self.review_banner.hide()

    def _totals_changed(self, ticked: int, total: int, count: int) -> None:
        text = f"<b>{count}</b> items · <b>{human_size(ticked) or '0 B'}</b> of {human_size(total)}"
        if self.result and self.result.mode != "restore":
            free = sysinfo.free_bytes(self.path_edit.text() or str(Path.home()))
            need = ticked * 2   # folder + archive
            colour = "#c0392b" if free and need > free else "inherit"
            text += (f" · <span style='color:{colour}'>free at destination: "
                     f"{human_size(free)}</span>")
            if free and need > free:
                text += " — not enough room for the folder and the archive"
        self.totals.setText(text)

    def _back_to_mode(self) -> None:
        self._cleanup_work()
        self._clear_passwords()
        self.stack.setCurrentWidget(self.page_mode)

    # ── presets ──────────────────────────────────────────────────────────────
    def _save_preset(self) -> None:
        name, ok = QInputDialog.getText(self, "Save preset", "Preset name:")
        if not ok or not name.strip():
            return
        PRESET_DIR.mkdir(parents=True, exist_ok=True)
        safe = re.sub(r"[^\w.-]+", "_", name.strip())
        data = {"app": APP_NAME, "version": __version__, "mode": self.result.mode,
                "checked": self.tree.checked_map()}
        (PRESET_DIR / f"{safe}.json").write_text(json.dumps(data, indent=1))
        QMessageBox.information(self, APP_NAME, f"Saved preset “{name.strip()}”.")

    def _fill_load_menu(self) -> None:
        self.load_menu.clear()
        files = sorted(PRESET_DIR.glob("*.json")) if PRESET_DIR.is_dir() else []
        if not files:
            a = self.load_menu.addAction("(no presets yet)")
            a.setEnabled(False)
        for f in files:
            self.load_menu.addAction(f.stem, lambda p=f: self._load_preset(p))
        self.load_menu.addSeparator()
        self.load_menu.addAction("From file…", self._load_preset_file)

    def _load_preset_file(self) -> None:
        f, _ = QFileDialog.getOpenFileName(self, "Load preset", str(PRESET_DIR), "*.json")
        if f:
            self._load_preset(Path(f))

    def _load_preset(self, path: Path) -> None:
        try:
            data = json.loads(path.read_text())
            n = self.tree.apply_map({k: bool(v) for k, v in data.get("checked", {}).items()})
        except (OSError, ValueError) as e:
            QMessageBox.warning(self, APP_NAME, f"Could not load preset:\n{e}")
            return
        QMessageBox.information(self, APP_NAME, f"Applied “{path.stem}” to {n} items. "
                                "Items not in the preset keep their current state.")

    # ── dry run / start ──────────────────────────────────────────────────────
    def _dry_run(self) -> None:
        extra = ""
        if self.result.mode == "restore":
            extra = ("Login screen switch: " + ("ON" if self.opt_sddm.isChecked() else "off"))
        text = job.dry_run_text(self.result, self.tree.checked_map(), extra,
                                base=self.pack_dir)
        dlg = QMessageBox(self)
        dlg.setWindowTitle("Dry run")
        dlg.setText("This is what would happen:")
        dlg.setDetailedText(text)
        lines = text.splitlines()
        dlg.setInformativeText("\n".join(lines[:14]) + ("\n…" if len(lines) > 14 else ""))
        dlg.exec()

    def _start_run(self) -> None:
        r = self.result
        checked = self.tree.checked_map()
        if not any(checked.values()):
            QMessageBox.warning(self, APP_NAME, "Nothing is ticked.")
            return
        if r.mode == "restore":
            if r.info.get("version_mismatch") and not self.opt_mismatch.isChecked():
                QMessageBox.warning(self, APP_NAME,
                                    "The Plasma versions don't match. Tick the option to "
                                    "continue anyway, or use a pack made on the same version.")
                return
            q = QMessageBox.question(
                self, "Ready to restore?",
                "This will change your desktop settings and may install packages.\n\n"
                "Have you taken a snapshot? If the login screen ever goes black, press "
                "Ctrl+Alt+F3 and see the README's Safety section.\n\nStart the restore?")
            if q != QMessageBox.Yes:
                return
            self.current_job = job.build_restore_job(
                r, checked, self.pack_dir, self.work_root,
                self.opt_sddm.isChecked(), self.opt_mismatch.isChecked())
            self.work_root = None   # now owned by the job's cleanup
        else:
            password, delete = None, False
            if r.mode == "migrate":
                delete = self.opt_delete.isChecked()
                if self.opt_lock.isChecked():
                    password = self.pw1.text()
                    if not password:
                        QMessageBox.warning(self, APP_NAME, "Type a password, or untick "
                                            "“Protect the backup with a password”.")
                        self.pw1.setFocus()
                        return
                    if password != self.pw2.text():
                        QMessageBox.warning(self, APP_NAME, "The two passwords don't match.")
                        self.pw2.setFocus()
                        return
                    if not shutil.which("gpg"):
                        QMessageBox.critical(self, APP_NAME, "Password protection needs gpg, which "
                                             "isn't installed.\n\nInstall it with:\n"
                                             "sudo pacman -S gnupg")
                        return
                    if password_strength(password)[0] < 2 and QMessageBox.question(
                            self, APP_NAME, "This password is weak — someone who gets the file "
                            "could guess it.\n\nUse it anyway?") != QMessageBox.Yes:
                        self.pw1.setFocus()
                        return
            self.current_job = job.build_backup_job(r, checked, self.path_edit.text().strip(),
                                                    password=password, delete_folder=delete)
            password = None
            self._clear_passwords()
        self._run(self.current_job)

    # ── page 3: run ──────────────────────────────────────────────────────────
    def _build_run_page(self) -> QWidget:
        w = QWidget()
        lay = QVBoxLayout(w)
        lay.setContentsMargins(20, 16, 20, 16)
        self.run_title = _title("Working…", 16)
        lay.addWidget(self.run_title)
        self.run_step = QLabel("")
        lay.addWidget(self.run_step)
        self.run_bar = QProgressBar()
        lay.addWidget(self.run_bar)
        self.run_banner = Banner()
        lay.addWidget(self.run_banner)
        self.log = QPlainTextEdit()
        self.log.setReadOnly(True)
        self.log.setMaximumBlockCount(30000)
        self.log.setFont(QFontDatabase.systemFont(QFontDatabase.FixedFont))
        lay.addWidget(self.log, 1)
        row = QHBoxLayout()
        row.addStretch()
        self.btn_cancel = QPushButton(QIcon.fromTheme("process-stop"), "Cancel")
        self.btn_cancel.clicked.connect(self._cancel)
        self.btn_open = QPushButton(QIcon.fromTheme("folder-open"), "Open folder")
        self.btn_open.clicked.connect(lambda: QDesktopServices.openUrl(
            QUrl.fromLocalFile(self._result_folder())))
        self.btn_savelog = QPushButton(QIcon.fromTheme("document-save"), "Save log")
        self.btn_savelog.clicked.connect(self._save_log)
        self.btn_home = QPushButton(QIcon.fromTheme("go-home"), "Start over")
        self.btn_home.clicked.connect(lambda: self.stack.setCurrentWidget(self.page_mode))
        for b in (self.btn_cancel, self.btn_open, self.btn_savelog, self.btn_home):
            row.addWidget(b)
        lay.addLayout(row)
        return w

    def _run(self, j: job.Job) -> None:
        self.log.clear()
        self.run_banner.hide()
        self.out_dir = ""
        self.archive_path = ""
        self._buf = ""
        self.run_title.setText(f"{j.title} in progress…")
        self.run_step.setText(" · ".join(j.summary))
        script = Path(j.program[3]) if len(j.program) > 3 else None
        try:
            self._headers_total = max(1, script.read_text().count('header "')) if script else 1
        except OSError:
            self._headers_total = 1
        self._headers_seen = 0
        self.run_bar.setRange(0, self._headers_total)
        self.run_bar.setValue(0)
        for b, vis in [(self.btn_cancel, True), (self.btn_open, False),
                       (self.btn_savelog, False), (self.btn_home, False)]:
            b.setVisible(vis)
        self.stack.setCurrentWidget(self.page_run)

        self.proc = QProcess(self)
        env = QProcessEnvironment()
        for k, v in j.env.items():
            env.insert(k, v)
        self.proc.setProcessEnvironment(env)
        self.proc.setProcessChannelMode(QProcess.MergedChannels)
        self.proc.setStandardInputFile(QProcess.nullDevice())
        self.proc.readyReadStandardOutput.connect(self._read_output)
        self.proc.finished.connect(self._finished)
        self._append(f"$ {' '.join(j.program[2:])}\n", "#888")
        self.proc.start(j.program[0], j.program[1:])

    def _read_output(self) -> None:
        data = bytes(self.proc.readAllStandardOutput()).decode("utf-8", "replace")
        self._buf += data.replace("\r", "\n")
        lines = self._buf.split("\n")
        self._buf = lines.pop()
        for raw in lines:
            line = ANSI_RE.sub("", raw)
            self._handle_line(line)

    def _handle_line(self, line: str) -> None:
        s = line.strip()
        m = HEADER_RE.match(s)
        if m:
            self._headers_seen += 1
            self.run_bar.setValue(min(self._headers_seen, self._headers_total))
            self.run_step.setText(m.group(1))
            self._append(line, None, bold=True)
            return
        dm = re.match(r"^\s*(Destination|Folder)\s*:\s*(\S.*?)(\s+\(.*\))?$", line)
        if dm and not self.out_dir:
            self.out_dir = dm.group(2)
        am = re.match(r"^\s*Archive\s*:\s*(\S.*?)(\s+\(.*\))?$", line)
        if am and os.path.isabs(am.group(1)):
            self.archive_path = am.group(1)
        colour = None
        if s.startswith("[OK]"):
            colour = "#2e8b57"
        elif s.startswith("[WARN]"):
            colour = "#c08a00"
        elif s.startswith("[ERR]"):
            colour = "#c0392b"
        elif s.startswith("[SKIP]"):
            colour = "#3b7dd8"
        elif s.startswith("?"):
            colour = "#8e44ad"
        self._append(line, colour)

    def _append(self, text: str, colour: str | None, bold: bool = False) -> None:
        esc = html.escape(text.rstrip("\n")) or "&nbsp;"
        style = []
        if colour:
            style.append(f"color:{colour}")
        if bold:
            style.append("font-weight:bold")
        self.log.appendHtml(f"<span style='{';'.join(style)}'>{esc}</span>" if style else
                            f"<span>{esc}</span>")
        self.log.moveCursor(QTextCursor.End)

    def _cancel(self) -> None:
        if not self.proc or self.proc.state() == QProcess.NotRunning:
            return
        if QMessageBox.question(self, APP_NAME, "Stop now? A half-finished restore can leave "
                                "your desktop in a mixed state.") != QMessageBox.Yes:
            return
        pid = self.proc.processId()
        try:
            os.killpg(pid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            self.proc.terminate()
        QTimer.singleShot(5000, lambda: self.proc and self.proc.state() != QProcess.NotRunning
                          and self.proc.kill())

    def _finished(self, code: int, status) -> None:
        if self._buf:
            self._handle_line(ANSI_RE.sub("", self._buf))
            self._buf = ""
        ok = code == 0 and status == QProcess.NormalExit
        j = self.current_job
        self.run_bar.setValue(self._headers_total)
        text = self.log.toPlainText()
        if "ARCHIVE BLOCKED" in text:
            ok = False
            self.run_banner.show_kind("error", "<b>The theme pack was not built.</b> The security "
                                      "scan found something that looks private — it's listed in "
                                      "the log. Untick it and try again.")
        elif ok:
            msg = {"Full backup": "Backup finished. <b>Keep it private</b> — it contains passwords "
                                  "and keys.",
                   "Theme pack": "Theme pack built and passed the security scan. Send your friends "
                                 "the .tar.gz — they open it with HermitCrab's Restore.",
                   "Restore": "Restore finished. <b>Log out and back in</b> (a reboot is "
                              "safest) to see everything."}[j.title]
            if j.title == "Full backup":
                if "Password protected (AES-256)" in text:
                    msg = ("Backup finished and <b>locked with your password</b>. "
                           "If you forget it, the backup can't be opened.")
                if "Backup folder deleted" in text:
                    msg += "<br>The archive was checked first, then the folder was deleted — "
                    msg += "the backup is now one single file."
            deps = self._theme_deps()
            if deps:
                msg += f"<br><br>Your friends will need {deps}."
            self.run_banner.show_kind("ok", msg)
        else:
            self.run_banner.show_kind("error", f"<b>{j.title} stopped with an error</b> "
                                      f"(exit code {code}). The log below shows where.")
        self.run_title.setText(f"{j.title} {'done' if ok else 'stopped'}")
        for b, vis in [(self.btn_cancel, False), (self.btn_open, j.title != "Restore"),
                       (self.btn_savelog, True), (self.btn_home, True)]:
            b.setVisible(vis)
        self._run_cleanup(j)
        self.proc = None

    def _run_cleanup(self, j: job.Job | None) -> None:
        for p in (j.cleanup if j else []):
            shutil.rmtree(p, ignore_errors=True)

    def _result_folder(self) -> str:
        if self.archive_path and Path(self.archive_path).exists():
            return str(Path(self.archive_path).parent)
        if self.out_dir and Path(self.out_dir).is_dir():
            return self.out_dir
        return self.current_job.output_hint

    def _theme_deps(self) -> str:
        if not self.current_job or self.current_job.title != "Theme pack" or not self.out_dir:
            return ""
        d = Path(self.out_dir) / "dependencies"
        n = sum(len([l for l in (d / f).read_text().splitlines() if l.strip()])
                for f in ("native.txt", "aur.txt") if (d / f).is_file())
        return f"{n} packages (installed automatically on restore)" if n else ""

    def _save_log(self) -> None:
        f, _ = QFileDialog.getSaveFileName(self, "Save log", str(
            Path.home() / f"hermitcrab-{time.strftime('%Y%m%d-%H%M%S')}.log"))
        if f:
            Path(f).write_text(self.log.toPlainText())

    # ── lifecycle ────────────────────────────────────────────────────────────
    def _cleanup_work(self) -> None:
        if self.work_root:
            shutil.rmtree(self.work_root, ignore_errors=True)
            self.work_root = None

    def closeEvent(self, ev) -> None:
        if self.proc and self.proc.state() != QProcess.NotRunning:
            if QMessageBox.question(self, APP_NAME, "A job is still running. Stop it and quit?") \
                    != QMessageBox.Yes:
                ev.ignore()
                return
            try:
                os.killpg(self.proc.processId(), signal.SIGTERM)
            except (ProcessLookupError, PermissionError):
                pass
            self.proc.waitForFinished(5000)
            self._run_cleanup(self.current_job)
        self._cleanup_work()
        ev.accept()


def run() -> int:
    QApplication.setApplicationName("hermitcrab")
    QApplication.setApplicationDisplayName(APP_NAME)
    # The desktop portal rejects an app ID it can't find a .desktop file for
    # ("App info not found"), so only claim it once the launcher is installed.
    if desktop.is_installed() or Path(f"/usr/share/applications/{APP_ID}.desktop").exists():
        QApplication.setDesktopFileName(APP_ID)
    app = QApplication(sys.argv)
    theme.apply(app)
    icon = desktop.icon_path()
    if icon:
        app.setWindowIcon(QIcon(str(icon)))
    win = MainWindow()
    win.show()
    return app.exec()
