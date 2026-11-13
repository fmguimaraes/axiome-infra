-- Funnel 7 — Admin governance · actor_role = admin (AXI-2507)
-- role_created / role_updated / role_deleted / role_assigned /
-- project_visibility_changed / project_access_granted / project_access_revoked /
-- project_access_level_changed / org_rule_access_changed /
-- kg_permission_created / kg_permission_updated / kg_permission_deleted /
-- org_member_added / org_member_removed / workspace_member_added
--
-- Deliberately FLAT, not sequential (FR11): these 15 actions are independent
-- RBAC/permission-scope admin operations with no natural order or common entry
-- point — unlike funnels 1-6 there is no "step 1 before step 2" journey to chain,
-- so this is a per-event volume breakdown rather than a funnel/step-conversion
-- query. Identity keys on user_id (admin actions are always authenticated; there
-- is no pre-auth admin persona, so no anonymous_id fallback is needed here).
-- Paste into a Metabase Native question and render as a Bar chart (event on the
-- category axis, events/distinct_admins as the two series). Optional
-- {{start_date}} / {{end_date}} are Date variables.
SELECT
  event,
  count(*)                          AS events,
  count(DISTINCT user_id)           AS distinct_admins,
  min(ts_server)                    AS first_seen,
  max(ts_server)                    AS last_seen
FROM organization_svc.analytics_events
WHERE actor_role = 'admin'
  [[ AND ts_server >= {{start_date}} ]]
  [[ AND ts_server <  {{end_date}} ]]
GROUP BY event
ORDER BY events DESC;
