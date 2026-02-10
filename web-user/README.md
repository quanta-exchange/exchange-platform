# web-user

`edge-gateway` 백엔드 위에 붙이는 사용자용 웹 프론트엔드(Vite + React + TypeScript)입니다.

## 실행

1. 백엔드 실행 (예: edge-gateway on `localhost:8081`)
2. 프론트엔드 실행:

```bash
cd web-user
npm install
npm run dev
```

개발 모드에서는 Vite 프록시가 `/v1`, `/ws` 요청을 `VITE_PROXY_TARGET`으로 전달합니다.

## 환경변수

`.env.example` 기준:

- `VITE_PROXY_TARGET`: 개발 서버 프록시 대상 (기본 `http://localhost:8081`)
- `VITE_API_BASE_URL`: 프록시 없이 절대 URL 호출이 필요할 때 사용
- `VITE_WS_URL`: 웹소켓 URL 강제 지정이 필요할 때 사용

## 주의

- `/v1/orders`, `/v1/smoke/trades`는 서버에서 `EDGE_API_SECRETS`를 설정하면 서명이 필요합니다.
- 현재 웹 앱은 데모/로컬 개발 기준으로, 서명 우회 없이 동작하려면 `EDGE_API_SECRETS`를 비워 둬야 합니다.
- 실운영에서는 브라우저가 비밀키를 직접 들지 않도록 BFF/서명 프록시를 추가하는 것이 맞습니다.
