# wezterm-zip-setup

ブログ記事（https://catnipglitch.dev/wezterm-zip-setup/ ）の配布物です。

WezTerm の ZIP（ポータブル）版を `%LOCALAPPDATA%\wezterm-zip` 配下にバージョン別で配置し、`current` という junction で「いま使う版」を切り替える PowerShell スクリプトです。WezTerm の nightly はローリングタグでアセットが上書きされ、古い版を後から取得できないため、バージョン別に残しておく方式にしています。

## ファイル

- `setup_wezterm_version.ps1` — 最新 nightly のダウンロード、sha256 照合、展開、`current` junction の作成・切り替えまでを行うスクリプト

## 使い方

```powershell
# 最新 nightly を取得して切り替える
.\setup_wezterm_version.ps1

# ユーザーレベル PATH に current を追加する
.\setup_wezterm_version.ps1 -AddToPath

# 導入済みバージョンと current の確認
.\setup_wezterm_version.ps1 -List

# 直前のバージョンへ戻す
.\setup_wezterm_version.ps1 -Rollback

# スタートメニュー・タスクバーピンの向き先を current へ修正する
.\setup_wezterm_version.ps1 -FixShortcuts
```

そのほかのパラメータはスクリプト先頭のコメントベースヘルプを参照してください（`Get-Help .\setup_wezterm_version.ps1 -Detailed`）。

## 動作要件と注記

- Windows 11 + PowerShell 7 で動作確認しています。管理者権限は不要です
- 末尾の「設定の読み込み」検証は筆者環境の設定ファイルパス（`~\dotfiles\wezterm\.wezterm.lua`）を参照しており、存在しない環境ではスキップされます
- 更新・切り替えの前に WezTerm をすべて終了してください（実行中は既定で中断します）

## 凍結ポリシー

このフォルダは記事公開時点のスナップショットで、公開後は更新しません。不具合が見つかった場合はこの README に errata として追記します。
