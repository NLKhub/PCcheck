@echo off
:: *****************************************************************************
:: Copyright (c) 2026 Cloudraw Co. Ltd. All Rights Reserved.
::
:: This software is the confidential and proprietary information of
:: Cloudraw Co. Ltd. ("Confidential Information"). You shall not disclose
:: such Confidential Information and shall use it only in accordance with
:: the terms of the license agreement you entered into with Cloudraw.
:: *****************************************************************************

:: --silent : scheduled task invocation -> skip setup, run diagnostics
if /I "%~1"=="--silent" goto :MAIN

:: ======================================================================
:: SETUP MODE  (first run: creates VBS launcher + registers task)
:: ======================================================================
chcp 65001 >nul

:: Task already registered -> just trigger silently and exit
schtasks /query /tn "CloudrawPCCheck" >nul 2>&1
if %ERRORLEVEL% equ 0 (
    schtasks /run /tn "CloudrawPCCheck" >nul 2>&1
    exit
)

:: Task not registered yet -- elevation required for setup
net session >nul 2>&1
if %ERRORLEVEL% neq 0 (
    powershell -Command "Start-Process cmd -ArgumentList '/c \"%~f0\"' -Verb RunAs -WindowStyle Hidden"
    exit
)

:: [Admin] 1) Create VBS silent launcher (same base name as this bat, .vbs extension)
set "VBS_FILE=%~dpn0.vbs"
if not exist "%VBS_FILE%" (
    (
        echo Dim s,f,b
        echo Set s=CreateObject^("WScript.Shell"^)
        echo Set f=CreateObject^("Scripting.FileSystemObject"^)
        echo b=f.BuildPath^(f.GetParentFolderName^(WScript.ScriptFullName^),f.GetBaseName^(WScript.ScriptFullName^)^&".bat"^)
        echo s.Run "cmd /c "^&Chr^(34^)^&Chr^(34^)^&b^&Chr^(34^)^&" --silent"^&Chr^(34^),0,False
    ) > "%VBS_FILE%"
)

:: [Admin] 2) Register scheduled task
powershell -NoProfile -ExecutionPolicy Bypass -Command "$n='CloudrawPCCheck'; $v='%VBS_FILE%'; $a=New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('//nologo '+[char]34+$v+[char]34); $s=New-ScheduledTaskSettingsSet -Hidden -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew; $p=New-ScheduledTaskPrincipal -UserId (whoami) -LogonType Interactive -RunLevel Highest; Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue; Register-ScheduledTask -TaskName $n -Action $a -Settings $s -Principal $p | Out-Null"

:: [Admin] 3) Run immediately
schtasks /run /tn "CloudrawPCCheck" >nul 2>&1
exit

:: ======================================================================
:: MAIN DIAGNOSTIC  (invoked via --silent by the scheduled task)
:: ======================================================================
:MAIN
chcp 65001 >nul
:: 관리자 권한 확인
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo 관리자 권한이 필요합니다. 다시 실행합니다.
    powershell -Command "Start-Process cmd -ArgumentList '/c \"%~f0\" --silent' -Verb RunAs -WindowStyle Hidden"
    exit
)
setlocal EnableDelayedExpansion
pushd "%~dp0"
set "HOSTNAME=%COMPUTERNAME%"
for /f "usebackq tokens=*" %%A in (`hostname`) do set "HOSTNAME=%%A"
if exist result.json del result.json
if exist "!HOSTNAME!_result.json" del "!HOSTNAME!_result.json"

set cloudraw=%TEMP%\cloudraw
set script=%cloudraw%\script

if not exist "%cloudraw%" (
    mkdir "%cloudraw%"
)

TITLE Windows Security Check

:: Windows 버전 확인 시작
if exist %windir%\SysWOW64 (
    set WinBit=64
) else (
    set WinBit=32
)

:: Windows 10, 11 구분
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-CimInstance Win32_OperatingSystem | Select-Object -ExpandProperty Caption" > "%temp%\os_caption.txt"
set /p OSName=<"%temp%\os_caption.txt"
del "%temp%\os_caption.txt"

set "WinVer_name="
echo %OSName% | findstr /I "Windows 10" >nul && (
    set WinVer_name=10
    set WinVer=10
)
echo %OSName% | findstr /I "Windows 11" >nul && (
    set WinVer_name=11
    set WinVer=11
)

if not defined WinVer_name (
    set WinVer_name=Unknown
    set WinVer=0
)

echo Windows %WinVer_name% %WinBit%bit


echo #################           [PC-001] 비밀번호 주기적 변경 확인 (PC-01)          ################

:: [PC-001-001] 최대 암호 사용 기간 점검
set "security_file=%cloudraw%\cfg_pc001.txt"
set "utf8_security_file=%cloudraw%\cfg_pc001_utf8.txt"

secedit /export /cfg "%security_file%" > nul 2>&1
if exist "%security_file%" (
    powershell -NoProfile -NonInteractive -Command "Get-Content '%security_file%' | Set-Content -Encoding utf8 '%utf8_security_file%'"
    chcp 65001 > nul
)

set "max_pw_age=Unknown"
if exist "%utf8_security_file%" (
    for /f "tokens=2 delims==" %%A in ('findstr /B /C:"MaximumPasswordAge =" "%utf8_security_file%"') do set "max_pw_age=%%A"
)
:: 공백 제거
for /f "tokens=* delims= " %%A in ("!max_pw_age!") do set "max_pw_age=%%A"

:: secedit에서 -1은 '제한 없음'을 의미
if "!max_pw_age!"=="-1" set "max_pw_age=0"

:: [PC-001-002] 암호 사용 기간 제한 없음 설정된 계정 확인
powershell -NoProfile -ExecutionPolicy Bypass -Command "$users = Get-CimInstance Win32_UserAccount -Filter 'LocalAccount=True and Disabled=False and PasswordExpires=False'; if ($users) { ($users.Name) -join ', ' } else { 'None' }" > "%temp%\pc001_pw_users.txt"
set "pw_never_expires_users=Unknown"
set /p pw_never_expires_users=<"%temp%\pc001_pw_users.txt"
del "%temp%\pc001_pw_users.txt"

:: 판정 로직
set "is_age_valid=0"
if "!max_pw_age!" NEQ "Unknown" (
    if !max_pw_age! LEQ 90 if !max_pw_age! GTR 0 set "is_age_valid=1"
)

set "is_user_valid=0"
if "!pw_never_expires_users!"=="None" set "is_user_valid=1"

if "!is_age_valid!"=="1" (
    if "!is_user_valid!"=="1" (
        set PC_001_result=Y
        set PC_001_001={"max_password_age": "!max_pw_age!", "pw_never_expires_users": "!pw_never_expires_users!", "comment": "Maximum password age is set to 90 days or less, and password expiration is applied to all active accounts."}
    ) else (
        set PC_001_result=N
        set PC_001_001={"max_password_age": "!max_pw_age!", "pw_never_expires_users": "!pw_never_expires_users!", "comment": "Active accounts with password never expires enabled were found."}
    )
) else (
    set PC_001_result=N
    if "!max_pw_age!"=="0" (
        set PC_001_001={"max_password_age": "Unlimited", "pw_never_expires_users": "!pw_never_expires_users!", "comment": "Maximum password age is set to unlimited. This is vulnerable."}
    ) else if "!max_pw_age!"=="Unknown" (
        set PC_001_result=N/A
        set PC_001_001={"max_password_age": "Unknown", "pw_never_expires_users": "!pw_never_expires_users!", "comment": "Unable to determine the maximum password age."}
    ) else (
        set PC_001_001={"max_password_age": "!max_pw_age!", "pw_never_expires_users": "!pw_never_expires_users!", "comment": "Maximum password age exceeds 90 days."}
    )
)




:: 종합 평가 로직
set "PC_001_total_comment="
set "PC_001_total_result=!PC_001_result!"

if "!PC_001_result!"=="N" (
    set "PC_001_total_comment=CIIP_PC-001_WINDOWS_N_0"
) else if "!PC_001_result!"=="Y" (
    set "PC_001_total_comment=CIIP_PC-001_WINDOWS_Y_0"
) else (
    set "PC_001_total_comment=CIIP_PC-001_WINDOWS_N/A_0"
)

echo Result=!PC_001_total_result!

