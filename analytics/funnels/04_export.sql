-- Funnel 4 — Export · actor_role = analyst
-- export_charts_selected → export_created → export_downloaded
-- (export_created / export_downloaded are shared with the client funnel; actor_role
--  splits the analyst view from client engagement.)
WITH actor_steps AS (
  SELECT
    COALESCE(anonymous_id, user_id) AS actor,
    MIN(ts_server) FILTER (WHERE event = 'export_charts_selected') AS s1,
    MIN(ts_server) FILTER (WHERE event = 'export_created')         AS s2,
    MIN(ts_server) FILTER (WHERE event = 'export_downloaded')      AS s3
  FROM organization_svc.events
  WHERE actor_role = 'analyst'
    AND COALESCE(anonymous_id, user_id) IS NOT NULL
    [[ AND ts_server >= {{start_date}} ]]
    [[ AND ts_server <  {{end_date}} ]]
  GROUP BY 1
),
reached AS (
  SELECT
    (s1 IS NOT NULL)                            AS r1,
    (s1 IS NOT NULL AND s2 >= s1)               AS r2,
    (s1 IS NOT NULL AND s2 >= s1 AND s3 >= s2)  AS r3
  FROM actor_steps
),
by_step AS (
  SELECT v.step_no, v.step_name, count(*) FILTER (WHERE v.reached) AS users
  FROM reached r
  CROSS JOIN LATERAL (VALUES
    (1, '1. export_charts_selected', r.r1),
    (2, '2. export_created',         r.r2),
    (3, '3. export_downloaded',      r.r3)
  ) AS v(step_no, step_name, reached)
  GROUP BY v.step_no, v.step_name
)
SELECT
  step_name,
  users,
  round(100.0 * users / NULLIF(first_value(users) OVER (ORDER BY step_no), 0), 1) AS pct_of_entry,
  round(100.0 * users / NULLIF(lag(users)         OVER (ORDER BY step_no), 0), 1) AS pct_of_prev_step
FROM by_step
ORDER BY step_no;
