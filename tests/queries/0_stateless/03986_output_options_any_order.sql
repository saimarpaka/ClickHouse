-- Test that INTO OUTFILE, FORMAT, and SETTINGS can appear in any order
-- and produce consistent AST formatting roundtrips.

-- Verify double-formatting consistency for all permutations of output options.
SELECT
    q,
    formatQuerySingleLine(q) AS f1,
    formatQuerySingleLine(formatQuerySingleLine(q)) AS f2,
    f1 = f2 AS consistent
FROM
(
    -- Standard order: INTO OUTFILE, FORMAT, SETTINGS
    SELECT 'SELECT 1 INTO OUTFILE ''/dev/null'' FORMAT TSV SETTINGS max_threads = 1' AS q
    UNION ALL SELECT 'SELECT 1 INTO OUTFILE ''/dev/null'' SETTINGS max_threads = 1 FORMAT TSV'
    UNION ALL SELECT 'SELECT 1 FORMAT TSV INTO OUTFILE ''/dev/null'' SETTINGS max_threads = 1'
    UNION ALL SELECT 'SELECT 1 FORMAT TSV SETTINGS max_threads = 1 INTO OUTFILE ''/dev/null'''
    UNION ALL SELECT 'SELECT 1 SETTINGS max_threads = 1 INTO OUTFILE ''/dev/null'' FORMAT TSV'
    UNION ALL SELECT 'SELECT 1 SETTINGS max_threads = 1 FORMAT TSV INTO OUTFILE ''/dev/null'''
    -- Two out of three
    UNION ALL SELECT 'SELECT 1 FORMAT TSV SETTINGS max_threads = 1'
    UNION ALL SELECT 'SELECT 1 SETTINGS max_threads = 1 FORMAT TSV'
    UNION ALL SELECT 'SELECT 1 INTO OUTFILE ''/dev/null'' FORMAT TSV'
    UNION ALL SELECT 'SELECT 1 FORMAT TSV INTO OUTFILE ''/dev/null'''
    UNION ALL SELECT 'SELECT 1 INTO OUTFILE ''/dev/null'' SETTINGS max_threads = 1'
    UNION ALL SELECT 'SELECT 1 SETTINGS max_threads = 1 INTO OUTFILE ''/dev/null'''
    -- UNION ALL with output options in different orders
    UNION ALL SELECT '(SELECT 1) UNION ALL (SELECT 2) SETTINGS max_threads = 1 INTO OUTFILE ''/dev/null'' FORMAT TSV'
    UNION ALL SELECT '(SELECT 1) UNION ALL (SELECT 2) FORMAT TSV SETTINGS max_threads = 1 INTO OUTFILE ''/dev/null'''
    -- EXPLAIN with output options
    UNION ALL SELECT 'EXPLAIN AST SELECT 1 SETTINGS max_threads = 1 INTO OUTFILE ''/dev/null'' FORMAT TSV'
    UNION ALL SELECT 'EXPLAIN AST SELECT 1 FORMAT TSV INTO OUTFILE ''/dev/null'' SETTINGS max_threads = 1'
    -- INTO OUTFILE with TRUNCATE and COMPRESSION
    UNION ALL SELECT 'SELECT 1 SETTINGS max_threads = 1 INTO OUTFILE ''/dev/null'' TRUNCATE FORMAT TSV'
    UNION ALL SELECT 'SELECT 1 INTO OUTFILE ''/dev/null'' TRUNCATE COMPRESSION ''gzip'' SETTINGS max_threads = 1 FORMAT TSV'
)
ORDER BY q;