echo [ >> result.json

:: 최종 JSON 출력
(
echo {
echo   "id": "PC-001",
echo   "total_result": "!PC_001_total_result!",
echo   "total_comment": "!PC_001_total_comment!",
echo   "response": [
echo     {
echo       "id": "PC-001-001",
echo       "data": [!PC_001_001!],
echo       "result": "!PC_001_result!"
echo     }
echo   ]
echo }
) >> result.json
echo , >> result.json


echo #################           [PC-002] 비밀번호 관리정책 설정 점검 (PC-02)          ################

:: 보안 정책 내보내기
set "security_file_pc002=%cloudraw%\cfg_pc002.txt"
set "utf8_security_file_pc002=%cloudraw%\cfg_pc002_utf8.txt"

secedit /export /cfg "%security_file_pc002%" > nul 2>&1
if exist "%security_file_pc002%" (
    powershell -NoProfile -NonInteractive -Command "Get-Content '%security_file_pc002%' | Set-Content -Encoding utf8 '%utf8_security_file_pc002%'"
    chcp 65001 > nul
)

if not exist "%utf8_security_file_pc002%" (
    set PC_002_001={"min_password_length": "Unknown", "comment": "Unable to verify the security policy configuration file."}
    set PC_002_001_result=N/A
    set PC_002_002={"password_complexity": "Unknown", "comment": "Unable to verify the security policy configuration file."}
    set PC_002_002_result=N/A
    goto :PC002_EVAL
)

:: [PC-002-001] 최소 암호 길이 점검 (기준: 8자 이상)
set "min_pw_len=0"
for /f "tokens=2 delims==" %%A in ('findstr /B /C:"MinimumPasswordLength =" "%utf8_security_file_pc002%"') do set "min_pw_len=%%A"
for /f "tokens=* delims= " %%A in ("!min_pw_len!") do set "min_pw_len=%%A"

if !min_pw_len! GEQ 8 (
    set PC_002_001={"min_password_length": "!min_pw_len!", "comment": "Minimum password length is set to 8 or more characters."}
    set PC_002_001_result=Y
) else if !min_pw_len! EQU 0 (
    set PC_002_001={"min_password_length": "!min_pw_len!", "comment": "Minimum password length is not set (0). Empty passwords are allowed. This is vulnerable."}
    set PC_002_001_result=N
) else (
    set PC_002_001={"min_password_length": "!min_pw_len!", "comment": "Minimum password length is less than 8 characters. This is vulnerable."}
    set PC_002_001_result=N
)


:: [PC-002-002] 암호 복잡성 설정 점검 (사용함 = 1)
set "pw_complexity=0"
for /f "tokens=2 delims==" %%A in ('findstr /B /C:"PasswordComplexity =" "%utf8_security_file_pc002%"') do set "pw_complexity=%%A"
for /f "tokens=* delims= " %%A in ("!pw_complexity!") do set "pw_complexity=%%A"

if "!pw_complexity!"=="1" (
    set PC_002_002={"password_complexity": "Enabled", "comment": "Password complexity requirement is enabled."}
    set PC_002_002_result=Y
) else (
    set PC_002_002={"password_complexity": "Disabled", "comment": "Password complexity requirement is disabled. This is vulnerable."}
    set PC_002_002_result=N
)


:: 임시 파일 정리
if exist "%security_file_pc002%" del "%security_file_pc002%"
if exist "%utf8_security_file_pc002%" del "%utf8_security_file_pc002%"
chcp 65001 > nul

:PC002_EVAL

:: 종합 평가 로직
set "PC_002_total_comment="
set "PC_002_total_result="

if "!PC_002_001_result!"=="Y" if "!PC_002_002_result!"=="Y" (
    set "PC_002_total_result=Y"
    set "PC_002_total_comment=CIIP_PC-002_WINDOWS_Y_0"
    goto :PC002_JSON
)

if "!PC_002_001_result!"=="N/A" if "!PC_002_002_result!"=="N/A" (
    set "PC_002_total_result=N/A"
    set "PC_002_total_comment=CIIP_PC-002_WINDOWS_N/A_0"
    goto :PC002_JSON
)

set "PC_002_total_result=N"
set "PC_002_total_comment=CIIP_PC-002_WINDOWS_N_0"

:PC002_JSON

echo Result=!PC_002_total_result!

:: 최종 JSON 출력
(
echo {
echo   "id": "PC-002",
echo   "total_result": "!PC_002_total_result!",
echo   "total_comment": "!PC_002_total_comment!",
echo   "response": [
echo     {
echo       "id": "PC-002-001",
echo       "data": [!PC_002_001!],
echo       "result": "!PC_002_001_result!"
echo     },
echo     {
echo       "id": "PC-002-002",
echo       "data": [!PC_002_002!],
echo       "result": "!PC_002_002_result!"
echo     }
echo   ]
echo }
) >> result.json
echo , >> result.json


echo #################           [PC-003] 복구 콘솔에서 자동 로그온을 금지하도록 설정 (PC-03)          ################

:: [PC-003-001] 복구 콘솔 자동 관리 로그온 허용 설정 점검
:: 레지스트리 경로: HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Setup\RecoveryConsole
:: 값 이름: SecurityLevel
:: 양호 기준: 값이 0 (사용 안 함) 또는 키가 존재하지 않는 경우
set "recovery_autologon="
set "reg_path_pc003=HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Setup\RecoveryConsole"

for /f "tokens=3" %%A in ('reg query "%reg_path_pc003%" /v SecurityLevel 2^>nul') do (
    set "recovery_autologon=%%A"
)

if not defined recovery_autologon (
    set PC_003_001={"SecurityLevel": "Not Configured", "comment": "Recovery Console SecurityLevel registry key does not exist. Auto logon is disabled by default."}
    set PC_003_result=Y
) else if "!recovery_autologon!"=="0x0" (
    set PC_003_001={"SecurityLevel": "0 (Disabled)", "comment": "Recovery Console automatic administrative logon is disabled."}
    set PC_003_result=Y
) else if "!recovery_autologon!"=="0x1" (
    set PC_003_001={"SecurityLevel": "1 (Enabled)", "comment": "Recovery Console automatic administrative logon is enabled. This is vulnerable."}
    set PC_003_result=N
) else (
    set PC_003_001={"SecurityLevel": "!recovery_autologon!", "comment": "Recovery Console SecurityLevel has an unexpected value."}
    set PC_003_result=N
)



:: 종합 평가 로직
set "PC_003_total_comment="
set "PC_003_total_result=!PC_003_result!"

if "!PC_003_result!"=="N" (
    set "PC_003_total_comment=CIIP_PC-003_WINDOWS_N_0"
) else if "!PC_003_result!"=="Y" (
    set "PC_003_total_comment=CIIP_PC-003_WINDOWS_Y_0"
) else (
    set "PC_003_total_comment=CIIP_PC-003_WINDOWS_N/A_0"
)

echo Result=!PC_003_total_result!

:: 최종 JSON 출력
(
echo {
echo   "id": "PC-003",
echo   "total_result": "!PC_003_total_result!",
echo   "total_comment": "!PC_003_total_comment!",
echo   "response": [
echo     {
echo       "id": "PC-003-001",
echo       "data": [!PC_003_001!],
echo       "result": "!PC_003_result!"
echo     }
echo   ]
echo }
) >> result.json
echo , >> result.json



echo #################           [PC-004] 공유 폴더 제거 점검 (PC-04)          ################

:: [PC-004-001] 기본 공유 폴더 존재 여부 점검 (C$, D$, Admin$ 등)
set "default_shares="
set "first_share=1"

for /f "tokens=1" %%A in ('net share 2^>nul ^| findstr /R ".*\$"') do (
    echo %%A | findstr /I /R "^C\$ ^D\$ ^E\$ ^F\$ ^Admin\$" >nul && (
        if "!first_share!"=="1" (
            set "default_shares=%%A"
            set "first_share=0"
        ) else (
            set "default_shares=!default_shares!, %%A"
        )
    )
)

:: IPC$는 시스템 필수 공유이므로 제외
if "!first_share!"=="1" (
    set PC_004_001={"default_shares": "None", "comment": "No default administrative shares (C$, D$, Admin$) found."}
    set PC_004_001_result=Y
) else (
    set PC_004_001={"default_shares": "!default_shares!", "comment": "Default administrative shares found. These should be removed."}
    set PC_004_001_result=N
)


:: [PC-004-002] AutoShareWks 레지스트리 값 점검 (기본 공유 자동 생성 방지)
:: 경로: HKLM\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters
:: 값: AutoShareWks = 0 이면 양호
set "auto_share_wks="
set "reg_path_pc004=HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters"

for /f "tokens=3" %%A in ('reg query "%reg_path_pc004%" /v AutoShareWks 2^>nul') do (
    set "auto_share_wks=%%A"
)

if not defined auto_share_wks (
    set PC_004_002={"AutoShareWks": "Not Configured", "comment": "AutoShareWks registry value does not exist. Default shares will be created automatically on reboot."}
    set PC_004_002_result=N
) else if "!auto_share_wks!"=="0x0" (
    set PC_004_002={"AutoShareWks": "0 (Disabled)", "comment": "AutoShareWks is set to 0. Automatic default share creation is disabled."}
    set PC_004_002_result=Y
) else (
    set PC_004_002={"AutoShareWks": "!auto_share_wks!", "comment": "AutoShareWks is not set to 0. Default shares will be created automatically on reboot."}
    set PC_004_002_result=N
)


:: [PC-004-003] 일반 공유 폴더의 Everyone 권한 존재 여부 점검
powershell -NoProfile -ExecutionPolicy Bypass -Command "$shares = Get-SmbShare -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '\$$' -and $_.Name -ne 'IPC$' }; $result = @(); foreach ($s in $shares) { $acl = Get-SmbShareAccess -Name $s.Name -ErrorAction SilentlyContinue | Where-Object { $_.AccountName -eq 'Everyone' }; if ($acl) { $result += $s.Name } }; if ($result.Count -gt 0) { $result -join ', ' } else { 'None' }" > "%temp%\pc004_everyone.txt"
set "everyone_shares=None"
set /p everyone_shares=<"%temp%\pc004_everyone.txt"
del "%temp%\pc004_everyone.txt"

if "!everyone_shares!"=="None" (
    set PC_004_003={"everyone_shared_folders": "None", "comment": "No shared folders with Everyone permission found."}
    set PC_004_003_result=Y
) else (
    set PC_004_003={"everyone_shared_folders": "!everyone_shares!", "comment": "Shared folders with Everyone permission found. Everyone access should be removed."}
    set PC_004_003_result=N
)


:: [PC-004-004] 암호로 보호된 공유 설정 여부 점검
:: 레지스트리: HKLM\SYSTEM\CurrentControlSet\Control\Lsa -> everyoneincludesanonymous
:: 및 네트워크 공유 암호 보호 상태 확인
set "pw_protected_sharing="

powershell -NoProfile -ExecutionPolicy Bypass -Command "$regPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'; $val = (Get-ItemProperty -Path $regPath -Name 'everyoneincludesanonymous' -ErrorAction SilentlyContinue).everyoneincludesanonymous; $netPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters'; $restrict = (Get-ItemProperty -Path $netPath -Name 'restrictnullsessaccess' -ErrorAction SilentlyContinue).restrictnullsessaccess; if ($val -eq 0 -and ($restrict -eq 1 -or $restrict -eq $null)) { 'Enabled' } else { 'Disabled' }" > "%temp%\pc004_pwshare.txt"
set /p pw_protected_sharing=<"%temp%\pc004_pwshare.txt"
del "%temp%\pc004_pwshare.txt"

if "!pw_protected_sharing!"=="Enabled" (
    set PC_004_004={"password_protected_sharing": "Enabled", "comment": "Password protected sharing is enabled."}
    set PC_004_004_result=Y
) else (
    set PC_004_004={"password_protected_sharing": "Disabled", "comment": "Password protected sharing is disabled. This is vulnerable."}
    set PC_004_004_result=N
)


:: 종합 평가 로직
set "PC_004_total_comment="
set "PC_004_total_result="

:: 4개 소항목 모두 Y여야 양호
if "!PC_004_001_result!"=="Y" if "!PC_004_002_result!"=="Y" if "!PC_004_003_result!"=="Y" if "!PC_004_004_result!"=="Y" (
    set "PC_004_total_result=Y"
    set "PC_004_total_comment=CIIP_PC-004_WINDOWS_Y_0"
    goto :PC004_JSON
)

set "PC_004_total_result=N"
set "PC_004_total_comment=CIIP_PC-004_WINDOWS_N_0"

:PC004_JSON

echo Result=!PC_004_total_result!

:: 최종 JSON 출력
(
echo {
echo   "id": "PC-004",
echo   "total_result": "!PC_004_total_result!",
echo   "total_comment": "!PC_004_total_comment!",
echo   "response": [
echo     {
echo       "id": "PC-004-001",
echo       "data": [!PC_004_001!],
echo       "result": "!PC_004_001_result!"
echo     },
echo     {
echo       "id": "PC-004-002",
echo       "data": [!PC_004_002!],
echo       "result": "!PC_004_002_result!"
echo     },
echo     {
echo       "id": "PC-004-003",
echo       "data": [!PC_004_003!],
echo       "result": "!PC_004_003_result!"
echo     },
echo     {
echo       "id": "PC-004-004",
echo       "data": [!PC_004_004!],
echo       "result": "!PC_004_004_result!"
echo     }
echo   ]
echo }
) >> result.json
echo , >> result.json



echo #################           [PC-005] 항목의 불필요한 서비스 점검 (PC-05)          ################

:: [PC-005-001] 불필요한 서비스 실행 여부 점검
:: 서비스명(ServiceName) 기준으로 점검, Windows 10/11에 없는 서비스는 자동 무시
:: 1. 점검할 서비스 목록 정의
set "svcList='Alerter','wuauserv','ClipSrv','Browser','CryptSvc','Dhcp','TrkWks','TrkSvr','Dnscache','WerSvc','hidserv','ImapiService','irmon','Messenger','mnmsrvc','WmdmPmSN','Spooler','RemoteRegistry','simptcp','upnphost','wzcsvc'"

:: 2. PowerShell 실행 결과를 임시 파일에 저장 (중단 방지)
powershell -NoProfile -ExecutionPolicy Bypass -Command "$running = @(); foreach ($svc in @(%svcList%)) { $s = Get-Service -Name $svc -ErrorAction SilentlyContinue; if ($s -and $s.Status -eq 'Running') { $running += \"$($s.Name)[$($s.DisplayName)]\" } }; if ($running.Count -gt 0) { $running -join ', ' } else { 'None' }" > "%temp%\svc_result.txt"

:: 3. 임시 파일에서 결과 읽기
set /p running_unnecessary_svcs=<"%temp%\svc_result.txt"
del "%temp%\svc_result.txt"

:: 4. 결과 판정
if /i "!running_unnecessary_svcs!"=="None" (
    set "PC_005_001={"running_unnecessary_services": "None", "comment": "No unnecessary services from the checklist are running."}"
    set "PC_005_result=Y"
) else (
    set "PC_005_001={"running_unnecessary_services": "!running_unnecessary_svcs!", "comment": "Unnecessary services are currently running."}"
    set "PC_005_result=N"
)



:: 종합 평가 로직
set "PC_005_total_comment="
set "PC_005_total_result=!PC_005_result!"

if "!PC_005_result!"=="N" (
    set "PC_005_total_comment=CIIP_PC-005_WINDOWS_N_0"
) else if "!PC_005_result!"=="Y" (
    set "PC_005_total_comment=CIIP_PC-005_WINDOWS_Y_0"
) else (
    set "PC_005_total_comment=CIIP_PC-005_WINDOWS_N/A_0"
)

echo Result=!PC_005_total_result!

:: 최종 JSON 출력
(
echo {
echo   "id": "PC-005",
echo   "total_result": "!PC_005_total_result!",
echo   "total_comment": "!PC_005_total_comment!",
echo   "response": [
echo     {
echo       "id": "PC-005-001",
echo       "data": [!PC_005_001!],
echo       "result": "!PC_005_result!"
echo     }
echo   ]
echo }
) >> result.json
echo , >> result.json



echo #################           [PC-006] 비인가 상용 메신저 사용 금지 (PC-06)          ################

:: [PC-006-001] Windows Messenger 실행 허용 안 함 정책 설정 점검
:: 레지스트리: HKLM\SOFTWARE\Policies\Microsoft\Messenger\Client -> PreventRun
:: 양호 기준: PreventRun = 1 (실행 허용 안 함 = 사용)
set "messenger_policy="
set "reg_path_pc006=HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Messenger\Client"

for /f "tokens=3" %%A in ('reg query "%reg_path_pc006%" /v PreventRun 2^>nul') do (
    set "messenger_policy=%%A"
)

if not defined messenger_policy (
    set PC_006_001={"PreventRun": "Not Configured", "comment": "Windows Messenger policy (PreventRun) is not configured."}
    set PC_006_001_result=N
) else if "!messenger_policy!"=="0x1" (
    set PC_006_001={"PreventRun": "1 (Enabled)", "comment": "Windows Messenger is blocked by group policy."}
    set PC_006_001_result=Y
) else (
    set PC_006_001={"PreventRun": "!messenger_policy!", "comment": "Windows Messenger policy is not set to block execution."}
    set PC_006_001_result=N
)


:: [PC-006-002] 상용 메신저 설치 여부 점검
:: 프로그램 추가/제거 목록(Uninstall 레지스트리)에서 주요 상용 메신저 탐지
powershell -NoProfile -ExecutionPolicy Bypass -Command "$patterns = @('KakaoTalk','NateOn','Skype','LINE','Telegram','WeChat','QQ','Viber','Discord','WhatsApp'); $paths = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'); $apps = Get-ItemProperty $paths -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -ne $null }; $found = @(); foreach ($p in $patterns) { $match = $apps | Where-Object { $_.DisplayName -match $p }; if ($match) { foreach ($m in $match) { $found += $m.DisplayName } } }; if ($found.Count -gt 0) { ($found | Select-Object -Unique) -join ', ' } else { 'None' }" > "%temp%\pc006_messenger.txt"
set "installed_messengers=None"
set /p installed_messengers=<"%temp%\pc006_messenger.txt"
del "%temp%\pc006_messenger.txt"

if "!installed_messengers!"=="None" (
    set PC_006_002={"installed_messengers": "None", "comment": "No commercial messengers are installed."}
    set PC_006_002_result=Y
) else (
    set PC_006_002={"installed_messengers": "!installed_messengers!", "comment": "Commercial messengers are installed. These should be removed."}
    set PC_006_002_result=N
)


:: 종합 평가 로직
set "PC_006_total_comment="
set "PC_006_total_result="

if "!PC_006_001_result!"=="Y" if "!PC_006_002_result!"=="Y" (
    set "PC_006_total_result=Y"
    set "PC_006_total_comment=CIIP_PC-006_WINDOWS_Y_0"
    goto :PC006_JSON
)

set "PC_006_total_result=N"
set "PC_006_total_comment=CIIP_PC-006_WINDOWS_N_0"

:PC006_JSON

echo Result=!PC_006_total_result!

:: 최종 JSON 출력
(
echo {
echo   "id": "PC-006",
echo   "total_result": "!PC_006_total_result!",
echo   "total_comment": "!PC_006_total_comment!",
echo   "response": [
echo     {
echo       "id": "PC-006-001",
echo       "data": [!PC_006_001!],
echo       "result": "!PC_006_001_result!"
echo     },
echo     {
echo       "id": "PC-006-002",
echo       "data": [!PC_006_002!],
echo       "result": "!PC_006_002_result!"
echo     }
echo   ]
echo }
) >> result.json
echo , >> result.json



echo #################           [PC-007] 파일 시스템이 NTFS 포맷으로 설정 (PC-07)          ################

:: [PC-007-001] 모든 디스크 볼륨의 파일 시스템이 NTFS인지 점검
:: 1. Non-NTFS 볼륨 확인 (임시 파일 방식으로 괄호 파싱 문제 방지)
powershell -NoProfile -ExecutionPolicy Bypass -Command "$vols = Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -ne $null -and $_.DriveType -eq 'Fixed' -and $_.FileSystemType -ne 'NTFS' }; if ($vols) { ($vols | ForEach-Object { \"$($_.DriveLetter):[$($_.FileSystemType)]\" }) -join ', ' } else { 'None' }" > "%temp%\pc007_non_ntfs.txt"
set /p non_ntfs_volumes=<"%temp%\pc007_non_ntfs.txt"
del "%temp%\pc007_non_ntfs.txt"

:: 2. 전체 볼륨 정보도 수집 (참고용)
powershell -NoProfile -ExecutionPolicy Bypass -Command "$vols = Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -ne $null -and $_.DriveType -eq 'Fixed' }; if ($vols) { ($vols | ForEach-Object { \"$($_.DriveLetter):[$($_.FileSystemType)]\" }) -join ', ' } else { 'None' }" > "%temp%\pc007_all_vols.txt"
set /p all_volumes=<"%temp%\pc007_all_vols.txt"
del "%temp%\pc007_all_vols.txt"

:: 3. 결과 판정
if /i "!non_ntfs_volumes!"=="None" (
    set "PC_007_001={"all_volumes": "!all_volumes!", "non_ntfs_volumes": "None", "comment": "All fixed disk volumes are using NTFS file system."}"
    set "PC_007_result=Y"
) else (
    set "PC_007_001={"all_volumes": "!all_volumes!", "non_ntfs_volumes": "!non_ntfs_volumes!", "comment": "Non-NTFS volumes found. These should be converted to NTFS."}"
    set "PC_007_result=N"
)



:: 종합 평가 로직
set "PC_007_total_comment="
set "PC_007_total_result=!PC_007_result!"

if "!PC_007_result!"=="N" (
    set "PC_007_total_comment=CIIP_PC-007_WINDOWS_N_0"
) else if "!PC_007_result!"=="Y" (
    set "PC_007_total_comment=CIIP_PC-007_WINDOWS_Y_0"
) else (
    set "PC_007_total_comment=CIIP_PC-007_WINDOWS_N/A_0"
)

echo Result=!PC_007_total_result!

:: 최종 JSON 출력
(
echo {
echo   "id": "PC-007",
echo   "total_result": "!PC_007_total_result!",
echo   "total_comment": "!PC_007_total_comment!",
echo   "response": [
echo     {
echo       "id": "PC-007-001",
echo       "data": [!PC_007_001!],
echo       "result": "!PC_007_result!"
echo     }
echo   ]
echo }
) >> result.json
echo , >> result.json



echo #################           [PC-008] 대상 시스템이 Windows 서버를 제외한 다른 OS로 멀티 부팅이 가능하지 않도록 설정 점검 (PC-08)          ################

:: [PC-008-001] 멀티 부팅 설정 여부 점검
:: 1. PowerShell 스크립트를 임시 파일로 작성 (괄호 매칭 문제 방지를 위해 개별 echo 사용)
if exist "%temp%\pc008_script.ps1" del "%temp%\pc008_script.ps1"
echo $entries = bcdedit /enum osloader ^| Select-String -Pattern 'description\s+(.+)$' >> "%temp%\pc008_script.ps1"
echo $descs = $entries ^| ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() } ^| Where-Object { $_ -notmatch 'Recovery' -and $_ -notmatch '복구' } >> "%temp%\pc008_script.ps1"
echo if ($descs^) { >> "%temp%\pc008_script.ps1"
echo     $count = @($descs^).Count >> "%temp%\pc008_script.ps1"
echo     $list = @($descs^) -join ', ' >> "%temp%\pc008_script.ps1"
echo     Write-Output "${count}|${list}" >> "%temp%\pc008_script.ps1"
echo } else { >> "%temp%\pc008_script.ps1"
echo     Write-Output "0|None" >> "%temp%\pc008_script.ps1"
echo } >> "%temp%\pc008_script.ps1"

