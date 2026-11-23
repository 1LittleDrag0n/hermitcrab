"""PyInstaller entry point (the AppImage binary)."""

import sys

from hermitcrab.__main__ import main

if __name__ == "__main__":
    sys.exit(main())
