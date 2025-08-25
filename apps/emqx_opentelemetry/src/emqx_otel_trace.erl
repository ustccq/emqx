%%--------------------------------------------------------------------
%% Copyright (c) 2023-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------
-module(emqx_otel_trace).

-behaviour(emqx_external_trace).

-export([
    ensure_traces/1,
    start/1,
    stop/0
]).

-export([toggle_registered/1]).

%% --------------------------------------------------------------------
%% Rich Trace Mode callbacks

-export([
    client_connect/3,
    client_disconnect/3,
    client_subscribe/3,
    client_unsubscribe/3,
    client_authn/3,
    client_authn_backend/3,
    client_authz/3,
    client_authz_backend/3,

    broker_disconnect/3,
    broker_subscribe/3,
    broker_unsubscribe/3,

    %% Message Processing Spans (From Client)
    %% PUBLISH(form Publisher) -> ROUTE -> FORWARD(optional) -> DELIVER(to Subscribers)
    client_publish/3,
    client_puback/3,
    client_pubrec/3,
    client_pubrel/3,
    client_pubcomp/3,
    msg_route/3,
    msg_forward/3,
    msg_handle_forward/3,

    broker_publish/3,

    %% Start Span when `emqx_channel:handle_out/3` called.
    %% Stop when `emqx_channel:handle_outgoing/3` returned
    outgoing/3,

    apply_rule/3,
    handle_action/3
]).

-export([
    msg_attrs/1
]).

%% --------------------------------------------------------------------
%% Span enrichments APIs

-export([
    add_span_attrs/1,
    add_span_attrs/2,
    set_status_ok/0,
    set_status_error/0,
    set_status_error/1
]).

%% --------------------------------------------------------------------
%% Helper APIs

-export([
    with_action_metadata/2
]).

-include("emqx_otel_trace.hrl").
-include_lib("emqx/include/emqx.hrl").
-include_lib("emqx/include/logger.hrl").
-include_lib("emqx/include/emqx_mqtt.hrl").
-include_lib("emqx/include/emqx_trace.hrl").
-include_lib("emqx_resource/include/emqx_resource_errors.hrl").
-include_lib("emqx/include/emqx_external_trace.hrl").
-include_lib("opentelemetry_api/include/otel_tracer.hrl").
-include_lib("opentelemetry_api/include/opentelemetry.hrl").

-define(EMQX_OTEL_CTX, emqx_otel_ctx).

-define(USER_PROPERTY, 'User-Property').

-define(TRACE_MODE_E2E, e2e).
-define(TRACE_MODE_LEGACY, legacy).

-define(TRACE_MODE_KEY, {?MODULE, trace_mode}).
-define(TRACE_ALL_KEY, {?MODULE, trace_all}).
-define(TRACE_FOLLOW_TRACEPARENT_KEY, {?MODULE, follow_traceparent}).
-define(SHOULD_TRACE_ALL, persistent_term:get(?TRACE_ALL_KEY, false)).

-define(with_process_fun_apply(SpanName, Attrs, ProcessFun, Args),
    ?with_trace_mode(
        erlang:apply(ProcessFun, Args),
        ?with_span(
            SpanName,
            #{attributes => Attrs},
            fun(_SpanCtx) ->
                erlang:apply(ProcessFun, Args)
            end
        )
    )
).

-define(with_trace_mode(LegacyModeBody, E2EModeBody),
    case persistent_term:get(?TRACE_MODE_KEY, ?TRACE_MODE_LEGACY) of
        ?TRACE_MODE_E2E -> E2EModeBody;
        ?TRACE_MODE_LEGACY -> LegacyModeBody
    end
).

%%--------------------------------------------------------------------
%% config
%%--------------------------------------------------------------------

-spec toggle_registered(boolean()) -> ok | {error, term()}.
toggle_registered(true = _Enable) ->
    emqx_external_trace:register_provider(?MODULE);
toggle_registered(false = _Enable) ->
    _ = emqx_external_trace:unregister_provider(?MODULE),
    ok.

-spec ensure_traces(map()) -> ok | {error, term()}.
ensure_traces(#{traces := #{enable := true}} = Conf) ->
    start(Conf);
ensure_traces(_Conf) ->
    ok.

-spec start(map()) -> ok | {error, term()}.
start(#{traces := TracesConf, exporter := ExporterConf}) ->
    #{
        max_queue_size := MaxQueueSize,
        exporting_timeout := ExportingTimeout,
        scheduled_delay := ScheduledDelay,
        filter := Filter
    } = TracesConf,
    OtelEnv =
        [
            {bsp_scheduled_delay_ms, ScheduledDelay},
            {bsp_exporting_timeout_ms, ExportingTimeout},
            {bsp_max_queue_size, MaxQueueSize},
            {traces_exporter, emqx_otel_config:otel_exporter(ExporterConf)}
        ] ++ set_trace_filter(Filter),
    ok = application:set_env([{opentelemetry, OtelEnv}]),
    Res = assert_started(opentelemetry:start_default_tracer_provider()),
    case Res of
        ok ->
            _ = toggle_registered(true),
            Res;
        Err ->
            Err
    end.

set_trace_filter(#{
    trace_mode := ?TRACE_MODE_LEGACY,
    trace_all := TraceAll
}) ->
    %% local setting, no sampler
    persistent_term:put(?TRACE_MODE_KEY, ?TRACE_MODE_LEGACY),
    persistent_term:put(?TRACE_ALL_KEY, TraceAll),
    _ = application:unset_env(opentelemetry, sampler),
    [];
set_trace_filter(#{
    trace_mode := ?TRACE_MODE_E2E,
    e2e_tracing_options := E2EOpts
}) ->
    persistent_term:put(?TRACE_MODE_KEY, ?TRACE_MODE_E2E),
    persistent_term:put(
        ?TRACE_FOLLOW_TRACEPARENT_KEY,
        maps:get(follow_traceparent, E2EOpts, true)
    ),
    [{sampler, {emqx_otel_sampler, E2EOpts}}].

-spec stop() -> ok.
stop() ->
    _ = toggle_registered(false),
    safe_stop_default_tracer().