:: 2. 스크립트 실행
powershell -NoProfile -ExecutionPolicy Bypass -File "%temp%\pc008_script.ps1" > "%temp%\pc008_boot.txt" 2>nul
del "%temp%\pc008_script.ps1" 2>nul

:: 3. 결과 읽기
set "pc008_raw=0|None"
if exist "%temp%\pc008_boot.txt" set /p pc008_raw=<"%temp%\pc008_boot.txt"
del "%temp%\pc008_boot.txt" 2>nul

:: 4. 데이터 분리
set "os_count=0"
set "os_list=None"
for /f "tokens=1,2 delims=|" %%X in ("!pc008_raw!") do (
    set "os_count=%%X"
    set "os_list=%%Y"
)

:: 5. 결과 판정
if !os_count! LEQ 1 (
    set "PC_008_001={"os_count": "!os_count!", "os_list": "!os_list!", "comment": "Only one OS is installed."}"
    set "PC_008_result=Y"
) else (
    set "PC_008_001={"os_count": "!os_count!", "os_list": "!os_list!", "comment": "Multiple OS entries found."}"
    set "PC_008_result=N"
)



:: 종합 평가 로직
set "PC_008_total_comment="
set "PC_008_total_result=!PC_008_result!"

if "!PC_008_result!"=="N" (
    set "PC_008_total_comment=CIIP_PC-008_WINDOWS_N_0"
) else if "!PC_008_result!"=="Y" (
    set "PC_008_total_comment=CIIP_PC-008_WINDOWS_Y_0"
) else (
    set "PC_008_total_comment=CIIP_PC-008_WINDOWS_N/A_0"
)

