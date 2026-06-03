-- ============================================================
-- Stored Procedure : SP_PLECHECK
-- Description      : Comprehensive Page Life Expectancy (PLE)
--                    Diagnostic, Root Cause Analysis & Fix Guide
-- Author           : DBA Team
-- Version          : 1.0
-- Compatibility    : SQL Server 2012 and above
-- ============================================================
-- USAGE:
--   EXEC SP_PLECHECK                        -- Full analysis
--   EXEC SP_PLECHECK @Mode = 'QUICK'        -- Quick PLE snapshot only
--   EXEC SP_PLECHECK @Mode = 'MEMORY'       -- Memory pressure analysis
--   EXEC SP_PLECHECK @Mode = 'QUERIES'      -- Top memory-consuming queries
--   EXEC SP_PLECHECK @Mode = 'INDEXES'      -- Missing/unused indexes
--   EXEC SP_PLECHECK @Mode = 'WAITS'        -- Wait stats related to memory
--   EXEC SP_PLECHECK @Mode = 'FIX'          -- Fix recommendations only
--   EXEC SP_PLECHECK @PLEThreshold = 1000   -- Custom PLE warning threshold
-- ============================================================

CREATE OR ALTER PROCEDURE SP_PLECHECK
    @Mode           NVARCHAR(20) = 'FULL',      -- FULL | QUICK | MEMORY | QUERIES | INDEXES | WAITS | FIX
    @PLEThreshold   INT          = 300,          -- Alert threshold (default 300s; enterprise: 1000s+)
    @TopN           INT          = 20,           -- Top N rows for query/index sections
    @Debug          BIT          = 0             -- 1 = print section headers to messages
