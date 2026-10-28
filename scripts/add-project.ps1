# Jedit.Jed - Add Project. Double-click "Add Project.bat" to run.
# Drop video(s) into the "_ADD PROJECT HERE" folder first.
param([switch]$DryRun)
$ErrorActionPreference = 'Continue'   # native tools (git) write progress to stderr; we check exit codes instead
$Repo   = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Drop   = Join-Path $Repo '_ADD PROJECT HERE'
$Done   = Join-Path $Drop 'done'
$Arch   = Join-Path $Repo 'media\archive'
$Json   = Join-Path $Repo 'projects.json'
$Live   = 'https://jkudaisi.github.io/jedit-jed/'
$MaxMB  = 90   # GitHub rejects files over 100 MB, keep a safety margin
$Utf8   = New-Object System.Text.UTF8Encoding($false)

function Say($t, $c = 'Gray') { Write-Host $t -ForegroundColor $c }
function Fail($t) { Say ''; Say "  X  $t" 'Red'; Say '     Nothing was lost. Your files are still where they were.' 'Yellow'; Pause-End; exit 1 }
function Pause-End { Say ''; Read-Host '  Press Enter to close' | Out-Null }
function Ask($q, $def) {
  $p = if ($def -ne $null -and $def -ne '') { "  $q [$def]" } else { "  $q" }
  $a = Read-Host $p
  if ([string]::IsNullOrWhiteSpace($a)) { return $def } else { return $a.Trim() }
}
function JStr($s) {
  if ($s -eq $null) { $s = '' }
  $sb = New-Object System.Text.StringBuilder
  foreach ($ch in $s.ToCharArray()) {
    switch ($ch) {
      '"'  { [void]$sb.Append('\"') } '\' { [void]$sb.Append('\\') }
      "`n" { [void]$sb.Append('\n') } "`r" { } "`t" { [void]$sb.Append(' ') }
      default { [void]$sb.Append($ch) }
    }
  }
  return '"' + $sb.ToString() + '"'
}
function Slug($s) { $x = ($s.ToLower() -replace '[^a-z0-9]', ''); if ($x.Length -gt 20) { $x = $x.Substring(0, 20) }; if (!$x) { $x = 'project' }; return $x }
function Run-FF($argList) {
  $p = Start-Process -FilePath $script:FF -ArgumentList $argList -NoNewWindow -Wait -PassThru -RedirectStandardError (Join-Path $env:TEMP 'jedit-ffmpeg.log')
  if ($p.ExitCode -ne 0) { Fail "ffmpeg failed. Details: $env:TEMP\jedit-ffmpeg.log" }
}
function Q($s) { return '"' + $s + '"' }

Clear-Host
Say ''
Say '  ==========================================' 'Red'
Say '   JEDIT.JED  -  ADD A PROJECT TO THE SITE' 'White'
Say '  ==========================================' 'Red'
if ($DryRun) { Say '   (TEST RUN: nothing will be committed or pushed)' 'Yellow' }
Say ''

if (!(Test-Path $Drop)) { New-Item -ItemType Directory $Drop | Out-Null }
if (!(Test-Path $Done)) { New-Item -ItemType Directory $Done | Out-Null }
Set-Location $Repo

