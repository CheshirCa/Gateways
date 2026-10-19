EnableExplicit

CompilerIf Not #PB_Compiler_Thread
  CompilerError "Gateway Monitor requires a thread-safe executable (/THREAD)."
CompilerEndIf

#AppName    = "Gateway Monitor"
#AppVersion = "4.2"
#AppTitle   = #AppName + " " + #AppVersion

#WindowMain = 1
#WindowGraph = 2
#TrayIcon   = 1
#TrayImage  = 1
#PopupMenu  = 1
#GraphCanvas = 1
#GraphFont = 1
#CsvHeader = "Gateway name;Address;Port;Check time;Response, ms;Result"
#TimerCheck = 1
#TimerTrayRetry = 2
#EventTaskbarCreated = #PB_Event_FirstCustomValue + 1

#MenuOpenLog      = 8997
#MenuReloadConfig = 8998
#MenuExportDatabase = 8996
#MenuExit         = 9000
#MenuGatewayBase  = 1000
#MenuAppInfo      = 999
#MenuLanguageBase = 9100
#MaxLanguages = 100

; PureBasic не предоставляет стандартной команды для чтения языка Windows.
; GetLocaleInfo_ возвращает трёхбуквенный код ISO 639-2, например RUS.
#LOCALE_USER_DEFAULT = $0400
#LOCALE_SISO639LANGNAME = $0059

; Обычное popup-меню PureBasic не публикует событие наведения на MenuItem().
; Эти константы нужны только для отслеживания выбранной строки и показа
; неактивирующегося окна с графиком.
#WM_MENUSELECT = $011F
#WM_EXITMENULOOP = $0212
#HWND_TOPMOST = -1
#SWP_NOSIZE = $0001
#SWP_NOMOVE = $0002
#SWP_NOACTIVATE = $0010
#SWP_SHOWWINDOW = $0040

#ERROR_ALREADY_EXISTS = 183
#LOG_ROTATE_SIZE = 5242880 ; 5 MB
#MAX_LOG_ARCHIVES = 10
#MAX_GATEWAYS = 15
#CHECK_PARALLELISM = 8
#RESPONSE_RETENTION_SECONDS = 86400
#GRAPH_WIDTH = 420
#GRAPH_HEIGHT = 230

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
  responseMs.i
  checkedAtEpoch.q
  checkedAt.s
EndStructure

Structure ResponseSample
  recordedAt.q
  responseMs.i
  tcpOk.i
EndStructure

Structure Language
  code.s
  name.s
EndStructure

Global NewList Gateways.Gateway()
Global NewList CheckItems.CheckItem()
Global NewList GraphSamples.ResponseSample()
Global NewList Languages.Language()
Global NewMap LanguageGroups.s()
Global NewMap Translations.s()

Global CheckIntervalSec.i = 10
Global FailCountLimit.i = 3
Global RecoverCountLimit.i = 1   ; сколько подряд успешных проверок нужно для перехода FAIL -> OK
Global ConfigFile.s
Global ConfigError.s

Global LogEnabled.i = 0
Global LogFile.s = "gateways.log"
Global ResponseDatabase.i = -1
Global ResponseDatabaseFile.s

Global AppMutex.i     ; WinAPI-мьютекс, защита от второй копии приложения
Global CheckThreadID.i = 0
Global CheckGeneration.i = 0
Global ReloadPending.i = #False
Global StopMutex.i
Global StopRequested.i = #False
Global LogWarningShown.i = #False
Global TrayAvailable.i = #False
Global TaskbarCreatedMessage.i
Global LastIconSignature.s
Global GraphGatewayIndex.i = -1
Global LanguageCode.s = "ENG"
Global LanguagePreference.s = "auto"

Declare StartChecks()
Declare CheckAllGatewaysThread(dummy.i)
Declare CheckOneGatewayThread(*item.CheckItem)
Declare ApplyCheckResults()
Declare FinishReloadConfig()
Declare CompleteFinishedCheck()
Declare UpdateTrayIcon()
Declare RestoreTrayIcon()
Declare HideResponseGraph()

Procedure RequestCheckStop(stop.i)
  LockMutex(StopMutex)
  StopRequested = stop
  UnlockMutex(StopMutex)
EndProcedure

Procedure.i CheckStopRequested()
  Protected requested.i
  LockMutex(StopMutex)
  requested = StopRequested
  UnlockMutex(StopMutex)
  ProcedureReturn requested
EndProcedure

Procedure.s NowText()
  ProcedureReturn FormatDate("%hh:%ii:%ss", Date())
EndProcedure

Procedure.s NowDateTime()
  ProcedureReturn FormatDate("%dd.%mm.%yyyy %hh:%ii:%ss", Date())
EndProcedure

Procedure.s DefaultText(key.s)
  Select UCase(key)
    Case "LANGUAGE_NAME" : ProcedureReturn "English"
    Case "CSV_HEADER" : ProcedureReturn #CsvHeader
    Case "MENU_OPEN_LOG" : ProcedureReturn "Open log"
    Case "MENU_EXPORT_CSV" : ProcedureReturn "Export database to CSV"
    Case "MENU_RELOAD_CONFIG" : ProcedureReturn "Reload configuration"
    Case "MENU_LANGUAGE" : ProcedureReturn "Language"
    Case "MENU_EXIT" : ProcedureReturn "Exit"
    Case "STATUS_DISABLED" : ProcedureReturn "DISABLED"
    Case "STATUS_CHECKING" : ProcedureReturn "CHECKING"
    Case "TRAY_NO_ACTIVE" : ProcedureReturn "NO ACTIVE GATEWAYS"
    Case "GRAPH_RESPONSE_24H" : ProcedureReturn "response time for 24 hours"
    Case "GRAPH_24H_AGO" : ProcedureReturn "24 h ago"
    Case "GRAPH_NOW" : ProcedureReturn "now"
    Case "GRAPH_NO_SAMPLES" : ProcedureReturn "No measurements yet"
    Case "GRAPH_SUCCESSFUL" : ProcedureReturn "Successful"
    Case "GRAPH_ERRORS" : ProcedureReturn "Errors"
    Case "DIALOG_EXPORT_TITLE" : ProcedureReturn "Export database"
    Case "DIALOG_CSV_PATTERN" : ProcedureReturn "CSV (*.csv)|*.csv"
    Case "DIALOG_OVERWRITE" : ProcedureReturn "The file already exists. Replace it?"
    Case "DIALOG_EXPORT_OK" : ProcedureReturn "Database exported to CSV:"
    Case "DIALOG_EXPORT_ERROR" : ProcedureReturn "Could not export database to CSV:"
    Case "DIALOG_LOG_ERROR" : ProcedureReturn "Could not write the log: "
    Case "CONFIG_ERROR_TITLE" : ProcedureReturn "Configuration error"
    Case "DIALOG_ALREADY_RUNNING" : ProcedureReturn "The application is already running or the mutex could not be created."
    Case "DIALOG_STOP_MUTEX_ERROR" : ProcedureReturn "Could not create the stop mutex."
    Case "DIALOG_DB_ERROR" : ProcedureReturn "Could not open the response-time database: "
    Case "DIALOG_WINDOW_ERROR" : ProcedureReturn "Could not create the service window."
    Case "DIALOG_GRAPH_WINDOW_ERROR" : ProcedureReturn "Could not create the chart window."
    Case "DIALOG_TRAY_ERROR" : ProcedureReturn "Could not create the tray icon."
    Case "CONFIG_CANNOT_CREATE_DIR" : ProcedureReturn "Could not create directory "
    Case "CONFIG_CANNOT_READ" : ProcedureReturn "Could not read "
    Case "CONFIG_DUPLICATE_SECTION" : ProcedureReturn "Duplicate configuration section: "
    Case "CONFIG_CANNOT_MOVE" : ProcedureReturn "Could not migrate "
    Case "CONFIG_CANNOT_CREATE" : ProcedureReturn "Could not create "
    Case "CONFIG_CANNOT_OPEN" : ProcedureReturn "Could not open "
    Case "CONFIG_INTERVAL_RANGE" : ProcedureReturn "interval_sec must be between 1 and 86400"
    Case "CONFIG_FAIL_RANGE" : ProcedureReturn "fail_count must be between 1 and 1000"
    Case "CONFIG_RECOVER_RANGE" : ProcedureReturn "recover_count must be between 1 and 1000"
    Case "CONFIG_LOG_ENABLED" : ProcedureReturn "log_enabled must be 0 or 1"
    Case "CONFIG_LOG_FILE" : ProcedureReturn "log_file must not be empty"
    Case "CONFIG_LEGACY" : ProcedureReturn "Legacy INI format found. Remove the [Gateways] section and use gateway names as section names."
    Case "CONFIG_SECTION_EMPTY" : ProcedureReturn "Gateway section name must not be empty"
    Case "CONFIG_ENABLED" : ProcedureReturn "enabled must be 0 or 1"
    Case "CONFIG_MAX_GATEWAYS" : ProcedureReturn "Enabled gateway count must not exceed "
    Case "CONFIG_HOST_REQUIRED" : ProcedureReturn "host is required for an enabled gateway"
    Case "CONFIG_PORT_RANGE" : ProcedureReturn "port must be between 1 and 65535"
    Case "CONFIG_CANNOT_READ_GROUPS" : ProcedureReturn "Could not read configuration sections"
  EndSelect
  ProcedureReturn key