%%--------------------------------------------------------------------
%% Rich mode trace API
%%--------------------------------------------------------------------

-spec client_connect(
    InitAttrs :: emqx_external_trace:init_attrs(),
    ProcessFun :: emqx_external_trace:t_fun(),
    Args :: emqx_external_trace:t_args()
) ->
    Res :: emqx_external_trace:t_res().
client_connect(InitAttrs, ProcessFun, [Packet] = Args) ->
    ?with_trace_mode(
        erlang:apply(ProcessFun, Args),
        begin
            RootCtx = e2e_mode_root_ctx(Packet),
            SpanCtx = otel_tracer:start_span(
                RootCtx,
                ?current_tracer,
                ?CLIENT_CONNECT_SPAN_NAME,
                #{attributes => InitAttrs}
            ),
            Ctx = otel_tracer:set_current_span(RootCtx, SpanCtx),
            _ = otel_ctx:attach(Ctx),
            try
                erlang:apply(ProcessFun, Args)
            after
                _ = ?end_span(),
                clear()
            end
        end
    ).

-spec client_disconnect(
    InitAttrs :: emqx_external_trace:init_attrs(),
    ProcessFun :: emqx_external_trace:t_fun(),
    Args :: emqx_external_trace:t_args()
) ->
    Res :: emqx_external_trace:t_res().
client_disconnect(InitAttrs, ProcessFun, [Packet] = Args) ->
    ?with_trace_mode(
        erlang:apply(ProcessFun, Args),
        begin
            RootCtx = e2e_mode_root_ctx(Packet),
            SpanCtx = otel_tracer:start_span(
                RootCtx,
                ?current_tracer,
                ?CLIENT_DISCONNECT_SPAN_NAME,
                #{attributes => InitAttrs}
            ),
            Ctx = otel_tracer:set_current_span(RootCtx, SpanCtx),
            _ = otel_ctx:attach(Ctx),
            try
                erlang:apply(ProcessFun, Args)
            after
                _ = ?end_span(),
                clear()
            end
        end
    ).

-spec client_subscribe(
    InitAttrs :: emqx_external_trace:init_attrs(),
    ProcessFun :: emqx_external_trace:t_fun(),
    Args :: emqx_external_trace:t_args()
) ->
    Res :: emqx_external_trace:t_res().
client_subscribe(InitAttrs, ProcessFun, [Packet] = Args) ->
    ?with_trace_mode(
        erlang:apply(ProcessFun, Args),
        begin
            RootCtx = e2e_mode_root_ctx(Packet),
            SpanCtx = otel_tracer:start_span(
                RootCtx,
                ?current_tracer,
                ?CLIENT_SUBSCRIBE_SPAN_NAME,
                #{attributes => InitAttrs}
            ),
            Ctx = otel_tracer:set_current_span(RootCtx, SpanCtx),
            _ = otel_ctx:attach(Ctx),
            try
                erlang:apply(ProcessFun, Args)
            after
                _ = ?end_span(),
                clear()
            end
        end
    ).

-spec client_unsubscribe(
    InitAttrs :: emqx_external_trace:init_attrs(),
    ProcessFun :: emqx_external_trace:t_fun(),
    Args :: emqx_external_trace:t_args()
) ->
    Res :: emqx_external_trace:t_res().
client_unsubscribe(InitAttrs, ProcessFun, [Packet] = Args) ->
    ?with_trace_mode(
        erlang:apply(ProcessFun, Args),
        begin
            RootCtx = e2e_mode_root_ctx(Packet),
            SpanCtx = otel_tracer:start_span(
                RootCtx,
                ?current_tracer,
                ?CLIENT_UNSUBSCRIBE_SPAN_NAME,
                #{attributes => InitAttrs}
            ),
            Ctx = otel_tracer:set_current_span(RootCtx, SpanCtx),
            _ = otel_ctx:attach(Ctx),
            try
                erlang:apply(ProcessFun, Args)
            after
                _ = ?end_span(),
                clear()
            end
        end
    ).

-spec client_authn(
    Attrs :: emqx_external_trace:attrs(),
    ProcessFun :: emqx_external_trace:t_fun(),
    Args :: emqx_external_trace:t_args()
) ->
    Res :: emqx_external_trace:t_res().
client_authn(Attrs, ProcessFun, Args) ->
    ?with_process_fun_apply(?CLIENT_AUTHN_SPAN_NAME, Attrs, ProcessFun, Args).

-spec client_authn_backend(
    Attrs :: emqx_external_trace:attrs(),
    ProcessFun :: emqx_external_trace:t_fun(),
    Args :: emqx_external_trace:t_args()
) ->
    Res
when
    Res :: emqx_external_trace:t_res().
client_authn_backend(Attrs, ProcessFun, Args) ->
    ?with_process_fun_apply(?CLIENT_AUTHN_BACKEND_SPAN_NAME, Attrs, ProcessFun, Args).

-spec client_authz(
    Attrs :: emqx_external_trace:attrs(),
    ProcessFun :: emqx_external_trace:t_fun(),
    Args :: emqx_external_trace:t_args()
) ->
    Res :: emqx_external_trace:t_res().
client_authz(Attrs, ProcessFun, Args) ->
    ?with_process_fun_apply(?CLIENT_AUTHZ_SPAN_NAME, Attrs, ProcessFun, Args).

-spec client_authz_backend(
    Attrs :: emqx_external_trace:attrs(),
    ProcessFun :: emqx_external_trace:t_fun(),
    Args :: emqx_external_trace:t_args()
) ->
    Res :: emqx_external_trace:t_res().
client_authz_backend(Attrs, ProcessFun, Args) ->
    ?with_process_fun_apply(?CLIENT_AUTHZ_BACKEND_SPAN_NAME, Attrs, ProcessFun, Args).

-spec broker_disconnect(
    InitAttrs :: emqx_external_trace:init_attrs(),
    ProcessFun :: emqx_external_trace:t_fun(),
    Args :: emqx_external_trace:t_args()
) ->
    Res :: emqx_external_trace:t_res().
