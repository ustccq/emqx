%%--------------------------------------------------------------------
%% Copyright (c) 2021-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

%% @doc The Gateway channel behavior
%%
%% This module does not export any functions at the moment.
%% It is only used to standardize the implement of emqx_foo_channel.erl
%% module if it integrated with emqx_gateway_conn module
-module(emqx_gateway_channel).

-export_type([gen_server_from/0, channel/0]).

-type channel() :: any().

%%--------------------------------------------------------------------
%% Info & Stats

%% @doc Get the channel detailed information.
-callback info(channel()) -> emqx_types:infos().

-callback info(Key :: atom() | [atom()], channel()) -> any().

%% @doc Get the channel statistic items
-callback stats(channel()) -> emqx_types:stats().

%%--------------------------------------------------------------------
%% Init

%% @doc Initialize the channel state
-callback init(emqx_types:conninfo(), map()) -> channel().

%%--------------------------------------------------------------------
%% Handles

-type conn_state() :: idle | connecting | connected | disconnected | atom().

-type gen_server_from() :: {pid(), Tag :: term()}.

-type reply() ::
    {outgoing, emqx_gateway_frame:frame()}
    | {outgoing, [emqx_gateway_frame:frame()]}
    | {event, conn_state() | updated}
    | {close, Reason :: atom()}.

-type replies() :: reply() | [reply()].

%% @doc Handle the incoming frame
-callback handle_in(
    emqx_gateway_frame:frame() | {frame_error, any()},
    channel()
) ->
    {ok, channel()}
    | {ok, replies(), channel()}
    | {shutdown, Reason :: any(), channel()}
    | {shutdown, Reason :: any(), replies(), channel()}.

%% @doc Handle the outgoing messages dispatched from PUB/SUB system
-callback handle_deliver(list(emqx_types:deliver()), channel()) ->
    {ok, channel()}
    | {ok, replies(), channel()}.

%% @doc Handle the timeout event
-callback handle_timeout(reference(), Msg :: any(), channel()) ->
    {ok, channel()}
    | {ok, replies(), channel()}
    | {shutdown, Reason :: any(), channel()}.

%% @doc Handle the custom gen_server:call/2 for its connection process
-callback handle_call(Req :: any(), From :: gen_server_from(), channel()) ->
    {reply, Reply :: any(), channel()}
    %% Reply to caller and trigger an event(s)
    | {reply, Reply :: any(), EventOrEvents :: tuple() | list(tuple()), channel()}
    | {noreply, channel()}
    | {noreply, EventOrEvents :: tuple() | list(tuple()), channel()}
    | {shutdown, Reason :: any(), Reply :: any(), channel()}
    %% Shutdown the process, reply to caller and write a packet to client
    | {shutdown, Reason :: any(), Reply :: any(), emqx_gateway_frame:frame(), channel()}.

%% @doc Handle the custom gen_server:cast/2 for its connection process
-callback handle_cast(Req :: any(), channel()) ->
    ok
    | {ok, channel()}
    | {shutdown, Reason :: any(), channel()}.

%% @doc Handle the custom process messages for its connection process
-callback handle_info(Info :: any(), channel()) ->
    ok
    | {ok, channel()}
    | {shutdown, Reason :: any(), channel()}.

%%--------------------------------------------------------------------
%% Terminate

%% @doc The callback for process terminated
-callback terminate(any(), channel()) -> ok.

-export_type([conn_state/0, reply/0, replies/0]).