AS
BEGIN
    SET NOCOUNT ON;
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;  -- Minimise impact on production
    SET ARITHABORT  OFF;   -- Do not abort on arithmetic errors (divide by zero returns NULL)
    SET ARITHIGNORE ON;    -- Suppress arithmetic warnings; NULLIF guards handle safe output

  BEGIN TRY

    -- ─────────────────────────────────────────────
    -- 0.  VARIABLES
    -- ─────────────────────────────────────────────
    DECLARE @TotalRAM_GB        DECIMAL(10,2),
            @MaxServerMemory_GB DECIMAL(10,2),
            @MinServerMemory_GB DECIMAL(10,2),
            @SQLVersion         NVARCHAR(200),
            @InstanceName       NVARCHAR(200),
            @CurrentPLE         BIGINT,
            @CurrentPLE_NUMA    NVARCHAR(2000),
            @BufferPoolMB       DECIMAL(10,2),
            @TargetServerMB     DECIMAL(10,2),
            @RunTime            DATETIME        = GETDATE();

    SELECT @SQLVersion    = @@VERSION,
           @InstanceName  = @@SERVERNAME;

    -- ─────────────────────────────────────────────
    -- 1.  HEADER BANNER
    -- ─────────────────────────────────────────────
    IF @Mode IN ('FULL','QUICK','FIX')
    BEGIN
        SELECT
            '=========================================='                        AS [Report],
            'SP_PLECHECK  –  PLE Diagnostic Report'                           AS [Title],
            CONVERT(NVARCHAR,@RunTime,120)                                     AS [RunTime],
            @InstanceName                                                       AS [Instance],
            @Mode                                                               AS [Mode],
            CAST(@PLEThreshold AS NVARCHAR) + ' seconds'                       AS [PLE_Alert_Threshold];
    END

    -- ─────────────────────────────────────────────
    -- 2.  CURRENT PLE  (per NUMA node + total)
    -- ─────────────────────────────────────────────
    IF @Mode IN ('FULL','QUICK')
    BEGIN
        IF @Debug = 1 PRINT '>> Section 2: Current PLE Values';

        -- Global PLE (all NUMA nodes combined / single-node instance)
        SELECT @CurrentPLE = cntr_value
        FROM   sys.dm_os_performance_counters
        WHERE  counter_name = 'Page life expectancy'
          AND  object_name  LIKE '%Buffer Manager%';

        SELECT
            counter_name                                    AS [Counter],
            object_name                                     AS [NUMA_Node_Object],
            cntr_value                                      AS [PLE_Seconds],
            CASE
                WHEN cntr_value <  @PLEThreshold                 THEN '🔴 CRITICAL – Below threshold'
                WHEN cntr_value <  @PLEThreshold * 2             THEN '🟡 WARNING  – Near threshold'
                ELSE                                                  '🟢 HEALTHY'
            END                                             AS [Status],
            @PLEThreshold                                   AS [Threshold_Seconds],
            cntr_value - @PLEThreshold                      AS [Delta_From_Threshold]
        FROM   sys.dm_os_performance_counters
        WHERE  counter_name = 'Page life expectancy'
          AND  object_name  LIKE '%Buffer%'
        ORDER  BY object_name;
    END

    -- ─────────────────────────────────────────────
    -- 3.  MEMORY CONFIGURATION & PRESSURE OVERVIEW
    -- ─────────────────────────────────────────────
    IF @Mode IN ('FULL','MEMORY')
    BEGIN
        IF @Debug = 1 PRINT '>> Section 3: Memory Configuration';

        -- OS physical memory
        SELECT @TotalRAM_GB = physical_memory_kb / 1048576.0
        FROM   sys.dm_os_sys_info;

        -- SQL Server max/min memory settings
        SELECT
            @MaxServerMemory_GB = CAST(value_in_use AS DECIMAL(10,2)) / 1024.0
        FROM   sys.configurations
        WHERE  name = 'max server memory (MB)';

        SELECT
            @MinServerMemory_GB = CAST(value_in_use AS DECIMAL(10,2)) / 1024.0
        FROM   sys.configurations
        WHERE  name = 'min server memory (MB)';

        -- Buffer pool usage
        SELECT @BufferPoolMB   = SUM(pages_kb)       / 1024.0,
               @TargetServerMB = SUM(awe_allocated_kb) / 1024.0
        FROM   sys.dm_os_memory_clerks
        WHERE  type = 'MEMORYCLERK_SQLBUFFERPOOL';

        -- 3a. SQL Server Memory Settings
        SELECT
            @TotalRAM_GB                                    AS [Physical_RAM_GB],
            @MaxServerMemory_GB                             AS [SQL_Max_Memory_GB],
            @MinServerMemory_GB                             AS [SQL_Min_Memory_GB],
            CAST(@MaxServerMemory_GB / NULLIF(@TotalRAM_GB,0) * 100 AS DECIMAL(5,1))
                                                            AS [SQL_RAM_Pct],
            CASE
                WHEN @MaxServerMemory_GB / NULLIF(@TotalRAM_GB,0) > 0.95
                    THEN '⚠ Max Memory set too high – OS has no headroom'
                WHEN @MaxServerMemory_GB / NULLIF(@TotalRAM_GB,0) < 0.60
                    THEN '⚠ Max Memory may be set too low – review allocation'
                ELSE '✔ Memory allocation looks reasonable'
            END                                             AS [Memory_Config_Assessment];

        -- 3b. Buffer Pool Usage
        SELECT
            type                                            AS [Clerk_Type],
            name                                            AS [Clerk_Name],
            CAST(pages_kb / 1024.0 AS DECIMAL(10,2))       AS [Used_MB],
            CAST(pages_kb * 100.0 / NULLIF(SUM(pages_kb) OVER(), 0) AS DECIMAL(5,2))
                                                            AS [Pct_Of_Total]
        FROM   sys.dm_os_memory_clerks
        WHERE  pages_kb > 0
        ORDER  BY pages_kb DESC
        OFFSET 0 ROWS FETCH NEXT @TopN ROWS ONLY;

        -- 3c. Memory Grants (queries waiting for / holding memory)
        SELECT
            session_id,
            requested_memory_kb / 1024                      AS [Requested_MB],
            granted_memory_kb   / 1024                      AS [Granted_MB],
            used_memory_kb      / 1024                      AS [Used_MB],
            DATEDIFF(SECOND, request_time, GETDATE())       AS [Wait_Seconds],
            queue_id,
            grant_time
        FROM   sys.dm_exec_query_memory_grants
        ORDER  BY granted_memory_kb DESC;

        -- 3d. OS Memory Pressure signals
        SELECT
            physical_memory_in_use_kb / 1024               AS [Process_Memory_MB],
            page_fault_count,
            memory_utilization_percentage,
            CASE
                WHEN memory_utilization_percentage < 80  THEN '🟢 Low pressure'
                WHEN memory_utilization_percentage < 90  THEN '🟡 Moderate pressure'
                ELSE                                          '🔴 High pressure – PLE will drop'
            END                                             AS [OS_Memory_Pressure]
        FROM   sys.dm_os_process_memory;

        -- 3e. NUMA node memory distribution
        SELECT
            memory_node_id                                  AS [NUMA_Node],
            virtual_address_space_reserved_kb / 1024       AS [VAS_Reserved_MB],
            virtual_address_space_committed_kb / 1024      AS [VAS_Committed_MB],
            locked_page_allocations_kb / 1024              AS [Locked_Pages_MB],
            pages_kb / 1024                                 AS [Buffer_Pool_MB],
            foreign_committed_kb / 1024                     AS [Foreign_Committed_MB],
            target_kb / 1024                                AS [Target_MB]
        FROM   sys.dm_os_memory_nodes
        WHERE  memory_node_id <> 64                         -- Exclude DAC node
        ORDER  BY memory_node_id;
    END

    -- ─────────────────────────────────────────────
    -- 4.  TOP MEMORY-CONSUMING QUERIES
    -- ─────────────────────────────────────────────
    IF @Mode IN ('FULL','QUERIES')
    BEGIN
        IF @Debug = 1 PRINT '>> Section 4: Top Memory-Consuming Queries';

        -- 4a. By total granted memory
        SELECT TOP (@TopN)
            qs.total_grant_kb / 1024                       AS [Total_Grant_MB],
            qs.max_grant_kb   / 1024                       AS [Max_Grant_MB],
            qs.execution_count,
            qs.total_elapsed_time / 1000                   AS [Total_Elapsed_ms],
            qs.total_logical_reads,
            qs.total_logical_writes,
            DB_NAME(qt.dbid)                               AS [Database],
            OBJECT_NAME(qt.objectid, qt.dbid)              AS [Object],
            SUBSTRING(qt.text, 1, 300)                     AS [Query_Text_Preview],
            qp.query_plan                                   AS [Execution_Plan]
        FROM   sys.dm_exec_query_stats  AS qs
        CROSS  APPLY sys.dm_exec_sql_text(qs.sql_handle)    AS qt
        CROSS  APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
        ORDER  BY qs.total_grant_kb DESC;

        -- 4b. Queries doing the most logical reads (buffer pool pressure)
        SELECT TOP (@TopN)
            qs.total_logical_reads / NULLIF(qs.execution_count,0)
                                                            AS [Avg_Logical_Reads],
            qs.total_logical_reads,
            qs.execution_count,
            qs.total_physical_reads,
            CASE WHEN NULLIF(qs.total_physical_reads,0) IS NULL THEN NULL
                 ELSE qs.total_logical_reads / qs.total_physical_reads
            END                                             AS [Buffer_Hit_Ratio_Approx],
            DB_NAME(qt.dbid)                               AS [Database],
            OBJECT_NAME(qt.objectid, qt.dbid)              AS [Object],
            SUBSTRING(qt.text, 1, 300)                     AS [Query_Text_Preview]
        FROM   sys.dm_exec_query_stats  AS qs
        CROSS  APPLY sys.dm_exec_sql_text(qs.sql_handle)    AS qt
        ORDER  BY qs.total_logical_reads DESC;

        -- 4c. Currently executing sessions with high memory / reads
        SELECT
            r.session_id,
            r.status,
            r.command,
            DB_NAME(r.database_id)                         AS [Database],
            r.cpu_time,
            r.total_elapsed_time / 1000                    AS [Elapsed_ms],
            r.reads,
            r.writes,
            r.logical_reads,
            r.granted_query_memory * 8 / 1024              AS [Granted_Memory_MB],
            t.text                                          AS [Query_Text]
        FROM   sys.dm_exec_requests    AS r
        CROSS  APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
        WHERE  r.session_id <> @@SPID
        ORDER  BY r.logical_reads DESC;
    END

    -- ─────────────────────────────────────────────
    -- 5.  MISSING & UNUSED INDEXES
    --     (Missing indexes drive extra scans → high logical reads → PLE drops)
    -- ─────────────────────────────────────────────
    IF @Mode IN ('FULL','INDEXES')
    BEGIN
        IF @Debug = 1 PRINT '>> Section 5: Index Analysis';

        -- 5a. Missing indexes (high-impact first)
        SELECT TOP (@TopN)
            ROUND(migs.avg_total_user_cost * migs.avg_user_impact * (migs.user_seeks + migs.user_scans), 0)
                                                            AS [Impact_Score],
            migs.user_seeks,
            migs.user_scans,
            CAST(migs.avg_user_impact AS INT)               AS [Avg_Improvement_Pct],
            DB_NAME(mid.database_id)                        AS [Database],
            OBJECT_NAME(mid.object_id, mid.database_id)    AS [Table],
            mid.equality_columns,
            mid.inequality_columns,
            mid.included_columns,
            'CREATE NONCLUSTERED INDEX [IX_Missing_' +
                OBJECT_NAME(mid.object_id, mid.database_id) + '_' +
                CAST(mig.index_group_handle AS VARCHAR) +
                '] ON ' + mid.statement + ' (' +
                ISNULL(mid.equality_columns,'') +
                CASE WHEN mid.inequality_columns IS NOT NULL
                     THEN (CASE WHEN mid.equality_columns IS NOT NULL THEN ',' ELSE '' END) + mid.inequality_columns
                     ELSE '' END + ')' +
                CASE WHEN mid.included_columns IS NOT NULL
                     THEN ' INCLUDE (' + mid.included_columns + ')' ELSE '' END + ';'
                                                            AS [Suggested_CREATE_Statement]
        FROM   sys.dm_db_missing_index_group_stats  AS migs
        JOIN   sys.dm_db_missing_index_groups       AS mig  ON migs.group_handle = mig.index_group_handle
        JOIN   sys.dm_db_missing_index_details      AS mid  ON mig.index_handle  = mid.index_handle
        ORDER  BY Impact_Score DESC;

        -- 5b. Unused indexes (consuming buffer pool with no read benefit)
        SELECT TOP (@TopN)
            DB_NAME()                                       AS [Database],
            OBJECT_NAME(i.object_id)                        AS [Table],
            i.name                                          AS [Index_Name],
            i.type_desc                                     AS [Index_Type],
            ius.user_seeks,
            ius.user_scans,
            ius.user_lookups,
            ius.user_updates,
            CAST(8 * SUM(a.used_pages) / 1024.0 AS DECIMAL(10,2))
                                                            AS [Size_MB],
            'DROP INDEX [' + i.name + '] ON [' + OBJECT_NAME(i.object_id) + '];'
                                                            AS [Drop_Script_If_Confirmed]
        FROM   sys.indexes                AS i
        JOIN   sys.dm_db_index_usage_stats AS ius ON i.object_id  = ius.object_id
                                                 AND i.index_id   = ius.index_id
                                                 AND ius.database_id = DB_ID()
        JOIN   sys.partitions             AS p   ON i.object_id   = p.object_id
                                                 AND i.index_id   = p.index_id
        JOIN   sys.allocation_units       AS a   ON p.partition_id = a.container_id
        WHERE  i.type_desc  <> 'HEAP'
          AND  i.is_primary_key = 0
          AND  i.is_unique_constraint = 0
          AND  ius.user_seeks  + ius.user_scans + ius.user_lookups = 0
          AND  ius.user_updates > 0          -- Being maintained but never read
        GROUP  BY i.object_id, i.name, i.type_desc, i.index_id,
                  ius.user_seeks, ius.user_scans, ius.user_lookups, ius.user_updates
        ORDER  BY Size_MB DESC;

        -- 5c. Most fragmented indexes (fragmentation kills read efficiency → more pages loaded)
        SELECT TOP (@TopN)
            DB_NAME(ips.database_id)                        AS [Database],
            OBJECT_NAME(ips.object_id, ips.database_id)    AS [Table],
            i.name                                          AS [Index_Name],
            ips.index_type_desc,
            CAST(ips.avg_fragmentation_in_percent AS DECIMAL(5,1))
                                                            AS [Fragmentation_Pct],
            ips.page_count,
            CASE
                WHEN ips.avg_fragmentation_in_percent > 30  THEN 'REBUILD   – ALTER INDEX ... REBUILD'
                WHEN ips.avg_fragmentation_in_percent > 5   THEN 'REORGANIZE – ALTER INDEX ... REORGANIZE'
                ELSE                                             'OK'
            END                                             AS [Recommended_Action]
        FROM   sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') AS ips
        JOIN   sys.indexes AS i ON ips.object_id = i.object_id
                                AND ips.index_id  = i.index_id
        WHERE  ips.avg_fragmentation_in_percent > 5
          AND  ips.page_count > 100
        ORDER  BY ips.avg_fragmentation_in_percent DESC;
    END

    -- ─────────────────────────────────────────────
    -- 6.  WAIT STATISTICS  (memory-related waits)
    -- ─────────────────────────────────────────────
    IF @Mode IN ('FULL','WAITS')
    BEGIN
        IF @Debug = 1 PRINT '>> Section 6: Wait Statistics';

        SELECT TOP (@TopN)
            wait_type,
            waiting_tasks_count,
            CAST(wait_time_ms / 1000.0 AS DECIMAL(12,1))  AS [Total_Wait_Sec],
            CAST(max_wait_time_ms / 1000.0 AS DECIMAL(10,1))
                                                            AS [Max_Wait_Sec],
            CAST(wait_time_ms * 100.0 / NULLIF(SUM(wait_time_ms) OVER(),0) AS DECIMAL(5,2))
                                                            AS [Pct_Of_Total],
            CASE wait_type
                WHEN 'PAGEIOLATCH_SH'    THEN '🔴 Reading pages from disk – buffer pool pressure / missing indexes'
                WHEN 'PAGEIOLATCH_EX'    THEN '🔴 Writing pages to disk   – high memory pressure'
                WHEN 'PAGEIOLATCH_UP'    THEN '🟡 Page update I/O latch   – disk write pressure'
                WHEN 'RESOURCE_SEMAPHORE'THEN '🔴 Queries queuing for memory grants – PLE killer'
                WHEN 'RESOURCE_SEMAPHORE_QUERY_COMPILE'
                                         THEN '🟡 Compile waiting for memory grant'
                WHEN 'CMEMTHREAD'        THEN '🟡 Memory allocator contention'
                WHEN 'SOS_SCHEDULER_YIELD' THEN '🟡 CPU pressure – may mask memory issues'
                WHEN 'WRITELOG'          THEN '🟡 Log write latency'
                WHEN 'ASYNC_IO_COMPLETION' THEN '🟡 Async I/O – possible disk saturation'
                WHEN 'IO_COMPLETION'     THEN '🟡 Sync I/O completion'
                WHEN 'LATCH_SH'          THEN '🟡 Shared latch – possible contention'
                WHEN 'LATCH_EX'          THEN '🔴 Exclusive latch contention'
                ELSE                          '  Review if significant'
            END                                             AS [Meaning_And_Action]
        FROM   sys.dm_os_wait_stats
        WHERE  wait_type NOT IN (
                   'SLEEP_TASK','BROKER_TO_FLUSH','BROKER_TASK_STOP',
                   'CLR_AUTO_EVENT','DISPATCHER_QUEUE_SEMAPHORE','FT_IFTS_SCHEDULER_IDLE_WAIT',
                   'HADR_FILESTREAM_IOMGR_IOCOMPLETION','HADR_WORK_QUEUE',
                   'HADR_CLUSAPI_CALL','HADR_TIMER_TASK',
                   'ONDEMAND_TASK_QUEUE','REQUEST_FOR_DEADLOCK_SEARCH',
                   'RESOURCE_QUEUE','SERVER_IDLE_CHECK','SLEEP_DBSTARTUP',
                   'SLEEP_DBRECOVER','SLEEP_DBTIMESTAMP','SLEEP_MASTERDBREADY',
                   'SLEEP_MASTERMDREADY','SLEEP_MASTERUPGRADED','SLEEP_MSDBSTARTUP',
                   'SLEEP_SYSTEMTASK','SLEEP_TEMPDBSTARTUP','SNI_HTTP_ACCEPT',
                   'SP_SERVER_DIAGNOSTICS_SLEEP','SQLTRACE_BUFFER_FLUSH',
                   'SQLTRACE_INCREMENTAL_FLUSH_SLEEP','WAITFOR',
                   'XE_DISPATCHER_WAIT','XE_TIMER_EVENT',
                   'BROKER_EVENTHANDLER','CHECKPOINT_QUEUE','DBMIRROR_EVENTS_QUEUE',
                   'SQLTRACE_WAIT_ENTRIES','WAIT_XTP_OFFLINE_CKPT_NEW_LOG'
               )
        ORDER  BY wait_time_ms DESC;
    END

    -- ─────────────────────────────────────────────
    -- 7.  BUFFER POOL  –  HOT DATABASES & OBJECTS
    -- ─────────────────────────────────────────────
    IF @Mode IN ('FULL')
    BEGIN
        IF @Debug = 1 PRINT '>> Section 7: Buffer Pool Consumers';

        -- 7a. Which databases consume the most buffer pool
        SELECT TOP (@TopN)
            CASE WHEN database_id = 32767 THEN 'Resource DB'
                 ELSE DB_NAME(database_id)
            END                                             AS [Database],
            COUNT_BIG(*) * 8 / 1024                        AS [Buffer_MB],
            SUM(CAST(is_modified AS INT))                   AS [Dirty_Pages],
            COUNT_BIG(*)                                    AS [Total_Pages]
        FROM   sys.dm_os_buffer_descriptors
        GROUP  BY database_id
        ORDER  BY Buffer_MB DESC;

        -- 7b. Top tables/indexes holding buffer pool pages (current DB)
        SELECT TOP (@TopN)
            OBJECT_NAME(p.object_id)                        AS [Object],
            i.name                                          AS [Index_Name],
            i.type_desc                                     AS [Index_Type],
            COUNT_BIG(*) * 8 / 1024                        AS [Buffer_MB],
            COUNT_BIG(*)                                    AS [Pages_In_Buffer],
            SUM(CAST(bd.is_modified AS INT))                AS [Dirty_Pages]
        FROM   sys.dm_os_buffer_descriptors AS bd
        JOIN   sys.allocation_units         AS au ON bd.allocation_unit_id = au.allocation_unit_id
        JOIN   sys.partitions               AS p  ON au.container_id       = p.hobt_id
        JOIN   sys.indexes                  AS i  ON p.object_id           = i.object_id
                                                 AND p.index_id            = i.index_id
        WHERE  bd.database_id = DB_ID()
        GROUP  BY p.object_id, i.name, i.type_desc
        ORDER  BY Buffer_MB DESC;
    END

    -- ─────────────────────────────────────────────
    -- 8.  PLE HISTORY  (via Ring Buffer – last few hours if available)
    -- ─────────────────────────────────────────────
    IF @Mode IN ('FULL','MEMORY')
    BEGIN
        IF @Debug = 1 PRINT '>> Section 8: PLE History from Ring Buffer';

        SELECT TOP 50
            DATEADD(ms, rbm.timestamp - si.ms_ticks, GETDATE())
                                                            AS [Approx_Timestamp],
            rbm.record.value('(./Record/ResourceMonitor/IndicatorsProcess)[1]','int')
                                                            AS [Process_Indicator],
            rbm.record.value('(./Record/ResourceMonitor/IndicatorsSystem)[1]','int')
                                                            AS [System_Indicator],
            rbm.record.value('(./Record/ResourceMonitor/Notification)[1]','nvarchar(100)')
                                                            AS [Notification],
            rbm.record.value('(./Record/MemoryRecord/MemoryUtilization)[1]','int')
                                                            AS [Memory_Utilization_Pct]
        FROM (
            SELECT
                timestamp,
                CONVERT(XML, record) AS record
            FROM   sys.dm_os_ring_buffers
            WHERE  ring_buffer_type = N'RING_BUFFER_RESOURCE_MONITOR'
        ) AS rbm
        CROSS JOIN sys.dm_os_sys_info AS si
        ORDER  BY rbm.timestamp DESC;
    END

    -- ─────────────────────────────────────────────
    -- 9.  PLAN CACHE  –  BLOAT & SINGLE-USE PLANS
    -- ─────────────────────────────────────────────
    IF @Mode IN ('FULL','MEMORY')
    BEGIN
        IF @Debug = 1 PRINT '>> Section 9: Plan Cache Analysis';

        -- 9a. Plan cache summary
        SELECT
            objtype                                         AS [Cache_Object_Type],
            COUNT_BIG(*)                                    AS [Plan_Count],
            SUM(CAST(size_in_bytes AS BIGINT)) / 1048576   AS [Cache_MB],
            AVG(usecounts)                                  AS [Avg_Use_Count]
        FROM   sys.dm_exec_cached_plans
        GROUP  BY objtype
        ORDER  BY Cache_MB DESC;

        -- 9b. Single-use plans (ad-hoc plan cache bloat – a major PLE thief)
        SELECT
            SUM(CAST(size_in_bytes AS BIGINT)) / 1048576   AS [Single_Use_Plan_MB],
            COUNT(*)                                        AS [Single_Use_Plan_Count],
            CASE
                WHEN SUM(CAST(size_in_bytes AS BIGINT)) / 1048576 > 500
                    THEN '🔴 HIGH – Enable "optimize for ad hoc workloads" immediately'
                WHEN SUM(CAST(size_in_bytes AS BIGINT)) / 1048576 > 100
                    THEN '🟡 MODERATE – Consider "optimize for ad hoc workloads"'
                ELSE '🟢 OK'
            END                                             AS [Assessment_And_Fix]
        FROM   sys.dm_exec_cached_plans
        WHERE  usecounts = 1
          AND  objtype   = 'Adhoc';

        -- 9c. Largest individual cached plans
        SELECT TOP (@TopN)
            cp.usecounts,
            cp.objtype,
            CAST(cp.size_in_bytes / 1048576.0 AS DECIMAL(6,2))
                                                            AS [Plan_MB],
            DB_NAME(qt.dbid)                               AS [Database],
            SUBSTRING(qt.text, 1, 300)                     AS [Query_Text_Preview]
        FROM   sys.dm_exec_cached_plans AS cp
        CROSS  APPLY sys.dm_exec_sql_text(cp.plan_handle) AS qt
        ORDER  BY cp.size_in_bytes DESC;
    END

    -- ─────────────────────────────────────────────
    -- 10.  TEMPDB  –  CONTENTION & SIZING
    --      (Excessive TempDB use evicts buffer pool pages → PLE drops)
    -- ─────────────────────────────────────────────
    IF @Mode IN ('FULL')
    BEGIN
        IF @Debug = 1 PRINT '>> Section 10: TempDB Analysis';

        -- 10a. TempDB file sizes and space
        SELECT
            name,
            physical_name,
            CAST(size * 8.0 / 1024 AS DECIMAL(10,2))       AS [Size_MB],
            CAST(max_size * 8.0 / 1024 AS DECIMAL(10,2))   AS [Max_Size_MB],
            growth,
            is_percent_growth
        FROM   tempdb.sys.database_files
        ORDER  BY name;

        -- 10b. TempDB object usage by session
        SELECT TOP (@TopN)
            t.session_id,
            t.internal_objects_alloc_page_count / 128       AS [Internal_Obj_MB],
            t.user_objects_alloc_page_count / 128           AS [User_Obj_MB],
            t.internal_objects_dealloc_page_count / 128     AS [Internal_Deallocated_MB],
            r.reads,
            r.logical_reads,
            r.granted_query_memory,
            st.text                                         AS [Query_Text]
        FROM   sys.dm_db_session_space_usage AS t
        JOIN   sys.dm_exec_sessions          AS s  ON t.session_id = s.session_id
        LEFT   JOIN sys.dm_exec_requests     AS r  ON t.session_id = r.session_id
        OUTER  APPLY sys.dm_exec_sql_text(r.sql_handle) AS st
        WHERE  t.internal_objects_alloc_page_count + t.user_objects_alloc_page_count > 0
        ORDER  BY (t.internal_objects_alloc_page_count + t.user_objects_alloc_page_count) DESC;
    END

    -- ─────────────────────────────────────────────
    -- 11.  ROOT CAUSE DIAGNOSIS
    -- ─────────────────────────────────────────────
    IF @Mode IN ('FULL','QUICK')
    BEGIN
        IF @Debug = 1 PRINT '>> Section 11: Root Cause Diagnosis';

        DECLARE @RC_MaxMemTooHigh    BIT = 0,
                @RC_PlanCacheBloat  BIT = 0,
                @RC_HighLogicalReads BIT = 0,
                @RC_MemGrantWait    BIT = 0,
                @RC_PageIOLatch     BIT = 0,
                @RC_MissingIndex    BIT = 0;

        -- Check plan cache bloat
        IF EXISTS (
            SELECT 1 FROM sys.dm_exec_cached_plans
            WHERE  usecounts = 1 AND objtype = 'Adhoc'
            HAVING SUM(CAST(size_in_bytes AS BIGINT)) / NULLIF(1048576, 0) > 200
        ) SET @RC_PlanCacheBloat = 1;

        -- Check memory grant waits
        IF EXISTS (
            SELECT 1 FROM sys.dm_os_wait_stats
            WHERE wait_type = 'RESOURCE_SEMAPHORE' AND wait_time_ms > 10000
        ) SET @RC_MemGrantWait = 1;

        -- Check page I/O latch
        IF EXISTS (
            SELECT 1 FROM sys.dm_os_wait_stats
            WHERE wait_type IN ('PAGEIOLATCH_SH','PAGEIOLATCH_EX') AND wait_time_ms > 50000
        ) SET @RC_PageIOLatch = 1;

        -- Check missing indexes
        IF EXISTS (
            SELECT 1 FROM sys.dm_db_missing_index_group_stats
            WHERE avg_user_impact > 40 AND (user_seeks + user_scans) > 1000
        ) SET @RC_MissingIndex = 1;

        SELECT
            CASE WHEN @CurrentPLE < @PLEThreshold THEN '🔴 PLE IS BELOW THRESHOLD' ELSE '🟢 PLE is above threshold' END
                                                            AS [Overall_PLE_Status],
            @CurrentPLE                                     AS [Current_PLE],
            @PLEThreshold                                   AS [Threshold],
            CASE @RC_PlanCacheBloat  WHEN 1 THEN '✅ YES – Plan cache bloat detected'     ELSE '❌ No' END
                                                            AS [RCA_PlanCacheBloat],
            CASE @RC_MemGrantWait    WHEN 1 THEN '✅ YES – Memory grant waits detected'   ELSE '❌ No' END
                                                            AS [RCA_MemoryGrantWaits],
            CASE @RC_PageIOLatch     WHEN 1 THEN '✅ YES – High PAGEIOLATCH waits'        ELSE '❌ No' END
                                                            AS [RCA_PageIOLatch],
            CASE @RC_MissingIndex    WHEN 1 THEN '✅ YES – High-impact missing indexes'   ELSE '❌ No' END
                                                            AS [RCA_MissingIndexes];
    END

    -- ─────────────────────────────────────────────
    -- 12.  FIX RECOMMENDATIONS  (actionable scripts)
    -- ─────────────────────────────────────────────
    IF @Mode IN ('FULL','FIX')
    BEGIN
        IF @Debug = 1 PRINT '>> Section 12: Fix Recommendations';

        -- Build fix recommendations into a temp table to avoid VALUES column-count issues
        IF OBJECT_ID('tempdb..#PLE_Fixes') IS NOT NULL DROP TABLE #PLE_Fixes;

        CREATE TABLE #PLE_Fixes (
            Priority            INT,
            Urgency             NVARCHAR(20),
            Category            NVARCHAR(50),
            Issue               NVARCHAR(500),
            Fix_Description     NVARCHAR(2000),
            SQL_Command_To_Run  NVARCHAR(MAX),
            Expected_Impact     NVARCHAR(500),
            Risk_Level          NVARCHAR(100)
        );

        -- ── Immediate fixes ──
        INSERT INTO #PLE_Fixes VALUES (
            1, '🔴 IMMEDIATE', 'Plan Cache',
            'Ad-hoc plan cache bloat consuming buffer pool',
            'Enable "Optimize for Ad Hoc Workloads". Stubs cached instead of full plans for single-use queries.',
            'EXEC sp_configure ''optimize for ad hoc workloads'', 1; RECONFIGURE WITH OVERRIDE;',
            'Reduces plan cache MB significantly; PLE improves within minutes',
            'LOW – online change, no restart'
        );
        INSERT INTO #PLE_Fixes VALUES (
            2, '🔴 IMMEDIATE', 'Max Server Memory',
            'SQL Server max memory may be mis-configured leaving OS starved',
            'Set max server memory to leave 10-15% (at least 4 GB) for the OS. Adjust value to your server RAM.',
            '-- Replace 53248 with (TotalRAM_MB - 4096) or 85% of total RAM MB
