# Implementation Plan

- [ ] 1. partial な contract 本体だけを先行実装する
  - coverage test work は task 2 に defer し、この task の `_Requirements:_` には未実施 coverage AC を含めない
  - _Requirements:_ 1.1
  - _Boundary:_ Shared Task Rule, Architect Guidance

- [ ]* 2. deferred coverage fixture を追加する
  - task 1 の regression coverage test を追加する
  - task 1 の failure path test を追加する
  - task 1 の safety fallback test を追加する
  - runtime behavior change の shell-level test を追加する
  - _Requirements:_ 2.1, 2.2, 2.3, 2.4
  - _Depends:_ 1
