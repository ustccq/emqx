%%--------------------------------------------------------------------
%% Copyright (c) 2021-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

%% @doc Manage the server status and reload strategy
-module(emqx_exhook_mgr).

-behaviour(gen_server).
-behaviour(emqx_config_backup).

-include("emqx_exhook.hrl").
-include_lib("emqx/include/logger.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").

-define(SERVERS, [exhook, servers]).
-define(EXHOOK_ROOT, exhook).
-define(EXHOOK, [?EXHOOK_ROOT]).

%% APIs
-export([start_link/0]).

%% Mgmt API
-export([
    list/0,
    lookup/1,
    enable/1,
    disable/1,
    server_info/1,
    all_servers_info/0,
    server_hooks_metrics/1
]).

%% Helper funcs
-export([
    running/0,
    service/1,
    hooks/1,
    init_ref_counter_table/0
]).

-export([
    update_config/2,
    pre_config_update/3,
    post_config_update/5
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-export([roots/0]).

%% Data backup
-export([
    import_config/2
]).

-export_type([
    server_name/0
]).

%% Running servers
-type state() :: #{servers := servers()}.

-type server_options() :: map().
-type server_name() :: binary().

-type status() ::
    connected
    %% only for trying reload
    | connecting
    | disconnected
    | disabled.

-type server() :: #{
    status => status(),
    timer => undefined | reference(),
    order => integer(),
    %% include the content of server_options
    atom() => any()
}.
-type servers() :: #{server_name() => server()}.

-type position() ::
    front
    | rear
    | {before, binary()}
    | {'after', binary()}.

-define(DEFAULT_TIMEOUT, 60000).
-define(REFRESH_INTERVAL, timer:seconds(5)).

-export_type([servers/0, server/0]).

%%----------------------------------------------------------------------------------------
%% APIs
%%----------------------------------------------------------------------------------------

-spec start_link() ->
    ignore
    | {ok, pid()}
    | {error, any()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

list() ->
    call(list).

-spec lookup(server_name()) -> not_found | server().
lookup(Name) ->
    call({lookup, Name}).

enable(Name) ->
    update_config([exhook, servers], {enable, Name, true}).

disable(Name) ->
    update_config([exhook, servers], {enable, Name, false}).

server_info(Name) ->
    call({?FUNCTION_NAME, Name}).

all_servers_info() ->
    call(?FUNCTION_NAME).

server_hooks_metrics(Name) ->
    call({?FUNCTION_NAME, Name}).

call(Req) ->
    gen_server:call(?MODULE, Req, ?DEFAULT_TIMEOUT).

init_ref_counter_table() ->
    _ = ets:new(?HOOKS_REF_COUNTER, [named_table, public]).

%%========================================================================================
%% Hocon schema
roots() ->
    emqx_exhook_schema:server_config().

update_config(KeyPath, UpdateReq) ->
    case emqx_conf:update(KeyPath, UpdateReq, #{override_to => cluster}) of
        {ok, UpdateResult} ->
            #{post_config_update := #{?MODULE := Result}} = UpdateResult,
            {ok, Result};
        Error ->
            Error
    end.

pre_config_update(?SERVERS, {add, #{<<"name">> := Name} = Conf}, OldConf) ->
    case lists:any(fun(#{<<"name">> := ExistedName}) -> ExistedName =:= Name end, OldConf) of
        true ->
            throw(already_exists);
        false ->
            NConf = maybe_write_certs(Conf),
            {ok, OldConf ++ [NConf]}
    end;
pre_config_update(?SERVERS, {update, Name, Conf}, OldConf) ->
    NewConf = replace_conf(Name, fun(_) -> Conf end, OldConf),
    {ok, lists:map(fun maybe_write_certs/1, NewConf)};
pre_config_update(?SERVERS, {delete, ToDelete}, OldConf) ->
    {ok, do_delete(ToDelete, OldConf)};
pre_config_update(?SERVERS, {move, Name, Position}, OldConf) ->
    {ok, do_move(Name, Position, OldConf)};
pre_config_update(?SERVERS, {enable, Name, Enable}, OldConf) ->
    ReplaceFun = fun(Conf) -> Conf#{<<"enable">> => Enable} end,
    NewConf = replace_conf(Name, ReplaceFun, OldConf),
    {ok, lists:map(fun maybe_write_certs/1, NewConf)};
pre_config_update(?EXHOOK, NewConf, _OldConf) when NewConf =:= #{} ->
    {ok, NewConf#{<<"servers">> => []}};
pre_config_update(?EXHOOK, NewConf = #{<<"servers">> := Servers}, _OldConf) ->
    {ok, NewConf#{<<"servers">> => lists:map(fun maybe_write_certs/1, Servers)}}.

post_config_update(_KeyPath, UpdateReq, NewConf, OldConf, _AppEnvs) ->
    Result = call({update_config, UpdateReq, NewConf, OldConf}),
    {ok, Result}.

%%========================================================================================

%%----------------------------------------------------------------------------------------
%% Data backup
%%----------------------------------------------------------------------------------------

import_config(_Namespace, #{<<"exhook">> := #{<<"servers">> := Servers} = ExHook}) ->
    OldServers = emqx:get_raw_config(?SERVERS, []),
    KeyFun = fun(#{<<"name">> := Name}) -> Name end,
    ExHook1 = ExHook#{<<"servers">> => emqx_utils:merge_lists(OldServers, Servers, KeyFun)},
    case emqx_conf:update(?EXHOOK, ExHook1, #{override_to => cluster}) of
        {ok, #{raw_config := #{<<"servers">> := NewRawServers}}} ->
            Changed = maps:get(changed, emqx_utils:diff_lists(NewRawServers, OldServers, KeyFun)),
            ChangedPaths = [?SERVERS ++ [Name] || {#{<<"name">> := Name}, _} <- Changed],
            {ok, #{root_key => ?EXHOOK_ROOT, changed => ChangedPaths}};
        Error ->
            {error, #{root_key => ?EXHOOK_ROOT, reason => Error}}
    end;
import_config(_Namespace, _RawConf) ->
    {ok, #{root_key => ?EXHOOK_ROOT, changed => []}}.

%%----------------------------------------------------------------------------------------
%% gen_server callbacks
%%----------------------------------------------------------------------------------------

init([]) ->
    process_flag(trap_exit, true),
    emqx_conf:add_handler(?EXHOOK, ?MODULE),
    emqx_conf:add_handler(?SERVERS, ?MODULE),
    ServerL = emqx:get_config(?SERVERS),
    Servers = load_all_servers(ServerL),
    Servers2 = reorder(ServerL, Servers),
    refresh_tick(),
    {ok, #{servers => Servers2}}.

-spec load_all_servers(list(server_options())) -> servers().
load_all_servers(ServerL) ->
    load_all_servers(ServerL, #{}).

load_all_servers([#{name := Name} = Options | More], Servers) ->
    {_, Server} = do_load_server(opts_to_state(Options)),
    load_all_servers(More, Servers#{Name => Server});
load_all_servers([], Servers) ->
    Servers.

handle_call(
    list,
    _From,
    State = #{servers := Servers}
) ->
    Infos = get_servers_info(Servers),
    OrderServers = sort_name_by_order(Infos, Servers),
    {reply, OrderServers, State};
handle_call(
    {update_config, {move, _Name, _Position}, NewConfL, _},
    _From,
    #{servers := Servers} = State
) ->
    Servers2 = reorder(NewConfL, Servers),
    {reply, ok, State#{servers := Servers2}};
handle_call({update_config, {delete, ToDelete}, _, _}, _From, State) ->
    {reply, ok, remove_server(ToDelete, State)};
handle_call(
    {update_config, {add, RawConf}, NewConfL, _},
    _From,
    #{servers := Servers} = State
) ->
    {_, #{name := Name} = Conf} = emqx_config:check_config(?MODULE, RawConf),
    {Result, Server} = do_load_server(opts_to_state(Conf)),
    Servers2 = Servers#{Name => Server},
    Servers3 = reorder(NewConfL, Servers2),
    {reply, Result, State#{servers := Servers3}};
handle_call({update_config, {update, Name, _Conf}, NewConfL, _}, _From, State) ->
    {Result, State2} = restart_server(Name, NewConfL, State),
    {reply, Result, State2};
handle_call({update_config, {enable, Name, _Enable}, NewConfL, _}, _From, State) ->
    {Result, State2} = restart_server(Name, NewConfL, State),
    {reply, Result, State2};
handle_call({update_config, _, ConfL, ConfL}, _From, State) ->
    {reply, ok, State};
handle_call({update_config, _, #{servers := NewConfL}, #{servers := OldConfL}}, _From, State) ->
    #{
        removed := Removed,
        added := Added,
        changed := Updated
    } = emqx_utils:diff_lists(NewConfL, OldConfL, fun(#{name := Name}) -> Name end),
    State2 = remove_servers(Removed, State),
    {UpdateRes, State3} = restart_servers(Updated, NewConfL, State2),
    {AddRes, State4 = #{servers := Servers4}} = add_servers(Added, State3),
    State5 = State4#{servers => reorder(NewConfL, Servers4)},
    case UpdateRes =:= [] andalso AddRes =:= [] of
        true -> {reply, ok, State5};
        false -> {reply, {error, #{added => AddRes, updated => UpdateRes}}, State5}
    end;
handle_call({lookup, Name}, _From, State) ->
    {reply, where_is_server(Name, State), State};
handle_call({server_info, Name}, _From, State) ->
    case where_is_server(Name, State) of
        not_found ->
            Result = not_found;
        #{status := Status} ->
            HooksMetrics = emqx_exhook_metrics:server_metrics(Name),
            Result = #{
                status => Status,
                metrics => HooksMetrics
            }
    end,
    {reply, Result, State};
handle_call(
    all_servers_info,
    _From,
    #{servers := Servers} = State
) ->
    Status = map_each_server(fun({Name, #{status := Status}}) -> {Name, Status} end, Servers),
    Metrics = emqx_exhook_metrics:servers_metrics(),

    Result = #{
        status => Status,
        metrics => Metrics
    },

    {reply, Result, State};
handle_call({server_hooks_metrics, Name}, _From, State) ->
    Result = emqx_exhook_metrics:hooks_metrics(Name),
    {reply, Result, State};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

remove_servers(Removes, State) ->
    lists:foldl(
        fun(Conf, Acc) ->
            ToDelete = maps:get(name, Conf),
            remove_server(ToDelete, Acc)
        end,
        State,
        Removes
    ).

remove_server(ToDelete, State) ->
    emqx_exhook_metrics:on_server_deleted(ToDelete),
    #{servers := Servers} = State2 = do_unload_server(ToDelete, State),
    Servers2 = maps:remove(ToDelete, Servers),
    update_servers(Servers2, State2).

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({timeout, _Ref, {reload, Name}}, State) ->
    {_, NState} = do_reload_server(Name, State),
    {noreply, NState};
handle_info(refresh_tick, #{servers := Servers} = State) ->
    refresh_tick(),
    emqx_exhook_metrics:update(?REFRESH_INTERVAL),
    NServers = map_each_server(
        fun({Name, Server}) -> {Name, do_health_check(Server)} end,
        Servers
    ),
    {noreply, State#{servers => NServers}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(Reason, State = #{servers := Servers}) ->
    _ = unload_exhooks(),
    _ = maps:fold(
        fun(Name, _, AccIn) ->
            do_unload_server(Name, AccIn)
        end,
        State,
        Servers
    ),
    ?tp(info, exhook_mgr_terminated, #{reason => Reason, servers => Servers}),
    emqx_conf:remove_handler(?SERVERS),
    emqx_conf:remove_handler(?EXHOOK),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%----------------------------------------------------------------------------------------
%% Internal funcs
%%----------------------------------------------------------------------------------------

unload_exhooks() ->
    [
        emqx_hooks:del(Name, {M, F})
     || {Name, {M, F, _A}} <- ?ENABLED_HOOKS
    ].

add_servers(Added, State) ->
    lists:foldl(
        fun(Conf = #{name := Name}, {ResAcc, StateAcc}) ->
            case do_load_server(opts_to_state(Conf)) of
                {ok, Server} ->
                    #{servers := Servers} = StateAcc,
                    Servers2 = Servers#{Name => Server},
                    {ResAcc, update_servers(Servers2, StateAcc)};
                {Err, StateAcc1} ->
                    {[Err | ResAcc], StateAcc1}
            end
        end,
        {[], State},
        Added
    ).

-spec do_load_server(server()) -> {ok, server()} | {error, term()}.
do_load_server(#{name := Name} = Server) ->
    case emqx_exhook_server:load(Name, Server) of
        {ok, ServiceState} ->
            save(Name, ServiceState),
            {ok, Server#{status => connected}};
        disable ->
            {ok, set_disable(Server)};
        {ErrorType, Reason} ->
            ?SLOG(
                error,
                #{
                    msg => "failed_to_load_exhook_callback_server",
                    reason => Reason,
                    name => Name
                }
            ),
            case ErrorType of
                load_error ->
                    {ok, ensure_reload_timer(Server)};
                _ ->
                    {ErrorType, Server#{status => disconnected}}
            end
    end.

do_load_server(#{name := Name} = Server, #{servers := Servers} = State) ->
    {Result, Server2} = do_load_server(Server),
    {Result, update_servers(Servers#{Name => Server2}, State)}.

-spec do_reload_server(server_name(), state()) ->
    {{error, term()}, state()}
    | {ok, state()}.
do_reload_server(Name, State) ->
    case where_is_server(Name, State) of
        not_found ->
            {{error, not_found}, State};
        #{timer := undefined} ->
            {ok, State};
        Server ->
            clean_reload_timer(Server),
            do_load_server(Server, State)
    end.

-spec do_unload_server(server_name(), state()) -> state().
do_unload_server(Name, #{servers := Servers} = State) ->
    case where_is_server(Name, State) of
        not_found ->
            State;
        #{status := disabled} ->
            State;
        Server ->
            clean_reload_timer(Server),
            case service(Name) of
                undefined ->
                    State;
                Service ->
                    ok = unsave(Name),
                    ok = emqx_exhook_server:unload(Service),
                    Servers2 = Servers#{Name := set_disable(Server)},
                    State#{servers := Servers2}
            end
    end.

-spec ensure_reload_timer(server()) -> server().
ensure_reload_timer(#{name := Name, auto_reconnect := Intv} = Server) when is_integer(Intv) ->
    maybe
        true ?= expired_timer(Server),
        %% otherwise, respect the running timer
        %% NOTE: parallel health check and reload timer
        %% should send te the current gen_server
        Ref = erlang:start_timer(Intv, erlang:whereis(?MODULE), {reload, Name}),
        %% mark status as connecting, the refresh_tick will check real conn states
        Server#{status => connecting, timer => Ref}
    else
        false -> Server
    end;
ensure_reload_timer(Server) ->
    Server#{status => disconnected}.

expired_timer(#{timer := undefined}) ->
    true;
expired_timer(#{timer := Timer}) ->
    case erlang:read_timer(Timer) of
        false -> true;
        _RemainingTime -> false
    end.

-spec clean_reload_timer(server()) -> ok.
clean_reload_timer(#{timer := undefined}) ->
    ok;
clean_reload_timer(#{timer := Timer}) ->
    _ = erlang:cancel_timer(Timer),
    ok.

-spec cancel_reload_timer(server()) -> server().
cancel_reload_timer(#{timer := undefined} = Server) ->
    Server;
cancel_reload_timer(#{timer := Timer} = Server) ->
    _ = erlang:cancel_timer(Timer),
    Server#{timer => undefined}.

-spec do_move(binary(), position(), list(server_options())) -> list(server_options()).
do_move(Name, Position, ConfL) ->
    move(ConfL, Name, Position, []).

move([#{<<"name">> := Name} = Server | T], Name, Position, HeadL) ->
    move_to(Position, Server, lists:reverse(HeadL) ++ T);
move([Server | T], Name, Position, HeadL) ->
    move(T, Name, Position, [Server | HeadL]);
move([], _Name, _Position, _HeadL) ->
    throw(not_found).

move_to(?CMD_MOVE_FRONT, Server, ServerL) ->
    [Server | ServerL];
move_to(?CMD_MOVE_REAR, Server, ServerL) ->
    ServerL ++ [Server];
move_to(Position, Server, ServerL) ->
    move_to(ServerL, Position, Server, []).

move_to([#{<<"name">> := Name} | _] = T, ?CMD_MOVE_BEFORE(Name), Server, HeadL) ->
    lists:reverse(HeadL) ++ [Server | T];
move_to([#{<<"name">> := Name} = H | T], ?CMD_MOVE_AFTER(Name), Server, HeadL) ->
    lists:reverse(HeadL) ++ [H, Server | T];
move_to([H | T], Position, Server, HeadL) ->
    move_to(T, Position, Server, [H | HeadL]);
move_to([], _Position, _Server, _HeadL) ->
    not_found.

-spec do_delete(binary(), list(server_options())) -> list(server_options()).
do_delete(ToDelete, OldConf) ->
    case lists:any(fun(#{<<"name">> := ExistedName}) -> ExistedName =:= ToDelete end, OldConf) of
        true ->
            lists:filter(
                fun(#{<<"name">> := Name}) -> Name =/= ToDelete end,
                OldConf
            );
        false ->
            throw(not_found)
    end.

-spec reorder(list(server_options()), servers()) -> servers().
reorder(ServerL, Servers) ->
    Orders = reorder(ServerL, 1, Servers),
    update_order(Orders),
    Orders.

reorder([#{name := Name} | T], Order, Servers) ->
    reorder(T, Order + 1, update_order(Name, Servers, Order));
reorder([], _Order, Servers) ->
    Servers.

update_order(Name, Servers, Order) ->
    Server = maps:get(Name, Servers),
    Servers#{Name := Server#{order := Order}}.

get_servers_info(Svrs) ->
    Fold = fun(Name, Conf, Acc) ->
        [
            maps:merge(Conf, #{hooks => hooks(Name)})
            | Acc
        ]
    end,
    maps:fold(Fold, [], Svrs).

where_is_server(Name, #{servers := Servers}) ->
    maps:get(Name, Servers, not_found).

-type replace_fun() :: fun((server_options()) -> server_options()).

-spec replace_conf(binary(), replace_fun(), list(server_options())) -> list(server_options()).
replace_conf(Name, ReplaceFun, ConfL) ->
    replace_conf(ConfL, Name, ReplaceFun, []).

replace_conf([#{<<"name">> := Name} = H | T], Name, ReplaceFun, HeadL) ->
    New = ReplaceFun(H),
    lists:reverse(HeadL) ++ [New | T];
replace_conf([H | T], Name, ReplaceFun, HeadL) ->
    replace_conf(T, Name, ReplaceFun, [H | HeadL]);
replace_conf([], _, _, _) ->
    throw(not_found).

restart_servers(Updated, NewConfL, State) ->
    lists:foldl(
        fun({_Old, Conf}, {ResAcc, StateAcc}) ->
            Name = maps:get(name, Conf),
            case restart_server(Name, NewConfL, StateAcc) of
                {ok, StateAcc1} -> {ResAcc, StateAcc1};
                {Err, StateAcc1} -> {[Err | ResAcc], StateAcc1}
            end
        end,
        {[], State},
        Updated
    ).

-spec restart_server(binary(), list(server_options()), state()) ->
    {ok, state()}
    | {{error, term()}, state()}.
restart_server(Name, ConfL, State) ->
    case lists:search(fun(#{name := CName}) -> CName =:= Name end, ConfL) of
        false ->
            {{error, not_found}, State};
        {value, Conf} ->
            case where_is_server(Name, State) of
                not_found ->
                    {{error, not_found}, State};
                Server ->
                    Server2 = maps:merge(Server, Conf),
                    State2 = do_unload_server(Name, State),
                    do_load_server(Server2, State2)
            end
    end.

sort_name_by_order(Names, Orders) ->
    lists:sort(
        fun
            (A, B) when is_binary(A) ->
                emqx_utils_maps:deep_get([A, order], Orders) <
                    emqx_utils_maps:deep_get([B, order], Orders);
            (#{name := A}, #{name := B}) ->
                emqx_utils_maps:deep_get([A, order], Orders) <
                    emqx_utils_maps:deep_get([B, order], Orders)
        end,
        Names
    ).

refresh_tick() ->
    erlang:send_after(?REFRESH_INTERVAL, erlang:whereis(?MODULE), ?FUNCTION_NAME).

-spec opts_to_state(server_options()) -> server().
opts_to_state(Options) ->
    maps:merge(Options, #{status => disconnected, timer => undefined, order => 0}).

update_servers(Servers, State) ->
    update_order(Servers),
    State#{servers := Servers}.

set_disable(Server) ->
    Server#{status := disabled, timer := undefined}.

do_health_check(Server) ->
    handle_health_check_res(
        Server,
        emqx_exhook_server:health_check(Server)
    ).

handle_health_check_res(Server, disable) ->
    Server#{status => disabled};
handle_health_check_res(Server, true) ->
    (cancel_reload_timer(Server))#{status := connected};
handle_health_check_res(#{status := connecting} = Server, false) ->
    %% reload timer mark status to `connecting` but health check still failed
    %% make sure reload timer is working and the mark status is `disconnected`
    (ensure_reload_timer(Server))#{status => disconnected};
handle_health_check_res(Server, false) ->
    ensure_reload_timer(Server);
handle_health_check_res(Server, skip) ->
    %% skip the health check due to unsaved/reconnecting service
    ensure_reload_timer(Server).

%%----------------------------------------------------------------------------------------
%% Server state persistent
-spec save(server_name(), emqx_exhook_server:service()) -> ok.
save(Name, ServerState) ->
    Saved = persistent_term:get(?APP, []),
    persistent_term:put(?APP, lists:reverse([Name | Saved])),
    persistent_term:put({?APP, Name}, ServerState).

unsave(Name) ->
    case persistent_term:get(?APP, []) of
        [] ->
            ok;
        Saved ->
            case lists:member(Name, Saved) of
                false ->
                    ok;
                true ->
                    persistent_term:put(?APP, lists:delete(Name, Saved))
            end
    end,
    persistent_term:erase({?APP, Name}),
    ok.

running() ->
    persistent_term:get(?APP, []).

-spec service(server_name()) -> emqx_exhook_server:service() | undefined.
service(Name) ->
    case persistent_term:get({?APP, Name}, undefined) of
        undefined -> undefined;
        Service -> Service
    end.

update_order(Servers) ->
    Running = running(),
    Orders = maps:filter(
        fun
            (Name, #{status := connected}) ->
                lists:member(Name, Running);
            (_, _) ->
                false
        end,
        Servers
    ),
    Running2 = sort_name_by_order(Running, Orders),
    persistent_term:put(?APP, Running2).

hooks(Name) ->
    case service(Name) of
        undefined ->
            [];
        Service ->
            emqx_exhook_server:hooks(Service)
    end.

maybe_write_certs(#{<<"name">> := Name} = Conf) ->
    case
        emqx_tls_lib:ensure_ssl_files_in_mutable_certs_dir(
            ssl_file_path(Name), maps:get(<<"ssl">>, Conf, undefined)
        )
    of
        {ok, SSL} ->
            new_ssl_source(Conf, SSL);
        {error, Reason} ->
            ?SLOG(error, Reason#{msg => "bad_ssl_config"}),
            throw({bad_ssl_config, Reason})
    end.

ssl_file_path(Name) ->
    filename:join(["exhook", Name]).

new_ssl_source(Source, undefined) ->
    Source;
new_ssl_source(Source, SSL) ->
    Source#{<<"ssl">> => SSL}.

map_each_server(Fun, Servers) ->
    maps:from_list(emqx_utils:pmap(Fun, maps:to_list(Servers))).