echo Result=!PC_008_total_result!

:: 최종 JSON 출력
(
echo {
echo   "id": "PC-008",
echo   "total_result": "!PC_008_total_result!",
echo   "total_comment": "!PC_008_total_comment!",
echo   "response": [
echo     {
echo       "id": "PC-008-001",
echo       "data": [!PC_008_001!],
echo       "result": "!PC_008_result!"
echo     }
echo   ]
echo }
) >> result.json
echo , >> result.json


echo #################           [PC-009] 브라우저 종료 시 임시 인터넷 파일 폴더의 내용을 삭제하도록 설정 (PC-09)          ################

:: [PC-009-001] 그룹 정책 - 브라우저 닫을 때 임시 인터넷 파일 폴더 비우기 설정 점검
:: 레지스트리: HKLM\SOFTWARE\Policies\Microsoft\Internet Explorer\Main -> Empty Temp Files On Exit
:: 양호 기준: 값이 yes 또는 문자열 "yes"
set "gpo_empty_temp="
set "reg_path_pc009_gpo=HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Internet Explorer\Main"

for /f "tokens=2,*" %%A in ('reg query "%reg_path_pc009_gpo%" /v "Empty Temp Files On Exit" 2^>nul ^| findstr /I "Empty"') do (
    set "gpo_empty_temp=%%B"
)

if not defined gpo_empty_temp (
    set PC_009_001={"gpo_empty_temp_files": "Not Configured", "comment": "Group Policy for emptying temporary internet files on browser close is not configured."}
    set PC_009_001_result=N
) else (
    echo !gpo_empty_temp! | findstr /I "yes" >nul
    if !errorlevel! EQU 0 (
        set PC_009_001={"gpo_empty_temp_files": "Enabled", "comment": "Group Policy is configured to empty temporary internet files on browser close."}
        set PC_009_001_result=Y
    ) else (
        set PC_009_001={"gpo_empty_temp_files": "Disabled", "comment": "Group Policy for emptying temporary internet files on browser close is disabled."}
        set PC_009_001_result=N
    )
)


:: [PC-009-002] 사용자 설정 - 임시 인터넷 파일 캐시 유지 설정 점검
:: 레지스트리: HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Cache -> Persistent
:: 양호 기준: Persistent = 0 (종료 시 삭제)
set "cache_persistent="
set "reg_path_pc009_user=HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Cache"

for /f "tokens=3" %%A in ('reg query "%reg_path_pc009_user%" /v Persistent 2^>nul') do (
    set "cache_persistent=%%A"
)

if not defined cache_persistent (
    set PC_009_002={"cache_persistent": "Not Configured", "comment": "Cache Persistent registry value does not exist. Temporary files may not be deleted on browser close."}
    set PC_009_002_result=N
) else if "!cache_persistent!"=="0x0" (
    set PC_009_002={"cache_persistent": "0 (Delete on exit)", "comment": "Temporary internet files are set to be deleted when browser closes."}
    set PC_009_002_result=Y
) else (
    set PC_009_002={"cache_persistent": "!cache_persistent! (Keep)", "comment": "Temporary internet files are not deleted when browser closes. This is vulnerable."}
    set PC_009_002_result=N
)


:: 종합 평가 로직 (GPO 또는 사용자 설정 중 하나라도 활성화되어 있으면 양호)
set "PC_009_total_comment="
set "PC_009_total_result="

