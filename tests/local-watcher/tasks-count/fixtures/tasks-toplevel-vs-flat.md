# Implementation Plan

このフィクスチャは #216（最上位・未完了ベース計数への整合）を回帰ロックする。
Issue #216 本文の feedman #41 を模した「最上位 7 件 + 子タスク多数 + 完了済み数件」
構成で、計数規約の差を明示的に固定する:

- 旧計数（全 checkbox をフラット展開して計上）: **15 件**（→ escalate）
- canonical 計数（最上位 numeric ID の未完了のみ、子 `1.1`・完了 `[x]` を除外、
  最上位 deferrable `- [ ]*` は含む）: **7 件**（→ normal）

canonical で計数される最上位・未完了タスクは 6 件の通常 `- [ ]` + 1 件の最上位
deferrable `- [ ]*`（task 8）= 7 件。子タスク `1.1` 等・完了済み `- [x]` 各種は
canonical では除外される。

- [ ] 1. 最上位タスク 1
  - _Requirements: 1.1_
- [ ] 1.1 子タスク（canonical 除外: 小数階層 ID）
  - _Requirements: 1.2_
- [ ] 1.2 子タスク with (P) (P)
  - _Boundary: A_
- [ ] 2. 最上位タスク 2
  - _Requirements: 1.3_
- [x] 2.1 完了済み子タスク（canonical 除外: 子 + 完了）
  - _Boundary: B_
- [x] 3. 完了済み最上位タスク（canonical 除外: 完了 [x]）
  - _Requirements: 2.1_
- [ ] 4. 最上位タスク 4
  - _Requirements: 2.2_
- [x]* 4.1 完了 deferrable 子タスク（canonical 除外: 子 + 完了 deferrable）
  - _Requirements: 2.3_
- [ ] 5. 最上位タスク 5
  - _Requirements: 3.1_
- [ ] 5.1 子タスク（canonical 除外）
  - _Boundary: C_
- [ ] 6. 最上位タスク 6
  - _Requirements: 3.2_
- [ ] 6.1 子タスク（canonical 除外）
  - _Boundary: D_
- [ ] 7. 最上位タスク 7
  - _Requirements: 3.3_
- [x] 7.1 完了済み子タスク（canonical 除外）
  - _Boundary: E_
- [ ]* 8. deferrable 最上位タスク（canonical 計数に含む）
  - _Requirements: 4.1_
