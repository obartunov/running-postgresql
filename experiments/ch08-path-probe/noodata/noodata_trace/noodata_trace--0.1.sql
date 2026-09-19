\echo Use "CREATE EXTENSION noodata_trace" to load this file. \quit

-- Attach all planner trajectory points to this module's callback.  Call it as
-- a single statement: points attached one at a time would observe the
-- planning of the later attach statements.  Events are emitted only while
-- noodata_trace.enabled is on.
CREATE FUNCTION noodata_trace_attach()
RETURNS void
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT;

CREATE FUNCTION noodata_trace_detach()
RETURNS void
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT;
