"""Execution boundary: research terminal supports only replay, paper, and MT5 reads."""

class TradingBlocked(Exception):
    pass

class LiveExecutionEngine:
    def __init__(self, app_state, *args, **kwargs):
        self.state = app_state
        self.state.revoke_real_trading()

    def _blocked(self, *args, **kwargs):
        self.state.revoke_real_trading()
        raise TradingBlocked("Este terminal permite datos LIVE y operaciones simuladas. Ejecución MT5 deshabilitada.")

    authorize = preview = send = close_position = _blocked

    def kill_switch(self):
        self.state.revoke_real_trading()
        self.state.lock_trading()

    def own_positions(self):
        return []
