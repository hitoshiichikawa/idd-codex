# Implementation Plan

- [ ] 1. watcher の task boundary contract を実装する
  - runtime behavior change を伴う contract 判定を shared rule と Architect prompt に追加する
  - regression coverage test と failure path test と safety fallback test を同 task の driver fixture で追加する
  - shell-level test として `bash tests/local-watcher/task-boundary-contract/contract-driver.sh` を追加する
  - _Requirements: 2.1, 2.2, 2.3, 2.4_
