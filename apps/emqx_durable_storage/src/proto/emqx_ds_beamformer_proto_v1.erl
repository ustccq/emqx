%%--------------------------------------------------------------------
%% Copyright (c) 2024-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------
-module(emqx_ds_beamformer_proto_v1).

-behavior(emqx_bpapi).

-include_lib("emqx_utils/include/bpapi.hrl").
%% API:
-export([
    where/2,
    subscribe/6,
    unsubscribe/3,
    suback_a/4,
    subscription_info/3
]).

%% behavior callbacks:
-export([introduced_in/0]).

%%================================================================================
%% API functions
%%================================================================================

-spec where(node(), emqx_ds_beamformer:dbshard()) ->
    pid() | undefined | {error, _}.
where(Node, DBShard) ->
    erpc:call(Node, emqx_ds_beamformer, where, [DBShard]).

-spec subscribe(
    node(),
    pid(),
    pid(),
    emqx_ds:sub_ref(),
    _Iterator,
    emqx_ds:sub_opts()
) ->
    {ok, emqx_ds:sub_ref()} | emqx_ds:error(_).
subscribe(Node, Server, Client, SubRef, It, Opts) ->
    erpc:call(Node, emqx_ds_beamformer, subscribe, [Server, Client, SubRef, It, Opts]).

-spec unsubscribe(
    node(),
    emqx_ds_beamformer:dbshard(),
    emqx_ds:sub_ref()
) ->
    boolean().
unsubscribe(Node, DBShard, SubRef) ->
    erpc:call(Node, emqx_ds_beamformer, unsubscribe, [DBShard, SubRef]).

%% @doc Ack seqno asynchronously:
-spec suback_a(
    node(),
    emqx_ds_beamformer:dbshard(),
    emqx_ds:sub_ref(),
    emqx_ds:sub_seqno()
) -> ok.
suback_a(Node, DBShard, SubRef, SeqNo) ->
    erpc:cast(Node, emqx_ds_beamformer, suback, [DBShard, SubRef, SeqNo]).

%% @doc Lookup subscription info:
-spec subscription_info(
    node(),
    emqx_ds_beamformer:dbshard(),
    emqx_ds:sub_ref()
) ->
    emqx_ds:sub_info() | undefined.
subscription_info(Node, DBShard, SubRef) ->
    erpc:call(Node, emqx_ds_beamformer, subscription_info, [DBShard, SubRef]).

%%================================================================================
%% behavior callbacks
%%================================================================================

introduced_in() ->
    "5.9.0".
