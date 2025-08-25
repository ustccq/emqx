%%--------------------------------------------------------------------
%% Copyright (c) 2022-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_proto_v2).

-behaviour(emqx_bpapi).

-include("bpapi.hrl").

-export([
    introduced_in/0,

    are_running/1,
    is_running/1,

    get_alarms/2,
    get_stats/1,
    get_metrics/1,

    deactivate_alarm/2,
    delete_all_deactivated_alarms/1,

    clean_authz_cache/1,
    clean_authz_cache/2,
    clean_pem_cache/1
]).

introduced_in() ->
    "5.0.22".

-spec is_running(node()) -> boolean() | {badrpc, term()}.
is_running(Node) ->
    rpc:call(Node, emqx, is_running, []).

-spec are_running([node()]) -> emqx_rpc:erpc_multicall(boolean()).
are_running(Nodes) when is_list(Nodes) ->
    erpc:multicall(Nodes, emqx, is_running, []).

-spec get_alarms(node(), all | activated | deactivated) -> [map()].
get_alarms(Node, Type) ->
    rpc:call(Node, emqx_alarm, get_alarms, [Type]).

-spec get_stats(node()) -> emqx_stats:stats() | {badrpc, _}.
get_stats(Node) ->
    rpc:call(Node, emqx_stats, getstats, []).

-spec get_metrics(node()) -> [{emqx_metrics:metric_name(), non_neg_integer()}] | {badrpc, _}.
get_metrics(Node) ->
    rpc:call(Node, emqx_metrics, all, []).

-spec clean_authz_cache(node(), emqx_types:clientid()) ->
    ok
    | {error, not_found}
    | {badrpc, _}.
clean_authz_cache(Node, ClientId) ->
    rpc:call(Node, emqx_authz_cache, drain_cache, [ClientId]).

-spec clean_authz_cache(node()) -> ok | {badrpc, _}.
clean_authz_cache(Node) ->
    rpc:call(Node, emqx_authz_cache, drain_cache, []).

-spec clean_pem_cache(node()) -> ok | {badrpc, _}.
clean_pem_cache(Node) ->
    rpc:call(Node, ssl_pem_cache, clear, []).

-spec deactivate_alarm(node(), binary() | atom()) ->
    ok | {error, not_found} | {badrpc, _}.
deactivate_alarm(Node, Name) ->
    rpc:call(Node, emqx_alarm, deactivate, [Name]).

-spec delete_all_deactivated_alarms(node()) -> ok | {badrpc, _}.
delete_all_deactivated_alarms(Node) ->
    rpc:call(Node, emqx_alarm, delete_all_deactivated_alarms, []).
