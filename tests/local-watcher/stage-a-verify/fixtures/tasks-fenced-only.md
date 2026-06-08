# Implementation Plan

- [ ] 1. Implement
  - 本体実装
  - _Requirements: 1.1_

- [ ] 2. Verify (fenced only)
  - 以下を順に実行:

```bash
./gradlew assembleDebug
./gradlew test
shellcheck local-watcher/bin/*.sh
```

  - _Requirements: 1.2_
