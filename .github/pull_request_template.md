## 변경 내용

<!-- 무엇을 왜 바꿨는지 적는다. 관련 이슈가 있으면 `Closes #번호`를 적는다. -->

## 확인 항목

- [ ] PR 제목이 Conventional Commits 형식이다. 스쿼시 병합하면 PR 제목이 `main`의 커밋 메시지가 된다.
- [ ] `src/`를 바꿨다면 `bash tools/build.sh`로 `dist/`를 다시 만들어 같은 PR에 넣었다.
- [ ] `sudo bash tests/run.sh`가 통과한다.
- [ ] 사용자에게 보이는 변경은 CHANGELOG의 `[Unreleased]`에 적었다.
- [ ] 호환을 깨는 변경이면 PR 제목의 타입 뒤에 `!`를 붙였고, 병합할 때 커밋 본문에 `BREAKING CHANGE:`를 적는다.

## 실제 VM 확인

<!-- 실제 VM에서 확인했다면 OS, 하이퍼바이저, 확인한 항목(docs/DESIGN.md 검증 현황의 목록 번호)을 적는다. 확인하지 않았다면 이 구역을 지운다. -->
