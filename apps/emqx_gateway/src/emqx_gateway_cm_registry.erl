%%--------------------------------------------------------------------
%% Copyright (c) 2021-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

%% @doc The gateway connection registry
-module(emqx_gateway_cm_registry).

-include("emqx_gateway.hrl").

-behaviour(gen_server).

-export([start_link/1]).

-export([
    register_channel/2,
    unregister_channel/2
]).

-export([lookup_channels/2, get_connected_client_count/0]).

-export([tabname/1]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

%% Internal exports (RPC)
-export([
    do_cleanup_channels/2
]).

-define(CM_SHARD, emqx_gateway_cm_shard).
-define(LOCK, {?MODULE, cleanup_down}).

-record(channel, {chid, pid}).

%% @doc Start the global channel registry for the given gateway name.
-spec start_link(gateway_name()) -> emqx_types:startlink_ret().
start_link(Name) ->
    gen_server:start_link(?MODULE, [Name], []).

-spec tabname(gateway_name()) -> atom().
tabname(Name) ->
    %% XXX: unsafe ??
    list_to_atom(lists:concat([emqx_gateway_, Name, '_channel_registry'])).

%%--------------------------------------------------------------------
%% APIs
%%--------------------------------------------------------------------

%% @doc Register a global channel.
-spec register_channel(gateway_name(), binary() | {binary(), pid()}) -> ok.
register_channel(Name, ClientId) when is_binary(ClientId) ->
    register_channel(Name, {ClientId, self()});
register_channel(Name, {ClientId, ChanPid}) when
    is_binary(ClientId), is_pid(ChanPid)
->
    mria:dirty_write(tabname(Name), record(ClientId, ChanPid)).

%% @doc Unregister a global channel.
-spec unregister_channel(gateway_name(), binary() | {binary(), pid()}) -> ok.
unregister_channel(Name, ClientId) when is_binary(ClientId) ->
    unregister_channel(Name, {ClientId, self()});
unregister_channel(Name, {ClientId, ChanPid}) when
    is_binary(ClientId), is_pid(ChanPid)
->
    mria:dirty_delete_object(tabname(Name), record(ClientId, ChanPid)).

%% @doc Lookup the global channels.
-spec lookup_channels(gateway_name(), binary()) -> list(pid()).
lookup_channels(Name, ClientId) ->
    [
        ChanPid
     || #channel{pid = ChanPid} <- mnesia:dirty_read(tabname(Name), ClientId)
    ].

record(ClientId, ChanPid) ->
    #channel{chid = ClientId, pid = ChanPid}.

get_connected_client_count() ->
    Gatewyas = emqx_gateway_utils:find_gateway_definitions(),
    Fun = fun(#{name := Name}, Acc) ->
        Tab = tabname(Name),
        case ets:info(Tab, size) of
            undefined ->
                Acc;
            Size ->
                Acc + Size
        end
    end,
    lists:foldl(Fun, 0, Gatewyas).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([Name]) ->
    Tab = tabname(Name),
    ok = mria:create_table(Tab, [
        {type, bag},
        {rlog_shard, ?CM_SHARD},
        {storage, ram_copies},
        {record_name, channel},
        {attributes, record_info(fields, channel)},
        {storage_properties, [
            {ets, [
                {read_concurrency, true},
                {write_concurrency, true}
            ]}
        ]}
    ]),
    ok = mria:wait_for_tables([Tab]),
    ok = ekka:monitor(membership),
    {ok, #{name => Name}}.

handle_call(Req, _From, State) ->
    logger:error("Unexpected call: ~p", [Req]),
    {reply, ignored, State}.

handle_cast(Msg, State) ->
    logger:error("Unexpected cast: ~p", [Msg]),
    {noreply, State}.

handle_info({membership, {mnesia, down, Node}}, State = #{name := Name}) ->
    cleanup_channels(Node, Name),
    {noreply, State};
handle_info({membership, {node, down, Node}}, State = #{name := Name}) ->
    cleanup_channels(Node, Name),
    {noreply, State};
handle_info({membership, _Event}, State) ->
    {noreply, State};
handle_info(Info, State) ->
    logger:error("Unexpected info: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

cleanup_channels(Node, Name) ->
    Tab = tabname(Name),
    global:trans(
        {?LOCK, self()},
        fun() ->
            mria:transaction(?CM_SHARD, fun ?MODULE:do_cleanup_channels/2, [Node, Tab])
        end
    ).

do_cleanup_channels(Node, Tab) ->
    Pat = [{#channel{pid = '$1', _ = '_'}, [{'==', {node, '$1'}, Node}], ['$_']}],
    lists:foreach(
        fun(Chan) ->
            mnesia:delete_object(Tab, Chan, write)
        end,
        mnesia:select(Tab, Pat, write)
    ).
