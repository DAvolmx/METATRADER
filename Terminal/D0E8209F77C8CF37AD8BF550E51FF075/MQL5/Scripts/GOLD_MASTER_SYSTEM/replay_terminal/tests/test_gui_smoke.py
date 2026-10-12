"""
Prueba de humo de la interfaz (sin pantalla: QT_QPA_PLATFORM=offscreen).
Carga datos, avanza el replay, opera en simulación, dibuja, entra en mercado
sintético, ejecuta un backtest y comprueba que nada se rompe.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
QtWidgets = pytest.importorskip("PySide6.QtWidgets")
pytest.importorskip("pyqtgraph")


@pytest.fixture(scope="module")
def app():
    return QtWidgets.QApplication.instance() or QtWidgets.QApplication([])


def test_gui_end_to_end(app, history_m1, gold_spec, tmp_path, monkeypatch):
    from PySide6 import QtCore
    for n in ("warning", "information", "critical"):
        monkeypatch.setattr(QtWidgets.QMessageBox, n, staticmethod(lambda *a, **k: None))
    from data.data_manager import resample_ohlc
    from ui.main_window import MainWindow
    w = MainWindow(db_path=tmp_path / "gui.db")
    df5 = resample_ohlc(history_m1, "M1", "M5").drop(columns="complete")
    w.spec = gold_spec
    w.chk_synth.setChecked(True)
    w.start_dt.setDateTime(QtCore.QDateTime(df5["time"].iloc[600].to_pydatetime().replace(tzinfo=None)))
    w._build_session(df5, "M5")
    assert w.mode.name == "REPLAY"
    for _ in range(20):
        w._next()
    w.trade_panel.sl_mode.setCurrentText("POINTS")
    w.trade_panel.sl.setValue(300)
    w._order("BUY", w.trade_panel.params())
    assert len(w.paper.trades) == 1 and w.paper.trades[0].volume > 0
    w._save_drawing(w.charts[0], "hline", {"t1": df5["time"].iloc[600].isoformat(), "p1": 2300.0})
    w._prev()
    assert not w._can_trade()[0]                 # mirando el pasado no se opera
    w._jump(df5["time"].iloc[-1].to_pydatetime())
    for _ in range(30):
        w._next()
    assert w.replay.in_synthetic_zone and w.mode.name == "SYNTHETIC"
    assert w.trade_panel.route.text().startswith("Destino: SIMULACIÓN")
    w._run_backtest(w.bt_panel.params())
    w.pool.waitForDone(120000)
    for _ in range(5):
        app.processEvents()
    assert w.bt_result is not None
    w.close()


def test_drawing_drag_and_delete(app, history_m1, tmp_path):
    """Arrastrar un ancla y el cuerpo de una trendline, y borrarla."""
    from PySide6 import QtCore
    from charts.chart_widget import ChartWidget
    ch = ChartWidget("M1")
    ch.resize(900, 500)
    ch.show()
    df = history_m1.head(200)
    ch.set_bars(df)
    app.processEvents()
    t1, t2 = df["time"].iloc[50], df["time"].iloc[120]
    d = {"id": 7, "kind": "trend", "style": {"color": "#fff"},
         "coordinates": {"t1": t1.isoformat(), "p1": float(df["low"].iloc[50]),
                         "t2": t2.isoformat(), "p2": float(df["high"].iloc[120])}}
    ch.draw_drawings([d])
    got = []
    ch.drawing_modified.connect(lambda i, c, s: got.append((i, dict(c))))
    # 1) ancla 2
    a2 = ch._to_px(*ch._anchors(ch._drawings[0])[2])
    hit = ch.hit_test(a2)
    assert hit == (7, "anchor", 2)
    ch.begin_drag(hit, ch.plot.vb.mapSceneToView(a2))
    ch.update_drag(QtCore.QPointF(150, float(df["high"].iloc[120]) + 1))
    ch.finish_drag()
    assert got and got[-1][1]["t2"] == df["time"].iloc[150].isoformat()
    assert got[-1][1]["p2"] == pytest.approx(float(df["high"].iloc[120]) + 1)
    # 2) cuerpo: mitad del segmento -> mueve todo 10 velas
    an = ch._anchors(ch._drawings[0])
    mid = QtCore.QPointF((an[1][0] + an[2][0]) / 2, (an[1][1] + an[2][1]) / 2)
    hit = ch.hit_test(ch._to_px(mid.x(), mid.y()))
    assert hit == (7, "body", 0)
    ch.begin_drag(hit, mid)
    ch.update_drag(QtCore.QPointF(mid.x() + 10, mid.y()))
    ch.finish_drag()
    assert got[-1][1]["t1"] == df["time"].iloc[60].isoformat()
    # 3) borrar
    deleted = []
    ch.drawing_deleted.connect(deleted.append)
    ch.select(7)
    ch.delete_selected()
    assert deleted == [7]
    ch.close()


def test_speed_slider(app):
    from ui.replay_panel import ReplayPanel
    rp = ReplayPanel()
    got = []
    rp.speed.connect(got.append)
    rp.set_speed_value(37)
    assert got[-1] == 37 and rp.speed_label.text() == "37x"
    rp.speed_slider.setValue(0)
    assert got[-1] == pytest.approx(0.1)
    rp.speed_slider.setValue(1000)
    assert got[-1] == pytest.approx(200, rel=0.01)
