"""ui/dialogs.py — Confirmaciones de seguridad."""
from __future__ import annotations

from PySide6 import QtWidgets


def confirm_real_trading(parent, login, server) -> bool:
    box = QtWidgets.QMessageBox(parent)
    box.setIcon(QtWidgets.QMessageBox.Warning)
    box.setWindowTitle("⚠ OPERACIONES REALES")
    box.setText("⚠ OPERACIONES REALES\n\nLas siguientes acciones enviarán órdenes reales\n"
                f"a la cuenta conectada de MetaTrader 5.\n\nCuenta:\n{login}\n\nServidor:\n{server}\n\n"
                "¿Deseas continuar?")
    box.setStandardButtons(QtWidgets.QMessageBox.Yes | QtWidgets.QMessageBox.No)
    box.setDefaultButton(QtWidgets.QMessageBox.No)
    if box.exec() != QtWidgets.QMessageBox.Yes:
        return False
    text, ok = QtWidgets.QInputDialog.getText(
        parent, "Confirmación final", f"Escribe el número de cuenta ({login}) para autorizar:")
    return ok and text.strip() == str(login)


def confirm_order(parent, pv, currency: str) -> bool:
    def fmt(x):
        return "N/A" if x is None else f"{x:.2f} {currency}"
    msg = (f"🔴 ORDEN REAL\n\n{pv.direction} {pv.volume} {pv.symbol} @ {pv.price}\n"
           f"SL: {pv.sl}   TP: {pv.tp}\n\nRiesgo: {fmt(pv.risk_money)}\nBeneficio objetivo: {fmt(pv.reward_money)}\n"
           f"Margen: {fmt(pv.margin)}\n\norder_check: retcode {pv.check_retcode} ({pv.check_comment})\n"
           f"Cuenta {pv.account} @ {pv.server}\n\n¿Enviar la orden?")
    r = QtWidgets.QMessageBox.question(parent, "Confirmar orden real", msg,
                                       QtWidgets.QMessageBox.Yes | QtWidgets.QMessageBox.No,
                                       QtWidgets.QMessageBox.No)
    return r == QtWidgets.QMessageBox.Yes


def account_changed(parent, old, new) -> None:
    QtWidgets.QMessageBox.critical(
        parent, "CAMBIO DE CUENTA DETECTADO",
        f"CAMBIO DE CUENTA DETECTADO\n\nCuenta anterior:\n{old}\n\nCuenta actual:\n{new}\n\n"
        "Las operaciones reales han sido bloqueadas hasta verificar la nueva conexión.\n"
        "Debes volver a autorizar el trading real si lo necesitas.")


def confirm(parent, title, text) -> bool:
    return QtWidgets.QMessageBox.question(parent, title, text,
                                          QtWidgets.QMessageBox.Yes | QtWidgets.QMessageBox.No,
                                          QtWidgets.QMessageBox.No) == QtWidgets.QMessageBox.Yes
