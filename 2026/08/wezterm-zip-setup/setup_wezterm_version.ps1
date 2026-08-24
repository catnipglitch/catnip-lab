<#
.SYNOPSIS
    WezTerm の ZIP（ポータブル）版をバージョン別に配置し、current junction で切り替える。
.DESCRIPTION
    %LOCALAPPDATA%\wezterm-zip 配下にバージョン付きフォルダを並べ、
    current という junction で「いま使う版」を指す方式で WezTerm を管理する。
    更新は「展開 + junction 張り替え」、ロールバックは「junction を戻すだけ」で済む。

    WezTerm の nightly は GitHub のローリングタグでアセットが上書きされるため、
    古い版は後から取得できない。バージョン別に残しておくことが唯一の退避手段になる。

    管理者権限は不要（ディレクトリ junction は昇格なしで作成できる）。
.PARAMETER ZipPath
    ダウンロードせず、手元の zip を使う。
.PARAMETER Version
    展開済みのバージョンフォルダ名を指定して current を切り替える（ダウンロードなし）。
.PARAMETER Root
    バージョンを配置するルート。既定は %LOCALAPPDATA%\wezterm-zip。
    通常は変更不要で、隔離した場所で動作確認したいときに使う。
.PARAMETER Rollback
    直前に使っていたバージョンへ current を戻す。
.PARAMETER List
    導入済みバージョンと現在の current を表示して終了する。
.PARAMETER AddToPath
    ユーザーレベル PATH に current を追加する。既定では PATH を変更しない。
.PARAMETER FixShortcuts
    スタートメニューとタスクバーピンの WezTerm ショートカットを current 向きに作成・修正する。
    実行中ウィンドウからのピン留めは junction 解決後の実パス（バージョンフォルダ直指し）で
    .lnk が作られるため、バージョン切り替え後も古い版を起動し続ける。これを張り直す。
    既定では変更せず、直指しのリンクを検出したら警告だけ出す。
.PARAMETER AllowRunning
    この管理下から WezTerm が実行中でも中断せずに続行する。
    ただし実行中のプロセスは古い版のまま動き続けるため、通常は WezTerm を終了してから実行すること。
.PARAMETER Force
    既に展開済みのバージョンを再展開する（旧フォルダは .bak.yyyyMMdd-HHmmss へ退避）。
    実行中プロセスの扱いには影響しない（そちらは -AllowRunning）。
.EXAMPLE
    # 最新 nightly を取得して切り替える
    .\scripts\setup_wezterm_version.ps1
.EXAMPLE
    # 導入済みバージョンを確認する
    .\scripts\setup_wezterm_version.ps1 -List
.EXAMPLE
    # 直前のバージョンへ戻す
    .\scripts\setup_wezterm_version.ps1 -Rollback
.EXAMPLE
    # ショートカットを current 向きに修正する（単独実行可）
    .\scripts\setup_wezterm_version.ps1 -FixShortcuts
#>

param(
    [string]$ZipPath,
    [string]$Version,
    [string]$Root = (Join-Path $env:LOCALAPPDATA 'wezterm-zip'),
    [switch]$Rollback,
    [switch]$List,
    [switch]$AddToPath,
    [switch]$FixShortcuts,
    [switch]$AllowRunning,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$CurrentLink = Join-Path $Root 'current'
$StateFile = Join-Path $Root '.previous'
$ZipUrl = 'https://github.com/wezterm/wezterm/releases/download/nightly/WezTerm-windows-nightly.zip'

# --- 導入済みバージョンの一覧を返す ---
# current junction と、-Force の再展開時に退避した *.bak.* は選択肢に出さない。
function Get-InstalledVersion {
    if (-not (Test-Path $Root)) { return @() }
    Get-ChildItem $Root -Directory -Force |
        Where-Object { -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) } |
        Where-Object { $_.Name -notlike '*.bak.*' } |
        Select-Object -ExpandProperty Name |
        Sort-Object
}

