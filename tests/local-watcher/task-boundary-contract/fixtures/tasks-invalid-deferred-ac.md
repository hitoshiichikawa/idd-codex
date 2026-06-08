# Implementation Plan

- [ ] 1. coverage AC を先行 task に載せたまま test work を defer する
  - regression coverage と failure path と safety fallback の test work は task 2 に defer する
  - _Requirements: 1.1, 2.1, 2.2, 2.3, 2.4_
  - _Boundary: Shared Task Rule, Architect Guidance_

- [ ]* 2. deferred coverage fixture を追加する
  - task 1 の regression coverage test と failure path test と safety fallback test を追加する
  - runtime behavior change の shell-level test を追加する
  - _Requirements: 2.1, 2.2, 2.3, 2.4_
  - _Depends: 1_