broker_disconnect(InitAttrs, ProcessFun, Args) ->
    ?with_process_fun_apply(?BROKER_DISCONNECT_SPAN_NAME, InitAttrs, ProcessFun, Args).

-spec broker_subscribe(
    InitAttrs :: emqx_external_trace:init_attrs(),
    ProcessFun :: emqx_external_trace:t_fun(),
    Args :: emqx_external_trace:t_args()
) ->
    Res :: emqx_external_trace:t_res().
broker_subscribe(InitAttrs, ProcessFun, Args) ->
    ?with_process_fun_apply(?BROKER_SUBSCRIBE_SPAN_NAME, InitAttrs, ProcessFun, Args).

-spec broker_unsubscribe(
    InitAttrs :: emqx_external_trace:init_attrs(),
    ProcessFun :: emqx_external_trace:t_fun(),
    Args :: emqx_external_trace:t_args()
) ->
    Res :: emqx_external_trace:t_res().
broker_unsubscribe(InitAttrs, ProcessFun, Args) ->
    ?with_process_fun_apply(?BROKER_UNSUBSCRIBE_SPAN_NAME, InitAttrs, ProcessFun, Args).

-spec client_publish(
    InitAttrs :: emqx_external_trace:init_attrs(),
    ProcessFun :: emqx_external_trace:t_fun(),
    Args :: emqx_external_trace:t_args()
) ->
    Res :: emqx_external_trace:t_res().
client_publish(InitAttrs, ProcessFun, [Packet] = Args) ->
    ?with_trace_mode(
        trace_process_publish(
            Packet, #{clientid => maps:get('client.clientid', InitAttrs)}, ProcessFun
        ),
        begin
            %% XXX: should trace for durable sessions?
            RootCtx = e2e_mode_root_ctx(Packet),
            SpanCtx = otel_tracer:start_span(
                RootCtx,
                ?current_tracer,
                ?CLIENT_PUBLISH_SPAN_NAME,
                #{attributes => InitAttrs}
            ),
            Ctx = otel_tracer:set_current_span(RootCtx, SpanCtx),
            %% Otel attach for next spans (client_authz, msg_route... etc )
            _ = otel_ctx:attach(Ctx),

            %% Attach in process dictionary for outgoing/awaiting packets
            %% for PUBACK/PUBREC/PUBREL/PUBCOMP
            %% TODO: CONNACK, AUTH, SUBACK, UNSUBACK, DISCONNECT
            attach_outgoing(Packet, Ctx),

            try
                erlang:apply(ProcessFun, Args)
            after
                _ = ?end_span(),
                erase_outgoing(Packet),
                clear()
            end
        end
    ).

-compile({inline, [attach_outgoing/2, erase_outgoing/1]}).
attach_outgoing(?PUBLISH_PACKET(?QOS_0), _Ctx) ->
    ok;
attach_outgoing(?PUBLISH_PACKET(?QOS_1, PacketId), Ctx) ->
    attach_internal_ctx(
        {?PUBACK, PacketId},
        Ctx
    ),
    ok;
attach_outgoing(?PUBLISH_PACKET(?QOS_2, PacketId), Ctx) ->
    attach_internal_ctx(
        {?PUBREC, PacketId},
        Ctx
    ),
    ok.

erase_outgoing(?PUBLISH_PACKET(?QOS_0)) ->
    ok;
erase_outgoing(?PUBLISH_PACKET(?QOS_1, PacketId)) ->
    earse_internal_ctx({?PUBACK, PacketId}),
    ok;
erase_outgoing(?PUBLISH_PACKET(?QOS_2, PacketId)) ->
    earse_internal_ctx({?PUBREC, PacketId}),
    ok.

-spec client_puback(
    InitAttrs :: emqx_external_trace:init_attrs(),
    ProcessFun :: emqx_external_trace:t_fun(),
    Args :: emqx_external_trace:t_args()
) ->
    Res :: emqx_external_trace:t_res().
client_puback(InitAttrs, ProcessFun, Args) ->
    client_incoming(InitAttrs, ProcessFun, Args).

-spec client_pubrec(
    InitAttrs :: emqx_external_trace:init_attrs(),
    ProcessFun :: emqx_external_trace:t_fun(),
    Args :: emqx_external_trace:t_args()
) ->
    Res :: emqx_external_trace:t_res().
client_pubrec(InitAttrs, ProcessFun, Args) ->
    client_incoming(InitAttrs, ProcessFun, Args).

-spec client_pubrel(
    InitAttrs :: emqx_external_trace:init_attrs(),
    ProcessFun :: emqx_external_trace:t_fun(),
    Args :: emqx_external_trace:t_args()
) ->
    Res :: emqx_external_trace:t_res().
client_pubrel(InitAttrs, ProcessFun, Args) ->
    client_incoming(InitAttrs, ProcessFun, Args).

-spec client_pubcomp(
    InitAttrs :: emqx_external_trace:init_attrs(),
    ProcessFun :: emqx_external_trace:t_fun(),
    Args :: emqx_external_trace:t_args()
) ->
    Res :: emqx_external_trace:t_res().
client_pubcomp(InitAttrs, ProcessFun, Args) ->
    client_incoming(InitAttrs, ProcessFun, Args).

-spec msg_route(
    InitAttrs :: emqx_external_trace:init_attrs(),
    ProcessFun :: emqx_external_trace:t_fun(),
    Args :: emqx_external_trace:t_args()
) ->
    Res :: emqx_external_trace:t_res().
msg_route(InitAttrs, ProcessFun, [Delivery] = Args) ->
    ?with_trace_mode(
        erlang:apply(ProcessFun, Args),
        case ignore_delivery(Delivery) of
            true ->
                erlang:apply(ProcessFun, Args);
            false ->
                ?with_span(
                    ?MSG_ROUTE_SPAN_NAME,
                    #{attributes => InitAttrs},
                    fun(_SpanCtx) ->
                        NArgs = [put_ctx(otel_ctx:get_current(), Delivery)],
                        erlang:apply(ProcessFun, NArgs)
                    end
                )
        end
    ).