EndProcedure

Procedure.s Text(key.s)
  key = UCase(key)
  If FindMapElement(Translations(), key) And Trim(Translations()) <> ""
    ProcedureReturn Translations()
  EndIf
  ProcedureReturn DefaultText(key)
EndProcedure

Procedure.s SystemLanguageCode()
  Protected buffer.s = Space(16)
  Protected length.i
  
  length = GetLocaleInfo_(#LOCALE_USER_DEFAULT, #LOCALE_SISO639LANGNAME, @buffer, 16)
  If length > 1
    ProcedureReturn UCase(Left(buffer, length - 1))
  EndIf
  ProcedureReturn "ENG"
EndProcedure

Procedure.i IsLanguageSection(group.s)
  group = UCase(Trim(group))
  ProcedureReturn Bool(Left(group, 5) = "LANG-" And Len(group) = 8)
EndProcedure

Procedure RegisterLanguage(code.s, group.s)
  If Not FindMapElement(LanguageGroups(), code)
    AddElement(Languages())
    Languages()\code = code
    Languages()\name = code
  EndIf
  LanguageGroups(code) = group
EndProcedure

Procedure LoadLanguages(preferred.s)
  Protected group.s, code.s, target.s, systemCode.s
  
  ClearList(Languages())
  ClearMap(LanguageGroups())
  ClearMap(Translations())
  RegisterLanguage("ENG", "")
  
  If ExaminePreferenceGroups()
    While NextPreferenceGroup()
      group = Trim(PreferenceGroupName())
      If IsLanguageSection(group)
        code = UCase(Mid(group, 6))
        RegisterLanguage(code, group)
      EndIf
    Wend
  EndIf
  
  ForEach Languages()
    If FindMapElement(LanguageGroups(), Languages()\code) And LanguageGroups() <> ""
      PreferenceGroup(LanguageGroups())
      Languages()\name = Trim(ReadPreferenceString("LANGUAGE_NAME", Languages()\code))
    ElseIf Languages()\code = "ENG"
      Languages()\name = DefaultText("LANGUAGE_NAME")
    EndIf
  Next
  
  preferred = UCase(Trim(preferred))
  LanguagePreference = preferred
  If preferred <> "" And preferred <> "AUTO" And FindMapElement(LanguageGroups(), preferred)
    target = preferred
  Else
    systemCode = SystemLanguageCode()
    If FindMapElement(LanguageGroups(), systemCode)
      target = systemCode
    Else
      target = "ENG"
    EndIf
  EndIf
  If Not FindMapElement(LanguageGroups(), target)
    target = "ENG"
  EndIf
  LanguageCode = target
  
  If FindMapElement(LanguageGroups(), LanguageCode) And LanguageGroups() <> ""
    PreferenceGroup(LanguageGroups())
    If ExaminePreferenceKeys()
      While NextPreferenceKey()
        Translations(UCase(Trim(PreferenceKeyName()))) = PreferenceKeyValue()
      Wend
    EndIf
  EndIf
EndProcedure

Procedure.i SaveLanguagePreference(code.s)
  If Not OpenPreferences(ConfigFile, #PB_Preference_NoSpace, #PB_UTF8)
    ProcedureReturn #False
  EndIf
  PreferenceGroup("Settings")
  WritePreferenceString("language", code)
  ClosePreferences()
  ProcedureReturn #True
EndProcedure

Procedure.s GatewayKey(name.s, host.s, port.i)
  ; Разделитель не допускается в имени INI-секции Windows, поэтому ключ
  ; однозначно связывает историю с адресом конкретного шлюза.
  ProcedureReturn name + Chr(31) + host + Chr(31) + Str(port)
EndProcedure

Procedure.i OpenResponseDatabase(databaseFile.s = "")
  Protected f.i
  
  If databaseFile = ""
    ResponseDatabaseFile = GetPathPart(ProgramFilename()) + "gateways.dat"
  Else
    ResponseDatabaseFile = databaseFile
  EndIf
  
  If IsDatabase(ResponseDatabase)
    CloseDatabase(ResponseDatabase)
  EndIf
  ResponseDatabase = -1
  
  If FileSize(ResponseDatabaseFile) = -1
    f = CreateFile(#PB_Any, ResponseDatabaseFile)
    If f = 0
      ProcedureReturn #False
    EndIf
    CloseFile(f)
  EndIf
  
  UseSQLiteDatabase()
  ResponseDatabase = OpenDatabase(#PB_Any, ResponseDatabaseFile, "", "", #PB_Database_SQLite)
  If ResponseDatabase = 0
    ResponseDatabase = -1
    ProcedureReturn #False
  EndIf
  
  If Not DatabaseUpdate(ResponseDatabase, "CREATE TABLE IF NOT EXISTS response_samples (gateway_key TEXT NOT NULL, recorded_at INTEGER NOT NULL, response_ms INTEGER NOT NULL, tcp_ok INTEGER NOT NULL)")
    CloseDatabase(ResponseDatabase)
    ResponseDatabase = -1
    ProcedureReturn #False
  EndIf
  If Not DatabaseUpdate(ResponseDatabase, "CREATE INDEX IF NOT EXISTS response_samples_lookup ON response_samples (gateway_key, recorded_at)")
    CloseDatabase(ResponseDatabase)
    ResponseDatabase = -1
    ProcedureReturn #False
  EndIf
  
  ProcedureReturn #True
EndProcedure

Procedure CloseResponseDatabase()
  If IsDatabase(ResponseDatabase)
    CloseDatabase(ResponseDatabase)
  EndIf
  ResponseDatabase = -1
EndProcedure

Procedure SaveResponseSample(name.s, host.s, port.i, responseMs.i, tcpOk.i, recordedAt.q)
  If Not IsDatabase(ResponseDatabase)
    ProcedureReturn
  EndIf
  
  SetDatabaseQuad(ResponseDatabase, 0, recordedAt - #RESPONSE_RETENTION_SECONDS)
  DatabaseUpdate(ResponseDatabase, "DELETE FROM response_samples WHERE recorded_at < ?")
  
  SetDatabaseString(ResponseDatabase, 0, GatewayKey(name, host, port))
  SetDatabaseQuad(ResponseDatabase, 1, recordedAt)
  SetDatabaseLong(ResponseDatabase, 2, responseMs)
  SetDatabaseLong(ResponseDatabase, 3, tcpOk)
  DatabaseUpdate(ResponseDatabase, "INSERT INTO response_samples (gateway_key, recorded_at, response_ms, tcp_ok) VALUES (?, ?, ?, ?)")
EndProcedure

Procedure.i LoadResponseSamples(name.s, host.s, port.i)
  Protected cutoff.q = Date() - #RESPONSE_RETENTION_SECONDS
  
  ClearList(GraphSamples())
  If Not IsDatabase(ResponseDatabase)
    ProcedureReturn #False
  EndIf
  
  SetDatabaseString(ResponseDatabase, 0, GatewayKey(name, host, port))
  SetDatabaseQuad(ResponseDatabase, 1, cutoff)
  If Not DatabaseQuery(ResponseDatabase, "SELECT recorded_at, response_ms, tcp_ok FROM response_samples WHERE gateway_key = ? AND recorded_at >= ? ORDER BY recorded_at")
    ProcedureReturn #False
  EndIf
  While NextDatabaseRow(ResponseDatabase)
    AddElement(GraphSamples())
    GraphSamples()\recordedAt = GetDatabaseQuad(ResponseDatabase, 0)
    GraphSamples()\responseMs = GetDatabaseLong(ResponseDatabase, 1)
    GraphSamples()\tcpOk = GetDatabaseLong(ResponseDatabase, 2)
  Wend
  FinishDatabaseQuery(ResponseDatabase)
  ProcedureReturn #True
EndProcedure

Procedure.s CsvField(text.s)
  ProcedureReturn Chr(34) + ReplaceString(text, Chr(34), Chr(34) + Chr(34)) + Chr(34)
EndProcedure

Procedure.i ExportResponseDatabase(exportFile.s)
  Protected file.i
  Protected gatewayKey.s
  Protected name.s
  Protected host.s
  Protected port.s
  Protected line.s
  Protected result.s
  Protected written.i = #True
  Protected cutoff.q = Date() - #RESPONSE_RETENTION_SECONDS
  
  If Not IsDatabase(ResponseDatabase)
    ProcedureReturn #False
  EndIf
  
  file = CreateFile(#PB_Any, exportFile, #PB_File_BOM | #PB_UTF8)
  If file = 0
    ProcedureReturn #False
  EndIf
  
  If Not WriteStringN(file, Text("CSV_HEADER"), #PB_UTF8)
    written = #False
  EndIf
  SetDatabaseQuad(ResponseDatabase, 0, cutoff)
  If DatabaseQuery(ResponseDatabase, "SELECT gateway_key, recorded_at, response_ms, tcp_ok FROM response_samples WHERE recorded_at >= ? ORDER BY recorded_at, gateway_key")
    While NextDatabaseRow(ResponseDatabase)
      gatewayKey = GetDatabaseString(ResponseDatabase, 0)
      name = StringField(gatewayKey, 1, Chr(31))
      host = StringField(gatewayKey, 2, Chr(31))
      port = StringField(gatewayKey, 3, Chr(31))
      If GetDatabaseLong(ResponseDatabase, 3)
        result = "OK"
      Else
        result = "FAIL"
      EndIf
      line = CsvField(name) + ";" + CsvField(host) + ";" + CsvField(port) + ";" + CsvField(FormatDate("%yyyy-%mm-%dd %hh:%ii:%ss", GetDatabaseQuad(ResponseDatabase, 1))) + ";" + CsvField(Str(GetDatabaseLong(ResponseDatabase, 2))) + ";" + CsvField(result)
      If Not WriteStringN(file, line, #PB_UTF8)
        written = #False
      EndIf
    Wend
    FinishDatabaseQuery(ResponseDatabase)
  Else
    written = #False
  EndIf
  
  CloseFile(file)
  ProcedureReturn written
EndProcedure

Procedure ExportResponseDatabaseRequester()
  Protected defaultFile.s
  Protected exportFile.s
  
  defaultFile = GetPathPart(ResponseDatabaseFile) + "gateway_response_history.csv"
  exportFile = SaveFileRequester(Text("DIALOG_EXPORT_TITLE"), defaultFile, Text("DIALOG_CSV_PATTERN"), 0, WindowID(#WindowMain))
  If exportFile = ""
    ProcedureReturn
  EndIf
  If LCase(GetExtensionPart(exportFile)) <> "csv"
    exportFile + ".csv"
  EndIf
  
  If FileSize(exportFile) <> -1
    If MessageRequester(#AppTitle, Text("DIALOG_OVERWRITE"), #PB_MessageRequester_YesNo | #PB_MessageRequester_Warning) <> #PB_MessageRequester_Yes
      ProcedureReturn
    EndIf
  EndIf
  
  If ExportResponseDatabase(exportFile)
    MessageRequester(#AppTitle, Text("DIALOG_EXPORT_OK") + #CRLF$ + exportFile)
  Else
    MessageRequester(#AppTitle, Text("DIALOG_EXPORT_ERROR") + #CRLF$ + exportFile, #PB_MessageRequester_Warning)
  EndIf
EndProcedure

Procedure.s Quote(text.s)
  ProcedureReturn Chr(34) + text + Chr(34)
EndProcedure

Procedure RotateLogIfNeeded()
  Protected size.q
  Protected rotatedName.s
  Protected archiveCount.i
  Protected NewList archives.s()
  
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
    If ExamineDirectory(0, GetPathPart(LogFile), GetFilePart(LogFile) + ".*.old")
      While NextDirectoryEntry(0)
        If DirectoryEntryType(0) = #PB_DirectoryEntry_File
          AddElement(archives())
          archives() = DirectoryEntryName(0)
        EndIf
      Wend
      FinishDirectory(0)
      SortList(archives(), #PB_Sort_Descending)
      ForEach archives()
        archiveCount + 1
        If archiveCount > #MAX_LOG_ARCHIVES
          DeleteFile(GetPathPart(LogFile) + archives())
        EndIf
      Next
    EndIf
  EndIf
EndProcedure

Procedure WriteLog(text.s)
  Protected f.i
  Protected written.i
  
  If LogEnabled = 0
    ProcedureReturn
  EndIf
  
  RotateLogIfNeeded()
  
  f = OpenFile(#PB_Any, LogFile)
  If f
    FileSeek(f, Lof(f))
    written = WriteStringN(f, NowDateTime() + "  " + text, #PB_UTF8)
    CloseFile(f)
    If written = 0 And Not LogWarningShown
      LogWarningShown = #True
      MessageRequester(#AppTitle, Text("DIALOG_LOG_ERROR") + LogFile, #PB_MessageRequester_Warning)
    EndIf
  ElseIf Not LogWarningShown
    LogWarningShown = #True
    MessageRequester(#AppTitle, Text("DIALOG_LOG_ERROR") + LogFile, #PB_MessageRequester_Warning)
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

Procedure ShowTrayBalloon(title.s, text.s, warning.i = #True)
  ; Встроенная WinAPI-структура PureBasic имеет нужное для x86/x64 выравнивание.
  ; У SysTray-библиотеки нет команды для balloon-уведомлений.
  Protected nid.NOTIFYICONDATA
  
  nid\cbSize = SizeOf(NOTIFYICONDATA)
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
  WriteStringN(f, "language=auto")
  WriteStringN(f, "")
  WriteStringN(f, "[Example-Gateway]")
  WriteStringN(f, "host=192.0.2.1")
  WriteStringN(f, "port=8291")
  WriteStringN(f, "enabled=0")
  WriteStringN(f, "alert_down=Gateway is unavailable")
  WriteStringN(f, "alert_up=Gateway connection restored")
  WriteStringN(f, "")
  WriteStringN(f, "[LANG-ENG]")
  WriteStringN(f, "LANGUAGE_NAME=English")
  WriteStringN(f, "CSV_HEADER=Gateway name;Address;Port;Check time;Response, ms;Result")
  WriteStringN(f, "MENU_OPEN_LOG=Open log")
  WriteStringN(f, "MENU_EXPORT_CSV=Export database to CSV")
  WriteStringN(f, "MENU_RELOAD_CONFIG=Reload configuration")
  WriteStringN(f, "MENU_LANGUAGE=Language")
  WriteStringN(f, "MENU_EXIT=Exit")
  WriteStringN(f, "STATUS_DISABLED=DISABLED")
  WriteStringN(f, "STATUS_CHECKING=CHECKING")
  WriteStringN(f, "TRAY_NO_ACTIVE=NO ACTIVE GATEWAYS")
  WriteStringN(f, "GRAPH_RESPONSE_24H=response time for 24 hours")
  WriteStringN(f, "GRAPH_24H_AGO=24 h ago")
  WriteStringN(f, "GRAPH_NOW=now")
  WriteStringN(f, "GRAPH_NO_SAMPLES=No measurements yet")
  WriteStringN(f, "GRAPH_SUCCESSFUL=Successful")
  WriteStringN(f, "GRAPH_ERRORS=Errors")
  WriteStringN(f, "DIALOG_EXPORT_TITLE=Export database")
  WriteStringN(f, "DIALOG_CSV_PATTERN=CSV (*.csv)|*.csv")
  WriteStringN(f, "DIALOG_OVERWRITE=The file already exists. Replace it?")
  WriteStringN(f, "DIALOG_EXPORT_OK=Database exported to CSV:")
  WriteStringN(f, "DIALOG_EXPORT_ERROR=Could not export database to CSV:")
  WriteStringN(f, "DIALOG_LOG_ERROR=Could not write the log: ")
  WriteStringN(f, "CONFIG_ERROR_TITLE=Configuration error")
  WriteStringN(f, "DIALOG_ALREADY_RUNNING=The application is already running or the mutex could not be created.")
  WriteStringN(f, "DIALOG_STOP_MUTEX_ERROR=Could not create the stop mutex.")
  WriteStringN(f, "DIALOG_DB_ERROR=Could not open the response-time database: ")
  WriteStringN(f, "DIALOG_WINDOW_ERROR=Could not create the service window.")
  WriteStringN(f, "DIALOG_GRAPH_WINDOW_ERROR=Could not create the chart window.")
  WriteStringN(f, "DIALOG_TRAY_ERROR=Could not create the tray icon.")
  WriteStringN(f, "CONFIG_CANNOT_CREATE_DIR=Could not create directory ")
  WriteStringN(f, "CONFIG_CANNOT_READ=Could not read ")
  WriteStringN(f, "CONFIG_DUPLICATE_SECTION=Duplicate configuration section: ")
  WriteStringN(f, "CONFIG_CANNOT_MOVE=Could not migrate ")
  WriteStringN(f, "CONFIG_CANNOT_CREATE=Could not create ")
  WriteStringN(f, "CONFIG_CANNOT_OPEN=Could not open ")
  WriteStringN(f, "CONFIG_INTERVAL_RANGE=interval_sec must be between 1 and 86400")
  WriteStringN(f, "CONFIG_FAIL_RANGE=fail_count must be between 1 and 1000")
  WriteStringN(f, "CONFIG_RECOVER_RANGE=recover_count must be between 1 and 1000")
  WriteStringN(f, "CONFIG_LOG_ENABLED=log_enabled must be 0 or 1")
  WriteStringN(f, "CONFIG_LOG_FILE=log_file must not be empty")
  WriteStringN(f, "CONFIG_LEGACY=Legacy INI format found. Remove the [Gateways] section and use gateway names as section names.")
  WriteStringN(f, "CONFIG_SECTION_EMPTY=Gateway section name must not be empty")
  WriteStringN(f, "CONFIG_ENABLED=enabled must be 0 or 1")
  WriteStringN(f, "CONFIG_MAX_GATEWAYS=Enabled gateway count must not exceed ")
  WriteStringN(f, "CONFIG_HOST_REQUIRED=host is required for an enabled gateway")
  WriteStringN(f, "CONFIG_PORT_RANGE=port must be between 1 and 65535")
  WriteStringN(f, "CONFIG_CANNOT_READ_GROUPS=Could not read configuration sections")
  WriteStringN(f, "")
  WriteStringN(f, "[LANG-RUS]")
  WriteStringN(f, "LANGUAGE_NAME=Русский")
  WriteStringN(f, "CSV_HEADER=Имя шлюза;Адрес;Порт;Время проверки;Отклик, мс;Результат")
  WriteStringN(f, "MENU_OPEN_LOG=Открыть лог")
  WriteStringN(f, "MENU_EXPORT_CSV=Экспорт базы в CSV")
  WriteStringN(f, "MENU_RELOAD_CONFIG=Перечитать конфигурацию")
  WriteStringN(f, "MENU_LANGUAGE=Язык")
  WriteStringN(f, "MENU_EXIT=Выход")
  WriteStringN(f, "STATUS_DISABLED=ОТКЛЮЧЕН")
  WriteStringN(f, "STATUS_CHECKING=ПРОВЕРКА")
  WriteStringN(f, "TRAY_NO_ACTIVE=НЕТ АКТИВНЫХ ШЛЮЗОВ")
  WriteStringN(f, "GRAPH_RESPONSE_24H=отклик за 24 часа")
  WriteStringN(f, "GRAPH_24H_AGO=24 ч назад")
  WriteStringN(f, "GRAPH_NOW=сейчас")
  WriteStringN(f, "GRAPH_NO_SAMPLES=Пока нет измерений")
  WriteStringN(f, "GRAPH_SUCCESSFUL=Успешно")
  WriteStringN(f, "GRAPH_ERRORS=Ошибки")
  WriteStringN(f, "DIALOG_EXPORT_TITLE=Экспорт базы")
  WriteStringN(f, "DIALOG_CSV_PATTERN=CSV (*.csv)|*.csv")
  WriteStringN(f, "DIALOG_OVERWRITE=Файл уже существует. Заменить его?")
  WriteStringN(f, "DIALOG_EXPORT_OK=База экспортирована в CSV:")
  WriteStringN(f, "DIALOG_EXPORT_ERROR=Не удалось экспортировать базу в CSV:")
  WriteStringN(f, "DIALOG_LOG_ERROR=Не удалось записать журнал: ")
  WriteStringN(f, "CONFIG_ERROR_TITLE=Ошибка конфигурации")
  WriteStringN(f, "DIALOG_ALREADY_RUNNING=Программа уже запущена или не удалось создать мьютекс.")
  WriteStringN(f, "DIALOG_STOP_MUTEX_ERROR=Не удалось создать мьютекс остановки.")
  WriteStringN(f, "DIALOG_DB_ERROR=Не удалось открыть базу времени отклика: ")
  WriteStringN(f, "DIALOG_WINDOW_ERROR=Не удалось создать служебное окно.")
  WriteStringN(f, "DIALOG_GRAPH_WINDOW_ERROR=Не удалось создать окно графика.")
  WriteStringN(f, "DIALOG_TRAY_ERROR=Не удалось создать иконку трея.")
  WriteStringN(f, "CONFIG_CANNOT_CREATE_DIR=Не удалось создать каталог ")
  WriteStringN(f, "CONFIG_CANNOT_READ=Не удалось прочитать ")
  WriteStringN(f, "CONFIG_DUPLICATE_SECTION=Повторная секция конфигурации: ")
  WriteStringN(f, "CONFIG_CANNOT_MOVE=Не удалось перенести ")
  WriteStringN(f, "CONFIG_CANNOT_CREATE=Не удалось создать ")
  WriteStringN(f, "CONFIG_CANNOT_OPEN=Не удалось открыть ")
  WriteStringN(f, "CONFIG_INTERVAL_RANGE=interval_sec должен быть в диапазоне 1..86400")
  WriteStringN(f, "CONFIG_FAIL_RANGE=fail_count должен быть в диапазоне 1..1000")
  WriteStringN(f, "CONFIG_RECOVER_RANGE=recover_count должен быть в диапазоне 1..1000")
  WriteStringN(f, "CONFIG_LOG_ENABLED=log_enabled должен быть равен 0 или 1")
  WriteStringN(f, "CONFIG_LOG_FILE=log_file не должен быть пустым")
  WriteStringN(f, "CONFIG_LEGACY=Обнаружен старый формат INI. Удалите секцию [Gateways] и используйте названия шлюзов как имена секций.")
  WriteStringN(f, "CONFIG_SECTION_EMPTY=Имя секции шлюза не должно быть пустым")
  WriteStringN(f, "CONFIG_ENABLED=enabled должен быть равен 0 или 1")
  WriteStringN(f, "CONFIG_MAX_GATEWAYS=Количество включённых шлюзов не должно превышать ")
  WriteStringN(f, "CONFIG_HOST_REQUIRED=для включённого шлюза требуется host")
  WriteStringN(f, "CONFIG_PORT_RANGE=port должен быть в диапазоне 1..65535")
  WriteStringN(f, "CONFIG_CANNOT_READ_GROUPS=Не удалось прочитать секции конфигурации")
  CloseFile(f)
  
  ProcedureReturn #True
EndProcedure

Procedure.i AppendDefaultLanguageSections(file.s)
  Protected templateFile.s = file + ".languages.tmp"
  Protected source.i, destination.i, inLanguageSection.i, line.s
  
  If Not CreateSampleConfig(templateFile)
    ProcedureReturn #False
  EndIf
  source = ReadFile(#PB_Any, templateFile)
  destination = OpenFile(#PB_Any, file, #PB_UTF8)
  If source = 0 Or destination = 0
    If source : CloseFile(source) : EndIf
    If destination : CloseFile(destination) : EndIf
    DeleteFile(templateFile)
    ProcedureReturn #False
  EndIf
  
  FileSeek(destination, Lof(destination))
  WriteStringN(destination, "", #PB_UTF8)
  ReadStringFormat(source)
  While Not Eof(source)
    line = ReadString(source, #PB_UTF8)
    If Left(UCase(Trim(line)), 6) = "[LANG-"
      inLanguageSection = #True
    EndIf
    If inLanguageSection
      WriteStringN(destination, line, #PB_UTF8)
    EndIf
  Wend
  
  CloseFile(source)
  CloseFile(destination)
  DeleteFile(templateFile)
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

Procedure.s DefaultConfigPath()
  Protected directory.s = GetEnvironmentVariable("APPDATA")
  If directory = ""
    directory = GetHomeDirectory()
  EndIf
  If Right(directory, 1) <> "\"
    directory + "\"
  EndIf
  directory + "Gateway Monitor\"
  If FileSize(directory) <> -2 And Not CreateDirectory(directory)
    ConfigError = Text("CONFIG_CANNOT_CREATE_DIR") + directory
    ProcedureReturn ""
  EndIf
  ProcedureReturn directory + "gateways.ini"
EndProcedure

Procedure.i ValidateConfigGroups(path.s)
  Protected f.i, line.s, group.s, key.s
  Protected NewMap seen.i()
  f = ReadFile(#PB_Any, path)
  If f = 0
    ConfigError = Text("CONFIG_CANNOT_READ") + path
    ProcedureReturn #False
  EndIf
  ReadStringFormat(f)
  While Not Eof(f)
    line = Trim(ReadString(f, #PB_UTF8))
    If Left(line, 1) = "[" And Right(line, 1) = "]"
      group = Trim(Mid(line, 2, Len(line) - 2))
      key = LCase(group)
      If FindMapElement(seen(), key)
        ConfigError = Text("CONFIG_DUPLICATE_SECTION") + "[" + group + "]"
        CloseFile(f)
        ProcedureReturn #False
      EndIf
      seen(key) = 1
    EndIf
  Wend
  CloseFile(f)
  ProcedureReturn #True
EndProcedure

; Конфигурация сначала полностью читается во временный список. Действующие
; настройки заменяются только после успешного чтения и проверки всех полей.
Procedure.i LoadConfig(configPath.s = "")
  Protected NewList loaded.Gateway()
  Protected count.i, group.s
  Protected interval.i, failLimit.i, recoverLimit.i, logOn.i
  Protected logPath.s, oldConfig.s, enabledText.s, logOnText.s
  
  ConfigError = ""
  If configPath <> ""
    ConfigFile = configPath
  ElseIf ConfigFile = ""
    ConfigFile = DefaultConfigPath()
    If ConfigFile = ""
      ProcedureReturn #False
    EndIf
  EndIf
  
  If FileSize(ConfigFile) = -1
    oldConfig = GetPathPart(ProgramFilename()) + "gateways.ini"
    If oldConfig <> ConfigFile And FileSize(oldConfig) >= 0
      If Not CopyFile(oldConfig, ConfigFile)
        ConfigError = Text("CONFIG_CANNOT_MOVE") + oldConfig
        ProcedureReturn #False
      EndIf
    ElseIf Not CreateSampleConfig(ConfigFile)
      ConfigError = Text("CONFIG_CANNOT_CREATE") + ConfigFile
      ProcedureReturn #False
    EndIf
  EndIf
  If Not ValidateConfigGroups(ConfigFile)
    ProcedureReturn #False
  EndIf
  
  If Not OpenPreferences(ConfigFile, #PB_Preference_NoSpace, #PB_UTF8)
    ConfigError = Text("CONFIG_CANNOT_OPEN") + ConfigFile
    ProcedureReturn #False
  EndIf
  
  PreferenceGroup("Settings")
  interval     = ReadPreferenceInteger("interval_sec", 10)
  failLimit    = ReadPreferenceInteger("fail_count", 3)
  recoverLimit = ReadPreferenceInteger("recover_count", 1)
  logOnText    = Trim(ReadPreferenceString("log_enabled", "0"))
  logOn        = Val(logOnText)
  logPath      = Trim(ReadPreferenceString("log_file", "gateways.log"))
  LanguagePreference = Trim(ReadPreferenceString("language", ""))
  If LanguagePreference = ""
    LanguagePreference = "auto"
    WritePreferenceString("language", LanguagePreference)
  EndIf
  LoadLanguages(LanguagePreference)
  If ListSize(Languages()) = 1 And FindMapElement(LanguageGroups(), "ENG") And LanguageGroups() = ""
    ClosePreferences()
    If Not AppendDefaultLanguageSections(ConfigFile)
      ConfigError = Text("CONFIG_CANNOT_CREATE") + ConfigFile
      ProcedureReturn #False
    EndIf
    ProcedureReturn LoadConfig(ConfigFile)
  EndIf
  
  If interval < 1 Or interval > 86400
    ConfigError = Text("CONFIG_INTERVAL_RANGE")
  ElseIf failLimit < 1 Or failLimit > 1000
    ConfigError = Text("CONFIG_FAIL_RANGE")
  ElseIf recoverLimit < 1 Or recoverLimit > 1000
    ConfigError = Text("CONFIG_RECOVER_RANGE")
  ElseIf logOnText <> "0" And logOnText <> "1"
    ConfigError = Text("CONFIG_LOG_ENABLED")
  ElseIf logPath = ""
    ConfigError = Text("CONFIG_LOG_FILE")
  EndIf
  
  If ConfigError = ""
    If ExaminePreferenceGroups()
      While NextPreferenceGroup()
        group = Trim(PreferenceGroupName())
        
        ; Settings содержит глобальные параметры, LANG-XXX — переводы.
        ; Все прочие секции являются шлюзами.
        If LCase(group) <> "settings" And Not IsLanguageSection(group)
          If LCase(group) = "gateways"
            ConfigError = Text("CONFIG_LEGACY")
            Break
          EndIf
          
          enabledText = Trim(ReadPreferenceString("enabled", "1"))
          If group = ""
            ConfigError = Text("CONFIG_SECTION_EMPTY")
            Break
          ElseIf enabledText <> "0" And enabledText <> "1"
            ConfigError = group + ": " + Text("CONFIG_ENABLED")
            Break
          ElseIf enabledText = "1"
            count + 1
            If count > #MAX_GATEWAYS
              ConfigError = Text("CONFIG_MAX_GATEWAYS") + Str(#MAX_GATEWAYS)
              Break
            EndIf
            
            AddElement(loaded())
            loaded()\name = group
            loaded()\host = Trim(ReadPreferenceString("host", ""))
            loaded()\port = ReadPreferenceInteger("port", 8291)
            loaded()\enabled = #True
            loaded()\state = #GatewayStateUnknown
            loaded()\failStreak = 0
            loaded()\okStreak = 0
            loaded()\lastCheck = "-"
            loaded()\alertDown = ReadPreferenceString("alert_down", "")
            loaded()\alertUp = ReadPreferenceString("alert_up", "")
            
            If loaded()\host = ""
              ConfigError = group + ": " + Text("CONFIG_HOST_REQUIRED")
              Break
            ElseIf loaded()\port < 1 Or loaded()\port > 65535
              ConfigError = group + ": " + Text("CONFIG_PORT_RANGE")
              Break
            EndIf
          EndIf
        EndIf
      Wend
    Else
      ConfigError = Text("CONFIG_CANNOT_READ_GROUPS")
    EndIf
  EndIf
  
  ClosePreferences()
  
  If ConfigError <> ""
    ProcedureReturn #False
  EndIf
  
  If Not IsAbsoluteWindowsPath(logPath)
    logPath = GetPathPart(ConfigFile) + logPath
  EndIf
  
  ; Совпадающий шлюз сохраняет состояние и счётчики при перезагрузке.
  ForEach loaded()
    ForEach Gateways()
      If LCase(Gateways()\name) = LCase(loaded()\name) And Gateways()\host = loaded()\host And Gateways()\port = loaded()\port
        loaded()\state = Gateways()\state
        loaded()\failStreak = Gateways()\failStreak
        loaded()\okStreak = Gateways()\okStreak
        loaded()\lastCheck = Gateways()\lastCheck
        Break
      EndIf
    Next
  Next
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
  
  loaded = LoadConfig()
  ReloadPending = #False
  
  If loaded
    RemoveWindowTimer(#WindowMain, #TimerCheck)
    AddWindowTimer(#WindowMain, #TimerCheck, CheckIntervalSec * 1000)
    WriteLog("CONFIG RELOADED")
    StartChecks()
    UpdateTrayIcon()
  Else
    WriteLog("CONFIG ERROR  " + ConfigError)
    ShowTrayBalloon(Text("CONFIG_ERROR_TITLE"), ConfigError, #True)
  EndIf
EndProcedure

Procedure ReloadConfig()
  ReloadPending = #True
  
  ; Не блокируем UI ожиданием сетевого таймаута. Если проверка уже идёт,
  ; перезагрузка продолжится после её штатного завершения.
  If CheckThreadID = 0
    FinishReloadConfig()
  ElseIf Not IsThread(CheckThreadID)
    CompleteFinishedCheck()
  Else
    RequestCheckStop(#True)
  EndIf
EndProcedure

Procedure.i CheckTcp(host.s, port.i, *responseMs.Integer, timeoutMs.i = 1500)
  Protected conn.i
  Protected startedAt.q
  
  startedAt = ElapsedMilliseconds()
  conn = OpenNetworkConnection(host, port, #PB_Network_TCP, timeoutMs)
  *responseMs\i = ElapsedMilliseconds() - startedAt
  
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
Procedure.i StartChecks()
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
  
  RequestCheckStop(#False)
  CheckGeneration + 1
  CheckThreadID = CreateThread(@CheckAllGatewaysThread(), CheckGeneration)
  
  If CheckThreadID = 0
    ClearList(CheckItems())
    WriteLog("ERROR  Не удалось запустить поток проверки")
    ProcedureReturn #False
  EndIf
  
  ProcedureReturn #True
EndProcedure

; Каждый поток пробы пишет только в свой элемент снимка. Курсор списка остаётся
; у координирующего потока; UI не читает снимок до его полного завершения.
Procedure CheckOneGatewayThread(*item.CheckItem)
  If Not CheckStopRequested()
    *item\tcpOk = CheckTcp(*item\host, *item\port, @*item\responseMs)
    *item\checkedAtEpoch = Date()
    *item\checkedAt = NowText()
  EndIf
EndProcedure

Procedure CheckAllGatewaysThread(dummy.i)
  Protected Dim workers.i(#CHECK_PARALLELISM - 1)
  Protected count.i, index.i
  ForEach CheckItems()
    If CheckStopRequested()
      Break
    EndIf
    workers(count) = CreateThread(@CheckOneGatewayThread(), @CheckItems())
    If workers(count)
      count + 1
    Else
      ; Если поток создать не удалось, не теряем результат этой пробы.
      CheckOneGatewayThread(@CheckItems())
    EndIf
    If count = #CHECK_PARALLELISM
      For index = 0 To count - 1
        WaitThread(workers(index))
      Next
      count = 0
    EndIf
  Next
  For index = 0 To count - 1
    WaitThread(workers(index))
  Next
  PostEvent(#PB_Event_FirstCustomValue, #WindowMain, dummy)
EndProcedure

; Применение результатов и все побочные эффекты выполняются главным потоком.
Procedure ApplyCheckResults()
  Protected oldState.i, newState.i
  Protected eventTime.s, eventText.s, downNames.s, upNames.s
  Protected downTitle.s, upTitle.s, downCount.i, upCount.i
  
  ForEach CheckItems()
    If SelectElement(Gateways(), CheckItems()\gatewayIndex)
      oldState = Gateways()\state
      ApplyProbeResult(@Gateways(), CheckItems()\tcpOk)
      newState = Gateways()\state
      Gateways()\lastCheck = CheckItems()\checkedAt
      SaveResponseSample(Gateways()\name, Gateways()\host, Gateways()\port, CheckItems()\responseMs, CheckItems()\tcpOk, CheckItems()\checkedAtEpoch)
      
      If newState <> oldState
        eventTime = NowDateTime()
        
        If newState = #GatewayStateFail
          If oldState = #GatewayStateUnknown
            WriteLog("INITIAL FAIL  " + Gateways()\name + "  " + Gateways()\host + ":" + Str(Gateways()\port))
          Else
            WriteLog("FAIL  " + Gateways()\name + "  " + Gateways()\host + ":" + Str(Gateways()\port))
          EndIf
          
          If Trim(Gateways()\alertDown) <> ""
            downCount + 1
            If downNames <> "" : downNames + ", " : EndIf
            downNames + Gateways()\name
            downTitle = Gateways()\alertDown
          EndIf
        Else
          If oldState = #GatewayStateUnknown
            WriteLog("INITIAL OK    " + Gateways()\name + "  " + Gateways()\host + ":" + Str(Gateways()\port))
          Else
            WriteLog("OK    " + Gateways()\name + "  " + Gateways()\host + ":" + Str(Gateways()\port))
          EndIf
          
          If oldState <> #GatewayStateUnknown And Trim(Gateways()\alertUp) <> ""
            upCount + 1
            If upNames <> "" : upNames + ", " : EndIf
            upNames + Gateways()\name
            upTitle = Gateways()\alertUp
          EndIf
        EndIf
      EndIf
    EndIf
  Next
  If downCount And upCount
    eventText = "FAIL: " + downNames + #CRLF$ + "OK: " + upNames
    ShowTrayBalloon("Изменения состояния шлюзов", Left(eventText, 240), #True)
  ElseIf downCount
    If downCount > 1 : downTitle = "Недоступны шлюзы" : EndIf
    ShowTrayBalloon(downTitle, Left(downNames, 240) + #CRLF$ + "Время: " + eventTime, #True)
  ElseIf upCount
    If upCount > 1 : upTitle = "Связь восстановлена" : EndIf
    ShowTrayBalloon(upTitle, Left(upNames, 240) + #CRLF$ + "Время: " + eventTime, #False)
  EndIf
  
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
    x = cx + Round(Cos((angle - 90.0) * #PI / 180.0) * radius, #PB_Round_Nearest)
    y = cy + Round(Sin((angle - 90.0) * #PI / 180.0) * radius, #PB_Round_Nearest)
    LineXY(cx, cy, x, y)
    angle + stepDeg
  Wend
  
  ; Луч точно по конечной границе сектора - чтобы соседние сектора
  ; смыкались без зазора независимо от шага stepDeg.
  x = cx + Round(Cos((endAngle - 90.0) * #PI / 180.0) * radius, #PB_Round_Nearest)
  y = cy + Round(Sin((endAngle - 90.0) * #PI / 180.0) * radius, #PB_Round_Nearest)
  LineXY(cx, cy, x, y)
EndProcedure

Procedure UpdateTrayIcon()
  Protected activeCount.i, index.i, size.i, center.i, radius.i
  Protected startAngle.d, endAngle.d, sectorSize.d
  Protected okColor.i, failColor.i, unknownColor.i, borderColor.i
  Protected hasFail.i, hasUnknown.i
  Protected tooltip.s, failedNames.s, signature.s
  
  okColor = RGBA(0, 180, 0, 255)
  failColor = RGBA(220, 0, 0, 255)
  unknownColor = RGBA(140, 140, 140, 255)
  borderColor = RGBA(40, 40, 40, 255)
  
  ForEach Gateways()
    If Gateways()\enabled
      activeCount + 1
      signature + Gateways()\name + ":" + Str(Gateways()\state) + ";"
      If Gateways()\state = #GatewayStateFail
        hasFail = #True
        If failedNames <> "" : failedNames + ", " : EndIf
        failedNames + Gateways()\name
      ElseIf Gateways()\state = #GatewayStateUnknown
        hasUnknown = #True
      EndIf
    EndIf
  Next
  If signature = LastIconSignature And IsImage(#TrayImage)
    ProcedureReturn
  EndIf
  size = DesktopScaledX(16)
  If size < 16 : size = 16 : EndIf
  If size > 64 : size = 64 : EndIf
  center = size / 2
  radius = center - 1
  
  If IsImage(#TrayImage)
    FreeImage(#TrayImage)
  EndIf
  
  If Not CreateImage(#TrayImage, size, size, 32, #PB_Image_Transparent)
    ProcedureReturn
  EndIf
  
  If StartDrawing(ImageOutput(#TrayImage))
    DrawingMode(#PB_2DDrawing_AlphaBlend)
    Box(0, 0, size, size, RGBA(0, 0, 0, 0))
    
    If activeCount = 0
      DrawSector(center, center, radius, 0.0, 360.0, unknownColor)
    ElseIf activeCount > 16
      ; Маленькая иконка не различает десятки секторов: показываем худший статус.
      If hasFail
        DrawSector(center, center, radius, 0.0, 360.0, failColor)
      ElseIf hasUnknown
        DrawSector(center, center, radius, 0.0, 360.0, unknownColor)
      Else
        DrawSector(center, center, radius, 0.0, 360.0, okColor)
      EndIf
    Else
      sectorSize = 360.0 / activeCount
      ForEach Gateways()
        If Gateways()\enabled
          startAngle = index * sectorSize
          endAngle = startAngle + sectorSize
          Select Gateways()\state
            Case #GatewayStateOk
              DrawSector(center, center, radius, startAngle, endAngle, okColor)
            Case #GatewayStateFail
              DrawSector(center, center, radius, startAngle, endAngle, failColor)
            Default
              DrawSector(center, center, radius, startAngle, endAngle, unknownColor)
          EndSelect
          index + 1
        EndIf
      Next
    EndIf
    
    DrawingMode(#PB_2DDrawing_Outlined | #PB_2DDrawing_AlphaBlend)
    Circle(center, center, radius, borderColor)
    
    StopDrawing()
    LastIconSignature = signature
  EndIf
  
  If TrayAvailable And IsSysTrayIcon(#TrayIcon)
    ChangeSysTrayIcon(#TrayIcon, ImageID(#TrayImage))
  EndIf
  
  If activeCount = 0
    tooltip = #AppTitle + ": " + Text("TRAY_NO_ACTIVE")
  ElseIf hasFail
    tooltip = #AppTitle + ": FAIL — " + failedNames
  ElseIf hasUnknown
    tooltip = #AppTitle + ": " + Text("STATUS_CHECKING")
  Else
    tooltip = #AppTitle + ": OK"
  EndIf
  
  If TrayAvailable And IsSysTrayIcon(#TrayIcon)
    SysTrayIconToolTip(#TrayIcon, Left(tooltip, 127))
  EndIf
EndProcedure

Procedure RestoreTrayIcon()
  If IsSysTrayIcon(#TrayIcon)
    RemoveSysTrayIcon(#TrayIcon)
  EndIf
  TrayAvailable = Bool(AddSysTrayIcon(#TrayIcon, WindowID(#WindowMain), ImageID(#TrayImage)))
  If TrayAvailable
    LastIconSignature = Chr(1)
    UpdateTrayIcon()
  EndIf
EndProcedure

Procedure HideResponseGraph()
  If IsWindow(#WindowGraph)
    HideWindow(#WindowGraph, #True)
  EndIf
  GraphGatewayIndex = -1
EndProcedure

Procedure DrawResponseGraph(name.s, host.s, port.i)
  ; Верхняя зона — заголовок, нижняя — подписи оси X и статистика.
  ; Они не пересекаются с полем графика.
  Protected left.i = 38, top.i = 60, right.i = #GRAPH_WIDTH - 12, bottom.i = #GRAPH_HEIGHT - 52
  Protected width.i, height.i, maximumMs.i = 1, x.i, y.i, previousX.i, previousY.i
  Protected first.i = #True, sampleCount.i, okCount.i, failedCount.i
  Protected cutoff.q = Date() - #RESPONSE_RETENTION_SECONDS
  Protected position.d, valuePosition.d
  Protected caption.s
  
  LoadResponseSamples(name, host, port)
  ForEach GraphSamples()
    sampleCount + 1
    If GraphSamples()\tcpOk
      okCount + 1
    Else
      failedCount + 1
    EndIf
    If GraphSamples()\responseMs > maximumMs
      maximumMs = GraphSamples()\responseMs
    EndIf
  Next
  If maximumMs < 50
    maximumMs = 50
  EndIf
  
  width = right - left
  height = bottom - top
  If StartDrawing(CanvasOutput(#GraphCanvas))
    ; Явно задаём фон и прозрачный режим текста: иначе DrawText() рисует
    ; собственную подложку с системным цветом, которая в тёмной теме чёрная.
    DrawingMode(#PB_2DDrawing_Default)
    BackColor(RGB(255, 255, 255))
    Box(0, 0, #GRAPH_WIDTH, #GRAPH_HEIGHT, RGB(255, 255, 255))
    DrawingMode(#PB_2DDrawing_Transparent)
    If IsFont(#GraphFont)
      DrawingFont(FontID(#GraphFont))
    EndIf
    FrontColor(RGB(0, 0, 0))
    DrawText(10, 8, name + " — " + Text("GRAPH_RESPONSE_24H"))
    FrontColor(RGB(45, 45, 45))
    LineXY(left, top, left, bottom)
    LineXY(left, bottom, right, bottom)
    DrawText(left, bottom + 6, Text("GRAPH_24H_AGO"))
    DrawText(right - TextWidth(Text("GRAPH_NOW")), bottom + 6, Text("GRAPH_NOW"))
    ; Единица измерения идёт отдельной строкой под числом шкалы.
    DrawText(5, top - 30, Str(maximumMs))
    DrawText(8, top - 16, "ms")
    DrawText(14, bottom - 8, "0")
    
    If sampleCount = 0
      FrontColor(RGB(45, 45, 45))
      DrawText(left + 10, top + height / 2 - 8, Text("GRAPH_NO_SAMPLES"))
    Else
      ForEach GraphSamples()
        position = (GraphSamples()\recordedAt - cutoff) / #RESPONSE_RETENTION_SECONDS
        If position < 0.0 : position = 0.0 : EndIf
        If position > 1.0 : position = 1.0 : EndIf
        x = left + Round(position * width, #PB_Round_Nearest)
        valuePosition = GraphSamples()\responseMs / maximumMs
        If valuePosition > 1.0 : valuePosition = 1.0 : EndIf
        y = bottom - Round(valuePosition * height, #PB_Round_Nearest)
        
        If GraphSamples()\tcpOk
          FrontColor(RGB(0, 145, 0))
          If Not first
            LineXY(previousX, previousY, x, y)
          EndIf
          Circle(x, y, 2, RGB(0, 145, 0))
          previousX = x
          previousY = y
          first = #False
        Else
          FrontColor(RGB(210, 0, 0))
          LineXY(x, bottom, x, bottom - 9)
        EndIf
      Next
      caption = Text("GRAPH_SUCCESSFUL") + ": " + Str(okCount) + "   " + Text("GRAPH_ERRORS") + ": " + Str(failedCount)
      FrontColor(RGB(20, 20, 20))
      DrawText(left, #GRAPH_HEIGHT - 22, caption)
    EndIf
    StopDrawing()
  EndIf
EndProcedure

Procedure ShowResponseGraph(gatewayIndex.i)
  Protected x.i, y.i, mouseX.i, mouseY.i, desktopCount.i, desktop.i
  Protected desktopX.i, desktopY.i, desktopRight.i, desktopBottom.i
  
  If Not IsWindow(#WindowGraph)
    ProcedureReturn
  EndIf
  If gatewayIndex < 0 Or gatewayIndex >= ListSize(Gateways())
    HideResponseGraph()
    ProcedureReturn
  EndIf
  If GraphGatewayIndex = gatewayIndex And IsWindow(#WindowGraph)
    ProcedureReturn
  EndIf
  If Not SelectElement(Gateways(), gatewayIndex)
    HideResponseGraph()
    ProcedureReturn
  EndIf
  
  GraphGatewayIndex = gatewayIndex
  DrawResponseGraph(Gateways()\name, Gateways()\host, Gateways()\port)
  mouseX = DesktopMouseX()
  mouseY = DesktopMouseY()
  ; График открывается слева и выше курсора, чтобы не уходить за правую
  ; или нижнюю границу экрана при работе с иконкой в системном трее.
  x = mouseX - #GRAPH_WIDTH - 14
  y = mouseY - #GRAPH_HEIGHT - 14
  desktopCount = ExamineDesktops()
  For desktop = 0 To desktopCount - 1
    desktopX = DesktopX(desktop)
    desktopY = DesktopY(desktop)
    desktopRight = desktopX + DesktopWidth(desktop)
    desktopBottom = desktopY + DesktopHeight(desktop)
    If mouseX >= desktopX And mouseX < desktopRight And mouseY >= desktopY And mouseY < desktopBottom
      If x < desktopX : x = desktopX : EndIf
      If y < desktopY : y = desktopY : EndIf
      If x + #GRAPH_WIDTH > desktopRight : x = desktopRight - #GRAPH_WIDTH : EndIf
      If y + #GRAPH_HEIGHT > desktopBottom : y = desktopBottom - #GRAPH_HEIGHT : EndIf
      Break
    EndIf
  Next
  SetWindowPos_(WindowID(#WindowGraph), #HWND_TOPMOST, x, y, 0, 0, #SWP_NOSIZE | #SWP_NOACTIVATE | #SWP_SHOWWINDOW)
EndProcedure

Procedure TrayWindowCallback(hWnd.i, message.i, wParam.i, lParam.i)
  ; У SysTray-библиотеки нет события пересоздания панели задач Explorer.
  If message = TaskbarCreatedMessage
    PostEvent(#EventTaskbarCreated, #WindowMain, 0)
  ElseIf message = #WM_MENUSELECT
    If (wParam & $FFFF) >= #MenuGatewayBase And (wParam & $FFFF) < #MenuGatewayBase + ListSize(Gateways())
      ShowResponseGraph((wParam & $FFFF) - #MenuGatewayBase)
    Else
      HideResponseGraph()
    EndIf
  ElseIf message = #WM_EXITMENULOOP
    HideResponseGraph()
  EndIf
  ProcedureReturn #PB_ProcessPureBasicEvents
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
      status = Text("STATUS_DISABLED")
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
          status = Text("STATUS_CHECKING")
      EndSelect
    EndIf
    
    MenuItem(id, bullet + " " + ReplaceString(Gateways()\name, "&", "&&") + " — " + status + " — " + Gateways()\lastCheck)
    ; Пункт остаётся без команды при щелчке, но не отключается: Windows не
    ; гарантирует WM_MENUSELECT для отключённой строки, а оно нужно графику
    ; при наведении.
    
    id + 1
  Next
  
  MenuBar()
  MenuItem(#MenuOpenLog, Text("MENU_OPEN_LOG"))
  MenuItem(#MenuExportDatabase, Text("MENU_EXPORT_CSV"))
  MenuItem(#MenuReloadConfig, Text("MENU_RELOAD_CONFIG"))
  OpenSubMenu(Text("MENU_LANGUAGE"))
  id = #MenuLanguageBase
  ForEach Languages()
    If Languages()\code = LanguageCode
      MenuItem(id, "✓ " + Languages()\name)
    Else
      MenuItem(id, Languages()\name)
    EndIf
    id + 1
  Next
  CloseSubMenu()
  MenuBar()
  MenuItem(#MenuExit, Text("MENU_EXIT"))
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
    ApplyCheckResults()
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
  MessageRequester(#AppTitle, Text("DIALOG_ALREADY_RUNNING"), #PB_MessageRequester_Info)
  End
EndIf

StopMutex = CreateMutex()
If StopMutex = 0
  MessageRequester(#AppTitle, Text("DIALOG_STOP_MUTEX_ERROR"), #PB_MessageRequester_Error)
  CloseHandle_(AppMutex)
  End 1
EndIf

If Not LoadConfig()
  MessageRequester(#AppTitle, ConfigError, #PB_MessageRequester_Error)
  FreeMutex(StopMutex)
  CloseHandle_(AppMutex)
  End 1
EndIf

If Not OpenResponseDatabase()
  MessageRequester(#AppTitle, Text("DIALOG_DB_ERROR") + GetPathPart(ProgramFilename()) + "gateways.dat", #PB_MessageRequester_Warning)
EndIf

If Not OpenWindow(#WindowMain, 0, 0, 1, 1, #AppTitle, #PB_Window_Invisible)
  MessageRequester(#AppTitle, Text("DIALOG_WINDOW_ERROR"), #PB_MessageRequester_Error)
  FreeMutex(StopMutex)
  CloseHandle_(AppMutex)
  End 1
EndIf

If OpenWindow(#WindowGraph, 0, 0, #GRAPH_WIDTH, #GRAPH_HEIGHT, #AppTitle, #PB_Window_BorderLess | #PB_Window_Tool)
  CanvasGadget(#GraphCanvas, 0, 0, #GRAPH_WIDTH, #GRAPH_HEIGHT)
  LoadFont(#GraphFont, "Segoe UI", 8, #PB_Font_HighQuality)
  HideResponseGraph()
Else
  MessageRequester(#AppTitle, Text("DIALOG_GRAPH_WINDOW_ERROR"), #PB_MessageRequester_Warning)
EndIf

; WaitWindowEvent() не получает зарегистрированное сообщение TaskbarCreated как
; обычное событие PB; callback только передаёт его в главный цикл.
TaskbarCreatedMessage = RegisterWindowMessage_("TaskbarCreated")
SetWindowCallback(@TrayWindowCallback(), #WindowMain)
If Not CreateImage(#TrayImage, 16, 16, 32, #PB_Image_Transparent)
  MessageRequester(#AppTitle, Text("DIALOG_TRAY_ERROR"), #PB_MessageRequester_Error)
  CloseWindow(#WindowMain)
  FreeMutex(StopMutex)
  CloseHandle_(AppMutex)
  End 1
EndIf
RestoreTrayIcon()
AddWindowTimer(#WindowMain, #TimerTrayRetry, 5000)
WriteLog("APP START")

; Первый опрос тоже выполняется асинхронно. Пока он не завершён, активные
; шлюзы отображаются серым цветом без ложного FAIL/OK.
UpdateTrayIcon()
StartChecks()

AddWindowTimer(#WindowMain, #TimerCheck, CheckIntervalSec * 1000)

Define event.i
Define quit.i = #False

Repeat
  event = WaitWindowEvent()
  
  Select event
      
    Case #PB_Event_Timer
      If EventTimer() = #TimerTrayRetry
        If Not TrayAvailable Or Not IsSysTrayIcon(#TrayIcon)
          RestoreTrayIcon()
        EndIf
        ; Короткий таймер также подбирает результат, если PostEvent потерян.
        If CheckThreadID And Not IsThread(CheckThreadID)
          CompleteFinishedCheck()
        EndIf
      ElseIf EventTimer() = #TimerCheck
        ; Запускаем проверку в фоновом потоке, только если предыдущий
        ; цикл уже завершился - это исключает наложение проверок друг
        ; на друга при медленных/недоступных хостах и не блокирует
        ; главный поток (окно, меню, иконка) на время сетевых таймаутов.
        If ReloadPending
          If CheckThreadID And Not IsThread(CheckThreadID)
            CompleteFinishedCheck()
          EndIf
        ElseIf CheckThreadID = 0
          StartChecks()
        ElseIf Not IsThread(CheckThreadID)
          ; Резервный путь на случай, если PostEvent() не удалось поставить
          ; событие в очередь: не теряем готовые результаты.
          CompleteFinishedCheck()
          If Not ReloadPending
            StartChecks()
          EndIf
        EndIf
      EndIf
      
    Case #PB_Event_FirstCustomValue
      ; Устаревшее событие уже обработанного цикла не должно ожидать новый
      ; поток, который мог стартовать по таймеру.
      If EventGadget() = CheckGeneration
        CompleteFinishedCheck()
      EndIf

    Case #EventTaskbarCreated
      RestoreTrayIcon()
      
    Case #PB_Event_SysTray
      If EventGadget() = #TrayIcon And EventType() = #PB_EventType_RightClick
        RebuildPopupMenu()
        ; Для меню невидимого окна SetActiveWindow() не даёт нужного фокуса.
        SetForegroundWindow_(WindowID(#WindowMain))
        DisplayPopupMenu(#PopupMenu, WindowID(#WindowMain))
        PostMessage_(WindowID(#WindowMain), #WM_NULL, 0, 0)
      EndIf
      
    Case #PB_Event_Menu
      Select EventMenu()
          
        Case #MenuOpenLog
          OpenLogFile()

        Case #MenuExportDatabase
          ExportResponseDatabaseRequester()
          
        Case #MenuReloadConfig
          ReloadConfig()
          
        Case #MenuExit
          quit = #True

        Default
          If EventMenu() >= #MenuLanguageBase And EventMenu() < #MenuLanguageBase + ListSize(Languages())
            If SelectElement(Languages(), EventMenu() - #MenuLanguageBase)
              If SaveLanguagePreference(Languages()\code)
                ReloadConfig()
              EndIf
            EndIf
          EndIf
          
      EndSelect
      
  EndSelect
  
Until quit

; Ресурсы нельзя освобождать, пока поток использует CheckItems() и сетевую
; библиотеку. Ограниченный двухсекундный WaitThread здесь был небезопасен.
RequestCheckStop(#True)
If IsSysTrayIcon(#TrayIcon)
  RemoveSysTrayIcon(#TrayIcon)
EndIf
TrayAvailable = #False
If CheckThreadID
  WaitThread(CheckThreadID)
EndIf
WriteLog("APP STOP")
CloseResponseDatabase()
If IsWindow(#WindowGraph)
  CloseWindow(#WindowGraph)
EndIf
If IsFont(#GraphFont)
  FreeFont(#GraphFont)
EndIf
FreeMutex(StopMutex)

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
; DPIAware
; Thread
; UseIcon = gateways.ico
; Executable = gateways_v4_2.exe
