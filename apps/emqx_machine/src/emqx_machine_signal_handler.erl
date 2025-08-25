%%--------------------------------------------------------------------
%% Copyright (c) 2021-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

%% This module implements a gen_event handler which
%% swap-in replaces the default one from OTP.
%% The kill signal (sigterm) is captured so we can
%% perform graceful shutdown.
-module(emqx_machine_signal_handler).

-export([
    start/0,
    init/1,
    handle_event/2,
    handle_call/2,
    handle_info/2,
    terminate/2
]).

-include_lib("emqx/include/logger.hrl").

start() ->
    ok = gen_event:swap_sup_handler(
        erl_signal_server,
        {erl_signal_handler, []},
        {?MODULE, []}
    ).

init({[], _}) -> {ok, #{}}.

handle_event(sigterm, State) ->
    Msg = "received_terminate_signal",
    ?SLOG(critical, #{msg => Msg}),
    ?ULOG("~ts ~ts, shutting down now.~n", [emqx_utils_calendar:now_to_rfc3339(), Msg]),
    emqx_machine_terminator:graceful(),
    {ok, State};
handle_event(Event, State) ->
    %% delegate other events back to erl_signal_handler
    %% erl_signal_handler does not make use of the State
    %% so we can pass whatever from here
    _ = erl_signal_handler:handle_event(Event, State),
    {ok, State}.

handle_info(stop, State) ->
    {ok, State};
handle_info(_Other, State) ->
    {ok, State}.

handle_call(_Request, State) ->
    {ok, ok, State}.

terminate(_Args, _State) ->
    ok.
