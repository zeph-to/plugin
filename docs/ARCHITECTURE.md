# Zeph Agent Plugin — Architecture Guide

## 3개의 레이어

```
┌─────────────────────────────────────────────────────────────┐
│ Layer 3: Plugin (hooks)                                     │
│ → 자동 실행. Claude Code 전용. 100% 신뢰.                    │
│ → Stop hook, AskUserQuestion hook                           │
│ → zeph CLI (@zeph-to/cli) 사용                          │
├─────────────────────────────────────────────────────────────┤
│ Layer 2: MCP Server (@zeph-to/mcp-server)                   │
│ → AI가 tool 호출. 요청 시 동작.                               │
│ → zeph_ask, zeph_notify, zeph_prompt, zeph_input 등         │
│ → Claude Code, Gemini CLI, Cursor, Windsurf 지원            │
├─────────────────────────────────────────────────────────────┤
│ Layer 1: CLI (@zeph-to/cli)                            │
│ → shell command. 어디서든 실행 가능.                          │
│ → zeph notify --title "..." --body "..."                    │
│ → notify만 가능. prompt/input 불가.                          │
└─────────────────────────────────────────────────────────────┘
```

## 각 레이어 비교

| | CLI | MCP Server | Plugin (hooks) |
|---|---|---|---|
| **npm 패키지** | @zeph-to/cli | @zeph-to/mcp-server | — (GitHub repo) |
| **실행 방식** | shell command | AI agent가 tool 호출 | Claude Code event hook |
| **트리거** | 수동 / hook script | AI 자발적 or 유저 요청 | 자동 (이벤트 기반) |
| **신뢰도** | 100% | ~70% (요청 시 100%) | 100% |
| **notify** | ✓ | ✓ | ✓ (Stop hook) |
| **prompt** | ✗ | ✓ | ✗ |
| **input** | ✗ | ✓ | ✗ |
| **clipboard** | ✗ | ✓ | ✗ |
| **file** | ✗ | ✓ | ✗ |
| **지원 에이전트** | 아무데서나 | MCP 지원 에이전트 | Claude Code only |

## Plugin Hooks 상세

### Stop Hook (zeph-stop.sh)

```
Claude 응답 종료
  → Stop hook 실행
  → transcript 파일에서 tool_use 횟수 카운트
  → 2개 이상이면 → zeph CLI로 push 전송
  → 2개 미만이면 → skip (노이즈 방지)
```

**언제 동작:** 매 Claude 응답 후 자동 실행
**알림 내용:** "Claude 완료: {project} / {branch} — {N} tools"
**조건:** tool 사용 2개 이상 (짧은 대화 필터링)

### AskUserQuestion Hook (zeph-ask.sh)

```
Claude가 유저에게 질문 (AskUserQuestion tool 호출)
  → PreToolUse hook 실행
  → 질문 내용 추출
  → zeph CLI로 push 전송
```

**언제 동작:** Claude가 질문할 때 자동
**알림 내용:** "Claude 질문: {project} / {질문 내용}"

### SessionStart Hook (zeph-setup.js)

```
세션 시작
  → ZEPH_API_KEY 확인
  → 없으면: hookSpecificOutput.additionalContext에 안내 메시지 (내부 노트)
  → 있으면: 원격 제어 룰 (remote-control rules) 주입
      ├─ ZEPH_HOOK_ID 있으면: 양방향 (notify + ask + prompt + input)
      └─ 없으면: 단방향 (notify only)
```

**중요:** 출력은 `{"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": "..."}}` JSON 포맷. plain text stdout은 사용자 transcript에만 보이고 모델 컨텍스트에는 안 들어감 — 룰이 실제 작동하려면 JSON 출력 필수.

**참고:** 룰은 권장 사항이지만, Stop hook 자동 알림과 짝지어 설계되어 있어 모델이 룰을 따르지 않더라도 알림 자체는 누락되지 않음.

## MCP Server Tools 상세

| Tool | 용도 | 동작 | 필요 env |
|------|------|------|----------|
| zeph_notify | 알림 전송 | fire & forget | ZEPH_API_KEY |
| zeph_ask | 선택지+텍스트 결합 | blocking (응답 대기) | + ZEPH_HOOK_ID |
| zeph_prompt | 선택지 질문 | blocking (응답 대기) | + ZEPH_HOOK_ID |
| zeph_input | 텍스트 입력 | blocking (응답 대기) | + ZEPH_HOOK_ID |
| zeph_clipboard | 클립보드 복사 | fire & forget | ZEPH_API_KEY |
| zeph_file | 파일 전송 | fire & forget | ZEPH_API_KEY |
| zeph_list | 알림 목록 | read only | ZEPH_API_KEY |
| zeph_dismiss | 알림 읽음 | fire & forget | ZEPH_API_KEY |
| zeph_dismiss_all | 전체 읽음 | fire & forget | ZEPH_API_KEY |
| zeph_broadcast | 채널 전송 | fire & forget | ZEPH_API_KEY |

