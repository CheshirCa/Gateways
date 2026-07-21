EnableExplicit

#AppName    = "Gateway Monitor"
#AppVersion = "3.1"
#AppTitle   = #AppName + " " + #AppVersion

#WindowMain = 1
#TrayIcon   = 1
#TrayImage  = 1
#PopupMenu  = 1
#TimerCheck = 1

#MenuOpenLog      = 8997
#MenuReloadConfig = 8998
#MenuExit         = 9000
#MenuGatewayBase  = 1000
#MenuAppInfo      = 999

#ERROR_ALREADY_EXISTS = 183
#LOG_ROTATE_SIZE = 5242880 ; 5 MB
#MAX_GATEWAYS = 128

#GatewayStateUnknown  = -1
#GatewayStateFail     = 0
#GatewayStateOk       = 1

Structure Gateway
  name.s
  host.s
  port.i
  enabled.i
  state.i          ; #GatewayStateUnknown, #GatewayStateFail или #GatewayStateOk
  failStreak.i
  okStreak.i       ; сколько подряд успешных проверок (для симметричного анти-флаппинга)
  lastCheck.s
  alertDown.s
  alertUp.s
EndStructure

; Полностью отдельный снимок данных для фонового потока. Главный поток не
; обращается к этому списку, пока проверка выполняется, а фоновый поток никогда
; не обращается к Gateways(). Так курсор списка PureBasic не разделяется между
; потоками.
Structure CheckItem
  gatewayIndex.i
  host.s
  port.i
  tcpOk.i
  checkedAt.s
EndStructure

Global NewList Gateways.Gateway()
Global NewList CheckItems.CheckItem()

Global CheckIntervalSec.i = 10
Global FailCountLimit.i = 3
Global RecoverCountLimit.i = 1   ; сколько подряд успешных проверок нужно для перехода FAIL -> OK
Global ConfigFile.s
Global ConfigError.s

Global LogEnabled.i = 0
Global LogFile.s = "gateways.log"

Global AppMutex.i     ; WinAPI-мьютекс, защита от второй копии приложения
Global CheckThreadID.i = 0
Global CheckGeneration.i = 0
Global CurrentCheckLogChanges.i = #True
Global CurrentCheckNotify.i = #True
Global ReloadPending.i = #False