if "!PC_009_001_result!"=="Y" (
    set "PC_009_total_result=Y"
    set "PC_009_total_comment=CIIP_PC-009_WINDOWS_Y_0"
    goto :PC009_JSON
)
if "!PC_009_002_result!"=="Y" (
    set "PC_009_total_result=Y"
    set "PC_009_total_comment=CIIP_PC-009_WINDOWS_Y_0"
    goto :PC009_JSON
)

set "PC_009_total_result=N"
set "PC_009_total_comment=CIIP_PC-009_WINDOWS_N_0"

:PC009_JSON

echo Result=!PC_009_total_result!

:: 최종 JSON 출력
(
echo {
echo   "id": "PC-009",
echo   "total_result": "!PC_009_total_result!",
echo   "total_comment": "!PC_009_total_comment!",
echo   "response": [
echo     {
echo       "id": "PC-009-001",
echo       "data": [!PC_009_001!],
echo       "result": "!PC_009_001_result!"
echo     },
echo     {
echo       "id": "PC-009-002",
echo       "data": [!PC_009_002!],
echo       "result": "!PC_009_002_result!"
echo     }
echo   ]
echo }
) >> result.json
echo , >> result.json



echo #################           [PC-010] 주기적 보안 패치 및 벤더 권고사항 적용 (PC-10)          ################

:: [PC-010-001] 최근 적용된 보안 패치(HotFix) 확인
:: 1. PowerShell 스크립트 작성
if exist "%temp%\pc010_script.ps1" del "%temp%\pc010_script.ps1"
echo $hf = Get-CimInstance Win32_QuickFixEngineering -Property HotFixID,InstalledOn -ErrorAction SilentlyContinue ^| Where-Object { $_.InstalledOn -ne $null } ^| Sort-Object InstalledOn -Descending ^| Select-Object -First 1 >> "%temp%\pc010_script.ps1"
echo if ($hf^) { >> "%temp%\pc010_script.ps1"
echo     Write-Output "$($hf.InstalledOn.ToString('yyyy-MM-dd'))^|$($hf.HotFixID)" >> "%temp%\pc010_script.ps1"
echo } else { >> "%temp%\pc010_script.ps1"
echo     Write-Output "Unknown^|None" >> "%temp%\pc010_script.ps1"
echo } >> "%temp%\pc010_script.ps1"

:: 2. 스크립트 실행
powershell -NoProfile -ExecutionPolicy Bypass -File "%temp%\pc010_script.ps1" > "%temp%\pc010_patch.txt" 2>nul
del "%temp%\pc010_script.ps1" 2>nul

:: 3. 결과 읽기
set "last_patch_date=Unknown"
set "last_patch_kb=None"
set /p pc010_raw=<"%temp%\pc010_patch.txt"
del "%temp%\pc010_patch.txt" 2>nul

for /f "tokens=1,2 delims=|" %%X in ("!pc010_raw!") do (
    set "last_patch_date=%%X"
    set "last_patch_kb=%%Y"
)

if "!last_patch_date!"=="Unknown" (
    set "PC_010_001={"last_patch_date": "Unknown", "last_patch_kb": "None", "comment": "Unable to determine the last installed hotfix date."}"
    set "PC_010_001_result=N"
) else (
    set "PC_010_001={"last_patch_date": "!last_patch_date!", "last_patch_kb": "!last_patch_kb!", "comment": "Last installed hotfix information retrieved. Review if patch is recent enough."}"
    set "PC_010_001_result=Verification"
)


:: [PC-010-002] Windows Update 자동 업데이트 설정 확인
:: 레지스트리: HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU -> AUOptions
:: 또는 Windows 10/11의 기본 Windows Update 서비스 상태 확인
set "au_options="
set "wu_service_status="

:: 그룹 정책 기반 자동 업데이트 설정 확인
for /f "tokens=3" %%A in ('reg query "HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v AUOptions 2^>nul') do (
    set "au_options=%%A"
)

:: Windows Update 서비스(wuauserv) 상태 확인
for /f "tokens=3" %%A in ('sc query "wuauserv" 2^>nul ^| findstr "STATE"') do (
    set "wu_service_status=%%A"
)

:: AUOptions 값 해석
set "au_desc="
if "!au_options!"=="0x2" set "au_desc=2 (Notify for download and install)"
if "!au_options!"=="0x3" set "au_desc=3 (Auto download and notify for install)"
if "!au_options!"=="0x4" set "au_desc=4 (Auto download and schedule the install)"
if "!au_options!"=="0x5" set "au_desc=5 (Allow local admin to choose setting)"

if not defined au_desc (
    if defined au_options (
        set "au_desc=!au_options! (Unknown)"
    ) else (
        set "au_desc=Not Configured (Using Windows default)"
    )
)

:: Windows Update 서비스 상태 해석
set "wu_desc="
if "!wu_service_status!"=="4" set "wu_desc=Running"
if "!wu_service_status!"=="1" set "wu_desc=Stopped"
if not defined wu_desc (
    if defined wu_service_status (set "wu_desc=!wu_service_status!") else (set "wu_desc=Unknown")
)

:: 판정: 서비스가 실행 중이거나 AUOptions가 3 이상이면 양호
set "PC_010_002_result=N"
if "!wu_service_status!"=="4" set "PC_010_002_result=Y"
if "!au_options!"=="0x3" set "PC_010_002_result=Y"
if "!au_options!"=="0x4" set "PC_010_002_result=Y"
if "!au_options!"=="0x5" set "PC_010_002_result=Y"

if "!PC_010_002_result!"=="Y" (
    set PC_010_002={"AUOptions": "!au_desc!", "wu_service_status": "!wu_desc!", "comment": "Windows Update automatic update is configured."}
) else (
    set PC_010_002={"AUOptions": "!au_desc!", "wu_service_status": "!wu_desc!", "comment": "Windows Update automatic update is not properly configured."}
)


:: 종합 평가 로직
set "PC_010_total_comment="
set "PC_010_total_result="

:: 001이 Unknown이면 N, 002가 N이면 N, 그 외는 Verification (관리자 확인 필요)
if "!PC_010_001_result!"=="N" (
    set "PC_010_total_result=N"
    set "PC_010_total_comment=CIIP_PC-010_WINDOWS_N_0"
    goto :PC010_JSON
)
if "!PC_010_002_result!"=="N" (
    set "PC_010_total_result=N"
    set "PC_010_total_comment=CIIP_PC-010_WINDOWS_N_0"
    goto :PC010_JSON
)

set "PC_010_total_result=Verification"
set "PC_010_total_comment=CIIP_PC-010_WINDOWS_Verification_0"

:PC010_JSON

echo Result=!PC_010_total_result!

:: 최종 JSON 출력
(
echo {
echo   "id": "PC-010",
echo   "total_result": "!PC_010_total_result!",
echo   "total_comment": "!PC_010_total_comment!",
echo   "response": [
echo     {
echo       "id": "PC-010-001",
echo       "data": [!PC_010_001!],
echo       "result": "!PC_010_001_result!"
echo     },
echo     {
echo       "id": "PC-010-002",
echo       "data": [!PC_010_002!],
echo       "result": "!PC_010_002_result!"
echo     }
echo   ]
echo }
) >> result.json
echo , >> result.json



echo #################           [PC-011] 지원이 종료되지 않은 Windows OS Build 적용 (PC-11)          ################

:: [PC-011-001] Windows OS 버전 및 빌드 정보 확인
if exist "%temp%\pc011_script.ps1" del "%temp%\pc011_script.ps1"
echo $os = Get-CimInstance Win32_OperatingSystem >> "%temp%\pc011_script.ps1"
echo Write-Output $os.Caption >> "%temp%\pc011_script.ps1"
echo Write-Output $os.Version >> "%temp%\pc011_script.ps1"
echo Write-Output $os.BuildNumber >> "%temp%\pc011_script.ps1"

powershell -NoProfile -ExecutionPolicy Bypass -File "%temp%\pc011_script.ps1" > "%temp%\pc011_os_info.txt"
del "%temp%\pc011_script.ps1" 2>nul

(
set /p pc011_os_name=
set /p pc011_os_version=
set /p pc011_os_build=
) < "%temp%\pc011_os_info.txt"
del "%temp%\pc011_os_info.txt" 2>nul

:: DisplayVersion (예: 22H2, 23H2, 24H2)
set "pc011_display_ver="
for /f "tokens=3" %%A in ('reg query "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v DisplayVersion 2^>nul') do (
    set "pc011_display_ver=%%A"
)
if not defined pc011_display_ver set "pc011_display_ver=Unknown"

if "!pc011_os_name!"=="" (
    set PC_011_001={"os_name": "Unknown", "os_version": "Unknown", "os_build": "Unknown", "display_version": "Unknown", "comment": "Unable to retrieve OS version information."}
    set PC_011_result=N/A
) else (
    set PC_011_001={"os_name": "!pc011_os_name!", "os_version": "!pc011_os_version!", "os_build": "!pc011_os_build!", "display_version": "!pc011_display_ver!", "comment": "Verify that this OS version and build is still supported by Microsoft."}
    set PC_011_result=Verification
)



:: 종합 평가 로직
set "PC_011_total_comment="
set "PC_011_total_result=!PC_011_result!"

if "!PC_011_result!"=="N/A" (
    set "PC_011_total_comment=CIIP_PC-011_WINDOWS_N/A_0"
) else (
    set "PC_011_total_comment=CIIP_PC-011_WINDOWS_Verification_0"
)

echo Result=!PC_011_total_result!