-spec msg_forward(
    InitAttrs :: emqx_external_trace:init_attrs(),
    ProcessFun :: emqx_external_trace:t_fun(),
    Args :: emqx_external_trace:t_args()
) ->
    Res :: emqx_external_trace:t_res().
msg_forward(InitAttrs, ProcessFun, [Delivery] = Args) ->
    ?with_trace_mode(
        erlang:apply(ProcessFun, Args),
        case ignore_delivery(Delivery) of
            true ->
                erlang:apply(ProcessFun, Args);
            false ->
                ?with_span(
                    ?MSG_FORWARD_SPAN_NAME,
                    #{attributes => InitAttrs},
                    fun(_SpanCtx) ->
                        NArgs = [put_ctx(otel_ctx:get_current(), Delivery)],
                        erlang:apply(ProcessFun, NArgs)
                    end
                )
        end
    ).

-spec msg_handle_forward(
    InitAttrs :: emqx_external_trace:init_attrs(),
    ProcessFun :: emqx_external_trace:t_fun(),
    Args :: emqx_external_trace:t_args()
) ->
    Res :: emqx_external_trace:t_res().
msg_handle_forward(InitAttrs, ProcessFun, [Delivery] = Args) ->
    ?with_trace_mode(
        erlang:apply(ProcessFun, Args),
        case ignore_delivery(Delivery) of
            true ->
                erlang:apply(ProcessFun, Args);
            false ->
                _ = otel_ctx:attach(get_ctx(Delivery)),
                ?with_span(
                    ?MSG_HANDLE_FORWARD_SPAN_NAME,
                    #{attributes => InitAttrs},
                    fun(_SpanCtx) ->
                        NArgs = [put_ctx(otel_ctx:get_current(), Delivery)],
                        erlang:apply(ProcessFun, NArgs)
                    end
                )
        end
    ).

%% NOTE:
%% Span starts in Delivers(Msg) and stops when outgoing(Packets)
%% Only for `PUBLISH(Qos=0|1|2)`
-spec broker_publish(
    emqx_external_trace:attrs(),
    TraceAction :: ?EXT_TRACE_START,
    %% Delivers with Ctx Attached
    list(Deliver)
) -> list(Deliver) when
    Deliver :: emqx_types:deliver().
