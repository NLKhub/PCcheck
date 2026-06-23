# PCCheck - Windows PC 보안 점검 도구

PC의 보안 설정 항목을 자동으로 점검하고, 결과를 JSON 파일로 저장하여 수집 서버로 전송합니다.

---

## 파일 구성

```
PCCheck/
├── remote_diagnostic_pc.bat   # 점검 실행 본체 (클라이언트) — 설정/실행 모두 포함
├── server_receive.ps1         # 결과 수신 서버 본체
└── server_receive.bat         # 수신 서버 실행기
```

> `remote_diagnostic_pc.vbs` 는 최초 실행 시 bat 파일과 같은 위치에 **자동 생성**됩니다.
> 별도로 배포하거나 미리 만들 필요 없습니다.

---

## 점검 항목 (PC-001 ~ PC-018)

| 항목 | 내용 |
|---|---|
| PC-001 | 비밀번호 주기적 변경 (최대 사용 기간, 만료 계정) |
| PC-002 | 비밀번호 관리정책 (최소 길이, 복잡성) |
| PC-003 | 복구 콘솔 자동 로그온 금지 |
| PC-004 | 공유 폴더 제거 (기본 공유, Everyone 권한) |
| PC-005 | 불필요한 서비스 실행 여부 |
| PC-006 | 비인가 상용 메신저 사용 금지 |
| PC-007 | 파일 시스템 NTFS 포맷 설정 |
| PC-008 | 멀티 부팅 설정 여부 |
| PC-009 | 브라우저 종료 시 임시 파일 삭제 설정 |
| PC-010 | 주기적 보안 패치 적용 여부 |
| PC-011 | 지원 종료되지 않은 Windows OS 버전 |
| PC-012 | Windows 자동 로그인 설정 여부 |
| PC-013 | 바이러스 백신 설치 및 업데이트 |
| PC-014 | 백신 실시간 감시 기능 활성화 |
| PC-015 | Windows 방화벽 활성화 |
| PC-016 | 화면보호기 및 암호 보호 설정 |
| PC-017 | 이동식 미디어 자동 실행 방지 |
| PC-018 | 원격 지원 비활성화 |

---

## 아키텍처

```
[점검 대상 PC]                              [수집 서버 10.140.124.207]

  remote_diagnostic_pc.bat (최초 1회 실행)
       │
       ├─ VBS 자동 생성 (remote_diagnostic_pc.vbs)
       ├─ 스케줄드 태스크 등록 (CloudrawPCCheck)
       └─ 태스크 즉시 실행 후 종료
                                              server_receive.bat 실행 중
       ┌──────────────────────────┐                   │
       │  CloudrawPCCheck 태스크  │                   │
       │  wscript → bat --silent  │                   │
       │  PC-001 ~ PC-018 점검    │                   │
       │  18개 항목 완전성 검증   │                   │
       └──────────┬───────────────┘                   │
                  │                                   │
                  └──── HTTP POST :8080/result ───────►│
                                             results\HOSTNAME_IP_날짜_result.json
```

---

## 서버 준비 (수집 서버: 10.140.124.207)

### `server_receive.bat` 실행 (관리자)

```
server_receive.bat 더블클릭
```

- 관리자 권한 자동 요청
- TCP 8080 방화벽 인바운드 규칙 자동 등록
- 수신 대기 시작 (`Ctrl+C`로 종료)
- 수신된 파일은 `results\` 폴더에 자동 저장

### 수신 로그 예시

```
============================================
  PCCheck Result Receiver
============================================
  Started : 2026-06-22 10:00:00
  Port    : 8080
  Save to : C:\PCCheck\results
  Stop    : Ctrl+C
============================================