# ---- ffmpeg ----
$script:FF = $null; $script:FP = $null
$cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
if ($cmd) { $script:FF = $cmd.Source }
if (!$script:FF) {
  $local = Get-ChildItem (Join-Path $Repo 'tools') -Recurse -Filter ffmpeg.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($local) { $script:FF = $local.FullName }
}
if (!$script:FF) {
  Say '  ffmpeg (the video converter) is not installed. Installing it now, one time only...' 'Yellow'
  try {
    winget install -e --id Gyan.FFmpeg --accept-source-agreements --accept-package-agreements | Out-Host
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue; if ($cmd) { $script:FF = $cmd.Source }
  } catch { }
  if (!$script:FF) {
    Say '  winget did not work, downloading a portable copy into tools\ ...' 'Yellow'
    $zip = Join-Path $env:TEMP 'ffmpeg.zip'; $tools = Join-Path $Repo 'tools'
    try {
      Invoke-WebRequest 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip' -OutFile $zip -UseBasicParsing
      Expand-Archive $zip -DestinationPath $tools -Force
      $local = Get-ChildItem $tools -Recurse -Filter ffmpeg.exe | Select-Object -First 1; if ($local) { $script:FF = $local.FullName }
    } catch { }
  }
  if (!$script:FF) { Fail 'Could not install ffmpeg. Check your internet connection and try again.' }
}
$script:FP = Join-Path (Split-Path $script:FF) 'ffprobe.exe'
if (!(Test-Path $script:FP)) { $c = Get-Command ffprobe -ErrorAction SilentlyContinue; if ($c) { $script:FP = $c.Source } }

function Probe($f) {
  $o = & $script:FP -v error -select_streams v:0 -show_entries stream=width,height:stream_tags=rotate:format=duration -of default=nw=1 $f 2>$null
  $r = @{ w = 0; h = 0; d = 0; rot = 0 }
  foreach ($l in $o) {
    if ($l -match '^width=(\d+)') { $r.w = [int]$matches[1] }
    elseif ($l -match '^height=(\d+)') { $r.h = [int]$matches[1] }
    elseif ($l -match '^duration=([\d\.]+)') { $r.d = [double]::Parse($matches[1], [Globalization.CultureInfo]::InvariantCulture) }
    elseif ($l -match 'rotate=(-?\d+)') { $r.rot = [int]$matches[1] }
  }
  if ([math]::Abs($r.rot) -eq 90 -or [math]::Abs($r.rot) -eq 270) { $t = $r.w; $r.w = $r.h; $r.h = $t }
  return $r
}

# ---- git sanity ----
git rev-parse --is-inside-work-tree 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Fail 'This folder is not the site repo (git not found here).' }
if (!(Test-Path $Json)) { Fail 'projects.json is missing from the site folder.' }

# ---- find videos ----
$exts = '.mp4', '.mov', '.m4v', '.mkv', '.avi', '.webm'
$vids = @(Get-ChildItem $Drop -File | Where-Object { $exts -contains $_.Extension.ToLower() } | Sort-Object Name)

