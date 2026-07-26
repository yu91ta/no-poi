# P-1GP2026_PrimeMember

リマインダー（タスク通知）と家計簿（収支履歴）は、容量を抑えるために圧縮バイナリ形式でローカル保存されます。

- 優先保存先: `./.nopoi_local/reminder_expense.min.v1.bin`
- 上記が書き込み不可の環境では、OS のアプリサポート領域へ自動でフォールバック
- `.nopoi_local/` は `.gitignore` に追加済みのため、`git push` 対象から除外されます
