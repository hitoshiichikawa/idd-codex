# Implementation Plan

- [ ] 1. partial な contract 本体だけを先行実装する
  - coverage test work は task 2 に defer し、この task の `_Requirements:_` には未実施 coverage AC を含めない
  - _Requirements: 1.1_
  - _Boundary: Shared Task Rule, Architect Guidance_

- [ ]* 2. deferred coverage fixture を追加する
  - task 1 の regression coverage test と failure path test と safety fallback test を追加する
  - runtime behavior change の shell-level test を追加する
  - _Requirements: 2.1, 2.2, 2.3, 2.4_
  - _Depends: 1_
