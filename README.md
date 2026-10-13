# Kompresor PRO

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](https://opensource.org/licenses/MIT)

🇬🇧 Quick start — English below  
🇵🇱 Szybki start — polski poniżej

<p align="center">
  <img src="https://github.com/user-attachments/assets/0f317399-1ec4-4e03-9b7e-d5bc2a87d64c" width="48%" alt="Kompresor PRO GUI">
  <img src="https://github.com/user-attachments/assets/74b659ff-753f-451f-88f7-9539c2dc3830" width="48%" alt="Licencja">
</p>
---

# 🇬🇧 ENGLISH

## What it is
- Simple Windows GUI frontend (PowerShell + WinForms) that uses FFmpeg to batch-compress videos.
- Auto-detects available encoders (NVENC/libx265/libx264/AV1) and shows only usable options.

## Requirements
- Windows 10/11
- PowerShell 5+
- [`ffmpeg.exe`](https://ffmpeg.org/download.html) and [`ffprobe.exe`](https://ffmpeg.org/download.html) available next to the script or in PATH

## Run (two options)
1. Run the included batch launcher (recommended for normal use — closes the CMD window right away):
   - Double‑click `start.bat` (or run it from Explorer).
   - `start.bat` launches the script so only the GUI is visible (no lingering console).
2. Run the PowerShell script directly (useful for debugging / visible console):
   - Open PowerShell and run:
     `powershell -NoProfile -ExecutionPolicy Bypass -File "kompresor_PRO.ps1"`

## Notes
- If GUI does not appear: try option 1 to see console errors, or check `%~dp0kompressor_run.log` if you use the logging variant.

## Troubleshooting
- If FFmpeg is missing or not in PATH the script will show status in the footer and in the GUI log.
- If you need admin privileges to access devices/folders, run PowerShell / start.bat as Administrator.

## ⚖️ License
- **MIT License** — Free to use, modify, and distribute for everyone.


---

# 🇵🇱 POLSKI

## Czym jest
- Prosty GUI (PowerShell + WinForms) korzystający z FFmpeg do wsadowej kompresji wideo.
- Automatyczne wykrywanie enkoderów (NVENC/libx265/libx264/AV1) — dostępne pozycje są widoczne w GUI.

## Wymagania
- Windows 10/11
- PowerShell 5+
- [`ffmpeg.exe`](https://ffmpeg.org/download.html) i [`ffprobe.exe`](https://ffmpeg.org/download.html) obok skryptu lub w PATH

## Uruchomienie (dwie opcje)
1. Uruchom dostarczony launcher .bat (zalecane do normalnego użycia):
   - Dwukliknij `start.bat` (albo uruchom z Explorera).
   - `start.bat` uruchamia skrypt tak, że widoczne jest tylko GUI (bez konsoli).
2. Uruchom skrypt PowerShell bezpośrednio (przydatne do debugowania / widoczny terminal):
   - Otwórz PowerShell i uruchom:
     `powershell -NoProfile -ExecutionPolicy Bypass -File "kompresor_PRO.ps1"`

## Uwagi
- Jeśli GUI się nie pokazuje: spróbuj opcji 1, aby zobaczyć błędy w konsoli, lub sprawdź plik log (jeśli używasz wariantu z logowaniem).

## Rozwiązywanie problemów
- Jeśli FFmpeg nie jest wykryty — zobaczysz to w stopce GUI oraz w logu.
- Jeżeli wymagane są uprawnienia administratora, uruchom PowerShell / start.bat jako Administrator.

## ⚖️ Licencja
- **Licencja MIT** — Wolny do użytku, modyfikacji i dystrybucji dla każdego (free to all).