:: 최종 JSON 출력
(
echo {
echo   "id": "PC-011",
echo   "total_result": "!PC_011_total_result!",
echo   "total_comment": "!PC_011_total_comment!",
echo   "response": [
echo     {
echo       "id": "PC-011-001",
echo       "data": [!PC_011_001!],
echo       "result": "!PC_011_result!"
echo     }
echo   ]
echo }
) >> result.json
echo , >> result.json



echo #################           [PC-012] Windows 자동 로그인 점검 (PC-12)          ################

:: [PC-012-001] AutoAdminLogon 레지스트리 값 점검
:: 레지스트리: HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon -> AutoAdminLogon
:: 양호 기준: 값이 존재하지 않거나 0인 경우 (자동 로그인 비활성화)
:: 취약 기준: 값이 1인 경우 (자동 로그인 활성화)
set "auto_admin_logon="
set "reg_path_pc012=HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"

for /f "tokens=3" %%A in ('reg query "%reg_path_pc012%" /v AutoAdminLogon 2^>nul') do (
    set "auto_admin_logon=%%A"
)

if not defined auto_admin_logon (
    set PC_012_001={"AutoAdminLogon": "Not Configured", "comment": "AutoAdminLogon registry value does not exist. Auto logon is disabled by default."}
    set PC_012_result=Y
) else if "!auto_admin_logon!"=="0" (
    set PC_012_001={"AutoAdminLogon": "0 (Disabled)", "comment": "Windows automatic logon is disabled."}
    set PC_012_result=Y
) else if "!auto_admin_logon!"=="1" (
    set PC_012_001={"AutoAdminLogon": "1 (Enabled)", "comment": "Windows automatic logon is enabled. This is vulnerable."}
    set PC_012_result=N
) else (
    set PC_012_001={"AutoAdminLogon": "!auto_admin_logon!", "comment": "AutoAdminLogon has an unexpected value."}
    set PC_012_result=N
)



:: 종합 평가 로직
set "PC_012_total_comment="
set "PC_012_total_result=!PC_012_result!"

if "!PC_012_result!"=="N" (
    set "PC_012_total_comment=CIIP_PC-012_WINDOWS_N_0"
) else if "!PC_012_result!"=="Y" (
    set "PC_012_total_comment=CIIP_PC-012_WINDOWS_Y_0"
) else (
    set "PC_012_total_comment=CIIP_PC-012_WINDOWS_N/A_0"
)

echo Result=!PC_012_total_result!

:: 최종 JSON 출력
(
echo {
echo   "id": "PC-012",
echo   "total_result": "!PC_012_total_result!",
echo   "total_comment": "!PC_012_total_comment!",
echo   "response": [
echo     {
echo       "id": "PC-012-001",
echo       "data": [!PC_012_001!],
echo       "result": "!PC_012_result!"
echo     }
echo   ]
echo }
) >> result.json
echo , >> result.json



echo #################           [PC-013] 바이러스 백신 프로그램 설치 및 주기적 업데이트 (PC-13)          ################

:: [PC-013-001] 백신 프로그램 설치 및 실행 여부 점검
:: Windows Defender(기본) 또는 3rd party 백신 확인
set "av_enabled="
set "av_name="

:: Windows Defender 상태 확인 (Get-MpComputerStatus)
if exist "%temp%\pc013_script.ps1" del "%temp%\pc013_script.ps1"
echo try { >> "%temp%\pc013_script.ps1"
echo     $s = Get-MpComputerStatus -ErrorAction Stop >> "%temp%\pc013_script.ps1"
echo     Write-Output "$($s.AntivirusEnabled)^|Windows Defender" >> "%temp%\pc013_script.ps1"
echo } catch { >> "%temp%\pc013_script.ps1"
echo     Write-Output "Error^|None" >> "%temp%\pc013_script.ps1"
echo } >> "%temp%\pc013_script.ps1"
echo try { >> "%temp%\pc013_script.ps1"
echo     $av = Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop ^| Where-Object { $_.displayName -ne 'Windows Defender' -and $_.displayName -ne 'Microsoft Defender Antivirus' } ^| Select-Object -First 1 >> "%temp%\pc013_script.ps1"
echo     if ($av^) { Write-Output $av.displayName } else { Write-Output 'None' } >> "%temp%\pc013_script.ps1"
echo } catch { >> "%temp%\pc013_script.ps1"
echo     Write-Output 'None' >> "%temp%\pc013_script.ps1"
echo } >> "%temp%\pc013_script.ps1"

powershell -NoProfile -ExecutionPolicy Bypass -File "%temp%\pc013_script.ps1" > "%temp%\pc013_av_info.txt"
del "%temp%\pc013_script.ps1" 2>nul

set "av_enabled=Error"
set "av_name=None"
set "third_party_av=None"

(
set /p pc013_raw=
set /p third_party_av=
) < "%temp%\pc013_av_info.txt"
del "%temp%\pc013_av_info.txt" 2>nul

for /f "tokens=1,2 delims=|" %%X in ("!pc013_raw!") do (
    set "av_enabled=%%X"
    set "av_name=%%Y"
)

if not "!third_party_av!"=="None" (
    set "av_name=!third_party_av!"
)

if not "!third_party_av!"=="None" (
    set "av_name=!third_party_av!"
)

if "!av_enabled!"=="True" (
    set PC_013_001={"antivirus_name": "!av_name!", "antivirus_enabled": "True", "comment": "Antivirus is installed and enabled."}
    set PC_013_001_result=Y
) else if not "!third_party_av!"=="None" (
    set PC_013_001={"antivirus_name": "!av_name!", "antivirus_enabled": "Detected (3rd party)", "comment": "Third-party antivirus detected. Verify it is active."}
    set PC_013_001_result=Verification
) else (
    set PC_013_001={"antivirus_name": "!av_name!", "antivirus_enabled": "!av_enabled!", "comment": "Antivirus is not enabled or not installed."}
    set PC_013_001_result=N
)


:: [PC-013-002] 백신 업데이트 날짜 점검
set "av_sig_date="
set "av_sig_version="

if exist "%temp%\pc013_sig_script.ps1" del "%temp%\pc013_sig_script.ps1"
echo try { >> "%temp%\pc013_sig_script.ps1"
echo     $s = Get-MpComputerStatus -ErrorAction Stop >> "%temp%\pc013_sig_script.ps1"
echo     Write-Output "$($s.AntivirusSignatureLastUpdated.ToString('yyyy-MM-dd'))^|$($s.AntivirusSignatureVersion)" >> "%temp%\pc013_sig_script.ps1"
echo } catch { >> "%temp%\pc013_sig_script.ps1"
echo     Write-Output "Unknown^|Unknown" >> "%temp%\pc013_sig_script.ps1"
echo } >> "%temp%\pc013_sig_script.ps1"

powershell -NoProfile -ExecutionPolicy Bypass -File "%temp%\pc013_sig_script.ps1" > "%temp%\pc013_sig.txt"
del "%temp%\pc013_sig_script.ps1" 2>nul

set "av_sig_date=Unknown"
set "av_sig_version=Unknown"
set /p pc013_sig_raw=<"%temp%\pc013_sig.txt"
del "%temp%\pc013_sig.txt" 2>nul

for /f "tokens=1,2 delims=|" %%X in ("!pc013_sig_raw!") do (
    set "av_sig_date=%%X"
    set "av_sig_version=%%Y"
)

if "!av_sig_date!"=="Unknown" (
    set PC_013_002={"signature_date": "Unknown", "signature_version": "Unknown", "comment": "Unable to retrieve antivirus signature update date."}
    set PC_013_002_result=Verification
) else (
    set PC_013_002={"signature_date": "!av_sig_date!", "signature_version": "!av_sig_version!", "comment": "Antivirus signature information retrieved. Verify if update is recent enough."}
    set PC_013_002_result=Verification
)


:: 종합 평가 로직
set "PC_013_total_comment="
set "PC_013_total_result="

if "!PC_013_001_result!"=="N" (
    set "PC_013_total_result=N"
    set "PC_013_total_comment=CIIP_PC-013_WINDOWS_N_0"
) else if "!PC_013_001_result!"=="Y" (
    set "PC_013_total_result=Verification"
    set "PC_013_total_comment=CIIP_PC-013_WINDOWS_Verification_0"
) else (
    set "PC_013_total_result=Verification"
    set "PC_013_total_comment=CIIP_PC-013_WINDOWS_Verification_0"
)

echo Result=!PC_013_total_result!

:: 최종 JSON 출력
(
echo {
echo   "id": "PC-013",
echo   "total_result": "!PC_013_total_result!",
echo   "total_comment": "!PC_013_total_comment!",
echo   "response": [
echo     {
echo       "id": "PC-013-001",
echo       "data": [!PC_013_001!],
echo       "result": "!PC_013_001_result!"
echo     },
echo     {
echo       "id": "PC-013-002",
echo       "data": [!PC_013_002!],
echo       "result": "!PC_013_002_result!"
echo     }
echo   ]
echo }
) >> result.json
echo , >> result.json



echo #################           [PC-014] 바이러스 백신 프로그램에서 제공하는 실시간 감시 기능 활성화 (PC-14)          ################

:: [PC-014-001] 백신 실시간 보호 활성화 여부 점검
:: Windows Defender의 Get-MpComputerStatus -> RealTimeProtectionEnabled
set "rtp_enabled="

