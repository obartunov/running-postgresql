/*-------------------------------------------------------------------------
 *
 * noodata_trace.c
 *		Emit planner trajectory events as one JSON object per NOTICE.
 *
 * Test/demo callback for the planner injection points
 *
 *		planner-add-path-accept
 *		planner-add-path-reject
 *		planner-add-path-displace
 *		planner-add-path-precheck-reject
 *		planner-index-path-generated
 *		planner-index-path-not-generated
 *
 * Every add_path event is reported from the point of view of its subject, the
 * path whose fate the event decides:
 *
 *		accept           subject = new path,     no competitor
 *		reject           subject = new path,     competitor = dominating path
 *		displace         subject = removed path, competitor = new path
 *		precheck-reject  subject = proposed path (no Path exists yet),
 *		                 competitor = dominating path
 *
 * Paths get a small integer id, unique within one top-level planner
 * invocation, so that "accepted, later displaced" is a sequence of events on
 * one id rather than a single final status.  The id belongs to the Path
 * object: the same object added to two relations (a scan/join path passed on
 * to an upper relation) keeps its id, and rel_id tells the memberships apart.
 * An id is dropped exactly when add_path() frees the path, so a later path
 * allocated at the same address gets a new one.  A path that entered a
 * pathlist without add_path() (for example a projection substituted in place)
 * gets its id when first seen as a competitor, flagged with
 * competitor_first_seen.
 *
 * Relations get a rel_id per planner invocation as well.  Upper relations
 * have no relids, and rel_id is what separates, say, the ordered relation
 * from the final one.
 *
 * Events are emitted only while noodata_trace.enabled is on; SET and RESET
 * are not planned, so bracketing one EXPLAIN with them captures exactly that
 * planner invocation.
 *
 * The payloads are planner-local and meaningful only to code compiled
 * against the same sources.  This module is a dataset generator, not an API.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "catalog/index.h"
#include "fmgr.h"
#include "lib/stringinfo.h"
#include "nodes/pathnodes.h"
#include "optimizer/pathnode.h"
#include "optimizer/paths.h"
#include "optimizer/planner.h"
#include "utils/guc.h"
#include "utils/hsearch.h"
#include "utils/injection_point.h"
#include "utils/json.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"

#ifndef USE_INJECTION_POINTS
#error "noodata_trace requires a server built with --enable-injection-points"
#endif

PG_MODULE_MAGIC;

PG_FUNCTION_INFO_V1(noodata_trace_attach);
PG_FUNCTION_INFO_V1(noodata_trace_detach);

extern PGDLLEXPORT void noodata_trace_event(const char *name,
											const void *private_data,
											void *arg);

static const char *const trace_points[] = {
	"planner-add-path-accept",
	"planner-add-path-reject",
	"planner-add-path-displace",
	"planner-add-path-precheck-reject",
	"planner-index-path-generated",
	"planner-index-path-not-generated",
};

typedef struct IdEntry
{
	const void *ptr;			/* hash key: Path or RelOptInfo */
	int			id;
} IdEntry;

static bool trace_enabled = false;
static planner_hook_type prev_planner_hook = NULL;
static int	planner_depth = 0;
static int	plan_seq = 0;
static int	event_seq = 0;
static int	next_path_id = 0;
static int	next_rel_id = 0;
static HTAB *path_ids = NULL;
static HTAB *rel_ids = NULL;

static void
reset_plan_state(void)
{
	HASHCTL		ctl;

	if (path_ids != NULL)
		hash_destroy(path_ids);
	if (rel_ids != NULL)
		hash_destroy(rel_ids);

	ctl.keysize = sizeof(const void *);
	ctl.entrysize = sizeof(IdEntry);
	ctl.hcxt = TopMemoryContext;
	path_ids = hash_create("noodata_trace path ids", 256, &ctl,
						   HASH_ELEM | HASH_BLOBS | HASH_CONTEXT);
	rel_ids = hash_create("noodata_trace rel ids", 64, &ctl,
						  HASH_ELEM | HASH_BLOBS | HASH_CONTEXT);
	event_seq = 0;
	next_path_id = 0;
	next_rel_id = 0;
}

static PlannedStmt *
noodata_planner(Query *parse, const char *query_string, int cursorOptions,
				ParamListInfo boundParams, ExplainState *es)
{
	PlannedStmt *result;

	if (planner_depth == 0)
	{
		plan_seq++;
		reset_plan_state();
	}

	planner_depth++;
	PG_TRY();
	{
		if (prev_planner_hook)
			result = prev_planner_hook(parse, query_string, cursorOptions,
									   boundParams, es);
		else
			result = standard_planner(parse, query_string, cursorOptions,
									  boundParams, es);
	}
	PG_FINALLY();
	{
		planner_depth--;
	}
	PG_END_TRY();

	return result;
}