# --- current junction が指しているバージョンフォルダ名を返す ---
function Get-CurrentVersion {
    if (-not (Test-Path $CurrentLink)) { return $null }
    $item = Get-Item $CurrentLink -Force
    if (-not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { return $null }
    Split-Path -Leaf $item.Target
}

# --- current junction を張り替える ---
# Remove-Item に -Recurse を付けないこと。環境によってはリンク先の中身まで消える。
function Set-CurrentVersion {
    param([string]$VersionName)

    $target = Join-Path $Root $VersionName
    if (-not (Test-Path $target)) {
        Write-Error "バージョンが見つかりません: $target"
    }

    $previous = Get-CurrentVersion

    if (Test-Path $CurrentLink) {
        $item = Get-Item $CurrentLink -Force
        if (-not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            Write-Error "current が junction ではなく実ディレクトリです。中身を失う恐れがあるため中断します: $CurrentLink"
        }
        Remove-Item $CurrentLink -Force
    }

    New-Item -ItemType Junction -Path $CurrentLink -Target $target | Out-Null
    Write-Host "  current → $VersionName" -ForegroundColor Green

    if ($previous -and $previous -ne $VersionName) {
        Set-Content -Path $StateFile -Value $previous -Encoding UTF8
    }
}

# --- 展開物からバージョン文字列を得る ---
# zip の内部構造や更新日に依存しないよう、バイナリ自身に名乗らせる。
function Get-WezTermVersion {
    param([string]$ExePath)

    $output = & $ExePath --version 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "wezterm.exe --version の実行に失敗しました: $output"
    }
    # 出力例: "wezterm 20260812-070121-fe3006ae"
    $token = ($output -split '\s+') | Select-Object -Last 1
    if ([string]::IsNullOrWhiteSpace($token)) {
        Write-Error "バージョン文字列を判別できませんでした: $output"
    }
    $token.Trim()
}

