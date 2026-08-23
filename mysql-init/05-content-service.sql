-- MSA 전환(content-service 추출, Phase 7 DB per Service 패턴 재사용): 01-notification-service.sql/
-- 02-identity-service.sql/03-study-service.sql/04-calendar-service.sql과 동일한 방식으로
-- content_db 스키마 + 전용 계정을 추가한다.
--
-- 알려진 한계(문서화된 임시 상태): content_db는 study_db/identity_db와 물리적으로 분리된 별개의
-- 스키마다. 정합성은 순전히 애플리케이션 레벨(Long ID 참조 + 동기 HTTP 조회)로만 유지된다.

CREATE DATABASE IF NOT EXISTS content_db
  CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;

CREATE USER IF NOT EXISTS 'content_service'@'%'
  IDENTIFIED BY 'content_service_local_only_pw';

-- content_service 계정은 content_db에만 권한이 있다. groovy_db/identity_db/study_db/
-- calendar_db에는 아무 권한도 주지 않는다.
GRANT ALL PRIVILEGES ON content_db.* TO 'content_service'@'%';

FLUSH PRIVILEGES;