static int
ptr_id(HTAB *map, const void *ptr, int *next, bool *first_seen)
{
	bool		found;
	IdEntry    *e = hash_search(map, &ptr, HASH_ENTER, &found);

	if (!found)
		e->id = ++(*next);
	if (first_seen)
		*first_seen = !found;
	return e->id;
}

static int
path_id(const Path *path, bool *first_seen)
{
	return ptr_id(path_ids, path, &next_path_id, first_seen);
}

/* Call where add_path() frees the path: its address may be reused */
static void
path_freed(const Path *path)
{
	if (!IsA(path, IndexPath))
		hash_search(path_ids, &path, HASH_REMOVE, NULL);
}

static const char *
path_type_name(const Path *path)
{
	if (IsA(path, ProjectionPath))
		return "Projection";

	switch (path->pathtype)
	{
		case T_SeqScan:
			return "SeqScan";
		case T_SampleScan:
			return "SampleScan";
		case T_IndexScan:
			return "IndexScan";
		case T_IndexOnlyScan:
			return "IndexOnlyScan";
		case T_BitmapHeapScan:
			return "BitmapHeapScan";
		case T_TidScan:
			return "TidScan";
		case T_TidRangeScan:
			return "TidRangeScan";
		case T_SubqueryScan:
			return "SubqueryScan";
		case T_FunctionScan:
			return "FunctionScan";
		case T_ValuesScan:
			return "ValuesScan";
		case T_CteScan:
			return "CteScan";
		case T_ForeignScan:
			return "ForeignScan";
		case T_CustomScan:
			return "CustomScan";
		case T_NestLoop:
			return "NestLoop";
		case T_MergeJoin:
			return "MergeJoin";
		case T_HashJoin:
			return "HashJoin";
		case T_Sort:
			return "Sort";
		case T_IncrementalSort:
			return "IncrementalSort";
		case T_Gather:
			return "Gather";
		case T_GatherMerge:
			return "GatherMerge";
		case T_Material:
			return "Material";
		case T_Memoize:
			return "Memoize";
		case T_Result:
			return "Result";
		case T_ProjectSet:
			return "ProjectSet";
		case T_Agg:
			return "Agg";
		case T_Group:
			return "Group";
		case T_Unique:
			return "Unique";
		case T_WindowAgg:
			return "WindowAgg";
		case T_SetOp:
			return "SetOp";
		case T_Append:
			return "Append";
		case T_MergeAppend:
			return "MergeAppend";
		case T_Limit:
			return "Limit";
		case T_LockRows:
			return "LockRows";
		case T_ModifyTable:
			return "ModifyTable";
		default:
			return "Other";
	}
}

/*
 * Index behind a path.  A bitmap heap path is attributed to the index of a
 * single-index bitmap qual; BitmapAnd/BitmapOr report none.
 */
static Oid
path_index_oid(const Path *path)
{
	if (IsA(path, IndexPath))
		return ((const IndexPath *) path)->indexinfo->indexoid;
	if (IsA(path, BitmapHeapPath))
		return path_index_oid(((const BitmapHeapPath *) path)->bitmapqual);
	return InvalidOid;
}

static void
key(StringInfo buf, const char *k)
{
	if (buf->len > 1)
		appendStringInfoChar(buf, ',');
	escape_json(buf, k);
	appendStringInfoChar(buf, ':');
}

static void
put_str(StringInfo buf, const char *k, const char *v)
{
	key(buf, k);
	if (v)
		escape_json(buf, v);
	else
		appendStringInfoString(buf, "null");
}

static void
put_int(StringInfo buf, const char *k, int v)
{
	key(buf, k);
	appendStringInfo(buf, "%d", v);
}

static void
put_bool(StringInfo buf, const char *k, bool v)
{
	key(buf, k);
	appendStringInfoString(buf, v ? "true" : "false");
}

static void
put_num(StringInfo buf, const char *k, double v)
{
	key(buf, k);
	appendStringInfo(buf, "%.2f", v);
}

