-- MSA 전환(study-service 추출, Phase 7 DB per Service 패턴 재사용): 01/02와 동일한 방식으로
-- study_db 스키마 + 전용 계정을 추가한다.

CREATE DATABASE IF NOT EXISTS study_db
  CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;

CREATE USER IF NOT EXISTS 'study_service'@'%'
  IDENTIFIED BY 'study_service_local_only_pw';

-- study_service 계정은 study_db에만 권한이 있다. groovy_db/identity_db/notification_db에는
-- 아무 권한도 주지 않는다.
GRANT ALL PRIVILEGES ON study_db.* TO 'study_service'@'%';

FLUSH PRIVILEGES;
