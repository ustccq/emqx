%%--------------------------------------------------------------------
%% Copyright (c) 2022-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_dashboard_proto_v1).

-behaviour(emqx_bpapi).

-export([
    introduced_in/0,
    do_sample/2,
    current_rate/1,
    deprecated_since/0
]).

-include("emqx_dashboard.hrl").
-include_lib("emqx/include/bpapi.hrl").

introduced_in() ->
    "5.0.0".

deprecated_since() ->
    "5.8.4".

-spec do_sample(node(), Latest :: pos_integer() | infinity) -> list(map()) | emqx_rpc:badrpc().
do_sample(Node, Latest) ->
    rpc:call(Node, emqx_dashboard_monitor, do_sample, [Node, Latest], ?RPC_TIMEOUT).

-spec current_rate(node()) -> {ok, map()} | emqx_rpc:badrpc().
current_rate(Node) ->
    rpc:call(Node, emqx_dashboard_monitor, current_rate, [Node], ?RPC_TIMEOUT).