if exist "%temp%\pc014_rtp_script.ps1" del "%temp%\pc014_rtp_script.ps1"
echo try { >> "%temp%\pc014_rtp_script.ps1"
echo     $s = Get-MpComputerStatus -ErrorAction Stop >> "%temp%\pc014_rtp_script.ps1"
echo     Write-Output $s.RealTimeProtectionEnabled >> "%temp%\pc014_rtp_script.ps1"
echo } catch { >> "%temp%\pc014_rtp_script.ps1"
echo     Write-Output 'Error' >> "%temp%\pc014_rtp_script.ps1"
echo } >> "%temp%\pc014_rtp_script.ps1"

powershell -NoProfile -ExecutionPolicy Bypass -File "%temp%\pc014_rtp_script.ps1" > "%temp%\pc014_rtp.txt"
del "%temp%\pc014_rtp_script.ps1" 2>nul

set "rtp_enabled=Error"
set /p rtp_enabled=<"%temp%\pc014_rtp.txt"
del "%temp%\pc014_rtp.txt" 2>nul

if "!rtp_enabled!"=="True" (
    set PC_014_001={"real_time_protection": "Enabled", "comment": "Real-time protection is enabled."}
    set PC_014_result=Y
) else if "!rtp_enabled!"=="False" (
    set PC_014_001={"real_time_protection": "Disabled", "comment": "Real-time protection is disabled. This is vulnerable."}
    set PC_014_result=N
) else (
    set PC_014_001={"real_time_protection": "Unknown", "comment": "Unable to determine real-time protection status. A third-party antivirus may be managing protection."}
    set PC_014_result=Verification
)


:: 종합 평가 로직
set "PC_014_total_comment="
set "PC_014_total_result=!PC_014_result!"

if "!PC_014_result!"=="N" (
    set "PC_014_total_comment=CIIP_PC-014_WINDOWS_N_0"
) else if "!PC_014_result!"=="Y" (
    set "PC_014_total_comment=CIIP_PC-014_WINDOWS_Y_0"
) else (
    set "PC_014_total_comment=CIIP_PC-014_WINDOWS_Verification_0"
)

echo Result=!PC_014_total_result!

:: 최종 JSON 출력
(
echo {
echo   "id": "PC-014",
echo   "total_result": "!PC_014_total_result!",
echo   "total_comment": "!PC_014_total_comment!",
echo   "response": [
echo     {
echo       "id": "PC-014-001",
echo       "data": [!PC_014_001!],
echo       "result": "!PC_014_result!"
echo     }
echo   ]
echo }
) >> result.json
echo , >> result.json



echo #################           [PC-015] OS에서 제공하는 침입차단 기능 활성화 (PC-15)          ################

:: [PC-015-001] Windows 방화벽 프로필별 활성화 여부 점검
:: 도메인, 개인(Private), 공용(Public) 3개 프로필 모두 확인
set "fw_domain="
set "fw_private="
set "fw_public="
set "fw_result=Y"

:: 도메인 프로필
for /f "tokens=2" %%A in ('netsh advfirewall show domainprofile state 2^>nul ^| findstr /I "State"') do set "fw_domain=%%A"

:: 개인 프로필
for /f "tokens=2" %%A in ('netsh advfirewall show privateprofile state 2^>nul ^| findstr /I "State"') do set "fw_private=%%A"

:: 공용 프로필
for /f "tokens=2" %%A in ('netsh advfirewall show publicprofile state 2^>nul ^| findstr /I "State"') do set "fw_public=%%A"

:: 하나라도 OFF이면 취약
if /I "!fw_domain!"=="OFF" set "fw_result=N"
if /I "!fw_private!"=="OFF" set "fw_result=N"
if /I "!fw_public!"=="OFF" set "fw_result=N"

if not defined fw_domain if not defined fw_private if not defined fw_public (
    set "fw_result=N/A"
)

if "!fw_result!"=="Y" (
    set PC_015_001={"domain_profile": "!fw_domain!", "private_profile": "!fw_private!", "public_profile": "!fw_public!", "comment": "All firewall profiles are enabled."}
) else if "!fw_result!"=="N" (
    set PC_015_001={"domain_profile": "!fw_domain!", "private_profile": "!fw_private!", "public_profile": "!fw_public!", "comment": "One or more firewall profiles are disabled."}
) else (
    set PC_015_001={"domain_profile": "Unknown", "private_profile": "Unknown", "public_profile": "Unknown", "comment": "Unable to determine firewall status."}
)


:: 종합 평가 로직
set "PC_015_total_comment="
set "PC_015_total_result=!fw_result!"

if "!fw_result!"=="N" (
    set "PC_015_total_comment=CIIP_PC-015_WINDOWS_N_0"
) else if "!fw_result!"=="Y" (
    set "PC_015_total_comment=CIIP_PC-015_WINDOWS_Y_0"
) else (
    set "PC_015_total_comment=CIIP_PC-015_WINDOWS_N/A_0"
)

echo Result=!PC_015_total_result!

:: 최종 JSON 출력
(
echo {
echo   "id": "PC-015",
echo   "total_result": "!PC_015_total_result!",
echo   "total_comment": "!PC_015_total_comment!",
echo   "response": [
echo     {
echo       "id": "PC-015-001",
echo       "data": [!PC_015_001!],
echo       "result": "!fw_result!"
echo     }
echo   ]
echo }
) >> result.json
echo , >> result.json



echo #################           [PC-016] 화면보호기 대기 시간 설정 및 재시작 시 암호 보호 설정 (PC-16)          ################

:: [PC-016-001] 화면보호기 설정 점검
:: 레지스트리: HKCU\Control Panel\Desktop
:: ScreenSaveActive = 1 (활성화)
:: ScreenSaverIsSecure = 1 (암호 보호)
:: ScreenSaveTimeOut <= 600 (10분 이하, 초 단위)
set "scr_active="
set "scr_secure="
set "scr_timeout="
set "pc016_result=Y"

for /f "tokens=3" %%A in ('reg query "HKEY_CURRENT_USER\Control Panel\Desktop" /v ScreenSaveActive 2^>nul') do set "scr_active=%%A"
for /f "tokens=3" %%A in ('reg query "HKEY_CURRENT_USER\Control Panel\Desktop" /v ScreenSaverIsSecure 2^>nul') do set "scr_secure=%%A"
for /f "tokens=3" %%A in ('reg query "HKEY_CURRENT_USER\Control Panel\Desktop" /v ScreenSaveTimeOut 2^>nul') do set "scr_timeout=%%A"

:: 판정 로직
if not "!scr_active!"=="1" set "pc016_result=N"
if not "!scr_secure!"=="1" set "pc016_result=N"

if "!scr_timeout!"=="" (
    set "pc016_result=N"
) else (
    set /a timeout_val=!scr_timeout!
    if !timeout_val! GTR 600 set "pc016_result=N"
    if !timeout_val! EQU 0 set "pc016_result=N"
)

:: 가독성 향상 (빈 값 처리)
if "!scr_active!"=="" set "scr_active=Not Configured"
if "!scr_secure!"=="" set "scr_secure=Not Configured"
if "!scr_timeout!"=="" set "scr_timeout=Not Configured"

if "!pc016_result!"=="Y" (
    set PC_016_001={"screen_saver_active": "!scr_active!", "password_protected": "!scr_secure!", "timeout_sec": "!scr_timeout!", "comment": "Screen saver is enabled with password protection and timeout within 10 minutes."}
) else (
    set PC_016_001={"screen_saver_active": "!scr_active!", "password_protected": "!scr_secure!", "timeout_sec": "!scr_timeout!", "comment": "Screen saver settings do not meet security requirements."}
)


:: 종합 평가 로직
set "PC_016_total_comment="
set "PC_016_total_result=!pc016_result!"

if "!pc016_result!"=="N" (
    set "PC_016_total_comment=CIIP_PC-016_WINDOWS_N_0"
) else (
    set "PC_016_total_comment=CIIP_PC-016_WINDOWS_Y_0"
)

echo Result=!PC_016_total_result!


:: 최종 JSON 출력
(
echo {
echo   "id": "PC-016",
echo   "total_result": "!PC_016_total_result!",
echo   "total_comment": "!PC_016_total_comment!",
echo   "response": [
echo     {
echo       "id": "PC-016-001",
echo       "data": [!PC_016_001!],
echo       "result": "!pc016_result!"
echo     }
echo   ]
echo }
) >> result.json
echo , >> result.json



echo #################           [PC-017] CD, DVD, USB 메모리 등과 같은 미디어의 자동 실행 방지 등 이동식 미디어에 대한 보안대책 수립 (PC-17)          ################

:: [PC-017-001] 그룹 정책 - 자동 실행 끄기 설정 점검
:: 레지스트리: HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer -> NoDriveTypeAutoRun
:: 양호 기준: 값이 0xFF (255, 모든 드라이브 자동 실행 차단) 인 경우
set "no_autorun_gpo="
set "reg_path_pc017_gpo=HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"

for /f "tokens=3" %%A in ('reg query "%reg_path_pc017_gpo%" /v NoDriveTypeAutoRun 2^>nul') do (
    set "no_autorun_gpo=%%A"
)

