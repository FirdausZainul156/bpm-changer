<#
.SYNOPSIS
    BPM Changer - change the tempo of an audio file without changing its pitch.

.DESCRIPTION
    - Detects the original BPM automatically (first 2 minutes of the track)
    - Shows the half / double alternatives and has a "Tap tempo" button to confirm by ear
    - Lets you type a target BPM (e.g. 100 -> 110)
    - Uses FFmpeg's "atempo" filter, so the pitch stays the same
    - OPTIONAL: also saves separate vocal and instrumental files (needs Demucs)

.NOTES
    Version : 1.1.0
    Requires: Windows, PowerShell 5.1+, FFmpeg (in PATH or next to this script)
    Optional: Python + Demucs for vocal/instrumental separation:  pip install demucs

    Changelog
    1.1.0  Added optional vocal/instrumental split (Demucs), Tap tempo button,
           half/double hints after detection, cancel running jobs when window closes.
    1.0.0  First GUI version: BPM detection, target BPM, drag & drop, atempo conversion.
#>

$script:AppVersion = '1.1.0'
$script:AppName    = 'BPM Changer'
$ErrorActionPreference = 'Stop'

# WinForms needs a Single-Threaded Apartment. Relaunch if needed.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $psExe = (Get-Process -Id $PID).Path
    Start-Process -FilePath $psExe -ArgumentList '-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------------------
