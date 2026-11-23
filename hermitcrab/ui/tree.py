"""The review tree: every scanned item with a checkbox, size and location."""

from __future__ import annotations

from PySide6.QtCore import Qt, Signal
from PySide6.QtGui import QBrush, QColor, QFont
from PySide6.QtWidgets import QHeaderView, QTreeWidget, QTreeWidgetItem

from ..model import GROUP, Item, ScanResult, human_size

ROLE_ITEM = Qt.UserRole + 1
ROLE_SIZE = Qt.UserRole + 2    # total bytes under this row (for sorting)
ROLE_ORDER = Qt.UserRole + 3   # position in the original scan order
COL_NAME, COL_SIZE, COL_WHERE = 0, 1, 2

SORT_ORIGINAL, SORT_SIZE, SORT_NAME = "original", "size", "name"


class SortItem(QTreeWidgetItem):
    """Sorts by real byte counts, not by the "1.2 GB" text in the column."""

    def __lt__(self, other: QTreeWidgetItem) -> bool:
        mode = getattr(self.treeWidget(), "sort_mode", SORT_ORIGINAL)
        if mode == SORT_SIZE:
            return (self.data(COL_NAME, ROLE_SIZE) or 0) < (other.data(COL_NAME, ROLE_SIZE) or 0)
        if mode == SORT_NAME:
            a = self.text(COL_NAME).removeprefix("🔒 ").lower()
            b = other.text(COL_NAME).removeprefix("🔒 ").lower()
            return a < b
        return (self.data(COL_NAME, ROLE_ORDER) or 0) < (other.data(COL_NAME, ROLE_ORDER) or 0)


