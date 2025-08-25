%%--------------------------------------------------------------------
%% Copyright (c) 2022-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_bridge_proto_v3).

-behaviour(emqx_bpapi).

-export([
    introduced_in/0,
    deprecated_since/0,

    list_bridges/1,
    list_bridges_on_nodes/1,
    restart_bridge_to_node/3,
    start_bridge_to_node/3,
    stop_bridge_to_node/3,
    lookup_from_all_nodes/3,
    restart_bridges_to_all_nodes/3,
    start_bridges_to_all_nodes/3,
    stop_bridges_to_all_nodes/3
]).

-include_lib("emqx/include/bpapi.hrl").

-define(TIMEOUT, 15000).

introduced_in() ->
    "5.0.21".

deprecated_since() ->
    "5.0.22".

-spec list_bridges(node()) -> list() | emqx_rpc:badrpc().
list_bridges(Node) ->
    rpc:call(Node, emqx_bridge, list, [], ?TIMEOUT).

-spec list_bridges_on_nodes([node()]) ->
    emqx_rpc:erpc_multicall([emqx_resource:resource_data()]).
list_bridges_on_nodes(Nodes) ->
    erpc:multicall(Nodes, emqx_bridge, list, [], ?TIMEOUT).

-type key() :: atom() | binary() | [byte()].

-spec restart_bridge_to_node(node(), key(), key()) ->
    term().
restart_bridge_to_node(Node, BridgeType, BridgeName) ->
    rpc:call(
        Node,
        emqx_bridge_resource,
        restart,
        [BridgeType, BridgeName],
        ?TIMEOUT
    ).

-spec start_bridge_to_node(node(), key(), key()) ->
    term().
start_bridge_to_node(Node, BridgeType, BridgeName) ->
    rpc:call(
        Node,
        emqx_bridge_resource,
        start,
        [BridgeType, BridgeName],
        ?TIMEOUT
    ).

-spec stop_bridge_to_node(node(), key(), key()) ->
    term().
stop_bridge_to_node(Node, BridgeType, BridgeName) ->
    rpc:call(
        Node,
        emqx_bridge_resource,
        stop,
        [BridgeType, BridgeName],
        ?TIMEOUT
    ).

-spec restart_bridges_to_all_nodes([node()], key(), key()) ->
    emqx_rpc:erpc_multicall(ok).
restart_bridges_to_all_nodes(Nodes, BridgeType, BridgeName) ->
    erpc:multicall(
        Nodes,
        emqx_bridge_resource,
        restart,
        [BridgeType, BridgeName],
        ?TIMEOUT
    ).

-spec start_bridges_to_all_nodes([node()], key(), key()) ->
    emqx_rpc:erpc_multicall(ok).
start_bridges_to_all_nodes(Nodes, BridgeType, BridgeName) ->
    erpc:multicall(
        Nodes,
        emqx_bridge_resource,
        start,
        [BridgeType, BridgeName],
        ?TIMEOUT
    ).

-spec stop_bridges_to_all_nodes([node()], key(), key()) ->
    emqx_rpc:erpc_multicall(ok).
stop_bridges_to_all_nodes(Nodes, BridgeType, BridgeName) ->
    erpc:multicall(
        Nodes,
        emqx_bridge_resource,
        stop,
        [BridgeType, BridgeName],
        ?TIMEOUT
    ).

-spec lookup_from_all_nodes([node()], key(), key()) ->
    emqx_rpc:erpc_multicall(term()).
lookup_from_all_nodes(Nodes, BridgeType, BridgeName) ->
    erpc:multicall(
        Nodes,
        emqx_bridge_api,
        lookup_from_local_node,
        [BridgeType, BridgeName],
        ?TIMEOUT
    ).
