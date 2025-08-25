%%--------------------------------------------------------------------
%% Copyright (c) 2022-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_management_proto_v4).

-behaviour(emqx_bpapi).

-export([
    introduced_in/0,

    node_info/1,
    broker_info/1,
    list_subscriptions/1,

    list_listeners/1,
    subscribe/3,
    unsubscribe/3,
    unsubscribe_batch/3,

    call_client/3,

    get_full_config/1,

    kickout_clients/2
]).

-include_lib("emqx/include/bpapi.hrl").

introduced_in() ->
    "5.1.0".

-spec unsubscribe_batch(node(), emqx_types:clientid(), [emqx_types:topic()]) ->
    {unsubscribe, _} | {error, _} | {badrpc, _}.
unsubscribe_batch(Node, ClientId, Topics) ->
    rpc:call(Node, emqx_mgmt, do_unsubscribe_batch, [ClientId, Topics]).

-spec node_info([node()]) -> emqx_rpc:erpc_multicall(map()).
node_info(Nodes) ->
    erpc:multicall(Nodes, emqx_mgmt, node_info, [], 30000).

-spec broker_info([node()]) -> emqx_rpc:erpc_multicall(map()).
broker_info(Nodes) ->
    erpc:multicall(Nodes, emqx_mgmt, broker_info, [], 30000).

-spec list_subscriptions(node()) -> [map()] | {badrpc, _}.
list_subscriptions(Node) ->
    rpc:call(Node, emqx_mgmt, do_list_subscriptions, []).

-spec list_listeners(node()) -> map() | {badrpc, _}.
list_listeners(Node) ->
    rpc:call(Node, emqx_mgmt_api_listeners, do_list_listeners, []).

-spec subscribe(node(), emqx_types:clientid(), emqx_types:topic_filters()) ->
    {subscribe, _} | {error, atom()} | {badrpc, _}.
subscribe(Node, ClientId, TopicTables) ->
    rpc:call(Node, emqx_mgmt, do_subscribe, [ClientId, TopicTables]).

-spec unsubscribe(node(), emqx_types:clientid(), emqx_types:topic()) ->
    {unsubscribe, _} | {error, _} | {badrpc, _}.
unsubscribe(Node, ClientId, Topic) ->
    rpc:call(Node, emqx_mgmt, do_unsubscribe, [ClientId, Topic]).

-spec call_client(node(), emqx_types:clientid(), term()) -> term().
call_client(Node, ClientId, Req) ->
    rpc:call(Node, emqx_mgmt, do_call_client, [ClientId, Req]).

-spec get_full_config(node()) -> map() | list() | {badrpc, _}.
get_full_config(Node) ->
    rpc:call(Node, emqx_mgmt_api_configs, get_full_config, []).

-spec kickout_clients(node(), [emqx_types:clientid()]) -> ok | {badrpc, _}.
kickout_clients(Node, ClientIds) ->
    rpc:call(Node, emqx_mgmt, do_kickout_clients, [ClientIds]).