static void
put_relids(StringInfo buf, const char *k, Relids relids)
{
	int			m = -1;
	bool		first = true;

	key(buf, k);
	appendStringInfoChar(buf, '[');
	while ((m = bms_next_member(relids, m)) >= 0)
	{
		appendStringInfo(buf, first ? "%d" : ",%d", m);
		first = false;
	}
	appendStringInfoChar(buf, ']');
}

static void
put_rel(StringInfo buf, RelOptInfo *rel)
{
	const char *kind;

	switch (rel->reloptkind)
	{
		case RELOPT_BASEREL:
			kind = "base";
			break;
		case RELOPT_JOINREL:
			kind = "join";
			break;
		case RELOPT_OTHER_MEMBER_REL:
			kind = "other_member";
			break;
		case RELOPT_OTHER_JOINREL:
			kind = "other_join";
			break;
		case RELOPT_UPPER_REL:
			kind = "upper";
			break;
		case RELOPT_OTHER_UPPER_REL:
			kind = "other_upper";
			break;
		default:
			kind = "other";
			break;
	}
	put_int(buf, "rel_id", ptr_id(rel_ids, rel, &next_rel_id, NULL));
	put_str(buf, "rel_kind", kind);
	put_relids(buf, "relids", rel->relids);
}

/*
 * Pathkeys as ["v<varno>.<attno> ASC", ...].  Only a Var member is named;
 * anything else is reported as "expr", which is enough to compare two
 * trajectories structurally without deparsing.
 */
static void
put_pathkeys(StringInfo buf, const char *k, List *pathkeys)
{
	ListCell   *lc;
	bool		first = true;

	key(buf, k);
	appendStringInfoChar(buf, '[');
	foreach(lc, pathkeys)
	{
		PathKey    *pk = lfirst_node(PathKey, lc);
		EquivalenceClass *ec = pk->pk_eclass;
		StringInfoData item;

		initStringInfo(&item);
		if (ec->ec_members != NIL &&
			IsA(((EquivalenceMember *) linitial(ec->ec_members))->em_expr, Var))
		{
			Var		   *v = (Var *)
				((EquivalenceMember *) linitial(ec->ec_members))->em_expr;

			appendStringInfo(&item, "v%d.%d", v->varno, v->varattno);
		}
		else
			appendStringInfoString(&item, "expr");
		appendStringInfoString(&item,
							   pk->pk_cmptype == COMPARE_GT ? " DESC" : " ASC");
		if (pk->pk_nulls_first)
			appendStringInfoString(&item, " NULLS FIRST");

		if (!first)
			appendStringInfoChar(buf, ',');
		escape_json(buf, item.data);
		pfree(item.data);
		first = false;
	}
	appendStringInfoChar(buf, ']');
}

static void
put_index(StringInfo buf, const char *k, Oid indexoid)
{
	put_str(buf, k, OidIsValid(indexoid) ? get_rel_name(indexoid) : NULL);
}

/* Path fields, with prefix "" for the subject or "competitor_" */
static void
put_path(StringInfo buf, const char *prefix, const Path *path, int id,
		 bool first_seen)
{
	char		k[64];

#define K(name) (snprintf(k, sizeof(k), "%s%s", prefix, name), k)
	put_int(buf, K("path_id"), id);
	if (first_seen)
		put_bool(buf, K("first_seen"), true);
	put_str(buf, K("path_type"), path_type_name(path));
	put_index(buf, K("index"), path_index_oid(path));
	put_num(buf, K("startup_cost"), path->startup_cost);
	put_num(buf, K("total_cost"), path->total_cost);
	put_num(buf, K("rows"), path->rows);
	put_int(buf, K("disabled_nodes"), path->disabled_nodes);
	put_pathkeys(buf, K("pathkeys"), path->pathkeys);
	put_relids(buf, K("required_outer"), PATH_REQ_OUTER(path));
	put_bool(buf, K("parallel_safe"), path->parallel_safe);
	put_int(buf, K("parallel_workers"), path->parallel_workers);
#undef K
}

static void
begin_event(StringInfo buf, const char *event)
{
	initStringInfo(buf);
	appendStringInfoChar(buf, '{');
	put_str(buf, "event", event);
	put_int(buf, "plan", plan_seq);
	put_int(buf, "seq", ++event_seq);
}

static void
emit(StringInfo buf)
{
	appendStringInfoChar(buf, '}');
	ereport(NOTICE, errmsg_internal("NOODATA %s", buf->data));
	pfree(buf->data);
}

