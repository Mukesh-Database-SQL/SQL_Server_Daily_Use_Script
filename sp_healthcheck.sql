/*
========================================================================
  sp_healthcheck - SQL Server Health Check Stored Procedure
  Author   : Mukesh Chaurasia (inspired by sp_Blitz by Brent Ozar)
  Version  : 1.0
  Created  : 2026
  Purpose  : Comprehensive SQL Server health check with deep server
             resource usage diagnostics (CPU, Memory, I/O, TempDB,
             Wait Stats, Blocking, Jobs, Index Health, etc.)
========================================================================
  OUTPUT SECTIONS:
    [1]  Priority Findings        – Critical issues (sp_Blitz style)
    [2]  CPU Usage                – Current + ring buffer CPU history
    [3]  Memory Usage             – PLE, Buffer Pool, Memory Clerks
    [4]  I/O Stats                – Per-file read/write latency
    [5]  TempDB Usage             – Session & task allocation
    [6]  Wait Statistics          – Top waits (filtered noise)
    [7]  Active Sessions          – Running + blocked sessions
    [8]  Blocking Chains          – Blocker → Victim detail
    [9]  Top Queries by CPU       – Cached plan resource consumers
    [10] Database Sizes           – Data/Log size & growth settings
    [11] Backup Status            – Last full/diff/log backup per DB
    [12] SQL Agent Job Health     – Failed jobs (last 24 hours)
    [13] Index Health             – Missing indexes + unused indexes
    [14] VLF Count                – Databases with excessive VLFs
    [15] Server Configuration     – Key sp_configure settings
========================================================================
  USAGE:
    EXEC sp_healthcheck                          -- all checks
    EXEC sp_healthcheck @ChecksToInclude = 'CPU,Memory,IO'
    EXEC sp_healthcheck @Debug = 1               -- print section headers
    EXEC sp_healthcheck @TopN = 20               -- show top 20 rows
========================================================================
*/

USE master;
GO