EXEC sp_configure ''max server memory (MB)'', 53248;
RECONFIGURE WITH OVERRIDE;',
            'Prevents OS paging of buffer pool pages; stabilises PLE',
            'LOW – online change; verify @TotalRAM_GB before running'
        );
        INSERT INTO #PLE_Fixes VALUES (
            3, '🔴 IMMEDIATE', 'Memory',
            'Lock Pages in Memory not configured – Windows may page out buffer pool',
            'Grant SQL Server service account the "Lock Pages in Memory" Windows privilege.',
            '-- Windows: gpedit.msc > Computer Config > Windows Settings > Security Settings
-- > Local Policies > User Rights Assignment > Lock Pages in Memory
-- Add the SQL Server service account, then restart SQL Server.',
            'Prevents buffer pool from being paged to disk by Windows memory manager',
            'LOW – Windows policy change; SQL Server restart required'
        );

        -- ── Short-term fixes ──
        INSERT INTO #PLE_Fixes VALUES (
            4, '🟡 SHORT TERM', 'Indexes',
            'Missing indexes causing table scans that load excessive pages into buffer pool',
            'Review Section 5a output. Create high-impact missing indexes in a maintenance window.',
            '-- Use the CREATE NONCLUSTERED INDEX scripts from Section 5a.
