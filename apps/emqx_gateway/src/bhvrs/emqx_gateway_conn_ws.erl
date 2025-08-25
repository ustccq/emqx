%%--------------------------------------------------------------------
%% Copyright (c) 2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

%% WS/WSS Connection
-module(emqx_gateway_conn_ws).

-include_lib("emqx/include/logger.hrl").
-include_lib("emqx/include/types.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").

-ifdef(TEST).
-compile(export_all).
-compile(nowarn_export_all).
-endif.

%% API
-export([
    info/1,
    stats/1
]).

-export([
    call/2,
    call/3
]).

%% WebSocket callbacks
-export([
    init/2,
    websocket_init/1,
    websocket_handle/2,
    websocket_info/2,
    websocket_close/2,
    terminate/3
]).

%% Export for CT
-export([set_field/3]).

-import(
    emqx_utils,
    [
        maybe_apply/2,
        start_timer/2
    ]
).

-record(state, {
    %% Peername of the ws connection
    peername :: emqx_types:peername(),
    %% Sockname of the ws connection
    sockname :: emqx_types:peername(),
    %% Sock state
    sockstate :: emqx_types:sockstate(),
    %% Simulate the active_n opt
    active_n :: pos_integer(),
    %% Piggyback
    piggyback :: single | multiple,
    %% Limiter
    limiter :: option(emqx_limiter_client_container:t()),
    %% Limit Timer
    limit_timer :: option(reference()),
    %% Parse State
    parse_state :: emqx_gateway_frame:parse_state(),
    %% Serialize options
    serialize :: emqx_gateway_frame:serialize_options(),
    %% Channel
    channel :: emqx_gateway_channel:channel(),
    %% GC State
    gc_state :: option(emqx_gc:gc_state()),
    %% Postponed Packets|Cmds|Events
    postponed :: list(emqx_types:packet() | ws_cmd() | tuple()),
    %% Stats Timer
    stats_timer :: disabled | option(reference()),
    %% Idle Timeout
    idle_timeout :: timeout(),
    %%% Idle Timer
    idle_timer :: option(reference()),
    %% OOM Policy
    oom_policy :: option(emqx_types:oom_policy()),
    %% Frame Module
    frame_mod :: atom(),
    %% Channel Module
    chann_mod :: atom(),
    %% Listener Tag
    listener :: listener() | undefined
}).

-type listener() :: {GwName :: atom(), LisType :: atom(), LisName :: atom()}.

-type state() :: #state{}.

-type ws_cmd() :: {active, boolean()} | close.

-define(INFO_KEYS, [
    socktype,
    peername,
    sockname,
    sockstate,
    active_n
]).

-define(SOCK_STATS, [
    recv_oct,
    recv_cnt,
    send_oct,
    send_cnt
]).

-define(ENABLED(X), (X =/= undefined)).

-dialyzer({no_match, [info/2]}).
-dialyzer({nowarn_function, [websocket_init/1, postpone/2, classify/4]}).

