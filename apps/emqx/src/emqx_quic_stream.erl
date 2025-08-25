%%--------------------------------------------------------------------
%% Copyright (c) 2021-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

%% MQTT over QUIC
%% multistreams: This is the control stream.
%% single stream: This is the only main stream.
%%   callbacks are from emqx_connection process rather than quicer_stream
-module(emqx_quic_stream).

-ifndef(BUILD_WITHOUT_QUIC).

-behaviour(quicer_remote_stream).

-include("logger.hrl").
-include_lib("emqx/include/emqx_mqtt.hrl").

%% emqx transport Callbacks
-export([
    type/1,
    wait/1,
    getstat/2,
    fast_close/1,
    shutdown/2,
    shutdown/3,
    abort_read/2,
    ensure_ok_or_exit/2,
    send/2,
    setopts/2,
    getopts/2,
    peername/1,
    sockname/1,
    peercert/1,
    peersni/1,
    wait_for_close/1
]).

-export_type([cb_ret/0, cb_data/0, connection_handle/0, stream_handle/0, socket_info/0]).

-include_lib("quicer/include/quicer.hrl").
-include_lib("emqx/include/emqx_quic.hrl").

-type cb_ret() :: quicer_stream:cb_ret().
-type cb_data() :: quicer_stream:cb_state().
-type connection_handle() :: quicer:connection_handle().
-type stream_handle() :: quicer:stream_handle().

-export([
    send_complete/3,
    peer_send_shutdown/3,
    peer_send_aborted/3,
    peer_receive_aborted/3,
    send_shutdown_complete/3,
    stream_closed/3,
    passive/3
]).

-export_type([socket/0]).

-type socket() :: {quic, connection_handle(), stream_handle(), socket_info()}.

-type socket_info() :: #{
    is_orphan => boolean(),
    ctrl_stream_start_flags => quicer:stream_open_flags(),
    %% and quicer:new_conn_props()
    _ => _
}.

%%% For Accepting New Remote Stream
-spec wait({pid(), connection_handle(), socket_info()}) ->
    {ok, socket()} | {error, enotconn}.
wait({ConnOwner, Conn, ConnInfo}) ->
    {ok, Conn} = quicer:async_accept_stream(Conn, []),
    ConnOwner ! {self(), stream_acceptor_ready},
    receive
        %% New incoming stream, this is a *control* stream
        {quic, new_stream, Stream, #{is_orphan := IsOrphan, flags := StartFlags}} ->
            SocketInfo = ConnInfo#{
                is_orphan => IsOrphan,
                ctrl_stream_start_flags => StartFlags
            },
            {ok, socket(Conn, Stream, SocketInfo)};
        %% connection closed event for stream acceptor
        {quic, closed, undefined, undefined} ->
            {error, enotconn};
        %% Connection owner process down
        {'EXIT', ConnOwner, _Reason} ->
            {error, enotconn}
    end.

-spec type(_) -> quic.
type(_) ->
    quic.

peername({quic, Conn, _Stream, _Info}) ->
    quicer:peername(Conn).

sockname({quic, Conn, _Stream, _Info}) ->
    quicer:sockname(Conn).

peercert(_S) ->
    %% @todo but unsupported by msquic
    nossl.

peersni(_S) ->
    %% @todo
    undefined.

getstat({quic, Conn, _Stream, _Info}, Stats) ->
    case quicer:getstat(Conn, Stats) of
        {error, _} -> {error, closed};
        Res -> Res
    end.

setopts({quic, _Conn, Stream, _Info}, Opts) ->
    lists:foreach(
        fun
            ({Opt, V}) when is_atom(Opt) ->
                quicer:setopt(Stream, Opt, V);
            (Opt) when is_atom(Opt) ->
                quicer:setopt(Stream, Opt, true)
        end,
        Opts
    ),
    ok.

getopts(_Socket, _Opts) ->
    %% @todo
    {ok, [
        {high_watermark, 0},
        {high_msgq_watermark, 0},
        {sndbuf, 0},
        {recbuf, 0},
        {buffer, 80000}
    ]}.

%% @TODO supply some App Error Code from caller
fast_close({ConnOwner, Conn, _ConnInfo}) when is_pid(ConnOwner) ->
    %% handshake aborted.
    _ = quicer:async_shutdown_connection(Conn, ?QUIC_CONNECTION_SHUTDOWN_FLAG_NONE, 0),
    ok;
fast_close({quic, _Conn, Stream, _Info}) ->
    %% Force flush, cutoff time 3s
    _ = quicer:shutdown_stream(Stream, ?QUIC_SAFE_TIMEOUT),
    %% @FIXME Since we shutdown the control stream, we shutdown the connection as well
    %% *BUT* Msquic does not flush the send buffer if we shutdown the connection after
    %% gracefully shutdown the stream.
    % quicer:async_shutdown_connection(Conn, ?QUIC_CONNECTION_SHUTDOWN_FLAG_NONE, 0),
    ok.

-spec wait_for_close(quicer:stream_handle()) -> ok.
wait_for_close(Stream) ->
    receive
        %% We are expecting peer to close the stream
        {quic, Evtname, Stream, _} when
            Evtname =:= peer_send_shutdown orelse
                Evtname =:= peer_send_aborted orelse
                Evtname =:= stream_closed
        ->
            ok
    after ?QUIC_SAFE_TIMEOUT ->
        ok
    end.

