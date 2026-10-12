"""ui/style.py — Tema oscuro tipo terminal profesional."""
QSS = """
QWidget { background:#131722; color:#d1d4dc; font-family:'Segoe UI'; font-size:9pt; }
QGroupBox { border:1px solid #2a2e39; border-radius:4px; margin-top:8px; padding:6px; }
QGroupBox::title { subcontrol-origin: margin; left:8px; color:#787b86; }
QPushButton { background:#2a2e39; border:1px solid #363a45; border-radius:3px; padding:4px 10px; }
QPushButton:hover { background:#363a45; }
QPushButton:disabled { color:#555; }
QPushButton#buy { background:#1b5e57; font-weight:bold; }
QPushButton#sell { background:#7f2b2a; font-weight:bold; }
QPushButton#danger { background:#b71c1c; font-weight:bold; }
QPushButton#auth { background:#e65100; font-weight:bold; }
QLineEdit, QComboBox, QSpinBox, QDoubleSpinBox, QDateTimeEdit {
  background:#1e222d; border:1px solid #363a45; border-radius:3px; padding:2px 4px; }
QTabWidget::pane { border:1px solid #2a2e39; }
QTabBar::tab { background:#1e222d; padding:5px 12px; border:1px solid #2a2e39; }
QTabBar::tab:selected { background:#2a2e39; }
QTableWidget { gridline-color:#2a2e39; background:#131722; }
QHeaderView::section { background:#1e222d; border:0; padding:3px; }
QPlainTextEdit { background:#0e1118; font-family:Consolas,monospace; }
QLabel#mode_LIVE { background:#1565c0; color:white; font-weight:bold; padding:3px 8px; }
QLabel#mode_REPLAY { background:#6a1b9a; color:white; font-weight:bold; padding:3px 8px; }
QLabel#mode_SIMULATION { background:#2e7d32; color:white; font-weight:bold; padding:3px 8px; }
QLabel#mode_SYNTHETIC { background:#8e24aa; color:white; font-weight:bold; padding:3px 8px; }
QLabel#mode_REAL { background:#c62828; color:white; font-weight:bold; padding:3px 8px; }
"""