void
noodata_trace_event(const char *name, const void *private_data, void *arg)
{
	StringInfoData buf;

	if (!trace_enabled || path_ids == NULL)
		return;

	if (strcmp(name, "planner-add-path-precheck-reject") == 0)
	{
		PlannerPathPrecheckInjectionData *d = arg;
		bool		first_seen;
		int			old_id = path_id(d->old_path, &first_seen);

		begin_event(&buf, "PRECHECK_REJECTED");
		put_rel(&buf, d->parent_rel);
		/* no Path exists yet, so no id and no type */
		key(&buf, "path_id");
		appendStringInfoString(&buf, "null");
		put_str(&buf, "path_type", NULL);
		put_num(&buf, "startup_cost", d->startup_cost);
		put_num(&buf, "total_cost", d->total_cost);
		put_int(&buf, "disabled_nodes", d->disabled_nodes);
		put_pathkeys(&buf, "pathkeys", d->pathkeys);
		put_relids(&buf, "required_outer", d->required_outer);
		put_path(&buf, "competitor_", d->old_path, old_id, first_seen);
		emit(&buf);
	}
	else if (strcmp(name, "planner-index-path-generated") == 0 ||
			 strcmp(name, "planner-index-path-not-generated") == 0)
	{
		PlannerIndexPathInjectionData *d = arg;
		bool		born = (name[strlen("planner-index-path-")] == 'g');

		begin_event(&buf, born ? "INDEX_PATH_GENERATED" :
					"INDEX_PATH_NOT_GENERATED");
		put_rel(&buf, d->rel);
		put_index(&buf, "index", d->index->indexoid);
		put_str(&buf, "table",
				get_rel_name(IndexGetRelation(d->index->indexoid, false)));
		put_relids(&buf, "required_outer", d->required_outer);
		put_bool(&buf, "bitmap_only", d->bitmap_only);
		put_bool(&buf, "has_index_clauses", d->has_index_clauses);
		put_bool(&buf, "has_useful_pathkeys", d->has_useful_pathkeys);
		put_bool(&buf, "has_useful_backward_pathkeys",
				 d->has_useful_backward_pathkeys);
		put_bool(&buf, "useful_predicate", d->useful_predicate);
		put_bool(&buf, "index_only_scan", d->index_only_scan);
		put_int(&buf, "npaths", d->npaths);
		emit(&buf);
	}
	else
	{
		PlannerPathComparisonInjectionData *d = arg;

		if (strcmp(name, "planner-add-path-accept") == 0)
		{
			int			id = path_id(d->new_path, NULL);

			begin_event(&buf, "ACCEPTED");
			put_rel(&buf, d->parent_rel);
			put_path(&buf, "", d->new_path, id, false);
		}
		else if (strcmp(name, "planner-add-path-reject") == 0)
		{
			int			id = path_id(d->new_path, NULL);
			bool		first_seen;
			int			old_id = path_id(d->old_path, &first_seen);

			begin_event(&buf, "REJECTED");
			put_rel(&buf, d->parent_rel);
			put_path(&buf, "", d->new_path, id, false);
			put_path(&buf, "competitor_", d->old_path, old_id, first_seen);
			path_freed(d->new_path);
		}
		else
		{
			bool		first_seen;
			int			old_id = path_id(d->old_path, &first_seen);
			int			id = path_id(d->new_path, NULL);

			begin_event(&buf, "DISPLACED");
			put_rel(&buf, d->parent_rel);
			/* the displaced path is the subject; first_seen is about it */
			put_path(&buf, "", d->old_path, old_id, first_seen);
			put_path(&buf, "competitor_", d->new_path, id, false);
			path_freed(d->old_path);
		}
		emit(&buf);
	}
}

Datum
noodata_trace_attach(PG_FUNCTION_ARGS)
{
	for (int i = 0; i < lengthof(trace_points); i++)
		InjectionPointAttach(trace_points[i], "noodata_trace",
							 "noodata_trace_event", NULL, 0);
	PG_RETURN_VOID();
}

Datum
noodata_trace_detach(PG_FUNCTION_ARGS)
{
	for (int i = 0; i < lengthof(trace_points); i++)
		(void) InjectionPointDetach(trace_points[i]);
	PG_RETURN_VOID();
}

void
_PG_init(void)
{
	DefineCustomBoolVariable("noodata_trace.enabled",
							 "Emit planner trajectory events as NOTICE lines.",
							 NULL,
							 &trace_enabled,
							 false,
							 PGC_USERSET,
							 0,
							 NULL, NULL, NULL);
	MarkGUCPrefixReserved("noodata_trace");

	prev_planner_hook = planner_hook;
	planner_hook = noodata_planner;
}
