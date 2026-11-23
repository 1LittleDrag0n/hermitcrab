"""SUDO_ASKPASS helper: shows a password dialog and prints the answer.

sudo runs this whenever a backend script needs root and there is no
terminal. The password goes to sudo's stdin and nowhere else.
"""

from __future__ import annotations

import sys


def main(argv: list[str]) -> int:
    from PySide6.QtWidgets import QApplication, QInputDialog, QLineEdit

    from .ui import theme

    app = QApplication.instance() or QApplication(sys.argv[:1])
    theme.apply(app)
    prompt = " ".join(argv).strip() or "Password:"
    text, ok = QInputDialog.getText(
        None, "HermitCrab — administrator access",
        "HermitCrab needs your password for a step that changes system files\n"
        "(login screen, Wi-Fi, packages).\n\n" + prompt,
        QLineEdit.Password)
    if not ok:
        return 1
    sys.stdout.write(text + "\n")
    sys.stdout.flush()
    return 0