# BPM detector (compiled C# for speed) + DPI helper
# ---------------------------------------------------------------------------
if (-not ('BpmDetector' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;

public static class NativeHelper
{
    [DllImport("user32.dll")]
    private static extern bool SetProcessDPIAware();

    public static void EnableDpiAwareness()
    {
        try { SetProcessDPIAware(); } catch (Exception) { }
    }
}

public static class BpmDetector
{
    // Reads raw mono 16-bit PCM and estimates the tempo. Returns 0 if it cannot.
    public static double Detect(string rawPath, int sampleRate)
    {
        byte[] bytes = File.ReadAllBytes(rawPath);
        int n = bytes.Length / 2;
        const int hop = 128;
        int frames = n / hop;
        if (frames < 400) return 0;

        // 1) Loudness envelope
        double[] env = new double[frames];
        for (int f = 0; f < frames; f++)
        {
            double sum = 0;
            int off = f * hop;
            for (int i = 0; i < hop; i++)
            {
                double s = BitConverter.ToInt16(bytes, (off + i) * 2) / 32768.0;
                sum += s * s;
            }
            env[f] = Math.Log(1.0 + 1000.0 * Math.Sqrt(sum / hop));
        }

        // 2) Onset strength (rising edges only)
        double[] onset = new double[frames];
        for (int f = 1; f < frames; f++)
        {
            double d = env[f] - env[f - 1];
            onset[f] = d > 0 ? d : 0;
        }

        // 3) Remove local average (~1 second window)
        double[] cs = new double[frames + 1];
        for (int i = 0; i < frames; i++) cs[i + 1] = cs[i] + onset[i];
        int w = (int)(sampleRate / (double)hop);
        double[] flat = new double[frames];
        for (int f = 0; f < frames; f++)
        {
            int lo = Math.Max(0, f - w);
            int hi = Math.Min(frames, f + w + 1);
            double mean = (cs[hi] - cs[lo]) / (hi - lo);
            double v = onset[f] - mean;
            flat[f] = v > 0 ? v : 0;
        }

        // 4) Autocorrelation over candidate tempos (70-180 BPM)
        double fps = sampleRate / (double)hop;
        double bestBpm = 0, bestScore = double.MinValue;
        for (double bpm = 70.0; bpm <= 180.0; bpm += 0.25)
        {
            double lag = fps * 60.0 / bpm;
            double score = Ac(flat, lag) + 0.5 * Ac(flat, 2.0 * lag) + 0.25 * Ac(flat, 4.0 * lag);
            double oct = Math.Log(bpm / 120.0, 2.0);
            score *= Math.Exp(-0.5 * oct * oct / (0.9 * 0.9));   // mild preference for common tempos
            if (score > bestScore) { bestScore = score; bestBpm = bpm; }
        }
        return Math.Round(bestBpm, 1);
    }

    private static double Ac(double[] x, double lag)
    {
        int li = (int)lag;
        double fr = lag - li;
        int n = x.Length - li - 1;
        if (n < 50) return 0;
        double sum = 0;
        for (int i = 0; i < n; i++)
            sum += x[i] * (x[i + li] * (1.0 - fr) + x[i + li + 1] * fr);
        return sum / n;
    }
}
'@
}

[NativeHelper]::EnableDpiAwareness()
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------------------------------------------------------------------------
# State + helpers
# ---------------------------------------------------------------------------
$script:Inv         = [Globalization.CultureInfo]::InvariantCulture
$script:InputFile   = $null
$script:OutManual   = $false
$script:Closing     = $false
$script:CurrentProc = $null
$script:Clock       = [Diagnostics.Stopwatch]::StartNew()
$script:TapTimes    = New-Object 'System.Collections.Generic.List[double]'

function Find-FFmpeg {
    $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    if ($PSScriptRoot) {
        $local = Join-Path $PSScriptRoot 'ffmpeg.exe'
        if (Test-Path $local) { return $local }
    }
    return $null
}

function Test-Quiet([string]$File, [string]$ArgLine) {
    try {
        $p = Start-Process -FilePath $File -ArgumentList $ArgLine -WindowStyle Hidden -PassThru -Wait
        return ($p.ExitCode -eq 0)
    } catch { return $false }
}

# Looks for Demucs (optional). Returns @{ File; Prefix } or $null.
function Find-Demucs {
    $d = Get-Command demucs -ErrorAction SilentlyContinue
    if ($d) { return @{ File = $d.Source; Prefix = '' } }
    foreach ($py in 'python', 'py') {
        $c = Get-Command $py -ErrorAction SilentlyContinue
        if ($c -and (Test-Quiet $c.Source '-c "import demucs"')) {
            return @{ File = $c.Source; Prefix = '-m demucs ' }
        }
    }
    return $null
}

$script:FFmpeg = Find-FFmpeg
if (-not $script:FFmpeg) {
    [void][System.Windows.Forms.MessageBox]::Show(
        "FFmpeg was not found.`n`nInstall it with:`n    winget install ffmpeg`n`n(or put ffmpeg.exe next to this script), then run again.",
        "$script:AppName v$script:AppVersion", 'OK', 'Error')
    exit 1
}
$script:Demucs = Find-Demucs

function Stop-ProcessTree($p) {
    try {
        Start-Process -FilePath 'taskkill.exe' -ArgumentList "/PID $($p.Id) /T /F" -WindowStyle Hidden -Wait
    } catch { }
}

function Invoke-Process([string]$FilePath, [string]$ArgLine) {
    $errFile = [IO.Path]::GetTempFileName()
    $p = Start-Process -FilePath $FilePath -ArgumentList $ArgLine -WindowStyle Hidden -PassThru -RedirectStandardError $errFile
    $null = $p.Handle   # keeps the process handle so ExitCode is available
    $script:CurrentProc = $p
    while (-not $p.HasExited) {
        if ($script:Closing) { break }
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 50
    }
    if ($script:Closing) {
        Stop-ProcessTree $p
        Remove-Item $errFile -ErrorAction SilentlyContinue
        return [pscustomobject]@{ ExitCode = -1; Error = '' }
    }
    $p.WaitForExit()
    $err = Get-Content $errFile -Raw -ErrorAction SilentlyContinue
    Remove-Item $errFile -ErrorAction SilentlyContinue
    $script:CurrentProc = $null
    return [pscustomobject]@{ ExitCode = $p.ExitCode; Error = $err }
}

function Invoke-FFmpeg([string]$ArgLine) { return (Invoke-Process $script:FFmpeg $ArgLine) }

function Get-Tail([string]$text, [int]$max = 400) {
    if (-not $text) { return 'No details available.' }
    $t = $text.Trim()
    if ($t.Length -gt $max) { $t = $t.Substring($t.Length - $max) }
    return $t
}

function Get-AtempoChain([double]$t) {
    # Older FFmpeg builds only accept 0.5 - 2.0 per atempo, so chain if needed.
    $parts = @()
    while ($t -gt 2.0) { $parts += 'atempo=2.0'; $t = $t / 2.0 }
    while ($t -lt 0.5) { $parts += 'atempo=0.5'; $t = $t / 0.5 }
    $parts += ('atempo=' + $t.ToString('0.######', $script:Inv))
    return ($parts -join ',')
}

function Set-NumValue($num, [decimal]$v) {
    if ($v -lt $num.Minimum) { $v = $num.Minimum }
    if ($v -gt $num.Maximum) { $v = $num.Maximum }
    $num.Value = $v
}

function Set-Status([string]$text, [string]$kind = 'info') {
    if ($script:Closing) { return }
    $script:lblStatus.Text = $text
    switch ($kind) {
        'ok'    { $script:lblStatus.ForeColor = [Drawing.Color]::SeaGreen }
        'error' { $script:lblStatus.ForeColor = [Drawing.Color]::Firebrick }
        default { $script:lblStatus.ForeColor = [Drawing.Color]::DimGray }
    }
}

function Set-Busy([bool]$busy, [string]$text = '') {
    if ($script:Closing) { return }
    foreach ($c in @($script:btnBrowse, $script:btnDetect, $script:btnHalf, $script:btnDouble, $script:btnTap,
                     $script:numOrig, $script:numTarget, $script:btnSave, $script:btnConvert)) {
        $c.Enabled = -not $busy
    }
    $script:chkSplit.Enabled = ((-not $busy) -and [bool]$script:Demucs)
    $script:form.AllowDrop = -not $busy
    if ($busy) {
        $script:progress.Style = 'Marquee'
        $script:progress.MarqueeAnimationSpeed = 30
        $script:form.Cursor = [Windows.Forms.Cursors]::WaitCursor
        if ($text) { Set-Status $text }
    } else {
        $script:progress.Style = 'Continuous'
        $script:progress.MarqueeAnimationSpeed = 0
        $script:progress.Value = 0
        $script:form.Cursor = [Windows.Forms.Cursors]::Default
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Update-Speed {
    $o = [double]$script:numOrig.Value
    $t = [double]$script:numTarget.Value
    $r = $t / $o
    $pct = ($r - 1) * 100
    $sign = if ($pct -ge 0) { '+' } else { '' }
    $script:lblSpeed.Text = ('Speed: x{0:0.000}   ({1}{2:0.0}%)   -   pitch stays the same' -f $r, $sign, $pct)
}

function Update-OutputName {
    if ($script:OutManual -or -not $script:InputFile) { return }
    $dir  = Split-Path $script:InputFile -Parent
    $base = [IO.Path]::GetFileNameWithoutExtension($script:InputFile)
    $ext  = [IO.Path]::GetExtension($script:InputFile)
    $tag  = ([decimal]$script:numTarget.Value).ToString('0.##', $script:Inv)
    $script:txtOut.Text = Join-Path $dir ("{0}_{1}bpm{2}" -f $base, $tag, $ext)
}

function Invoke-DetectBpm {
    if (-not $script:InputFile -or -not (Test-Path -LiteralPath $script:InputFile)) {
        Set-Status 'Choose an audio file first.' 'error'
        return
    }
    $raw = Join-Path ([IO.Path]::GetTempPath()) ("bpmchanger_{0}.raw" -f [guid]::NewGuid())
    Set-Busy $true 'Analyzing tempo... (this takes a few seconds)'
    try {
        $argLine = '-v error -y -i "{0}" -t 120 -vn -ac 1 -ar 11025 -f s16le "{1}"' -f $script:InputFile, $raw
        $res = Invoke-FFmpeg $argLine
        if ($script:Closing) { return }
        if ($res.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $raw)) {
            $script:lblDetect.Text = 'Could not read this audio file.'
            Set-Status 'FFmpeg could not decode the file.' 'error'
            return
        }
        $bpm = [BpmDetector]::Detect($raw, 11025)
        if ($bpm -le 0) {
            $script:lblDetect.Text = 'Could not detect BPM (file too short?). Enter it manually or tap it.'
            Set-Status 'BPM detection failed. You can type the BPM yourself.' 'error'
            return
        }
        Set-NumValue $script:numOrig ([decimal]$bpm)
        Set-NumValue $script:numTarget ([decimal][Math]::Round($bpm + 10))

        $alts = @()
        if ($bpm / 2 -ge 50)  { $alts += ('{0:0.#}' -f ($bpm / 2)) }
        if ($bpm * 2 -le 220) { $alts += ('{0:0.#}' -f ($bpm * 2)) }
        $script:lblDetect.Text = ('Detected: {0:0.0} BPM   (could also be {1} - tap along to check)' -f $bpm, ($alts -join ' or '))
        Set-Status 'Ready. Set your target BPM and press the button below.'
    }
    catch {
        Set-Status ('Detection error: ' + $_.Exception.Message) 'error'
    }
    finally {
        Remove-Item -LiteralPath $raw -ErrorAction SilentlyContinue
        Set-Busy $false
    }
}

function Set-InputFile([string]$path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    $script:InputFile = $path
    $script:OutManual = $false
    $script:txtIn.Text = $path
    $script:lblDetect.Text = ''
    Update-OutputName
    Invoke-DetectBpm
    Update-OutputName
}

# Separates vocals / instrumental with Demucs, then applies the same tempo change to each stem.
function Invoke-Split([string]$OutPath, [string]$Filter, [string]$Extra) {
    $tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('bpmchanger_' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $tmpRoot
    $made = @()
    try {
        $wav = Join-Path $tmpRoot 'track.wav'
        Set-Status 'Splitting: preparing audio...'
        $r = Invoke-FFmpeg ('-v error -y -i "{0}" -vn -ac 2 -ar 44100 "{1}"' -f $script:InputFile, $wav)
        if ($script:Closing) { return $made }
        if ($r.ExitCode -ne 0) { throw ('Could not decode the audio for separation. ' + (Get-Tail $r.Error)) }

        Set-Status 'Splitting vocals / instrumental with Demucs... (can take several minutes on a CPU)'
        $stemDir = Join-Path $tmpRoot 'stems'
        $demArgs = '{0}--two-stems=vocals -o "{1}" "{2}"' -f $script:Demucs.Prefix, $stemDir, $wav
        $r = Invoke-Process $script:Demucs.File $demArgs
        if ($script:Closing) { return $made }

        $voc = Get-ChildItem -Path $stemDir -Recurse -Filter 'vocals.wav'    -ErrorAction SilentlyContinue | Select-Object -First 1
        $ins = Get-ChildItem -Path $stemDir -Recurse -Filter 'no_vocals.wav' -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $voc -or -not $ins) { throw ('Demucs did not produce the stems. ' + (Get-Tail $r.Error)) }

        $dir  = Split-Path $OutPath -Parent
        $base = [IO.Path]::GetFileNameWithoutExtension($OutPath)
        $ext  = [IO.Path]::GetExtension($OutPath)
        $jobs = @(
            @{ Src = $voc.FullName; Dest = (Join-Path $dir ("{0}_vocals{1}" -f $base, $ext));       Name = 'vocals' },
            @{ Src = $ins.FullName; Dest = (Join-Path $dir ("{0}_instrumental{1}" -f $base, $ext)); Name = 'instrumental' }
        )
        foreach ($j in $jobs) {
            Set-Status ("Changing tempo of {0} track..." -f $j.Name)
            $r = Invoke-FFmpeg ('-y -i "{0}" -filter:a "{1}" {2}"{3}"' -f $j.Src, $Filter, $Extra, $j.Dest)
            if ($script:Closing) { return $made }
            if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $j.Dest)) {
                throw ('Could not save the {0} file. {1}' -f $j.Name, (Get-Tail $r.Error))
            }
            $made += $j.Dest
        }
        return $made
    }
    finally {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-Convert {
    if (-not $script:InputFile) { Set-Status 'Choose an audio file first.' 'error'; return }
    $out = $script:txtOut.Text
    if (-not $out) { Set-Status 'Choose where to save the new file.' 'error'; return }
    if ([IO.Path]::GetFullPath($out) -eq [IO.Path]::GetFullPath($script:InputFile)) {
        Set-Status 'Output file must be different from the input file.' 'error'
        return
    }
    $orig   = [double]$script:numOrig.Value
    $target = [double]$script:numTarget.Value
    $tempo  = $target / $orig
    $filter = Get-AtempoChain $tempo

    $extra = ''
    if ([IO.Path]::GetExtension($out).ToLower() -eq '.mp3') { $extra = '-q:a 0 ' }

    $argLine = '-y -i "{0}" -filter:a "{1}" {2}"{3}"' -f $script:InputFile, $filter, $extra, $out

    Set-Busy $true ('Converting {0:0.#} -> {1:0.#} BPM ...' -f $orig, $target)
    try {
        $res = Invoke-FFmpeg $argLine
        if ($script:Closing) { return }
        if ($res.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $out)) {
            Set-Status ('FFmpeg failed: ' + (Get-Tail $res.Error 500)) 'error'
            return
        }
        $saved = @($out)

        if ($script:chkSplit.Checked -and $script:Demucs) {
            try {
                $stems = @(Invoke-Split $out $filter $extra)
                $saved += $stems
            }
            catch {
                Set-Status ('Tempo-changed file saved, but splitting failed: ' + $_.Exception.Message) 'error'
                return
            }
        }
        if ($script:Closing) { return }

        Set-Status ('Done! Saved {0} file(s) in: {1}' -f $saved.Count, (Split-Path $out -Parent)) 'ok'
        $list = ($saved | ForEach-Object { Split-Path $_ -Leaf }) -join "`n"
        $ans = [System.Windows.Forms.MessageBox]::Show(
            "Finished!`n`n$list`n`nOpen the folder?", "$script:AppName v$script:AppVersion", 'YesNo', 'Information')
        if ($ans -eq 'Yes') { Start-Process explorer.exe -ArgumentList "/select,`"$out`"" }
    }
    catch {
        Set-Status ('Error: ' + $_.Exception.Message) 'error'
    }
    finally {
        Set-Busy $false
    }
}

# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------
$fontNormal = New-Object Drawing.Font('Segoe UI', 10)
$fontBold   = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold)
$fontSmall  = New-Object Drawing.Font('Segoe UI', 8.5)

function New-Label($text, $x, $y, $w, $h, $font) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object Drawing.Point($x, $y)
    $l.Size = New-Object Drawing.Size($w, $h); $l.Font = $font
    return $l
}
function New-Button($text, $x, $y, $w, $h) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text; $b.Location = New-Object Drawing.Point($x, $y)
    $b.Size = New-Object Drawing.Size($w, $h); $b.Font = $fontNormal
    return $b
}
function New-Numeric($x, $y, $w, $min, $max, $val) {
    $n = New-Object Windows.Forms.NumericUpDown
    $n.Location = New-Object Drawing.Point($x, $y); $n.Size = New-Object Drawing.Size($w, 28)
    $n.Font = $fontNormal; $n.DecimalPlaces = 1; $n.Increment = [decimal]0.5
    $n.Minimum = $min; $n.Maximum = $max; $n.Value = $val
    return $n
}

$script:form = New-Object Windows.Forms.Form
$form = $script:form
$form.Text = "$script:AppName v$script:AppVersion"
$form.ClientSize = New-Object Drawing.Size(560, 535)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.Font = $fontNormal
$form.AllowDrop = $true

# 1. Input
$form.Controls.Add((New-Label '1.  Choose an audio file (or drag && drop it here)' 20 15 520 24 $fontBold))
$script:txtIn = New-Object Windows.Forms.TextBox
$script:txtIn.Location = New-Object Drawing.Point(20, 42); $script:txtIn.Size = New-Object Drawing.Size(420, 28)
$script:txtIn.ReadOnly = $true; $script:txtIn.Font = $fontNormal
$form.Controls.Add($script:txtIn)
$script:btnBrowse = New-Button 'Browse...' 450 40 90 30
$form.Controls.Add($script:btnBrowse)

# 2. Original BPM
$form.Controls.Add((New-Label '2.  Original BPM' 20 88 520 24 $fontBold))
$script:numOrig = New-Numeric 20 115 100 20 300 100
$form.Controls.Add($script:numOrig)
$script:btnDetect = New-Button 'Detect BPM' 130 113 110 32
$script:btnHalf   = New-Button '/ 2' 250 113 50 32
$script:btnDouble = New-Button 'x 2' 310 113 50 32
$script:btnTap    = New-Button 'Tap tempo' 370 113 110 32
$form.Controls.AddRange(@($script:btnDetect, $script:btnHalf, $script:btnDouble, $script:btnTap))
$script:lblDetect = New-Label 'Detected BPM will appear here.' 20 152 520 22 $fontSmall
$script:lblDetect.ForeColor = [Drawing.Color]::DimGray
$form.Controls.Add($script:lblDetect)

# 3. Target BPM
$form.Controls.Add((New-Label '3.  Target BPM' 20 190 520 24 $fontBold))
$script:numTarget = New-Numeric 20 217 100 20 400 110
$form.Controls.Add($script:numTarget)
$script:lblSpeed = New-Label '' 135 221 410 22 $fontNormal
$form.Controls.Add($script:lblSpeed)

# 4. Output
$form.Controls.Add((New-Label '4.  Save as' 20 262 520 24 $fontBold))
$script:txtOut = New-Object Windows.Forms.TextBox
$script:txtOut.Location = New-Object Drawing.Point(20, 289); $script:txtOut.Size = New-Object Drawing.Size(420, 28)
$script:txtOut.ReadOnly = $true; $script:txtOut.Font = $fontNormal
$form.Controls.Add($script:txtOut)
$script:btnSave = New-Button 'Browse...' 450 287 90 30
$form.Controls.Add($script:btnSave)

# Optional: vocal / instrumental split
$script:chkSplit = New-Object Windows.Forms.CheckBox
$script:chkSplit.Text = 'Also save separate vocal + instrumental files (optional)'
$script:chkSplit.Location = New-Object Drawing.Point(20, 330)
$script:chkSplit.Size = New-Object Drawing.Size(520, 26)
$script:chkSplit.Font = $fontNormal
$script:chkSplit.Enabled = [bool]$script:Demucs
$form.Controls.Add($script:chkSplit)
if ($script:Demucs) {
    $hint = 'Uses Demucs (AI). Expect a few minutes per song on a CPU. Creates *_vocals and *_instrumental files.'
} else {
    $hint = 'Not available: install Python, then run  pip install demucs  and restart this app.'
}
$script:lblSplitHint = New-Label $hint 40 356 500 20 $fontSmall
$script:lblSplitHint.ForeColor = [Drawing.Color]::DimGray
$form.Controls.Add($script:lblSplitHint)

# Convert
$script:btnConvert = New-Button 'Change BPM' 20 388 520 48
$script:btnConvert.Font = New-Object Drawing.Font('Segoe UI', 12, [Drawing.FontStyle]::Bold)
$script:btnConvert.FlatStyle = 'Flat'
$script:btnConvert.BackColor = [Drawing.Color]::SteelBlue
$script:btnConvert.ForeColor = [Drawing.Color]::White
$form.Controls.Add($script:btnConvert)

$script:progress = New-Object Windows.Forms.ProgressBar
$script:progress.Location = New-Object Drawing.Point(20, 446); $script:progress.Size = New-Object Drawing.Size(520, 16)
$form.Controls.Add($script:progress)

$script:lblStatus = New-Label 'Choose an audio file to begin.' 20 468 520 40 $fontSmall
$script:lblStatus.ForeColor = [Drawing.Color]::DimGray
$form.Controls.Add($script:lblStatus)

$lblFooter = New-Label ("v$script:AppVersion  -  powered by FFmpeg atempo (tempo changes, pitch does not)") 20 510 520 18 $fontSmall
$lblFooter.ForeColor = [Drawing.Color]::Gray
$form.Controls.Add($lblFooter)

# ---------------------------------------------------------------------------
# Events
# ---------------------------------------------------------------------------
$script:btnBrowse.Add_Click({
    $dlg = New-Object Windows.Forms.OpenFileDialog
    $dlg.Title  = 'Choose an audio file'
    $dlg.Filter = 'Audio files|*.mp3;*.wav;*.flac;*.m4a;*.aac;*.ogg;*.opus;*.wma|All files|*.*'
    if ($dlg.ShowDialog() -eq 'OK') { Set-InputFile $dlg.FileName }
})

$script:btnSave.Add_Click({
    $dlg = New-Object Windows.Forms.SaveFileDialog
    $dlg.Title = 'Save the new audio file as'
    $dlg.OverwritePrompt = $true
    if ($script:txtOut.Text) {
        $dlg.InitialDirectory = Split-Path $script:txtOut.Text -Parent
        $dlg.FileName = Split-Path $script:txtOut.Text -Leaf
        $ext = [IO.Path]::GetExtension($script:txtOut.Text).TrimStart('.')
        if ($ext) { $dlg.Filter = "Same format (*.$ext)|*.$ext|All files|*.*"; $dlg.DefaultExt = $ext }
    }
    if ($dlg.ShowDialog() -eq 'OK') { $script:txtOut.Text = $dlg.FileName; $script:OutManual = $true }
})

$script:btnDetect.Add_Click({ Invoke-DetectBpm })
$script:btnHalf.Add_Click({ Set-NumValue $script:numOrig ($script:numOrig.Value / 2) })
$script:btnDouble.Add_Click({ Set-NumValue $script:numOrig ($script:numOrig.Value * 2) })

# Tap tempo: tap along to the music; needs 4+ taps. Pauses over 2 seconds restart the count.
$script:btnTap.Add_Click({
    $now = $script:Clock.Elapsed.TotalSeconds
    $n = $script:TapTimes.Count
    if ($n -gt 0 -and ($now - $script:TapTimes[$n - 1]) -gt 2.0) { $script:TapTimes.Clear() }
    $script:TapTimes.Add($now)
    if ($script:TapTimes.Count -gt 12) { $script:TapTimes.RemoveAt(0) }
    $n = $script:TapTimes.Count
    if ($n -ge 4) {
        $span = $script:TapTimes[$n - 1] - $script:TapTimes[0]
        $bpm  = 60.0 * ($n - 1) / $span
        Set-NumValue $script:numOrig ([decimal][Math]::Round($bpm, 1))
        $script:lblDetect.Text = ('Tapped: {0:0.0} BPM   ({1} taps - keep going for more accuracy)' -f $bpm, $n)
    } else {
        $script:lblDetect.Text = ('Keep tapping to the beat... ({0}/4)' -f $n)
    }
})

$script:numOrig.Add_ValueChanged({ Update-Speed })
$script:numTarget.Add_ValueChanged({ Update-Speed; Update-OutputName })
$script:btnConvert.Add_Click({ Invoke-Convert })

$form.Add_DragEnter({
    if ($_.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) { $_.Effect = 'Copy' }
})
$form.Add_DragDrop({
    $files = $_.Data.GetData([Windows.Forms.DataFormats]::FileDrop)
    if ($files -and $files.Count -gt 0) { Set-InputFile $files[0] }
})

# Stop any running FFmpeg / Demucs job when the window is closed
$form.Add_FormClosing({
    $script:Closing = $true
    try { if ($script:CurrentProc -and -not $script:CurrentProc.HasExited) { Stop-ProcessTree $script:CurrentProc } } catch { }
})

Update-Speed
[void]$form.ShowDialog()
