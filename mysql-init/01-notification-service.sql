-- MSA 전환 Phase 7(DB per Service): 하나의 MySQL 컨테이너 안에서 스키마 소유권부터 분리한다.
-- legacy-monolith(groovy_db)는 삭제됐다. 여기서는
-- notification-service 전용 스키마 + 그 스키마에만 접근 가능한 전용 계정을 추가로 만든다.
--
-- 비밀번호를 파일에 고정값으로 넣은 건 이 컴포즈 스택이 로컬 검증 전용(볼륨도 없어 매번
-- 새로 뜨는 휘발성 DB)이기 때문이다. 실제 배포에서는 시크릿 매니저 등으로 주입해야 한다
-- (Phase 10/11에서 다룰 영역 — 지금은 "스키마/권한 분리"라는 이번 Phase의 주제에 집중한다).

CREATE DATABASE IF NOT EXISTS notification_db
  CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;

CREATE USER IF NOT EXISTS 'notification_service'@'%'
  IDENTIFIED BY 'notification_service_local_only_pw';

-- notification_service 계정은 notification_db에만 권한이 있다. groovy_db(legacy가 쓰는
-- study/user/memoir/calendar 테이블들)에는 아무 권한도 주지 않는다 — 완료 기준
-- "코드에서 cross-schema JOIN이 물리적으로 실행 불가능함"을 계정 레벨에서 강제한다.
GRANT ALL PRIVILEGES ON notification_db.* TO 'notification_service'@'%';

FLUSH PRIVILEGES;