shutdown(Socket, Dir) ->
    shutdown(Socket, Dir, ?QUIC_SAFE_TIMEOUT).

shutdown({quic, _Conn, Stream, _Info}, read_write, Timeout) ->
    %% A graceful shutdown means both side shutdown the read and write gracefully.
    quicer:shutdown_stream(Stream, ?QUIC_STREAM_SHUTDOWN_FLAG_GRACEFUL, 1, Timeout).

abort_read({quic, _Conn, Stream, _Info}, Reason) ->
    %% while waiting for write to complete, abort read.
    %% use async to unblock the caller.
    Flag = ?QUIC_STREAM_SHUTDOWN_FLAG_ABORT_RECEIVE,
    quicer:async_shutdown_stream(
        Stream, Flag, reason_code(Reason)
    ).

reason_code(takenover) -> ?RC_SESSION_TAKEN_OVER;
reason_code(discarded) -> ?RC_SESSION_TAKEN_OVER;
reason_code(kicked) -> ?RC_ADMINISTRATIVE_ACTION;
reason_code(_) -> ?RC_UNSPECIFIED_ERROR.

-spec ensure_ok_or_exit(atom(), list(term())) -> term().
ensure_ok_or_exit(Fun, Args = [Sock | _]) when is_atom(Fun), is_list(Args) ->
    case erlang:apply(?MODULE, Fun, Args) of
        {error, Reason} when Reason =:= enotconn; Reason =:= closed ->
            fast_close(Sock),
            exit(normal);
        {error, Reason} ->
            fast_close(Sock),
            exit({shutdown, Reason});
        Result ->
            Result
    end.

send({quic, _Conn, Stream, _Info}, Data) ->
    case quicer:async_send(Stream, Data, ?QUICER_SEND_FLAG_SYNC) of
        {ok, _Len} -> ok;
        {error, X, Y} -> {error, {X, Y}};
        Other -> Other
    end.

%%%
%%% quicer stream callbacks
%%%

-spec peer_receive_aborted(stream_handle(), non_neg_integer(), cb_data()) -> cb_ret().
peer_receive_aborted(Stream, ErrorCode, S) ->
    _ = quicer:async_shutdown_stream(Stream, ?QUIC_STREAM_SHUTDOWN_FLAG_ABORT, ErrorCode),
    {ok, S}.

-spec peer_send_aborted(stream_handle(), non_neg_integer(), cb_data()) -> cb_ret().
peer_send_aborted(Stream, ErrorCode, S) ->
    %% we abort receive with same reason
    _ = quicer:async_shutdown_stream(Stream, ?QUIC_STREAM_SHUTDOWN_FLAG_ABORT, ErrorCode),
    {ok, S}.

-spec peer_send_shutdown(stream_handle(), undefined, cb_data()) -> cb_ret().
peer_send_shutdown(Stream, undefined, S) ->
    _ = quicer:async_shutdown_stream(Stream, ?QUIC_STREAM_SHUTDOWN_FLAG_GRACEFUL, 0),
    {ok, S}.

-spec send_complete(stream_handle(), boolean(), cb_data()) -> cb_ret().
send_complete(_Stream, false, S) ->
    {ok, S};
send_complete(_Stream, true = _IsCancelled, S) ->
    ?SLOG(error, #{msg => "send_cancelled"}),
    {ok, S}.

-spec send_shutdown_complete(stream_handle(), boolean(), cb_data()) -> cb_ret().
send_shutdown_complete(_Stream, _IsGraceful, S) ->
    {ok, S}.

-spec passive(stream_handle(), undefined, cb_data()) -> cb_ret().
passive(Stream, undefined, S) ->
    case quicer:setopt(Stream, active, 10) of
        ok -> ok;
        Error -> ?SLOG(error, #{msg => "set_active_error", error => Error})
    end,
    {ok, S}.

-spec stream_closed(stream_handle(), quicer:stream_closed_props(), cb_data()) ->
    {{continue, term()}, cb_data()}.
stream_closed(
    _Stream,
    #{
        is_conn_shutdown := IsConnShutdown,
        is_app_closing := IsAppClosing,
        is_shutdown_by_app := IsAppShutdown,
        is_closed_remotely := IsRemote,
        status := Status,
        error := Code
    },
    S
) when
    is_boolean(IsConnShutdown) andalso
        is_boolean(IsAppClosing) andalso
        is_boolean(IsAppShutdown) andalso
        is_boolean(IsRemote) andalso
        is_atom(Status) andalso
        is_integer(Code)
->
    %% For now we fake a sock_closed for
    %% emqx_connection:process_msg to append
    %% a msg to be processed
    Reason =
        case Code of
            ?MQTT_QUIC_CONN_NOERROR ->
                normal;
            _ ->
                Status
        end,
    {{continue, {sock_closed, Reason}}, S}.

%%%
%%%  Internals
%%%
-spec socket(connection_handle(), stream_handle(), socket_info()) -> socket().
socket(Conn, CtrlStream, Info) when is_map(Info) ->
    {quic, Conn, CtrlStream, Info}.

%% BUILD_WITHOUT_QUIC
-else.
-endif.