IF OBJECT_ID('dbo.sp_healthcheck', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_healthcheck;
GO

CREATE PROCEDURE dbo.sp_healthcheck
    @ChecksToInclude NVARCHAR(500) = 'ALL',   -- Comma-separated or 'ALL'
    @TopN            INT           = 10,       -- Rows per resource section
    @Debug           BIT           = 0        -- Print section headers
AS
BEGIN
    SET NOCOUNT ON;
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    /* ============================================================
       INTERNAL VARIABLES
    ============================================================ */
    DECLARE @NowUTC     DATETIME2 = SYSUTCDATETIME();
    DECLARE @ServerName NVARCHAR(128) = @@SERVERNAME;
    DECLARE @SQLVersion NVARCHAR(256) = @@VERSION;
    DECLARE @Uptime     NVARCHAR(50);
    DECLARE @SQL        NVARCHAR(MAX);
    DECLARE @Msg        NVARCHAR(256);

    /* Compute uptime */
    SELECT @Uptime = CONVERT(NVARCHAR(10), DATEDIFF(DAY, sqlserver_start_time, GETDATE()))
                   + ' days, '
                   + CONVERT(NVARCHAR(10), DATEDIFF(HOUR, sqlserver_start_time, GETDATE()) % 24)
                   + ' hrs'
    FROM sys.dm_os_sys_info;

    /* Helper: is section requested? */
    -- We normalise @ChecksToInclude to upper-case for comparison
    SET @ChecksToInclude = UPPER(@ChecksToInclude);

    /* ============================================================
       RESULT TABLE  (sp_Blitz–style findings)
    ============================================================ */
    IF OBJECT_ID('tempdb..#Findings') IS NOT NULL DROP TABLE #Findings;
    CREATE TABLE #Findings (
        FindingID   INT IDENTITY(1,1),
        Priority    TINYINT,          -- 1=Critical 2=Warning 3=Info
        Category    NVARCHAR(50),
        Finding     NVARCHAR(200),
        Details     NVARCHAR(2000),
        HowToFix    NVARCHAR(500)
    );

    /* ============================================================
       SECTION HEADER HELPER
    ============================================================ */
    IF @Debug = 1 PRINT '== sp_healthcheck starting on ' + @ServerName + ' ==';

    /* ============================================================
       [1]  PRIORITY FINDINGS  (sp_Blitz style checks)
    ============================================================ */
    IF @ChecksToInclude IN ('ALL') OR @ChecksToInclude LIKE '%FINDINGS%'
    BEGIN
        IF @Debug = 1 PRINT '[1] Running Priority Findings...';

        /* ---- 1a. Databases without FULL backup in last 7 days ---- */
        INSERT INTO #Findings (Priority, Category, Finding, Details, HowToFix)
        SELECT
            1,
            'Backup',
            'No Recent FULL Backup',
            'Database [' + d.name + '] last full backup: '
                + ISNULL(CONVERT(NVARCHAR(20), MAX(b.backup_finish_date), 120), 'NEVER'),
            'Run: BACKUP DATABASE [' + d.name + '] TO DISK = N''<path>'''
        FROM sys.databases d
        LEFT JOIN msdb.dbo.backupset b
            ON b.database_name = d.name
            AND b.type = 'D'
            AND b.backup_finish_date >= DATEADD(DAY, -7, GETDATE())
        WHERE d.database_id > 4          -- exclude system DBs
          AND d.state_desc = 'ONLINE'
          AND d.is_read_only = 0
        GROUP BY d.name
        HAVING MAX(b.backup_finish_date) IS NULL;

        /* ---- 1b. Databases with Auto-Shrink ON ---- */
        INSERT INTO #Findings (Priority, Category, Finding, Details, HowToFix)
        SELECT
            2,
            'Configuration',
            'Auto-Shrink Enabled',
            'Database [' + name + '] has AUTO_SHRINK = ON. Causes fragmentation & I/O spikes.',
            'ALTER DATABASE [' + name + '] SET AUTO_SHRINK OFF;'
        FROM sys.databases
        WHERE is_auto_shrink_on = 1
          AND database_id > 4;

        /* ---- 1c. Databases in SIMPLE recovery on production ---- */
        INSERT INTO #Findings (Priority, Category, Finding, Details, HowToFix)
        SELECT
            2,
            'Configuration',
            'Simple Recovery Model',
            'Database [' + name + '] is in SIMPLE recovery – point-in-time restore not possible.',
            'ALTER DATABASE [' + name + '] SET RECOVERY FULL;'
        FROM sys.databases
        WHERE recovery_model_desc = 'SIMPLE'
          AND database_id > 4
          AND name NOT IN ('tempdb');

        /* ---- 1d. Low Page Life Expectancy ---- */
        INSERT INTO #Findings (Priority, Category, Finding, Details, HowToFix)
        SELECT
            1,
            'Memory',
            'Low Page Life Expectancy',
            'PLE = ' + CONVERT(NVARCHAR(20), cntr_value)
                     + ' sec (threshold: 300s). Indicates memory pressure.',
            'Check memory grants, consider adding RAM or max server memory adjustment.'
        FROM sys.dm_os_performance_counters
        WHERE object_name LIKE '%Buffer Manager%'
          AND counter_name = 'Page life expectancy'
          AND cntr_value < 300;

        /* ---- 1e. tempdb with single data file ---- */
        INSERT INTO #Findings (Priority, Category, Finding, Details, HowToFix)
        SELECT
            2,
            'TempDB',
            'Single TempDB Data File',
            'TempDB has only 1 data file. Recommend 1 file per logical CPU core (max 8).',
            'Add TempDB data files: ALTER DATABASE tempdb ADD FILE (NAME=..., FILENAME=...)'
        WHERE (SELECT COUNT(*) FROM sys.master_files
               WHERE database_id = 2 AND type = 0) = 1;

        /* ---- 1f. Databases with compatibility level < instance ---- */
        INSERT INTO #Findings (Priority, Category, Finding, Details, HowToFix)
        SELECT
            3,
            'Configuration',
            'Old Compatibility Level',
            'Database [' + name + '] at compat level '
                + CONVERT(NVARCHAR(10), compatibility_level)
                + '. Instance supports higher.',
            'ALTER DATABASE [' + name + '] SET COMPATIBILITY_LEVEL = <latest>;'
        FROM sys.databases
        WHERE compatibility_level < (
            SELECT compatibility_level FROM sys.databases WHERE name = 'model'
        )
        AND database_id > 4;

        /* ---- 1g. Orphaned users ---- */
        -- (checks each DB dynamically)
        IF OBJECT_ID('tempdb..#OrphanedUsers') IS NOT NULL DROP TABLE #OrphanedUsers;
        CREATE TABLE #OrphanedUsers (DBName NVARCHAR(128), UserName NVARCHAR(128));

        EXEC sp_MSforeachdb N'
            USE [?];
            IF DB_ID() > 4
            INSERT INTO #OrphanedUsers
            SELECT DB_NAME(), dp.name
            FROM sys.database_principals dp
            LEFT JOIN sys.server_principals sp ON dp.sid = sp.sid
            WHERE dp.type IN (''S'',''U'',''G'')
              AND dp.name NOT IN (''dbo'',''guest'',''sys'',''INFORMATION_SCHEMA'')
              AND sp.sid IS NULL
              AND dp.authentication_type_desc = ''INSTANCE'';
        ';

        INSERT INTO #Findings (Priority, Category, Finding, Details, HowToFix)
        SELECT
            2,
            'Security',
            'Orphaned Users',
            'DB [' + DBName + '] has orphaned user: ' + UserName,
            'ALTER USER [' + UserName + '] WITH LOGIN = [<login>]; or DROP USER [' + UserName + '];'
        FROM #OrphanedUsers;

        /* ---- 1h. Max server memory = default (2147483647) ---- */
        INSERT INTO #Findings (Priority, Category, Finding, Details, HowToFix)
        SELECT
            1,
            'Memory',
            'Max Server Memory Not Configured',
            'Max server memory is set to default (2147483647 MB). SQL Server may consume all OS memory.',
            'EXEC sp_configure ''max server memory (MB)'', <recommended_MB>; RECONFIGURE;'
        FROM sys.configurations
        WHERE name = 'max server memory (MB)'
          AND CONVERT(INT, value_in_use) = 2147483647;

        /* ---- 1i. Instant File Initialization not enabled ---- */
        INSERT INTO #Findings (Priority, Category, Finding, Details, HowToFix)
        SELECT
            3,
            'Configuration',
            'Instant File Initialization Not Detected',
            'IFI cannot be checked via T-SQL directly. Verify SE_MANAGE_VOLUME_NAME privilege for SQL service account.',
            'Grant ''Perform Volume Maintenance Tasks'' privilege to SQL Server service account.'
        WHERE NOT EXISTS (
            SELECT 1 FROM sys.dm_server_services -- placeholder; real check needs xp_cmdshell or DMF
            WHERE 1 = 0
        ) AND 1 = 0; -- intentionally disabled placeholder; remove 'AND 1=0' to enable

        /* ---- 1j. Databases with page verification != CHECKSUM ---- */
        INSERT INTO #Findings (Priority, Category, Finding, Details, HowToFix)
        SELECT
            2,
            'Integrity',
            'Page Verification Not CHECKSUM',
            'Database [' + name + '] uses PAGE_VERIFY = ' + page_verify_option_desc + '.',
            'ALTER DATABASE [' + name + '] SET PAGE_VERIFY CHECKSUM;'
        FROM sys.databases
        WHERE page_verify_option_desc <> 'CHECKSUM'
          AND database_id > 2;

        /* Return findings */
        SELECT
            FindingID,
            CASE Priority WHEN 1 THEN '🔴 CRITICAL'
                          WHEN 2 THEN '🟠 WARNING'
                          ELSE        '🔵 INFO' END AS Severity,
            Category,
            Finding,
            Details,
            HowToFix
        FROM #Findings
        ORDER BY Priority, Category, FindingID;

    END -- [1] Priority Findings


    /* ============================================================
       [2]  CPU USAGE
    ============================================================ */
    IF @ChecksToInclude = 'ALL' OR @ChecksToInclude LIKE '%CPU%'
    BEGIN
        IF @Debug = 1 PRINT '[2] CPU Usage...';

        /* Current SQL CPU usage */
        SELECT
            'CURRENT CPU USAGE'                          AS Section,
            cpu_count                                    AS LogicalCPUs,
            scheduler_count                              AS OnlineSchedulers,
            -- process_kernel_time_ms and process_user_time_ms give cumulative CPU
            CAST(process_kernel_time_ms AS BIGINT)       AS KernelTime_ms,
            CAST(process_user_time_ms   AS BIGINT)       AS UserTime_ms,
            CAST((process_user_time_ms + process_kernel_time_ms) AS BIGINT) AS TotalCPUTime_ms
        FROM sys.dm_os_sys_info;

        /* Per-scheduler (NUMA / CPU) utilisation snapshot */
        SELECT TOP (@TopN)
            'PER SCHEDULER CPU'                          AS Section,
            scheduler_id,
            cpu_id,
            status,
            is_online,
            current_tasks_count                          AS CurrentTasks,
            runnable_tasks_count                         AS RunnableTasks,
            current_workers_count                        AS CurrentWorkers,
            active_workers_count                         AS ActiveWorkers,
            work_queue_count                             AS WorkQueueCount,
            pending_disk_io_count                        AS PendingDiskIO,
            load_factor                                  AS LoadFactor
        FROM sys.dm_os_schedulers
        WHERE status = 'VISIBLE ONLINE'
        ORDER BY load_factor DESC;

        /* Ring buffer CPU history (last 256 ticks ≈ 4 hrs) */
        ;WITH RingBuffer AS (
            SELECT
                record.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'INT') AS SQL_CPU_Util,
                record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]',          'INT') AS SystemIdle,
                100 - record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]',    'INT')
                    - record.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'INT')
                                                                                                     AS OtherProcess_CPU,
                DATEADD(ms,
                    -1 * (si.cpu_ticks / (si.cpu_ticks / si.ms_ticks) - record.value('(./Record/@id)[1]', 'BIGINT')),
                    GETDATE())                                                                        AS RecordTime
            FROM (
                SELECT CONVERT(XML, record) AS record
                FROM sys.dm_os_ring_buffers
                WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR'
                  AND record LIKE '% %'
            ) AS rb
            CROSS JOIN sys.dm_os_sys_info si
        )
        SELECT TOP (30)
            'CPU HISTORY (Ring Buffer)'                  AS Section,
            CONVERT(NVARCHAR(20), RecordTime, 120)       AS SampleTime,
            SQL_CPU_Util                                 AS SQL_CPU_Pct,
            SystemIdle                                   AS Idle_Pct,
            OtherProcess_CPU                             AS OtherProcess_Pct,
            100 - SystemIdle                             AS Total_CPU_Pct
        FROM RingBuffer
        ORDER BY RecordTime DESC;

    END -- [2] CPU


    /* ============================================================
       [3]  MEMORY USAGE
    ============================================================ */
    IF @ChecksToInclude = 'ALL' OR @ChecksToInclude LIKE '%MEMORY%'
    BEGIN
        IF @Debug = 1 PRINT '[3] Memory Usage...';

        /* Server memory summary */
        SELECT
            'MEMORY SUMMARY'                                             AS Section,
            physical_memory_in_use_kb / 1024                            AS PhysMemInUse_MB,
            locked_page_allocations_kb / 1024                           AS LockedPages_MB,
            virtual_address_space_committed_kb / 1024                   AS VAC_MB,
            page_fault_count                                            AS PageFaultCount,
            memory_utilization_percentage                               AS MemUtilPct
        FROM sys.dm_os_process_memory;

        /* PLE – Page Life Expectancy per NUMA node */
        SELECT
            'PAGE LIFE EXPECTANCY'                                       AS Section,
            object_name,
            instance_name,
            cntr_value                                                   AS PLE_Seconds,
            CASE WHEN cntr_value < 300 THEN 'CRITICAL ❌'
                 WHEN cntr_value < 1000 THEN 'WARNING ⚠'
                 ELSE 'HEALTHY ✅' END                                   AS Status
        FROM sys.dm_os_performance_counters
        WHERE counter_name = 'Page life expectancy'
          AND object_name LIKE '%Buffer Manager%' OR object_name LIKE '%Buffer Node%';

        /* Buffer Pool usage per database */
        SELECT TOP (@TopN)
            'BUFFER POOL BY DATABASE'                                    AS Section,
            ISNULL(DB_NAME(database_id), 'ResourceDB')                   AS DatabaseName,
            COUNT(*) * 8 / 1024                                          AS BufferPool_MB,
            CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2)) AS BufferPool_Pct
        FROM sys.dm_os_buffer_descriptors
        GROUP BY database_id
        ORDER BY BufferPool_MB DESC;

        /* Top memory clerks */
        SELECT TOP (@TopN)
            'MEMORY CLERKS'                                              AS Section,
            type,
            name,
            SUM(pages_kb) / 1024                                         AS MemoryUsed_MB
        FROM sys.dm_os_memory_clerks
        GROUP BY type, name
        ORDER BY MemoryUsed_MB DESC;

        /* Memory grants (pending + active) */
        SELECT
            'MEMORY GRANTS'                                              AS Section,
            SUM(granted_memory_kb) / 1024                               AS TotalGranted_MB,
            SUM(required_memory_kb) / 1024                              AS TotalRequired_MB,
            SUM(requested_memory_kb) / 1024                             AS TotalRequested_MB,
            COUNT(*)                                                     AS ActiveGrants,
            MAX(wait_time_ms)                                            AS MaxWaitTime_ms
        FROM sys.dm_exec_query_memory_grants;

    END -- [3] Memory


    /* ============================================================
       [4]  I/O STATISTICS
    ============================================================ */
    IF @ChecksToInclude = 'ALL' OR @ChecksToInclude LIKE '%IO%'
    BEGIN
        IF @Debug = 1 PRINT '[4] I/O Stats...';

        SELECT TOP (@TopN)
            'IO STATS PER FILE'                                          AS Section,
            DB_NAME(f.database_id)                                       AS DatabaseName,
            f.physical_name                                              AS FileName,
            f.type_desc                                                  AS FileType,
            vfs.io_stall_read_ms,
            vfs.num_of_reads,
            CASE WHEN vfs.num_of_reads > 0
                 THEN vfs.io_stall_read_ms / vfs.num_of_reads
                 ELSE 0 END                                              AS AvgReadLatency_ms,
            vfs.io_stall_write_ms,
            vfs.num_of_writes,
            CASE WHEN vfs.num_of_writes > 0
                 THEN vfs.io_stall_write_ms / vfs.num_of_writes
                 ELSE 0 END                                              AS AvgWriteLatency_ms,
            (vfs.num_of_bytes_read + vfs.num_of_bytes_written) / 1048576 AS TotalIO_MB,
            CASE WHEN (vfs.io_stall_read_ms / NULLIF(vfs.num_of_reads,0)) > 50
                   OR (vfs.io_stall_write_ms / NULLIF(vfs.num_of_writes,0)) > 50
                 THEN '⚠ HIGH LATENCY'
                 ELSE '✅ OK' END                                        AS LatencyStatus
        FROM sys.dm_io_virtual_file_stats(NULL, NULL) vfs
        INNER JOIN sys.master_files f
            ON f.database_id = vfs.database_id
            AND f.file_id    = vfs.file_id
        ORDER BY (vfs.io_stall_read_ms + vfs.io_stall_write_ms) DESC;

    END -- [4] I/O


    /* ============================================================
       [5]  TEMPDB USAGE
    ============================================================ */
    IF @ChecksToInclude = 'ALL' OR @ChecksToInclude LIKE '%TEMPDB%'
    BEGIN
        IF @Debug = 1 PRINT '[5] TempDB Usage...';

        /* TempDB file sizes */
        SELECT
            'TEMPDB FILES'                                               AS Section,
            name,
            physical_name,
            type_desc,
            size * 8 / 1024                                              AS CurrentSize_MB,
            max_size * 8 / 1024                                          AS MaxSize_MB,
            CASE is_percent_growth WHEN 1 THEN CONVERT(NVARCHAR,growth) + '%'
                                   ELSE CONVERT(NVARCHAR, growth*8/1024) + ' MB'
            END                                                          AS AutoGrowth
        FROM tempdb.sys.database_files;

        /* Space allocation summary */
        SELECT
            'TEMPDB SPACE SUMMARY'                                       AS Section,
            SUM(unallocated_extent_page_count) * 8 / 1024               AS FreeSpace_MB,
            SUM(internal_object_reserved_page_count) * 8 / 1024         AS InternalObjects_MB,
            SUM(user_object_reserved_page_count) * 8 / 1024             AS UserObjects_MB,
            SUM(version_store_reserved_page_count) * 8 / 1024           AS VersionStore_MB
        FROM sys.dm_db_file_space_usage
        WHERE database_id = 2;

        /* Top TempDB consumers by session */
        SELECT TOP (@TopN)
            'TOP TEMPDB CONSUMERS'                                       AS Section,
            tsu.session_id,
            es.login_name,
            es.program_name,
            es.host_name,
            (tsu.user_objects_alloc_page_count - tsu.user_objects_dealloc_page_count) * 8 AS UserObjects_KB,
            (tsu.internal_objects_alloc_page_count - tsu.internal_objects_dealloc_page_count) * 8 AS InternalObjects_KB,
            es.status,
            es.last_request_start_time
        FROM sys.dm_db_session_space_usage tsu
        INNER JOIN sys.dm_exec_sessions es ON es.session_id = tsu.session_id
        WHERE tsu.session_id > 50
        ORDER BY (tsu.user_objects_alloc_page_count + tsu.internal_objects_alloc_page_count) DESC;

    END -- [5] TempDB


    /* ============================================================
       [6]  WAIT STATISTICS  (filtered: removes benign waits)
    ============================================================ */
    IF @ChecksToInclude = 'ALL' OR @ChecksToInclude LIKE '%WAIT%'
    BEGIN
        IF @Debug = 1 PRINT '[6] Wait Statistics...';

        ;WITH Waits AS (
            SELECT
                wait_type,
                waiting_tasks_count,
                wait_time_ms,
                signal_wait_time_ms,
                wait_time_ms - signal_wait_time_ms                       AS resource_wait_time_ms,
                CAST(100.0 * wait_time_ms
                     / SUM(wait_time_ms) OVER ()  AS DECIMAL(5,2))      AS WaitPct
            FROM sys.dm_os_wait_stats
            WHERE wait_type NOT IN (
                -- Benign waits to exclude (SQL Server idle waits)
                'SLEEP_TASK','BROKER_TO_FLUSH','BROKER_TASK_STOP',
                'CLR_AUTO_EVENT','DISPATCHER_QUEUE_SEMAPHORE',
                'FT_IFTS_SCHEDULER_IDLE_WAIT','HADR_FILESTREAM_IOMGR_IOCOMPLETION',
                'HADR_WORK_QUEUE','LAZYWRITER_SLEEP','LOGMGR_QUEUE',
                'ONDEMAND_TASK_QUEUE','REQUEST_FOR_DEADLOCK_SEARCH',
                'RESOURCE_QUEUE','SERVER_IDLE_CHECK','SLEEP_DBSTARTUP',
                'SLEEP_DCOMSTARTUP','SLEEP_MASTERDBREADY','SLEEP_MASTERMDREADY',
                'SLEEP_MASTERUPGRADED','SLEEP_MSDBSTARTUP','SLEEP_SYSTEMTASK',
                'SLEEP_TEMPDBSTARTUP','SNI_HTTP_ACCEPT','SP_SERVER_DIAGNOSTICS_SLEEP',
                'SQLAGENT_ALERT_SCHEDULER_IDLE','SQLAGENT_ALERTLOG_IOCOMPLETION_WAIT',
                'SQLAGENT_SHUTDOWN_SLEEP','SQLAGENT_WAIT_FOR_SHUTDOWN',
                'WAIT_XTP_OFFLINE_CKPT_NEW_LOG','XE_DISPATCHER_WAIT',
                'XE_TIMER_EVENT','WAITFOR','BROKER_EVENTHANDLER',
                'CHECKPOINT_QUEUE','DBMIRROR_EVENTS_QUEUE','SQLAGENT_STEPS_THREAD',
                'CLR_QUANTUM_TASK','RESOURCE_GOVERNOR_IDLE','XE_DISPATCHER_JOIN',
                'DIRTY_PAGE_POLL','HADR_CLUSAPI_CALL','HADR_FILESTREAM_IOMGR_IOCOMPLETION',
                'HADR_TIMER_TASK','HADR_WORK_QUEUE','UCS_SESSION_REGISTRATION',
                'SNI_HTTP_ACCEPT','SOSHOST_INTERNAL','SLEEP_DBSTARTUP'
            )
            AND wait_time_ms > 0
        )
        SELECT TOP (@TopN)
            'WAIT STATISTICS'                                            AS Section,
            wait_type,
            waiting_tasks_count,
            wait_time_ms,
            resource_wait_time_ms,
            signal_wait_time_ms                                          AS CPUQueue_WaitTime_ms,
            CAST(wait_time_ms * 1.0
                 / NULLIF(waiting_tasks_count,0) AS DECIMAL(10,2))      AS AvgWait_ms,
            WaitPct                                                      AS WaitPercent
        FROM Waits
        ORDER BY wait_time_ms DESC;

    END -- [6] Wait Stats


    /* ============================================================
       [7]  ACTIVE SESSIONS  (running + blocked)
    ============================================================ */
    IF @ChecksToInclude = 'ALL' OR @ChecksToInclude LIKE '%SESSION%'
    BEGIN
        IF @Debug = 1 PRINT '[7] Active Sessions...';

        SELECT TOP (@TopN)
            'ACTIVE SESSIONS'                                            AS Section,
            es.session_id,
            es.status,
            COALESCE(er.blocking_session_id, 0)                                       AS BlockedBy,
            es.login_name,
            es.host_name,
            es.program_name,
            es.database_id,
            DB_NAME(es.database_id)                                      AS DatabaseName,
            es.cpu_time                                                  AS CPU_ms,
            es.logical_reads,
            es.reads                                                     AS PhysicalReads,
            es.writes,
            es.memory_usage * 8                                          AS Memory_KB,
            er.wait_type,
            er.wait_time                                                 AS WaitTime_ms,
            er.last_wait_type,
            SUBSTRING(st.text, (er.statement_start_offset/2)+1,
                ((CASE er.statement_end_offset WHEN -1 THEN DATALENGTH(st.text)
                  ELSE er.statement_end_offset END - er.statement_start_offset)/2)+1)
                                                                         AS CurrentStatement,
            es.last_request_start_time
        FROM sys.dm_exec_sessions es
        LEFT JOIN sys.dm_exec_requests er ON er.session_id = es.session_id
        OUTER APPLY sys.dm_exec_sql_text(er.sql_handle) st
        WHERE es.is_user_process = 1
          AND es.status <> 'sleeping'
        ORDER BY es.cpu_time DESC;

    END -- [7] Active Sessions


    /* ============================================================
       [8]  BLOCKING CHAINS
    ============================================================ */
    IF @ChecksToInclude = 'ALL' OR @ChecksToInclude LIKE '%BLOCK%'
    BEGIN
        IF @Debug = 1 PRINT '[8] Blocking Chains...';

        ;WITH BlockingTree AS (
            SELECT
                es.session_id,
                er.blocking_session_id,
                es.login_name,
                es.host_name,
                DB_NAME(er.database_id)                                  AS DatabaseName,
                er.wait_type,
                er.wait_time / 1000                                      AS WaitSec,
                er.status,
                CAST(SUBSTRING(st.text, (er.statement_start_offset/2)+1,
                    ((CASE er.statement_end_offset WHEN -1 THEN DATALENGTH(st.text)
                      ELSE er.statement_end_offset END
                      - er.statement_start_offset)/2)+1)
                AS NVARCHAR(500))                                         AS BlockedSQL,
                0                                                        AS Level,
                CAST(es.session_id AS NVARCHAR(100))                     AS Chain
            FROM sys.dm_exec_sessions es
            INNER JOIN sys.dm_exec_requests er ON er.session_id = es.session_id
            OUTER APPLY sys.dm_exec_sql_text(er.sql_handle) st
            WHERE er.blocking_session_id > 0
        )
        SELECT
            'BLOCKING CHAINS'                                            AS Section,
            session_id                                                   AS VictimSession,
            blocking_session_id                                          AS BlockerSession,
            login_name,
            host_name,
            DatabaseName,
            wait_type,
            WaitSec                                                      AS WaitSeconds,
            status,
            BlockedSQL
        FROM BlockingTree
        ORDER BY WaitSec DESC;

    END -- [8] Blocking


    /* ============================================================
       [9]  TOP QUERIES BY CPU  (Plan Cache)
    ============================================================ */
    IF @ChecksToInclude = 'ALL' OR @ChecksToInclude LIKE '%QUERY%'
    BEGIN
        IF @Debug = 1 PRINT '[9] Top Queries by CPU...';

        SELECT TOP (@TopN)
            'TOP QUERIES BY CPU'                                         AS Section,
            qs.total_worker_time / 1000                                  AS TotalCPU_ms,
            qs.execution_count,
            CAST(qs.total_worker_time * 1.0
                 / NULLIF(qs.execution_count,0) / 1000 AS DECIMAL(10,2)) AS AvgCPU_ms,
            qs.total_logical_reads                                       AS TotalLogicalReads,
            CAST(qs.total_logical_reads * 1.0
                 / NULLIF(qs.execution_count,0) AS DECIMAL(12,0))       AS AvgLogicalReads,
            qs.total_elapsed_time / 1000                                 AS TotalElapsed_ms,
            qs.plan_generation_num,
            DB_NAME(st.dbid)                                             AS DatabaseName,
            OBJECT_NAME(st.objectid, st.dbid)                           AS ObjectName,
            SUBSTRING(st.text, (qs.statement_start_offset/2)+1,
                ((CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(st.text)
                  ELSE qs.statement_end_offset END
                  - qs.statement_start_offset)/2)+1)                     AS QueryText
        FROM sys.dm_exec_query_stats qs
        CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
        WHERE st.dbid NOT IN (1,2,3,4)   -- exclude system DBs
        ORDER BY qs.total_worker_time DESC;

    END -- [9] Top Queries


    /* ============================================================
       [10] DATABASE SIZES & GROWTH SETTINGS
    ============================================================ */
    IF @ChecksToInclude = 'ALL' OR @ChecksToInclude LIKE '%DB%' OR @ChecksToInclude LIKE '%SIZE%'
    BEGIN
        IF @Debug = 1 PRINT '[10] Database Sizes...';

        SELECT
            'DATABASE SIZES'                                             AS Section,
            d.name                                                       AS DatabaseName,
            d.state_desc,
            d.recovery_model_desc,
            d.compatibility_level,
            SUM(CASE WHEN mf.type = 0 THEN mf.size END) * 8 / 1024     AS DataSize_MB,
            SUM(CASE WHEN mf.type = 1 THEN mf.size END) * 8 / 1024     AS LogSize_MB,
            (SUM(mf.size) * 8 / 1024)                                   AS TotalSize_MB,
            d.log_reuse_wait_desc                                        AS LogReuseWait
        FROM sys.databases d
        INNER JOIN sys.master_files mf ON mf.database_id = d.database_id
        GROUP BY d.name, d.state_desc, d.recovery_model_desc,
                 d.compatibility_level, d.log_reuse_wait_desc
        ORDER BY TotalSize_MB DESC;

    END -- [10] DB Sizes


    /* ============================================================
       [11] BACKUP STATUS
    ============================================================ */
    IF @ChecksToInclude = 'ALL' OR @ChecksToInclude LIKE '%BACKUP%'
    BEGIN
        IF @Debug = 1 PRINT '[11] Backup Status...';

        SELECT
            'BACKUP STATUS'                                              AS Section,
            d.name                                                       AS DatabaseName,
            MAX(CASE b.type WHEN 'D' THEN b.backup_finish_date END)     AS LastFullBackup,
            DATEDIFF(HOUR,
                MAX(CASE b.type WHEN 'D' THEN b.backup_finish_date END),
                GETDATE())                                               AS HoursSinceFullBackup,
            MAX(CASE b.type WHEN 'I' THEN b.backup_finish_date END)     AS LastDiffBackup,
            MAX(CASE b.type WHEN 'L' THEN b.backup_finish_date END)     AS LastLogBackup,
            CASE WHEN MAX(CASE b.type WHEN 'D' THEN b.backup_finish_date END) IS NULL
                 THEN '🔴 NEVER BACKED UP'
                 WHEN DATEDIFF(HOUR,
                      MAX(CASE b.type WHEN 'D' THEN b.backup_finish_date END),
                      GETDATE()) > 168
                 THEN '🔴 > 7 DAYS OLD'
                 WHEN DATEDIFF(HOUR,
                      MAX(CASE b.type WHEN 'D' THEN b.backup_finish_date END),
                      GETDATE()) > 24
                 THEN '🟠 > 1 DAY OLD'
                 ELSE '✅ RECENT' END                                    AS BackupStatus
        FROM sys.databases d
        LEFT JOIN msdb.dbo.backupset b ON b.database_name = d.name
        WHERE d.database_id > 4
          AND d.state_desc = 'ONLINE'
        GROUP BY d.name
        ORDER BY LastFullBackup ASC;

    END -- [11] Backup Status


    /* ============================================================
       [12] SQL AGENT JOB HEALTH (last 24 hours)
    ============================================================ */
    IF @ChecksToInclude = 'ALL' OR @ChecksToInclude LIKE '%JOB%'
    BEGIN
        IF @Debug = 1 PRINT '[12] SQL Agent Jobs...';

        SELECT TOP (@TopN)
            'SQL AGENT JOB HEALTH'                                       AS Section,
            j.name                                                       AS JobName,
            j.enabled                                                    AS IsEnabled,
            CASE jh.run_status
                WHEN 0 THEN '🔴 FAILED'
                WHEN 1 THEN '✅ SUCCEEDED'
                WHEN 2 THEN '🟠 RETRY'
                WHEN 3 THEN '⚫ CANCELLED'
                WHEN 4 THEN '🔵 IN PROGRESS'
                ELSE 'UNKNOWN'
            END                                                          AS LastRunStatus,
            CONVERT(DATETIME,
                CONVERT(NVARCHAR(8), jh.run_date) + ' '
                + STUFF(STUFF(RIGHT('000000' + CONVERT(NVARCHAR(6), jh.run_time), 6), 3, 0, ':'), 6, 0, ':'))
                                                                         AS LastRunTime,
            jh.message                                                   AS ResultMessage,
            STUFF(STUFF(RIGHT('000000' + CONVERT(NVARCHAR(6),jh.run_duration), 6), 3, 0, ':'), 6, 0, ':')
                                                                         AS RunDuration_HHMMSS,
            s.next_run_date,
            s.next_run_time
        FROM msdb.dbo.sysjobs j
        LEFT JOIN (
            SELECT job_id,
                   MAX(instance_id) AS LastInstanceID
            FROM msdb.dbo.sysjobhistory
            WHERE step_id = 0
            GROUP BY job_id
        ) latest ON latest.job_id = j.job_id
        LEFT JOIN msdb.dbo.sysjobhistory jh
            ON jh.job_id = j.job_id
            AND jh.instance_id = latest.LastInstanceID
        LEFT JOIN (
            SELECT job_id, next_run_date, next_run_time
            FROM msdb.dbo.sysjobschedules
        ) s ON s.job_id = j.job_id
        ORDER BY
            CASE jh.run_status WHEN 0 THEN 0 ELSE 1 END, -- failed jobs first
            jh.run_date DESC,
            jh.run_time DESC;

    END -- [12] SQL Agent Jobs


    /* ============================================================
       [13] INDEX HEALTH
    ============================================================ */
    IF @ChecksToInclude = 'ALL' OR @ChecksToInclude LIKE '%INDEX%'
    BEGIN
        IF @Debug = 1 PRINT '[13] Index Health...';

        /* Missing Index suggestions (from DMV) */
        SELECT TOP (@TopN)
            'MISSING INDEXES'                                            AS Section,
            mid.database_id,
            DB_NAME(mid.database_id)                                     AS DatabaseName,
            OBJECT_NAME(mid.object_id, mid.database_id)                 AS TableName,
            migs.avg_total_user_cost
                * migs.avg_user_impact
                * (migs.user_seeks + migs.user_scans)                   AS ImprovementScore,
            mid.equality_columns,
            mid.inequality_columns,
            mid.included_columns,
            migs.user_seeks,
            migs.user_scans,
            migs.last_user_seek,
            migs.avg_user_impact                                         AS EstImprovementPct,
            'CREATE INDEX [IX_' + OBJECT_NAME(mid.object_id, mid.database_id)
                + '_Missing_' + CONVERT(NVARCHAR(10), mid.index_handle)
                + '] ON '
                + mid.statement
                + ' (' + ISNULL(mid.equality_columns,'')
                + CASE WHEN mid.inequality_columns IS NOT NULL
                       THEN (CASE WHEN mid.equality_columns IS NOT NULL THEN ',' ELSE '' END)
                            + mid.inequality_columns ELSE '' END + ')'
                + ISNULL(' INCLUDE (' + mid.included_columns + ')','')  AS SuggestedCreateStatement
        FROM sys.dm_db_missing_index_details mid
        INNER JOIN sys.dm_db_missing_index_groups mig
            ON mig.index_handle = mid.index_handle
        INNER JOIN sys.dm_db_missing_index_group_stats migs
            ON migs.group_handle = mig.index_group_handle
        ORDER BY ImprovementScore DESC;

        /* Unused Indexes */
        SELECT TOP (@TopN)
            'UNUSED INDEXES'                                             AS Section,
            DB_NAME()                                                    AS DatabaseName,
            OBJECT_NAME(i.object_id)                                     AS TableName,
            i.name                                                       AS IndexName,
            i.type_desc,
            ius.user_seeks,
            ius.user_scans,
            ius.user_lookups,
            ius.user_updates,
            ius.last_user_seek,
            ius.last_user_scan,
            'DROP INDEX [' + i.name + '] ON ['
                + OBJECT_NAME(i.object_id) + '];'                       AS DropStatement
        FROM sys.indexes i
        INNER JOIN sys.dm_db_index_usage_stats ius
            ON ius.object_id = i.object_id
            AND ius.index_id = i.index_id
            AND ius.database_id = DB_ID()
        WHERE i.type_desc NOT IN ('HEAP','CLUSTERED')
          AND ius.user_seeks = 0
          AND ius.user_scans = 0
          AND ius.user_lookups = 0
          AND ius.user_updates > 0        -- only writing, never reading = overhead
          AND OBJECTPROPERTY(i.object_id, 'IsUserTable') = 1
        ORDER BY ius.user_updates DESC;

    END -- [13] Index Health


    /* ============================================================
       [14] VLF COUNT  (Virtual Log Files)
    ============================================================ */
    IF @ChecksToInclude = 'ALL' OR @ChecksToInclude LIKE '%VLF%'
    BEGIN
        IF @Debug = 1 PRINT '[14] VLF Count...';

        IF OBJECT_ID('tempdb..#VLFs') IS NOT NULL DROP TABLE #VLFs;
        CREATE TABLE #VLFs (
            DatabaseName NVARCHAR(128),
            VLFCount     INT
        );

        EXEC sp_MSforeachdb N'
            USE [?];
            DECLARE @cnt INT;
            SELECT @cnt = COUNT(*) FROM sys.dm_db_log_info(DB_ID());
            IF DB_ID() > 4
                INSERT INTO #VLFs VALUES (DB_NAME(), @cnt);
        ';

        SELECT
            'VLF COUNT'                                                  AS Section,
            DatabaseName,
            VLFCount,
            CASE WHEN VLFCount > 1000 THEN '🔴 CRITICAL (>1000)'
                 WHEN VLFCount > 500  THEN '🟠 HIGH (>500)'
                 WHEN VLFCount > 100  THEN '🟡 ELEVATED (>100)'
                 ELSE '✅ OK' END                                        AS Status,
            'DBCC SHRINKFILE (N''<logfile>'', 1); ALTER DATABASE [' + DatabaseName
                + '] MODIFY FILE (NAME=N''<logfile>'', SIZE=<appropriate_size>MB);'
                                                                         AS RemediationHint
        FROM #VLFs
        ORDER BY VLFCount DESC;

    END -- [14] VLF


    /* ============================================================
       [15] SERVER CONFIGURATION REVIEW
    ============================================================ */
    IF @ChecksToInclude = 'ALL' OR @ChecksToInclude LIKE '%CONFIG%'
    BEGIN
        IF @Debug = 1 PRINT '[15] Server Configuration...';

        SELECT
            'SERVER CONFIGURATION'                                       AS Section,
            name,
            description,
            CONVERT(NVARCHAR(50), value_in_use)                         AS CurrentValue,
            CONVERT(NVARCHAR(50), minimum)                              AS MinAllowed,
            CONVERT(NVARCHAR(50), maximum)                              AS MaxAllowed,
            is_dynamic,
            is_advanced
        FROM sys.configurations
        WHERE name IN (
            'max server memory (MB)',
            'min server memory (MB)',
            'max degree of parallelism',
            'cost threshold for parallelism',
            'optimize for ad hoc workloads',
            'remote admin connections',
            'backup compression default',
            'clr enabled',
            'cross db ownership chaining',
            'Database Mail XPs',
            'xp_cmdshell',
            'show advanced options',
            'fill factor (%)',
            'blocked process threshold (s)',
            'lightweight pooling',
            'priority boost',
            'index create memory (KB)',
            'min memory per query (KB)',
            'network packet size (B)',
            'remote login timeout (s)'
        )
        ORDER BY name;

        /* Summary header line */
        SELECT
            'SERVER INFO SUMMARY'                                        AS Section,
            @ServerName                                                  AS ServerName,
            @SQLVersion                                                  AS SQLVersion,
            @Uptime                                                      AS Uptime,
            @NowUTC                                                      AS CheckRunTime_UTC,
            (SELECT physical_memory_kb / 1024 FROM sys.dm_os_sys_info)  AS TotalRAM_MB,
            (SELECT cpu_count FROM sys.dm_os_sys_info)                   AS LogicalCPUs,
            (SELECT cntr_value
             FROM sys.dm_os_performance_counters
             WHERE counter_name = 'Page life expectancy'
               AND object_name LIKE '%Buffer Manager%')                  AS PLE_Current,
            (SELECT COUNT(*) FROM sys.databases WHERE state_desc='ONLINE') AS OnlineDatabases,
            (SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE is_user_process=1) AS UserSessions;

    END -- [15] Config

    /* ============================================================
       CLEANUP
    ============================================================ */
    IF OBJECT_ID('tempdb..#Findings')      IS NOT NULL DROP TABLE #Findings;
    IF OBJECT_ID('tempdb..#OrphanedUsers') IS NOT NULL DROP TABLE #OrphanedUsers;
    IF OBJECT_ID('tempdb..#VLFs')          IS NOT NULL DROP TABLE #VLFs;

    IF @Debug = 1 PRINT '== sp_healthcheck complete ==';

END -- Procedure
GO

/* ================================================================
   GRANT EXECUTE (adjust role/login as needed)
================================================================ */
-- GRANT EXECUTE ON dbo.sp_healthcheck TO [<YourMonitoringLogin>];
-- GO

/* ================================================================
   QUICK USAGE EXAMPLES
================================================================

-- Full health check (all 15 sections):
EXEC dbo.sp_healthcheck;

-- Only CPU + Memory + IO:
EXEC dbo.sp_healthcheck @ChecksToInclude = 'CPU,MEMORY,IO';

-- Findings + Backup only, top 20 rows per section:
EXEC dbo.sp_healthcheck @ChecksToInclude = 'FINDINGS,BACKUP', @TopN = 20;

-- Debug mode (prints section headers in Messages tab):
EXEC dbo.sp_healthcheck @Debug = 1;

================================================================ */
