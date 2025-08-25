%%--------------------------------------------------------------------
%% Copyright (c) 2017-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_sup).

-behaviour(supervisor).

-include("types.hrl").

-export([
    start_link/0,
    start_child/1,
    start_child/2,
    stop_child/1
]).

-export([init/1]).

-type startchild_ret() ::
    {ok, pid()}
    | {ok, pid(), term()}
    | {error, term()}.

-define(SUP, ?MODULE).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-spec start_link() -> startlink_ret().
start_link() ->
    supervisor:start_link({local, ?SUP}, ?MODULE, []).

-spec start_child(supervisor:child_spec()) -> startchild_ret().
start_child(ChildSpec) when is_map(ChildSpec) ->
    supervisor:start_child(?SUP, ChildSpec).

-spec start_child(module(), worker | supervisor) -> startchild_ret().
start_child(Mod, Type) ->
    start_child(child_spec(Mod, Type)).

-spec stop_child(atom()) -> ok | {error, term()}.
stop_child(ChildId) ->
    case supervisor:terminate_child(?SUP, ChildId) of
        ok -> supervisor:delete_child(?SUP, ChildId);
        Error -> Error
    end.

%%--------------------------------------------------------------------
%% Supervisor callbacks
%%--------------------------------------------------------------------

init([]) ->
    KernelSup = child_spec(emqx_kernel_sup, supervisor),
    RouterSup = child_spec(emqx_router_sup, supervisor),
    BrokerSup = child_spec(emqx_broker_sup, supervisor),
    CMSup = child_spec(emqx_cm_sup, supervisor),
    SysSup = child_spec(emqx_sys_sup, supervisor),
    Limiter = child_spec(emqx_limiter_sup, supervisor),
    AccessControlMetricsSup = child_spec(emqx_access_control_metrics_sup, supervisor),
    Children =
        [KernelSup] ++
            [RouterSup || emqx_boot:is_enabled(broker)] ++
            [BrokerSup || emqx_boot:is_enabled(broker)] ++
            [CMSup || emqx_boot:is_enabled(broker)] ++
            [SysSup, Limiter, AccessControlMetricsSup],
    SupFlags = #{
        strategy => one_for_all,
        intensity => 0,
        period => 1
    },
    {ok, {SupFlags, Children}}.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

child_spec(Mod, supervisor) ->
    #{
        id => Mod,
        start => {Mod, start_link, []},
        restart => permanent,
        shutdown => infinity,
        type => supervisor,
        modules => [Mod]
    };
child_spec(Mod, worker) ->
    #{
        id => Mod,
        start => {Mod, start_link, []},
        restart => permanent,
        shutdown => 15000,
        type => worker,
        modules => [Mod]
    }.