# --- ユーザーレベル PATH に current を通す（-AddToPath 指定時のみ） ---
# 未指定のときは何も変更せず、通っていなければ案内だけ出す。
function Invoke-PathSetup {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $onPath = $userPath -and ($userPath -split ';' | Where-Object { $_.TrimEnd('\') -eq $CurrentLink.TrimEnd('\') })

    if ($AddToPath) {
        if ($onPath) {
            Write-Host "  PATH には既に登録済みです: $CurrentLink" -ForegroundColor Yellow
        }
        else {
            # ユーザーレベル PATH が空のとき素直に連結すると先頭が ';' になるため分岐する
            $newPath = if ([string]::IsNullOrEmpty($userPath)) { $CurrentLink } else { "$userPath;$CurrentLink" }
            [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
            Write-Host "  PATH に追加しました (ユーザーレベル): $CurrentLink" -ForegroundColor Green
            Write-Host '  反映には新しいシェルを開いてください。' -ForegroundColor Cyan
        }
    }
    elseif (-not $onPath) {
        Write-Host ''
        Write-Warning "PATH に $CurrentLink がありません。通す場合は -AddToPath を付けて再実行してください。"
    }
}

# --- スタートメニューとタスクバーピンのショートカットを current 向きに揃える ---
# 実行中ウィンドウからのピン留めは junction 解決後の実パスで .lnk が作られるため、
# バージョン切り替え後も古い版を起動し続ける（Issue #12 で発生）。
# -FixShortcuts 指定時は修正し、未指定時は直指しを検出して警告だけ出す（Invoke-PathSetup と同じ流儀）。
# ピン留めの「追加」は Windows がプログラムからの操作を許していないため扱わない（既存の書き換えのみ）。
function Invoke-ShortcutFix {
    $gui = Join-Path $CurrentLink 'wezterm-gui.exe'
    $startMenuLnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\WezTerm.lnk'
    $taskbarDir = Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'

    if (-not (Test-Path $gui)) {
        if ($FixShortcuts) {
            Write-Error "current 配下に wezterm-gui.exe がありません。先にバージョンを導入してください: $gui"
        }
        return
    }

    $shell = New-Object -ComObject WScript.Shell

    # タスクバーピンのうち WezTerm を指すものを集める。
    # アンインストールで向き先が消えた壊れリンクも拾えるよう、ファイル名でも判定する。
    $pins = @()
    if (Test-Path $taskbarDir) {
        $pins = @(Get-ChildItem $taskbarDir -Filter '*.lnk' -File | Where-Object {
            $link = $shell.CreateShortcut($_.FullName)
            # 壊れリンクは TargetPath が空になりうる（Split-Path は空文字列で例外を投げる）
            $targetLeaf = if ($link.TargetPath) { Split-Path -Leaf $link.TargetPath } else { '' }
            ($targetLeaf -like 'wezterm*.exe') -or ($_.BaseName -match 'wezterm')
        })
    }

    if (-not $FixShortcuts) {
        $misdirected = @($pins | Where-Object {
            $shell.CreateShortcut($_.FullName).TargetPath -ne $gui
        })
        if ($misdirected.Count -gt 0) {
            Write-Host ''
            Write-Warning "current 向きでない WezTerm のピン留めがあります（$($misdirected.Count) 件）。バージョン切り替え後も古い版を起動し続けます。修正するには -FixShortcuts を付けて再実行してください。"
        }
        return
    }

    # スタートメニュー: 無ければ作成、あれば向き先を更新
    $existed = Test-Path $startMenuLnk
    $sm = $shell.CreateShortcut($startMenuLnk)
    $sm.TargetPath = $gui
    $sm.WorkingDirectory = $env:USERPROFILE
    $sm.IconLocation = "$gui,0"
    $sm.Save()
    $action = if ($existed) { '更新' } else { '作成' }
    Write-Host "  スタートメニューを${action}: $startMenuLnk" -ForegroundColor Green

    # タスクバーピン: current 向きでなければ書き換える（Arguments 等は触らない）
    foreach ($pin in $pins) {
        $link = $shell.CreateShortcut($pin.FullName)
        if ($link.TargetPath -eq $gui) {
            Write-Host "  ピン留めは current 向きです: $($pin.Name)" -ForegroundColor Yellow
            continue
        }
        $link.TargetPath = $gui
        $link.WorkingDirectory = $env:USERPROFILE
        $link.IconLocation = "$gui,0"
        $link.Save()
        Write-Host "  ピン留めを current 向きに修正: $($pin.Name)" -ForegroundColor Green
    }
    if ($pins.Count -eq 0) {
        Write-Host '  タスクバーに WezTerm のピン留めはありません（追加はスタートメニューから手動で行ってください）。' -ForegroundColor Cyan
    }
}

Write-Host ''
Write-Host '=== setup wezterm version ===' -ForegroundColor Magenta
Write-Host "  Root: $Root"
Write-Host ''

if (-not (Test-Path $Root)) {
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    Write-Host "  ディレクトリを作成: $Root" -ForegroundColor Cyan
}

# --- -List: 一覧表示して終了 ---
if ($List) {
    $current = Get-CurrentVersion
    # Set-StrictMode 下では単一要素が配列にならず .Count が落ちるため @() で包む
    $versions = @(Get-InstalledVersion)
    if ($versions.Count -eq 0) {
        Write-Host '  導入済みバージョンはありません。' -ForegroundColor Yellow
    }
    else {
        foreach ($v in $versions) {
            if ($v -eq $current) {
                Write-Host "  * $v  (current)" -ForegroundColor Green
            }
            else {
                Write-Host "    $v"
            }
        }
    }
    if (Test-Path $StateFile) {
        Write-Host "  直前のバージョン: $(Get-Content $StateFile -Raw | ForEach-Object { $_.Trim() })" -ForegroundColor Cyan
    }
    Write-Host ''
    exit 0
}

# --- -AddToPath / -FixShortcuts 単独: 設定だけ行って終了 ---
# これが無いと単独指定で新規バージョンの取得（約 70MB）が始まってしまう。
# どちらの処理も実行中の WezTerm に影響しないため、プロセスチェックより前に置く。
if (($AddToPath -or $FixShortcuts) -and -not ($ZipPath -or $Version -or $Rollback)) {
    Invoke-PathSetup
    Invoke-ShortcutFix
    Write-Host ''
    Write-Host '完了しました。' -ForegroundColor Green
    Write-Host ''
    exit 0
}

# --- 実行中プロセスの確認 ---
# junction の張り替え自体は動作中プロセスに影響しない。問題になるのは
# 「この管理下から起動している WezTerm」だけで、その場合は切り替えても
# 実行中のプロセスは古い版のまま動き続け、切り替えたつもりの混乱が起きる。
# 別の場所（インストーラ版など）から動いている分には支障がないので止めない。
$managed = @(
    Get-Process -Name 'wezterm*' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase) }
)
if ($managed.Count -gt 0 -and -not $AllowRunning) {
    Write-Warning "この管理下から WezTerm が実行中です（$($managed.Count) プロセス）。切り替えても実行中のプロセスは古い版のままです。"
    Write-Error 'WezTerm を終了してから実行するか、承知のうえなら -AllowRunning を付けてください。'
}

# --- -Rollback: 直前のバージョンへ戻す ---
if ($Rollback) {
    if (-not (Test-Path $StateFile)) {
        Write-Error "直前のバージョンが記録されていません。-List で確認し -Version で指定してください: $StateFile"
    }
    $previous = (Get-Content $StateFile -Raw).Trim()
    # -Force で再展開すると旧フォルダが *.bak.* へ退避されるため、
    # 記録されたバージョンが既に存在しないことがある。理由が分かる形で止める。
    if (-not (Test-Path (Join-Path $Root $previous))) {
        Write-Error "記録された直前のバージョンが見つかりません: $previous`n  -List で導入済みバージョンを確認し、-Version <名前> で指定してください。"
    }
    Write-Host "  ロールバック先: $previous" -ForegroundColor Cyan
    Set-CurrentVersion -VersionName $previous
    Write-Host ''
    Write-Host "  $(& (Join-Path $CurrentLink 'wezterm.exe') --version)" -ForegroundColor Green
    Write-Host ''
    Write-Host '完了しました。' -ForegroundColor Green
    Write-Host ''
    exit 0
}

# --- -Version: 展開済みバージョンへ切り替える ---
if ($Version) {
    Set-CurrentVersion -VersionName $Version
    Write-Host ''
    Write-Host "  $(& (Join-Path $CurrentLink 'wezterm.exe') --version)" -ForegroundColor Green
    Write-Host ''
    Write-Host '完了しました。' -ForegroundColor Green
    Write-Host ''
    exit 0
}

# --- ここから新規バージョンの導入 ---
$workDir = Join-Path ([System.IO.Path]::GetTempPath()) "wezterm-zip-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

try {
    # --- zip の用意 ---
    if ($ZipPath) {
        if (-not (Test-Path $ZipPath)) {
            Write-Error "zip が見つかりません: $ZipPath"
        }
        $zipFile = (Resolve-Path $ZipPath).Path
        Write-Host "  ローカルの zip を使用: $zipFile" -ForegroundColor Cyan
    }
    else {
        $zipFile = Join-Path $workDir 'WezTerm-windows-nightly.zip'
        $shaFile = "$zipFile.sha256"

        # 既定の進捗バーがあると Invoke-WebRequest は 70MB で極端に遅くなる
        $prevProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            Write-Host '  ダウンロード中 (約 70MB) ...' -ForegroundColor Cyan
            Invoke-WebRequest -Uri $ZipUrl -OutFile $zipFile
            Invoke-WebRequest -Uri "$ZipUrl.sha256" -OutFile $shaFile
        }
        finally {
            $ProgressPreference = $prevProgress
        }

        # --- sha256 照合 ---
        # .sha256 の中身は "<hash>  <filename>" 形式。先頭トークンだけを見る。
        $expected = ((Get-Content $shaFile -Raw).Trim() -split '\s+')[0]
        $actual = (Get-FileHash $zipFile -Algorithm SHA256).Hash
        if ($expected -ne $actual) {
            Write-Error "sha256 が一致しません。`n  expected: $expected`n  actual:   $actual"
        }
        Write-Host "  sha256 OK: $actual" -ForegroundColor Green
    }

    # --- 展開 ---
    $extractDir = Join-Path $workDir 'extracted'
    Write-Host '  展開中 ...' -ForegroundColor Cyan
    Expand-Archive -Path $zipFile -DestinationPath $extractDir -Force

    $exe = Get-ChildItem $extractDir -Recurse -Filter 'wezterm.exe' -File | Select-Object -First 1
    if (-not $exe) {
        Write-Error "展開物に wezterm.exe が見つかりません: $extractDir"
    }
    $payloadDir = $exe.Directory.FullName

    # --- サムドライブモードの防止 ---
    # wezterm.exe と同じ場所にドット無しの wezterm.lua があると、
    # %USERPROFILE%\.wezterm.lua より優先されて設定が乗っ取られる。
    # ドット付きの .wezterm.lua は同梱サンプルであり、この判定には掛からない。
    $thumbDriveConfig = Join-Path $payloadDir 'wezterm.lua'
    if (Test-Path $thumbDriveConfig) {
        $disabled = "$thumbDriveConfig.bundled-disabled"
        Move-Item $thumbDriveConfig $disabled -Force
        Write-Warning "同梱の wezterm.lua を無効化しました（サムドライブモードで設定が乗っ取られるため）: $disabled"
    }

    # --- バージョン判定 ---
    $versionString = Get-WezTermVersion -ExePath $exe.FullName
    $versionName = "WezTerm-windows-$versionString"
    Write-Host "  バージョン: $versionString" -ForegroundColor Green

    # --- 配置 ---
    $destDir = Join-Path $Root $versionName
    if (Test-Path $destDir) {
        if ($Force) {
            $backup = "$destDir.bak.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Write-Host "  既存バージョンをバックアップ: $destDir → $backup" -ForegroundColor Cyan
            Move-Item $destDir $backup
        }
        else {
            Write-Host "  このバージョンは導入済みです（展開をスキップ）: $versionName" -ForegroundColor Yellow
        }
    }

    if (-not (Test-Path $destDir)) {
        Move-Item $payloadDir $destDir
        Write-Host "  配置: $destDir" -ForegroundColor Green
    }

    # --- current の張り替え ---
    Set-CurrentVersion -VersionName $versionName
}
finally {
    if (Test-Path $workDir) {
        Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- 検証 ---
Write-Host ''
Write-Host '  --- 検証 ---' -ForegroundColor Magenta
$currentExe = Join-Path $CurrentLink 'wezterm.exe'
Write-Host "  $(& $currentExe --version)" -ForegroundColor Green

$repoConfig = Join-Path $HOME 'dotfiles\wezterm\.wezterm.lua'
if (Test-Path $repoConfig) {
    & $currentExe --config-file $repoConfig show-keys > $null 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host '  設定の読み込み: OK' -ForegroundColor Green
    }
    else {
        Write-Warning "設定の読み込みに失敗しました。新バージョンで非互換が入った可能性があります: $repoConfig"
        Write-Warning "  ロールバック: .\scripts\setup_wezterm_version.ps1 -Rollback"
    }
}

Invoke-PathSetup
Invoke-ShortcutFix

Write-Host ''
Write-Host '完了しました。' -ForegroundColor Green
Write-Host ''

# 設定読み込みチェックの $LASTEXITCODE が末尾まで残り、
# 成功しているのに終了コード 1 を返してしまうため明示的に 0 で終える。
exit 0