if not defined no_autorun_gpo (
    set PC_017_001={"NoDriveTypeAutoRun": "Not Configured", "comment": "Group Policy for disabling AutoRun is not configured."}
    set PC_017_001_result=N
) else (
    set /a autorun_dec=!no_autorun_gpo!
    if !autorun_dec! GEQ 255 (
        set PC_017_001={"NoDriveTypeAutoRun": "!no_autorun_gpo! (All drives disabled)", "comment": "AutoRun is disabled for all drive types via Group Policy."}
        set PC_017_001_result=Y
    ) else if !autorun_dec! GEQ 181 (
        set PC_017_001={"NoDriveTypeAutoRun": "!no_autorun_gpo!", "comment": "AutoRun is partially disabled via Group Policy."}
        set PC_017_001_result=Verification
    ) else (
        set PC_017_001={"NoDriveTypeAutoRun": "!no_autorun_gpo!", "comment": "AutoRun is not sufficiently restricted via Group Policy."}
        set PC_017_001_result=N
    )
)


:: [PC-017-002] 사용자 설정 - AutoPlay 비활성화 점검
:: 레지스트리: HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers -> DisableAutoplay
:: 양호 기준: 값이 1 (자동 실행 비활성화)
set "disable_autoplay="
set "reg_path_pc017_user=HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers"

for /f "tokens=3" %%A in ('reg query "%reg_path_pc017_user%" /v DisableAutoplay 2^>nul') do (
    set "disable_autoplay=%%A"
)

if not defined disable_autoplay (
    set PC_017_002={"DisableAutoplay": "Not Configured", "comment": "AutoPlay user setting is not configured."}
    set PC_017_002_result=N
) else if "!disable_autoplay!"=="0x1" (
    set PC_017_002={"DisableAutoplay": "1 (Disabled)", "comment": "AutoPlay is disabled in user settings."}
    set PC_017_002_result=Y
) else if "!disable_autoplay!"=="1" (
    set PC_017_002={"DisableAutoplay": "1 (Disabled)", "comment": "AutoPlay is disabled in user settings."}
    set PC_017_002_result=Y
) else (
    set PC_017_002={"DisableAutoplay": "!disable_autoplay! (Enabled)", "comment": "AutoPlay is enabled in user settings."}
    set PC_017_002_result=N
)


:: 종합 평가 로직 (둘 중 하나라도 Y이면 양호)
set "PC_017_total_comment="
set "PC_017_total_result="

if "!PC_017_001_result!"=="Y" (
    set "PC_017_total_result=Y"
    set "PC_017_total_comment=CIIP_PC-017_WINDOWS_Y_0"
    goto :PC017_JSON
)
if "!PC_017_002_result!"=="Y" (
    set "PC_017_total_result=Y"
    set "PC_017_total_comment=CIIP_PC-017_WINDOWS_Y_0"
    goto :PC017_JSON
)

set "PC_017_total_result=N"
set "PC_017_total_comment=CIIP_PC-017_WINDOWS_N_0"

:PC017_JSON

echo Result=!PC_017_total_result!

:: 최종 JSON 출력
(
echo {
echo   "id": "PC-017",
echo   "total_result": "!PC_017_total_result!",
echo   "total_comment": "!PC_017_total_comment!",
echo   "response": [
echo     {
echo       "id": "PC-017-001",
echo       "data": [!PC_017_001!],
echo       "result": "!PC_017_001_result!"
echo     },
echo     {
echo       "id": "PC-017-002",
echo       "data": [!PC_017_002!],
echo       "result": "!PC_017_002_result!"
echo     }
echo   ]
echo }
) >> result.json
echo , >> result.json

echo #################           [PC-018] 원격 지원을 금지하도록 정책 설정 점검 (PC-18)          ################

:: [PC-018-001] 원격 지원 비활성화 여부 점검
:: 레지스트리: HKLM\SYSTEM\CurrentControlSet\Control\Remote Assistance -> fAllowToGetHelp
:: 양호 기준: 값이 0 (사용 안 함)
set "allow_help="
set "reg_path_pc018=HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Remote Assistance"

for /f "tokens=3" %%A in ('reg query "%reg_path_pc018%" /v fAllowToGetHelp 2^>nul') do (
    set "allow_help=%%A"
)

if not defined allow_help (
    set PC_018_001={"fAllowToGetHelp": "Not Configured", "comment": "Remote Assistance setting not found. Verify manually."}
    set PC_018_result=Verification
) else if "!allow_help!"=="0x0" (
    set PC_018_001={"fAllowToGetHelp": "0 (Disabled)", "comment": "Remote Assistance is disabled."}
    set PC_018_result=Y
) else if "!allow_help!"=="0" (
    set PC_018_001={"fAllowToGetHelp": "0 (Disabled)", "comment": "Remote Assistance is disabled."}
    set PC_018_result=Y
) else (
    set PC_018_001={"fAllowToGetHelp": "1 (Enabled)", "comment": "Remote Assistance is enabled. This is vulnerable."}
    set PC_018_result=N
)


:: 종합 평가 로직
set "PC_018_total_comment="
set "PC_018_total_result=!PC_018_result!"

if "!PC_018_result!"=="N" (
    set "PC_018_total_comment=CIIP_PC-018_WINDOWS_N_0"
) else if "!PC_018_result!"=="Y" (
    set "PC_018_total_comment=CIIP_PC-018_WINDOWS_Y_0"
) else (
    set "PC_018_total_comment=CIIP_PC-018_WINDOWS_Verification_0"
)

echo Result=!PC_018_total_result!


:: 최종 JSON 출력
(
echo {
echo   "id": "PC-018",
echo   "total_result": "!PC_018_total_result!",
echo   "total_comment": "!PC_018_total_comment!",
echo   "response": [
echo     {
echo       "id": "PC-018-001",
echo       "data": [!PC_018_001!],
echo       "result": "!PC_018_result!"
echo     }
echo   ]
echo }
) >> result.json
echo ] >> result.json

:: PowerShell로 파일 이름 변경 (한글 포함 경로/파일명 지원) 및 JSON 전송
:: PC-001~PC-018 18개 항목 완전성 검증 후 전송
if exist "%temp%\pc_finalize.ps1" del "%temp%\pc_finalize.ps1"
echo $hostname = $env:COMPUTERNAME >> "%temp%\pc_finalize.ps1"
echo $ip = ^(Get-NetIPConfiguration ^| Where-Object { $_.IPv4DefaultGateway -ne $null } ^| Select-Object -First 1^).IPv4Address.IPAddress >> "%temp%\pc_finalize.ps1"
echo if ^(-not $ip^) { $ip = ^(Get-NetIPAddress -AddressFamily IPv4 ^| Where-Object { $_.IPAddress -ne '127.0.0.1' } ^| Select-Object -First 1^).IPAddress } >> "%temp%\pc_finalize.ps1"
echo if ^(-not $ip^) { $ip = 'UnknownIP' } >> "%temp%\pc_finalize.ps1"
echo $dst = "${hostname}_${ip}_result.json" >> "%temp%\pc_finalize.ps1"
echo if ^(Test-Path $dst^) { Remove-Item $dst -Force } >> "%temp%\pc_finalize.ps1"
echo Rename-Item -Path 'result.json' -NewName $dst >> "%temp%\pc_finalize.ps1"
echo $jsonContent = [System.IO.File]::ReadAllText^($dst, [System.Text.Encoding]::UTF8^) >> "%temp%\pc_finalize.ps1"
echo $missing = @^(^) >> "%temp%\pc_finalize.ps1"
echo for ^($i = 1; $i -le 18; $i++^) { >> "%temp%\pc_finalize.ps1"
echo     $id = 'PC-{0:D3}' -f $i >> "%temp%\pc_finalize.ps1"
echo     $pattern = [char]34 + 'id' + [char]34 + ': ' + [char]34 + $id + [char]34 >> "%temp%\pc_finalize.ps1"
echo     if ^($jsonContent.IndexOf^($pattern^) -lt 0^) { $missing += $id } >> "%temp%\pc_finalize.ps1"
echo } >> "%temp%\pc_finalize.ps1"
echo if ^($missing.Count -gt 0^) { >> "%temp%\pc_finalize.ps1"
echo     Write-Host ^('INCOMPLETE: Missing ' + ^($missing -join ', '^) + '. Not sending.'^) >> "%temp%\pc_finalize.ps1"
echo } else { >> "%temp%\pc_finalize.ps1"
echo     $serverUrl = 'http://10.140.124.207:8080/result?host=' + $hostname + '^&ip=' + $ip >> "%temp%\pc_finalize.ps1"
echo     try { >> "%temp%\pc_finalize.ps1"
echo         $bytes = [System.Text.Encoding]::UTF8.GetBytes^($jsonContent^) >> "%temp%\pc_finalize.ps1"
echo         $response = Invoke-WebRequest -Uri $serverUrl -Method POST -Body $bytes -ContentType 'application/json; charset=utf-8' -UseBasicParsing -TimeoutSec 30 >> "%temp%\pc_finalize.ps1"
echo         Write-Host ^('Sent OK: HTTP ' + $response.StatusCode^) >> "%temp%\pc_finalize.ps1"
echo     } catch { >> "%temp%\pc_finalize.ps1"
echo         Write-Host ^('Failed to send: ' + $_.Exception.Message^) >> "%temp%\pc_finalize.ps1"
echo     } >> "%temp%\pc_finalize.ps1"
echo } >> "%temp%\pc_finalize.ps1"

powershell -NoProfile -ExecutionPolicy Bypass -File "%temp%\pc_finalize.ps1"
del "%temp%\pc_finalize.ps1" 2>nul

if exist "%cloudraw%" (
    rmdir /s /q "%cloudraw%"
)

endlocal