-- Always test in DEV/QA first. Do NOT create all suggestions at once.
-- Monitor after: SELECT * FROM sys.dm_db_missing_index_group_stats;',
            'Reduces logical reads per query; buffer pool pages used more efficiently',
            'MEDIUM – index creation briefly locks; always use WITH (ONLINE = ON)'
        );
        INSERT INTO #PLE_Fixes VALUES (
            5, '🟡 SHORT TERM', 'Indexes',
            'Fragmented indexes causing extra page reads and lower read efficiency',
            'Rebuild indexes with fragmentation > 30%; reorganise those between 5-30%.',
            'ALTER INDEX [IndexName] ON [dbo].[TableName]
    REBUILD WITH (ONLINE = ON, SORT_IN_TEMPDB = ON, FILLFACTOR = 80);
-- Or for light fragmentation (5-30%):
ALTER INDEX [IndexName] ON [dbo].[TableName] REORGANIZE;',
            'Fewer pages read per query; improved sequential I/O patterns',
            'LOW-MEDIUM – ONLINE rebuild has minimal production impact'
        );
        INSERT INTO #PLE_Fixes VALUES (
            6, '🟡 SHORT TERM', 'Query Tuning',
            'Queries with excessive logical reads evicting useful pages from buffer pool',
            'Review top queries from Section 4a/4b. Rewrite or add indexes to convert scans to seeks.',
            'SELECT TOP 20
    total_logical_reads,
    execution_count,
    total_logical_reads / NULLIF(execution_count,0) AS avg_reads,
    SUBSTRING(st.text, 1, 200) AS query_text
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
ORDER BY total_logical_reads DESC;',
            'Direct reduction in buffer pool page churn',
            'MEDIUM – requires query or application changes'
        );
        INSERT INTO #PLE_Fixes VALUES (
            7, '🟡 SHORT TERM', 'Memory Grants',
            'Queries waiting for or holding excessive memory grants (RESOURCE_SEMAPHORE waits)',
            'Update statistics; add MAXDOP and MAX_GRANT_PERCENT hints to heavy queries.',
            '-- Update statistics on key tables (run during low-traffic window):
