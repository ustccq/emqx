%%--------------------------------------------------------------------
%% Copyright (c) 2022-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------
-module(emqx_bpapi).

%% API:
-export([
    start/0,
    announce/2,
    nodes_supporting_bpapi_version/2,
    supported_version/1, supported_version/2,
    supported_apis/1,
    versions_file/1
]).

%% Internal exports (RPC)
-export([
    announce_fun/1,
    announce_fun/2
]).

-export_type([api/0, api_version/0, var_name/0, call/0, rpc/0, bpapi_meta/0]).

-include_lib("stdlib/include/ms_transform.hrl").

-type api() :: atom().
-type api_version() :: non_neg_integer().
-type var_name() :: atom().
-type call() :: {module(), atom(), [var_name()]}.
-type rpc() :: {_From :: call(), _To :: call()}.

-type bpapi_meta() ::
    #{
        api := api(),
        version := api_version(),
        calls := [rpc()],
        casts := [rpc()]
    }.

-include("emqx_bpapi.hrl").

-callback introduced_in() -> string().

-callback deprecated_since() -> string().

-callback bpapi_meta() -> bpapi_meta().

-optional_callbacks([deprecated_since/0]).

-define(BPAPI_SHARD, emqx_common_shard).

-spec start() -> ok.
start() ->
    ok = mria:create_table(?TAB, [
        {type, set},
        {storage, ram_copies},
        {attributes, record_info(fields, ?TAB)},
        {rlog_shard, ?BPAPI_SHARD}
    ]),
    ok = mria:wait_for_tables([?TAB]),
    announce(node(), emqx).

%% @doc Get maximum version of the backplane API supported by the node
-spec supported_version(node(), api()) -> api_version() | undefined.
supported_version(Node, API) ->
    case ets:lookup(?TAB, {Node, API}) of
        [#?TAB{version = V}] -> V;
        [] -> undefined
    end.

%% @doc Get maximum version of the backplane API supported by the
%% entire cluster
-spec supported_version(api()) -> api_version().
supported_version(API) ->
    ets:lookup_element(?TAB, {?multicall, API}, #?TAB.version).

-spec supported_apis(node()) -> [{api(), api_version()}].
supported_apis(Node) ->
    try
        lists:flatten(ets:match(?TAB, {?TAB, {Node, '$1'}, '$2'}))
    catch
        error:badarg ->
            []
    end.

-spec announce(node(), atom()) -> ok.
announce(Node, App) ->
    {ok, Data} = file:consult(?MODULE:versions_file(App)),
    %% replicant(5.6.0) will call old core(<5.6.0) announce_fun/2 is undef on old core
    %% so we just use anonymous function to update.
    case mria:transaction(?BPAPI_SHARD, fun ?MODULE:announce_fun/2, [Node, Data]) of
        {atomic, ok} ->
            ok;
        {aborted, {undef, [{?MODULE, announce_fun, _, _} | _]}} ->
            {atomic, ok} = mria:transaction(
                ?BPAPI_SHARD,
                fun() ->
                    MS = ets:fun2ms(fun(#?TAB{key = {N, API}}) when N =:= Node ->
                        {N, API}
                    end),
                    OldKeys = mnesia:select(?TAB, MS, write),
                    _ = [
                        mnesia:delete({?TAB, Key})
                     || Key <- OldKeys
                    ],
                    %% Insert new records:
                    _ = [
                        mnesia:write(#?TAB{key = {Node, API}, version = Version})
                     || {API, Version} <- Data
                    ],
                    %% Update maximum supported version:
                    _ = [update_minimum(API) || {API, _} <- Data],
                    ok
                end
            ),
            ok
    end.

-spec versions_file(atom()) -> file:filename_all().
versions_file(App) ->
    filename:join(code:priv_dir(App), "bpapi.versions").

-spec nodes_supporting_bpapi_version(api(), api_version()) -> [node()].
nodes_supporting_bpapi_version(BPAPIName, Vsn) ->
    [
        N
     || N <- emqx:running_nodes(),
        case emqx_bpapi:supported_version(N, BPAPIName) of
            undefined -> false;
            NVsn when is_number(NVsn) -> NVsn >= Vsn
        end
    ].

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

%% Attention:
%% This function is just to prevent errors when being called during a rolling upgrade
%% if the version is less than 5.5.0. Its 'node' parameter is wrong!
-spec announce_fun([{api(), api_version()}]) -> ok.
announce_fun(Data) ->
    announce_fun(node(), Data).

-spec announce_fun(node(), [{api(), api_version()}]) -> ok.
announce_fun(Node, Data) ->
    %% Delete old records, if present:
    MS = ets:fun2ms(fun(#?TAB{key = {N, API}}) when N =:= Node ->
        {N, API}
    end),
    OldKeys = mnesia:select(?TAB, MS, write),
    _ = [
        mnesia:delete({?TAB, Key})
     || Key <- OldKeys
    ],
    %% Insert new records:
    _ = [
        mnesia:write(#?TAB{key = {Node, API}, version = Version})
     || {API, Version} <- Data
    ],
    %% Update maximum supported version:
    [update_minimum(API) || {API, _} <- Data],
    ok.

-spec update_minimum(api()) -> ok.
update_minimum(API) ->
    MS = ets:fun2ms(fun(
        #?TAB{
            key = {N, A},
            version = Value
        }
    ) when
        N =/= ?multicall,
        A =:= API
    ->
        Value
    end),
    MinVersion = lists:min(mnesia:select(?TAB, MS)),
    mnesia:write(#?TAB{key = {?multicall, API}, version = MinVersion}).