broker_publish(Attrs, ?EXT_TRACE_START, Delivers) ->
    ?with_trace_mode(
        start_trace_send(Delivers, #{clientid => maps:get('client.clientid', Attrs)}),
        lists:map(
            fun({deliver, Topic, Msg0} = Deliver) ->
                case get_ctx(Msg0) of
                    Ctx when is_map(Ctx) ->
                        NAttrs = maps:merge(Attrs, msg_attrs(Msg0)),
                        SpanCtx = otel_tracer:start_span(
                            Ctx, ?current_tracer, ?BROKER_PUBLISH_SPAN_NAME, #{attributes => NAttrs}
                        ),
                        NCtx = otel_tracer:set_current_span(Ctx, SpanCtx),
                        Msg = put_ctx(NCtx, Msg0),
                        {deliver, Topic, Msg};
                    _ ->
                        Deliver
                end
            end,
            Delivers
        )
    ).

-spec outgoing(
    Attrs :: emqx_external_trace:attrs(),
    TraceAction :: ?EXT_TRACE_START | ?EXT_TRACE_STOP,
    emqx_types:packet() | [emqx_types:packet()]
) ->
    Res :: emqx_external_trace:t_res().
outgoing(Attrs, ?EXT_TRACE_START, Packet) ->
    %% Note: the function case only for
    %% `PUBACK`, `PUBREC`, `PUBREL`, `PUBCOMP`
    ?with_trace_mode(
        Packet,
        start_outgoing_trace(Attrs, Packet)
    );
outgoing(Attrs, ?EXT_TRACE_STOP, Any) ->
    ?with_trace_mode(
        end_trace_send(Any),
        stop_outgoing_trace(Attrs, Any)
    ).

-spec apply_rule(
    Attrs :: emqx_external_trace:attrs(),
    ProcessFun :: emqx_external_trace:t_fun(),
    Args :: emqx_external_trace:t_args()
) ->
    Res :: emqx_external_trace:t_res().
apply_rule(Attrs, ProcessFun, [Envs] = Args) ->
    ?with_trace_mode(
        erlang:apply(ProcessFun, Args),
        ?with_span(
            ?BROKER_RULE_ENGINE_APPLY,
            #{attributes => Attrs},
            fun(_SpanCtx) ->
                erlang:apply(ProcessFun, [
                    Envs#{metadata => #{?EMQX_OTEL_CTX => otel_ctx:get_current()}}
                ])
            end
        )
    ).

-spec handle_action(
    Attrs :: emqx_external_trace:attrs(),
    TraceAction :: ?EXT_TRACE_START | ?EXT_TRACE_STOP,
    Any :: map()
) ->
    Res :: emqx_external_trace:t_res().
handle_action(Attrs, ?EXT_TRACE_START, Envs) ->
    ?with_trace_mode(
        Envs,
        begin
            RootCtx = e2e_mode_root_ctx(Envs),
            %% Start span here, but will end it after async action done
            %% XXX: should end `action' span after fallback span?
            %% FIXME: fix default OTEL_SPAN_SWEEPER_STRATEGY
            %% https://hexdocs.pm/opentelemetry/1.5.0/readme.html#span-sweeper
            SpanCtx = otel_tracer:start_span(
                RootCtx,
                ?current_tracer,
                ?BROKER_RULE_ENGINE_ACTION,
                #{attributes => Attrs}
            ),
            Ctx = otel_tracer:set_current_span(RootCtx, SpanCtx),
            put_ctx(Ctx, Envs)
        end
    );
handle_action(_Attrs, ?EXT_TRACE_STOP, RequestContext) ->
    ?with_trace_mode(
        ok,
        begin
            Ctx = e2e_mode_root_ctx(RequestContext),
            CurrentSpanCtx = otel_tracer:current_span_ctx(Ctx),
            _ = set_status_by_request_result(CurrentSpanCtx, RequestContext),
            otel_span:end_span(CurrentSpanCtx)
        end
    ).

%%--------------------------------------------------------------------
%% Legacy Mode
%%--------------------------------------------------------------------

-spec trace_process_publish(Packet, ChannelInfo, fun((Packet) -> Res)) -> Res when
    Packet :: emqx_types:packet(),
    ChannelInfo :: emqx_external_trace:channel_info(),
    Res :: term().
trace_process_publish(Packet, ChannelInfo, ProcessFun) ->
    case legacy_mode_root_ctx(Packet) of
        false ->
            ProcessFun(Packet);
        RootCtx ->
            Attrs = maps:merge(packet_attributes(Packet), channel_attributes(ChannelInfo)),
            SpanCtx = otel_tracer:start_span(RootCtx, ?current_tracer, process_message, #{
                attributes => Attrs
            }),
            Ctx = otel_tracer:set_current_span(RootCtx, SpanCtx),
            %% put ctx to packet, so it can be further propagated
            Packet1 = put_ctx_to_packet(Ctx, Packet),
            _ = otel_ctx:attach(Ctx),
            try
                ProcessFun(Packet1)
            after
                _ = ?end_span(),
                clear()
            end
    end.

-spec start_trace_send(list(emqx_types:deliver()), emqx_external_trace:channel_info()) ->
    list(emqx_types:deliver()).
start_trace_send(Delivers, ChannelInfo) ->
    lists:map(
        fun({deliver, Topic, Msg} = Deliver) ->
            case get_ctx_from_msg(Msg) of
                Ctx when is_map(Ctx) ->
                    Attrs = maps:merge(
                        msg_attributes(Msg), sub_channel_attributes(ChannelInfo)
                    ),
                    StartOpts = #{attributes => Attrs},
                    SpanCtx = otel_tracer:start_span(
                        Ctx, ?current_tracer, send_published_message, StartOpts
                    ),
                    Msg1 = put_ctx_to_msg(
                        otel_tracer:set_current_span(Ctx, SpanCtx), Msg
                    ),
                    {deliver, Topic, Msg1};
                _ ->
                    Deliver
            end
        end,
        Delivers
    ).

-spec end_trace_send(emqx_types:packet() | [emqx_types:packet()]) -> ok.
end_trace_send(Packets) ->
    lists:foreach(
        fun(Packet) ->
            case get_ctx_from_packet(Packet) of
                Ctx when is_map(Ctx) ->
                    otel_span:end_span(otel_tracer:current_span_ctx(Ctx));
                _ ->
                    ok
            end
        end,
        packets_list(Packets)
    ).

%% --------------------------------------------------------------------
%% Internal Helpers
%% --------------------------------------------------------------------

%% ====================
%% Broker -> Client(`Publisher'):
start_outgoing_trace(Attrs, ?PUBACK_PACKET(PacketId) = Packet) ->
    start_outgoing_trace(Attrs, Packet, detach_internal_ctx({?PUBACK, PacketId}));
start_outgoing_trace(Attrs, ?PUBREC_PACKET(PacketId) = Packet) ->
    start_outgoing_trace(Attrs, Packet, detach_internal_ctx({?PUBREC, PacketId}));
start_outgoing_trace(Attrs, ?PUBCOMP_PACKET(PacketId) = Packet) ->
    start_outgoing_trace(Attrs, Packet, detach_internal_ctx({?PUBREL, PacketId}));
%% ====================
%% Broker -> Client(`Subscriber'):
start_outgoing_trace(Attrs, ?PUBREL_PACKET(PacketId) = Packet) ->
    %% Previous awaiting was PUBREC
    %% the awaiting PUBREL Span's parent is outgoing PUBREC Span
    start_outgoing_trace(Attrs, Packet, detach_internal_ctx({?PUBREC, PacketId}));
%% The Incoming span is still being recorded and Ctx has not been erased
%% when the following outgoing spans starting.
%% `SUBACK' / `UNSUBACK' / `PUBACK'
start_outgoing_trace(Attrs, Packet) ->
    start_outgoing_trace(Attrs, Packet, otel_ctx:get_current()).

start_outgoing_trace(Attrs, Packet, ParentCtx) ->
    SpanCtx = otel_tracer:start_span(
        ParentCtx,
        ?current_tracer,
        outgoing_span_name(Packet),
        #{attributes => Attrs}
    ),
    NCtx = otel_tracer:set_current_span(ParentCtx, SpanCtx),
    _PacketWithCtx = put_ctx(NCtx, Packet).

%% Ctx attached in Delivers in `broker_publish/2` and
%% transformed to Packet when outgoing
stop_outgoing_trace(Attrs, Anys) when is_list(Anys) ->
    lists:foreach(fun(Any) -> stop_outgoing_trace(Attrs, Any) end, Anys);
stop_outgoing_trace(Attrs, Packet) when is_record(Packet, mqtt_packet) ->
    %% Maybe awaiting for next Packet
    %% The current outgoing Packet SHOULD NOT be modified
    ok = outgoing_maybe_awaiting_next(Packet, Attrs),
    Ctx = get_ctx(Packet),
    ok = maybe_override_message_qos(Packet, Ctx),
    end_span(Ctx);
stop_outgoing_trace(_Attrs, Any) ->
    end_span(get_ctx(Any)).

-compile({inline, [end_span/1]}).
end_span(Ctx) when
    is_map(Ctx)
->
    otel_span:end_span(otel_tracer:current_span_ctx(Ctx));
end_span(_) ->
    ok.

%% Note:
%% When replying PUBACK/PUBREC/PUBCOMP to the `Publisher' or sending PUBLISH/PUBREL to the `Subscriber',
%% the current `PacketId' is stored and awaiting-trace begins.
%% At this time, a new span begins and the span ends after receiving and processing the reply
%% from Client(might be Publisher or Subscriber).

-compile({inline, [outgoing_maybe_awaiting_next/2]}).
%% ====================
%% Broker -> Client(`Publisher'):
outgoing_maybe_awaiting_next(?PACKET(?PUBACK), _Attrs) ->
    %% PUBACK (QoS=1), Ignore
    ok;
outgoing_maybe_awaiting_next(?PUBREC_PACKET(PacketId, _ReasonCode) = Packet, Attrs) ->
    %% PUBREC (QoS=2), Awaiting PUBREL
    start_awaiting_trace(?PUBREL, PacketId, Packet, Attrs);
outgoing_maybe_awaiting_next(?PACKET(?PUBCOMP), _Attrs) ->
    %% PUBCOMP (QoS=2), Ignore
    ok;
%% ====================
%% Broker -> Client(`Subscriber'):
outgoing_maybe_awaiting_next(?PUBLISH_PACKET(?QOS_0), _Attrs) ->
    %% PUBLISH (QoS=0), Ignore
    ok;
outgoing_maybe_awaiting_next(?PUBLISH_PACKET(?QOS_1, PacketId) = Packet, Attrs) ->
    %% PUBLISH (QoS=1), Awaiting PUBACK
    start_awaiting_trace(?PUBACK, PacketId, Packet, Attrs);
outgoing_maybe_awaiting_next(?PUBLISH_PACKET(?QOS_2, PacketId) = Packet, Attrs) ->
    %% PUBLISH (QoS=2), Awaiting PUBREC
    start_awaiting_trace(?PUBREC, PacketId, Packet, Attrs);
outgoing_maybe_awaiting_next(?PUBREL_PACKET(PacketId, _ReasonCode) = Packet, Attrs) ->
    %% PUBREL (QoS=2), Awaiting PUBCOMP
    start_awaiting_trace(?PUBCOMP, PacketId, Packet, Attrs);
%% ====================
outgoing_maybe_awaiting_next(_, _) ->
    %% TODO: Awaiting AUTH
    ok.

maybe_override_message_qos(?PUBLISH_PACKET(QoS), Ctx) ->
    ok = add_span_attrs(#{'message.qos' => QoS}, Ctx);
maybe_override_message_qos(_, _Ctx) ->
    ok.

start_awaiting_trace(AwaitingType, PacketId, Packet, Attrs) ->
    AwaitingCtxKey = internal_extra_key(AwaitingType, PacketId),
    ParentCtx = get_ctx(Packet),
    AwaitingSpanCtx = otel_tracer:start_span(
        ParentCtx,
        ?current_tracer,
        awaiting_span_name(AwaitingType),
        #{attributes => Attrs}
    ),
    NCtx = otel_tracer:set_current_span(ParentCtx, AwaitingSpanCtx),
    _ = attach_internal_ctx(AwaitingCtxKey, NCtx),
    ok.

client_incoming(Attrs, ProcessFun, [?PACKET(AwaitingType, PktVar)] = Args) ->
    ?with_trace_mode(
        erlang:apply(ProcessFun, Args),
        try
            erlang:apply(ProcessFun, Args)
        after
            end_awaiting_client_packet(
                internal_extra_key(AwaitingType, PktVar), Attrs
            )
        end
    ).

end_awaiting_client_packet(AwaitingCtxKey, Attrs) ->
    case detach_internal_ctx(AwaitingCtxKey) of
        Ctx when is_map(Ctx) ->
            ok = add_span_attrs(Attrs, Ctx),
            _ = end_span(Ctx),
            earse_internal_ctx(AwaitingCtxKey),
            ok;
        _ ->
            %% TODO:
            %% erlang:get() for all internal_extra_key and erase all unknown Awaiting Type
            earse_internal_ctx(AwaitingCtxKey),
            ok
    end,
    ok.

%%--------------------------------------------------------------------

attach_internal_ctx({Type, PktVarOrPacketId}, Value) ->
    attach_internal_ctx(internal_extra_key(Type, PktVarOrPacketId), Value);
attach_internal_ctx(Key, Value) ->
    erlang:put(Key, Value).

detach_internal_ctx({Type, PktVarOrPacketId}) ->
    detach_internal_ctx(internal_extra_key(Type, PktVarOrPacketId));
detach_internal_ctx(Key) ->
    erlang:get(Key).

earse_internal_ctx({Type, PktVarOrPacketId}) ->
    earse_internal_ctx(internal_extra_key(Type, PktVarOrPacketId));
earse_internal_ctx(Key) ->
    erlang:erase(Key).

-compile(
    {inline, [
        internal_extra_key/2,
        outgoing_span_name/1,
        awaiting_span_name/1
    ]}
).

internal_extra_key(Type, PktVar) when is_tuple(PktVar) ->
    internal_extra_key(
        Type,
        emqx_packet:info(packet_id, PktVar)
    );
internal_extra_key(Type, PacketId) ->
    {
        ?MQTT_INTERNAL_EXTRA,
        emqx_packet:type_name(Type),
        PacketId
    }.

%% Outgoing Packet Span Name
%% Broker -> Client(`Subscriber'):
outgoing_span_name(?PACKET(?PUBREL)) ->
    %% PUBREL (QoS=2)
    ?BROKER_PUBREL_SPAN_NAME;
%% Broker -> Client(`Publisher'):
outgoing_span_name(?PACKET(?PUBACK)) ->
    %% PUBACK (QoS=1)
    ?BROKER_PUBACK_SPAN_NAME;
outgoing_span_name(?PACKET(?PUBREC)) ->
    %% PUBREC (QoS=2)
    ?BROKER_PUBREC_SPAN_NAME;
outgoing_span_name(?PACKET(?PUBCOMP)) ->
    %% PUBCOMP (QoS=2)
    ?BROKER_PUBCOMP_SPAN_NAME.

%% Incoming Packet Span Name
%% Client(`Publisher') -> Broker:
awaiting_span_name(?PUBREL) ->
    %% PUBREL (QoS=2)
    ?CLIENT_PUBREL_SPAN_NAME;
%% Client(`Subscriber') -> Broker:
awaiting_span_name(?PUBACK) ->
    %% PUBACK (QoS=1)
    ?CLIENT_PUBACK_SPAN_NAME;
awaiting_span_name(?PUBREC) ->
    %% PUBREC (QoS=2)
    ?CLIENT_PUBREC_SPAN_NAME;
awaiting_span_name(?PUBCOMP) ->
    %% PUBCOMP (QoS=2)
    ?CLIENT_PUBCOMP_SPAN_NAME.

set_status_by_request_result(SpanCtx, #{result := Result} = _RequestContext) ->
    do_set_status_by_request_result(SpanCtx, Result);
set_status_by_request_result(_SpanCtx, _RequestContext) ->
    %% no manually set status, Span status will be ?OTEL_STATUS_UNSET
    ok.

do_set_status_by_request_result(SpanCtx, ?EMQX_TRACE_STOP_ACTION(_)) ->
    set_status(SpanCtx, ?OTEL_STATUS_ERROR, <<"action_stopped_after_template_rendering">>);
do_set_status_by_request_result(SpanCtx, ?RESOURCE_ERROR_M(_, _)) ->
    set_status(SpanCtx, ?OTEL_STATUS_ERROR, <<"out_of_service">>);
do_set_status_by_request_result(SpanCtx, {error, {recoverable_error, _}}) ->
    set_status(SpanCtx, ?OTEL_STATUS_ERROR, <<"out_of_service">>);
do_set_status_by_request_result(SpanCtx, {error, {unrecoverable_error, _}}) ->
    set_status(SpanCtx, ?OTEL_STATUS_ERROR, <<"action_failed_unknown">>);
do_set_status_by_request_result(SpanCtx, R) ->
    case is_ok_result(R) of
        false ->
            set_status(SpanCtx, ?OTEL_STATUS_ERROR, <<"action_failed_unknown">>);
        true ->
            set_status(SpanCtx, ?OTEL_STATUS_OK)
    end.

is_ok_result(ok) ->
    true;
is_ok_result({async_return, R}) ->
    is_ok_result(R);
is_ok_result(R) when is_tuple(R) ->
    ok == erlang:element(1, R);
is_ok_result(_) ->
    false.

set_status(SpanCtx, StatusOrCode) ->
    otel_span:set_status(SpanCtx, StatusOrCode).

set_status(SpanCtx, StatusOrCode, Msg) ->
    otel_span:set_status(SpanCtx, StatusOrCode, Msg).

%%--------------------------------------------------------------------
%% Span Attributes API
%%--------------------------------------------------------------------

-spec add_span_attrs(AttrsOrMeta) -> ok when
    AttrsOrMeta :: emqx_external_trace:attrs().
add_span_attrs(EmpytAttr) when map_size(EmpytAttr) =:= 0 ->
    ok;
add_span_attrs(Attrs) ->
    ?with_trace_mode(
        ok,
        begin
            _ = ?set_attributes(Attrs),
            ok
        end
    ).

add_span_attrs(Attrs, Ctx) ->
    CurrentSpanCtx = otel_tracer:current_span_ctx(Ctx),
    otel_span:set_attributes(CurrentSpanCtx, Attrs),
    ok.

-spec set_status_ok() -> ok.
set_status_ok() ->
    ?with_trace_mode(
        ok,
        begin
            ?set_status(?OTEL_STATUS_OK),
            ok
        end
    ).

-spec set_status_error() -> ok.
set_status_error() ->
    set_status_error(<<>>).

-spec set_status_error(unicode:unicode_binary()) -> ok.
set_status_error(Msg) ->
    ?with_trace_mode(
        ok,
        begin
            ?set_status(?OTEL_STATUS_ERROR, Msg),
            ok
        end
    ).

msg_attrs(_Msg = #message{flags = #{sys := true}}) ->
    #{};
msg_attrs(Msg = #message{}) ->
    Attrs = #{
        'message.msgid' => emqx_guid:to_hexstr(Msg#message.id),
        'message.qos' => Msg#message.qos,
        'message.from' => Msg#message.from,
        'message.topic' => Msg#message.topic,
        'message.retain' => maps:get(retain, Msg#message.flags, false),
        'message.payload_size' => size(Msg#message.payload)
    },
    msg_attr_props(Msg, Attrs).

msg_attr_props(#message{headers = #{properties := Props0 = #{'User-Property' := _}}}, Acc) ->
    Props = maps:update_with('User-Property', fun maps:from_list/1, Props0),
    Acc#{
        'message.pub_props' => emqx_utils_json:encode(Props)
    };
msg_attr_props(#message{headers = #{properties := Props = #{}}}, Acc) ->
    Acc#{
        'message.pub_props' => emqx_utils_json:encode(Props)
    };
msg_attr_props(_Msg, Acc) ->
    Acc.

with_action_metadata(#{metadata := Metadata} = _Envs, RequestContext) when
    is_map(RequestContext)
->
    RequestContext#{metadata => Metadata};
with_action_metadata(_Envs, RequestContext) ->
    RequestContext.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

ignore_delivery(#delivery{message = #message{topic = Topic}}) ->
    is_sys(Topic).

%% ====================
%% Trace Context in message
put_ctx(
    OtelCtx,
    Msg = #message{extra = Extra}
) when is_map(Extra) ->
    Msg#message{extra = Extra#{?EMQX_OTEL_CTX => OtelCtx}};
%% ====================
%% Trace Context in delivery
put_ctx(OtelCtx, #delivery{message = Msg} = Delivery) ->
    NMsg = put_ctx(OtelCtx, Msg),
    Delivery#delivery{message = NMsg};
%% ====================
%% Trace Context in packet PUBLISH or PUBACK(PUBREC, PUBREL, PUBCOMP distinguish by type and qos)
put_ctx(
    OtelCtx,
    #mqtt_packet{
        variable = #mqtt_packet_publish{properties = Props} = PubPacket
    } = Packet
) ->
    NProps = to_properties(?EMQX_OTEL_CTX, OtelCtx, Props),
    Packet#mqtt_packet{variable = PubPacket#mqtt_packet_publish{properties = NProps}};
put_ctx(
    OtelCtx,
    #mqtt_packet{
        variable = #mqtt_packet_puback{properties = Props} = PubAckPacket
    } = Packet
) ->
    NProps = to_properties(?EMQX_OTEL_CTX, OtelCtx, Props),
    Packet#mqtt_packet{variable = PubAckPacket#mqtt_packet_puback{properties = NProps}};
%% ====================
%% Rule Columns Metadata
put_ctx(
    OtelCtx,
    #{metadata := Metadata} = Envs
) ->
    Envs#{metadata => Metadata#{?EMQX_OTEL_CTX => OtelCtx}};
%% ====================
%% ignore
put_ctx(
    _OtelCtx,
    Any
) ->
    Any.

get_ctx(#message{extra = Extra}) ->
    from_extra(?EMQX_OTEL_CTX, Extra);
get_ctx(#delivery{message = #message{extra = Extra}}) ->
    from_extra(?EMQX_OTEL_CTX, Extra);
get_ctx(#mqtt_packet{
    variable = PktVar
}) when is_tuple(PktVar) ->
    from_extra(
        ?EMQX_OTEL_CTX,
        maps:get(
            ?MQTT_INTERNAL_EXTRA,
            emqx_packet:info(properties, PktVar),
            #{}
        )
    );
get_ctx(#{metadata := Metadata} = _Columns) ->
    maps:get(?EMQX_OTEL_CTX, Metadata, undefined);
get_ctx(_) ->
    undefined.

from_extra(Key, Map) ->
    maps:get(Key, Map, undefined).

to_properties(Key, Value, Props) ->
    Extra = maps:get(?MQTT_INTERNAL_EXTRA, Props, #{}),
    Props#{?MQTT_INTERNAL_EXTRA => Extra#{Key => Value}}.

clear() ->
    otel_ctx:clear(),
    ?with_trace_mode(
        ok,
        case logger:get_process_metadata() of
            M when is_map(M) ->
                logger:set_process_metadata(maps:without(otel_span:hex_span_ctx_keys(), M));
            _ ->
                ok
        end
    ).

%% --------------------------------------------------------------------
%% Legacy helpers
%% --------------------------------------------------------------------

packets_list(Packets) when is_list(Packets) ->
    Packets;
packets_list(Packet) ->
    [Packet].

legacy_mode_root_ctx(#mqtt_packet{variable = PktVar}) ->
    case should_trace_packet(PktVar) of
        true ->
            Ctx = extract_traceparent_from_packet(PktVar),
            should_trace_context(Ctx) andalso Ctx;
        false ->
            false
    end.

e2e_mode_root_ctx(#mqtt_packet{variable = PktVar}) ->
    case persistent_term:get(?TRACE_FOLLOW_TRACEPARENT_KEY, true) of
        true ->
            extract_traceparent_from_packet(PktVar);
        false ->
            otel_ctx:new()
    end;
e2e_mode_root_ctx(#{metadata := #{?EMQX_OTEL_CTX := Ctx}}) ->
    Ctx;
e2e_mode_root_ctx(#{reply_to := {_, _, #{metadata := #{?EMQX_OTEL_CTX := Ctx}}}} = _RequestContext) ->
    Ctx;
e2e_mode_root_ctx(_) ->
    otel_ctx:new().

extract_traceparent_from_packet(PktVar) ->
    Ctx = otel_ctx:new(),
    case emqx_packet:info(properties, PktVar) of
        #{?USER_PROPERTY := UserProps} ->
            otel_propagator_text_map:extract_to(Ctx, UserProps);
        _ ->
            Ctx
    end.

should_trace_context(RootCtx) ->
    map_size(RootCtx) > 0 orelse ?SHOULD_TRACE_ALL.

should_trace_packet(Packet) ->
    not is_sys(emqx_packet:info(topic_name, Packet)).

%% TODO: move to emqx_topic module?
is_sys(<<"$SYS/", _/binary>> = _Topic) -> true;
is_sys(_Topic) -> false.

msg_attributes(Msg) ->
    #{
        'messaging.destination.name' => emqx_message:topic(Msg),
        'messaging.client_id' => emqx_message:from(Msg)
    }.

packet_attributes(#mqtt_packet{variable = Packet}) ->
    #{'messaging.destination.name' => emqx_packet:info(topic_name, Packet)}.

channel_attributes(ChannelInfo) ->
    #{'messaging.client_id' => maps:get(clientid, ChannelInfo, undefined)}.

sub_channel_attributes(ChannelInfo) ->
    channel_attributes(ChannelInfo).

put_ctx_to_msg(OtelCtx, Msg = #message{extra = Extra}) when is_map(Extra) ->
    Msg#message{extra = Extra#{?EMQX_OTEL_CTX => OtelCtx}};
%% extra field has not being used previously and defaulted to an empty list, it's safe to overwrite it
put_ctx_to_msg(OtelCtx, Msg) when is_record(Msg, message) ->
    Msg#message{extra = #{?EMQX_OTEL_CTX => OtelCtx}}.

put_ctx_to_packet(
    OtelCtx, #mqtt_packet{variable = #mqtt_packet_publish{properties = Props} = PubPacket} = Packet
) ->
    Extra = maps:get(internal_extra, Props, #{}),
    Props1 = Props#{internal_extra => Extra#{?EMQX_OTEL_CTX => OtelCtx}},
    Packet#mqtt_packet{variable = PubPacket#mqtt_packet_publish{properties = Props1}}.

get_ctx_from_msg(#message{extra = Extra}) ->
    from_extra(Extra).

get_ctx_from_packet(#mqtt_packet{
    variable = #mqtt_packet_publish{properties = #{internal_extra := Extra}}
}) ->
    from_extra(Extra);
get_ctx_from_packet(_) ->
    undefined.

from_extra(#{?EMQX_OTEL_CTX := OtelCtx}) ->
    OtelCtx;
from_extra(_) ->
    undefined.

safe_stop_default_tracer() ->
    try
        _ = opentelemetry:stop_default_tracer_provider(),
        ok
    catch
        %% noramal scenario, opentelemetry supervisor is not started
        exit:{noproc, _} -> ok
    end,
    ok.

assert_started({ok, _Pid}) -> ok;
assert_started({ok, _Pid, _Info}) -> ok;
assert_started({error, {already_started, _Pid}}) -> ok;
assert_started({error, Reason}) -> {error, Reason}.