## CLI 사용법

```bash
# 설치
npm i -g @zeph-to/cli

# 기본 사용
zeph notify --title "빌드 완료" --body "에러 0건"

# env var로 인증
export ZEPH_API_KEY="ak_..."
zeph notify --title "test"

# flag로 인증
zeph notify --key ak_... --title "test"

# dev 서버
export ZEPH_BASE_URL="https://api.zeph.to/d1"
zeph notify --title "dev test"
```

## Mute / Push Mode 메커니즘

```
/zeph-mute 실행
  → Claude가 bash 실행: touch ${XDG_STATE_HOME:-~/.local/state}/zeph/muted-{cksum hash}
  → Stop hook: mute 파일 체크 → exit 0 (알림 skip)
  → Ask hook: mute 파일 체크 → exit 0 (알림 skip)
  → CLI (cli): mute 파일 체크 → exit 0 (다른 agent도 적용)
```

- **Scope:** project-dir 기반 hash. 다른 프로젝트 세션은 영향 없음.
- **생명주기:** per-user state dir에 저장 → `/zeph-unmute` 전까지 유지 (재부팅에도 유지).
  구버전이 `/tmp`에 남긴 파일은 현재 유저 소유일 때만 인정 (world-writable `/tmp`
  선점 공격 차단).
- **Mute 커맨드:** `/zeph-mute`, `/zeph-unmute`, `/zeph-status`

**Push Mode** — mute와 같은 state-파일 패턴(`pushmode-{hash}`)으로 Stop
hook의 자동 푸시 볼륨을 조절. mute가 완전 침묵이라면 push mode는 그 사이 다이얼:

- `/zeph-quiet` → `high` 마커만 통과 · `/zeph-loud` → 매 턴 푸시 · `/zeph-normal` → 기본
- **Scope:** 기본은 프로젝트 단위. `--global`을 붙이면 해시 없는 `pushmode-default`에
  기록되어, 자기 다이얼이 없는 모든 프로젝트의 기본값이 됨. 해석 순서는
  프로젝트 파일 > (구버전) `/tmp` 파일 > `pushmode-default` > `normal` —
  프로젝트 다이얼이 항상 전역을 이김. mute에는 전역 형태가 없음: 내용이 아니라
  존재로 판정하는 파일이라 특정 프로젝트만 해제할 방법이 없기 때문.
- **우선순위:** mute > push mode > (모델의) per-turn Push Signal 마커 > 볼륨 휴리스틱.
- Push Signal 마커(`<!-- zeph: skip|push|high -->`)는 모델이 응답에 emit → Stop hook이
  읽어 그 턴의 푸시를 조정(읽고 본문에서 strip).

## 유저 시나리오별 가이드

### 1. 여러 세션 돌리고 끝나면 알림 받고 싶다
→ **Plugin 설치만 하면 됨.** Stop hook이 자동 알림.

### 2. Claude가 질문할 때 모바일로 알림 받고 싶다
→ **Plugin 설치만 하면 됨.** AskUserQuestion hook이 자동 알림.
→ 단, 답변은 터미널에서 해야 함.

### 3. 모바일에서 직접 답변/지시하고 싶다 (원격 제어)
→ `ZEPH_HOOK_ID` 설정만 하면 됨. SessionStart 훅이 자동으로 양방향 룰을 주입.
→ 별도 프롬프트 불필요. 모델이 작업 종료 시 `zeph_ask`로 다음 액션 버튼+자유 입력을 보내고, 폰 응답을 직접 명령으로 해석해 즉시 실행 (Ask Loop).
→ `done`/`stop`/`exit` 응답 또는 타임아웃 fallback으로 루프 종료.

### 4. CI/CD나 스크립트에서 알림 보내고 싶다
→ **CLI만 사용:**
```bash
zeph notify --key ak_... --title "Deploy 완료"
```

### 5. 다른 AI 에이전트 (Cursor, Windsurf, Gemini, Codex, Copilot, Cline, Aider)에서 쓰고 싶다
→ **`npm install -g @zeph-to/cli && zeph install` 이면 됨.** 설치된 에이전트를 감지해서 각각 MCP 서버 + 알림 훅 + 행동 룰 파일(각 에이전트의 native always-on 위치)을 설정. (`zeph cc` 안 쓰고 알림만 원하면 `npx @zeph-to/cli install`로 글로벌 설치 생략 가능)
→ 행동 룰(zeph_ask 사용법, sticky REMOTE 등)은 7개 에이전트 모두 동일하게 적용됨 — cli의 templates.ts 공통 코어에서 생성.
→ Claude Code는 plugin이 SessionStart 훅으로 룰 주입, 나머지는 native 룰 파일.