class SelectionTree(QTreeWidget):
    # object, not int: Qt's int is 32-bit and overflows past 2 GB
    selectionChangedTotals = Signal(object, object, object)  # ticked bytes, total bytes, count

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setColumnCount(3)
        self.setHeaderLabels(["Item", "Size", "Details"])
        self.setUniformRowHeights(True)
        self.setAlternatingRowColors(True)
        self.setAnimated(True)
        h = self.header()
        h.setStretchLastSection(True)
        h.setSectionResizeMode(COL_NAME, QHeaderView.Interactive)
        h.setSectionResizeMode(COL_SIZE, QHeaderView.ResizeToContents)
        self.setColumnWidth(COL_NAME, 380)
        self.result: ScanResult | None = None
        self._qitems: dict[str, QTreeWidgetItem] = {}
        self._updating = False
        self._order = 0
        self.sort_mode = SORT_ORIGINAL
        self.itemChanged.connect(self._on_changed)
        # Click a column header to sort by it; click again to go back
        h.setSectionsClickable(True)
        h.sectionClicked.connect(self._header_clicked)
        h.setSortIndicatorShown(False)

    # ── build ────────────────────────────────────────────────────────────────
    def load(self, result: ScanResult) -> None:
        self._updating = True
        self.clear()
        self._qitems.clear()
        self._order = 0
        self.result = result
        for root in result.roots:
            q = self._make(root, None)
            self.addTopLevelItem(q)
            q.setExpanded(False)
            f = q.font(COL_NAME)
            f.setBold(True)
            q.setFont(COL_NAME, f)
        self._updating = False
        self._refresh_sizes()
        self.apply_sort(self.sort_mode)

    def _make(self, it: Item, parent: QTreeWidgetItem | None) -> QTreeWidgetItem:
        q = SortItem(parent)
        self._order += 1
        q.setData(COL_NAME, ROLE_ORDER, self._order)
        label = ("🔒 " if it.private else "") + it.label
        q.setText(COL_NAME, label)
        q.setText(COL_WHERE, it.note or self._short(it.location))
        q.setToolTip(COL_NAME, "\n".join(it.paths[:20] or it.packages[:20]) or it.label)
        q.setToolTip(COL_WHERE, q.text(COL_WHERE))
        q.setTextAlignment(COL_SIZE, Qt.AlignRight | Qt.AlignVCenter)
        q.setData(COL_NAME, ROLE_ITEM, it)
        flags = q.flags() | Qt.ItemIsUserCheckable
        if it.children:
            flags |= Qt.ItemIsAutoTristate
        q.setFlags(flags)
        if it.private:
            q.setForeground(COL_NAME, QBrush(QColor("#c0392b")))
        if it.children:
            for c in it.children:
                self._make(c, q)
        else:
            q.setCheckState(COL_NAME, Qt.Checked if it.default else Qt.Unchecked)
        self._qitems[it.id] = q
        return q

    @staticmethod
    def _short(p: str) -> str:
        from pathlib import Path
        h = str(Path.home())
        return "~" + p[len(h):] if p.startswith(h) else p

    # ── state ────────────────────────────────────────────────────────────────
    def checked_map(self) -> dict[str, bool]:
        out = {}
        for iid, q in self._qitems.items():
            it: Item = q.data(COL_NAME, ROLE_ITEM)
            if not it.children:
                out[iid] = q.checkState(COL_NAME) == Qt.Checked
        return out

    def apply_map(self, states: dict[str, bool]) -> int:
        n = 0
        self._updating = True
        for iid, on in states.items():
            q = self._qitems.get(iid)
            if q is not None and not q.data(COL_NAME, ROLE_ITEM).children:
                q.setCheckState(COL_NAME, Qt.Checked if on else Qt.Unchecked)
                n += 1
        self._updating = False
        self._refresh_sizes()
        return n

    def set_all(self, on: bool) -> None:
        self._updating = True
        for q in self._qitems.values():
            if not q.data(COL_NAME, ROLE_ITEM).children and not q.isHidden():
                q.setCheckState(COL_NAME, Qt.Checked if on else Qt.Unchecked)
        self._updating = False
        self._refresh_sizes()

    def reset_defaults(self) -> None:
        self._updating = True
        for q in self._qitems.values():
            it: Item = q.data(COL_NAME, ROLE_ITEM)
            if not it.children:
                q.setCheckState(COL_NAME, Qt.Checked if it.default else Qt.Unchecked)
        self._updating = False
        self._refresh_sizes()

    # ── sorting ──────────────────────────────────────────────────────────────
    sortModeChanged = Signal(str)

    def apply_sort(self, mode: str) -> None:
        """Re-order every level of the tree. Size sorts biggest first and uses
        the FULL size of a row, so rows don't jump around while you untick."""
        self.sort_mode = mode
        h = self.header()
        if mode == SORT_SIZE:
            self.sortItems(COL_SIZE, Qt.DescendingOrder)
            h.setSortIndicator(COL_SIZE, Qt.DescendingOrder)
            h.setSortIndicatorShown(True)
        elif mode == SORT_NAME:
            self.sortItems(COL_NAME, Qt.AscendingOrder)
            h.setSortIndicator(COL_NAME, Qt.AscendingOrder)
            h.setSortIndicatorShown(True)
        else:
            self.sortItems(COL_NAME, Qt.AscendingOrder)
            h.setSortIndicatorShown(False)
        self.sortModeChanged.emit(mode)

    def _header_clicked(self, col: int) -> None:
        wanted = {COL_SIZE: SORT_SIZE, COL_NAME: SORT_NAME}.get(col)
        if wanted is None:
            return
        self.apply_sort(SORT_ORIGINAL if self.sort_mode == wanted else wanted)

    # ── filtering ────────────────────────────────────────────────────────────
    def filter(self, text: str) -> None:
        text = text.strip().lower()

        def visit(q: QTreeWidgetItem) -> bool:
            it: Item = q.data(COL_NAME, ROLE_ITEM)
            hay = " ".join([it.label, it.note, *it.paths[:3], *it.packages[:3]]).lower()
            own = not text or text in hay
            child_hit = False
            for i in range(q.childCount()):
                child_hit |= visit(q.child(i))
            if own and text:
                # a matching group shows all its children
                for i in range(q.childCount()):
                    self._unhide(q.child(i))
            show = own or child_hit
            q.setHidden(not show)
            if text and child_hit:
                q.setExpanded(True)
            return show

        for i in range(self.topLevelItemCount()):
            visit(self.topLevelItem(i))

    def _unhide(self, q: QTreeWidgetItem) -> None:
        q.setHidden(False)
        for i in range(q.childCount()):
            self._unhide(q.child(i))

    # ── sizes ────────────────────────────────────────────────────────────────
    def _on_changed(self, q: QTreeWidgetItem, col: int) -> None:
        if col == COL_NAME and not self._updating:
            self._refresh_sizes()

    def _refresh_sizes(self) -> None:
        self.blockSignals(True)
        totals = [0, 0, 0]

        def visit(q: QTreeWidgetItem) -> tuple[int, int]:
            it: Item = q.data(COL_NAME, ROLE_ITEM)
            if q.childCount() == 0:
                on = q.checkState(COL_NAME) == Qt.Checked
                ticked = it.size if on else 0
                totals[0] += ticked
                totals[1] += it.size
                totals[2] += 1 if on else 0
                q.setText(COL_SIZE, human_size(it.size))
                q.setData(COL_NAME, ROLE_SIZE, it.size)
                self._dim(q, not on)
                return ticked, it.size
            t = a = 0
            for i in range(q.childCount()):
                ct, ca = visit(q.child(i))
                t += ct
                a += ca
            if a:
                q.setText(COL_SIZE, human_size(t) if t == a else
                          f"{human_size(t) or '0'} of {human_size(a)}")
            else:
                q.setText(COL_SIZE, "")
            q.setData(COL_NAME, ROLE_SIZE, a)
            self._dim(q, q.checkState(COL_NAME) == Qt.Unchecked)
            return t, a

        for i in range(self.topLevelItemCount()):
            visit(self.topLevelItem(i))
        self.blockSignals(False)
        self.selectionChangedTotals.emit(*totals)

    def _dim(self, q: QTreeWidgetItem, off: bool) -> None:
        it: Item = q.data(COL_NAME, ROLE_ITEM)
        col = self.palette().color(self.palette().ColorGroup.Disabled,
                                   self.palette().ColorRole.Text)
        for c in (COL_SIZE, COL_WHERE):
            q.setForeground(c, QBrush(col) if off else QBrush())
        if not it.private:
            q.setForeground(COL_NAME, QBrush(col) if off else QBrush())