-elvis([
    {elvis_style, invalid_dynamic_call, #{ignore => [emqx_gateway_conn_ws]}}
]).

-define(TAG, "GW-WSCONN").

%%--------------------------------------------------------------------
%% Info, Stats
%%--------------------------------------------------------------------

-spec info(pid() | state()) -> emqx_types:infos().
info(WsPid) when is_pid(WsPid) ->
    call(WsPid, info);
info(State = #state{chann_mod = ChannMod, channel = Channel}) ->
    ChanInfo = ChannMod:info(Channel),
    SockInfo = maps:from_list(
        info(?INFO_KEYS, State)
    ),
    ChanInfo#{sockinfo => SockInfo}.

info(Keys, State) when is_list(Keys) ->
    [{Key, info(Key, State)} || Key <- Keys];
info(socktype, _State) ->
    ws;
info(peername, #state{peername = Peername}) ->
    Peername;
info(sockname, #state{sockname = Sockname}) ->
    Sockname;
info(sockstate, #state{sockstate = SockSt}) ->
    SockSt;
info(active_n, #state{active_n = ActiveN}) ->
    ActiveN;
info(channel, #state{chann_mod = ChannMod, channel = Channel}) ->
    ChannMod:info(Channel);
info(gc_state, #state{gc_state = GcSt}) ->
    maybe_apply(fun emqx_gc:info/1, GcSt);
info(postponed, #state{postponed = Postponed}) ->
    Postponed;
info(stats_timer, #state{stats_timer = TRef}) ->
    TRef;
info(idle_timeout, #state{idle_timeout = Timeout}) ->
    Timeout.

-spec stats(pid() | state()) -> emqx_types:stats().
stats(WsPid) when is_pid(WsPid) ->
    call(WsPid, stats);
stats(#state{chann_mod = ChannMod, channel = Channel}) ->
    SockStats = emqx_pd:get_counters(?SOCK_STATS),
    ChanStats = ChannMod:stats(Channel),
    ProcStats = emqx_utils:proc_stats(),
    lists:append([SockStats, ChanStats, ProcStats]).

%% kick|discard|takeover
-spec call(pid(), Req :: term()) -> Reply :: term().
call(WsPid, Req) ->
    call(WsPid, Req, 5000).

call(WsPid, Req, Timeout) when is_pid(WsPid) ->
    Mref = erlang:monitor(process, WsPid),
    WsPid ! {call, {self(), Mref}, Req},
    receive
        {Mref, Reply} ->
            erlang:demonitor(Mref, [flush]),
            Reply;
        {'DOWN', Mref, _, _, Reason} ->
            exit(Reason)
    after Timeout ->
        erlang:demonitor(Mref, [flush]),
        exit(timeout)
    end.

%%--------------------------------------------------------------------
%% WebSocket callbacks
%%--------------------------------------------------------------------

init(Req, Opts) ->
    %% WS Transport Idle Timeout
    IdleTimeout = maps:get(idle_timeout, Opts, 7200000),
    MaxFrameSize =
        case maps:get(max_frame_size, Opts, 0) of
            0 -> infinity;
            I -> I
        end,
    Compress = emqx_utils_maps:deep_get([websocket, compress], Opts),
    WsOpts = #{
        compress => Compress,
        max_frame_size => MaxFrameSize,
        idle_timeout => IdleTimeout
    },
    case check_origin_header(Req, Opts) of
        {error, Message} ->
            ?SLOG(error, #{tag => ?TAG, msg => "invaild_origin_header", reason => Message}),
            {ok, cowboy_req:reply(403, Req), WsOpts};
        ok ->
            do_init(Req, Opts, WsOpts)
    end.

do_init(Req, Opts, WsOpts) ->
    case
        emqx_utils:pipeline(
            [
                fun init_state_and_channel/2,
                fun parse_sec_websocket_protocol/2
            ],
            [Req, Opts, WsOpts],
            undefined
        )
    of
        {error, Reason, _State} ->
            {ok, cowboy_req:reply(400, #{}, to_bin(Reason), Req), WsOpts};
        {ok, [Resp, Opts, WsOpts], NState} ->
            {cowboy_websocket_linger, Resp, [Req, Opts, NState], WsOpts}
    end.

init_state_and_channel([Req, Opts, _WsOpts], _State = undefined) ->
    {Peername, Peercert} = peername_and_cert(Req, Opts),
    Sockname = cowboy_req:sock(Req),
    WsCookie =
        try
            cowboy_req:parse_cookies(Req)
        catch
            error:badarg ->
                ?SLOG(error, #{tag => ?TAG, msg => "bad_cookie"}),
                undefined;
            Error:Reason ->
                ?SLOG(error, #{
                    tag => ?TAG,
                    msg => "failed_to_parse_cookie",
                    error => Error,
                    reason => Reason
                }),
                undefined
        end,
    ConnInfo = #{
        socktype => ws,
        peername => Peername,
        sockname => Sockname,
        peercert => Peercert,
        ws_cookie => WsCookie,
        conn_mod => ?MODULE
    },
    Limiter = undefined,
    FrameMod = maps:get(frame_mod, Opts),
    ChannMod = maps:get(chann_mod, Opts),
    ActiveN = emqx_gateway_utils:active_n(Opts),
    Piggyback = emqx_utils_maps:deep_get([websocket, piggyback], Opts, multiple),
    ParseState = FrameMod:initial_parse_state(#{}),
    Serialize = FrameMod:serialize_opts(),
    Channel = ChannMod:init(ConnInfo, Opts),
    GcState = emqx_gateway_utils:init_gc_state(Opts),
    StatsTimer = emqx_gateway_utils:stats_timer(Opts),
    IdleTimeout = emqx_gateway_utils:idle_timeout(Opts),
    OomPolicy = emqx_gateway_utils:oom_policy(Opts),
    IdleTimer = emqx_utils:start_timer(IdleTimeout, idle_timeout),
    emqx_logger:set_metadata_peername(esockd:format(Peername)),
    {ok, #state{
        peername = Peername,
        sockname = Sockname,
        sockstate = running,
        active_n = ActiveN,
        piggyback = Piggyback,
        limiter = Limiter,
        parse_state = ParseState,
        serialize = Serialize,
        channel = Channel,
        gc_state = GcState,
        postponed = [],
        stats_timer = StatsTimer,
        idle_timeout = IdleTimeout,
        idle_timer = IdleTimer,
        oom_policy = OomPolicy,
        frame_mod = FrameMod,
        chann_mod = ChannMod,
        listener = maps:get(listener, Opts, undeined)
    }}.

peername_and_cert(Req, Opts) ->
    case
        maps:get(proxy_protocol, Opts, false) andalso
            maps:get(proxy_header, Req)
    of
        #{src_address := SrcAddr, src_port := SrcPort, ssl := SSL} ->
            SourceName = {SrcAddr, SrcPort},
            %% Notice: Only CN is available in Proxy Protocol V2 additional info
            SourceSSL =
                case maps:get(cn, SSL, undefined) of
                    undeined -> nossl;
                    CN -> [{pp2_ssl_cn, CN}]
                end,
            {SourceName, SourceSSL};
        #{src_address := SrcAddr, src_port := SrcPort} ->
            SourceName = {SrcAddr, SrcPort},
            {SourceName, nossl};
        _ ->
            {get_peer(Req, Opts), cowboy_req:cert(Req)}
    end.

parse_sec_websocket_protocol([Req, Opts, WsOpts], State) ->
    SupportedSubprotocols = emqx_utils_maps:deep_get([websocket, supported_subprotocols], Opts),
    FailIfNoSubprotocol = emqx_utils_maps:deep_get([websocket, fail_if_no_subprotocol], Opts),
    case cowboy_req:parse_header(<<"sec-websocket-protocol">>, Req) of
        undefined ->
            case FailIfNoSubprotocol of
                true ->
                    {error, no_subprotocol};
                false ->
                    Picked = list_to_binary(lists:nth(1, SupportedSubprotocols)),
                    Resp = cowboy_req:set_resp_header(
                        <<"sec-websocket-protocol">>,
                        Picked,
                        Req
                    ),
                    {ok, [Resp, Opts, WsOpts], State}
            end;
        Subprotocols ->
            NSupportedSubprotocols = [
                list_to_binary(Subprotocol)
             || Subprotocol <- SupportedSubprotocols
            ],
            case pick_subprotocol(Subprotocols, NSupportedSubprotocols) of
                {ok, Subprotocol} ->
                    Resp = cowboy_req:set_resp_header(
                        <<"sec-websocket-protocol">>,
                        Subprotocol,
                        Req
                    ),
                    {ok, [Resp, Opts, WsOpts], State};
                {error, no_supported_subprotocol} ->
                    {error, no_supported_subprotocol}
            end
    end.

pick_subprotocol([], _SupportedSubprotocols) ->
    {error, no_supported_subprotocol};
pick_subprotocol([Subprotocol | Rest], SupportedSubprotocols) ->
    case lists:member(Subprotocol, SupportedSubprotocols) of
        true ->
            {ok, Subprotocol};
        false ->
            pick_subprotocol(Rest, SupportedSubprotocols)
    end.

parse_header_fun_origin(Req, Opts) ->
    case cowboy_req:header(<<"origin">>, Req) of
        undefined ->
            case emqx_utils_maps:deep_get([websocket, allow_origin_absence], Opts) of
                true -> ok;
                false -> {error, origin_header_cannot_be_absent}
            end;
        Value ->
            Origins = emqx_utils_maps:deep_get([websocket, check_origins], Opts, []),
            case lists:member(Value, Origins) of
                true -> ok;
                false -> {error, {origin_not_allowed, Value}}
            end
    end.

check_origin_header(Req, Opts) ->
    case emqx_utils_maps:deep_get([websocket, check_origin_enable], Opts) of
        true -> parse_header_fun_origin(Req, Opts);
        false -> ok
    end.

websocket_init([_Req, _Opts, State]) ->
    return(State#state{postponed = [after_init]}).

websocket_handle({binary, Data}, State) when is_list(Data) ->
    websocket_handle({text, iolist_to_binary(Data)}, State);
websocket_handle({binary, Data}, State) when is_binary(Data) ->
    websocket_handle({text, Data}, State);
websocket_handle({text, Data}, State) when is_list(Data) ->
    websocket_handle({text, iolist_to_binary(Data)}, State);
websocket_handle({text, Data}, State) ->
    ?SLOG(debug, #{tag => ?TAG, msg => "raw_bin_received", bin => Data}),
    ok = inc_recv_stats(1, iolist_size(Data)),
    NState = ensure_stats_timer(State),
    return(parse_incoming(Data, NState));
%% Pings should be replied with pongs, cowboy does it automatically
%% Pongs can be safely ignored. Clause here simply prevents crash.
websocket_handle(Frame, State) when Frame =:= ping; Frame =:= pong ->
    return(State);
websocket_handle({Frame, _}, State) when Frame =:= ping; Frame =:= pong ->
    return(State);
websocket_handle({Frame, _}, State) ->
    %% TODO: should not close the ws connection
    ?SLOG(error, #{tag => ?TAG, msg => "unexpected_frame", frame => Frame}),
    shutdown(unexpected_ws_frame, State).

websocket_info({call, From, Req}, State) ->
    handle_call(From, Req, State);
websocket_info({cast, rate_limit}, State) ->
    Cnt = emqx_pd:reset_counter(incoming_pubs),
    Oct = emqx_pd:reset_counter(incoming_bytes),
    NState = postpone({check_gc, Cnt, Oct}, State),
    return(ensure_rate_limit(NState));
websocket_info({cast, Msg}, State) ->
    handle_info(Msg, State);
websocket_info({incoming, Packet}, State) ->
    handle_incoming(Packet, State);
websocket_info({outgoing, Packets}, State) ->
    return(enqueue(Packets, State));
websocket_info({check_gc, Cnt, Oct}, State) ->
    return(check_oom(run_gc(Cnt, Oct, State)));
websocket_info(
    Deliver = {deliver, _Topic, _Msg},
    State = #state{active_n = ActiveN}
) ->
    Delivers = [Deliver | emqx_utils:drain_deliver(ActiveN)],
    with_channel(handle_deliver, [Delivers], State);
websocket_info(
    {timeout, TRef, limit_timeout},
    State = #state{limit_timer = TRef}
) ->
    NState = State#state{
        sockstate = running,
        limit_timer = undefined
    },
    return(enqueue({active, true}, NState));
websocket_info({timeout, TRef, Msg}, State) when is_reference(TRef) ->
    handle_timeout(TRef, Msg, State);
websocket_info({shutdown, Reason}, State) ->
    shutdown(Reason, State);
websocket_info({stop, Reason}, State) ->
    shutdown(Reason, State);
websocket_info(Info, State) ->
    handle_info(Info, State).

websocket_close({_, ReasonCode, _Payload}, State) when is_integer(ReasonCode) ->
    websocket_close(ReasonCode, State);
websocket_close(Reason, State) ->
    ?SLOG(debug, #{tag => ?TAG, msg => "websocket_closed", reason => Reason}),
    handle_info({sock_closed, Reason}, State).

terminate(Reason, _Req, #state{chann_mod = ChannMod, channel = Channel}) ->
    ClientId = ChannMod:info(clientid, Channel),
    ?tp(debug, conn_process_terminated, #{reason => Reason, clientid => ClientId}),
    ChannMod:terminate(Reason, Channel);
terminate(_Reason, _Req, _UnExpectedState) ->
    ok.

%%--------------------------------------------------------------------
%% Handle call
%%--------------------------------------------------------------------

handle_call(From, info, State) ->
    gen_server:reply(From, info(State)),
    return(State);
handle_call(From, stats, State) ->
    gen_server:reply(From, stats(State)),
    return(State);
handle_call(From, Req, State = #state{chann_mod = ChannMod, channel = Channel}) ->
    case ChannMod:handle_call(Req, From, Channel) of
        {reply, Reply, NChannel} ->
            gen_server:reply(From, Reply),
            return(State#state{channel = NChannel});
        {shutdown, Reason, Reply, NChannel} ->
            gen_server:reply(From, Reply),
            shutdown(Reason, State#state{channel = NChannel});
        {shutdown, Reason, Reply, Packet, NChannel} ->
            gen_server:reply(From, Reply),
            NState = postpone({outgoing, Packet}, State#state{channel = NChannel}),
            shutdown(Reason, NState)
    end.

%%--------------------------------------------------------------------
%% Handle Info
%%--------------------------------------------------------------------

handle_info({connack, ConnAck}, State) ->
    return(enqueue(ConnAck, State));
handle_info({close, Reason}, State) ->
    ?SLOG(debug, #{tag => ?TAG, msg => "force_to_close_socket", reason => Reason}),
    return(enqueue({close, Reason}, State));
handle_info({event, connected}, State = #state{chann_mod = ChannMod, channel = Channel}) ->
    Ctx = ChannMod:info(ctx, Channel),
    ClientId = ChannMod:info(clientid, Channel),
    emqx_gateway_ctx:insert_channel_info(
        Ctx,
        ClientId,
        info(State),
        stats(State)
    ),
    return(State);
handle_info({event, disconnected}, State = #state{chann_mod = ChannMod, channel = Channel}) ->
    Ctx = ChannMod:info(ctx, Channel),
    ClientId = ChannMod:info(clientid, Channel),
    emqx_gateway_ctx:set_chan_info(Ctx, ClientId, info(State)),
    emqx_gateway_ctx:connection_closed(Ctx, ClientId),
    return(State);
handle_info({event, _Other}, State = #state{chann_mod = ChannMod, channel = Channel}) ->
    Ctx = ChannMod:info(ctx, Channel),
    ClientId = ChannMod:info(clientid, Channel),
    emqx_gateway_ctx:set_chan_info(Ctx, ClientId, info(State)),
    emqx_gateway_ctx:set_chan_stats(Ctx, ClientId, stats(State)),
    return(State);
handle_info(Info, State) ->
    with_channel(handle_info, [Info], State).

%%--------------------------------------------------------------------
%% Handle timeout
%%--------------------------------------------------------------------

handle_timeout(TRef, Keepalive, State) when
    Keepalive =:= keepalive;
    Keepalive =:= keepalive_send
->
    StatVal =
        case Keepalive of
            keepalive -> emqx_pd:get_counter(recv_oct);
            keepalive_send -> emqx_pd:get_counter(send_oct)
        end,
    handle_timeout(TRef, {Keepalive, StatVal}, State);
handle_timeout(
    TRef,
    emit_stats,
    State = #state{
        chann_mod = ChannMod,
        channel = Channel,
        stats_timer = TRef
    }
) ->
    Ctx = ChannMod:info(ctx, Channel),
    ClientId = ChannMod:info(clientid, Channel),
    emqx_gateway_ctx:set_chan_stats(Ctx, ClientId, stats(State)),
    return(State#state{stats_timer = undefined});
handle_timeout(TRef, TMsg, State) ->
    with_channel(handle_timeout, [TRef, TMsg], State).

%%--------------------------------------------------------------------
%% Ensure rate limit
%%--------------------------------------------------------------------

ensure_rate_limit(State) ->
    State.

%%--------------------------------------------------------------------
%% Run GC, Check OOM
%%--------------------------------------------------------------------

run_gc(Cnt, Oct, State = #state{gc_state = GcSt}) ->
    case ?ENABLED(GcSt) andalso emqx_gc:run(Cnt, Oct, GcSt) of
        false -> State;
        {_IsGC, GcSt1} -> State#state{gc_state = GcSt1}
    end.

check_oom(State = #state{oom_policy = OomPolicy}) ->
    case ?ENABLED(OomPolicy) andalso emqx_utils:check_oom(OomPolicy) of
        Shutdown = {shutdown, _Reason} ->
            postpone(Shutdown, State);
        _Other ->
            ok
    end,
    State.

%%--------------------------------------------------------------------
%% Parse incoming data
%%--------------------------------------------------------------------

parse_incoming(<<>>, State) ->
    State;
parse_incoming(Data, State = #state{frame_mod = FrameMod, parse_state = ParseState}) ->
    try FrameMod:parse(Data, ParseState) of
        {ok, Packet, Rest, NParseState} ->
            NState = State#state{parse_state = NParseState},
            parse_incoming(Rest, postpone({incoming, Packet}, NState))
    catch
        error:Reason:Stk ->
            ?SLOG(
                error,
                #{
                    tag => ?TAG,
                    msg => "parse_failed",
                    data => Data,
                    reason => Reason,
                    stacktrace => Stk
                }
            ),
            FrameError = {frame_error, Reason},
            postpone({incoming, FrameError}, State)
    end.

%%--------------------------------------------------------------------
%% Handle incoming packet
%%--------------------------------------------------------------------

handle_incoming({frame_error, Reason}, State) ->
    with_channel(handle_frame_error, [Reason], State);
handle_incoming(
    Packet,
    State = #state{
        active_n = ActiveN, frame_mod = FrameMod, chann_mod = ChannMod, channel = Channel
    }
) ->
    Ctx = ChannMod:info(ctx, Channel),
    ok = inc_incoming_stats(Ctx, FrameMod, Packet),
    NState =
        case emqx_pd:get_counter(incoming_pubs) > ActiveN of
            true -> postpone({cast, rate_limit}, State);
            false -> State
        end,
    with_channel(handle_in, [Packet], NState);
handle_incoming(FrameError, State) ->
    with_channel(handle_in, [FrameError], State).

%%--------------------------------------------------------------------
%% With Channel
%%--------------------------------------------------------------------

with_channel(Fun, Args, State = #state{chann_mod = ChannMod, channel = Channel}) ->
    case erlang:apply(ChannMod, Fun, Args ++ [Channel]) of
        ok ->
            return(State);
        {ok, NChannel} ->
            return(State#state{channel = NChannel});
        {ok, Replies, NChannel} ->
            return(postpone(Replies, State#state{channel = NChannel}));
        {shutdown, Reason, NChannel} ->
            shutdown(Reason, State#state{channel = NChannel});
        {shutdown, Reason, Packet, NChannel} ->
            NState = State#state{channel = NChannel},
            shutdown(Reason, postpone(Packet, NState))
    end.

%%--------------------------------------------------------------------
%% Handle outgoing packets
%%--------------------------------------------------------------------

handle_outgoing(Packets, State = #state{active_n = ActiveN, piggyback = Piggyback}) ->
    IoData = lists:map(serialize_and_inc_stats_fun(State), Packets),
    Oct = iolist_size(IoData),
    ok = inc_sent_stats(length(Packets), Oct),
    NState =
        case emqx_pd:get_counter(outgoing_pubs) > ActiveN of
            true ->
                Cnt = emqx_pd:reset_counter(outgoing_pubs),
                Oct = emqx_pd:reset_counter(outgoing_bytes),
                postpone({check_gc, Cnt, Oct}, State);
            false ->
                State
        end,
    {
        case Piggyback of
            single -> [{binary, IoData}];
            multiple -> lists:map(fun(Bin) -> {binary, Bin} end, IoData)
        end,
        ensure_stats_timer(NState)
    }.

serialize_and_inc_stats_fun(#state{
    frame_mod = FrameMod, serialize = Serialize, chann_mod = ChannMod, channel = Channel
}) ->
    Ctx = ChannMod:info(ctx, Channel),
    fun(Packet) ->
        case FrameMod:serialize_pkt(Packet, Serialize) of
            %% FIXME: return <<>> is not correct, should return {error, message_too_large}
            <<>> ->
                ?SLOG(
                    warning,
                    #{
                        tag => ?TAG,
                        msg => "discarded_frame",
                        reason => "message_too_large",
                        frame => FrameMod:format(Packet)
                    }
                ),
                ok = inc_outgoing_stats(Ctx, FrameMod, {error, message_too_large}),
                <<>>;
            Data ->
                ?SLOG(debug, #{tag => ?TAG, msg => "raw_bin_sent", bin => Data}),
                ok = inc_outgoing_stats(Ctx, FrameMod, Packet),
                Data
        end
    end.

%%--------------------------------------------------------------------
%% Inc incoming/outgoing stats
%%--------------------------------------------------------------------

-compile(
    {inline, [
        inc_recv_stats/2,
        inc_incoming_stats/3,
        inc_outgoing_stats/3,
        inc_sent_stats/2
    ]}
).

inc_recv_stats(Cnt, Oct) ->
    inc_counter(incoming_bytes, Oct),
    inc_counter(recv_cnt, Cnt),
    inc_counter(recv_oct, Oct),
    emqx_metrics:inc('bytes.received', Oct).

inc_incoming_stats(Ctx, FrameMod, Packet) ->
    _ = emqx_pd:inc_counter(recv_pkt, 1),
    Type = FrameMod:type(Packet),
    case FrameMod:is_message(Packet) of
        true ->
            inc_counter(recv_msg, 1),
            inc_counter(incoming_pubs, 1);
        false ->
            ok
    end,
    Name = list_to_atom(lists:concat(["packets.", Type, ".received"])),
    emqx_gateway_ctx:metrics_inc(Ctx, Name).

inc_outgoing_stats(_Ctx, _FrameMod, {error, message_too_large}) ->
    inc_counter('send_msg.dropped', 1),
    inc_counter('send_msg.dropped.too_large', 1);
inc_outgoing_stats(Ctx, FrameMod, Packet) ->
    _ = emqx_pd:inc_counter(send_pkt, 1),
    Type = FrameMod:type(Packet),
    case FrameMod:is_message(Packet) of
        true ->
            inc_counter(send_msg, 1),
            inc_counter(outgoing_pubs, 1);
        false ->
            ok
    end,
    Name = list_to_atom(lists:concat(["packets.", Type, ".sent"])),
    emqx_gateway_ctx:metrics_inc(Ctx, Name).

inc_sent_stats(Cnt, Oct) ->
    inc_counter(outgoing_bytes, Oct),
    inc_counter(send_cnt, Cnt),
    inc_counter(send_oct, Oct),
    emqx_metrics:inc('bytes.sent', Oct).

inc_counter(Name, Value) ->
    _ = emqx_pd:inc_counter(Name, Value),
    ok.

%%--------------------------------------------------------------------
%% Helper functions
%%--------------------------------------------------------------------

-compile({inline, [ensure_stats_timer/1]}).

%%--------------------------------------------------------------------
%% Ensure stats timer

ensure_stats_timer(
    State = #state{
        idle_timeout = Timeout,
        stats_timer = undefined
    }
) ->
    State#state{stats_timer = start_timer(Timeout, emit_stats)};
ensure_stats_timer(State) ->
    State.

-compile({inline, [postpone/2, enqueue/2, return/1, shutdown/2]}).

%%--------------------------------------------------------------------
%% Postpone the packet, cmd or event

postpone({outgoing, Packet}, State) ->
    enqueue(Packet, State);
postpone(Event, State) when is_tuple(Event) ->
    enqueue(Event, State);
postpone(More, State) when is_list(More) ->
    lists:foldl(fun postpone/2, State, More).

enqueue([Packet], State = #state{postponed = Postponed}) ->
    State#state{postponed = [Packet | Postponed]};
enqueue(Packets, State = #state{postponed = Postponed}) when
    is_list(Packets)
->
    State#state{postponed = lists:reverse(Packets) ++ Postponed};
enqueue(Other, State = #state{postponed = Postponed}) ->
    State#state{postponed = [Other | Postponed]}.

shutdown(Reason, State = #state{postponed = Postponed}) ->
    return(State#state{postponed = [{shutdown, Reason} | Postponed]}).

return(State = #state{postponed = []}) ->
    {ok, State};
return(State = #state{postponed = Postponed}) ->
    {Packets, Cmds, Events} = classify(Postponed, [], [], []),
    ok = lists:foreach(fun trigger/1, Events),
    State1 = State#state{postponed = []},
    case {Packets, Cmds} of
        {[], []} ->
            {ok, State1};
        {[], Cmds} ->
            {Cmds, State1};
        {Packets, Cmds} ->
            {Frames, State2} = handle_outgoing(Packets, State1),
            {Frames ++ Cmds, State2}
    end.

classify([], Packets, Cmds, Events) ->
    {Packets, Cmds, Events};
classify([Packet | More], Packets, Cmds, Events) when
    %% frame
    is_tuple(Packet), tuple_size(Packet) > 2
->
    classify(More, [Packet | Packets], Cmds, Events);
classify([Cmd = {active, _} | More], Packets, Cmds, Events) ->
    classify(More, Packets, [Cmd | Cmds], Events);
classify([Cmd = {shutdown, _Reason} | More], Packets, Cmds, Events) ->
    classify(More, Packets, [Cmd | Cmds], Events);
classify([Cmd = close | More], Packets, Cmds, Events) ->
    classify(More, Packets, [Cmd | Cmds], Events);
classify([Cmd = {close, _Reason} | More], Packets, Cmds, Events) ->
    classify(More, Packets, [Cmd | Cmds], Events);
classify([Event | More], Packets, Cmds, Events) ->
    classify(More, Packets, Cmds, [Event | Events]).

trigger(Event) -> erlang:send(self(), Event).

get_peer(Req, Opts) ->
    {PeerAddr, PeerPort} = cowboy_req:peer(Req),
    AddrHeader = cowboy_req:header(
        emqx_utils_maps:deep_get([websocket, proxy_address_header], Opts), Req, <<>>
    ),
    ClientAddr =
        case string:tokens(binary_to_list(AddrHeader), ", ") of
            [] ->
                undefined;
            AddrList ->
                hd(AddrList)
        end,
    Addr =
        case inet:parse_address(ClientAddr) of
            {ok, A} ->
                A;
            _ ->
                PeerAddr
        end,
    PortHeader = cowboy_req:header(
        emqx_utils_maps:deep_get([websocket, proxy_port_header], Opts), Req, <<>>
    ),
    ClientPort =
        case string:tokens(binary_to_list(PortHeader), ", ") of
            [] ->
                undefined;
            PortList ->
                hd(PortList)
        end,
    try
        {Addr, list_to_integer(ClientPort)}
    catch
        _:_ -> {Addr, PeerPort}
    end.

to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(L) when is_list(L) -> list_to_binary(L);
to_bin(B) when is_binary(B) -> B.

%%--------------------------------------------------------------------
%% For CT tests
%%--------------------------------------------------------------------

set_field(Name, Value, State) ->
    Pos = emqx_utils:index_of(Name, record_info(fields, state)),
    setelement(Pos + 1, State, Value).
