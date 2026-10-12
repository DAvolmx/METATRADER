"""Detiene supervisor, servicio y dashboard de GOLD MASTER (primero el supervisor para que no los relance)."""
import subprocess
def kill(pattern):
    ps = ("Get-CimInstance Win32_Process -Filter \"Name='python.exe'\" | "
          f"? {{ $_.CommandLine -like '*{pattern}*' }} | % {{ Stop-Process -Id $_.ProcessId -Force; 'detenido {pattern} ' + $_.ProcessId }}")
    print(subprocess.run(["powershell", "-NoProfile", "-Command", ps], capture_output=True, text=True).stdout, end="")
for p in ("gm_supervisor", "gm_service", "dashboard_v3"): kill(p)