$commitMsg = $null; $newClips = @()
if ($vids.Count -eq 0) {
  Say '  No videos in "_ADD PROJECT HERE".' 'Yellow'
  $chg = git status --porcelain -- projects.json media
  if (!$chg) { Say '  And no edits to projects.json either. Nothing to do.'; Pause-End; exit 0 }
  Say '  You have edits to projects.json (or media). Checking the file...' 'Gray'
  try { $null = (Get-Content $Json -Raw -Encoding UTF8) | ConvertFrom-Json } catch { Fail "projects.json has a typo (broken JSON): $($_.Exception.Message). Fix it in Notepad and run again." }
  if ((Ask 'Publish these edits to the live site? (y/n)' 'y') -notmatch '^[yY]') { Say '  OK, nothing published.'; Pause-End; exit 0 }
  $commitMsg = 'Edit projects'
} else {
  Say "  Found $($vids.Count) video(s):" 'Cyan'
  $vids | ForEach-Object { Say ("     - {0}  ({1:N0} MB)" -f $_.Name, ($_.Length / 1MB)) }
  Say ''
  $groups = @()
  if ($vids.Count -gt 1) {
    Say '  Are these:' 'White'
    Say '     1 = clips of ONE project (one card, swipe between clips)'
    Say '     2 = SEPARATE projects (one card each)'
    $m = Ask 'Type 1 or 2' '1'
    if ($m -eq '2') { foreach ($v in $vids) { $groups += , @($v) } } else { $groups += , $vids }
  } else { $groups += , $vids }

  # next free number
  $nums = Get-ChildItem $Arch -File | ForEach-Object { if ($_.Name -match '^(\d+)-') { [int]$matches[1] } }
  $next = ([int]($nums | Measure-Object -Maximum).Maximum) + 1

  $cards = @()
  foreach ($g in $groups) {
    Say ''
    if ($groups.Count -gt 1) { Say "  ---- Project: $($g[0].Name) ----" 'Cyan' }
    $title = ''
    while (!$title) { $title = Ask 'Title / client (big name on the card, e.g. Rowan University)' '' }
    $sub   = Ask 'Subtitle (e.g. Event recap, Promo)' 'Recap'
    $year  = Ask 'Year' ((Get-Date).Year)
    $ig    = Ask 'Instagram handle or link' '@jedit.jed'
    $tsec  = Ask 'Thumbnail: which second of the video?' '3'
    if ($ig -match 'instagram\.com/([^/?#]+)') { $handle = '@' + $matches[1] } elseif ($ig.StartsWith('@')) { $handle = $ig } else { $handle = '@' + $ig }
    $link = if ($ig -match '^https?://') { $ig } else { '' }
    $base = '{0:D2}-{1}' -f $next, (Slug $title); $next++
    $clips = @(); $i = 0
    foreach ($v in $g) {
      $i++
      $name = if ($g.Count -gt 1) { "$base-$i" } else { $base }
      $info = Probe $v.FullName
      if ($info.w -eq 0) { Fail "Could not read the video $($v.Name). Is it a real video file?" }
      $shape = if ($info.h -gt $info.w) { 'vertical' } else { 'landscape' }
      Say ("  Converting {0}  ({1}x{2}, {3}, {4:N0}s) ..." -f $v.Name, $info.w, $info.h, $shape, $info.d) 'Cyan'
      # bitrate: 2.2 Mbps, lowered for long videos so the file stays under $MaxMB
      $kb = 2200
      if ($info.d -gt 0) { $cap = [int](($MaxMB * 8192) / $info.d) - 160; if ($cap -lt $kb) { $kb = [math]::Max(400, $cap); Say "     Long video: using $kb kbps to stay under GitHub's 100 MB limit." 'Yellow' } }
      $full = Join-Path $Arch "$name.mp4"; $prev = Join-Path $Arch "$name-prev.mp4"; $jpg = Join-Path $Arch "$name.jpg"
      $sc = "scale='if(gt(iw,ih),min(1080,iw),-2)':'if(gt(iw,ih),-2,min(1080,ih))'"
      Say '     1/3 full video...'
      Run-FF @('-y', '-hide_banner', '-i', (Q $v.FullName), '-vf', (Q $sc), '-c:v', 'libx264', '-preset', 'medium', '-profile:v', 'high', '-pix_fmt', 'yuv420p', '-b:v', "${kb}k", '-maxrate', "$([int]($kb*1.15))k", '-bufsize', "$($kb*2)k", '-c:a', 'aac', '-b:a', '128k', '-ac', '2', '-movflags', '+faststart', (Q $full))
      if ((Get-Item $full).Length -gt 99MB) { Remove-Item $full; Fail "$($v.Name) is still over 100 MB after compressing. Trim it shorter and try again." }
      Say '     2/3 hover preview...'
      $sp = "scale='if(gt(iw,ih),min(640,iw),-2)':'if(gt(iw,ih),-2,min(640,ih))',fps=30"
      Run-FF @('-y', '-hide_banner', '-t', '9', '-i', (Q $v.FullName), '-vf', (Q $sp), '-an', '-c:v', 'libx264', '-preset', 'medium', '-pix_fmt', 'yuv420p', '-b:v', '300k', '-maxrate', '360k', '-bufsize', '600k', '-g', '30', '-keyint_min', '30', '-sc_threshold', '0', '-movflags', '+faststart', (Q $prev))
      Say '     3/3 thumbnail...'
      $ts = 3.0; [void][double]::TryParse(($tsec -replace ',', '.'), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$ts)
      if ($info.d -gt 0 -and $ts -ge $info.d) { $ts = [math]::Max(0, $info.d / 2) }
      Run-FF @('-y', '-hide_banner', '-ss', $ts.ToString([Globalization.CultureInfo]::InvariantCulture), '-i', (Q $v.FullName), '-frames:v', '1', '-vf', (Q $sc), '-q:v', '3', (Q $jpg))
      Say ("     OK  {0}.mp4  {1:N1} MB" -f $name, ((Get-Item $full).Length / 1MB)) 'Green'
      $clips += $name; $script:newClips += $name
    }
    $cl = ($clips | ForEach-Object { JStr $_ }) -join ', '
    $obj = '{"account": ' + (JStr $handle) + ', "year": ' + $(if ($year -match '^\d{4}$') { $year } else { JStr $year }) + ', "title": "", "client": ' + (JStr $title) + ', "type": ' + (JStr $sub)
    if ($link) { $obj += ', "ig": ' + (JStr $link) }
    $obj += ', "clips": [' + $cl + ']}'
    $cards += $obj
  }

  # insert at top of archive list (first card = newest = A-01)
  $text = [IO.File]::ReadAllText($Json, $Utf8)
  $m = [regex]::Match($text, '"archive"\s*:\s*\[')
  if (!$m.Success) { Fail 'Could not find the "archive" list in projects.json.' }
  $ins = "`n    " + (($cards | Select-Object -Last ([int]::MaxValue)) -join ",`n    ") + ','
  # cards were entered oldest-first in the order dropped; the first dropped ends on top
  $text = $text.Insert($m.Index + $m.Length, $ins)
  try { $null = $text | ConvertFrom-Json } catch { Fail 'Internal error: the new projects.json would be broken. Nothing changed.' }
  [IO.File]::WriteAllText($Json, $text, $Utf8)
  Say ''; Say '  projects.json updated (new card is A-01, at the top).' 'Green'
  foreach ($v in $vids) { Move-Item $v.FullName (Join-Path $Done $v.Name) -Force }
  Say '  Originals moved to "_ADD PROJECT HERE\done".' 'Gray'
  $commitMsg = 'Add project: ' + (($groups | ForEach-Object { $_[0].BaseName }) -join ', ')
}

