# Implementation Plan

このフィクスチャは Req 1.2 / 1.3 / 1.4 を網羅する:
- 4 種 checkbox: `- [ ]` / `- [x]` / `- [ ]*` / `- [x]*`
- 親タスク（末尾 `.` あり）と子タスク（末尾 `.` なし、小数階層 ID）が混在
- `(P)` 並列マーカー付きタスクが含まれる

期待件数: 8 件（行内すべてが checkbox + numeric ID 形式のタスク行）

- [ ] 1. 未完了 親タスク
  - _Requirements: 1.1_

- [x] 1.1 完了済み 子タスク（末尾 . なし）
  - _Boundary: A_

- [ ] 1.2 未完了 子タスク with (P)
  - _Requirements: 1.2_
  - _Boundary: B_

- [ ]* 2. deferrable 親タスク
  - 対応する受入基準: 1.3
  - _Requirements: 1.3_

- [x]* 2.1 完了 deferrable 子タスク
  - _Requirements: 1.4_

- [ ] 3. 通常タスク
  - _Requirements: 2.1_

- [ ] 4. もうひとつ
  - _Requirements: 2.2_

- [x] 5. 完了済み単独タスク
  - _Requirements: 2.3_
