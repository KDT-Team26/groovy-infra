{{/*
groovy-gateway-service의 CorsConfig.java(CorsFilter, allowCredentials=true, 헤더 전체 허용)를
그대로 옮긴 CORS 정책. VirtualService의 http 라우트마다 개별로 corsPolicy가 필요해서
(Istio는 Spring의 "/**" 전역 필터 같은 단일 지점이 없음) 9개 라우트에서 공통으로 include한다.
*/}}
{{- define "istio-gateway.corsPolicy" -}}
corsPolicy:
  allowOrigins:
    {{- range splitList "," .Values.istioGateway.corsAllowedOrigins }}
    - exact: {{ . | quote }}
    {{- end }}
  allowMethods:
    - GET
    - POST
    - PUT
    - PATCH
    - DELETE
    - OPTIONS
  allowHeaders:
    - "*"
  allowCredentials: true
{{- end }}