[10:05:32]  OK   PC-HONG (192.168.1.55) -> PC-HONG_192.168.1.55_20260622_100532_result.json
[10:06:11]  OK   PC-KIM  (192.168.1.60) -> PC-KIM_192.168.1.60_20260622_100611_result.json
```

---

## 클라이언트 실행 방법

### 최초 실행 — 대상 PC에서 1회

관리자 계정(또는 관리자 권한이 있는 사용자)으로 로그인된 상태에서:

```
remote_diagnostic_pc.bat 더블클릭
```

bat 파일이 자동으로 다음을 수행합니다:

1. `remote_diagnostic_pc.vbs` 생성 (없을 경우)
2. 스케줄드 태스크 `CloudrawPCCheck` 등록
3. 태스크를 즉시 실행하고 종료

이후 점검은 **창 없이 백그라운드**에서 완전 무음으로 실행됩니다.

> 대상 사용자로 로그인된 상태에서 실행해야 HKCU(화면보호기, 자동실행 등 사용자 설정) 항목이 정확히 점검됩니다.

---

### 이후 실행 — 동일 PC 재실행

bat 파일을 다시 더블클릭하면 등록된 태스크를 즉시 트리거하고 종료합니다.

또는 명령줄에서:

```cmd
schtasks /run /tn "CloudrawPCCheck"
```

---

### 원격 일괄 실행

```powershell
# 여러 PC 동시 실행
Invoke-Command -ComputerName PC001, PC002, PC003 -ScriptBlock {
    schtasks /run /tn "CloudrawPCCheck"
}
```

---

### 태스크 제거

```cmd
schtasks /delete /tn "CloudrawPCCheck" /f
```

---

## 실행 흐름 상세

```
더블클릭 (--silent 없음)
  │
  ├─ 태스크 등록 여부 확인
  │    ├─ 등록됨  → schtasks /run 후 종료
  │    └─ 미등록  → 관리자 권한 확인
  │             ├─ 비관리자 → UAC 요청 후 재실행 (1회만)
  │             └─ 관리자   → VBS 생성 + 태스크 등록 + 즉시 실행 후 종료
  │
  └─ 태스크 실행 시 (--silent 플래그 자동 전달)
       wscript.exe → remote_diagnostic_pc.vbs
       cmd /c remote_diagnostic_pc.bat --silent
         │
         ├─ PC-001 ~ PC-018 점검 수행
         ├─ result.json → HOSTNAME_IP_result.json 로컬 저장
         ├─ PC-001~PC-018 18개 항목 완전성 검증
         │    ├─ 누락 항목 있음 → 로컬 저장만, 전송 안 함
         │    └─ 18개 모두 존재 → HTTP POST → 서버 전송
         └─ 완료
```

---

## 결과 JSON 구조

```json
[
  {
    "id": "PC-001",
    "total_result": "Y",
    "total_comment": "CIIP_PC-001_WINDOWS_Y_0",
    "response": [
      {
        "id": "PC-001-001",
        "data": [{ "max_password_age": "90", "pw_never_expires_users": "None", "comment": "..." }],
        "result": "Y"
      }
    ]
  },
  ...
]
```

`total_result` 값: `Y` (양호) / `N` (취약) / `Verification` (수동 확인 필요) / `N/A` (해당 없음)

---

## 요구 사항

| 항목 | 요건 |
|---|---|
| 운영체제 | Windows 10 / Windows 11 |
| 권한 | 관리자 (Administrator) — 최초 실행 시 1회만 필요 |
| PowerShell | 3.0 이상 (Windows 10 기본 탑재) |
| 네트워크 | 클라이언트 → 서버 TCP 8080 허용 |

---

## 주의 사항

- 점검 대상 PC와 수집 서버 사이의 방화벽에서 **TCP 8080** 포트가 열려 있어야 합니다.
- 서버 `server_receive.bat`은 점검 실행 전에 먼저 켜져 있어야 합니다.
- 18개 항목이 모두 포함된 결과만 서버로 전송됩니다. 누락 항목이 있으면 로컬에만 저장됩니다.
- 서버 전송 실패 시에도 로컬에 `HOSTNAME_IP_result.json`은 정상 저장됩니다.
- 수집 서버 주소 변경이 필요한 경우 `remote_diagnostic_pc.bat` 내 `$serverUrl` 값을 수정하세요.
