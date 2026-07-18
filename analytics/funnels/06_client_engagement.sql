-- Funnel 6 — Client engagement · actor_role = client
-- client_connected → chart_opened → export_created → export_downloaded → comment_added
-- All the shared events (chart_opened, export_created, export_downloaded,
-- comment_added) are scoped to the client persona by actor_role='client' — this is
-- exactly what separates funnel 6 from analyst funnels 2/4/5. client_connected is
-- pre-auth, so identity keys on the stable anonymous_id (preserved on login, FR6) so
-- the pre-auth entry and post-auth steps attribute to the same person.
WITH actor_steps AS (
  SELECT
    COALESCE(anonymous_id, user_id) AS actor,
    MIN(ts_server) FILTER (WHERE event = 'client_connected')  AS s1,
    MIN(ts_server) FILTER (WHERE event = 'chart_opened')      AS s2,
    MIN(ts_server) FILTER (WHERE event = 'export_created')    AS s3,
    MIN(ts_server) FILTER (WHERE event = 'export_downloaded') AS s4,
    MIN(ts_server) FILTER (WHERE event = 'comment_added')     AS s5
  FROM organization_svc.events
  WHERE actor_role = 'client'
    AND COALESCE(anonymous_id, user_id) IS NOT NULL
    [[ AND ts_server >= {{start_date}} ]]
    [[ AND ts_server <  {{end_date}} ]]
  GROUP BY 1
),
reached AS (
  SELECT
    (s1 IS NOT NULL)                                                     AS r1,
    (s1 IS NOT NULL AND s2 >= s1)                                        AS r2,
    (s1 IS NOT NULL AND s2 >= s1 AND s3 >= s2)                           AS r3,
    (s1 IS NOT NULL AND s2 >= s1 AND s3 >= s2 AND s4 >= s3)              AS r4,
    (s1 IS NOT NULL AND s2 >= s1 AND s3 >= s2 AND s4 >= s3 AND s5 >= s4) AS r5
  FROM actor_steps
),
by_step AS (
  SELECT v.step_no, v.step_name, count(*) FILTER (WHERE v.reached) AS users
  FROM reached r
  CROSS JOIN LATERAL (VALUES
    (1, '1. client_connected',  r.r1),
    (2, '2. chart_opened',      r.r2),
    (3, '3. export_created',    r.r3),
    (4, '4. export_downloaded', r.r4),
    (5, '5. comment_added',     r.r5)
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
