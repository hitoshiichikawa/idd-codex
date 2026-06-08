# Implementation Plan

- [ ] 1. coverage AC を先行 task に載せたまま test work を defer する
  - regression coverage / failure path / safety fallback / shell-level coverage は task 2 に defer する
  - _Requirements:_ 1.1, 2.1, 2.2, 2.3, 2.4
  - _Boundary:_ Shared Task Rule, Architect Guidance

- [ ]* 2. deferred coverage fixture を追加する
  - task 1 の regression coverage test を追加する
  - task 1 の failure path test を追加する
  - task 1 の safety fallback test を追加する
  - runtime behavior change の shell-level test を追加する
  - _Requirements:_ 2.1, 2.2, 2.3, 2.4
  - _Depends:_ 1