EXEC sp_updatestats;
-- Or full scan on a specific table:
UPDATE STATISTICS [dbo].[YourTable] WITH FULLSCAN;
-- Add to problem queries:
-- OPTION (MAXDOP 4, MAX_GRANT_PERCENT = 25)',
            'Reduces per-query memory footprint; more concurrent queries can run',
            'LOW'
        );
        INSERT INTO #PLE_Fixes VALUES (
            8, '🟡 SHORT TERM', 'TempDB',
            'TempDB spills from sort/hash operations consuming RAM intended for buffer pool',
            'Ensure TempDB has 1 data file per logical CPU (max 8), all equal size, pre-grown.',
            '-- Check current file count and sizes:
SELECT name, size*8/1024 AS size_mb, physical_name
FROM tempdb.sys.database_files;
-- Add a file example (adjust path and size):
ALTER DATABASE tempdb ADD FILE (
    NAME = N''tempdev2'',
    FILENAME = N''D:\TempDB\tempdev2.ndf'',
    SIZE = 4096MB, FILEGROWTH = 512MB);',
            'Reduces TempDB allocation contention and sort/hash spill pressure',
            'LOW-MEDIUM – add files online; sizing requires brief planning'
        );

        -- ── Longer-term fixes ──
        INSERT INTO #PLE_Fixes VALUES (
            9, '🔵 LONG TERM', 'Resource Governor',
            'Single workloads monopolising buffer pool and memory grants',
            'Implement Resource Governor to cap memory grant % per workload group.',
            'CREATE RESOURCE POOL ReportingPool
    WITH (MAX_MEMORY_PERCENT = 25, MAX_CPU_PERCENT = 50);