if ($DryRun) {
  Say ''; Say '  TEST RUN finished. Not committed, not pushed.' 'Yellow'
  Say ("  New clips: " + ($script:newClips -join ', '))
  Pause-End; exit 0
}

# ---- publish ----
Say ''; Say '  Uploading to GitHub...' 'Cyan'
git add -- projects.json media 2>&1 | Out-Null
git commit -m $commitMsg 2>&1 | Out-Host
if ($LASTEXITCODE -ne 0) { Fail 'git commit failed.' }
git push origin main 2>&1 | Out-Host
if ($LASTEXITCODE -ne 0) { Fail 'Upload (git push) failed. Check your internet, then just run Add Project.bat again (with no video) to retry the upload.' }
Say '  Uploaded. Waiting for the live site to update (usually 1-2 minutes)...' 'Cyan'
$want = if ($script:newClips.Count) { $script:newClips[0] } else { $null }
$local = [IO.File]::ReadAllText($Json, $Utf8) -replace '\s', ''
$ok = $false
for ($k = 0; $k -lt 40; $k++) {
  Start-Sleep 10
  try {
    $r = (Invoke-WebRequest -ErrorAction Stop ($Live + 'projects.json?t=' + [guid]::NewGuid()) -UseBasicParsing -Headers @{ 'Cache-Control' = 'no-cache' }).Content
    if ($r -is [byte[]]) { $r = $Utf8.GetString($r) }
    if (($want -and $r.Contains($want)) -or (!$want -and ($r -replace '\s', '') -eq $local)) { $ok = $true; break }
  } catch { }
  Write-Host '.' -NoNewline
}
Say ''
if ($ok) { Say "  LIVE!  $Live" 'Green'; Say '  (Refresh the page; on your phone you may need to close and reopen the tab.)' }
else { Say '  Uploaded, but the live site has not refreshed yet. Check in a few minutes:' 'Yellow'; Say "  $Live" }
Pause-End
