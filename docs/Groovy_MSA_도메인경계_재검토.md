# Groovy MSA 전환 — 도메인 경계 재검토 (Phase 1 착수 전)

> Phase 0 의존성 분석([`Groovy_MSA_Phase0_의존성분석.md`](./Groovy_MSA_Phase0_의존성분석.md)) 결과를 바탕으로,
> Phase 1(Modular Monolith 패키지 재편)을 시작하기 전에 현재 6개 도메인(Study/User/Memoir/Calendar/Notification/Tag)
> 경계 자체가 적절한지 재검토한다. **결론: 분리·통합이 필요한 도메인은 없음.** 다만 경계는 유지하되
> 소유권을 재확인해야 하는 지점 2곳을 확인했다.

## 검토 기준

DDD Bounded Context 관점에서 아래 3가지를 각 도메인에 적용:
1. **트랜잭션 일관성 경계**: 하나의 트랜잭션(또는 락)이 여러 엔티티에 걸쳐 있다면, 그 엔티티들은 물리적으로 분리하기 어렵다 → 같은 서비스로 묶여야 함.
2. **독자적 존재 이유(Aggregate Root)**: 다른 도메인 없이도 그 자체로 의미 있는 라이프사이클을 갖는가.
3. **소유권 명확성**: 데이터를 "누가 쓰고 누가 읽기만 하는지"가 명확한가, 아니면 두 도메인이 동등하게 소유권을 주장하는가.

## 도메인별 재검토

### Study (StudyService + ApplicationService + WaitlistService) — 분리하지 않음
정원(capacity) 판단이 `@Lock(PESSIMISTIC_WRITE)`로 Study 행을 잠근 채 Application(승인 수)과 Waitlist(대기열)를 함께 조작한다
(`ApplicationService.updateStatus()`가 Study 락 + Application 상태 변경 + Waitlist 제거를 한 트랜잭션에서 처리).
이 세 개를 서로 다른 서비스/DB로 쪼개면 정원 초과 방지를 분산 트랜잭션(Saga)으로 다시 구현해야 하는데,
지금 이 경계를 지키는 이유가 바로 그 비용을 피하기 위함이다. **하나의 Aggregate로 유지 — 계획서의 study-service
경계(Study+Application+Waitlist)가 코드 실제 결합도와 정확히 일치함을 재확인.**

### Memoir (MemoirService + MemoirCommentService) — 분리하지 않음
Memoir/Comment/Like는 항상 함께 조회·집계(댓글 수, 좋아요 수)되고 삭제도 캐스케이드로 함께 일어난다.
단일 Aggregate. 계획서의 content-service 경계 유지.

### Calendar — 분리·통합하지 않음
Study에 대한 의존도가 높아 "그냥 Study에 흡수하면 안 되나" 검토했으나, **개인 일정(스터디와 무관)이라는
독자적 존재 이유**가 있어 Study의 하위 개념이 아니다. 계획서의 calendar-service 경계 유지.
다만 Study 엔티티를 자신의 영속 계층에 직접 들고 있는 방식(N+1 회피용 JOIN FETCH까지 필요했던 상태)은
경계가 흐려진 신호이므로, 이번 Phase 1에서 ID 참조로 전환한다(§ Phase 1 실행 참고).

### Notification, User — 변경 없음
Notification은 나가는 의존성이 0인 leaf 도메인, User는 Auth+프로필이 하나의 Aggregate로 묶여 있어
분리할 이유가 없다.

### Tag — 경계는 유지하되 "소유권"을 명시적으로 재정의
가장 애매한 지점이었다. `Tag`(마스터 목록)는 순수 참조 데이터이고, 실제로는 두 개의 서로 다른 관계가
`tag` 패키지 하나에 얹혀 있다:
- `StudyTag` — **Study Aggregate가 소유**하는 데이터 (어떤 스터디가 어떤 태그를 다는지)
- `UserTag` — **User Aggregate가 소유**하는 데이터 (유저가 어떤 태그를 선호하는지)

계획서 초안은 "Tag는 작으니 study-service에 붙여둔다"고 제안했는데, 재검토 결과 이는 정확하지 않다.
`UserTag`(선호 태그, `/api/tags/me`)를 study-service에 두면 identity-service가 "내 선호 태그 조회"
하나를 위해 study-service를 호출해야 하는 역전이 생긴다. **Tag 마스터 데이터는 두 Bounded Context가
공유하는 참조 데이터(Shared Kernel)로 취급하고, StudyTag/UserTag는 각각 소유 Aggregate 쪽에 남기는
방향이 더 타당하다.** 지금 당장 패키지를 쪼개지는 않되(Tag 자체가 워낙 작아 지금 분리하는 비용이
더 크다), **Phase 2(서비스 경계 확정) 때 "Tag를 study-service에 흡수" 대신 "Tag 마스터 데이터를 어느
서비스가 소유하고 나머지 서비스는 어떻게 참조/복제할지"를 별도 안건으로 다시 논의**하도록 계획서에
반영해둔다.

## 결론

- 6개 도메인 경계(Study/User/Memoir/Calendar/Notification/Tag) 자체는 **분리·통합 없이 그대로 진행**.
- Tag의 "study-service 흡수" 제안만 재검토 대상으로 남기고 Phase 2로 이관.
- Phase 1은 기존 경계를 전제로, 경계를 넘나드는 **구현 방식**(Repository 직접 접근, Calendar의 Study
  엔티티 영속 참조)을 정리하는 데 집중한다.
