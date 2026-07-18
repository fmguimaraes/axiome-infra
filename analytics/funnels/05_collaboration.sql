-- Funnel 5 — Collaboration · actor_role = analyst
-- analysis_table_explored → comment_added
-- (comment_added is shared with the client funnel; actor_role='analyst' splits it.)
WITH actor_steps AS (
  SELECT
    COALESCE(anonymous_id, user_id) AS actor,
    MIN(ts_server) FILTER (WHERE event = 'analysis_table_explored') AS s1,
    MIN(ts_server) FILTER (WHERE event = 'comment_added')           AS s2
  FROM organization_svc.events
  WHERE actor_role = 'analyst'
    AND COALESCE(anonymous_id, user_id) IS NOT NULL
    [[ AND ts_server >= {{start_date}} ]]
    [[ AND ts_server <  {{end_date}} ]]
  GROUP BY 1
),
reached AS (
  SELECT
    (s1 IS NOT NULL)              AS r1,
    (s1 IS NOT NULL AND s2 >= s1) AS r2
  FROM actor_steps
),
by_step AS (
  SELECT v.step_no, v.step_name, count(*) FILTER (WHERE v.reached) AS users
  FROM reached r
  CROSS JOIN LATERAL (VALUES
    (1, '1. analysis_table_explored', r.r1),
    (2, '2. comment_added',           r.r2)
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