CREATE WORKLOAD GROUP ReportingGroup
    USING ReportingPool
    WITH (REQUEST_MAX_MEMORY_GRANT_PERCENT = 15);
ALTER RESOURCE GOVERNOR RECONFIGURE;',
            'Prevents runaway reporting queries from collapsing PLE for all workloads',
            'MEDIUM – requires classifier function; plan carefully'
        );
        INSERT INTO #PLE_Fixes VALUES (
            10, '🔵 LONG TERM', 'Memory',
            'Server does not have enough physical RAM for the working data set',
            'Add physical RAM. Compare total database data size to available server RAM.',
            '-- Estimate working set vs available RAM:
SELECT
    SUM(size_on_disk_bytes) / 1073741824.0  AS Total_Data_GB,
    physical_memory_in_use_kb / 1048576.0   AS SQL_Process_GB
FROM sys.master_files
CROSS JOIN sys.dm_os_process_memory
WHERE type = 0;
-- If Total_Data_GB >> server RAM GB, adding RAM is the highest-impact fix.',
            'Largest sustainable PLE improvement for data-heavy workloads',
            'LOW risk; requires hardware change or cloud VM resize'
        );
        INSERT INTO #PLE_Fixes VALUES (
            11, '🔵 LONG TERM', 'Architecture',
            'Read-heavy reports competing with OLTP workload for the same buffer pool',
            'Offload reporting to an Always On Readable Secondary replica.',
            '-- Configure readable secondary on existing AG:
ALTER AVAILABILITY GROUP [AG_Name]
    MODIFY REPLICA ON N''SecondaryServer''
    WITH (SECONDARY_ROLE(ALLOW_CONNECTIONS = READ_ONLY));
-- Point reporting connection strings to secondary listener.',
            'Eliminates reporting read pressure from primary buffer pool entirely',
            'HIGH effort – requires Always On AG or log shipping setup'
        );

        SELECT
            ROW_NUMBER() OVER (ORDER BY Priority)   AS [Step],
            Urgency                                  AS [Priority],
            Category,
            Issue,
            Fix_Description,
            SQL_Command_To_Run                       AS [SQL_Command_To_Run],
            Expected_Impact,
            Risk_Level
        FROM #PLE_Fixes
        ORDER BY Priority;

        DROP TABLE #PLE_Fixes;
    END

    -- ─────────────────────────────────────────────
    -- 13.  QUICK REFERENCE  –  Key formulas
    -- ─────────────────────────────────────────────
    IF @Mode IN ('FULL','FIX')
    BEGIN
        SELECT
            'Minimum Recommended PLE'                       AS [Metric],
            '(RAM_GB × 1000) / 4  seconds  — e.g. 64GB RAM → 16,000 s target'
                                                            AS [Formula_Or_Guideline]
        UNION ALL SELECT
            'SQL Max Server Memory',
            'TotalRAM_GB × 0.85  (leave 15% + 4 GB min for OS)'
        UNION ALL SELECT
            'Plan Cache Bloat check',
            'SELECT SUM(size_in_bytes)/1048576 FROM sys.dm_exec_cached_plans WHERE usecounts=1 AND objtype=''Adhoc'''
        UNION ALL SELECT
            'Quick PLE check',
            'SELECT cntr_value AS PLE FROM sys.dm_os_performance_counters WHERE counter_name=''Page life expectancy'' AND object_name LIKE ''%Buffer Manager%'''
        UNION ALL SELECT
            'Flush single-use plan cache (emergency)',
            'DBCC FREESYSTEMCACHE (''SQL Plans'');  -- Use with caution in prod; temporary relief only'
        UNION ALL SELECT
            'Clear full procedure cache (emergency – use only in test or extreme situations)',
            'DBCC FREEPROCCACHE;  -- ⚠ Causes CPU spike as all plans recompile'
        UNION ALL SELECT
            'Update all statistics',
            'EXEC sp_updatestats;  -- Run during low-traffic window'
        UNION ALL SELECT
            'Monitoring PLE over time',
            'Use sp_BlitzFirst (free, Brent Ozar) or set up SQL Agent job to log PLE to a table every 5 min';
    END

    SET NOCOUNT OFF;

  END TRY
  BEGIN CATCH
    -- Surface a clean error message instead of an ugly batch termination
    SELECT
        ERROR_NUMBER()                          AS [Error_Number],
        ERROR_SEVERITY()                        AS [Severity],
        ERROR_STATE()                           AS [State],
        ERROR_PROCEDURE()                       AS [Procedure],
        ERROR_LINE()                            AS [Line],
        ERROR_MESSAGE()                         AS [Error_Message],
        'Run EXEC SP_PLECHECK @Debug=1 to identify which section failed.'
                                                AS [Troubleshooting_Hint];
  END CATCH

END;
GO

-- ============================================================
--  QUICK USAGE EXAMPLES
-- ============================================================
-- Full analysis (default):
--   EXEC SP_PLECHECK;
--
-- Just the fix plan:
--   EXEC SP_PLECHECK @Mode = 'FIX';
--
-- Memory-focused investigation:
--   EXEC SP_PLECHECK @Mode = 'MEMORY';
--
-- Find the bad queries:
--   EXEC SP_PLECHECK @Mode = 'QUERIES', @TopN = 30;
--
-- Index opportunities:
--   EXEC SP_PLECHECK @Mode = 'INDEXES';
--
-- Wait stats:
--   EXEC SP_PLECHECK @Mode = 'WAITS';
--
-- Change alert threshold (enterprise servers need higher value):
--   EXEC SP_PLECHECK @PLEThreshold = 1000;
-- ============================================================
