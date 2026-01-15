<#
.SYNOPSIS
  Inspect the current Windows clipboard and print detected formats with:
  - data type / format name
  - length (chars / bytes / count / dimensions where applicable)
  - content (text or hex preview)
  Supports common formats: Text, UnicodeText, OEMText, HTML, RTF, CSV, Markdown (if present),
  FileDrop (files), Bitmap/Image.
  Binary payloads are previewed as first 128 bytes in hex.

.NOTES
  Requires STA for System.Windows.Forms. This script self-reinvokes in STA if needed.
#>

# --- Ensure STA (clipboard APIs require STA) ---
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
  $ps = (Get-Process -Id $PID).Path
  $args = @('-NoProfile','-ExecutionPolicy','Bypass','-Sta','-File', $PSCommandPath)
  & $ps @args
  exit $LASTEXITCODE
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Format-HexPreview {
  param(
    [Parameter(Mandatory=$true)][byte[]] $Bytes,
    [int] $MaxBytes = 128
  )
  $take = [Math]::Min($Bytes.Length, $MaxBytes)
  $head = $Bytes[0..($take-1)]
  ($head | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
}

function Get-BytesFromObject {
  param([Parameter(Mandatory=$true)] $Obj)

  # Prefer raw byte[] if already available
  if ($Obj -is [byte[]]) { return ,$Obj }

  # MemoryStream -> bytes
  if ($Obj -is [System.IO.MemoryStream]) { return ,$Obj.ToArray() }

  # String -> UTF8 bytes (for hex preview of text if needed)
  if ($Obj -is [string]) {
    return ,[System.Text.Encoding]::UTF8.GetBytes($Obj)
  }

  # Any other object -> attempt binary serialization via ToString() fallback
  try {
    $s = $Obj.ToString()
    return ,[System.Text.Encoding]::UTF8.GetBytes($s)
  } catch {
    return ,@()
  }
}

function Write-Section {
  param(
    [Parameter(Mandatory=$true)][string] $Title,
    [hashtable] $Fields
  )

  Write-Host ''
  Write-Host "=== $Title ==="
  foreach ($k in $Fields.Keys) {
    $v = $Fields[$k]
    if ($null -eq $v) { $v = '<null>' }
    Write-Host ('{0,-14}: {1}' -f $k, $v)
  }
}

# Common formats to probe explicitly (in addition to enumerating everything)
$KnownFormats = @(
  [System.Windows.Forms.DataFormats]::UnicodeText,
  [System.Windows.Forms.DataFormats]::Text,
  [System.Windows.Forms.DataFormats]::OemText,
  [System.Windows.Forms.DataFormats]::Html,
  [System.Windows.Forms.DataFormats]::Rtf,
  [System.Windows.Forms.DataFormats]::CommaSeparatedValue,
  [System.Windows.Forms.DataFormats]::FileDrop,
  [System.Windows.Forms.DataFormats]::Bitmap
)

# Some apps may register "Markdown" as a custom format name (not in DataFormats)
$CustomFormatNames = @('Markdown', 'text/markdown')

$cb = [System.Windows.Forms.Clipboard]::GetDataObject()
if (-not $cb) {
  Write-Host "Clipboard is empty or unavailable."
  exit 0
}

# Print all available format names
$formats = $cb.GetFormats() | Sort-Object
Write-Section -Title "Available clipboard formats" -Fields @{
  "Count"   = $formats.Count
  "Formats" = ($formats -join ', ')
}

# Helper: safe GetData
function Try-GetData {
  param(
    [Parameter(Mandatory=$true)][string] $FormatName
  )
  try {
    if ($cb.GetDataPresent($FormatName)) {
      return $cb.GetData($FormatName)
    }
  } catch { }
  return $null
}

# --- Text-like formats ---
function Dump-TextFormat {
  param(
    [Parameter(Mandatory=$true)][string] $FormatName
  )
  if (-not $cb.GetDataPresent($FormatName)) { return }

  $data = Try-GetData $FormatName
  if ($null -eq $data) { return }

  $s = [string]$data
  $charLen = $s.Length
  $byteLenUtf8 = ([System.Text.Encoding]::UTF8.GetByteCount($s))
  $typeName = $data.GetType().FullName

  Write-Section -Title "Text: $FormatName" -Fields @{
    "Format"     = $FormatName
    "DotNetType" = $typeName
    "Chars"      = $charLen
    "UTF8Bytes"  = $byteLenUtf8
    "Content"    = $s
  }
}

# --- HTML / RTF / CSV / Markdown (still text, but show separately) ---
function Dump-RichTextFormat {
  param(
    [Parameter(Mandatory=$true)][string] $FormatName
  )
  if (-not $cb.GetDataPresent($FormatName)) { return }

  $data = Try-GetData $FormatName
  if ($null -eq $data) { return }

  $s = [string]$data
  $charLen = $s.Length
  $byteLenUtf8 = ([System.Text.Encoding]::UTF8.GetByteCount($s))
  $typeName = $data.GetType().FullName

  Write-Section -Title "Rich text: $FormatName" -Fields @{
    "Format"     = $FormatName
    "DotNetType" = $typeName
    "Chars"      = $charLen
    "UTF8Bytes"  = $byteLenUtf8
    "Content"    = $s
  }
}

# --- Files ---
function Dump-FileDrop {
  $fmt = [System.Windows.Forms.DataFormats]::FileDrop
  if (-not $cb.GetDataPresent($fmt)) { return }

  $data = Try-GetData $fmt
  if ($null -eq $data) { return }

  # Usually string[]
  $typeName = $data.GetType().FullName
  $files = @()
  try { $files = @($data) } catch { }

  Write-Section -Title "Files (FileDrop)" -Fields @{
    "Format"     = $fmt
    "DotNetType" = $typeName
    "Count"      = $files.Count
    "Content"    = ($files -join [Environment]::NewLine)
  }
}

# --- Images ---
function Dump-Bitmap {
  $fmt = [System.Windows.Forms.DataFormats]::Bitmap
  if (-not $cb.GetDataPresent($fmt)) { return }

  $img = $null
  try { $img = [System.Windows.Forms.Clipboard]::GetImage() } catch { }
  if ($null -eq $img) {
    # Fallback: try raw data object
    $img = Try-GetData $fmt
  }
  if ($null -eq $img) { return }

  $typeName = $img.GetType().FullName

  # Convert to PNG bytes for deterministic byte sizing + hex preview
  $ms = New-Object System.IO.MemoryStream
  try {
    $img.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $pngBytes = $ms.ToArray()
  } catch {
    $pngBytes = @()
  } finally {
    $ms.Dispose()
  }

  $w = $null; $h = $null
  try { $w = $img.Width; $h = $img.Height } catch { }

  $hex = if ($pngBytes.Count -gt 0) { Format-HexPreview -Bytes $pngBytes -MaxBytes 128 } else { "<unable to encode image>" }

  Write-Section -Title "Image (Bitmap)" -Fields @{
    "Format"        = $fmt
    "DotNetType"    = $typeName
    "Dimensions"    = if ($w -and $h) { "${w}x${h}" } else { "<unknown>" }
    "PNGBytes"      = $pngBytes.Length
    "Hex(First128)" = $hex
  }
}

# --- Generic binary/custom formats (first 128 bytes in hex) ---
function Dump-BinaryFormat {
  param(
    [Parameter(Mandatory=$true)][string] $FormatName
  )
  if (-not $cb.GetDataPresent($FormatName)) { return }

  # Skip ones we already handled in more readable ways
  $skip = @(
    [System.Windows.Forms.DataFormats]::UnicodeText,
    [System.Windows.Forms.DataFormats]::Text,
    [System.Windows.Forms.DataFormats]::OemText,
    [System.Windows.Forms.DataFormats]::Html,
    [System.Windows.Forms.DataFormats]::Rtf,
    [System.Windows.Forms.DataFormats]::CommaSeparatedValue,
    [System.Windows.Forms.DataFormats]::FileDrop,
    [System.Windows.Forms.DataFormats]::Bitmap
  )
  if ($skip -contains $FormatName) { return }

  $data = Try-GetData $FormatName
  if ($null -eq $data) { return }

  $typeName = $data.GetType().FullName

  # Attempt to get bytes: common cases include MemoryStream, byte[]
  $bytes = Get-BytesFromObject $data
  $byteLen = $bytes.Length
  $hex = if ($byteLen -gt 0) { Format-HexPreview -Bytes $bytes -MaxBytes 128 } else { "<no bytes (or unsupported object)>" }

  Write-Section -Title "Binary/Other: $FormatName" -Fields @{
    "Format"        = $FormatName
    "DotNetType"    = $typeName
    "Bytes"         = $byteLen
    "Hex(First128)" = $hex
    "Note"          = "If this is a complex COM object, bytes may be a UTF-8 ToString() fallback."
  }
}

# ---- Dump common text first (most useful) ----
Dump-TextFormat -FormatName ([System.Windows.Forms.DataFormats]::UnicodeText)
Dump-TextFormat -FormatName ([System.Windows.Forms.DataFormats]::Text)
Dump-TextFormat -FormatName ([System.Windows.Forms.DataFormats]::OemText)

# Rich text formats
Dump-RichTextFormat -FormatName ([System.Windows.Forms.DataFormats]::Html)
Dump-RichTextFormat -FormatName ([System.Windows.Forms.DataFormats]::Rtf)
Dump-RichTextFormat -FormatName ([System.Windows.Forms.DataFormats]::CommaSeparatedValue)

# Markdown (custom, if present)
foreach ($mdFmt in $CustomFormatNames) {
  if ($cb.GetDataPresent($mdFmt)) {
    Dump-RichTextFormat -FormatName $mdFmt
  }
}

# Files and image
Dump-FileDrop
Dump-Bitmap

# ---- Finally enumerate any remaining formats and dump a binary preview ----
foreach ($f in $formats) {
  Dump-BinaryFormat -FormatName $f
}

Write-Host ""
Write-Host "Done."
