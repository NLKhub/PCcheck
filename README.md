# PCCheck - Windows PC 보안 점검 도구

PC의 보안 설정 항목을 자동으로 점검하고, 결과를 JSON 파일로 저장하여 수집 서버로 전송합니다.

---

## 파일 구성

```
PCCheck/
├── remote_diagnostic_pc.bat   # 점검 실행 본체 (클라이언트)
├── run_silent.vbs             # 무창 실행 래퍼 (CMD 창 숨김)
├── install_task.ps1           # 스케줄드 태스크 등록 (UAC 없는 완전 silent 실행)
├── server_receive.ps1         # 결과 수신 서버 본체
└── server_receive.bat         # 수신 서버 실행기
```

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
[점검 대상 PC]                         [수집 서버 10.140.124.207]
                                       
  schtasks /run ...                      server_receive.bat 실행 중
       │                                         │
       ▼                                         │
  run_silent.vbs (창 숨김)                       │
       │                                         │
       ▼                                         │
  remote_diagnostic_pc.bat                       │
       │  점검 수행                               │
       │  결과 저장: HOSTNAME_IP_result.json       │
       │                                         │
       └─── HTTP POST :8080/result ─────────────►│
                                        results\HOSTNAME_IP_날짜_result.json
```

---

## 서버 준비 (수집 서버: 10.140.124.207)

### 1. `server_receive.bat` 실행 (관리자)

```
server_receive.bat 더블클릭
```

- 관리자 권한 자동 요청
- TCP 8080 방화벽 인바운드 규칙 자동 등록
- 수신 대기 시작 (`Ctrl+C`로 종료)

### 2. 수신 로그 예시

```
============================================
  PCCheck 결과 수신 서버
============================================
  시작  : 2026-06-22 10:00:00
  포트  : 8080
  저장  : C:\PCCheck\results
  종료  : Ctrl+C
============================================

[10:05:32]  OK   PC-HONG (192.168.1.55) -> PC-HONG_192.168.1.55_20260622_100532_result.json
[10:06:11]  OK   PC-KIM  (192.168.1.60) -> PC-KIM_192.168.1.60_20260622_100611_result.json
```

### 3. 결과 파일 저장 위치

`server_receive.bat` 옆에 `results\` 폴더가 자동 생성됩니다.

```
results\
├── PC-HONG_192.168.1.55_20260622_100532_result.json
├── PC-KIM_192.168.1.60_20260622_100611_result.json
└── ...
```

---

## 클라이언트 실행 방법

### 방법 1 — 일반 실행 (CMD 창 보임, UAC 발생)

```
remote_diagnostic_pc.bat 더블클릭
```

- 관리자 권한 자동 요청 (UAC 표시)
- 점검 진행 상황이 콘솔에 출력됨
- 완료 후 `HOSTNAME_IP_result.json` 저장 및 서버 전송

---

### 방법 2 — Silent 실행 (CMD 창 숨김, UAC 1회 발생)

```
run_silent.vbs 더블클릭
```

- CMD 창이 완전히 숨겨진 채 백그라운드에서 실행
- 관리자 권한이 없는 경우 UAC 팝업 1회 발생
- 이미 관리자 계정이면 UAC 없이 완전 무음 실행

---

### 방법 3 — 완전 Silent 실행 ✅ 권장 (UAC 없음, 창 없음)

스케줄드 태스크를 사전 등록하는 방식입니다.
**IT 관리자가 대상 PC에서 1회만 실행**하면, 이후 트리거 시 UAC와 창이 전혀 표시되지 않습니다.

#### 3-1. 태스크 등록 (대상 PC에서 1회)

관리자 PowerShell을 열고 실행:
```powershell
.\install_task.ps1
```

> 대상 사용자로 로그인된 상태에서 실행해야 HKCU(화면보호기, 자동실행 등 사용자 설정) 항목이 정확하게 점검됩니다.

#### 3-2. 점검 실행 (이후 매번)

```cmd
schtasks /run /tn "CloudrawPCCheck"
```

사용자 화면에 아무것도 표시되지 않고 백그라운드에서 실행됩니다.

#### 3-3. 원격 일괄 실행

```powershell
# 여러 PC 동시 실행
Invoke-Command -ComputerName PC001, PC002, PC003 -ScriptBlock {
    schtasks /run /tn "CloudrawPCCheck"
}
```

#### 3-4. 태스크 제거

```powershell
.\install_task.ps1 -Uninstall
```

---

## 방법별 비교

| | 방법 1 (직접 실행) | 방법 2 (VBS) | 방법 3 (태스크) |
|---|:---:|:---:|:---:|
| CMD 창 표시 | O | X | X |
| UAC 팝업 | O | 비관리자만 | **X** |
| 사전 준비 | 없음 | 없음 | 태스크 1회 등록 |
| 원격 일괄 실행 | X | X | **O** |
| HKCU 정확도 | O | O | O |

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
| 권한 | 관리자 (Administrator) |
| PowerShell | 3.0 이상 (Windows 10 기본 탑재) |
| 네트워크 | 클라이언트 → 서버 TCP 8080 허용 |

---

## 주의 사항

- 점검 대상 PC와 수집 서버 사이의 방화벽에서 **TCP 8080** 포트가 열려 있어야 합니다.
- 서버 `server_receive.bat`은 점검 실행 전에 먼저 켜져 있어야 합니다.
- 서버 전송 실패 시에도 로컬에 `HOSTNAME_IP_result.json`은 정상 저장됩니다.
- 수집 서버 주소 변경이 필요한 경우 `remote_diagnostic_pc.bat` 내 `$serverUrl` 값을 수정하세요.
