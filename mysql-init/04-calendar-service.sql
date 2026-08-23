-- MSA 전환(calendar-service 추출, Phase 7 DB per Service 패턴 재사용): 01/02/03과 동일한
-- 방식으로 calendar_db 스키마 + 전용 계정을 추가한다. legacy-monolith(groovy_db)는 삭제됐고,
-- 여기서는 calendar-service 전용 스키마 + 그 스키마에만 접근 가능한 전용 계정만 추가로 만든다.

CREATE DATABASE IF NOT EXISTS calendar_db
  CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;

CREATE USER IF NOT EXISTS 'calendar_service'@'%'
  IDENTIFIED BY 'calendar_service_local_only_pw';

-- calendar_service 계정은 calendar_db에만 권한이 있다. groovy_db/study_db/identity_db에는
-- 아무 권한도 주지 않는다.
GRANT ALL PRIVILEGES ON calendar_db.* TO 'calendar_service'@'%';

FLUSH PRIVILEGES;