Declare StartChecks(logChanges.i = #True, notify.i = #True)
Declare CheckAllGatewaysThread(dummy.i)
Declare ApplyCheckResults(logChanges.i = #True, notify.i = #True)
Declare FinishReloadConfig()
Declare CompleteFinishedCheck()
Declare UpdateTrayIcon()

Procedure.s NowText()
  ProcedureReturn FormatDate("%hh:%ii:%ss", Date())
EndProcedure

Procedure.s NowDateTime()
  ProcedureReturn FormatDate("%dd.%mm.%yyyy %hh:%ii:%ss", Date())
EndProcedure

Procedure.s Quote(text.s)
  ProcedureReturn Chr(34) + text + Chr(34)
EndProcedure

Procedure RotateLogIfNeeded()
  Protected size.q
  Protected rotatedName.s
  
  If LogEnabled = 0
    ProcedureReturn
  EndIf
  
  size = FileSize(LogFile)
  
  If size >= #LOG_ROTATE_SIZE
    rotatedName = LogFile + "." + FormatDate("%yyyy%mm%dd-%hh%ii%ss", Date()) + ".old"
    
    If Not RenameFile(LogFile, rotatedName)
      ; Переименовать не удалось (например, файл занят другим процессом) —
      ; молча продолжаем писать в текущий файл, ротацию попробуем в следующий раз.
    EndIf
  EndIf
EndProcedure

Procedure WriteLog(text.s)
  Protected f.i
  
  If LogEnabled = 0
    ProcedureReturn
  EndIf
  
  RotateLogIfNeeded()
  
  f = OpenFile(#PB_Any, LogFile)
  If f
    FileSeek(f, Lof(f))
    WriteStringN(f, NowDateTime() + "  " + text, #PB_UTF8)
    CloseFile(f)
  EndIf
EndProcedure

Procedure OpenLogFile()
  Protected f.i
  
  If LogFile = ""
    ProcedureReturn
  EndIf
  
  If FileSize(LogFile) = -1
    f = CreateFile(#PB_Any, LogFile)
    If f
      CloseFile(f)
    EndIf
  EndIf
  
  ; Сначала пробуем открыть файл через ассоциированное в системе приложение,
  ; и только если это не удалось - принудительно через notepad.exe.
  If Not RunProgram(LogFile)
    RunProgram("notepad.exe", Quote(LogFile), "")
  EndIf
EndProcedure

Structure NOTIFYICONDATA_BALLOON
  cbSize.l
  hWnd.i
  uID.l
  uFlags.l
  uCallbackMessage.l
  hIcon.i
  szTip.w[128]
  dwState.l
  dwStateMask.l
  szInfo.w[256]
  StructureUnion
    uTimeout.l
    uVersion.l
  EndStructureUnion
  szInfoTitle.w[64]
  dwInfoFlags.l
EndStructure

Procedure ShowTrayBalloon(title.s, text.s, warning.i = #True)
  Protected nid.NOTIFYICONDATA_BALLOON
  
  nid\cbSize = SizeOf(NOTIFYICONDATA_BALLOON)
  nid\hWnd = WindowID(#WindowMain)
  nid\uID = #TrayIcon
  nid\uFlags = #NIF_INFO
  nid\uTimeout = 5000
  
  PokeS(@nid\szInfoTitle, title, 63, #PB_Unicode)
  PokeS(@nid\szInfo, text, 255, #PB_Unicode)
  
  If warning
    nid\dwInfoFlags = #NIIF_WARNING
  Else
    nid\dwInfoFlags = #NIIF_INFO
  EndIf
  
  Shell_NotifyIcon_(#NIM_MODIFY, @nid)
EndProcedure

Procedure.i CreateSampleConfig(file.s)
  Protected f.i
  
  f = CreateFile(#PB_Any, file, #PB_UTF8)
  If f = 0
    ProcedureReturn #False
  EndIf
  
  WriteStringN(f, "[Settings]")
  WriteStringN(f, "interval_sec=10")
  WriteStringN(f, "fail_count=3")
  WriteStringN(f, "recover_count=1")
  WriteStringN(f, "log_enabled=1")
  WriteStringN(f, "log_file=gateways.log")
  WriteStringN(f, "")
  WriteStringN(f, "[VPN-Server-1]")
  WriteStringN(f, "host=10.10.10.1")
  WriteStringN(f, "port=8291")
  WriteStringN(f, "enabled=1")
  WriteStringN(f, "alert_down=Упал основной VPN")
  WriteStringN(f, "alert_up=Основной VPN восстановлен")
  WriteStringN(f, "")
  WriteStringN(f, "[VPN-Server-2]")
  WriteStringN(f, "host=10.20.20.1")
  WriteStringN(f, "port=8291")
  WriteStringN(f, "enabled=1")
  WriteStringN(f, "")
  WriteStringN(f, "[Office-Network]")
  WriteStringN(f, "host=192.168.50.1")
  WriteStringN(f, "port=8291")
  WriteStringN(f, "enabled=1")
  CloseFile(f)
  
  ProcedureReturn #True
EndProcedure

Procedure.i IsAbsoluteWindowsPath(path.s)
  If Len(path) >= 3 And Mid(path, 2, 1) = ":" And (Mid(path, 3, 1) = "\" Or Mid(path, 3, 1) = "/")
    ProcedureReturn #True
  EndIf
  
  If Left(path, 2) = "\\"
    ProcedureReturn #True
  EndIf
  
  ProcedureReturn #False
EndProcedure

; Конфигурация сначала полностью читается во временный список. Действующие
; настройки заменяются только после успешного чтения и проверки всех полей.
Procedure.i LoadConfig(configPath.s = "")
  Protected NewList loaded.Gateway()
  Protected count.i, group.s
  Protected interval.i, failLimit.i, recoverLimit.i, logOn.i, enabledValue.i
  Protected logPath.s, appDirectory.s
  
  ConfigError = ""
  If configPath = ""
    ConfigFile = GetPathPart(ProgramFilename()) + "gateways.ini"
  Else
    ConfigFile = configPath
  EndIf
  appDirectory = GetPathPart(ProgramFilename())
  
  If FileSize(ConfigFile) = -1
    If Not CreateSampleConfig(ConfigFile)
      ConfigError = "Не удалось создать " + ConfigFile
      ProcedureReturn #False
    EndIf
  EndIf
  
  If Not OpenPreferences(ConfigFile, 0, #PB_UTF8)
    ConfigError = "Не удалось открыть " + ConfigFile
    ProcedureReturn #False
  EndIf
  
  PreferenceGroup("Settings")
  interval     = ReadPreferenceInteger("interval_sec", 10)
  failLimit    = ReadPreferenceInteger("fail_count", 3)
  recoverLimit = ReadPreferenceInteger("recover_count", 1)
  logOn        = ReadPreferenceInteger("log_enabled", 0)
  logPath      = Trim(ReadPreferenceString("log_file", "gateways.log"))
  
  If interval < 1 Or interval > 86400
    ConfigError = "interval_sec должен быть в диапазоне 1..86400"
  ElseIf failLimit < 1 Or failLimit > 1000
    ConfigError = "fail_count должен быть в диапазоне 1..1000"
  ElseIf recoverLimit < 1 Or recoverLimit > 1000
    ConfigError = "recover_count должен быть в диапазоне 1..1000"
  ElseIf logOn <> 0 And logOn <> 1
    ConfigError = "log_enabled должен быть равен 0 или 1"
  ElseIf logPath = ""
    ConfigError = "log_file не должен быть пустым"
  EndIf
  
  If ConfigError = ""
    If ExaminePreferenceGroups()
      While NextPreferenceGroup()
        group = Trim(PreferenceGroupName())
        
        ; Settings содержит глобальные параметры. Все остальные секции
        ; являются шлюзами, а имя секции используется как имя шлюза.
        If LCase(group) <> "settings"
          If LCase(group) = "gateways"
            ConfigError = "Обнаружен старый формат INI. Удалите секцию [Gateways] и используйте названия шлюзов как имена секций."
            Break
          EndIf
          
          count + 1
          If count > #MAX_GATEWAYS
            ConfigError = "Количество шлюзов не должно превышать " + Str(#MAX_GATEWAYS)
            Break
          EndIf
          
          AddElement(loaded())
          loaded()\name = group
          loaded()\host = Trim(ReadPreferenceString("host", ""))
          loaded()\port = ReadPreferenceInteger("port", 8291)
          enabledValue = ReadPreferenceInteger("enabled", 1)
          loaded()\enabled = Bool(enabledValue)
          loaded()\state = #GatewayStateUnknown
          loaded()\failStreak = 0
          loaded()\okStreak = 0
          loaded()\lastCheck = "-"
          loaded()\alertDown = ReadPreferenceString("alert_down", "")
          loaded()\alertUp = ReadPreferenceString("alert_up", "")
          
          If loaded()\name = ""
            ConfigError = "Имя секции шлюза не должно быть пустым"
            Break
          ElseIf enabledValue <> 0 And enabledValue <> 1
            ConfigError = group + ": enabled должен быть равен 0 или 1"
            Break
          ElseIf loaded()\enabled And loaded()\host = ""
            ConfigError = group + ": для включённого шлюза требуется host"
            Break
          ElseIf loaded()\enabled And (loaded()\port < 1 Or loaded()\port > 65535)
            ConfigError = group + ": port должен быть в диапазоне 1..65535"
            Break
          EndIf
        EndIf
      Wend
    Else
      ConfigError = "Не удалось прочитать секции конфигурации"
    EndIf
  EndIf
  
  ClosePreferences()
  
  If ConfigError <> ""
    ProcedureReturn #False
  EndIf
  
  If Not IsAbsoluteWindowsPath(logPath)
    logPath = appDirectory + logPath
  EndIf
  
  CopyList(loaded(), Gateways())
  CheckIntervalSec = interval
  FailCountLimit = failLimit
  RecoverCountLimit = recoverLimit
  LogEnabled = Bool(logOn)
  LogFile = logPath
  
  ProcedureReturn #True
EndProcedure

Procedure FinishReloadConfig()
  Protected loaded.i
  
  ReloadPending = #False
  loaded = LoadConfig()
  
  If loaded
    AddWindowTimer(#WindowMain, #TimerCheck, CheckIntervalSec * 1000)
    WriteLog("CONFIG RELOADED")
    StartChecks(#False, #False)
    UpdateTrayIcon()
  Else
    AddWindowTimer(#WindowMain, #TimerCheck, CheckIntervalSec * 1000)
    WriteLog("CONFIG ERROR  " + ConfigError)
    ShowTrayBalloon("Ошибка конфигурации", ConfigError, #True)
  EndIf
EndProcedure

Procedure ReloadConfig()
  RemoveWindowTimer(#WindowMain, #TimerCheck)
  ReloadPending = #True
  
  ; Не блокируем UI ожиданием сетевого таймаута. Если проверка уже идёт,
  ; перезагрузка продолжится после её штатного завершения.
  If CheckThreadID = 0
    FinishReloadConfig()
  ElseIf Not IsThread(CheckThreadID)
    CompleteFinishedCheck()
  EndIf
EndProcedure

Procedure.i CheckTcp(host.s, port.i, timeoutMs.i = 1500)
  Protected conn.i
  
  conn = OpenNetworkConnection(host, port, #PB_Network_TCP, timeoutMs)
  
  If conn
    CloseNetworkConnection(conn)
    ProcedureReturn #True
  EndIf
  
  ProcedureReturn #False
EndProcedure

; Чистая логика анти-флаппинга вынесена отдельно, чтобы её можно было покрыть
; автоматическими тестами без запуска окна и реальных сетевых соединений.
Procedure ApplyProbeResult(*gateway.Gateway, tcpOk.i)
  If tcpOk
    *gateway\failStreak = 0
    *gateway\okStreak + 1
    If *gateway\okStreak >= RecoverCountLimit
      *gateway\state = #GatewayStateOk
    EndIf
  Else
    *gateway\okStreak = 0
    *gateway\failStreak + 1
    If *gateway\failStreak >= FailCountLimit
      *gateway\state = #GatewayStateFail
    EndIf
  EndIf
EndProcedure

; Создаёт неизменяемый для главного потока снимок включённых шлюзов и
; запускает проверку. Gateways() после этого остаётся исключительно у UI.
Procedure.i StartChecks(logChanges.i = #True, notify.i = #True)
  Protected gatewayIndex.i
  
  If CheckThreadID
    ProcedureReturn #False
  EndIf
  
  ClearList(CheckItems())
  gatewayIndex = 0
  ForEach Gateways()
    If Gateways()\enabled And Gateways()\host <> ""
      AddElement(CheckItems())
      CheckItems()\gatewayIndex = gatewayIndex
      CheckItems()\host = Gateways()\host
      CheckItems()\port = Gateways()\port
    EndIf
    gatewayIndex + 1
  Next
  
  If ListSize(CheckItems()) = 0
    CheckThreadID = 0
    ProcedureReturn #False
  EndIf
  
  CurrentCheckLogChanges = logChanges
  CurrentCheckNotify = notify
  CheckGeneration + 1
  CheckThreadID = CreateThread(@CheckAllGatewaysThread(), CheckGeneration)
  
  If CheckThreadID = 0
    ClearList(CheckItems())
    WriteLog("ERROR  Не удалось запустить поток проверки")
    ProcedureReturn #False
  EndIf
  
  ProcedureReturn #True
EndProcedure

; Фоновый поток работает только со своим списком CheckItems(). Никаких UI,
; логов, Gateways() или WinAPI здесь нет.
Procedure CheckAllGatewaysThread(dummy.i)
  ForEach CheckItems()
    CheckItems()\tcpOk = CheckTcp(CheckItems()\host, CheckItems()\port)
    CheckItems()\checkedAt = NowText()
  Next
  
  PostEvent(#PB_Event_FirstCustomValue, #WindowMain, dummy)
EndProcedure

; Применение результатов и все побочные эффекты выполняются главным потоком.
Procedure ApplyCheckResults(logChanges.i = #True, notify.i = #True)
  Protected oldState.i, newState.i
  Protected eventTime.s, eventText.s
  
  ForEach CheckItems()
    If SelectElement(Gateways(), CheckItems()\gatewayIndex)
      oldState = Gateways()\state
      ApplyProbeResult(@Gateways(), CheckItems()\tcpOk)
      newState = Gateways()\state
      Gateways()\lastCheck = CheckItems()\checkedAt
      
      ; UNKNOWN -> OK/FAIL устанавливает исходное состояние, но не считается
      ; восстановлением или аварией и потому не создаёт ложное событие.
      If oldState <> #GatewayStateUnknown And newState <> oldState
        eventTime = NowDateTime()
        
        If newState = #GatewayStateFail
          If logChanges
            WriteLog("FAIL  " + Gateways()\name + "  " + Gateways()\host + ":" + Str(Gateways()\port))
          EndIf
          
          If notify And Trim(Gateways()\alertDown) <> ""
            eventText = "FAIL: " + Gateways()\name + #CRLF$ +
                        "Host: " + Gateways()\host + ":" + Str(Gateways()\port) + #CRLF$ +
                        "Время: " + eventTime
            ShowTrayBalloon(Gateways()\alertDown, eventText, #True)
          EndIf
        Else
          If logChanges
            WriteLog("OK    " + Gateways()\name + "  " + Gateways()\host + ":" + Str(Gateways()\port))
          EndIf
          
          If notify And Trim(Gateways()\alertUp) <> ""
            eventText = "OK: " + Gateways()\name + #CRLF$ +
                        "Host: " + Gateways()\host + ":" + Str(Gateways()\port) + #CRLF$ +
                        "Время: " + eventTime
            ShowTrayBalloon(Gateways()\alertUp, eventText, #False)
          EndIf
        EndIf
      EndIf
    EndIf
  Next
  
  ClearList(CheckItems())
EndProcedure

Procedure DrawSector(cx.i, cy.i, radius.i, startAngle.d, endAngle.d, color.i)
  Protected angle.d
  Protected stepDeg.d = 0.5
  Protected x.i, y.i
  
  FrontColor(color)
  
  ; Идём с фиксированным шагом от startAngle до endAngle без округления
  ; границ до целых градусов - иначе при total, не делящем 360 нацело,
  ; между соседними секторами накапливались щели/наплывы.
  angle = startAngle
  While angle < endAngle
    x = cx + Cos((angle - 90.0) * #PI / 180.0) * radius
    y = cy + Sin((angle - 90.0) * #PI / 180.0) * radius
    LineXY(cx, cy, x, y)
    angle + stepDeg
  Wend
  
  ; Луч точно по конечной границе сектора - чтобы соседние сектора
  ; смыкались без зазора независимо от шага stepDeg.
  x = cx + Cos((endAngle - 90.0) * #PI / 180.0) * radius
  y = cy + Sin((endAngle - 90.0) * #PI / 180.0) * radius
  LineXY(cx, cy, x, y)
EndProcedure

Procedure UpdateTrayIcon()
  Protected activeCount.i, index.i
  Protected startAngle.d, endAngle.d, sectorSize.d
  Protected okColor.i, failColor.i, unknownColor.i, borderColor.i
  Protected hasFail.i, hasUnknown.i
  Protected tooltip.s
  
  okColor = RGBA(0, 180, 0, 255)
  failColor = RGBA(220, 0, 0, 255)
  unknownColor = RGBA(140, 140, 140, 255)
  borderColor = RGBA(40, 40, 40, 255)
  
  ForEach Gateways()
    If Gateways()\enabled
      activeCount + 1
    EndIf
  Next
  
  If IsImage(#TrayImage)
    FreeImage(#TrayImage)
  EndIf
  
  CreateImage(#TrayImage, 32, 32, 32, #PB_Image_Transparent)
  
  If StartDrawing(ImageOutput(#TrayImage))
    DrawingMode(#PB_2DDrawing_AlphaBlend)
    Box(0, 0, 32, 32, RGBA(0, 0, 0, 0))
    
    If activeCount = 0
      DrawSector(16, 16, 14, 0.0, 360.0, unknownColor)
    Else
      sectorSize = 360.0 / activeCount
    EndIf
    index = 0
    
    ForEach Gateways()
      If Gateways()\enabled
        startAngle = index * sectorSize
        endAngle = startAngle + sectorSize
        
        Select Gateways()\state
          Case #GatewayStateOk
            DrawSector(16, 16, 14, startAngle, endAngle, okColor)
          Case #GatewayStateFail
            hasFail = #True
            DrawSector(16, 16, 14, startAngle, endAngle, failColor)
          Default
            hasUnknown = #True
            DrawSector(16, 16, 14, startAngle, endAngle, unknownColor)
        EndSelect
        
        index + 1
      EndIf
    Next
    
    DrawingMode(#PB_2DDrawing_Outlined | #PB_2DDrawing_AlphaBlend)
    Circle(16, 16, 14, borderColor)
    
    StopDrawing()
  EndIf
  
  ChangeSysTrayIcon(#TrayIcon, ImageID(#TrayImage))
  
  If activeCount = 0
    tooltip = #AppTitle + ": NO ACTIVE GATEWAYS"
  ElseIf hasFail
    tooltip = #AppTitle + ": FAIL"
  ElseIf hasUnknown
    tooltip = #AppTitle + ": CHECKING"
  Else
    tooltip = #AppTitle + ": OK"
  EndIf
  
  SysTrayIconToolTip(#TrayIcon, tooltip)
EndProcedure

Procedure RebuildPopupMenu()
  Protected id.i, status.s, bullet.s
  
  If IsMenu(#PopupMenu)
    FreeMenu(#PopupMenu)
  EndIf
  
  CreatePopupMenu(#PopupMenu)
  MenuItem(#MenuAppInfo, #AppTitle)
  DisableMenuItem(#PopupMenu, #MenuAppInfo, #True)
  MenuBar()
  
  id = #MenuGatewayBase
  
  ForEach Gateways()
    If Not Gateways()\enabled
      bullet = "○"
      status = "DISABLED"
    Else
      Select Gateways()\state
        Case #GatewayStateOk
          bullet = "✓"
          status = "OK"
        Case #GatewayStateFail
          bullet = "✖"
          status = "FAIL"
        Default
          bullet = "…"
          status = "CHECKING"
      EndSelect
    EndIf
    
    MenuItem(id, bullet + " " + Gateways()\name + " — " + status + " — " + Gateways()\lastCheck)
    DisableMenuItem(#PopupMenu, id, #True)
    
    id + 1
  Next
  
  MenuBar()
  MenuItem(#MenuOpenLog, "Открыть лог")
  MenuItem(#MenuReloadConfig, "Перечитать конфиг")
  MenuBar()
  MenuItem(#MenuExit, "Выход")
EndProcedure

Procedure CompleteFinishedCheck()
  If CheckThreadID = 0
    ProcedureReturn
  EndIf
  
  ; Событие посылается в самом конце потока, поэтому ожидание здесь обычно
  ; мгновенное. Оно гарантирует, что CheckItems() больше никто не изменяет.
  WaitThread(CheckThreadID)
  CheckThreadID = 0
  
  If ReloadPending
    ClearList(CheckItems())
    FinishReloadConfig()
  Else
    ApplyCheckResults(CurrentCheckLogChanges, CurrentCheckNotify)
    UpdateTrayIcon()
  EndIf
EndProcedure

CompilerIf Not Defined(GATEWAYS_LIBRARY, #PB_Constant)
  #GATEWAYS_LIBRARY = #False
CompilerEndIf

CompilerIf #GATEWAYS_LIBRARY = #False

; ---------- ЗАЩИТА ОТ ВТОРОЙ КОПИИ ----------
; У PureBasic нет встроенного межпроцессного именованного мьютекса. Поэтому
; здесь оставлен минимальный изолированный вызов WinAPI.
AppMutex = CreateMutex_(0, 1, "GatewaysTrayMonitor_SingleInstance_Mutex")

If AppMutex = 0 Or GetLastError_() = #ERROR_ALREADY_EXISTS
  End
EndIf

If Not LoadConfig()
  MessageRequester(#AppTitle, ConfigError, #PB_MessageRequester_Error)
  CloseHandle_(AppMutex)
  End 1
EndIf

If Not OpenWindow(#WindowMain, 0, 0, 1, 1, #AppTitle, #PB_Window_Invisible)
  MessageRequester(#AppTitle, "Не удалось создать служебное окно.", #PB_MessageRequester_Error)
  CloseHandle_(AppMutex)
  End 1
EndIf

CreateImage(#TrayImage, 32, 32, 32, #PB_Image_Transparent)
AddSysTrayIcon(#TrayIcon, WindowID(#WindowMain), ImageID(#TrayImage))

; Первый опрос тоже выполняется асинхронно. Пока он не завершён, активные
; шлюзы отображаются серым цветом без ложного FAIL/OK.
UpdateTrayIcon()
StartChecks(#False, #False)

AddWindowTimer(#WindowMain, #TimerCheck, CheckIntervalSec * 1000)

Define event.i
Define quit.i = #False

Repeat
  event = WaitWindowEvent()
  
  Select event
      
    Case #PB_Event_Timer
      If EventTimer() = #TimerCheck
        ; Запускаем проверку в фоновом потоке, только если предыдущий
        ; цикл уже завершился - это исключает наложение проверок друг
        ; на друга при медленных/недоступных хостах и не блокирует
        ; главный поток (окно, меню, иконка) на время сетевых таймаутов.
        If CheckThreadID = 0
          StartChecks(#True, #True)
        ElseIf Not IsThread(CheckThreadID)
          ; Резервный путь на случай, если PostEvent() не удалось поставить
          ; событие в очередь: не теряем готовые результаты.
          CompleteFinishedCheck()
          If Not ReloadPending
            StartChecks(#True, #True)
          EndIf
        EndIf
      EndIf
      
    Case #PB_Event_FirstCustomValue
      ; Устаревшее событие уже обработанного цикла не должно ожидать новый
      ; поток, который мог стартовать по таймеру.
      If EventGadget() = CheckGeneration
        CompleteFinishedCheck()
      EndIf
      
    Case #PB_Event_SysTray
      If EventGadget() = #TrayIcon
        RebuildPopupMenu()
        DisplayPopupMenu(#PopupMenu, WindowID(#WindowMain))
      EndIf
      
    Case #PB_Event_Menu
      Select EventMenu()
          
        Case #MenuOpenLog
          OpenLogFile()
          
        Case #MenuReloadConfig
          ReloadConfig()
          
        Case #MenuExit
          quit = #True
          
      EndSelect
      
  EndSelect
  
Until quit

; Ресурсы нельзя освобождать, пока поток использует CheckItems() и сетевую
; библиотеку. Ограниченный двухсекундный WaitThread здесь был небезопасен.
If CheckThreadID And IsThread(CheckThreadID)
  WaitThread(CheckThreadID)
EndIf

RemoveSysTrayIcon(#TrayIcon)

If AppMutex
  CloseHandle_(AppMutex)
EndIf

End
CompilerEndIf

; IDE Options = PureBasic 6.40 (Windows - x86)
; CursorPosition = 366
; FirstLine = 325
; Folding = ---
; EnableXP
; Thread
; UseIcon = gateways.ico
; Executable = gateways_v3_1.exe
