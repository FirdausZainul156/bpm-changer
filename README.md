# bpm-changer
Windows tool that changes the tempo of an audio file without changing its pitch. Detects the original BPM automatically, has tap tempo, and can optionally separate vocals and instrumentals with Demucs.
# BPM Changer

Change the tempo of an audio file without changing its pitch. It detects the original BPM automatically, offers half/double hints and a tap-tempo button, and can optionally save separate vocal and instrumental files.

## Requirements
- Windows with PowerShell 5.1 or newer
- FFmpeg, installed **before** you run the tool
- Optional: Python and Demucs for vocal/instrumental separation

## 1. Install FFmpeg
Open PowerShell and run:

```powershell
winget install Gyan.FFmpeg
```

Close and reopen PowerShell, then check it works:

```powershell
ffmpeg -version
```

(FFmpeg can also sit in the same folder as the script.)

## 2. Run the tool
Download `BPM-Changer-v1_1_0.ps1`, open PowerShell in that folder and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\BPM-Changer-v1_1_0.ps1
```

## 3. Optional: vocal/instrumental split
```powershell
pip install demucs
```

## How to use
1. Drag an audio file into the window.
2. Check the detected BPM (use tap tempo to confirm by ear).
3. Type your target BPM and convert.
